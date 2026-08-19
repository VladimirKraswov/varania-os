;//////////////////////////////////////////////////////////////////////////////
;// Varania OS — учебное 64-битное ядро amd64
;//////////////////////////////////////////////////////////////////////////////
;
;// Загрузчик уже включил long mode, построил identity mapping 0..8 MiB и
;// отобразил физические 0x100000..0x4FFFFF в верхнюю половину, начиная с
;// KERNEL.base. Ядро выполняется по каноническим 64-битным адресам.

format Binary as "bin"

include "../const.inc"

use64
org KERNEL.base

;// Образ начинается с безусловного перехода: подключаемые ниже модули могут
;// свободно содержать и код, и статические данные.
jmp kernel_start

include "amd64/macros.inc"
include "amd64/common.inc"
include "amd64/vga.inc"
include "amd64/print.inc"
include "amd64/pic.inc"
include "amd64/pit.inc"
include "amd64/keyboard.inc"
include "amd64/pmm.inc"
include "amd64/memory.inc"
include "amd64/exceptions.inc"
include "amd64/interrupts.inc"

PROGRAM.base = 0FFFF90000000000h shl 4

kernel_banner db "Varania OS amd64", 10
              db "long mode, 4-level paging, IDT64, E820 PMM", 10, 10, 0
memory_text   db "Free physical frames: ", 0
frame_text    db "Test frame: ", 0
demo_text     db "Running a copy from a separately mapped page...", 10, 0
ready_text    db 10, "VARANIA:BOOT_OK", 10
              db "System is ready. Keyboard input: ", 0
memory_error  db "ERROR: PMM/VMM could not prepare the test page", 10, 0

align 16
kernel_start:
  cli
  cld

  ;// Сегментные базы в long mode почти не используются, но корректные
  ;// селекторы полезны для диагностики и обязательны для SS.
  mov ax, SEL.data64
  mov ds, ax
  mov es, ax
  mov ss, ax
  mov fs, ax
  mov gs, ax

  call vga_init
  call print_init
  lea rdi, [kernel_banner]
  call print_string

  ;// IDT загружается до включения любых аппаратных прерываний.
  call interrupts_init
  in al, 0x70
  and al, 0x7F                    ;// снова разрешить NMI, запрещённые загрузчиком
  out 0x70, al

  call memory_init
  lea rdi, [memory_text]
  call print_string
  mov rdi, [pmm_free_count]
  call print_udec64
  mov edi, PRINT.newline
  call print_char

  ;// Повторяем идею исходного ядра: выделяем физический кадр, отображаем его
  ;// по новому виртуальному адресу, копируем туда позиционно-независимый код
  ;// и вызываем его. Программа печатает строку через int 0x30.
  call pmm_alloc_frame
  test rax, rax
  jz kernel_memory_error
  mov r12, rax

  lea rdi, [frame_text]
  call print_string
  mov rdi, r12
  call print_hex64
  mov edi, PRINT.newline
  call print_char

  mov rdi, PROGRAM.base
  mov rsi, r12
  mov edx, PAGE.RW
  call vmm_map_page
  test rax, rax
  jz kernel_memory_error

  lea rdi, [demo_text]
  call print_string
  mov rdi, PROGRAM.base
  lea rsi, [demo_program]
  mov edx, demo_program.size
  call memory_copy
  mov rax, PROGRAM.base
  call rax

  mov edi, 100                    ;// 100 IRQ0 в секунду
  call pit_init
  call keyboard_init
  sti

  ;// Контрольное сообщение появляется только после первого IRQ0. Поэтому
  ;// smoke-тест проверяет не просто вход в ядро, а рабочие IDT, PIC и PIT.
  .wait_first_tick:
    hlt
    cmp qword [pit_ticks], 0
    je .wait_first_tick

  lea rdi, [ready_text]
  call print_string

  ;// HLT экономит ресурсы хоста: процессор просыпается только для IRQ.
  .idle:
    hlt
    jmp .idle

kernel_memory_error:
  mov edi, VGA.white
  mov esi, VGA.red
  call print_set_colors
  lea rdi, [memory_error]
  call print_string
  jmp cpu_halt_forever

;// Код тестовой «пользовательской» программы. RIP-relative адрес строки
;// остаётся правильным после копирования всего блока в PROGRAM.base.
demo_program:
  lea rsi, [.message]
  int 0x30
  ret
  .message db "Program: Hello from a mapped amd64 page!", 10, 0
demo_program.size = $-demo_program

;// IDT занимает последние 4096 байт фиксированного 64-КиБ образа.
;// Проверка не позволит коду незаметно наложиться на таблицу.
if ($-$$) > IDT.offset
  display "Kernel is too large: code overlaps IDT", 10
  err
end if

times IDT.offset-($-$$) db 0
idt_table:
times IDT.size db 0

if ($-$$) <> KERNEL.size
  display "Unexpected kernel image size", 10
  err
end if
