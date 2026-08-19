format ELF64 executable 3
entry start
include "abi.inc"

SELF_EP = 1
NAMESERVER_EP = 2
SERVICE_ID = 1

segment readable executable
start:
  log ready_text, ready_text.size
  mov qword [message+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [message+IpcMessage.words+8], SERVICE_ID
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  test rax, rax
  jnz .failed

  xor ebx, ebx
.receive_batch:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz .failed
  inc rbx
  cmp qword [message+IpcMessage.words], rbx
  jne .failed
  cmp rbx, 4
  jb .receive_batch

  log queue_ok_text, queue_ok_text.size
.serve_forever:
  ipc_receive SELF_EP, message
  jmp .serve_forever

.failed:
  log error_text, error_text.size
  exit_process 1

segment readable writeable
ready_text db "service: registering endpoint in nameserver", 10
.size = $-ready_text
queue_ok_text db "VARANIA:IPC_QUEUE_OK", 10
.size = $-queue_ok_text
error_text db "service: wrong endpoint IPC sequence", 10
.size = $-error_text
align 8
message rb IpcMessage.bytes
