format ELF64 executable 3
entry start
include "abi.inc"

SELF_EP = 1
NAMESERVER_EP = 2
SERVICE_ID = 1

segment readable executable
start:
.lookup:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [message+IpcMessage.words+8], SERVICE_ID
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  test rax, rax
  jnz .failed
  ipc_receive SELF_EP, reply
  test rax, rax
  jnz .failed
  cmp qword [reply+IpcMessage.words], 0
  je .found
  system_call SYS_YIELD
  jmp .lookup

.found:
  cmp qword [reply+IpcMessage.cap_count], 1
  jne .failed
  mov r12, qword [reply+IpcMessage.caps+IpcCap.handle]
  mov ebx, 1
.send_next:
  mov qword [message+IpcMessage.words], rbx
  mov qword [message+IpcMessage.cap_count], 0
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  lea rsi, [message]
  syscall
  test rax, rax
  jnz .failed
  inc rbx
  cmp rbx, 5
  jb .send_next
  mov eax, SYS_CAP_CLOSE
  mov rdi, r12
  syscall
  log sent_text, sent_text.size
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 2

segment readable writeable
sent_text db "client: service found; four messages sent", 10
.size = $-sent_text
failed_text db "client: discovery or endpoint IPC failed", 10
.size = $-failed_text
align 8
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
