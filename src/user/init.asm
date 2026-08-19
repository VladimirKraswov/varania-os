format ELF64 executable 3
entry start
include "abi.inc"

;// Handle 1 — собственный inbox endpoint каждого процесса.
;// Handle 2 — endpoint procd, переданный bootstrap-политикой.
SELF_EP  = 1
PROCD_EP = 2
FAULT_EXIT_CODE = 128+14

segment readable executable
start:
  log init_text, init_text.size

  ;// Nameserver — первый обычный сервис. Его endpoint возвращает procd как
  ;// capability и затем ослабленно передаётся service/client.
  lea rdi, [nameserver_name]
  mov esi, nameserver_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js init_failed
  mov rdi, rax
  call close_handle                 ;// nameserver долгоживущий
  mov r12, rdx                      ;// endpoint nameserver

  lea rdi, [service_name]
  mov esi, service_name.size
  mov rdx, r12
  mov ecx, CAP_SEND
  call spawn
  test rax, rax
  js init_failed
  mov rdi, rax
  call close_handle                 ;// service долгоживущий
  mov rdi, rdx
  call close_handle                 ;// его endpoint найдём через nameserver

  lea rdi, [client_name]
  mov esi, client_name.size
  mov rdx, r12
  mov ecx, CAP_SEND
  call spawn
  test rax, rax
  js init_failed
  mov r13, rax
  mov rdi, rdx
  call close_handle

  lea rdi, [memory_name]
  mov esi, memory_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js init_failed
  mov r14, rax
  mov rdi, rdx
  call close_handle

  lea rdi, [isolation_name]
  mov esi, isolation_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js init_failed
  mov r15, rax
  mov rdi, rdx
  call close_handle

  ;// Выбор IRQ/I/O capability для keyboard — bootstrap policy procd. Init не
  ;// владеет железом и потому не может случайно расширить права драйвера.
  lea rdi, [keyboard_name]
  mov esi, keyboard_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js init_failed
  mov rdi, rax
  call close_handle
  mov rdi, rdx
  call close_handle

  mov rdi, r13
  call wait_success
  test rax, rax
  jnz init_failed
  mov rdi, r14
  call wait_success
  test rax, rax
  jnz init_failed
  mov rdi, r15
  system_call SYS_WAIT
  cmp rax, FAULT_EXIT_CODE
  jne init_failed
  log isolation_ok_text, isolation_ok_text.size

  ;// Прогрев slab отделён от измерения. Второй create → exit → wait должен
  ;// вернуть frames address space, stack, page tables и kernel stack.
  call spawn_lifecycle
  test rax, rax
  js init_failed
  mov rdi, rax
  call wait_lifecycle
  test rax, rax
  jnz init_failed
  system_call SYS_MEM_INFO
  mov rbx, rax
  call spawn_lifecycle
  test rax, rax
  js init_failed
  mov rdi, rax
  call wait_lifecycle
  test rax, rax
  jnz init_failed
  system_call SYS_MEM_INFO
  cmp rax, rbx
  jne init_failed
  log lifecycle_ok_text, lifecycle_ok_text.size

  ;// Revoke проверяется отдельным процессом: временные descendants не должны
  ;// загрязнять capability table init.
  lea rdi, [revoke_name]
  mov esi, revoke_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js init_failed
  mov r13, rax
  mov rdi, rdx
  call close_handle
  mov rdi, r13
  call wait_success
  test rax, rax
  jnz init_failed

  ;// Supervisor получает только send-only endpoint procd. Capability процесса,
  ;// которую вернёт procd, уже содержит CONTROL и позволяет выполнить kill.
  lea rdi, [supervisor_name]
  mov esi, supervisor_name.size
  mov edx, PROCD_EP
  mov ecx, CAP_SEND
  call spawn
  test rax, rax
  js init_failed
  mov r13, rax
  mov rdi, rdx
  call close_handle
  mov rdi, r13
  call wait_success
  test rax, rax
  jnz init_failed

  ;// Первый shared round прогревает slab-классы. После второго число свободных
  ;// физических frames обязано совпасть: mappings, address spaces и сам объект
  ;// действительно освобождены, а не только скрыты закрытыми handles.
  call run_shared_round
  test rax, rax
  jnz init_failed
  system_call SYS_MEM_INFO
  mov rbx, rax
  call run_shared_round
  test rax, rax
  jnz init_failed
  system_call SYS_MEM_INFO
  cmp rax, rbx
  jne init_failed

  log all_ok_text, all_ok_text.size
