;//////////////////////////////////////////////////////////////////////////////
;// VMM и простая куча ядра
;//////////////////////////////////////////////////////////////////////////////

vmm_next_table dq PT.FREE
heap_next      dq HEAP.base

;// Подготовить физическую память, пул таблиц страниц и линейную кучу.
memory_init:
  call pmm_init
  mov qword [vmm_next_table], PT.FREE
  mov rax, HEAP.base
  mov [heap_next], rax
  ret

;// Выделить RDI байт в куче. Память не освобождается: для небольшого учебного
;// ядра bump allocator прозрачен и достаточен. Возвращает RAX=0 при нехватке.
heap_alloc:
  test rdi, rdi
  jz .failed
  add rdi, 15
  and rdi, -16                    ;// выравнивание для данных и будущего ABI C
  mov rax, [heap_next]
  lea rdx, [rax+rdi]
  mov rcx, HEAP.base+HEAP.size
  cmp rdx, rcx
  ja .failed
  mov [heap_next], rdx
  ret
  .failed:
  xor eax, eax
  ret

;// Выдать и обнулить новую таблицу страниц из резервного пула загрузчика.
;// Таблицы лежат ниже 1 MiB и доступны через identity mapping.
vmm_alloc_table:
  mov rax, [vmm_next_table]
  cmp rax, PT.FREE+PT.FREE_PAGES*PAGE_SIZE
  jae .failed
  lea rdx, [rax+PAGE_SIZE]
  mov [vmm_next_table], rdx
  push rax
  mov rdi, rax
  xor eax, eax
  mov ecx, PAGE_SIZE/8
  cld
  rep stosq
  pop rax
  ret
  .failed:
  xor eax, eax
  ret

;// Найти или создать таблицу следующего уровня.
;// RDI = физический адрес таблицы, RSI = индекс записи. Возвращает физический
;// адрес следующей таблицы или ноль. Все таблицы проекта ниже 4 GiB.
vmm_next_level:
  push rbx
  lea rbx, [rdi+rsi*8]
  test byte [rbx], PAGE.P
  jnz .present
  call vmm_alloc_table
  test rax, rax
  jz .done
  mov rcx, rax
  or rcx, PAGE.P+PAGE.RW
  mov [rbx], rcx
  jmp .done
  .present:
  mov eax, [rbx]
  and eax, 0xFFFFF000
  .done:
  pop rbx
  ret

;// Отобразить физический кадр RSI по виртуальному адресу RDI.
;// RDX содержит PAGE.RW/PAGE.US; Present добавляется автоматически.
;// Возвращает RAX=1 при успехе, RAX=0 при нехватке таблиц.
vmm_map_page:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi                    ;// виртуальный адрес
  mov r13, rsi                    ;// физический адрес
  mov r14, rdx                    ;// флаги
  mov r15, cr3

  mov rsi, r12
  shr rsi, 39
  and esi, 0x1FF
  mov rdi, r15
  call vmm_next_level
  test rax, rax
  jz .failed

  mov rdi, rax
  mov rsi, r12
  shr rsi, 30
  and esi, 0x1FF
  call vmm_next_level
  test rax, rax
  jz .failed

  mov rdi, rax
  mov rsi, r12
  shr rsi, 21
  and esi, 0x1FF
  call vmm_next_level
  test rax, rax
  jz .failed

  mov rbx, r12
  shr rbx, 12
  and ebx, 0x1FF
  lea rbx, [rax+rbx*8]
  mov rax, r13
  and rax, -PAGE_SIZE
  or rax, r14
  or rax, PAGE.P
  mov [rbx], rax
  invlpg [r12]
  mov eax, 1
  jmp .done

  .failed:
  xor eax, eax
  .done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
