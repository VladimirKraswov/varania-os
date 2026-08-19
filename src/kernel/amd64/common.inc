;//////////////////////////////////////////////////////////////////////////////
;// Базовые функции amd64: порты, память и диагностический вывод
;//////////////////////////////////////////////////////////////////////////////

DEBUG_PORT = 0xE9 ;// QEMU/Bochs debug console; на обычном ПК запись безвредна

;// Записать символ из DIL в диагностический порт эмулятора.
debug_put_char:
  mov eax, edi
  out DEBUG_PORT, al
  ret

;// Напечатать нуль-терминированную строку RDI в диагностический порт.
debug_put_string:
  push rbx
  mov rbx, rdi
  .loop:
    mov al, [rbx]
    test al, al
    jz .done
    out DEBUG_PORT, al
    inc rbx
    jmp .loop
  .done:
  pop rbx
  ret

;// Копировать RDX байт из RSI в RDI. Области не должны пересекаться.
;// Возвращает исходный адрес назначения в RAX.
memory_copy:
  mov rax, rdi
  mov rcx, rdx
  cld
  rep movsb
  ret

;// Заполнить RDX байт по адресу RDI младшим байтом RSI.
;// Возвращает исходный адрес назначения в RAX.
memory_set:
  mov r8, rdi
  mov rax, rsi
  mov rcx, rdx
  cld
  rep stosb
  mov rax, r8
  ret

;// Вычислить длину строки RDI без завершающего нуля.
string_length:
  xor eax, eax
  .loop:
    cmp byte [rdi+rax], 0
    je .done
    inc rax
    jmp .loop
  .done:
  ret

;// Небольшая задержка для старых устройств ввода-вывода.
io_wait:
  mov al, 0
  out 0x80, al
  ret

;// Остановить процессор. CLI исключает случайное пробуждение IRQ.
cpu_halt_forever:
  cli
  .halt:
    hlt
    jmp .halt
