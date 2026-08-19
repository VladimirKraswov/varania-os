format ELF64 executable 3
entry start
include "abi.inc"

ROOT_CAP = 1
IRQ_CAP  = 2
IO_CAP   = 3
FAULT_EXIT_CODE = 128+14

segment readable executable
start:
  log init_text, init_text.size

  ;// Сначала постоянный IPC-сервис. Возвращённая process capability содержит
  ;// CAP_SEND|CAP_WAIT; клиенту передаём только ослабленное право CAP_SEND.
  lea rsi, [service_name]
  mov edx, service_name.size
  xor r10d, r10d
  xor r8d, r8d
  call spawn
  test rax, rax
  js init_failed
  mov r12, rax

  mov [one_grant.handle], r12
  mov qword [one_grant.rights], CAP_SEND
  lea rsi, [client_name]
  mov edx, client_name.size
  lea r10, [one_grant]
  mov r8d, 1
  call spawn
  test rax, rax
  js init_failed
  mov r13, rax

  lea rsi, [memory_name]
  mov edx, memory_name.size
  xor r10d, r10d
  xor r8d, r8d
  call spawn
  test rax, rax
  js init_failed
  mov r14, rax

  lea rsi, [isolation_name]
  mov edx, isolation_name.size
  xor r10d, r10d
  xor r8d, r8d
  call spawn
  test rax, rax
  js init_failed
  mov r15, rax

  ;// Драйвер получает ровно IRQ1 и read-only диапазон портов, причём handles
  ;// внутри ребёнка будут 1 и 2 независимо от номеров capabilities init.
  lea rsi, [keyboard_name]
  mov edx, keyboard_name.size
  lea r10, [driver_grants]
  mov r8d, 2
  call spawn
  test rax, rax
  js init_failed

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

  ;// Первый ребёнок прогревает slab. Затем сравниваем число свободных кадров
  ;// до и после полного create → exit → wait → teardown второго процесса.
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

  log all_ok_text, all_ok_text.size
init_idle:
  system_call SYS_YIELD
  jmp init_idle

;// Вход: RSI=name, EDX=len, R10=grants, R8=count. Выход: process handle.
spawn:
  mov eax, SYS_SPAWN
  mov edi, ROOT_CAP
  syscall
  ret

spawn_lifecycle:
  lea rsi, [lifecycle_name]
  mov edx, lifecycle_name.size
  xor r10d, r10d
  xor r8d, r8d
  jmp spawn

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

init_failed:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
init_text db "init: launching user services and drivers from initramfs", 10
.size = $-init_text
isolation_ok_text db "VARANIA:ISOLATION_OK", 10
.size = $-isolation_ok_text
lifecycle_ok_text db "VARANIA:LIFECYCLE_OK", 10
.size = $-lifecycle_ok_text
all_ok_text db "VARANIA:MICROKERNEL_OK", 10
.size = $-all_ok_text
failed_text db "init: integration test failed", 10
.size = $-failed_text

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

align 8
one_grant:
  .handle dq 0
  .rights dq 0
driver_grants:
  dq IRQ_CAP, CAP_WAIT
  dq IO_CAP, CAP_READ
