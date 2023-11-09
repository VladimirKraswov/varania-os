;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// Virtual Memory Manager - Менеджер виртуальной памяти      // 
;// Дата: 22.08.2019                                          //
;///////////////////////////////////////////////////////////////

include "memtools.inc"
include "pmm.inc"

mem.PAGE_SIZE             = pmm.FRAME_SIZE
mem.PAGE_OFF_MASK = 0xFFF
mem.PAGE_PTE_MASK = 0x3FF000
mem.PAGE_PDE_MASK = 0xFFC00000

mem.PAGE_PRESENT          = (1 shl 0) 
mem.PAGE_WRITABLE         = (1 shl 1)
mem.PAGE_USER             = (1 shl 2) 
mem.PAGE_WRITE_THROUGH    = (1 shl 3) 
mem.PAGE_CACHE_DISABLED   = (1 shl 4)
mem.PAGE_ACCESSED         = (1 shl 5) 
mem.PAGE_MODIFIED         = (1 shl 6)
mem.PAGE_GLOBAL           = (1 shl 8)

mem.HEAP_BASE             = 0x80000000

mem.heap     dd mem.HEAP_BASE
mem.dirPagesBase dd ?

;// Таблица дескрипторов сегментов для 32-битного ядра
align 16
GDT32:
  dq 0                  ;// NULL - 0
  dq 0x00CF9A000000FFFF ;// CODE - 8
  dq 0x00CF92000000FFFF ;// DATA - 16
GDTR32:
  dw $ - GDT32 - 1
  dd GDT32

macro mem.init
{ stdcall mem_init }

macro mem.mapTempPage _frame
{ stdcall mem_mapTempPage, _frame }

macro mem.mapPage _page, _frame, _count=1, _flags=11b
{ stdcall mem_mapPage,  _page, _frame, _count, _flags }

macro mem.malloc _size
{ stdcall mem_malloc, _size }

;// ПРОЦЕДУРЫ =======================================================

align 4
proc mem_init uses all_regs
  lgdt [GDTR32]   ;// Загрузим значение в GDTR
  pmm.init
  
  mov eax, cr3
  mem.descToAddr eax
  mov [mem.dirPagesBase], eax
  ret
endp

align 4
proc mem_mapTempPage uses all_regs, _frame: addr
  mov esi, KERNEL.tempPage
  mem.addrToPTE esi

  mov eax, [_frame]
  add eax, 11b
  mov [KERNEL.physTablePages+(esi*4)], eax
  
  invlpg [KERNEL.tempPage]
  ret
endp

align 4
proc mem_mapPage uses all_regs, _page: addr, _frame: addr, _count: dword, _flags: dword
  mov ecx, [_count]
  .NEXT_PAGE:
    ;// Получаем номер PDE в директории
    mov esi, [_page]
    mem.addrToPDE esi
    mov edi, [_page]
    mem.addrToPTE edi

    mov eax, [mem.dirPagesBase + (esi*4)]          ;// Прочитаем дескриптор из дириктории
    ;// Если таблица отсутствует то  создаем ее
    .if eax = 0
       pmm.allocFrame       ;// Выделим фрей под таблицу
       add eax, 111b        ;// Добавим к адресу фрейма атрибуты и получим дескриптор
       mov [mem.dirPagesBase + (esi*4)], eax       ;// Впишем дескриптор в каталог
       jmp  .NEXT_PAGE ;// Фрейм таблицы отображен во временную страницу
    .endif
    mem.descToAddr eax      ;// Преобразуем дескриптор в физ. адрес таблицы страниц. EAX = physic addres table
    mem.mapTempPage eax  ;// Отобразим выделенный фрейм во временную таблицу
    ;// Прибавим к адресу фрейма атрибуты, теперь это дескриптор
    mov eax, [_frame] 
    add eax, [_flags] 
    mov [KERNEL.tempPage + (edi*4)], eax          ;// Впишем дескриптор в таблицу страниц
    invlpg [_page]
    
    add [_page], mem.PAGE_SIZE
    loop .NEXT_PAGE
  ret
endp

align 4
proc mem_unmapPage uses all_regs, _page: addr, _count: dword
  ret
endp

proc mem_malloc uses not_eax,  _size: dword
  push [mem.heap]
  mov ecx, [_size]
  shr ecx, 12
  @@:
    pmm.allocFrame 
    mem.mapPage [mem.heap], eax
    add [mem.heap], mem.PAGE_SIZE
    loop @b
  pop eax
  return eax
endp
  




















  




