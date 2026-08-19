;/////////////////////////////////////////////////////////////////
;//// Copyright (c) Varania OS team 2019. All rights reserved.  //
;//// Distributed under terms of the GNU General Public License //
;//// Const - Модуль констант используемых в Varania OS        //
;//// Дата: 30.07.2019                                          //
;//// Версия amd64: 64-bit long mode, 4-level paging           //
;/////////////////////////////////////////////////////////////////

;//// PADDR - физ. адрес
;//// ADDR  - вирт. адрес

;/////////////////////////////////////////////////////////////////
;//// КАРТА ПАМЯТИ amd64 (bootstrap identity + HHDM)             //
;/////////////////////////////////////////////////////////////////
;// 0x000000-0x0005FF  MBR, данные BIOS
;// 0x000600-0x0009FF  буфер карты памяти E820 (SMAP)
;// 0x001000-0x001FFF  этап 2 загрузчика: 16-битный код 0x1000,
;//                     32-битный код 0x1800, 64-битный трамплин 0x1F00,
;//                     блок данных трамплина 0x1F40
;// 0x002000-0x00FFFF  32-битный стек загрузчика (растёт вниз с 0x10000)
;// 0x010000-0x014FFF  стартовые таблицы (identity + HHDM)
;// 0x050000-0x05FFFF  временная загрузка ядра (16-битный DMA, < 1 MiB)
;// 0x060000-0x08FFFF  временный bootstrap initramfs (192 KiB)
;// 0x100000-0x10FFFF  ядро (64 KiB), вирт. KERNEL.base
;// 0x110000-0x3EFFFF  bootstrap-резерв
;// 0x2DF000-0x2DF037  GDT64
;// 0x2DF060-0x2DF0C7  TSS64
;// 0x2E0000-0x2EFFFF  аварийный стек IST (растёт вниз с IST.top = 0x2F0000)
;// 0x2F0000-0x2FFFFF  стек ядра (растёт вниз с STACK.top = 0x300000)
;// 0x3F0000-0x3F7FFF  битовая карта PMM (8 кадров)
;// 0x400000-0x42FFFF  bootstrap initramfs: ELF, FASM и базовые службы
;//
;// HHDM (Higher Half Direct Map, PML4[256]) отображает физ. 0..1 GiB:
;//   0xFFFF800000000000 + physical_address
;/////////////////////////////////////////////////////////////////

;//// Размер загрузочного сектора (MBR) и страницы памяти
MBR.size                 = 512  ;// Размер MBR области
PAGE_SIZE                = 4096 ;// Размер страницы 4 KiB
PAGE_SIZE_2M             = 0x200000 ;// Размер большой страницы 2 MiB

;//// Карта памяти (E820), полученная от BIOS.
;//// Буфер лежит в нижнем мегабайте: загрузчик видит его через
;//// identity map, а микроядро после смены CR3 — через HHDM.
SMAP.segment = 0x0                          ;// Сегмент буфера карты памяти
SMAP.offset  = 0x600                        ;// Смещение буфера карты памяти
SMAP.base    = (SMAP.segment*16)+SMAP.offset ;// Физический адрес начала буфера
SMAP.size    = 1024                         ;// Размер буфера карты памяти
SMAP.count   = SMAP.base                    ;// [0..3] - количество записей E820
SMAP.entries = SMAP.base+4                  ;// [4..]  - записи E820 (24 байта)

