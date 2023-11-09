;/////////////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.        //
;// Distributed under terms of the GNU General Public License       //
;// Memory Info - Получение карты памяти от BIOS                    //
;// Дата: 22.08.2019                                                //
;/////////////////////////////////////////////////////////////////////

SMAP.table_size   = 24 ;// Размер одной таблицы
SMAP.type         = 20 ;// Тип описуемой области памяти

;// Получает от BIOS карту памяти. Применяется в реальном режиме. 
macro meminfo.get_smap smap_seg, smap_off
{
  push eax ebx edi
  push es 
  push smap_seg
  pop  es
  mov  di,smap_off+4                 ;// отступим 4 байта, в них мы будем держать количество таблиц                    ; ES:DI Указатель на буфер, отступим 4 байта
  xor  ebx,ebx                       ;// Значение возвращенное предыдущим вызовом
  @@:
    mov [es:smap_off],ebx            ;// Запишем колличество таблиц
    mov [es:di + SMAP.type], dword 1 ;// force a valid ACPI 3.X entry
    mov eax, 0xE820                  ;// Номер функции
    mov ecx, SMAP.table_size         ;// Размер буфера для принятия ячейки из таблицы (как минимум 20 байт)
    mov edx,"PAMS"                   ;// Строка "SMAP"
    int 0x15
    add di,SMAP.table_size           ;// передвигаем адрес в буфере
    cmp ebx, 0
    jnz @b
  pop es
  pop edi ebx eax
}




 
  
  
  
  
  
  
  