;//////////////////////////////////////////////////////////////////////////////
;// IDT, исключения и IRQ (системные вызовы вынесены в syscall.inc)
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

  lidt [idt_descriptor]
  call pic_init
  ret

;// Вектор без обработчика. Все реально разрешённые IRQ имеют отдельный stub.
interrupt_ignore:
  iretq

;// Генератор исключений не даёт 32 stub-ам разойтись. Если CPU не
;// кладёт error code, макрос добавляет ноль. Общий кадр всегда имеет вид
;// [vector, error, RIP, CS, RFLAGS, (RSP, SS при смене CPL)].
macro exception_stub name, vector, cpu_error
{
  name:
  if cpu_error = 0
    push 0
  end if
  push vector
  jmp exception_common
}

exception_stub exception_0,   0, 0
exception_stub exception_1,   1, 0
exception_stub exception_2,   2, 0
exception_stub exception_3,   3, 0
exception_stub exception_4,   4, 0
exception_stub exception_5,   5, 0
exception_stub exception_6,   6, 0
exception_stub exception_7,   7, 0
exception_stub exception_8,   8, 1
exception_stub exception_9,   9, 0
exception_stub exception_10, 10, 1
exception_stub exception_11, 11, 1
exception_stub exception_12, 12, 1
exception_stub exception_13, 13, 1
exception_stub exception_14, 14, 1
exception_stub exception_15, 15, 0
exception_stub exception_16, 16, 0
exception_stub exception_17, 17, 1
exception_stub exception_18, 18, 0
exception_stub exception_19, 19, 0
exception_stub exception_20, 20, 0
exception_stub exception_21, 21, 1
exception_stub exception_22, 22, 0
exception_stub exception_23, 23, 0
exception_stub exception_24, 24, 0
exception_stub exception_25, 25, 0
exception_stub exception_26, 26, 0
exception_stub exception_27, 27, 0
exception_stub exception_28, 28, 0
exception_stub exception_29, 29, 1
exception_stub exception_30, 30, 1
exception_stub exception_31, 31, 0

exception_common:
  push_all_registers
  ;// CS в аппаратном кадре точно показывает CPL, с которого пришла ошибка.
  ;// Ring-3 fault локализуем в процессе; ring-0 fault остаётся kernel panic.
  test byte [rsp+144], 3
  jz .kernel_fault
  mov rdi, [rsp+120]
  call exception_terminate_user
  mov rdi, rsp
  call scheduler_switch
  mov rsp, rax
  pop_all_registers
  iretq
  .kernel_fault:
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
  cmp byte [scheduler_is_idle], 0
  jne .resume_idle
  ;// IRQ и SYSCALL создают один формат Context. Возврат с другим RSP
  ;// означает, что IRETQ возобновит уже другую ring-3 задачу.
  mov rdi, rsp
  call scheduler_switch
  mov rsp, rax
  .resume_idle:
  pop_all_registers
  iretq

irq_1:
  push_all_registers
  mov edi, 1
  call pic_mask_irq                  ;// one-shot: драйвер повторно откроет IRQ через SYS_IRQ_WAIT
  mov edi, 1
  call device_irq_notify
  mov edi, 0x21
  call pic_send_eoi
  pop_all_registers
  iretq