;//// Продолжение загрузчика (этап 2, 4 KiB).
;//// 16-битный код - в начале страницы, 32-битный код - на смещении
;//// BOOT2.pm32 (физ. адрес 0x1800), 64-битный трамплин - в конце
;//// страницы на BOOT2.tramp (физ. адрес 0x1F00).
BOOT2.segment      = SMAP.segment
BOOT2.offset       = 0x1000
BOOT2.base         = (BOOT2.segment*16)+BOOT2.offset
BOOT2.pm32         = 0x800  ;// Смещение 32-битного кода внутри этапа 2
BOOT2.start32      = BOOT2.offset+BOOT2.pm32 ;// Физ. адрес старта 32-битного кода
BOOT2.tramp        = 0xF00  ;// Смещение 64-битного трамплина (физ. 0x1F00)
BOOT2.data         = 0xF40  ;// Смещение блока данных трамплина (физ. 0x1F40)
BOOT2.stack        = 0x500  ;// Верх 16-битного стека (ниже таблиц)
BOOT2.stack32      = 0x10000 ;// Верх 32-битного стека (область 0x2000..0x10000)
BOOT2.size         = 4096
BOOT2.firstSector  = 1    ;// LBA первого сектора этапа 2

;//// Физические адреса страничных таблиц (4-level paging).
;//// Identity-карта нужна только загрузчику. HHDM даёт ядру
;//// постоянный supervisor-only адрес каждого физического кадра.
PT.PML4       = 0x10000  ;// Таблица верхнего уровня (PML4)
PT.PDPT_ID    = 0x11000  ;// PDPT identity-карты
PT.PD_ID      = 0x12000  ;// 512 больших страниц identity-карты
PT.PDPT_HI    = 0x13000  ;// PDPT верхней половины
PT.PD_HI      = 0x14000  ;// PD верхней половины
PT.DIRECT_PAGES = 512    ;// 512 * 2 MiB = 1 GiB физической памяти

;//// Физические адреса ядра и служебных данных
KERNEL.tempBase    = 0x50000  ;// Временный физ. адрес ядра (16-битный DMA, < 1 MiB)
KERNEL.physBase    = 0x100000 ;// Физический адрес ядра
KERNEL.size        = 65536    ;// Размер ядра в байтах (128 секторов)
KERNEL.sectors     = KERNEL.size/512
KERNEL.firstSector = BOOT2.firstSector+(BOOT2.size/512) ;// LBA первого сектора ядра

;//// Initramfs содержит только доверенный bootstrap: procd, init и драйверы.
;//// Исходники и результаты self-hosted сборки живут на системном диске.
;//// 192 KiB целиком помещаются ниже 0x90000 и не зависят от EBDA/VGA.
INITRAMFS.tempBase    = 0x60000
INITRAMFS.physBase    = 0x400000
INITRAMFS.size        = 0x30000
INITRAMFS.sectors     = INITRAMFS.size/512
INITRAMFS.firstSector = KERNEL.firstSector+KERNEL.sectors

;//// HHDM начинается с PML4[256] и линейно отображает физические 0..1 GiB.
;//// Код ядра лежит по HHDM+физический KERNEL.physBase.
;//// Ограничение FASM 1.73: hex-литералы выше 0x9FFFFFFFFFFFFFFF парсер
;//// не принимает, поэтому константа записана выражением.
HHDM.base   = 0FFFF80000000000h shl 4
KERNEL.base = HHDM.base+KERNEL.physBase

;//// Разряды KERNEL.base для записи из 32-битного кода загрузчика
;//// (mov [mem], imm32 не может принять 64-битное значение целиком)
KERNEL.baseLo = 0x00100000 ;// младшие 32 бита
KERNEL.baseHi = 0xFFFF8000 ;// старшие 32 бита

;//// Виртуальный адрес 64-битной точки входа ядра (смещение 0 в образе)
KERNEL.entry = KERNEL.base
KERNEL.entryLo = KERNEL.entry mod 0x100000000  ;// младшие 32 бита (для записи из 32-битного кода)
KERNEL.entryHi = KERNEL.entry shr 32 ;// старшие 32 бита

;//// Преобразовать физический адрес в supervisor-only HHDM-адрес.
macro KERNEL.physToVirt _addr
{
  HHDM.base + _addr
}

;//// Флаги страничных дескрипторов
PAGE.P  = 1        ;// Present - страница в памяти
PAGE.RW = 2        ;// Read/Write - чтение/запись
PAGE.US = 4        ;// User - доступна из пользовательского режима
PAGE.PS = 0x80     ;// Page Size - большая страница (2 MiB)
PAGE.BORROWED = 0x200 ;// software bit: leaf PTE не владеет физическим кадром
PAGE.SHARED = PAGE.BORROWED ;// совместимое имя для shared-memory mappings
PAGE.NX = 1 shl 63 ;// No Execute, действует после включения EFER.NXE

