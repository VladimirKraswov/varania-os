;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// Driver Text Screen - Драйвер текстового экрана            //
;// Дата: 05.08.2019                                          //
;///////////////////////////////////////////////////////////////

dts.WIDTH  equ 80
dts.HEIGHT equ 25

;// Доступные цвета
dts.BLACK    	 equ 0  ;// Черный
dts.BLUE          equ 1  ;// Синий
dts.GREEN 	    equ 2  ;// Зеленый
dts.CYAN     	 equ 3  ;// Бирюзовый
dts.RED 	      equ 4  ;// Красный
dts.MAGENTA       equ 5  ;// Фиолетовый
dts.BROWN  	   equ 6  ;// Коричневый
dts.LIGHT_GRAY    equ 7  ;// Ярко серый
dts.DARK_GRAY     equ 8  ;// Темно серый
dts.LIGHT_BLUE    equ 9  ;// Голубой
dts.LIGHT_GREEN   equ 10 ;// Салатовый
dts.LIGHT_CYAN    equ 11 ;// Светло-бирюзовый
dts.LIGHT_RED     equ 12 ;// Розовый
dts.LIGHT_MAGENTA equ 13 ;// Светло-фиолетовый
dts.YELLOW        equ 14 ;// Желтый
dts.WHITE         equ 15 ;// Ярко-белый

dts.videobuffer dd 0xb8000   ;// Адрес видеобуфера

dts.port dw ?
;// МАКРОСЫ ============================================================================================================================

macro dts.init _vbAddr=0xb8000
{ 
  push eax
  push dword _vbAddr
  pop  dword [dts.videobuffer]

  mov ax, word [0x463]
  mov [dts.port], ax 
  pop eax
}

macro dts.setVideobuffer _videobuffer
{ stdcall dts_setVideobuffer, _videobuffer }

macro dts.clear _textColor, _bkgColor
{ stdcall dts_clear, _textColor, _bkgColor }

macro dts.setCursorPos  _x, _y
{ stdcall dts_setCursorPos, _x, _y }

macro dts.readCharacter _x, _y
{ stdcall dts_readCharacter, _x, _y }

macro dts.writeCharacter _char, _charColor, _bkgColor, _x, _y
{ stdcall dts_writeCharacter, _char, _charColor, _bkgColor, _x, _y }

macro dts.scroolDown
{ stdcall dts_scroolDown }

;// ПРОЦЕДУРЫ ============================================================================================================================

proc dts_setVideobuffer _videobuffer
  push [_videobuffer]
  pop [dts.videobuffer]
  ret
endp

;// Очистка экрана
proc dts_clear uses eax, _textColor, _bkgColor
  mov eax, [_bkgColor]
  shl eax, 4
  add eax, [_textColor]
  shl eax, 8
  mov al, ''
  ;// Заполняем видеобуфер цветом, один символ равен одному слову, (80*25) = 2000 слов
  com.memsetw [dts.videobuffer], eax, 2000 
  ret
endp
  

proc dts_setCursorPos uses all_regs, _x: dword, _y: dword
  ;// Вычесляем порядковый номер символа по формуле char_id = (y * 80 + x) 
  mov eax, [_y]
  mov ebx, 80
  mul bx
  add eax, [_x]

  mov dx, [dts.port] ; Порт
  mov ecx, eax ;// В EAX у нас находится расчитаная позиция курсора (номер ячейки в видеопамяти).
               ;// Сохраним эту позицию в ECX. Теперь в CH - старшая часть позиции курсора, CL - младшая

  mov al, 0x0E ;// В AL - регистр видеоконтроллера (хранит старший байт позиции курсора)
  mov ah, ch   ;// Заносим старший байт позиции курсора в AH
  out dx, ax   ;// Запишем в порт tty_port в регистр 0x0E старший байт позиции курсора

  mov al, 0x0F ;// В AL - регистр видеоконтроллера (хранит младший байт позиции курсора)
  mov ah, cl   ;// Заносим младший байт позиции курсора в AH
  out dx, ax   ;// Запишем в порт tty_port в регистр 0x0F младший байт позиции курсора
  ret
endp

proc dts_readCharacter uses not_eax, _x: dword, _y: dword
  ;// Вычесляем порядковый номер символа по формуле char_id = (y * dts.WIDTH + x) 
  mov eax, [_y]
  mov ebx, dts.WIDTH
  mul bx
  add eax, [_x]
  ;// Вычесляем линейный адрес символа в памяти addr = (char_id * 2)+vbAddr
  shl eax, 1
  add eax, [dts.videobuffer]
  ;// Прочитаем символ и его атрибуты из видеобуфера
  clr ecx
  mov cx, [eax]
  
  return ecx 
endp

;// Вывод символа на экран
proc dts_writeCharacter uses all_regs, _char: dword, _charColor: dword, _bkgColor: dword, _x: dword, _y: dword
  ;// Соеденяем атрибуты с ASCII кодом символа в одно слово
  clr ecx
  mov ecx, [_bkgColor]
  shl ecx, 4
  add ecx, [_charColor]
  shl ecx, 8
  add ecx, [_char]
  ;// Вычесляем порядковый номер символа по формуле char_id = (y * dts.WIDTH + x) 
  mov eax, [_y]
  mov ebx, dts.WIDTH
  mul bx
  add eax, [_x]
  ;// Вычесляем линейный адрес символа в памяти addr = (char_id * 2)+vbAddr
  shl eax, 1
  add eax, [dts.videobuffer]
  ;// Запишем символ и его атрибуты в видеобуфер
  mov [eax], cx
  ret
endp

;// Прокрутить экран
proc dts_scroolDown uses all_regs
  mov esi, [dts.videobuffer]                ;// Откуда копируем символы
  mov edi, esi                         ;// Куда копируем симыолы
  add esi, dts.WIDTH*2                 ;// Начинаем со второй строки
  
  mov ecx, dts.HEIGHT-1                ;// Всего нужно перекопировать dts.HEIGHT-последняя строка
  @@:
    com.memcpyw edi, esi, dts.WIDTH ;// Скопируем строку на строку выше
    ;// Переход к следующей строке
    mov edi, esi                       ;// Далее копировать будет в строку которая была источником
    add esi, dts.WIDTH*2               ;// А строку источник переместим ниже на одну строчку
    loop @b
   
  ;// Сотрем последнюю строку
  mov edi, [dts.videobuffer]
  add edi, ((dts.WIDTH*dts.HEIGHT)-dts.WIDTH)*2
  ;// Получим цвет фона которым закрасим последнюю строку
  mov eax, [edi-4] ;//копируем содержимое последней ячейки фиеобуфера
  clr al           ;// стираем символ
  ;// Заполняем полученным цветом всю последнюю строку
  com.memsetw edi, eax, dts.WIDTH
  ret
endp


    
    











;===================================================================================================================================