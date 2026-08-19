;//////////////////////////////////////////////////////////////////////////////
;// Varania OS — учебное 64-битное микроядро amd64
;//////////////////////////////////////////////////////////////////////////////
;
;// В ring 0 остаются только механизмы: память, планирование, IPC,
;// capabilities, прерывания и минимальный вывод для диагностики. Два
;// встроенных user-сервиса ниже доказывают работу изоляции и IPC.

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
include "amd64/task.inc"
include "amd64/ipc.inc"
include "amd64/device.inc"
include "amd64/syscall.inc"
include "amd64/exceptions.inc"
include "amd64/interrupts.inc"

kernel_banner db "Varania microkernel amd64", 10
              db "ring 3, preemptive scheduler, capabilities, IPC", 10, 10, 0
memory_text   db "Free physical frames: ", 0
start_text    db "Starting isolated user services...", 10, 0
memory_error  db "ERROR: kernel allocation or task creation failed", 10, 0

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
  call syscall_init

  ;// Каждый блоб получает свои физические страницы, PML4, user stack и
  ;// kernel stack. Из ring 3 нет ни одной прямой ссылки на ядро.
  lea rdi, [user_server]
  mov esi, user_server.size
  call task_create
  cmp rax, 0
  jl kernel_memory_error
  lea rdi, [user_client]
  mov esi, user_client.size
  call task_create
  cmp rax, 0
  jl kernel_memory_error
  lea rdi, [user_fault_probe]
  mov esi, user_fault_probe.size
  call task_create
  cmp rax, 0
  jl kernel_memory_error
  lea rdi, [user_keyboard_driver]
  mov esi, user_keyboard_driver.size
  call task_create
  cmp rax, 0
  jl kernel_memory_error

  ;// Handle 1 каждой задачи даёт CAP_SEND на другую. Глобальные PID в ABI не попадают.
  mov edi, 0
  mov esi, 1
  mov edx, CAP_SEND
  call capability_grant
  test rax, rax
  jz kernel_memory_error

  ;// Keyboard-service (task 3): handle 1 = IRQ1, handle 2 = read-only ports 0x60..0x64.
  ;// Даже этот драйвер не может обратиться к PIC, PIT или другим портам.
  mov edi, 3
  mov esi, 1
  call capability_grant_irq
  test rax, rax
  jz kernel_memory_error
  mov edi, 3
  mov esi, 0x60
  mov edx, 5
  mov ecx, CAP_READ
  call capability_grant_io
  test rax, rax
  jz kernel_memory_error
  mov edi, 1
  mov esi, 0
  mov edx, CAP_SEND
  call capability_grant
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

;// --------------------------------------------------------------------------
;// Встроенные user-space сервисы
;// --------------------------------------------------------------------------
;// Код не содержит абсолютных ссылок на ядро. RIP-relative строки остаются
;// корректными после копирования в USER.code. Это простейший прообраз будущего ELF-loader.

IPC_PING = 0x50494E47                 ;// "PING"
IPC_PONG = 0x504F4E47                 ;// "PONG"

user_server:
  mov eax, SYS_LOG
  lea rdi, [.ready]
  mov esi, .ready_size
  syscall
  mov eax, SYS_RECV
  syscall                             ;// блокируется до PING
  cmp rax, IPC_PING
  jne .failed
  mov eax, SYS_LOG
  lea rdi, [.received]
  mov esi, .received_size
  syscall
  mov eax, SYS_SEND
  mov edi, 1                          ;// capability, а не PID
  mov esi, IPC_PONG
  syscall
  .serve_next:
    mov eax, SYS_RECV               ;// нет работы — блокируемся, CPU может войти в HLT
    syscall
    jmp .serve_next
  .failed:
    mov eax, SYS_EXIT
    syscall
  .ready db "service: waiting for IPC", 10
  .ready_size = $-.ready
  .received db "service: PING received", 10
  .received_size = $-.received
user_server.size = $-user_server

user_client:
  mov eax, SYS_LOG
  lea rdi, [.started]
  mov esi, .started_size
  syscall
  mov eax, SYS_SEND
  mov edi, 1
  mov esi, IPC_PING
  syscall
  mov eax, SYS_RECV
  syscall                             ;// ответ ядро запишет в сохранённый RAX
  cmp rax, IPC_PONG
  jne .failed
  mov eax, SYS_LOG
  lea rdi, [.success]
  mov esi, .success_size
  syscall
  mov eax, SYS_EXIT
  syscall
  .failed:
    mov eax, SYS_LOG
    lea rdi, [.error]
    mov esi, .error_size
    syscall
    mov eax, SYS_EXIT
    syscall
  .started db "client: sending PING", 10
  .started_size = $-.started
  .success db "client: PONG received", 10, "VARANIA:MICROKERNEL_OK", 10
  .success_size = $-.success
  .error db "client: IPC protocol error", 10
  .error_size = $-.error
user_client.size = $-user_client

;// Третья задача намеренно выполняет UD2. Её #UD должен завершить только этот
;// процесс; IPC-сервис и клиент продолжают работу. Smoke-тест проверяет оба маркера.
user_fault_probe:
  mov eax, SYS_LOG
  lea rdi, [.message]
  mov esi, .message_size
  syscall
  ud2
  .message db "fault-probe: executing UD2", 10
  .message_size = $-.message
user_fault_probe.size = $-user_fault_probe

;// Пример драйвера в user space. В headless-тесте он блокируется без траты CPU;
;// в `make run` каждая клавиша проходит IRQ capability и ограниченное чтение порта.
user_keyboard_driver:
  mov eax, SYS_LOG
  lea rdi, [.ready]
  mov esi, .ready_size
  syscall
  .wait:
    mov eax, SYS_IRQ_WAIT
    mov edi, 1                      ;// IRQ capability
    syscall
    mov eax, SYS_IO_READ8
    mov edi, 2                      ;// I/O-port capability
    xor esi, esi                    ;// offset 0 => port 0x60
    syscall
    mov eax, SYS_LOG
    lea rdi, [.handled]
    mov esi, .handled_size
    syscall
    jmp .wait
  .ready db "keyboard-driver: waiting for IRQ1", 10
  .ready_size = $-.ready
  .handled db "keyboard-driver: IRQ1 handled", 10
  .handled_size = $-.handled
user_keyboard_driver.size = $-user_keyboard_driver

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
