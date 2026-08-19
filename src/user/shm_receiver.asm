format ELF64 executable 3
entry start
include "abi.inc"

SELF_EP = 1
SHARED_BASE = 0x60000000
FIRST_MAGIC = 0x517ACAFE
SECOND_MAGIC = 0x13579BDF
ACK_MAGIC = 0x02468ACE

segment readable executable
start:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz .failed
  cmp qword [message+IpcMessage.cap_count], 2
  jne .failed
  mov r12, qword [message+IpcMessage.caps+IpcCap.handle]
  mov r13, qword [message+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov eax, SYS_SHARED_MAP
  mov rdi, r12
  mov esi, SHARED_BASE
  mov edx, SPACE_MAP_WRITE
  syscall
  test rax, rax
  jnz .failed
  cmp qword [SHARED_BASE], FIRST_MAGIC
  jne .failed
  cmp qword [SHARED_BASE+PAGE_SIZE], SECOND_MAGIC
  jne .failed
  mov qword [SHARED_BASE+PAGE_SIZE], ACK_MAGIC
  mov qword [message+IpcMessage.cap_count], 0
  mov qword [message+IpcMessage.words], ACK_MAGIC
  mov eax, SYS_IPC_SEND
  mov rdi, r13
  lea rsi, [message]
  syscall
  test rax, rax
  jnz .failed
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
failed_text db "shm-receiver: failed", 10
.size = $-failed_text
align 8
message rb IpcMessage.bytes
