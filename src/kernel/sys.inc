;/////////////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.        //
;// Distributed under terms of the GNU General Public License       //
;// Syscall - Системные вызовы (Обработка программных прерываний)   //
;// Дата: 05.08.2019                                                //
;/////////////////////////////////////////////////////////////////////

macro sys.init
{ 
  int.setHandler 48,  sys_handler_int48, int.GATE_P+int.GATE_TRAP
}


;// Обработчики системных вызовов
;// Системный вызов INT 48 - печать строки
;// входные параметры: DS:ESI указывает на ASCIIZ-строку
sys_handler_int48:
  cli
  pt.print 'm', esi
  sti
  iret
