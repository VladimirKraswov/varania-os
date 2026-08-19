;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// BOOT - Загрузчик Varania OS         //
;// Дата: 30.07.2019                                          //
;// Версия amd64: 16-bit -> 32-bit (4-level paging) -> 64-bit //
;///////////////////////////////////////////////////////////////

format Binary as ""

use16 ;// 16-ти битный код

;// Обычно, после первых 3-4 байт загрузчика размещается заголовок некоторых файловых систем (например, FAT),
;// поэтому первым делом мы обходим все данные и прыгаем на истинную точку входа начального загрузчика.
;// Слово word говорит flat assembler не пытаться оптимизировать размер перехода и в любом случае
;// положить адрес перехода в 2 байта, даже если можно в 1. Таким образом наш jmp должен гарантированно занять 3 байта.

org 0x7C00
jmp word BOOT ;// сылка на загрузочный код 3 байта

;// ПОДКЛЮЧЕНИЯ

include "../const.inc"
include "disk.inc"

;// ПЕРЕМЕННЫЕ

disk_id db ? ;// диск с которого произведена загрузка

BOOT:
  ;// Инициализация сегментных регистров
  cli               ;// Запретить прерывания для смены адресов в сегментных регистрах
  xor  ax, ax       ;// ах = 0
  mov  ss, ax       ;// ss = 0 (Сегмент стека)
  mov  sp, 0x7C00   ;// Указатель стека
  push ax
  pop  es           ;// es = 0 (Дополнительный сегмент данных)
  push ax
  pop  ds           ;// ds = 0 (Сегмент данных)
  sti               ;// Разрешить прерывания (после изменения адресов)

  mov [disk_id], dl ;// Сохранить номер диска с которого загрузились

  ;// Дозагрузка загрузчика (этап 2, 8 секторов в 0x1000)
  disk.load_sectors [disk_id], 0, BOOT2.firstSector, BOOT2.size/512, BOOT2.base

  jmp fword BOOT2.segment:BOOT2.offset ;// Переход на продолжение загрузчика

;//-----Заполнитель-----
times 510 - ($ - $$) db 0 ;// $  = адрес текущей инструкции; $$ = адрес 1-й инструкции
dw 0xAA55 ;// сигнатура загрузочного сектора


;//=============================================================================================================
;// ЭТАП 2 (4 KiB, физ. 0x1000..0x1FFF)
;//   0x1000 (BOOT2.offset)   - 16-битный код
;//   0x1800 (BOOT2.start32)  - 32-битный код (PAE, paging, переход в 64-bit)
;//   0x1F00 (BOOT2.tramp)    - 64-битный трамплин
;//   0x1F40 (BOOT2.data)     - блок данных трамплина (entry + rsp)

org BOOT2.offset
use16

BOOT2.start:
  ;// Инициализация сегментных регистров
  cli                           ;// Запретить прерывания для смены адресов в сегментных регистрах
  mov  ax, BOOT2.segment        ;// сегмент 0
  mov  ss, ax                   ;// Сегмент стека
  mov  sp, BOOT2.offset         ;// Указатель стека (растёт вниз от 0x1000)
  push ax
  pop  es                       ;// Дополнительный сегмент данных
  push ax
  pop  ds                       ;// Сегмент данных
  sti

  ;// Очистка экрана (функция 02h прерывания 10h)
  mov ax, 0x02
  int 0x10

  ;// Открыть адресную линию A20 (чтобы была доступна вся память)
  in  al, 0x92
  or  al, 2
  out 0x92, al

  ;// Загрузка ядра во временный буфер (16-битный DMA, ниже 1 MiB)
  disk.load_sectors [disk_id], 0, KERNEL.firstSector, KERNEL.size/512, KERNEL.tempBase

  ;// Bootstrap-initramfs намеренно компактен: BIOS читает его в нижний
  ;// MiB обычным EDD DAP, а protected-mode этап перенесёт архив выше.
  disk.load_sectors [disk_id], 0, INITRAMFS.firstSector, INITRAMFS.sectors, INITRAMFS.tempBase

  ;// Получаем от BIOS карту памяти (E820)
  include "../kernel/memory/meminfo.inc"
  meminfo.get_smap SMAP.segment, SMAP.offset

  ;// Последний BIOS-вызов перед protected mode выбирает линейный 32-битный
  ;// framebuffer. Ищем лучший режим до 1280x800: это практический максимум
  ;// для программного композитора при минимальных 128 MiB RAM. Если VBE нет,
  ;// загрузка продолжится в text mode, а GUI-сервис честно сообщит ошибку.
  call vbe_initialize

  ;// Загружаем GDTR таблицей 32-битных дескрипторов
  lgdt [GDTR32]

  ;// Запрет всех прерываний
  cli
  ;// запрет NMI
  in   al, 0x70
  or   al, 0x80
  out  0x70, al

  ;// Переключаемся в защищенный режим
  mov eax, cr0
  or  eax, 1     ;// устанавливаем 0-вой бит (PE)
  mov cr0, eax

  ;// Переходим на 32-битный код
  jmp fword SEL.code32:stage32

