;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// Драйвер клавиатуры                                        //
;// Дата: 30.07.2019                                          //
;///////////////////////////////////////////////////////////////

;// +----H-----T----+  H - Голова
;// |0|0|1|1|1|0|0|0|
;// +---------------+  T - Хвост

;// Буффер клавиатуры
key.buffer.SIZE equ 16      ;// Размер буффера клавиатуры

key.buffer:
  db key.buffer.SIZE dup(0) 
  .head dd 0                     ;// Голова буффера
  .tail dd 0                     ;// Хвост буффера

;// МАКРООБЕРТКИ ===========================================================================================

macro key.init 
{ int.setHandler 33, key_readScancode, int.GATE_P+int.GATE_INT }
macro key.getScancode   { stdcall key_getScancode }
macro key.getChar _wait { stdcall key_getChar, _wait }

;// ПРОЦЕДУРЫ ============================================================================================

;// При возникновении прерывания читает сканкод клавиши из порта клавиатуры в буффер клавиш
;// Эту процедуру необходимо вызывать в обработчике прерываний клавиатуры
align 4
key_readScancode:
  pushad
  cli
  clr eax
  ;// запрашиваем позиционный код клавиши
  in   al, 0x60

  ;//  Если хвост достиг конца буффера, то переместим хвост в начало
  .if [key.buffer.tail] >= key.buffer.SIZE
    mov [key.buffer.tail], 0 ;// Перемещаем хвост в начало буффера
  .endif

  ;// добавляем сканкод в хвост буффера
  mov edi, [key.buffer.tail]
  mov [key.buffer+edi], al
  inc [key.buffer.tail]
 
  ;// посылка подтверждения обрабоки в порт клавиатуры
  ;// (установка и сброс 7 бита порта 61h)
  in   al, 0x61
  or   al, 80
  out  0x61, al
  xor  al, 80
  out  0x61, al

  sti
  pic.eoi
  popad
  iret
  
;// Читает сканкод клавиши из буффера, результат возврашает в EAX
align 4
proc key_getScancode uses not_eax
  clr eax
  ;// Если голова и хвост буффера равны то буффер пуст, читать нечего, выходим.
  mov esi, [key.buffer.head]
  .if esi = [key.buffer.tail]
    return 0                           ;// Выход.
  .endif
  ;// Если голова достигла конца буффера то перемещаем голову в начало буффера
  mov esi, [key.buffer.head]
  .if esi >= key.buffer.SIZE
    mov [key.buffer.head], 0  ;// Установка головы в начало буффера
  .endif
  ;// Чтение последней нажатой клавиши из буффера клавиатуры
  mov esi, [key.buffer.head]  ;// BL = голова буффера
  mov al,  [key.buffer+esi]   ;// Читаем последнюю нажатую клавишу из буффера
  inc [key.buffer.head]       ;// Перемещаем голову на 1 в конец буффера
 
  return eax                           ;// eax=scancode, Выход.
endp

















	