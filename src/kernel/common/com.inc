
macro com.stop
{
  hlt
  jmp $
}

macro com.min _a, _b
{ stdcall com_min, _a, _b}

macro com.max _a, _b
{ stdcall com_max, _a, _b}

macro com.bmpSetBit _bitmap, _index, _value
{ stdcall com_bmpSetBit, _bitmap, _index, _value }
  
macro com.bmpGetBit _bitmap, _index
{ stdcall com_bmpGetBit, _bitmap, _index }

macro com.getBit _src, _index
{ stdcall com_getBit, _src, _index }

;// ПРОЦЕДУРЫ =========================================================

;// Меньшее число
align 4
proc com_min _a: dword, _b: dword
  mov eax, [_a]
  .if [_b] < eax
    return [_b]
  .else
    return [_a]
  .endif
  ret
endp  

;// Большее число
align 4
proc com_max _a: dword, _b: dword
  mov eax, [_a]
  .if [_b] > eax
    return [_b]
  .else
    return [_a]
  .endif
  ret
endp

;// Залержка
macro com.wait _value
{
  local ..b
  push ecx
  mov ecx, _value*2000
  ..b:
    nop
    loop ..b
  pop ecx
}

;// Установить/Снять бит в битовой карте
proc com_bmpSetBit uses all_regs, _bitmap: addr, _index: dword, _value: dword
  clr edx            ;// Старшая часть делимого
  mov eax, [_index]  ;// Номер бита
  mov ebx, 32        ;// Делим номер бита на количество бит в одной выборке
  div bx             ;// Получаем в eax номер выборки, а в edx номер бита в выборке
  shl eax, 2         ;// Умножаем номер выборки на 4 (кол. байт в одной выборке)
  add eax, [_bitmap] ;// Прибавляем к адресу битовой карты номер выборки
  mov ebx, [eax]     ;// Выбираем 32 страницы

 .if [_value] = 0
    btr ebx, edx     ;// Устанавливаем бит в выборке по номеу бита в выборке    
  .else
    bts ebx, edx     ;// Сбрасываем бит в выборке по номеу бита в выборке    
  .endif

  mov [eax], ebx 
  ret
endp

;// Получить значения бита в битовой карте
proc com_bmpGetBit uses not_eax, _bitmap: addr, _index: dword
  clr edx            ;// Старшая часть делимого
  mov eax, [_index]  ;// Номер бита
  mov ebx, 32        ;// Делим номер бита на количество бит в одной выборке
  div bx             ;// Получаем в eax номер выборки, а в edx номер бита в выборке
  shl eax, 2         ;// Умножаем номер выборки на 4 (кол. байт в одной выборке)
  add eax, [_bitmap] ;// Прибавляем к адресу битовой карты номер выборки
  mov ebx, [eax]     ;// Выбираем 32 страницы    
  bt ebx, edx        ;// Проверка бита номер edx
  jc .RETURN_TRUE    ;// Если бит установлен вернем true
  return false       ;// иначе false
  .RETURN_TRUE:
    return true  
endp

;// Получить значения бита в регистре или переменной
proc com_getBit uses edx, _src: dword, _index: dword
  mov eax, [_src]
  mov edx, [_index] 
  bt eax, edx     ;// Проверка бита
  jc .RETURN_TRUE ;// Если бит установлен вернем true
  return false    ;// иначе false
  .RETURN_TRUE:
    return true  
endp
    
include "com_mem.inc"
include "com_str.inc"









