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
KEY_QUEUE_SIZE = 64              ;// степень двойки для дешёвого кольцевого буфера

segment readable executable
start:
  mov eax, SYS_MMIO_MAP
  mov edi, VGA_CAP
  mov esi, VGA_BASE
  syscall
  test rax, rax
  jnz .failed
  ;// Ctrl+C должен работать даже когда shell ждёт чужой процесс. Sessiond
  ;// запускается раньше terminal и владеет только CONTROL foreground-задачи.
  call lookup_session
  test rax, rax
  js .failed
  mov [session_endpoint], rax
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
  cmp rax, TERM_READKEY
  je .readkey
  cmp rax, TERM_DRAW
  je .draw
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
  mov rdi, qword [message+IpcMessage.words+8]
  call dispatch_key
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
  mov qword [pending_mode], 1
  mov qword [line_length], 0
  call drain_queued_keys
  jmp .serve

.bad_readline:
  call close_received_caps
  jmp .serve

.clear:
  call close_received_caps
  call console_clear
  jmp .serve

.readkey:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .bad_readline
  test qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  jz .bad_readline
  mov rdi, [pending_reply]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [pending_reply], rax
  mov qword [pending_mode], 2
  call drain_queued_keys
  jmp .serve

;// Абсолютный вывод уже подготовленных VGA cells. В words[1] упакованы
;// x:y:count (по 8 бит), words[2..7] содержат до 24 пар character/attribute.
;// Terminal проверяет границы и остаётся единственным владельцем VGA MMIO.
.draw:
  call close_received_caps
  mov rax, qword [message+IpcMessage.words+8]
  movzx ebx, al                   ;// x
  shr rax, 8
  movzx ecx, al                   ;// y
  shr rax, 8
  movzx edx, al                   ;// cells
  cmp ebx, VGA_WIDTH
  jae .serve
  cmp ecx, VGA_HEIGHT
  jae .serve
  test edx, edx
  jz .serve
  cmp edx, 24
  ja .serve
  mov eax, ebx
  add eax, edx
  cmp eax, VGA_WIDTH
  ja .serve
  imul ecx, VGA_WIDTH
  add ecx, ebx
  lea rdi, [VGA_BASE+rcx*2]
  lea rsi, [message+IpcMessage.words+16]
  mov ecx, edx
  rep movsw
  jmp .serve

.failed:
  log failed_text, failed_text.size
  exit_process 1

;// RDI=key event. Raw-клиент получает событие целиком; line discipline
;// использует младший ASCII-байт и тем самым остаётся совместимым с shell.
dispatch_key:
  push rbx
  mov rbx, rdi
  mov eax, ebx
  or al, 32
  cmp al, 'c'
  jne .route
  mov rax, rbx
  shr rax, 32
  test al, 2                     ;// KEY_MOD_CTRL >> 32
  jz .route
  cmp qword [pending_mode], 1
  jne .interrupt_foreground
  cmp qword [pending_reply], 0
  je .interrupt_foreground
  ;// В prompt Ctrl+C отменяет текущую строку, а не foreground process.
  call cancel_readline
  jmp .done
.interrupt_foreground:
  call notify_interrupt
  jmp .done
.route:
  mov rdi, rbx
  cmp qword [pending_reply], 0
  jne .have_waiter
  ;// Клиент может рисовать или обрабатывать предыдущую клавишу и ещё не
  ;// успеть выставить READKEY. Сохраняем событие, а не теряем его.
  call key_queue_push
  jmp .done
.have_waiter:
  cmp qword [pending_mode], 2
  je .raw
  mov bl, dil
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

.raw:
  mov rbx, rdi
  lea rdi, [reply]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rbx
  mov eax, SYS_IPC_SEND
  mov rdi, [pending_reply]
  lea rsi, [reply]
  syscall
  mov rdi, [pending_reply]
  call close_handle
  mov qword [pending_reply], 0
  mov qword [pending_mode], 0
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
  mov qword [pending_mode], 0
  mov qword [line_length], 0
  lea rdi, [line_buffer]
  mov ecx, LINE_MAX+1
  xor eax, eax
  rep stosb
