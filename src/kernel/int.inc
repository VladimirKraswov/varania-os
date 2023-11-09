;/////////////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.        //
;// Distributed under terms of the GNU General Public License       //
;// Interrupts - Менеджер прерыванний                               //
;// Krasov V.A. (FreeProger)                                        //
;// Дата: 11.10.2019                                                //
;/////////////////////////////////////////////////////////////////////

include "drivers/pic.inc" ;// Работа с контроллером прерываний 8259A

int.GATE_P    = 0x80 ;// Present
int.GATE_DPL1 = 0x20 ;// Descriptor Privilege Level - Указывает, какой уровень привилегий должен иметь вызывающий дескриптор.
int.GATE_DPL2 = 0x40
int.GATE_DPL3 = 0x60
int.GATE_S    = 0x10 ;// Storage Segment
int.GATE_CALL = 0x0C ;// (80386 32 bit) Шлюз вызова
int.GATE_TASK = 0x05 ;// (80386 32 bit) Шлюз задачи. Для переключения задач
int.GATE_INT  = 0x0E ;// (80386 32-bit) Шлюз прерывания. Используют для обслуживания аппаратных прерываний
int.GATE_TRAP = 0x0F ;// (80386 32-bit) Шлюз ловушки. Используют для обработки исключений и програмных прерываний

;// Таблица векторов прерываний
int.IDT_SIZE = 255*8        ;// Размер таблицы
int.IDT: rb int.IDT_SIZE    ;// Резервируем память под таблицу
int.IDTR:                   ;// Структура загружаемая в регистр IDTR
    .size dw int.IDT_SIZE-1 ;// Размер IDT таблицы 
    .addr dd int.IDT        ;// Адрес IDT таблицы 

;// Инициализация прерываний
macro int.init 
{
  pic.init 32, 0 ;// Инициализация контроллера прерываний 8259A
  ;// Очищаем память под IDT таблицу
  com.memset int.IDT, 0, int.IDT_SIZE
  ;// Установка заглушек для IRQ прерываний
  ;// Аппаратные прерывания (Hardware interrupts) от ведущего контроллера 8259A
  int.setHandler 32, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ0 — Прерывание интервального таймера, возникает 18,2 раза в секунду.
  int.setHandler 33, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ1 — клавиатура PS/2
  int.setHandler 34, 0, 0  ;// IRQ2 — запрос прерывания от ведомого контроллера прерываний (8259A - Slave)
  int.setHandler 35, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ3 — произвольное устройство (в IBM PC/AT — последовательный порт COM2 и COM4)
  int.setHandler 36, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ4 — произвольное устройство (в IBM PC/AT — последовательный порт COM1 и COM3)
  int.setHandler 37, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ5 — произвольное устройство (в IBM PC/AT — параллельный порт LPT2)
  int.setHandler 38, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ6 — произвольное устройство (в IBM PC/AT — контроллер гибких дисков)
  int.setHandler 39, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ7 — произвольное устройство (в IBM PC/AT — параллельный порт LPT1)
  ;// Аппаратные прерывания (Hardware interrupts) от ведомого контроллера 8259A (линии шины ISA)
  int.setHandler 40, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ8 — часы реального времени или высокоточный таймер событий №1
  int.setHandler 41, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ9 — произвольное устройство
  int.setHandler 42, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ10 — произвольное устройство
  int.setHandler 43, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ11 — произвольное устройство или высокоточный таймер событий №2
  int.setHandler 44, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ12 — произвольное устройство, обычно мышь PS/2, либо высокоточный таймер событий №3
  int.setHandler 45, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ13 — ошибка арифметического сопроцессора
  int.setHandler 46, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ14 — произвольное устройство, обычно первый контроллер ATA (или контроллер Serial ATA в режиме совместимости
  int.setHandler 47, int_EOI, int.GATE_P+int.GATE_INT  ;// IRQ15 — произвольное устройство, обычно второй контроллер ATA (или контроллер Serial ATA в режиме совместимости)                                              
  
  lidt  [int.IDTR] ;// загружаем регистр IDTR.
}

;// Отключить все прерывания
macro int.disable
{ call int_disable }

;// Включить все прерывания
macro int.enable
{ call int_enable }

macro int.setHandler _int_id, _handler, _type
{ stdcall int_setHandler, _int_id, _handler, _type }

;// Устанавливает обработчик прерывания в IDT
;// int_id  - Номер прерывания
;// handler - Адресс обработчика прерывания
;// type    - Тип прерывания
proc int_setHandler uses all_regs, _int_id: dword, _handler: addr, _type: dword
  pushfd                    ;// Сахраняем регистр флагов, в нем и разрешение на прерывания
  cli                       ;// Запрещаем аппаратные прерывания
  ;// Вычесляем адрес изменяемого дескриптора
  ;// EAX = (_int_id * 4) + int.IDTR.addr
  mov eax, [_int_id]        ;// Номер дескриптора прерывания
  shl eax, 3                ;// EAX = EAX*4
  add eax, int.IDT          ;// Добавляем к полученому адресу базу таблицы прерываний
  
  mov ebx, [_handler]       ;// Адрес обработчика
  mov ecx, [_type]          ;// Тип прерывания
  ;// Вносим изменение в дескриптор прерывания
  mov word [eax+0], bx       ;// Записываем младшую часть адреса обработчика прерывания (смещение в сегменте кода) 
  shr ebx, 16                ;// Сдвигаем старшую часть адреса в BX
  mov word [eax+6], bx       ;// Записываем старшую часть адреса
  mov word [eax+2], SEL_CODE ;// Записываем селектор сегмента в котором находится обработчик 
  mov byte [eax+4], 0        ;// Пустой. Если это шлюз вызова то младшие 5 бит это количество параметров, старшие 3 бита = 0
  mov byte [eax+5], cl       ;// Установка параметров шлюза прерывания
  popfd                      ;// Востанавливаем разрешение на прерывание
  ret
endp

;// Отключить все прерывания
proc int_disable uses eax
  cli ;// Запретить аппаратные прерывания
  ;// запрет NMI
  in   al, 0x70
  or   al, 0x80
  out  0x70, al
  ret
endp

;// Включить все прерывания
proc int_enable uses eax
  ;// разрешаем прерывания NMI
  in  al, 0x70
  and al, 0x7F
  out 0x70, al 
  sti ;// Разрешить аппаратные прерывания
  ret
endp

;// Пустой обработчик. сбрасывает заявку в контроллере (End Of Interrupt)
proc int_EOI
  pic.eoi ;// Конец прерывания
  iret
endp










                