;//////////////////////////////////////////////////////////////////////////////
;// Контроллер прерываний 8259A (PIC)
;//////////////////////////////////////////////////////////////////////////////

PIC.master_command = 0x20
PIC.master_data    = 0x21
PIC.slave_command  = 0xA0
PIC.slave_data     = 0xA1
PIC.eoi            = 0x20
PIC.master_offset  = 0x20
PIC.slave_offset   = 0x28

;// Перенести аппаратные IRQ из конфликтующего диапазона 0x08..0x0F в
;// 0x20..0x2F. После инициализации все линии замаскированы.
pic_init:
  mov al, 0x11
  out PIC.master_command, al
  call io_wait
  out PIC.slave_command, al
  call io_wait

  mov al, PIC.master_offset
  out PIC.master_data, al
  call io_wait
  mov al, PIC.slave_offset
  out PIC.slave_data, al
  call io_wait

  mov al, 0x04                    ;// ведомый PIC подключён к IRQ2 ведущего
  out PIC.master_data, al
  call io_wait
  mov al, 0x02                    ;// каскадный номер ведомого PIC
  out PIC.slave_data, al
  call io_wait

  mov al, 0x01                    ;// режим 8086
  out PIC.master_data, al
  call io_wait
  out PIC.slave_data, al
  call io_wait

  mov al, 0xFF                    ;// разрешаем только нужные драйверам IRQ
  out PIC.master_data, al
  out PIC.slave_data, al
  ret

;// Размаскировать IRQ с номером EDI (0..15).
pic_unmask_irq:
  mov ecx, edi
  cmp ecx, 8
  jb .master
  sub ecx, 8
  in al, PIC.slave_data
  mov ah, 1
  shl ah, cl
  not ah
  and al, ah
  out PIC.slave_data, al

  ;// Для ведомого PIC обязательно открыть каскадную линию IRQ2 ведущего.
  in al, PIC.master_data
  and al, 11111011b
  out PIC.master_data, al
  ret
  .master:
  in al, PIC.master_data
  mov ah, 1
  shl ah, cl
  not ah
  and al, ah
  out PIC.master_data, al
  ret

;// Сообщить PIC о завершении обработки вектора EDI.
pic_send_eoi:
  cmp edi, PIC.slave_offset
  jb .master_only
  mov al, PIC.eoi
  out PIC.slave_command, al
  .master_only:
  mov al, PIC.eoi
  out PIC.master_command, al
  ret
