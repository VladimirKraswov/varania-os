
;// МАКРООБЕРТКИ ==========================================================================================

macro com.memcpy _dst, _src, _count
{ stdcall com_memcpy, _dst, _src, _count }

macro com.memcpyw _dst, _src, _count
{ stdcall com_memcpyw, _dst, _src, _count }

macro com.memchr _memory, _value, _count
{ stdcall com_memchr, _memory, _value, _count }

macro com.memcmp _memory1, _memory2, _count
{ stdcall com_memcmp, _memory1, _memory2, _count }

macro com.memset _dst, _value, _count
{ stdcall com_memset, _dst, _value, _count }

macro com.memsetw _dst, _value, _count
{  stdcall com_memsetw, _dst, _value, _count }

macro com.memsetd _dst, _value, _count
{  stdcall com_memsetd, _dst, _value, _count }

macro com.memmove _dst, _src, _count
{ stdcall com_memmove, _dst, _src, _count }

;// ПРОЦЕДУРЫ ========================================================================================== 

;// Копирует count байт из области памяти src в dst, которые не должны пересекаться, 
;// в противном случае результат не определён (возможно как правильное копирование, так и нет) 
align 4
proc com_memcpy uses all_regs, _dst: addr, _src: addr, _count: dword
  mov esi, [_src]
  mov edi, [_dst]
  mov ecx, [_count]
  rep movsb
  ret 
endp

proc com_memcpyw  uses all_regs, _dst: addr, _src: addr, _count: dword
  mov esi, [_src]
  mov edi, [_dst]
  mov ecx, [_count]
  rep movsw
  ret 
endp

;// поиск первого вхождения указанного символа в массиве.
;// Возвращаемое значение:
;// Указатель на найденный символ, если, на указанном участке массива, найден требуемый символ.
;// NULL – если требуемый символ не найден. 
align 4
proc com_memchr uses not_eax, _memory: addr, _value: dword, _count: dword
  clr eax
  mov edi, [_memory]
  mov eax, [_value]
  mov ecx, [_count]
  repne scasb
  jne .not_found
  dec edi
  mov eax, edi
  jmp .exit
  .not_found:
    return 0
  .exit:
    return eax 
endp

;// Сравнивает первые n символов в областях памяти. Возвращает 1 если память не равна, 0 если равна
align 4
proc com_memcmp uses not_eax, _memory1: addr, _memory2: addr, _count: dword
  mov edi, [_memory1]
  mov esi, [_memory2]
  mov ecx, [_count]
  repe cmpsb
  seta al
  setb dl
  sub al, dl
  movzx eax, al
  not eax
  shl eax, 31
  shr eax, 31
  return eax
endp

;// void *memmove(void *, const void *, size_t);

;// Заполняет область памяти значением value 
align 4
proc com_memset uses all_regs, _dst: addr, _value: dword, _count: dword
  mov edi, [_dst]
  mov edx, [_value]
  mov al, dl
  shl eax, 8
  mov al, dl
  shl eax, 8
  mov al, dl
  shl eax, 8
  mov al, dl
  mov edx, [_count]
  mov ecx, edx
  shr ecx, 2
  rep stosd
  mov ecx, edx
  and ecx, 3
  rep stosb
  ret
endp

;// Заполняет область памяти словом value 
align 4
proc com_memsetw uses all_regs, _dst: addr, _value: dword, _count: dword
  mov edi, [_dst]
  mov edx, [_value]
  mov ax, dx
  shl eax, 16
  mov ax, dx
  mov edx, [_count]
  mov ecx, edx
  shr ecx, 1
  rep stosd
  mov ecx, edx
  and ecx, 1
  rep stosw
  ret
 endp

;// Заполняет область памяти словом value 
align 4
proc com_memsetd uses all_regs, _dst: addr, _value: dword, _count: dword
  mov edi, [_dst]  
  mov eax, [_value]  
  mov ecx, [_count] 
  rep stosd   
  ret
endp


;// void movmem(const void *source, void *dest, unsigned count)
;// void _fmovmem(const void far *source, void far *dest, unsigned count)
;// void movedata(unsigned sourceseg, unsigned sourceoff, unsigned destseg, unsigned destoff, size_t count)
;// void far * far _fmemset(void far *buf, int ch, size_t count)

;// Функция memmove копирует n байт из массива (области памяти), 
;// на который указывает аргумент source, в массив (область памяти), 
;// на который указывает аргумент destination. При этом массивы (области памяти) могут пересекаться. 
align 4
proc com_memmove uses all_regs, _dst: addr, _src: addr, _count: dword
  mov edi, [_dst]  
  mov esi, [_src]  
  mov ecx, [_count]  
  
  cmp esi, edi
  jae .label
  lea edi, [edi + ecx - 1]
  lea esi, [esi + ecx - 1]
  std  
 
  .label:
    rep movsb
    cld      
    ret
endp

;// void far *_fmemmove(void far *dest, const void far *source, size_t count)
;// void far * far _fmemcpy(void far *dest, const void far *source, size_t count)
;// int memicmp(const void *buf1, const void *buf2, size_t count)
;// int far_memcmp(const void far *buf1, const void far *buf2, size_t count)
;// int far_memicmp(const void far *buf1, const void far *buf2, size_t count)