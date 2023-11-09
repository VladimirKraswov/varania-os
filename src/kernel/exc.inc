;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// Exception handler - Обработчики исключений                //
;// Дата: 05.08.2019                                          //
;///////////////////////////////////////////////////////////////

;// Инициализация IDT
;// Ловушка - iret возвращает на следующую команду
;// Нарушение - iret возвращает на эту же команду
;// Авария - требует перезагрузки

pt.resetStr db "RESET SYSTEM!", 0

macro exc.init
{
  INT_TYPE = int.GATE_P+int.GATE_TRAP
  ;// Обработчики исключений (нарушений, ловушек и аварий)
  int.setHandler 0,  exc_0,  INT_TYPE       ;// #DE Нарушение. Ошибка деления, код ошибки-нет. Вызвано: div, idiv
  int.setHandler 1,  exc_1,  INT_TYPE       ;// #DB Нарушение/Ловешка. Исключение отладки. Код ошибки-нет.
  int.setHandler 2,  exc_2,  INT_TYPE       ;// Немаскируемые прерывания поступающие на порт NMI. (Аппаратный сбой)
  int.setHandler 3,  exc_3,  INT_TYPE       ;// #BP Ловушка. Программное прерывание служащее для отладки. Вызвано: int 3
  int.setHandler 4,  exc_4,  INT_TYPE       ;// #OF Ловушка. Фиксирует арефметическое переполнение(overflow). Код ошибки-нет. Вызвано: into
  int.setHandler 5,  exc_5,  INT_TYPE       ;// #BR Нарушение. Нарушение границ массива. Код ошибки-нет. Вызвано: bound
  int.setHandler 6,  exc_6,  INT_TYPE       ;// #UD Нарушение. Недопустимый код команды. Код ошибки-нет.
  int.setHandler 7,  exc_7,  INT_TYPE       ;// #NM Нарушение. Сопроцессор не доступен. Код ошибки-нет. Вызвано: esc, wait
  int.setHandler 8,  exc_8,  INT_TYPE       ;// #DF Авария. Двойное нарушение. Код ошибки-да
  int.setHandler 9,  exc_9,  INT_TYPE       ;// Авария. Выход сопроцессора из сегмента. Код ошибки-нет
  int.setHandler 10, exc_10, INT_TYPE       ;// #TS Нарушение. Недопуст. сегмент состояния задачи TSS. Ошибка-да. Выз. jmp, call, iret, прерывание
  int.setHandler 11, exc_11, INT_TYPE       ;// #NP Нарушение. Отсутствие сегмента. Ошибка-да. Выз. команда загрузки сегмент. регистра
  int.setHandler 12, exc_12, INT_TYPE       ;// #SS Нарушение. Ошибка обращения к стеку. Код ошибки-да. Вызвано: командой обращения к стеку
  int.setHandler 13, exc_13, INT_TYPE       ;// #GP Нарушение. Общая защита. Код ошибки-да. Вызвано: команда обращения к памяти
  int.setHandler 14, exc_14, INT_TYPE       ;// #PF Нарушение. Страничное нарушение. Код ошибки-да. Вызвано: команда обращения к памяти
  int.setHandler 15, exc_15, INT_TYPE       ;// Не используется
  int.setHandler 16, exc_16, INT_TYPE       ;// #MF Нарушение. Сопроцессор не доступен. Код ошибки-нет. Вызвано: esc, wait
  int.setHandler 17, exc_17, INT_TYPE       ;// #AC Нарушение. Ошибка выравнивания. Код ошибки-да. Вызвано: команда обращения к памяти
}

exc_0:  ;// Нарушение. Ошибка деления, код ошибки-нет. Вызвано: div, idiv
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 0,  Fault. #DE - Divide Error Exception. Induced (div, idiv). Induced (div, idiv).", pt.END_LN
  pt.print 'm', pt.resetStr
  com.stop

exc_1:  ;// Нарушение/Ловушка. Исключение отладки. Код ошибки-нет.
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 1,  Fault/Trap. #DB - Debug Exception.", pt.END_LN
  pt.print 'm', pt.resetStr 
  com.stop

exc_2:  ;// Немаскируемые прерывания поступающие на порт NMI. (Аппаратный сбой)
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 2,  Interrupt. Hardware failure. Induced (Hardware failure).", pt.END_LN 
  pt.print 'm', pt.resetStr 
  com.stop

exc_3:  ;// Ловушка. Программное прерывание служащее для отладки. Вызвано: int 3
  pt.clear pt.RED, pt.WHITE
  pt.print 's',  "exc - 3,  Trap. #BP - Breakpoint Exception. Induced (int 3).", pt.END_LN 
  iret
  
exc_4:  ;// Ловушка. Фиксирует арефметическое переполнение(overflow). Код ошибки-нет. Вызвано: into
  pt.clear pt.RED, pt.WHITE
  pt.print 's',  "exc - 4,  Trap. #OF - Overflow Exception. Induced (into).", pt.END_LN 
  iret

exc_5:  ;// Нарушение. Нарушение границ массива. Код ошибки-нет. Вызвано: bound
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 5,  Fault. #BR - BOUND Range Exceeded Exception. Induced (bound).", pt.END_LN 
  pt.print 'm', pt.resetStr 
  com.stop

exc_6:  ;// Нарушение. Недопустимый код команды. Код ошибки-нет.
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 6,  Fault. #UD - Invalid Opcode Exception. Induced (invalid command).", pt.END_LN 
  pt.print 'm', pt.resetStr 
  com.stop

