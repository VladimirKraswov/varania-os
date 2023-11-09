;//////////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rghts reserved.      //
;// Distributed under terms of the GNU General Public License    //
;// Porgram Interval Timer - Программируеиый интервальный таймер //                                             //
;// Дата: 10.10.2019                                             //
;//////////////////////////////////////////////////////////////////

pit.PORT_CHANAL_0 = 0x40 ;// Порт PIT нулевого канала
pit.PORT_CHANAL_2 = 0x41 ;// Порт PIT первого канала
pit.PORT_CHANAL_2 = 0x42 ;// Порт PIT второго канала
pit.PORT_DATA     = 0x43 ;// Порт данных PIT
pit.REPEAT        = 0x36 ;// Управляющий байт, устанавливает PIT в режим повтора

pit.tick dd 0

;// МАКРООБЕРТКИ

macro pit.init _frequency
{ 
  push eax
  int.setHandler 32, pit_timerCallbak, int.GATE_P+int.GATE_INT  ;// IRQ0 — Прерывание интервального таймера, возникает 18,2 раза в секунду.

  divisor = 1193180 / _frequency ;// Расчитываем частоту срабатывания
  ;// Устанавливаем PIT в режим повтора
  outb pit.PORT_DATA, pit.REPEAT
  ;// Устанавливаем частоту срабатывания нулевого канала таймера
  mov eax, divisor
  outb pit.PORT_CHANAL_0, al ;// Посылаем младшую часть
  outb pit.PORT_CHANAL_0, ah ;// затем старшую
  pop eax
}

;// ПРОЦЕДУРЫ

align 4
pit_timerCallbak:
  pushad
  cli
  inc [pit.tick]
  sti
  pic.eoi
  popad
  iret













