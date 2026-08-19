;//////////////////////////////////////////////////////////////////////////////
;// Программируемый интервальный таймер PIT 8253/8254
;//////////////////////////////////////////////////////////////////////////////

PIT.channel0 = 0x40
PIT.command  = 0x43
PIT.frequency = 1193182

pit_ticks dq 0

;// Запустить PIT с частотой EDI герц и открыть IRQ0.
pit_init:
  test edi, edi
  jnz .frequency_ok
  mov edi, 100
  .frequency_ok:
  mov eax, PIT.frequency
  xor edx, edx
  div edi
  cmp eax, 0xFFFF
  jbe .divisor_ok
  mov eax, 0xFFFF
  .divisor_ok:
  mov ecx, eax

  mov al, 00110110b              ;// канал 0, младший/старший байт, режим 3
  out PIT.command, al
  mov eax, ecx
  out PIT.channel0, al
  mov al, ah
  out PIT.channel0, al

  mov edi, 0
  call pic_unmask_irq
  ret

;// Обработчик IRQ0: пока ядру достаточно монотонного счётчика тиков.
pit_on_irq:
  inc qword [pit_ticks]
  ret
