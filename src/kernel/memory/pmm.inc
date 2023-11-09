;///////////////////////////////////////////////////////////////
;// Copyright (c) Varania OS team 2019. All rights reserved.  //
;// Distributed under terms of the GNU General Public License //
;// Physic Memory Manager - Менеджер физической памяти        //
;// Дата: 25.07.2019                                          //
;///////////////////////////////////////////////////////////////

pmm.MEM_SIZE = 33554432 ;// 32МБ
pmm.FRAME_SIZE = 4096   ;// 4КБ
pmm.MAX_FRAMES_COUNT = pmm.MEM_SIZE/pmm.FRAME_SIZE ;// Количество фреймов в 4Гб

pmm.frames.size = pmm.MAX_FRAMES_COUNT/8 ;// Размер битовой карты памяти = кол. страниц / кол. страниц в 1 байте
pmm.frames = KERNEL.bitmapFrames ;// Битовая карты памяти
pmm.memoryStart dd 0 ;// Адрес начала доступной памяти
pmm.memorySize  dd 0 ;// Размер ОЗУ
pmm.memoryFree  dd 0 ;// Размер свободной памяти

;// Инициализация менеджера памяти
macro pmm.init
{
  pushad
  ;// Пометить 4ГБ страниц как занятые
  com.memsetd pmm.frames, 0xFFFFFFFF, pmm.MAX_FRAMES_COUNT/32  
  ;// Получить информацию о начале свободной памяти и ее размер
  pmm.getMemoryInfo 
  ;// Разметить свободную область в битовой карте памяти
  mov ecx, [pmm.memoryFree]      ;// Размер доступной памяти
  shr ecx, 12                    ;// делим на pmm.FRAME_SIZE, получаем кол. доступных фреймов
  pmm.freeFrame [pmm.memoryStart], ecx
  popad
}

;// Разбирает карту памяти полученную от BIOS.
macro pmm.getMemoryInfo
{
  FREE_MEM_START = KERNEL.physBase+KERNEL.size
  mov [pmm.memoryStart], dword FREE_MEM_START ;// Свободная память начинается с этого адреса
  mov [pmm.memorySize] , dword pmm.MEM_SIZE   ;// Обьем ОЗУ
  mov [pmm.memoryFree] , dword pmm.MEM_SIZE-FREE_MEM_START ;// Доступно ОЗУ
}

macro pmm.firstFrame
{ stdcall pmm_firstFrame }

macro pmm.allocFrame
{ stdcall pmm_allocFrame }

macro pmm.freeFrame _frame, _count=1
{ stdcall pmm_freeFrame, _frame, _count}

macro pmm.getMemorySize
{ stdcall pmm_getMemorySize }

macro pmm.getMemoryFree
{ stdcall pmm.getMemoryFree }

;// ПРОЦЕДУРЫ =================================================================

;// Возвращает номер первого свободного фрейма
align 4
proc pmm_firstFrame uses not_eax
  clr edx                         ;// EDX = 0
  mov ecx, pmm.MAX_FRAMES_COUNT   ;// Кол. чтений 
  .READ_FRAME:
    com.bmpGetBit pmm.frames, edx ;// EAX = бит номер EDX из битовой карты
    .if eax = 0                   ;// Если бит сброшен то фрейм свободен,
        return edx                ;// возвращаем номер этого фрейма
    .endif
    inc edx                       ;// Переходим к следующему фрейму
    loop .READ_FRAME
  return 0                        ;// Не найдено ни одного свободного фрейма
endp

;// Выделить фрейм памяти
align 4
proc pmm_allocFrame uses all_regs
  ;// Проверяем осталась ли свободная память
  .if [pmm.memoryFree] < pmm.FRAME_SIZE ;// Если не осталась то сообщаем об этом
    pt.clear pt.RED, pt.WHITE
    pt.print 's', "Not free memory!", pt.END_LN
    com.stop
  .endif
  
  pmm.firstFrame                       ;// EAX = firstFrame. Ищем первый попавшийся свободный фрейм
  com.bmpSetBit pmm.frames, eax, 1     ;// Помечам свободный фрейм как занятый
  shl eax, 12                          ;// Получам адрес фрейма. адрес = номер фрейма * размер фрейма
  sub [pmm.memoryFree], pmm.FRAME_SIZE ;// Уменьшаем свободную память на размер фрейма
  return eax
endp

;// Освободить фрейм памяти
align 4
proc pmm_freeFrame uses all_regs, _frame: addr, _count: dword
  mov ecx, [_count] ;// Количество фреймов
  .FREE:
    mov eax, [_frame]
    shr eax, 12                          ;// Получам номер фрейма. номер = адрес фрейма / размер фрейма
    com.bmpSetBit pmm.frames, eax, 0     ;// Помечам фрейм как свободный
    add [pmm.memoryFree], pmm.FRAME_SIZE ;// Увеличиваем свободную память на размер фрейма
    add [_frame], pmm.FRAME_SIZE         ;// Переход к следующнму фрейму
    loop .FREE
  ret
endp

;// Вернуть обьем ОЗУ
align 4
proc pmm_getMemorySize
  return [pmm.memorySize]
endp

;// Вернуть размер свободной памяти
align 4
proc pmm_getMemoryFree
  return [pmm.memoryFree]
endp