;// Выбрать лучший VBE 2.0 direct-color LFB не больше 1280x800.
;// Буферы расположены в зарезервированной низкой памяти и затем читаются
;// микроядром только как platform boot information.
vbe_initialize:
  push ax
  push bx
  push cx
  push dx
  push si
  push di
  push es
  push fs
  xor ax, ax
  mov es, ax
  mov di, VBE.controllerInfo
  mov dword [es:di], VBE.magic
  mov ax, 0x4F00
  int 0x10
  cmp ax, 0x004F
  jne .done

  mov si, [es:VBE.controllerInfo+14] ;// far pointer: offset
  mov ax, [es:VBE.controllerInfo+16] ;// far pointer: segment
  mov fs, ax
  mov dword [es:VBE.bootInfo+VBE.Boot.magic], 0
  mov word [es:VBE.bootInfo+VBE.Boot.mode], 0xFFFF
  mov dword [es:VBE.bootInfo+VBE.Boot.pages], 0 ;// временно best area
.mode:
  mov cx, [fs:si]
  add si, 2
  cmp cx, 0xFFFF
  je .select
  push cx
  push si
  push fs
  xor ax, ax
  mov es, ax
  mov di, VBE.modeInfo
  mov ax, 0x4F01
  int 0x10
  pop fs
  pop si
  pop cx
  cmp ax, 0x004F
  jne .mode
  mov ax, [es:VBE.modeInfo+0]     ;// supported + graphics + linear framebuffer
  and ax, 0x0091
  cmp ax, 0x0091
  jne .mode
  cmp byte [es:VBE.modeInfo+25], 32
  jne .mode
  cmp byte [es:VBE.modeInfo+27], 6 ;// direct color
  jne .mode
  movzx eax, word [es:VBE.modeInfo+18]
  cmp eax, 800
  jb .mode
  cmp eax, 1280
  ja .mode
  movzx edx, word [es:VBE.modeInfo+20]
  cmp edx, 600
  jb .mode
  cmp edx, 800
  ja .mode
  imul eax, edx
  cmp eax, [es:VBE.bootInfo+VBE.Boot.pages]
  jbe .mode
  mov [es:VBE.bootInfo+VBE.Boot.pages], eax
  mov [es:VBE.bootInfo+VBE.Boot.mode], cx
  jmp .mode

.select:
  mov bx, [es:VBE.bootInfo+VBE.Boot.mode]
  cmp bx, 0xFFFF
  je .done
  ;// Повторно получаем информацию именно выбранного режима: modeInfo в цикле
  ;// сейчас описывает последний проверенный режим, а не обязательно лучший.
  mov cx, bx
  mov di, VBE.modeInfo
  mov ax, 0x4F01
  int 0x10
  cmp ax, 0x004F
  jne .done
  or bx, 0x4000                  ;// linear framebuffer
  mov ax, 0x4F02
  int 0x10
  cmp ax, 0x004F
  jne .done
  mov dword [es:VBE.bootInfo+VBE.Boot.magic], VBE.magic
  movzx eax, word [es:VBE.modeInfo+18]
  mov [es:VBE.bootInfo+VBE.Boot.width], eax
  movzx eax, word [es:VBE.modeInfo+20]
  mov [es:VBE.bootInfo+VBE.Boot.height], eax
  movzx eax, word [es:VBE.modeInfo+16]
  mov [es:VBE.bootInfo+VBE.Boot.pitch], eax
  movzx eax, byte [es:VBE.modeInfo+25]
  mov [es:VBE.bootInfo+VBE.Boot.bpp], eax
  mov eax, [es:VBE.modeInfo+40]
  mov [es:VBE.bootInfo+VBE.Boot.physical], eax
  mov eax, [es:VBE.bootInfo+VBE.Boot.pitch]
  mul dword [es:VBE.bootInfo+VBE.Boot.height]
  add eax, PAGE_SIZE-1
  shr eax, 12
  mov [es:VBE.bootInfo+VBE.Boot.pages], eax
