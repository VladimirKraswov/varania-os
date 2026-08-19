;//////////////////////////////////////////////////////////////////////////////
;// Высокоуровневая печать поверх VGA
;//////////////////////////////////////////////////////////////////////////////

PRINT.newline   = 10
PRINT.backspace = 8

print_x          dd 0
print_y          dd 0
print_text_color dd VGA.white
print_back_color dd VGA.black
hex_digits       db "0123456789ABCDEF"

;// Инициализировать состояние печати и очистить экран.
print_init:
  mov dword [print_x], 0
  mov dword [print_y], 0
  mov dword [print_text_color], VGA.white
  mov dword [print_back_color], VGA.black
  mov edi, VGA.white
  mov esi, VGA.black
  call vga_clear
  xor edi, edi
  xor esi, esi
  call vga_set_cursor
  ret

;// Установить цвета: EDI — текст, ESI — фон.
print_set_colors:
  mov [print_text_color], edi
  mov [print_back_color], esi
  ret

;// Перейти на следующую строку и при необходимости прокрутить экран.
print_newline:
  mov dword [print_x], 0
  inc dword [print_y]
  cmp dword [print_y], VGA.height
  jb .update_cursor

  mov edi, [print_text_color]
  mov esi, [print_back_color]
  call vga_scroll
  mov dword [print_y], VGA.height-1

  .update_cursor:
  mov edi, [print_x]
  mov esi, [print_y]
  call vga_set_cursor
  ret

;// Напечатать символ DIL. Символ одновременно уходит в debug-port 0xE9,
;// благодаря чему автоматический тест видит тот же текст, что и пользователь.
print_char:
  push rbx
  mov ebx, edi
  mov eax, ebx
  out DEBUG_PORT, al

  cmp bl, PRINT.newline
  je .newline
  cmp bl, PRINT.backspace
  je .backspace

  mov edi, ebx
  mov esi, [print_text_color]
  mov edx, [print_back_color]
  mov ecx, [print_x]
  mov r8d, [print_y]
  call vga_write_cell
  inc dword [print_x]
  cmp dword [print_x], VGA.width
  jb .cursor
  call print_newline
  jmp .done

  .backspace:
  cmp dword [print_x], 0
  je .cursor
  dec dword [print_x]
  mov edi, ' '
  mov esi, [print_text_color]
  mov edx, [print_back_color]
  mov ecx, [print_x]
  mov r8d, [print_y]
  call vga_write_cell
  jmp .cursor

  .newline:
  call print_newline
  jmp .done

  .cursor:
  mov edi, [print_x]
  mov esi, [print_y]
  call vga_set_cursor
  .done:
  pop rbx
  ret

;// Напечатать нуль-терминированную строку RDI.
print_string:
  push rbx
  mov rbx, rdi
  .loop:
    movzx edi, byte [rbx]
    test edi, edi
    jz .done
    call print_char
    inc rbx
    jmp .loop
  .done:
  pop rbx
  ret

;// Напечатать RDI как 16 шестнадцатеричных цифр с префиксом 0x.
print_hex64:
  push rbx
  push r12
  mov rbx, rdi
  mov edi, '0'
  call print_char
  mov edi, 'x'
  call print_char
  mov r12d, 16
  .digit:
    rol rbx, 4
    mov eax, ebx
    and eax, 0x0F
    lea rdx, [hex_digits]
    movzx edi, byte [rdx+rax]
    call print_char
    dec r12d
    jnz .digit
  pop r12
  pop rbx
  ret

;// Напечатать RDI как беззнаковое десятичное число.
print_udec64:
  push rbx
  push r12
  mov rax, rdi
  xor r12d, r12d
  mov ebx, 10
  test rax, rax
  jnz .divide
  mov edi, '0'
  call print_char
  jmp .done
  .divide:
    xor edx, edx
    div rbx
    add dl, '0'
    push rdx
    inc r12d
    test rax, rax
    jnz .divide
  .emit:
    pop rdi
    call print_char
    dec r12d
    jnz .emit
  .done:
  pop r12
  pop rbx
  ret
