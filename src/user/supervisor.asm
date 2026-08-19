format ELF64 executable 3
entry start
include "abi.inc"

SELF_EP  = 1
PROCD_EP = 2
KILLED_STATUS = 77
FAILED_STATUS = 55

segment readable executable
start:
  ;// Сначала проверяем административное завершение процесса, который мог уже
  ;// успеть заблокироваться в IPC_RECV.
  lea rdi, [kill_target_name]
  mov esi, kill_target_name.size
  call spawn
  test rax, rax
  js .failed
  mov r12, rax
  mov rdi, rdx
  call close_handle
  system_call SYS_YIELD
  system_call SYS_YIELD
  mov eax, SYS_PROCESS_KILL
  mov rdi, r12
  mov esi, KILLED_STATUS
  syscall
  test rax, rax
  jnz .failed
  mov rdi, r12
  system_call SYS_WAIT
  cmp rax, KILLED_STATUS
  jne .failed
  log kill_ok_text, kill_ok_text.size

  ;// Простая restart policy: дважды наблюдаем отказ и каждый раз создаём новый
  ;// процесс. Политика находится в user space, а ядро предоставляет только
  ;// lifecycle-примитивы и защищённые capabilities.
  mov ebx, 2
.restart:
  lea rdi, [worker_name]
  mov esi, worker_name.size
  call spawn
  test rax, rax
  js .failed
  mov r12, rax
  mov rdi, rdx
  call close_handle
  mov rdi, r12
  system_call SYS_WAIT
  cmp rax, FAILED_STATUS
  jne .failed
  dec ebx
  jnz .restart

  log supervisor_ok_text, supervisor_ok_text.size
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 1

;// RPC PROCD_SPAWN. RDI=name, RSI=len; RAX=process, RDX=child endpoint.
spawn:
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  test r13, r13
  jz .invalid
  cmp r13, 23
  ja .invalid
  lea rdi, [request]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [request+IpcMessage.words], PROCD_SPAWN
  lea rdi, [request+IpcMessage.words+8]
  mov rsi, r12
  mov rcx, r13
  rep movsb
  mov qword [request+IpcMessage.cap_count], 1
  mov qword [request+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [request+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send PROCD_EP, request
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, response
  test rax, rax
  jnz .done
  mov rax, qword [response+IpcMessage.words]
  test rax, rax
  js .done
  cmp qword [response+IpcMessage.cap_count], 2
  jne .invalid
  mov rax, qword [response+IpcMessage.caps+IpcCap.handle]
  mov rdx, qword [response+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  jmp .done
.invalid:
  mov rax, -22
.done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
  ret

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
.done:
  ret

segment readable writeable
kill_target_name db "kill_target.elf"
.size = $-kill_target_name
worker_name db "restart_worker.elf"
.size = $-worker_name
kill_ok_text db "VARANIA:KILL_OK", 10
.size = $-kill_ok_text
supervisor_ok_text db "VARANIA:SUPERVISOR_OK", 10
.size = $-supervisor_ok_text
failed_text db "supervisor: policy test failed", 10
.size = $-failed_text
align 8
request rb IpcMessage.bytes
response rb IpcMessage.bytes
