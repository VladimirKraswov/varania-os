;////////////////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.           //
;// Distributed under terms of the GNU General Public License          //
;// Program Interrup Controller - Драйвер контроллера прерываний 8259A //
;// Дата: 30.07.2019                                                   //
;////////////////////////////////////////////////////////////////////////

pic.PORT_20 equ 20h  ;// Master PIC — Command
pic.PORT_21 equ 21h  ;// Master PIC — Data
pic.PORT_A0 equ 0A0h ;// Slave PIC — Command 
pic.PORT_A1 equ 0A1h ;// Slave PIC — Data

pic.EOI  = 20h       ;// команда (End Of Interrupt). сбрасывает бит в регистре ISR 

;// Вход:
;// _base - Базовый номер IRQ прерываний
;// _mask - Маска прерываний IRQ0 - IRQ15
macro pic.init _base, _mask
{ 
  mov eax, _mask
  ;// Перепрограммирование ведущего (Master) контроллера
  outb pic.PORT_20, 11h     ;// Два контроллера
  outb pic.PORT_21, _base   ;// База для IRQ 0..7
  outb pic.PORT_21, 4       ;// Ведомый контроллер подсоеденен к входу 2
  outb pic.PORT_21, 1       ;// Требуется программная генерация EOI
  outb pic.PORT_21, al      ;// Маска прерываний для IRQ 0..7
  ;// Перепрограммирование ведомого (Slave) контроллера
  outb pic.PORT_A0, 11h     ;// Два контроллера
  outb pic.PORT_A1, _base+8 ;// База для IRQ 8..15
  outb pic.PORT_A1, 2       ;// Ведущий контроллер подключен к выходу 3
  outb pic.PORT_A1, 1       ;// Требуется программная генерация EOI
  outb pic.PORT_A1, ah      ;// Маска прерываний для IRQ 8..15
}

;// Очистка регистров обслуживания прерывания ISR. Сбрасывает заявку в обоих контроллерах
macro pic.eoi
{
  ;// Сброс заявки в контроллере прерываний: посылка End-Of-Interrupt (EOI)
  outb pic.PORT_20, pic.EOI ;// ... в ведущий (Master) контроллер ...
  outb pic.PORT_A0, pic.EOI ;// ... и в ведомый (Slave) контроллер.
}
 

















