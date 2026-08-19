format ELF64 executable 3
entry start
include "abi.inc"

SELF_EP    = 1
RECEIVER_EP = 2
SYSTEM_CAP = 3
SHARED_BASE = 0x60000000
FIRST_MAGIC = 0x517ACAFE
SECOND_MAGIC = 0x13579BDF
ACK_MAGIC = 0x02468ACE

segment readable executable
start:
  mov eax, SYS_SHARED_CREATE
  mov edi, SYSTEM_CAP
  mov esi, 2                       ;// проверяем объект из нескольких страниц
  syscall
  test rax, rax
  js .failed
  mov r12, rax
  mov eax, SYS_SHARED_MAP
  mov rdi, r12
  mov esi, SHARED_BASE
  mov edx, SPACE_MAP_WRITE
  syscall
  test rax, rax
  jnz .failed
  mov qword [SHARED_BASE], FIRST_MAGIC
  mov qword [SHARED_BASE+PAGE_SIZE], SECOND_MAGIC

  ;// Вместе с shared object передаём send-only endpoint для подтверждения.
  mov qword [message+IpcMessage.cap_count], 2
  mov qword [message+IpcMessage.caps+IpcCap.handle], r12
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_MAP+CAP_READ+CAP_WRITE
  mov qword [message+IpcMessage.caps+IpcCap.bytes+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.bytes+IpcCap.rights], CAP_SEND
  ipc_send RECEIVER_EP, message
  test rax, rax
  jnz .failed
  ipc_receive SELF_EP, response
  test rax, rax
  jnz .failed
  cmp qword [response+IpcMessage.words], ACK_MAGIC
  jne .failed
  cmp qword [SHARED_BASE+PAGE_SIZE], ACK_MAGIC
  jne .failed
  log ok_text, ok_text.size
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
ok_text db "VARANIA:SHM_OK", 10
.size = $-ok_text
failed_text db "shm-sender: failed", 10
.size = $-failed_text
align 8
message rb IpcMessage.bytes
response rb IpcMessage.bytes
