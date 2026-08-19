format ELF64 executable 3
entry start
include "abi.inc"

SELF_EP = 1

segment readable executable
start:
  ;// Создаём цепочку root → handle2 → handle3 обычной передачей capability.
  lea rdi, [message]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send SELF_EP, message
  test rax, rax
  jnz .failed
  ipc_receive SELF_EP, received
  test rax, rax
  jnz .failed
  mov r12, qword [received+IpcMessage.caps+IpcCap.handle]

  mov qword [message+IpcMessage.caps+IpcCap.handle], r12
  ipc_send SELF_EP, message
  test rax, rax
  jnz .failed
  ipc_receive SELF_EP, received
  test rax, rax
  jnz .failed
  mov r13, qword [received+IpcMessage.caps+IpcCap.handle]

  ;// Revoke сохраняет корневой handle, но атомарно закрывает всех потомков,
  ;// даже если между ними были временные узлы очереди IPC.
  mov eax, SYS_CAP_REVOKE
  mov edi, SELF_EP
  syscall
  cmp rax, 2
  jne .failed
  log active_text, active_text.size
  mov qword [message+IpcMessage.cap_count], 0
  mov eax, SYS_IPC_SEND
  mov rdi, r13
  lea rsi, [message]
  syscall
  cmp rax, -9
  jne .failed

  ;// Сам root не отозван и остаётся пригоден для IPC.
  ipc_send SELF_EP, message
  test rax, rax
  jnz .failed
  ipc_receive SELF_EP, received
  test rax, rax
  jnz .failed

  ;// Отзыв descendant, который ещё лежит в очереди, отменяет сообщение
  ;// целиком: payload без ожидаемой capability доставлять небезопасно.
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send SELF_EP, message
  test rax, rax
  jnz .failed
  log queued_text, queued_text.size
  mov eax, SYS_CAP_REVOKE
  mov edi, SELF_EP
  syscall
  test rax, rax                    ;// queued ghost не является active handle
  jnz .failed
  ipc_receive SELF_EP, received
  cmp rax, -9
  jne .failed

  mov qword [message+IpcMessage.cap_count], 0
  ipc_send SELF_EP, message
  test rax, rax
  jnz .failed
  ipc_receive SELF_EP, received
  test rax, rax
  jnz .failed
  log ok_text, ok_text.size
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
ok_text db "VARANIA:REVOKE_OK", 10
.size = $-ok_text
active_text db "cap-revoke-test: active descendants revoked", 10
.size = $-active_text
queued_text db "cap-revoke-test: revoking queued descendant", 10
.size = $-queued_text
failed_text db "cap-revoke-test: failed", 10
.size = $-failed_text
align 8
message rb IpcMessage.bytes
received rb IpcMessage.bytes
