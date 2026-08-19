format ELF64 executable 3
entry start
include "abi.inc"

;// PS/2 остаётся отдельным user-space driver. Он переводит scan code set 1 в
;// простой ASCII и отправляет события terminal service; line editing ему не
;// принадлежит. Handles задаёт policy procd.
SELF_EP       = 1
NAMESERVER_EP = 2
IRQ1_CAP      = 3
IO_CAP        = 4

segment readable executable
start:
  call lookup_terminal
  test rax, rax
  js .failed
  mov r12, rax
  log ready_text, ready_text.size

.wait:
  mov eax, SYS_IRQ_WAIT
  mov edi, IRQ1_CAP
  syscall
  test rax, rax
  js .failed
  mov eax, SYS_IO_READ8
  mov edi, IO_CAP
  xor esi, esi
  syscall
  test rax, rax
  js .failed
  mov rbx, rax
  test bl, 0x80                    ;// key release
  jnz .wait
  log handled_text, handled_text.size
  cmp bl, 64
  jae .wait
  movzx eax, byte [scancode_ascii+rbx]
  test al, al
  jz .wait
  mov qword [message+IpcMessage.words], TERM_KEY
  movzx eax, al
  mov qword [message+IpcMessage.words+8], rax
  mov qword [message+IpcMessage.cap_count], 0
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  lea rsi, [message]
  syscall
  test rax, rax
  jnz .failed
  jmp .wait

.failed:
  log failed_text, failed_text.size
  exit_process 1

;// Найти terminal endpoint через nameserver. RAX=handle/error.
lookup_terminal:
.retry:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [message+IpcMessage.words+8], SERVICE_TERMINAL
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, reply
  test rax, rax
  jnz .done
  cmp qword [reply+IpcMessage.words], 0
  je .found
  system_call SYS_YIELD
  jmp .retry
.found:
  cmp qword [reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [reply+IpcMessage.caps+IpcCap.handle]
  ret
.invalid:
  mov rax, -22
.done:
  ret

segment readable writeable
ready_text db "keyboard-driver: waiting for IRQ1", 10
.size = $-ready_text
handled_text db "keyboard-driver: IRQ1 handled", 10
.size = $-handled_text
failed_text db "keyboard-driver: terminal discovery or device error", 10
.size = $-failed_text

;// Нулевая запись означает «не текстовая клавиша». Shift/Ctrl в первой версии
;// line discipline намеренно не нужны: shell-команды вводятся строчными ASCII.
scancode_ascii:
db 0, 0, '1','2','3','4','5','6','7','8','9','0','-','=', 8, 0
db 'q','w','e','r','t','y','u','i','o','p','[',']', 10, 0, 'a','s'
db 'd','f','g','h','j','k','l',59,39,96,0,92,'z','x','c','v'
db 'b','n','m',',','.','/',0,0,0,' ',0,0,0,0,0,0
times 64 db 0

align 8
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
