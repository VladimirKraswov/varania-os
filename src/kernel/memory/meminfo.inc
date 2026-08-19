;/////////////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.        //
;// Distributed under terms of the GNU General Public License       //
;// Memory Info - Получение карты памяти от BIOS                    //
;// Дата: 22.08.2019                                                //
;/////////////////////////////////////////////////////////////////////

SMAP.table_size   = 24 ;// Размер одной записи E820
SMAP.type         = 16 ;// Тип описываемой области памяти
SMAP.attributes   = 20 ;// Расширенные атрибуты ACPI 3.x

;// Получает от BIOS карту памяти. Применяется только в реальном режиме.
;//
;// Формат буфера:
;//   dword [smap_off]     — число корректно полученных записей;
;//   [smap_off+4 + N*24]  — записи E820.
;//
;// EBX у BIOS — это непрозрачный ключ продолжения, а не число записей.
;// Исходная версия сохраняла EBX как счётчик, поэтому ядро не могло надёжно
;// разобрать карту. Здесь счётчик ведётся отдельно в BP и ограничивается
;// размером заранее выделенного буфера.
macro meminfo.get_smap smap_seg, smap_off
{
  local .next_entry, .done
  push eax ebx ecx edx edi ebp
  push es
  push smap_seg
  pop  es
  mov  di, smap_off+4                ;// первые 4 байта оставляем под счётчик
  xor  ebx, ebx                      ;// ноль начинает перечисление E820
  xor  bp, bp                        ;// число сохранённых записей
  @@:
    cmp bp, (SMAP.size-4)/SMAP.table_size
    jae .done                        ;// не выйти за пределы буфера
    mov [es:di + SMAP.attributes], dword 1 ;// запросить расширенную запись ACPI 3.x
    mov eax, 0xE820                  ;// Номер функции
    mov ecx, SMAP.table_size         ;// Размер буфера для принятия ячейки из таблицы (как минимум 20 байт)
    mov edx,"PAMS"                   ;// Строка "SMAP"
    int 0x15
    jc .done                         ;// BIOS закончил список или сообщил ошибку
    cmp eax, "PAMS"
    jne .done                        ;// защита от BIOS без E820
    test ecx, ecx
    jz .next_entry                   ;// пустую запись не сохраняем
    inc bp
    add di, SMAP.table_size
  .next_entry:
    test ebx, ebx
    jnz @b
  .done:
  mov [es:smap_off], bp
  mov [es:smap_off+2], word 0
  pop es
  pop ebp edi edx ecx ebx eax
}




 

  
  
  
  
  
  