.done:
  pop fs
  pop es
  pop di
  pop si
  pop dx
  pop cx
  pop bx
  pop ax
  ret

;// Таблица дескрипторов сегментов для 32-битного кода
align 16
GDT32:
  dq 0                  ;// NULL - 0
  dq 0x00CF9A000000FFFF ;// CODE - 8  (32-bit)
  dq 0x00CF92000000FFFF ;// DATA - 16 (32-bit)
GDTR32:
  dw $ - GDT32 - 1
  dd GDT32

;// Шаблон 64-битной GDT (будет скопирован в GDT64.base = 0x2DF000).
;// Дескриптор 64-битного TSS занимает две соседние 8-байтовые записи.
align 8
GDT64_SRC:
  dq 0                     ;// NULL   (0x00)
  dq 0x00CF9A000000FFFF    ;// code32 (0x08)
  dq 0x00CF92000000FFFF    ;// data32 (0x10)
  dq 0x00209A000000FFFF    ;// code64 (0x18) - L=1
  dq 0x00CF92000000FFFF    ;// data64 (0x20)
  dq 0x00CFF2000000FFFF    ;// user data64 (0x28), DPL=3
  dq 0x0020FA000000FFFF    ;// user code64 (0x30), DPL=3, L=1
  ;// TSS64 (селектор 0x38): limit, base, access=0x89, flags, base[63:32]
  dw  TSS64.size-1                         ;// Limit[15:0]
  dw  (HHDM.base+TSS64.base) mod 0x10000   ;// Base[15:0]
  db  ((HHDM.base+TSS64.base) shr 16) mod 0x100 ;// Base[23:16]
  db  0x89                                 ;// Present + available 64-bit TSS
  db  ((TSS64.size-1) shr 16) mod 0x10     ;// Flags=0, Limit[19:16]
  db  ((HHDM.base+TSS64.base) shr 24) mod 0x100 ;// Base[31:24]
  dd  (HHDM.base+TSS64.base) shr 32        ;// Base[63:32]
  dd  0                                    ;// Зарезервировано архитектурой
GDT64_SRC_END:
GDTR64:
  dw GDT64_SRC_END - GDT64_SRC - 1
  dd GDT64.base

;//-----Заполнитель 16-битной части до 0x1800-----
times BOOT2.pm32 - ($ - $$) db 0


;//=============================================================================================================
;// 32-БИТНАЯ ЧАСТЬ: 4-level paging, копирование ядра, GDT64/TSS64, переход в 64-bit

org BOOT2.offset + BOOT2.pm32
use32