.done:
  pop rbx
  ret

;// Отменить ввод shell и вернуть пустую строку, чтобы он показал новый prompt.
cancel_readline:
  lea rdi, [interrupt_echo]
  mov esi, interrupt_echo.size
  call console_write
  lea rdi, [reply]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov eax, SYS_IPC_SEND
  mov rdi, [pending_reply]
  lea rsi, [reply]
  syscall
  mov rdi, [pending_reply]
  call close_handle
  mov qword [pending_reply], 0
  mov qword [pending_mode], 0
  mov qword [line_length], 0
  lea rdi, [line_buffer]
  mov ecx, LINE_MAX+1
  xor eax, eax
  rep stosb
  ret

;// Fire-and-forget достаточно: sessiond уже хранит CONTROL capability, а
;// shell будет разбужен самим SYS_PROCESS_KILL через обычный WAIT status.
notify_interrupt:
  lea rdi, [control_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [control_message+IpcMessage.words], SESSION_INTERRUPT
.retry:
  mov eax, SYS_IPC_SEND
  mov rdi, [session_endpoint]
  lea rsi, [control_message]
  syscall
  cmp rax, -11
  jne .done
  system_call SYS_YIELD
  jmp .retry
.done:
  ret

;// Найти sessiond до публикации terminal. В этот момент другие клиенты ещё не
;// используют SELF_EP, поэтому синхронный bootstrap lookup однозначен.
lookup_session:
.retry:
  lea rdi, [control_message]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [control_message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [control_message+IpcMessage.words+8], SERVICE_SESSION
  mov qword [control_message+IpcMessage.words+16], 1
  mov qword [control_message+IpcMessage.cap_count], 1
  mov qword [control_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [control_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, control_message
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, control_reply
  test rax, rax
  jnz .done
  cmp qword [control_reply+IpcMessage.words], 0
  je .found
  system_call SYS_YIELD
  jmp .retry
.found:
  cmp qword [control_reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [control_reply+IpcMessage.caps+IpcCap.handle]
  ret
.invalid:
  mov rax, -22
.done:
  ret

;// RDI=key event. При переполнении отбрасывается самое старое событие:
;// свежий Ctrl+Q/F10 важнее давно накопленного autorepeat.
key_queue_push:
  mov rax, [key_queue_count]
  cmp rax, KEY_QUEUE_SIZE
  jb .space
  mov rax, [key_queue_head]
  inc rax
  and eax, KEY_QUEUE_SIZE-1
  mov [key_queue_head], rax
  dec qword [key_queue_count]
.space:
  mov rax, [key_queue_tail]
  mov [key_queue+rax*8], rdi
  inc rax
  and eax, KEY_QUEUE_SIZE-1
  mov [key_queue_tail], rax
  inc qword [key_queue_count]
  ret

;// После регистрации READKEY/READLINE доставить накопленные события. Raw
;// waiter закрывается после одного key; line discipline может принять пачку
;// вплоть до Enter. Остаток остаётся для следующего запроса.
drain_queued_keys:
.next:
  cmp qword [pending_reply], 0
  je .done
  cmp qword [key_queue_count], 0
  je .done
  mov rax, [key_queue_head]
  mov rdi, [key_queue+rax*8]
  inc rax
  and eax, KEY_QUEUE_SIZE-1
  mov [key_queue_head], rax
  dec qword [key_queue_count]
  call dispatch_key
  jmp .next
.done:
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
interrupt_echo db "^C", 10
.size = $-interrupt_echo
align 8
cursor_x dq 0
cursor_y dq 0
session_endpoint dq 0
pending_reply dq 0
pending_mode dq 0               ;// 1=READLINE, 2=READKEY
line_length dq 0
key_queue_head dq 0
key_queue_tail dq 0
key_queue_count dq 0
key_queue rq KEY_QUEUE_SIZE
;// LINE_MAX и storage обязаны меняться вместе: payload IPC даёт 47 байт плюс NUL.
line_buffer rb LINE_MAX+1
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
control_message rb IpcMessage.bytes
control_reply rb IpcMessage.bytes
