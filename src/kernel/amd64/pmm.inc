;//////////////////////////////////////////////////////////////////////////////
;// PMM — менеджер физических кадров памяти
;//////////////////////////////////////////////////////////////////////////////
;
;// Один бит карты соответствует одному физическому кадру 4 KiB:
;//   0 — кадр свободен, 1 — занят.
;// Сначала вся карта заполняется единицами. Затем только области E820 типа 1
;// (usable) освобождаются, а страницы ядра и служебных структур резервируются
;// повторно. Такой порядок безопасен даже при неполной или необычной карте BIOS.

pmm_free_count  dq 0
pmm_search_from dd PMM.memStart/PAGE_SIZE
pmm_max_frame   dd PMM.frames

;// Инициализировать карту кадров из буфера BIOS E820.
pmm_init:
  push rbx
  push r12
  push r13
  push r14
  push r15

  ;// По умолчанию вся память занята.
  mov rdi, PMM.bitmap
  mov rax, -1
  mov ecx, PMM.bitmapSize/8
  cld
  rep stosq
  mov qword [pmm_free_count], 0

  mov r13, SMAP.count
  mov r12d, [r13]
  cmp r12d, (SMAP.size-4)/24
  jbe .count_ok
  mov r12d, (SMAP.size-4)/24
  .count_ok:
  mov r13, SMAP.entries
  mov rbx, PMM.bitmap

  .entry_loop:
    test r12d, r12d
    jz .reserve_kernel
    cmp dword [r13+16], 1          ;// E820 type 1 = usable RAM
    jne .next_entry

    mov r14, [r13]                 ;// начало области
    mov r15, [r13+8]               ;// длина области
    test r15, r15
    jz .next_entry
    add r15, r14                   ;// адрес первого байта за областью
    jc .clamp_end                  ;// переполнение означает «выше лимита»
    jmp .align_range
  .clamp_end:
    mov r15, PMM.memEnd

  .align_range:
    add r14, PAGE_SIZE-1
    and r14, -PAGE_SIZE            ;// первый целый кадр внутри области
    and r15, -PAGE_SIZE            ;// конец округляем вниз
    cmp r14, PMM.memStart
    jae .start_ok
    mov r14, PMM.memStart
  .start_ok:
    cmp r15, PMM.memEnd
    jbe .end_ok
    mov r15, PMM.memEnd
  .end_ok:
    cmp r14, r15
    jae .next_entry

  .free_frame:
    mov rax, r14
    shr rax, 12
    btr qword [rbx], rax
    jnc .already_free
    inc qword [pmm_free_count]
  .already_free:
    add r14, PAGE_SIZE
    cmp r14, r15
    jb .free_frame

  .next_entry:
    add r13, 24
    dec r12d
    jmp .entry_loop

  .reserve_kernel:
    mov edi, PMM.resv.heapLo
    mov esi, PMM.resv.heapHi
    call pmm_reserve_frames
    mov edi, PMM.resv.svcLo
    mov esi, PMM.resv.svcHi
    call pmm_reserve_frames
    mov edi, PMM.resv.bitmapLo
    mov esi, PMM.resv.bitmapHi
    call pmm_reserve_frames

  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Пометить занятыми кадры EDI..ESI включительно.
pmm_reserve_frames:
  mov rdx, PMM.bitmap
  mov eax, edi
  .loop:
    cmp eax, esi
    ja .done
    bts qword [rdx], rax
    jc .was_reserved
    dec qword [pmm_free_count]
  .was_reserved:
    inc eax
    jmp .loop
  .done:
  ret

;// Выделить один физический кадр. Возврат: RAX = физический адрес или 0.
pmm_alloc_frame:
  mov rdx, PMM.bitmap
  mov eax, [pmm_search_from]
  mov ecx, [pmm_max_frame]
  .scan:
    cmp eax, ecx
    jae .out_of_memory
    bt qword [rdx], rax
    jnc .found
    inc eax
    jmp .scan
  .found:
    bts qword [rdx], rax
    dec qword [pmm_free_count]
    lea edx, [eax+1]
    mov [pmm_search_from], edx
    shl rax, 12
    ret
  .out_of_memory:
    xor eax, eax
    ret

;// Освободить физический кадр RDI. Невыровненные и служебные адреса
;// игнорируются, чтобы одна ошибка вызывающего кода не повредила PMM.
pmm_free_frame:
  test rdi, PAGE_SIZE-1
  jnz .done
  cmp rdi, PMM.memStart
  jb .done
  cmp rdi, PMM.memEnd
  jae .done
  mov rax, rdi
  shr rax, 12
  mov rdx, PMM.bitmap
  btr qword [rdx], rax
  jnc .done
  inc qword [pmm_free_count]
  cmp eax, [pmm_search_from]
  jae .done
  mov [pmm_search_from], eax
  .done:
  ret
