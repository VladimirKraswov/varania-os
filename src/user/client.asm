format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  ;// Handle 1 передал init при создании: это endpoint service с CAP_SEND.
  mov ebx, 1
.send_next:
  mov eax, SYS_SEND
  mov edi, 1
  mov rsi, rbx
  syscall
  test rax, rax
  jnz .failed
  inc rbx
  cmp rbx, 5
  jb .send_next
  log sent_text, sent_text.size
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 2

segment readable writeable
sent_text db "client: four IPC messages sent", 10
.size = $-sent_text
failed_text db "client: IPC send failed", 10
.size = $-failed_text