stage32:
  ;// Инициализация сегментных регистров
  mov ax,  SEL.data32
  mov ds,  ax
  mov es,  ax
  mov fs,  ax
  mov gs,  ax
  mov ss,  ax
  mov esp, BOOT2.stack32     ;// 32-битный стек (растёт вниз от 0x10000)
  cli

  ;// Настраиваем четырёхуровневые страничные таблицы.
  ;// Каждая таблица содержит 512 записей по 8 байт, поэтому очищаем
  ;// 1024 dword, а не 512 (это была ошибка ранней версии порта).
  mov eax, 0
  mov edi, PT.PML4
  mov ecx, 1024
  rep stosd
  mov edi, PT.PDPT_ID
  mov ecx, 1024
  rep stosd
  mov edi, PT.PDPT_HI
  mov ecx, 1024
  rep stosd
  mov edi, PT.PD_HI
  mov ecx, 1024
  rep stosd
  mov edi, PT.PD_ID
  mov ecx, 1024
  rep stosd
  ;// Identity и HHDM отображают одинаковые 0..1 GiB большими
  ;// страницами 2 MiB. U/S не установлен: ring 3 не видит HHDM.
  xor eax, eax
  mov edi, PT.PD_ID
  mov esi, PT.PD_HI
  mov ecx, PT.DIRECT_PAGES
  .fill_direct:
    mov edx, eax
    or edx, PAGE.P+PAGE.RW+PAGE.PS
    mov [edi], edx
    mov [esi], edx
    add eax, PAGE_SIZE_2M
    add edi, 8
    add esi, 8
    loop .fill_direct
  mov dword [PT.PDPT_ID+0], PT.PD_ID + PAGE.P+PAGE.RW
  mov dword [PT.PDPT_HI+0], PT.PD_HI + PAGE.P+PAGE.RW

  ;// PML4: identity (0) и верхняя половина (256)
  mov dword [PT.PML4+0],    PT.PDPT_ID + PAGE.P+PAGE.RW
  mov dword [PT.PML4+2048], PT.PDPT_HI + PAGE.P+PAGE.RW   ;// 256*8

  ;// Копируем ядро до включения paging: оба адреса пока обычные физические.
  mov esi, KERNEL.tempBase
  mov edi, KERNEL.physBase
  mov ecx, KERNEL.size/4
  rep movsd

  ;// Архив пользовательских ELF не является частью ядра и остаётся
  ;// read-only bootstrap-данными. Его адрес зарезервирован ниже PMM.memStart.
  mov esi, INITRAMFS.tempBase
  mov edi, INITRAMFS.physBase
  mov ecx, INITRAMFS.size/4
  rep movsd

  ;// Long mode требует PAE, EFER.LME и paging — именно в таком порядке.
  mov eax, PT.PML4
  mov cr3, eax
  mov eax, cr4
  or  eax, 1 shl 5        ;// CR4.PAE = 1
  mov cr4, eax
  mov ecx, 0xC0000080     ;// IA32_EFER
  rdmsr
  or  eax, 1 shl 8        ;// EFER.LME = 1
  wrmsr
  mov eax, cr0
  or  eax, 0x80010000     ;// CR0.PG + CR0.WP
  mov cr0, eax

  ;// Копируем 64-битную GDT в GDT64.base
  ;// В 32-битном режиме копируем dword; размер GDT кратен четырём.
  mov esi, GDT64_SRC
  mov edi, GDT64.base
  mov ecx, GDT64.size/4
  rep movsd

  ;// Заполняем TSS64. В 64-битном TSS RSP0 начинается с +4, IST1 — с +36.
  mov ecx, TSS64.size/4
  mov edi, TSS64.base
  mov eax, 0
  rep stosd
  mov dword [TSS64.base+4],  STACK.rspLo   ;// RSP0, младшие 32 бита
  mov dword [TSS64.base+8],  STACK.rspHi   ;// RSP0, старшие 32 бита
  mov dword [TSS64.base+36], IST.rspLo     ;// IST1, младшие 32 бита
  mov dword [TSS64.base+40], IST.rspHi     ;// IST1, старшие 32 бита
  mov word  [TSS64.base+102], TSS64.iopb   ;// конец I/O bitmap

  ;// GDTR можно загрузить до дальнего перехода; TR загрузим уже в long mode.
  lgdt [GDTR64]

  ;// Заполняем блок данных трамплина (entry + rsp)
  mov dword [BOOT2.offset+BOOT2.data+0],  KERNEL.entryLo
  mov dword [BOOT2.offset+BOOT2.data+4],  KERNEL.entryHi
  mov dword [BOOT2.offset+BOOT2.data+8],  STACK.rspLo
  mov dword [BOOT2.offset+BOOT2.data+12], STACK.rspHi

  ;// Дальний переход на 64-битный трамплин (адрес = 0x1F00, identity-карта)
  jmp fword SEL.code64:tramp64

;//-----Заполнитель 32-битной части до 0x1F00-----
;// ($-$$) = смещение внутри 32-битной части (org 0x1800), а не в странице,
;// поэтому цель относительная: BOOT2.tramp - BOOT2.pm32 = 0x700
times (BOOT2.tramp - BOOT2.pm32) - ($ - $$) db 0


;//=============================================================================================================
;// 64-БИТНЫЙ ТРАМПЛИН (физ. 0x1F00, identity-карта)
;// Загружает RSP из блока данных и переходит по вирт. адресу KERNEL.entry

org BOOT2.offset + BOOT2.tramp
use64

tramp64:
  mov ax, SEL.data64
  mov ds, ax
  mov es, ax
  mov ss, ax
  mov fs, ax
  mov gs, ax
  mov ax, SEL.tss
  ltr ax
  mov rsp, [BOOT2.offset+BOOT2.data+8]   ;// RSP = STACK.rsp
  mov rax, [BOOT2.offset+BOOT2.data+0]   ;// RAX = KERNEL.entry
  jmp rax                                ;// переход в ядро (64-bit)

;//-----Блок данных трамплина (16 байт, физ. 0x1F40)-----
times (BOOT2.data - BOOT2.tramp) - ($ - $$) db 0
times 16 db 0

;//-----Заполнитель до конца 4 KiB страницы-----
times (BOOT2.size - BOOT2.tramp) - ($ - $$) db 0
