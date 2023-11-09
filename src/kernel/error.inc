error.EXC_0  equ 0  ;// #DE Нарушение. Ошибка деления, код ошибки-нет. Вызвано: div, idiv
error.EXC_1  equ 1  ;// #DB Нарушение/Ловешка. Исключение отладки. Код ошибки-нет.
error.EXC_2  equ 2  ;// Немаскируемые прерывания поступающие на порт NMI. (Аппаратный сбой)
error.EXC_3  equ 3  ;// #BP Ловушка. Программное прерывание служащее для отладки. Вызвано: int 3
error.EXC_4  equ 4  ;// #OF Ловушка. Фиксирует арефметическое переполнение(overflow). Код ошибки-нет. Вызвано: into
error.EXC_5  equ 5  ;// #BR Нарушение. Нарушение границ массива. Код ошибки-нет. Вызвано: bound
error.EXC_6  equ 6  ;// #UD Нарушение. Недопустимый код команды. Код ошибки-нет.
error.EXC_7  equ 7  ;// #NM Нарушение. Сопроцессор не доступен. Код ошибки-нет. Вызвано: esc, wait
error.EXC_8  equ 8  ;// #DF Авария. Двойное нарушение. Код ошибки-да
error.EXC_9  equ 9  ;// Авария. Выход сопроцессора из сегмента. Код ошибки-нет
error.EXC_10 equ 10 ;// #TS Нарушение. Недопуст. сегмент состояния задачи TSS. Ошибка-да. Выз. jmp, call, iret, прерывание
error.EXC_11 equ 11 ;// #NP Нарушение. Отсутствие сегмента. Ошибка-да. Выз. команда загрузки сегмент. регистра
error.EXC_12 equ 12 ;// #SS Нарушение. Ошибка обращения к стеку. Код ошибки-да. Вызвано: командой обращения к стеку
error.EXC_13 equ 13 ;// #GP Нарушение. Общая защита. Код ошибки-да. Вызвано: команда обращения к памяти
error.EXC_14 equ 15 ;// #PF Нарушение. Страничное нарушение. Код ошибки-да. Вызвано: команда обращения к памяти
error.EXC_15 equ 15 ;// Не используется
error.EXC_16 equ 18 ;// #MF Нарушение. Сопроцессор не доступен. Код ошибки-нет. Вызвано: esc, wait
error.EXC_17 equ 19 ;// #AC Нарушение. Ошибка выравнивания. Код ошибки-да. Вызвано: команда обращения к памяти

macro error.collapse _message, _type: dword, _errorCode=false
{
  stdcall error_printReg
  com.stop
}

proc error_printReg
  pt.print 's',  "EAX="
  pt.print 'h',  eax, pt.ENDL
  pt.print 's',  "ECX="
  pt.print 'h',  ecx, pt.ENDL
  pt.print 's',  "EDX="
  pt.print 'h',  edx, pt.ENDL
  pt.print 's',  "EBX="
  pt.print 'h',  ebx, pt.ENDL
  pt.print 's',  "ESP="
  pt.print 'h',  esp, pt.ENDL
  pt.print 's',  "EBP="
  pt.print 'h',  ebp, pt.ENDL
  pt.print 's',  "ESI="
  pt.print 'h',  esi, pt.ENDL
  pt.print 's',  "EDI="
  pt.print 'h',  edi, pt.ENDL
  ret
endp










