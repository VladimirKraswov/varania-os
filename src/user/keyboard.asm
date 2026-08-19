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
  movzx ebx, al
  cmp bl, 0xE0
  jne .have_scan
  mov byte [extended_prefix], 1
  jmp .wait
.have_scan:
  mov r13b, [extended_prefix]
  mov byte [extended_prefix], 0
  mov r14b, bl
  and ebx, 0x7F                   ;// make/release имеют общий base code

  ;// Модификаторы меняют состояние и сами не отправляются как текст.
  cmp bl, 0x2A
  je .shift
  cmp bl, 0x36
  je .shift
  cmp bl, 0x1D
  je .control
  cmp bl, 0x38
  je .alt
  cmp bl, 0x3A
  je .caps
  test r14b, 0x80                 ;// release остальных клавиш
  jnz .wait

  log handled_text, handled_text.size
  test r13b, r13b
  jnz .extended_key
  cmp bl, 0x3B
  jb .ascii_key
  cmp bl, 0x44
  ja .ascii_key
  mov eax, KEY_F1-0x3B
  add eax, ebx
  jmp .with_modifiers

.extended_key:
  cmp bl, 0x48
  je .up
  cmp bl, 0x50
  je .down
  cmp bl, 0x4B
  je .left
  cmp bl, 0x4D
  je .right
  cmp bl, 0x47
  je .home
  cmp bl, 0x4F
  je .end
  cmp bl, 0x53
  je .delete
  cmp bl, 0x49
  je .page_up
  cmp bl, 0x51
  je .page_down
  cmp bl, 0x52
  je .insert
  cmp bl, 0x1C                    ;// Enter на цифровой клавиатуре
  je .enter
  jmp .wait
.up:       mov eax, KEY_UP
  jmp .with_modifiers
.down:     mov eax, KEY_DOWN
  jmp .with_modifiers
.left:     mov eax, KEY_LEFT
  jmp .with_modifiers
.right:    mov eax, KEY_RIGHT
  jmp .with_modifiers
.home:     mov eax, KEY_HOME
  jmp .with_modifiers
.end:      mov eax, KEY_END
  jmp .with_modifiers
.delete:   mov eax, KEY_DELETE
  jmp .with_modifiers
.page_up:  mov eax, KEY_PAGE_UP
  jmp .with_modifiers
.page_down: mov eax, KEY_PAGE_DOWN
  jmp .with_modifiers
.insert:   mov eax, KEY_INSERT
  jmp .with_modifiers
.enter:    mov eax, 10
  jmp .with_modifiers

.ascii_key:
  cmp ebx, 127
  ja .wait
  mov rdx, [modifiers]
  bt rdx, 32
  jnc .normal_table
  movzx eax, byte [scancode_shifted+rbx]
  jmp .caps_adjust
.normal_table:
  movzx eax, byte [scancode_ascii+rbx]
.caps_adjust:
  test al, al
  jz .wait
  ;// CapsLock действует только на буквы и складывается с Shift через XOR.
  cmp al, 'a'
  jb .upper_case
  cmp al, 'z'
  ja .upper_case
  cmp byte [caps_lock], 0
  je .with_modifiers
  sub al, 32
  jmp .with_modifiers
.upper_case:
  cmp al, 'A'
  jb .with_modifiers
  cmp al, 'Z'
  ja .with_modifiers
  cmp byte [caps_lock], 0
  je .with_modifiers
  add al, 32

.with_modifiers:
  mov rdx, [modifiers]
  or rax, rdx
  mov qword [message+IpcMessage.words], TERM_KEY
  mov qword [message+IpcMessage.words+8], rax
  mov qword [message+IpcMessage.cap_count], 0
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  lea rsi, [message]
  syscall
  test rax, rax
  jnz .failed
  jmp .wait

.shift:
  mov rax, KEY_MOD_SHIFT
  jmp .set_modifier
.control:
  mov rax, KEY_MOD_CTRL
  jmp .set_modifier
.alt:
  mov rax, KEY_MOD_ALT
.set_modifier:
  test r14b, 0x80
  jnz .clear_modifier
  or [modifiers], rax
  jmp .wait
.clear_modifier:
  not rax
  and [modifiers], rax
  jmp .wait
.caps:
  test r14b, 0x80
  jnz .wait
  xor byte [caps_lock], 1
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

;// Две таблицы делают US-раскладку явной и легко заменяемой. Состояние Shift,
;// Ctrl, Alt и CapsLock хранится драйвером, terminal получает готовое событие.
scancode_ascii:
db 0, 27, '1','2','3','4','5','6','7','8','9','0','-','=', 8, 9
db 'q','w','e','r','t','y','u','i','o','p','[',']', 10, 0, 'a','s'
db 'd','f','g','h','j','k','l',59,39,96,0,92,'z','x','c','v'
db 'b','n','m',',','.','/',0,0,0,' ',0,0,0,0,0,0
times 128-($-scancode_ascii) db 0

scancode_shifted:
db 0, 27, '!','@','#','$','%','^','&','*','(',')','_','+', 8, 9
db 'Q','W','E','R','T','Y','U','I','O','P','{','}', 10, 0, 'A','S'
db 'D','F','G','H','J','K','L',':',34,'~',0,'|','Z','X','C','V'
db 'B','N','M','<','>','?',0,0,0,' ',0,0,0,0,0,0
times 128-($-scancode_shifted) db 0

align 8
modifiers dq 0
extended_prefix db 0
caps_lock db 0
align 8
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
