;//////////////////////////////////////////////////////////////////////////////
;// Общие макросы ядра amd64
;//////////////////////////////////////////////////////////////////////////////
;
;// Внутри ядра используется простое соглашение о вызовах System V AMD64:
;//   RDI, RSI, RDX, RCX, R8, R9 — первые шесть аргументов;
;//   RAX                       — возвращаемое значение;
;//   RBX, RBP, R12-R15        — сохраняет вызываемая функция.
;//
;// Ядро написано на ассемблере целиком, поэтому это соглашение не навязано
;// компилятором. Мы выбрали известный стандарт, чтобы учебный код было легче
;// читать и в будущем связывать с C или Rust.

;// Сохранить все регистры общего назначения в обработчике прерывания.
;// RSP не сохраняется отдельно: процессор и так восстанавливает его через
;// IRETQ, если произошло переключение уровня привилегий.
macro push_all_registers
{
  push rax
  push rbx
  push rcx
  push rdx
  push rbp
  push rsi
  push rdi
  push r8
  push r9
  push r10
  push r11
  push r12
  push r13
  push r14
  push r15
}

;// Восстановить регистры в порядке, обратном push_all_registers.
macro pop_all_registers
{
  pop r15
  pop r14
  pop r13
  pop r12
  pop r11
  pop r10
  pop r9
  pop r8
  pop rdi
  pop rsi
  pop rbp
  pop rdx
  pop rcx
  pop rbx
  pop rax
}

;// Описать шлюз IDT во время инициализации.
macro install_idt_gate vector, handler, ist=0, attributes=0x8E
{
  mov edi, vector
  lea rsi, [handler]
  mov dl, attributes
  mov cl, ist
  call idt_set_gate
}
