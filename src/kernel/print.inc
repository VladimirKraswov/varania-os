pt.WIDTH equ dts.WIDTH
pt.HEIGHT equ dts.HEIGHT

;// Доступные цвета
pt.BLACK         equ 0  ;// Черный
pt.BLUE          equ 1  ;// Синий
pt.GREEN 	    equ 2  ;// Зеленый
pt.CYAN     	 equ 3  ;// Бирюзовый
pt.RED 	      equ 4  ;// Красный
pt.MAGENTA       equ 5  ;// Фиолетовый
pt.BROWN  	   equ 6  ;// Коричневый
pt.LIGHT_GRAY    equ 7  ;// Ярко серый
pt.DARK_GRAY     equ 8  ;// Темно серый
pt.LIGHT_BLUE    equ 9  ;// Голубой
pt.LIGHT_GREEN   equ 10 ;// Салатовый
pt.LIGHT_CYAN    equ 11 ;// Светло-бирюзовый
pt.LIGHT_RED     equ 12 ;// Розовый
pt.LIGHT_MAGENTA equ 13 ;// Светло-фиолетовый
pt.YELLOW        equ 14 ;// Желтый
pt.WHITE         equ 15 ;// Ярко-белый

pt.BYTE          equ 0
pt.WORD          equ 1
pt.DWORD         equ 2

pt.END_LN       equ 10 ;// Перенос строки
pt.BACKSPACE    equ 8

pt.intToStrBuffer   rb 33        ;// Буфер для преобразования чисел в строки
pt.x                dd 0
pt.y                dd 0
pt.textColor        dd pt.WHITE
pt.bkgColor         dd pt.BLACK
pt.endLine:         db 10, 0


macro pt.init _textColor=pt.WHITE, _bkgColor=pt.BLACK
{ 
  push _textColor
  pop [pt.textColor]
  push _bkgColor
  pop [pt.bkgColor]
  pt.clear
}

macro pt.getTextColor
{ mov eax, [pt.textColor] }

macro pt.setTextColor _color
{
  push _color
  pop [pt.textColor]
}

macro pt.getBkgColor
{ mov eax, [pt.bkgColor] }

macro pt.setBkgColor _color
{
  push _color
  pop [pt.bkgColor]
}

macro pt.clear _textColor=[pt.textColor], _bkgColor=[pt.bkgColor]
{ stdcall pt_clear, _textColor, _bkgColor }

macro pt.endLn
{ stdcall pt_endLn } 

macro pt.backspace
{ stdcall pt_backspace }

macro pt.printString _string
{ stdcall pt_printString, _string }

;// Печать текста
macro pt.print _type, _value, _endLine=0, _textColor=16, _bkgColor=16
{
  push [pt.textColor] [pt.bkgColor]

  if _textColor < 16
    mov [pt.textColor], _textColor
  end if

  if _bkgColor < 16
    mov [pt.bkgColor], _bkgColor
  end if

  if _type eq 'b'
    com.intToBinStr _value, pt.intToStrBuffer
    pt.printString pt.intToStrBuffer
  else if _type eq 'h'
    com.intToHexStr _value, pt.intToStrBuffer
    pt.printString pt.intToStrBuffer
  else if _type eq 'd'
    com.intToUdecStr _value, pt.intToStrBuffer
    pt.printString pt.intToStrBuffer
  else if _type eq 's'
    local ..print_string
    local ..s
    jmp ..print_string
    ..s db _value, 0
    ..print_string:
      pt.printString ..s
  else if _type eq 'm'
    pt.printString _value
  end if

  if _endLine > 0
    pt.printString pt.endLine
  end if
  ;// Вернуть прежний цвет
  pop [pt.bkgColor] [pt.textColor]
}

;// Очистить экран
proc pt_clear _textColor: dword, _bkgColor: dword
  dts.clear [_textColor], [_bkgColor]
  push [_textColor]
  pop [pt.textColor]
  push [_bkgColor]
  pop [pt.bkgColor]
  mov [pt.x], 0
  mov [pt.y], 0
  dts.setCursorPos [pt.x], [pt.y]
  ret
endp

;// Перевести каретку на новую строку
proc pt_endLn
  inc [pt.y]
  mov [pt.x], 0

  .if [pt.y] > pt.HEIGHT-1 ;
    dts.scroolDown ;// Прокрутить экран вниз на одну строку
    mov [pt.y], pt.HEIGHT-1
  .endif

  dts.setCursorPos [pt.x], [pt.y]
  ret
endp

;// Удаление последнего символа
proc pt_backspace
  .if [pt.x] > 0
    dec [pt.x]
    pt.print 's', ' '
    dec [pt.x]
    dts.setCursorPos [pt.x], [pt.y]
  .endif
  ret
endp

;// Печать строки
proc pt_printString uses all_regs, _string: addr
  mov esi, [_string]
  clr eax
  .loop:
    lodsb       ;// AL<-[DS:SI]&&SI++

    .if al = 0  ;// Конец строки?
      ret       ;// Завершить печать
    .endif

    .if al = pt.END_LN
      pt.endLn
    .elseif al = pt.BACKSPACE
      pt.backspace
    .else
      dts.writeCharacter eax, [pt.textColor], [pt.bkgColor], [pt.x], [pt.y]
      inc [pt.x]
      dts.setCursorPos [pt.x], [pt.y]
    .endif

    jmp .loop  ;//and Следующий символ
    
  .end:
    ret
endp











