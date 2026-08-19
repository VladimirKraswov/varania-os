format ELF64 executable 3
entry start
include "abi.inc"

;// User-space VGA terminal. Ядро предоставляет только MMIO mapping; раскладка
;// 80x25, scroll, line discipline и echo являются обычной политикой процесса.
SELF_EP       = 1
NAMESERVER_EP = 2
VGA_CAP       = 3
VGA_BASE      = 0x50000000
VGA_WIDTH     = 80
VGA_HEIGHT    = 25
VGA_ATTRIBUTE = 0x07
LINE_MAX      = 47               ;// весь payload IPC words[2..7]

segment readable executable
start:
  mov eax, SYS_MMIO_MAP
  mov edi, VGA_CAP
  mov esi, VGA_BASE
  syscall
  test rax, rax
  jnz .failed
  call console_clear
  lea rdi, [welcome_text]
  mov esi, welcome_text.size
  call console_write

  ;// Публикуем send-only endpoint под стабильным service ID.
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [message+IpcMessage.words+8], SERVICE_TERMINAL
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  test rax, rax
  jnz .failed
  log ready_text, ready_text.size

.serve:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz .failed
  mov rax, qword [message+IpcMessage.words]
  cmp rax, TERM_WRITE
  je .write
  cmp rax, TERM_KEY
  je .key
  cmp rax, TERM_READLINE
  je .readline
  cmp rax, TERM_CLEAR
  je .clear
  call close_received_caps
  jmp .serve

.write:
  call close_received_caps
  mov rsi, qword [message+IpcMessage.words+8]
  cmp rsi, 16
  ja .serve
  lea rdi, [message+IpcMessage.words+16]
  call console_write
  jmp .serve

.key:
  call close_received_caps
  mov dil, byte [message+IpcMessage.words+8]
  call line_key
  jmp .serve

.readline:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .bad_readline
  test qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  jz .bad_readline
  mov rdi, [pending_reply]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [pending_reply], rax
  mov qword [line_length], 0
  jmp .serve

.bad_readline:
  call close_received_caps
  jmp .serve

.clear:
  call close_received_caps
  call console_clear
  jmp .serve

.failed:
  log failed_text, failed_text.size
  exit_process 1

;// DIL=ASCII. Terminal хранит одну ожидающую READLINE capability.
line_key:
  push rbx
  mov bl, dil
  cmp qword [pending_reply], 0
  je .done
  cmp bl, 10
  je .enter
  cmp bl, 13
  je .enter
  cmp bl, 8
  je .backspace
  cmp bl, 32
  jb .done
  cmp bl, 126
  ja .done
  mov rax, [line_length]
  cmp rax, LINE_MAX
  jae .done
  mov [line_buffer+rax], bl
  inc qword [line_length]
  mov dil, bl
  call console_put
  jmp .done

.backspace:
  cmp qword [line_length], 0
  je .done
  dec qword [line_length]
  mov rax, [line_length]
  mov byte [line_buffer+rax], 0
  mov dil, 8
  call console_put
  jmp .done

.enter:
  mov dil, 10
  call console_put
  lea rdi, [reply]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov rax, [line_length]
  mov qword [reply+IpcMessage.words+8], rax
  lea rsi, [line_buffer]
  lea rdi, [reply+IpcMessage.words+16]
  mov rcx, rax
  rep movsb
  mov eax, SYS_IPC_SEND
  mov rdi, [pending_reply]
  lea rsi, [reply]
  syscall
  mov rdi, [pending_reply]
  call close_handle
  mov qword [pending_reply], 0
  mov qword [line_length], 0
  lea rdi, [line_buffer]
  mov ecx, LINE_MAX+1
  xor eax, eax
  rep stosb
.done:
  pop rbx
  ret

;// RDI=buffer, RSI=len.
console_write:
  push rbx
  push r12
  sub rsp, 8
  mov rbx, rdi
  mov r12, rsi
.next:
  test r12, r12
  jz .done
  mov dil, [rbx]
  call console_put
  inc rbx
  dec r12
  jmp .next
.done:
  add rsp, 8
  pop r12
  pop rbx
  ret

;// DIL=ASCII. Backspace стирает только текущую строку; line discipline не
;// разрешает команде переноситься, поэтому это поведение однозначно.
console_put:
  push rbx
  mov bl, dil
  cmp bl, 10
  je .newline
  cmp bl, 8
  je .backspace
  mov rax, [cursor_y]
  imul rax, VGA_WIDTH
  add rax, [cursor_x]
  shl rax, 1
  add rax, VGA_BASE
  mov [rax], bl
  mov byte [rax+1], VGA_ATTRIBUTE
  inc qword [cursor_x]
  cmp qword [cursor_x], VGA_WIDTH
  jb .done
.newline:
  mov qword [cursor_x], 0
  inc qword [cursor_y]
  cmp qword [cursor_y], VGA_HEIGHT
  jb .done
  call console_scroll
  mov qword [cursor_y], VGA_HEIGHT-1
  jmp .done
.backspace:
  cmp qword [cursor_x], 0
  je .done
  dec qword [cursor_x]
  mov rax, [cursor_y]
  imul rax, VGA_WIDTH
  add rax, [cursor_x]
  shl rax, 1
  add rax, VGA_BASE
  mov word [rax], (VGA_ATTRIBUTE shl 8)+' '
.done:
  pop rbx
  ret

console_clear:
  mov rdi, VGA_BASE
  mov ax, (VGA_ATTRIBUTE shl 8)+' '
  mov ecx, VGA_WIDTH*VGA_HEIGHT
  cld
  rep stosw
  mov qword [cursor_x], 0
  mov qword [cursor_y], 0
  ret

console_scroll:
  mov rsi, VGA_BASE+VGA_WIDTH*2
  mov rdi, VGA_BASE
  mov ecx, VGA_WIDTH*(VGA_HEIGHT-1)*2/8
  cld
  rep movsq
  mov ax, (VGA_ATTRIBUTE shl 8)+' '
  mov ecx, VGA_WIDTH
  rep stosw
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

segment readable writeable
welcome_text db "Welcome to Varania OS", 10
             db "User-space terminal, NVMe and VaraniaFS are ready.", 10
             db "Type 'help' for available commands.", 10, 10
.size = $-welcome_text
ready_text db "terminal: user-space VGA console ready", 10
.size = $-ready_text
failed_text db "terminal: fatal mapping or IPC error", 10
.size = $-failed_text
align 8
cursor_x dq 0
cursor_y dq 0
pending_reply dq 0
line_length dq 0
;// LINE_MAX и storage обязаны меняться вместе: payload IPC даёт 47 байт плюс NUL.
line_buffer rb LINE_MAX+1
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
