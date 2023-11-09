;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// BOOT - Загрузчик Varania OS         //
;// Дата: 30.07.2019                                          //
;///////////////////////////////////////////////////////////////

format Binary as ""

use16 ;// 16-ти битный код

;// Используем смещение для расчёта меток программы
org 0x7C00

;// Обычно, после первых 3-4 байт загрузчика размещается заголовок некоторых файловых систем (например, FAT), 
;// поэтому первым делом мы обходим все данные и прыгаем на истинную точку входа начального загрузчика. 
;// Специальное слово word говорит flat assembler не пытаться оптимизировать размер перехода и в любом случае 
;// положить адрес перехода в 2 байта, даже если можно в 1. Таким образом наш jmp должен гарантированно занять 3 байта и nop не понадобиться

jmp word BOOT ;// сылка на загрузочный код 3 байта
;// nop

;// ПОДКЛЮЧЕНИЯ

include "../const.inc"
include "disk.inc"

;// ПЕРЕМЕННЫЕ

disk_id db ? ;// диск с которого произведена загрузка

BOOT:
  ;// Инициализация сегментных регистров
  cli               ;// Запретить прерывания для смены адресов в сегментных регистрах
  ; cs=0
  xor  ax, ax       ;// ах = 0
  mov  ss, ax       ;// ss = 0 (Сегмент стека)
  mov  sp, 0x7C00   ;// Указатель стека
  push ax                     
  pop  es           ;// es = 0 (Дополнительный сегмент данных)
  push ax   
  pop  ds           ;// ds = 0 (Сегмент данных)
  sti               ;// Разрешить прерывания (после изменения адресов)

  mov [disk_id], dl ;// Сохранить номер диска с которого загрузились

  ;// Дозагрузка загрузчика
  ;// Параметры: disk_id, sec_h_id, sec_l_id, sec_count, buff_addr 
  disk.load_sectors [disk_id], 0, 1, BOOT2.size/512, BOOT2.base ;// Загрузить продолжение загрузчика

  jmp fword BOOT2.segment:BOOT2.offset ;// Переход на продолжение загрузчика

;//-----Заполнитель-----
;// Заполняем оставшееся место до 510 байт нулями
times 510 - ($ - $$) db 0 ;// $  = адрес текущей инструкции
                          ;// $$ = адрес 1-й инструкции

;// Последние два байти 511-тый и 512-тый
dw 0xAA55 ;// сигнатура загрузочного сектора  

;//=============================================================================================================
org BOOT2.offset

jmp BOOT2.start
  
include "../kernel/memory/meminfo.inc"

;// Таблица дескрипторов сегментов для 32-битного кода
align 16
GDT32:
  dq 0                  ;// NULL - 0
  dq 0x00CF9A000000FFFF ;// CODE - 8
  dq 0x00CF92000000FFFF ;// DATA - 16
GDTR32:
  dw $ - GDT32 - 1
  dd GDT32

BOOT2.start:
  ;// Инициализация сегментных регистров
  cli                           ;// Запретить прерывания для смены адресов в сегментных регистрах
  ;// cs=0
  mov  ax, BOOT2.segment 
  mov  ss, ax                   ;// Сегмент стека
  mov  sp, BOOT2.offset ;// Указатель стека
  push ax                     
  pop  es                       ;// Дополнительный сегмент данных
  push ax   
  pop  ds                       ;// Сегмент данных
  sti  
  
  ;// Очистка экрана
  mov ax, 0x02 ;// Очищаем экран - функция 02h прерывания 10h 
  int 0x10
  
  ;// Скрыть курсор
  ;//mov ah, 01h ; уст. размер/форму курсора (текст).
  ;//mov ch, 20h ; подавить курсор
  ;//int 10h
  
  ;// Открыть адресную линию A20 (чтобы была доступна вся память).
  in al, 0x92  ;// Читаем содержимое порта 0х92
  or al, 2     ;// Устанавливаем второй бит
  out 0x92, al ;// Записываем обратно в порт 0х92
  
  ;// Загрузка ядра
  ;// Параметры: disk_id, h_sec_id, l_sec_id, sec_count, buff_addr 
  disk.load_sectors [disk_id], 0, KERNEL.firstSector, KERNEL.size/512, KERNEL.tempBase ;// Загрузить ядро
  
  meminfo.get_smap SMAP.segment, SMAP.offset;// Получаем от BIOS карту памяти

  ;// Загрузим значение в GDTR
  lgdt [GDTR32]

  ;// Запрет всех прерываний
  cli ;// Запретить аппаратные прерывания
  ;// запрет NMI
  in   al, 0x70
  or   al, 0x80
  out  0x70, al
  
  ;// Переключаемся в защищенный режим.
  mov eax, cr0 
  or al, 1     ;// устанавливаем 0-вой бит
  mov cr0, eax ;// включаем PM
  
  ;// Перейдём на 32-битный код
  jmp fword SEL_CODE:START32

;// ==============================================================================================

use32

START32:
  ;// Инициализируем сегментные регистры, помещая в них селекторы
  mov ax,  SEL_DATA    ;// Сегмент данных
  mov ds,  ax          ;// ds = SELECTOR_DATA
  mov es,  ax  
  mov fs,  ax          ;// fs = SELECTOR_DATA
  mov ax,  ax          ;// сегмент стека
  mov ss,  ax          ;// ss = SELECTOR_STACK
  mov esp, BOOT2.stack ;// Стек
  
  ;// Настраиваем и включаем страничную адресацию
  ;// Очищаем каталог страниц
  mov eax, 0
  mov edi, KERNEL.physDirPages
  mov ecx, 1024
  rep stosd
  
  ;// Монтируем первый мегабайт
  mov [KERNEL.physDirPages], dword ONE_MB_TABLE_PAGES+111b ;// Вписываем таблицу в каталог
  ;// Заполним первую таблицу страниц
  mov eax, 11b
  mov ecx, 0x100000/PAGE_SIZE ;// 1MB / page_size = 256 стр.
  mov edi, ONE_MB_TABLE_PAGES
  @@:
    stosd
    add eax, 0x1000
    loop @b

  ;// Монтируем физ. память начиная с KERNEL.physBase (код ядра) по вирт. адресу KERNEL.base
  mov [KERNEL.physDirPages+(KERNEL.base shr 22)*4], dword KERNEL.physTablePages+111b ;// Вписываем таблицу в каталог
  ;// Заполняем последнюю таблицу
  mov eax, KERNEL.physBase+11b
  mov ecx, 0x400000/PAGE_SIZE ;// 4MB / page_size
  mov edi, KERNEL.physTablePages
  @@:
    stosd
    add eax, 0x1000
    loop @b
    
  ;// Устанавливаем текущий каталог таблиц страниц
  mov eax, KERNEL.physDirPages
  mov cr3, eax
  
  ;// Включаем страничную адресацию
  mov eax, cr0
  or  eax, 0x80000000 ;// установка  бита  PG=1
  mov cr0, eax 
  
  ;// копируем ядро по вирт. адресу KERNEL.base
  mov esi, KERNEL.tempBase ;// Источник
  mov edi, KERNEL.base     ;// Назначение
  mov ecx, KERNEL.size     ;// Размер
  rep movsb
  
  ;// Устанавливаем новый стек
  mov esp, KERNEL.stack 
  ;// Передаем управление ядру
  jmp KERNEL.base           
  
;//-----Заполнитель-----
;// Заполняем оставшееся место до 4096 байт нулями
times BOOT2.size - ($ - $$) db 0 ;// $  = адрес текущей инструкции
                                 ;// $$ = адрес 1-й инструкции
     
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      
                                      