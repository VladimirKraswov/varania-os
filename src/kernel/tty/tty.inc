;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// TTY - Драйвер терминала                                   //
;// Дата: 05.08.2019                                          //
;///////////////////////////////////////////////////////////////

include "ascii.inc"

macro tty.getChar _wait=false { stdcall tty_getChar, _wait }
macro tty.getLine _buffer, _size { stdcall tty_getLine, _buffer, _size }

;// Пользовательский ввод
tty.shift db 0
;// Возврощает ANSII символ нажатой клавиши
;// _wait - дожидатся нажатия клавиши
proc  tty_getChar uses not_eax, _wait: bool
  .GET_SCANCODE: ;// Возвращаемся сюда пока из ASCII таблицы не будет считан символ отличный от нуля
    key.getScancode ;// Функция драйвера клавиатуры. Читает в EAX сканкод нажатой/отпушенной клавиши
    
    ;// Если wait = true а сканкод равен нулю, повторяем чтение
    .if [_wait] = true & eax = 0
      jmp .GET_SCANCODE
    .endif
    
     ;// Если нажат правый шифт то установим shift = 1 (true)
    .if eax = tty.KEY_RIGHT_SHIFFT ;// Правый шифт
      inc [tty.shift]              ;// устанавливаем shift в 1 
    .endif

    ;// Если нажат левый шифт то установим shift = 1 (true)
    .if eax = tty.KEY_LEFT_SHIFFT ;// Левый шифт
      inc [tty.shift]             ;// устанавливаем shift в 1 
    .endif
    
    ;// Если правый шифт отпушен то установим shift = 0 (false)
    .if eax = tty.KEY_RIGHT_SHIFFT+tty.KEY_UP ;// Правый шифт, отпускание
      mov [tty.shift], 0                      ;// устанавливаем shift в 0 и выходим
    .endif

    ;// Если левый шифт отпушен то установим shift = 0 (false)
    .if eax = tty.KEY_LEFT_SHIFFT+tty.KEY_UP ;// Левый шифт, отпускание
      mov [tty.shift], 0                     ;// устанавливаем shift в 0 и выходим
    .endif

    ;// Если прочитанный код - отжатия клавиши то он = 0 
    test eax, tty.KEY_UP ;// Сравниваем побитно
    jz .end_test         ;// Это не сканкод отжатия, выходим
    xor eax, eax         ;// В противном случае присваиваем 0
    .end_test:
    
    ;// Теперь EAX содержит сканкод

    ;// Мы прочли сканкод не являющимся кодом отжатия клавиши,
    ;// читаем ASCII символ сканкода из таблицы в AL

    ;// Если не зажат Shift то читаем из ascii
    .if [tty.shift] = 0     
      mov al, byte [tty.ascii+eax] 
    .else                      ;// Если Shift зажат читаем из ascii_shifted
      mov al, byte [tty.ascii_shifted+eax] ;// Запишем в AL ASCII символ из таблицы символов
    .endif

    ;// Если wait = true а из таблицы символов вернулся ноль, повторить все заново
    .if [_wait] = true & eax = 0
      jmp .GET_SCANCODE
    .endif

    return eax
endp

proc tty_getLine uses all_regs, _buffer: addr, _size: uint32
  mov edi, [_buffer]
  com.memset edi, 0, [_size]
  .l:
    tty.getChar true
    .if [tty.coll] = tty.WIDTH
      mov eax, tty.KEY_ENTER
    .endif
    tty.printc eax
    
    
    .if eax = tty.KEY_ENTER
      xor ebx, ebx
      mov esi, [tty.row]
      dec esi
      mov ecx, [_size]
      dec ecx
      
      .read:
        dts.readCharacter ebx, esi
        mov [edi], al
        inc edi
        inc ebx
      loop .read
      ret
    .endif
  jmp .l
endp


    








;===================================================================================================================================