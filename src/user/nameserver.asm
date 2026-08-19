format ELF64 executable 3
entry start
include "abi.inc"

;// Минимальный user-space nameserver. Он ничего не знает о процессах: хранит
;// только ослабленную SEND-capability и версию ABI сервиса. Эта пара является
;// микроядерным аналогом динамической библиотеки: клиент подключает контракт
;// во время исполнения, но исполняемый код и состояние остаются изолированы.

SELF_EP = 1
SERVICE_MAX = 12

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
  mov rbx, qword [message+IpcMessage.words+8]
  test rbx, rbx
  jz .clear
  cmp rbx, SERVICE_MAX
  ja .clear
  dec rbx
  mov rdi, [service_endpoints+rbx*8]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [service_endpoints+rbx*8], rax
  mov rax, qword [message+IpcMessage.words+16]
  test rax, rax
  jnz .store_version
  mov eax, 1                     ;// старые сервисы автоматически получают ABI 1
.store_version:
  mov [service_versions+rbx*8], rax
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
  mov rbx, qword [message+IpcMessage.words+8]
  test rbx, rbx
  jz .missing
  cmp rbx, SERVICE_MAX
  ja .missing
  dec rbx
  mov rax, [service_endpoints+rbx*8]
  test rax, rax
  jz .missing
  mov rdx, [service_versions+rbx*8]
  mov rcx, qword [message+IpcMessage.words+16] ;// минимальная версия клиента
  cmp rdx, rcx
  jb .incompatible
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rdx
  mov qword [reply+IpcMessage.cap_count], 1
  mov qword [reply+IpcMessage.caps+IpcCap.handle], rax
  mov qword [reply+IpcMessage.caps+IpcCap.rights], CAP_SEND
  jmp .reply
.incompatible:
  mov qword [reply+IpcMessage.words], -93 ;// EPROTONOSUPPORT
  mov qword [reply+IpcMessage.words+8], rdx
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
service_endpoints dq SERVICE_MAX dup(0)
service_versions dq SERVICE_MAX dup(0)
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
