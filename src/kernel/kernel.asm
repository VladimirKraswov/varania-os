;//////////////////////////////////////////////////////////////////////////////
;// Varania OS — учебное 64-битное микроядро amd64
;//////////////////////////////////////////////////////////////////////////////
;
;// В ring 0 остаются только механизмы: память, планирование, IPC,
;// capabilities, прерывания и минимальный вывод для диагностики. Все обычные
;// программы, включая init и драйвер клавиатуры, загружаются как ELF64.

format Binary as "bin"

include "../const.inc"

use64
org KERNEL.base

;// Образ начинается с перехода: подключаемые модули могут содержать данные.
jmp kernel_start

include "amd64/macros.inc"
include "amd64/common.inc"
include "amd64/vga.inc"
include "amd64/print.inc"
include "amd64/pic.inc"
include "amd64/pit.inc"
include "amd64/keyboard.inc"        ;// сохранён как bootstrap-драйвер, но не включён
include "amd64/pmm.inc"
include "amd64/memory.inc"
include "amd64/slab.inc"
include "amd64/objects.inc"
include "amd64/initramfs.inc"
include "amd64/task.inc"
include "amd64/elf.inc"
include "amd64/ipc.inc"
include "amd64/device.inc"
include "amd64/syscall.inc"
include "amd64/exceptions.inc"
include "amd64/interrupts.inc"

kernel_banner db "Varania microkernel amd64", 10
              db "ELF64, dynamic processes, capabilities, queued IPC", 10, 10, 0
memory_text   db "Free physical frames: ", 0
start_text    db "Starting user/procd with read-only bootfs...", 10, 0
memory_error  db "ERROR: initramfs, allocation or init creation failed", 10, 0

align 16
kernel_start:
  cli
  cld

  mov ax, SEL.data64
  mov ds, ax
  mov es, ax
  mov ss, ax
  mov fs, ax
  mov gs, ax

  ;// Загрузчику был нужен физический адрес GDT. Перед первой сменой CR3
  ;// перезагружаем GDTR её постоянным HHDM-адресом.
  lgdt [gdt64_descriptor_high]

  call vga_init
  call print_init
  lea rdi, [kernel_banner]
  call print_string

  call interrupts_init
  in al, 0x70
  and al, 0x7F                    ;// снова разрешить NMI, запрещённые загрузчиком
  out 0x70, al

  call memory_init
  ;// Маленький self-test проходит и путь роста slab-а, и возврат объекта.
  mov edi, 80
  call kmalloc
  test rax, rax
  jz kernel_memory_error
  mov rdi, rax
  mov qword [rdi], 0x56415241       ;// "VARA" — запись в полезную область
  call kfree
  test rax, rax
  jz kernel_memory_error
  lea rdi, [memory_text]
  call print_string
  mov rdi, [pmm_free_count]
  call print_udec64
  mov edi, PRINT.newline
  call print_char
  call initramfs_init
  test rax, rax
  jz kernel_memory_error
  call syscall_init                 ;// SCE и NXE включаются до user mappings
  call task_create_init
  test rax, rax
  jz kernel_memory_error

  lea rdi, [start_text]
  call print_string
  mov edi, 100                    ;// квант 10 ms
  call pit_init
  jmp scheduler_start

kernel_memory_error:
  mov edi, VGA.white
  mov esi, VGA.red
  call print_set_colors
  lea rdi, [memory_error]
  call print_string
  jmp cpu_halt_forever

;// IDT занимает последние 4096 байт фиксированного 64-KiB образа.
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
