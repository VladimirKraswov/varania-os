;//////////////////////////////////////////////////////////////////////////////
;// Драйвер текстового режима VGA 80x25
;//////////////////////////////////////////////////////////////////////////////
;
;// Одна ячейка VGA — 16 бит: младший байт содержит ASCII-символ, старший —
;// цвет фона и текста. Буфер 0xB8000 доступен через identity mapping.

VGA.width  = 80
VGA.height = 25

VGA.black         = 0
VGA.blue          = 1
VGA.green         = 2
VGA.cyan          = 3
VGA.red           = 4
VGA.magenta       = 5
VGA.brown         = 6
VGA.light_gray    = 7
VGA.dark_gray     = 8
VGA.light_blue    = 9
VGA.light_green   = 10
VGA.light_cyan    = 11
VGA.light_red     = 12
VGA.light_magenta = 13
VGA.yellow        = 14
VGA.white         = 15

vga_buffer      dq HHDM.base+0xB8000
vga_cursor_port dw 0x3D4

;// Прочитать адрес CRT-контроллера из области данных BIOS.
vga_init:
  mov rax, HHDM.base+0x463
  mov ax, [rax]
  test ax, ax
  jnz .save_port
  mov ax, 0x3D4                    ;// безопасное значение для цветного VGA
  .save_port:
  mov [vga_cursor_port], ax
  ret

;// Очистить экран.
;// EDI = цвет текста, ESI = цвет фона.
vga_clear:
  mov eax, esi
  shl eax, 4
  or eax, edi
  shl eax, 8
  or eax, ' '
  mov rdi, [vga_buffer]
  mov ecx, VGA.width*VGA.height
  cld
  rep stosw
  ret

;// Записать одну ячейку.
;// DIL = символ, SIL = цвет текста, DL = фон, ECX = x, R8D = y.
vga_write_cell:
  mov eax, r8d
  imul eax, VGA.width
  add eax, ecx
  shl eax, 1
  add rax, [vga_buffer]

  mov r9b, dl
  shl r9b, 4
  or r9b, sil
  mov [rax], dil
  mov [rax+1], r9b
  ret

;// Сдвинуть строки 1..24 на позиции 0..23 и очистить последнюю строку.
;// EDI = цвет текста, ESI = цвет фона.
vga_scroll:
  push rbx
  mov ebx, edi
  mov r10d, esi

  mov rsi, [vga_buffer]
  lea rdi, [rsi+VGA.width*2]
  xchg rsi, rdi                    ;// источник = строка 1, назначение = строка 0
  mov ecx, VGA.width*(VGA.height-1)
  cld
  rep movsw

  mov eax, r10d
  shl eax, 4
  or eax, ebx
  shl eax, 8
  or eax, ' '
  mov ecx, VGA.width
  rep stosw

  pop rbx
  ret

;// Переместить аппаратный курсор. EDI = x, ESI = y.
vga_set_cursor:
  mov eax, esi
  imul eax, VGA.width
  add eax, edi
  mov ecx, eax
  mov dx, [vga_cursor_port]
  mov al, 0x0E
  out dx, al
  inc dx
  mov al, ch
  out dx, al
  dec dx
  mov al, 0x0F
  out dx, al
  inc dx
  mov al, cl
  out dx, al
  ret
