;//////////////////////////////////////////////////////////////////////////////
;// PMM — менеджер физических кадров 4 KiB
;//////////////////////////////////////////////////////////////////////////////
;
;// Один бит bitmap описывает один физический кадр:
;//   0 — свободен; 1 — занят.
;// Ядро никогда обращается к физическому адресу напряму: bitmap и E820
;// доступны через HHDM. Это важно после переключения CR3 на адресное
;// пространство пользовательской задачи.

pmm_free_count  dq 0
pmm_search_from dd PMM.memStart/PAGE_SIZE
pmm_max_frame   dd PMM.frames

function pmm_init
  push rbx
  push r12
  push r13
  push r14
  push r15

  ;// Безопасный старт: считаем всё занятым, затем освобождаем только
  ;// целые страницы из E820 type=1 выше bootstrap-резерва 5 MiB.
  hhdm_address rdi, PMM.bitmap
  mov rax, -1
  mov ecx, PMM.bitmapSize/8
  cld
  rep stosq
  mov qword [pmm_free_count], 0

  hhdm_address r13, SMAP.count
  mov r12d, [r13]
  cmp r12d, (SMAP.size-4)/24
  jbe .count_is_valid
  mov r12d, (SMAP.size-4)/24
  .count_is_valid:
  hhdm_address r13, SMAP.entries
  hhdm_address rbx, PMM.bitmap

  .next_region:
    test r12d, r12d
    jz .done
    cmp dword [r13+16], 1
    jne .advance

    mov r14, [r13]                 ;// начало usable-области
    mov r15, [r13+8]
    test r15, r15
    jz .advance
    add r15, r14                   ;// первый байт за областью
    jc .clamp_end
    jmp .align_region
  .clamp_end:
    mov r15, PMM.memEnd

  .align_region:
    add r14, PAGE_SIZE-1
    and r14, -PAGE_SIZE
    and r15, -PAGE_SIZE
    cmp r14, PMM.memStart
    jae .start_ok
    mov r14, PMM.memStart
  .start_ok:
    cmp r15, PMM.memEnd
    jbe .end_ok
    mov r15, PMM.memEnd
  .end_ok:
    cmp r14, r15
    jae .advance

  .free_one:
    mov rax, r14
    shr rax, 12
    btr qword [rbx], rax
    jnc .was_free
    inc qword [pmm_free_count]
  .was_free:
    add r14, PAGE_SIZE
    cmp r14, r15
    jb .free_one

  .advance:
    add r13, 24
    dec r12d
    jmp .next_region

  .done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Выделить один кадр. RAX=физический адрес или 0.
leaf_function pmm_alloc_frame
  hhdm_address rdx, PMM.bitmap
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
    lea ecx, [eax+1]
    mov [pmm_search_from], ecx
    shl rax, 12
    ret
  .out_of_memory:
    xor eax, eax
end_leaf

;// Выделить RDI соседних физических кадров. Этот механизм нужен только
;// для DMA-очередей устройств. Обычная user memory по-прежнему выделяется по одному
;// кадру и не раскрывает физические адреса. RAX=base или 0.
function pmm_alloc_contiguous
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  test r12, r12
  jz .failed
  cmp r12, [pmm_free_count]
  ja .failed
  hhdm_address rbx, PMM.bitmap
  mov r13d, [pmm_search_from]
  mov r14d, [pmm_max_frame]

  .candidate:
    mov rax, r13
    add rax, r12
    cmp rax, r14
    ja .failed
    xor ecx, ecx
  .check:
    cmp rcx, r12
    jae .claim
    mov rax, r13
    add rax, rcx
    bt qword [rbx], rax
    jc .occupied
    inc rcx
    jmp .check
  .occupied:
    ;// Все starts до занятого кадра уже не могут вместить весь диапазон.
    add r13, rcx
    inc r13
    jmp .candidate

  .claim:
    xor ecx, ecx
  .claim_one:
    cmp rcx, r12
    jae .success
    mov rax, r13
    add rax, rcx
    bts qword [rbx], rax
    inc rcx
    jmp .claim_one
  .success:
    sub [pmm_free_count], r12
    mov rax, r13
    add rax, r12
    cmp eax, [pmm_search_from]
    jbe .address
    mov [pmm_search_from], eax
  .address:
    mov rax, r13
    shl rax, 12
    jmp .done
  .failed:
    xor eax, eax
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Освободить кадр RDI. Невыровненные/служебные адреса игнорируются.
leaf_function pmm_free_frame
  test rdi, PAGE_SIZE-1
  jnz .done
  cmp rdi, PMM.memStart
  jb .done
  cmp rdi, PMM.memEnd
  jae .done
  mov rax, rdi
  shr rax, 12
  hhdm_address rdx, PMM.bitmap
  btr qword [rdx], rax
  jnc .done
  inc qword [pmm_free_count]
  cmp eax, [pmm_search_from]
  jae .done
  mov [pmm_search_from], eax
  .done:
end_leaf
