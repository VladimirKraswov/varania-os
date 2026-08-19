format ELF64 executable 3
entry start
include "abi.inc"

;//////////////////////////////////////////////////////////////////////////////
;// sessiond — supervisor foreground-процесса
;//////////////////////////////////////////////////////////////////////////////
;
;// Shell не может сам обработать Ctrl+C, пока заблокирован в SYS_WAIT.
;// Поэтому он делегирует sessiond только CAP_CONTROL текущего ребёнка.
;// Terminal остаётся отзывчивым и посылает SESSION_INTERRUPT независимо от
;// состояния приложения; ядро снимает цель с CPU, IPC, IRQ или WAIT.

SELF_EP       = 1
NAMESERVER_EP = 2
IPC_WOULD_BLOCK = -11
FOREGROUND_MAX = 8

segment readable executable
start:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [message+IpcMessage.words+8], SERVICE_SESSION
  mov qword [message+IpcMessage.words+16], 1
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov edi, NAMESERVER_EP
  lea rsi, [message]
  call send_retry
  test rax, rax
  jnz .failed
  log ready_text, ready_text.size

.serve:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz .failed
  mov rax, qword [message+IpcMessage.words]
  cmp rax, SESSION_SET_FOREGROUND
  je .set
  cmp rax, SESSION_CLEAR_FOREGROUND
  je .clear_foreground
  cmp rax, SESSION_INTERRUPT
  je .interrupt
  call close_received_caps
  jmp .clear_message

.set:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .discard
  test qword [message+IpcMessage.caps+IpcCap.rights], CAP_CONTROL
  jz .discard
  mov rdx, [foreground_depth]
  cmp rdx, FOREGROUND_MAX
  jae .discard
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [foreground_stack+rdx*8], rax
  mov rax, qword [message+IpcMessage.sender]
  mov [foreground_owner+rdx*8], rax
  inc qword [foreground_depth]
  ;// Capability теперь принадлежит policy state, а не входному сообщению.
  mov qword [message+IpcMessage.cap_count], 0
  log foreground_text, foreground_text.size
  jmp .clear_message

.clear_foreground:
  call close_received_caps
  mov rax, [foreground_depth]
  test rax, rax
  jz .clear_message
  dec rax
  mov rdx, qword [message+IpcMessage.sender]
  cmp rdx, [foreground_owner+rax*8]
  jne .clear_message             ;// чужой клиент не снимает foreground frame
  call pop_foreground
  jmp .clear_message

.interrupt:
  call close_received_caps
  mov rax, [foreground_depth]
  test rax, rax
  jz .clear_message
  dec rax
  mov rdi, [foreground_stack+rax*8]
  test rdi, rdi
  jz .clear_message
  mov eax, SYS_PROCESS_KILL
  mov esi, SESSION_INTERRUPTED_STATUS
  syscall
  test rax, rax
  jnz .clear_message
  log interrupted_text, interrupted_text.size
  ;// Не снимаем frame стека здесь: ожидающий родитель получит status 130 и
  ;// пришлёт CLEAR. Так вложенный run восстановит предыдущий foreground.
  jmp .clear_message

.discard:
  call close_received_caps
.clear_message:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  jmp .serve

.failed:
  log failed_text, failed_text.size
  exit_process 1

pop_foreground:
  mov rax, [foreground_depth]
  test rax, rax
  jz .done
  dec rax
  mov [foreground_depth], rax
  mov rdi, [foreground_stack+rax*8]
  mov qword [foreground_stack+rax*8], 0
  mov qword [foreground_owner+rax*8], 0
  call close_handle
.done:
  ret

close_received_caps:
  mov rcx, qword [message+IpcMessage.cap_count]
  xor ebx, ebx
.next:
  cmp rbx, rcx
  jae .done
  mov rax, rbx
  shl rax, 4
  mov rdi, qword [message+IpcMessage.caps+rax+IpcCap.handle]
  push rcx
  call close_handle
  pop rcx
  inc rbx
  jmp .next
.done:
  ret

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
.done:
  ret

send_retry:
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
.again:
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  mov rsi, r13
  syscall
  cmp rax, IPC_WOULD_BLOCK
  jne .done
  system_call SYS_YIELD
  jmp .again
.done:
  pop r13
  pop r12
  ret

segment readable writeable
ready_text db "sessiond: foreground supervision ready", 10
.size = $-ready_text
foreground_text db "VARANIA:FOREGROUND_TRACKED", 10
.size = $-foreground_text
interrupted_text db "VARANIA:FOREGROUND_INTERRUPTED", 10
.size = $-interrupted_text
failed_text db "sessiond: fatal IPC error", 10
.size = $-failed_text
align 8
foreground_depth dq 0
foreground_stack rq FOREGROUND_MAX
foreground_owner rq FOREGROUND_MAX
message rb IpcMessage.bytes
