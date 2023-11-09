;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rghts reserved.   //
;// Distributed under terms of the GNU General Public License //
;// Kernel - ядро                                             //
;// Дата: 28.07.2019                                          //
;///////////////////////////////////////////////////////////////

format Binary as "bin" ;// бинарный файл

use32
                                                                             
org KERNEL.base

jmp START

include "macro/macro.inc"      ;// Макросы расширения FASM
include "common/com.inc"       ;// Общие функции и макросы
include "../const.inc"         ;// Константы ядра

include "drivers/dts.inc"      ;// Драйвер текстового экрана
include "print.inc"            ;// Печать текста
include "error.inc"            ;// Сообщения об ошибках
include "int.inc"              ;// Менеджер прерываний
include "exc.inc"              ;// Обработчики исключений
include "memory/mem.inc"       ;// Менеджер памяти
include "drivers/pit.inc"      ;// Драйвер интервального таймера
include "drivers/key.inc"      ;// Драйвер клавиатуры
include "sys.inc"              ;// Обработчики системных вызовов
include "tty/tty.inc"          ;// Терминал

START:
  ;// Инициализация ядра
  dts.init 0xB8000              ;// Драйвер текстового экрана
  pt.init pt.WHITE, pt.BLACK    ;// Печать
  int.init                      ;// Прерывания
  exc.init                      ;// Исключения
  mem.init                      ;// Менеджер памяти
  pit.init 100                  ;// Интервальный таймер. Сто срабатываний в секунду, одино раз в 10 миллисекунд
  key.init                      ;// Драйвер клавиатуры
  sys.init                      ;// Системные вызовы
  int.enable                    ;// Включить обработку всех прерываний
  
  ;// Вывести приветствие
  pt.print 's', "Velcome to Varania OS! version: 1.0", pt.END_LN, pt.YELLOW
  ;mem.malloc 4096
  pmm.allocFrame
  mem.mapPage 8000000h, eax, 1, 11b
  com.memcpy 8000000h, prg, prg.size

  call 8000000h
  com.stop

prg:
  mov esi, msg
  int 48
  ret
  msg db "Prg1", 10, "Hello", 10, 0

prg.size = $ - prg
  
;// =========================================================================================
;// Заполняем оставшееся место нулями
times KERNEL.size-($-$$) db 0





















                       