;//// Селекторы сегментов 64-битной GDT. TSS занимает 16 байт.
SEL.null   = 0x00 ;// Нулевой (пустой) дескриптор
SEL.code32 = 0x08 ;// 32-битный код (protected mode)
SEL.data32 = 0x10 ;// 32-битные данные
SEL.code64 = 0x18 ;// 64-битный код (long mode)
SEL.data64 = 0x20 ;// 64-битные данные
SEL.userData64 = 0x28 ;// данные ring 3 (RPL добавляется при загрузке)
SEL.userCode64 = 0x30 ;// код ring 3
SEL.tss    = 0x38 ;// 64-битный TSS

;//// 64-битная GDT и TSS. Размещаются внутри 2 MiB страницы ядра и
;//// отображаются в верхней половине (PD_HI[0]).
GDT64.base = 0x2DF000 ;// Физический адрес GDT
GDT64.size = 72       ;// 7 обычных записей + 16-байтовый дескриптор TSS
TSS64.base = 0x2DF060 ;// Физический адрес TSS
TSS64.size = 104      ;// Размер 64-битного TSS (до конца I/O битовой карты)
TSS64.iopb = TSS64.size ;// Смещение конца I/O битовой карты в TSS

;//// Таблица векторов прерываний (IDT).
;//// Размещается внутри образа ядра на смещении IDT.offset,
;//// поэтому её виртуальный адрес лежит в верхней половине.
IDT.offset = 0xF000                 ;// Смещение IDT внутри образа ядра
IDT.size   = 256*16                 ;// 256 шлюзов x 16 байт (64-bit)
IDT.base   = KERNEL.base+IDT.offset ;// Виртуальный адрес IDT

;//// Стек ядра (внутри 2 MiB страницы ядра, растёт вниз; верх - STACK.top)
STACK.base = 0x2F0000 ;// Физическое начало стека ядра
STACK.size = 65536    ;// Размер стека ядра 64 KiB
STACK.top  = STACK.base+STACK.size  ;// Физ. верх стека (0x300000)
STACK.rsp  = HHDM.base+STACK.top
STACK.rspLo = STACK.rsp mod 0x100000000 ;// младшие 32 бита (для записи из 32-битного кода)
STACK.rspHi = STACK.rsp shr 32 ;// старшие 32 бита

;//// Аварийный стек (IST[1]) для двойных сбоев (#DF)
IST.base = 0x2E0000 ;// Физическое начало IST-стека
IST.size = 65536    ;// Размер IST-стека 64 KiB
IST.top  = IST.base+IST.size  ;// Физ. верх стека (0x2F0000)
IST.rsp  = HHDM.base+IST.top
IST.rspLo = IST.rsp mod 0x100000000 ;// младшие 32 бита (для записи из 32-битного кода)
IST.rspHi = IST.rsp shr 32 ;// старшие 32 бита

;//// Физический менеджер памяти (PMM)
;//// Управляет кадрами 4 KiB в диапазоне PMM.memStart..PMM.memEnd.
;//// Диапазон ограничивается при инициализации фактическим размером
;//// RAM (E820). Номер кадра в битовой карте = абсолютный физ. адрес / 4K
;//// (кадры ниже PMM.memStart не выдаются).
PMM.bitmap     = 0x3F0000  ;// Физ. адрес битовой карты кадров
PMM.bitmapSize = 32768     ;// 32 KiB = 1 бит на 4 KiB кадр (до 1 GiB)
PMM.frames     = PMM.bitmapSize*8 ;// Макс. число кадров в карте (262144)
PMM.memStart   = 0x500000  ;// bootstrap-области не выдаются задачам
PMM.memEnd     = 0x40000000 ;// Верх (ограничение, уточняется по E820)
