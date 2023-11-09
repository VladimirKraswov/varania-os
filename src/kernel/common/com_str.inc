
;// МАКРООБЕРТКИ ===========================================================================================

macro com.strcat dst_str, src_str
{ stdcall com_strcat, dst_str, src_str }

macro com.strchr _str, _char
{ stdcall com_strchr, _str, _char }

macro com.strcmp _str_1, _str_2
{ stdcall com_strcmp, _str_1, _str_2 }

macro com.strcpy _dst, _src
{ stdcall com_strcpy, _dst, _src }

macro com.strncpy _dst, _src, _max_count
{ stdcall com_strncpy, _dst, _src, _max_count}

macro com.strlen _str
{ stdcall com_strlen, _str}

macro com.intToBinStr _integer, _strBuff
{ stdcall com_intToBinStr, _integer, _strBuff }

macro com.intToHexStr _integer, _strBuff
{ stdcall com_intToHexStr, _integer, _strBuff }

macro com.intToUdecStr _integer, _strBuff
{ stdcall com_intToUdecStr, _integer, _strBuff }

;// ПРОЦЕДУРЫ ============================================================================================

;// Объединение строк. Функция добавляет копию строки stc_str в конец строки dst_str. 
;// Нулевой символ конца строки destptr заменяется первым символом строки srcptr, 
;// и новый нуль-символ добавляется в конец уже новой строки, 
;// сформированной объединением символов двух строк в строке destptr.
align 4
proc com_strcat dst_str: addr, src_str: addr
  com.strchr [dst_str], 0   ;// eax = strchr
  com.strcpy eax, [src_str]
  ret
endp

;// Функция strchr выполняет поиск первого вхождения символа symbol в строку string. 
;// Возвращает указатель на первое вхождение символа в строке. 
;// Завершающий нулевой символ считается частью Си-строки. 
;// Таким образом, он также может быть найден для получения указателя на конец строки.
align 4
proc com_strchr _str: addr, _char: dword
  ;// return memchr(str, value, strlen(str)+1)
  com.strlen [_str]               ;// eax = strlen
  inc eax                              ;// + завершающий 0 символ
  com.memchr [_str], [_char], eax ;// eax = memchr
  return eax
endp

;// Функция strcmp() осуществляет лексикографическую проверку двух строк, 
;// оканчивающихся нулевыми символами, и возвращает целое число со следующим значением
;// < 0 - str1 меньше, чем str2, 0 - str1 равна str2, > 0 - str1 больше, чем str2
align 4
proc com_strcmp _str_1: addr, _str_2: addr
  ;// return memcmp(str1, str2, strlen(str1) + 1)
  com.strlen [_str_1]                ;// eax = strlen
  inc eax
  com.memcmp [_str_1], [_str_2], eax ;// eax = memcmp
  return eax
endp

;// копирует строку из одного места в другое 
align 4
proc com_strcpy uses eax, _dst: addr, _src: addr
  com.strlen [_src]               ;// eax = strlen
  inc eax
  com.memcpy [_dst], [_src], eax
  ret
endp

;// Функция для копирования содержимого нуль-терминированной строки в буфер ограниченного размера.
;// Функция strncpy аналогична strcpy с защитой от переполнения буфера. 
align 4
proc com_strncpy uses eax edi, _dst: addr, _src: addr, _max_count: size_t
  ;//  size_t len = min(_max_cnt - 1, strlen(_src));
  dec [_max_count]                    ;// _max_cnt = _max_cnt- 1
  com.strlen [_src]              ;// eax = strlen(src)    
  com.min [_max_count], eax      ;// eax = min(_max_cnt - 1, strlen(_src))
  ;//  memcpy(_dst, _src, len);
  mov edi, [_dst]                     ;// edi = destination
  com.memcpy [_dst], [_src], eax ;// memcpy(dest, src, len);
  ;// _dst[len] = '\0';
  mov [edi + eax], dword 0         
  ret
endp

;// Возвращает длину строки 
align 4
proc com_strlen _str: addr
  com.memchr [_str], 0, -1 ;// eax = memchr
  sub eax, [_str]
  return eax
endp

;// ПРЕОБРАЗОВАНИЯ==================================================================================================================

;// Процедура преобразования числа в строку в двоичном виде
proc com_intToBinStr uses all_regs, _integer: dword, _strBuff: addr
  mov eax, [_integer]
  mov esi, [_strBuff]
  mov ecx, 32         ;// Счётчик цикла
 
  btbs_lp:
    rol eax, 1          ;// Циклический сдвиг EAX влево на 1 бит
    jc btbs_1           ;// Если выдвинутый бит = 1, то переход
    mov [esi], byte '0' ;// Добавление символа '0' в строку
    jmp btbs_end
  btbs_1:
    mov [esi], byte '1' ;// Добавление символа '1' в строку
  btbs_end:
    inc esi            ;// Инкремент SI
    loop btbs_lp       ;// Команда цикла
    
    mov [esi], byte 0
    ret                ;// Возврат из процедуры
endp
    
;// Процедура преобразования числа (0-15) в шестнадцатеричную цифру
;// вход : AL - число (0-15)
;// выход: AL - шестнадцатеричная цифра ('0'-'F')
com_intToHexDigit:
    add al, '0'  ;// Прибавляем символ '0' (код 0x30)
    cmp al, '9'  ;// Сравнение с символом '9' (код 0x39)
    jle thd_end  ;// Если получилось '0'-'9', то выход
    add al, 7    ;// Прибавляем ещё 7 для символов 'A'-'F'
thd_end:
    ret

;// Процедура преобразования байта в строку в шестнадцатеричном виде
proc com_intToHexStr uses all_regs, _integer: dword, _strBuff: addr
  mov ebx, [_integer]
  mov esi, [_strBuff]
  mov ecx, 4
  rol ebx, 8
  byteToStr:
    mov al, bl
    shr al, 4             ;// Выделение старшей тетрады
    call com_intToHexDigit ;// Преобразование в шестнадцатеричную цифру
    mov [esi], al         ;// Добавление символа в строку
    inc esi               ;// Инкремент DI
    mov al, bl            ;// Восстановление AL

    and al, 0Fh           ;// Выделение младшей тетрады
    call com_intToHexDigit ;// Преобразование в шестнадцатеричную цифру
    mov [esi], al         ;// Добавление символа в строку
    inc esi               ;// Инкремент DI

    rol ebx, 8
    loop byteToStr
  mov [esi], byte 0
  ret
endp
  
;// Процедура преобразования двойного слова в строку в десятичном виде (без знака)
proc com_intToUdecStr uses all_regs, _integer: dword, _strBuff: addr
  mov eax, [_integer]
  mov esi, [_strBuff]
  clr ecx         ;// Обнуление CX
  mov ebx, 10     ;// В BX делитель (10 для десятичной системы)
 
  @@:             ;// Цикл получения остатков от деления
    clr edx       ;// Обнуление старшей части двойного слова
    div ebx       ;// Деление AX=(DX:AX)/BX, остаток в DX
    add dl, '0'   ;// Преобразование остатка в код символа
    push edx      ;// Сохранение в стеке
    inc ecx       ;// Увеличение счетчика символов
    test eax, eax ;// Проверка AX
    jnz @b        ;// Переход к началу цикла, если частное не 0.
 
  @@:             ;// Цикл извлечения символов из стека
    pop edx       ;// Восстановление символа из стека
    mov [esi], dl ;// Сохранение символа в буфере
    inc esi       ;// Инкремент адреса буфера
    loop @b       ;// Команда цикла
    
    mov [esi], byte 0
    ret
endp