exc_7:  ;// Нарушение. Сопроцессор не доступен. Код ошибки-нет. Вызвано: esc, wait
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 7,  Fault. #NM - Device Not Available Exception. Induced (esc, wait).", pt.END_LN 
  pt.print 'm', pt.resetStr 
  com.stop

exc_8:  ;// Авария. Двойное нарушение. Код ошибки-да
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 8,  Abort. #DF - Double Fault Exception.", pt.END_LN 
  pt.print 'm', pt.resetStr 
  com.stop

exc_9:  ;// Авария. Выход сопроцессора из сегмента. Код ошибки-нет
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 9,  Fault. The output of the coprocessor segment.", pt.END_LN 
  pt.print 'm', pt.resetStr 
  com.stop

exc_10: ;// Нарушение. Недопустимый сегмент состояния задачи TSS. Код ошибки-да. Вызвано: jmp, call, iret, прерывание
  pop  eax ;// код ошибки
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 10, Fault. #TS - Invalid TSS Exception. Induced (jmp, call, iret, interrupt)."
  pt.print 's', "Error: ", 0 
  pt.print 'd', eax, 0, pt.BLUE
  pt.print 'm', pt.resetStr 
  com.stop

exc_11: ;// Нарушение. Отсутствие сегмента. Код ошибки-да. Вызвано: команда загрузки сегментного регистра
  pop  eax ;// код ошибки
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 11, Fault. #NP - Segment Not Present. Induced (segment register load command).", pt.END_LN 
  pt.print 's', "Error: ", 0 
  pt.print 'd', eax, 0, pt.BLUE
  pt.print 'm', pt.resetStr 
  com.stop

exc_12: ;// Нарушение. Ошибка обращения к стеку. Код ошибки-да. Вызвано: командой обращения к стеку
  pop  eax ;// код ошибки
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 12, Fault. #SS - Stack Fault Exception. Induced (stack access command). Induced (stack access command).", pt.END_LN 
  pt.print 's', "Error: ", 0 
  pt.print 'd', eax, 0, pt.BLUE
  pt.print 'm', pt.resetStr 
  com.stop

exc_13: ;// Нарушение. Общая защита. Код ошибки-да. Вызвано: команда обращения к памяти
  pop  eax ;// код ошибки
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 13, Fault. #GP - General Protection Exception. Induced (memory access command).", pt.END_LN 
  pt.print 's', "Error: ", 0 
  pt.print 'd', eax, 0, pt.BLUE
  pt.print 'm', pt.resetStr 
  com.stop

exc_14: ;// Нарушение. Страничное нарушение. Код ошибки-да. Вызвано: команда обращения к памяти
  pop  ebx ;// код ошибки
  pt.clear pt.RED, pt.WHITE
  pt.print 's',  "exc - 14, Fault. #PF - Page-Fault Exception.", pt.END_LN 
  pt.print 's',  "Induced (memory access command). Page addres = ", 0 
  mov eax, cr2
  pt.print 'h',  eax, 0, pt.BLUE
  pt.print 's', "h", pt.END_LN, pt.BLUE
  pt.print 's',  "Error code - ", 0 
  pt.print 'h', ebx, 0, pt.BLUE
  pt.print 's', "h", pt.END_LN, pt.BLUE
  ;// Разбор кода ошибки
  ;// Бит 0 - Если установлен, то ошибка не была вызвана отсутствием страницы. Если не установлен, страница отсутствует.
  com.getBit ebx, 0
  .if eax = true  
    pt.print 's',  "Page present", pt.END_LN
  .else
    pt.print 's',  "Page not present", pt.END_LN
  .endif
  ;// Бит 1 - Если установлен, операция, вызвавшая ошибку, была записью, иначе это было чтение.
  com.getBit ebx, 1
  .if eax = true  
    pt.print 's',  "Write page", pt.END_LN
  .else
    pt.print 's',  "Read page", pt.END_LN
  .endif
  ;// Бит 2 - Если установлен, то когда процессор был прерван он работал в пользовательском режиме. Иначе, он работал в режиме ядра.
  com.getBit ebx, 2
  .if eax = true  
    pt.print 's',  "User mode", pt.END_LN
  .else
    pt.print 's',  "Kernel mode", pt.END_LN
  .endif
  ;// Бит 3 - Если установлен, ошибка была вызвана перезаписью зарезервированных битов.
  com.getBit ebx, 3
  .if eax = true  
    pt.print 's',  "Write reserved bits", pt.END_LN
  .else
    pt.print 's',  "-", pt.END_LN
  .endif
  ;// Бит 4 - Если установлен, ошибка произошла во время выборки инструкции.
  com.getBit ebx, 4
  .if eax = true 
    pt.print 's',  "Read instruction", pt.END_LN
  .else
    pt.print 's',  "-", pt.END_LN
  .endif

  pt.print 'm', pt.resetStr 
  com.stop

exc_15: ;// Не используется
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "Shit!!!", pt.END_LN 
  pt.print 'm', pt.resetStr
  com.stop

exc_16: ;// Нарушение. Сопроцессор не доступен. Код ошибки-нет. Вызвано: esc, wait
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 16, Fault. #MF - x87 FPU Floating-Point Error. Induced (esc, wait).", pt.END_LN 
  pt.print 'm', pt.resetStr
  com.stop

exc_17: ;// Нарушение. Ошибка выравнивания. Код ошибки-да. Вызвано: команда обращения к памяти
  pop  eax ;// код ошибки
  pt.clear pt.RED, pt.WHITE
  pt.print 's', "exc - 17, Fault. #AC - Alignment Check Exception.Induced (memory access command). Induced (memory access command)."
  pt.print 's', "Error: ", 0
  pt.print 'd', eax, 0, pt.BLUE
  pt.print 'm', pt.resetStr
  com.stop
  















