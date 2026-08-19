format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  log ready_text, ready_text.size

  xor ebx, ebx
.receive_batch:
  system_call SYS_RECV
  inc rbx
  cmp rax, rbx
  jne .failed
  cmp rbx, 4
  jb .receive_batch

  log queue_ok_text, queue_ok_text.size
.serve_forever:
  system_call SYS_RECV
  jmp .serve_forever

.failed:
  log error_text, error_text.size
  exit_process 1

segment readable writeable
ready_text db "service: waiting for queued IPC", 10
.size = $-ready_text
queue_ok_text db "VARANIA:IPC_QUEUE_OK", 10
.size = $-queue_ok_text
error_text db "service: wrong IPC sequence", 10
.size = $-error_text
