format ELF64 executable 3
entry start
include "abi.inc"

;// Минимальный user-space nameserver. Он ничего не знает о процессах: хранит
;// только ослабленную SEND-capability зарегистрированного endpoint.

SELF_EP = 1

segment readable executable
start:
  log ready_text, ready_text.size
.serve:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz .failed
  mov rax, qword [message+IpcMessage.words]
  cmp rax, NAMESERVER_REGISTER
  je .register
  cmp rax, NAMESERVER_LOOKUP
  je .lookup
  jmp .clear

.register:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .clear
  mov rdi, [service_endpoint]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [service_endpoint], rax
  log registered_text, registered_text.size
  jmp .clear_without_received_caps

.lookup:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .clear
  mov r12, qword [message+IpcMessage.caps+IpcCap.handle]
  lea rdi, [reply]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov rax, [service_endpoint]
  test rax, rax
  jz .missing
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.cap_count], 1
  mov qword [reply+IpcMessage.caps+IpcCap.handle], rax
  mov qword [reply+IpcMessage.caps+IpcCap.rights], CAP_SEND
  jmp .reply
.missing:
  mov qword [reply+IpcMessage.words], -2
.reply:
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  lea rsi, [reply]
  syscall
  mov rdi, r12
  call close_handle                 ;// временная reply capability
  jmp .clear_without_received_caps

.clear:
  ;// Неизвестное сообщение не должно оставлять переданные handles.
  mov rcx, qword [message+IpcMessage.cap_count]
  xor ebx, ebx
.close_cap:
  cmp rbx, rcx
  jae .clear_without_received_caps
  mov rax, rbx
  shl rax, 4
  mov rdi, qword [message+IpcMessage.caps+rax+IpcCap.handle]
  push rcx
  call close_handle
  pop rcx
  inc rbx
  jmp .close_cap
.clear_without_received_caps:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  jmp .serve

.failed:
  log failed_text, failed_text.size
  exit_process 2

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
.done:
  ret

segment readable writeable
ready_text db "nameserver: endpoint registry ready", 10
.size = $-ready_text
registered_text db "nameserver: service endpoint registered", 10
.size = $-registered_text
failed_text db "nameserver: IPC error", 10
.size = $-failed_text
align 8
service_endpoint dq 0
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
