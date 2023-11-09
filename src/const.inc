;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// Const - Модуль констант используемых в Varania OS         //
;// Дата: 30.07.2019                                          //
;///////////////////////////////////////////////////////////////

;// PADDR - физ. адрес
;// ADDR  - вирт. адрес

;// BIOS_MEM_START           = 0x0F000
;// BIOS_MEM_END             = 0x0FFFF

MBR.size                 = 512  ;// Размер MBR области
PAGE_SIZE = 4096

;// Карта памяти полученная от BIOS.
SMAP.segment = 0x0                           ;// Адрес сегмента карты памяти
SMAP.offset  = 0x600                         ;// Адрес смещения карты памяти
SMAP.base    = (SMAP.segment*16)+SMAP.offset ;// Физический адрес базы карты памяти
SMAP.size    = 1024

;// Продолжение загрузчика
BOOT2.segment      = SMAP.segment
BOOT2.offset       = SMAP.offset+SMAP.size+BOOT2.stackSize
BOOT2.base         = (BOOT2.segment*16)+BOOT2.offset
BOOT2.stack        = BOOT2.base
BOOT2.stackSize    = 1024
BOOT2.size         = 4096
BOOT2.firstSector  = 1

ONE_MB_TABLE_PAGES = 0x11000  ;// Физ. адрес таблицы страниц первого мегабайта

;// Физ. адреса ядра и служебных данных
KERNEL.physDirPages    = 0x10000  ;// Физ. адрес каталога таблиц страниц
KERNEL.physTablePages  = 0x12000  ;// Физ. адрес таблицы страниц с ядром
KERNEL.tempBase        = 0x13000  ;// Временный физ. адрес ядра 
KERNEL.physBase        = 0x100000 ;// Физ. адрес ядра 
KERNEL.size            = 65544    ;// Размер ядра в байтах
KERNEL.firstSector     = BOOT2.firstSector+(BOOT2.size/512) ;// LBA номер первого сектора ядра
;// Вирт. адреса ядра и служебных данных (4MB)
KERNEL.base            = 0xFFC00000 ;// Вирт. адрес базы ядра
KERNEL.stack           = 0xFFFDB000 ;// Вирт. адрес стека ядра
KERNEL.idt             = 0xFFFDC000 ;// Вирт. адрес таблицы прерывани
KERNEL.videobuffer     = 0xFFFDD000 ;// Вирт. адрес видеобуфера
KERNEL.dirPages        = 0xFFFDE000 ;// Вирт. адрес зарезервирован
KERNEL.tempPage        = 0xFFFDF000 ;// Вирт. адрес временной страницы
KERNEL.bitmapFrames    = 0xFFFE0000 ;// Вирт. адрес битовой карты памяти (Размер 131072B=32ст.)

SEL_CODE           = 8  ;// Селектор сегмента кода   (1-ый дескриптор в GDT)                     
SEL_DATA           = 16 ;// Селектор сегмента данных (2-ий дескриптор в GDT)













