;//////////////////////////////////////////////////////////////////////////////
;// IDT, исключения, IRQ и учебный системный вызов int 0x30
;//////////////////////////////////////////////////////////////////////////////

idt_descriptor:
  dw IDT.size-1
  dq IDT.base

;// Записать один 16-байтовый interrupt gate.
;// EDI=вектор, RSI=обработчик, DL=атрибуты, CL=номер IST (0..7).
idt_set_gate:
  push rbx
  lea rax, [idt_table]
  mov ebx, edi
  shl rbx, 4
  add rax, rbx

  mov word [rax], si               ;// offset[15:0]
  mov word [rax+2], SEL.code64
  and cl, 7
  mov byte [rax+4], cl
  mov byte [rax+5], dl
  mov rbx, rsi
  shr rbx, 16
  mov word [rax+6], bx             ;// offset[31:16]
  shr rbx, 16
  mov dword [rax+8], ebx           ;// offset[63:32]
  mov dword [rax+12], 0
  pop rbx
  ret

;// Построить IDT в памяти, настроить PIC и загрузить IDTR.
interrupts_init:
  lea rdi, [idt_table]
  xor eax, eax
  mov ecx, IDT.size/8
  cld
  rep stosq

  ;// Сначала безопасный обработчик для всех 256 векторов.
  xor r12d, r12d
  .default_gate:
    mov edi, r12d
    lea rsi, [interrupt_ignore]
    mov dl, 0x8E
    xor ecx, ecx
    call idt_set_gate
    inc r12d
    cmp r12d, 256
    jb .default_gate

  install_idt_gate 0,  exception_0
  install_idt_gate 1,  exception_1
  install_idt_gate 2,  exception_2
  install_idt_gate 3,  exception_3
  install_idt_gate 4,  exception_4
  install_idt_gate 5,  exception_5
  install_idt_gate 6,  exception_6
  install_idt_gate 7,  exception_7
  install_idt_gate 8,  exception_8, 1     ;// #DF получает отдельный стек IST1
  install_idt_gate 9,  exception_9
  install_idt_gate 10, exception_10
  install_idt_gate 11, exception_11
  install_idt_gate 12, exception_12
  install_idt_gate 13, exception_13
  install_idt_gate 14, exception_14
  install_idt_gate 15, exception_15
  install_idt_gate 16, exception_16
  install_idt_gate 17, exception_17
  install_idt_gate 18, exception_18
  install_idt_gate 19, exception_19
  install_idt_gate 20, exception_20
  install_idt_gate 21, exception_21
  install_idt_gate 22, exception_22
  install_idt_gate 23, exception_23
  install_idt_gate 24, exception_24
  install_idt_gate 25, exception_25
  install_idt_gate 26, exception_26
  install_idt_gate 27, exception_27
  install_idt_gate 28, exception_28
  install_idt_gate 29, exception_29
  install_idt_gate 30, exception_30
  install_idt_gate 31, exception_31

  install_idt_gate 0x20, irq_0
  install_idt_gate 0x21, irq_1
  install_idt_gate 0x30, syscall_0x30, 0, 0xEE ;// доступен из ring 3

  lidt [idt_descriptor]
  call pic_init
  ret

;// Вектор без обработчика. Все реально разрешённые IRQ имеют отдельный stub.
interrupt_ignore:
  iretq

;// Исключения без кода ошибки кладут синтетический ноль, чтобы общий кадр
;// всегда имел вид [vector, error, RIP, CS, RFLAGS].
exception_0:  push 0; push 0;  jmp exception_common
exception_1:  push 0; push 1;  jmp exception_common
exception_2:  push 0; push 2;  jmp exception_common
exception_3:  push 0; push 3;  jmp exception_common
exception_4:  push 0; push 4;  jmp exception_common
exception_5:  push 0; push 5;  jmp exception_common
exception_6:  push 0; push 6;  jmp exception_common
exception_7:  push 0; push 7;  jmp exception_common
exception_8:          push 8;  jmp exception_common ;// CPU уже положил error
exception_9:  push 0; push 9;  jmp exception_common
exception_10:         push 10; jmp exception_common
exception_11:         push 11; jmp exception_common
exception_12:         push 12; jmp exception_common
exception_13:         push 13; jmp exception_common
exception_14:         push 14; jmp exception_common
exception_15: push 0; push 15; jmp exception_common
exception_16: push 0; push 16; jmp exception_common
exception_17:         push 17; jmp exception_common
exception_18: push 0; push 18; jmp exception_common
exception_19: push 0; push 19; jmp exception_common
exception_20: push 0; push 20; jmp exception_common
exception_21:         push 21; jmp exception_common
exception_22: push 0; push 22; jmp exception_common
exception_23: push 0; push 23; jmp exception_common
exception_24: push 0; push 24; jmp exception_common
exception_25: push 0; push 25; jmp exception_common
exception_26: push 0; push 26; jmp exception_common
exception_27: push 0; push 27; jmp exception_common
exception_28: push 0; push 28; jmp exception_common
exception_29:         push 29; jmp exception_common
exception_30:         push 30; jmp exception_common
exception_31: push 0; push 31; jmp exception_common

exception_common:
  push_all_registers
  mov rdi, [rsp+120]               ;// номер вектора
  mov rsi, [rsp+128]               ;// настоящий или синтетический error code
  mov rdx, [rsp+136]               ;// RIP, сохранённый процессором
  call exception_dispatch
  ;// exception_dispatch не возвращается; код ниже оставлен как документация
  ;// корректного восстановления кадра, если появятся возобновляемые ошибки.
  pop_all_registers
  add rsp, 16
  iretq

irq_0:
  push_all_registers
  call pit_on_irq
  mov edi, 0x20
  call pic_send_eoi
  pop_all_registers
  iretq

irq_1:
  push_all_registers
  call keyboard_on_irq
  mov edi, 0x21
  call pic_send_eoi
  pop_all_registers
  iretq

;// Учебный системный вызов: RSI указывает на строку, как в исходной Varania.
;// Пока пользовательского режима нет, но DPL=3 уже позволяет сохранить ABI
;// при его добавлении. Все регистры вызывающего кода восстанавливаются.
syscall_0x30:
  push_all_registers
  mov rdi, [rsp+72]                 ;// сохранённое значение RSI
  call print_string
  pop_all_registers
  iretq