.idle:
  system_call SYS_YIELD
  jmp .idle

;// RPC к procd.
;// RDI=name, RSI=len, RDX=optional cap, RCX=rights.
;// RAX=process cap/error, RDX=child endpoint cap.
spawn:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov r15, rcx
  test r13, r13
  jz .invalid
  cmp r13, 23
  ja .invalid
  lea rdi, [rpc_message]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [rpc_message+IpcMessage.words], PROCD_SPAWN
  lea rdi, [rpc_message+IpcMessage.words+8]
  mov rsi, r12
  mov rcx, r13
  rep movsb
  mov qword [rpc_message+IpcMessage.cap_count], 1
  mov qword [rpc_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [rpc_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  test r14, r14
  jz .send
  mov qword [rpc_message+IpcMessage.cap_count], 2
  mov qword [rpc_message+IpcMessage.caps+IpcCap.bytes+IpcCap.handle], r14
  mov qword [rpc_message+IpcMessage.caps+IpcCap.bytes+IpcCap.rights], r15
.send:
  ipc_send PROCD_EP, rpc_message
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, rpc_response
  test rax, rax
  jnz .done
  mov rax, qword [rpc_response+IpcMessage.words]
  test rax, rax
  js .done
  cmp qword [rpc_response+IpcMessage.cap_count], 2
  jne .invalid
  mov rax, qword [rpc_response+IpcMessage.caps+IpcCap.handle]
  mov rdx, qword [rpc_response+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  jmp .done
.invalid:
  mov rax, -22
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

spawn_lifecycle:
  lea rdi, [lifecycle_name]
  mov esi, lifecycle_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js .done
  push rax
  mov rdi, rdx
  call close_handle
  pop rax
.done:
  ret

;// Один полный shared-memory lifecycle. Receiver стартует первым и блокируется;
;// sender получает его endpoint, создаёт две страницы и ждёт подтверждение.
run_shared_round:
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8                       ;// System V alignment перед call
  lea rdi, [shm_receiver_name]
  mov esi, shm_receiver_name.size
  xor edx, edx
  xor ecx, ecx
  call spawn
  test rax, rax
  js .done
  mov r13, rax
  mov r14, rdx
  lea rdi, [shm_sender_name]
  mov esi, shm_sender_name.size
  mov rdx, r14
  mov ecx, CAP_SEND
  call spawn
  test rax, rax
  js .done
  mov r15, rax
  mov rdi, rdx
  call close_handle
  mov rdi, r14
  call close_handle
  mov rdi, r15
  call wait_success
  test rax, rax
  jnz .done
  mov rdi, r13
  call wait_success
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  ret

wait_success:
  system_call SYS_WAIT
  ret

wait_lifecycle:
  system_call SYS_WAIT
  cmp rax, 37
  jne .bad
  xor eax, eax
  ret
.bad:
  mov eax, 1
  ret

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
.done:
  ret

init_failed:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
init_text db "init: launching services through user-space procd", 10
.size = $-init_text
isolation_ok_text db "VARANIA:ISOLATION_OK", 10
.size = $-isolation_ok_text
lifecycle_ok_text db "VARANIA:LIFECYCLE_OK", 10
.size = $-lifecycle_ok_text
all_ok_text db "VARANIA:MICROKERNEL_OK", 10
.size = $-all_ok_text
failed_text db "init: integration test failed", 10
.size = $-failed_text

nameserver_name db "nameserver.elf"
.size = $-nameserver_name
service_name db "service.elf"
.size = $-service_name
client_name db "client.elf"
.size = $-client_name
memory_name db "memory_test.elf"
.size = $-memory_name
isolation_name db "isolation_test.elf"
.size = $-isolation_name
keyboard_name db "keyboard.elf"
.size = $-keyboard_name
lifecycle_name db "lifecycle_child.elf"
.size = $-lifecycle_name
revoke_name db "cap_revoke_test.elf"
.size = $-revoke_name
supervisor_name db "supervisor.elf"
.size = $-supervisor_name
shm_receiver_name db "shm_receiver.elf"
.size = $-shm_receiver_name
shm_sender_name db "shm_sender.elf"
.size = $-shm_sender_name

align 8
rpc_message rb IpcMessage.bytes
rpc_response rb IpcMessage.bytes
