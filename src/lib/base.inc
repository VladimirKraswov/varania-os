;//////////////////////////////////////////////////////////////////////////////
;// libvarania: базовые функции памяти и строк
;//////////////////////////////////////////////////////////////////////////////
;
;// Системная библиотека поставляется как читаемые FASM-модули. Приложение
;// включает только нужный umbrella-файл и получает статически проверяемый код
;// без скрытого ABI. Stateful API подключаются отдельно как .vlib-сервисы.

VLIB_OK            = 0
VLIB_ERR_IO        = -5
VLIB_ERR_NOT_FOUND = -2
VLIB_ERR_INVALID   = -22
VLIB_ERR_TOO_LONG  = -36
VLIB_ERR_PROTOCOL  = -93
VLIB_IPC_WOULD_BLOCK = -11

segment readable executable

;// RDI=buffer, RCX=bytes.
vlib_zero:
  xor eax, eax
  rep stosb
  ret

;// RDI=destination, RSI=source, RCX=bytes.
vlib_copy:
  rep movsb
  ret

;// RDI=NUL string, RSI=maximum including NUL. RAX=length/error.
vlib_string_length:
  xor eax, eax
.next:
  cmp rax, rsi
  jae .too_long
  cmp byte [rdi+rax], 0
  je .done
  inc rax
  jmp .next
.too_long:
  mov rax, VLIB_ERR_TOO_LONG
.done:
  ret

;// RDI=destination, RSI=source, RDX=capacity. RAX=length/error.
vlib_string_copy:
  push rbx
  xor ebx, ebx
.byte:
  cmp rbx, rdx
  jae .too_long
  mov al, [rsi+rbx]
  mov [rdi+rbx], al
  test al, al
  jz .copied
  inc rbx
  jmp .byte
.copied:
  mov rax, rbx
  pop rbx
  ret
.too_long:
  mov rax, VLIB_ERR_TOO_LONG
  pop rbx
  ret
