;//////////////////////////////////////////////////////////////////////////////
;// VMM — изолированные 64-битные адресные пространства
;//////////////////////////////////////////////////////////////////////////////
;
;// Каждая ring-3 задача имеет собственный PML4. Нижняя половина заполняется
;// отдельно, а PML4[256] ссылается на общий supervisor-only HHDM. Поэтому смена
;// CR3 не лишает ядро доступа к коду, стекам и таблицам страниц.

function memory_init
  call pmm_init
  call slab_init
endf

;// Выделить и обнулить таблицу страниц. RAX=физический адрес или 0.
function vmm_alloc_table
  call pmm_alloc_frame
  test rax, rax
  jz .done
  push rax
  hhdm_address rdi, rax
  xor eax, eax
  mov ecx, PAGE_SIZE/8
  cld
  rep stosq
  pop rax
  .done:
endf

;// Найти или создать таблицу следующего уровня.
;// RDI=физ. таблица, RSI=индекс, RDX=флаги будущей страницы. RAX=физ. адрес.
function vmm_next_level
  push rbx
  push r12
  mov r12, rdx
  hhdm_address rbx, rdi
  lea rbx, [rbx+rsi*8]
  test byte [rbx], PAGE.P
  jnz .present
  call vmm_alloc_table
  test rax, rax
  jz .done
  mov rcx, rax
  or rcx, PAGE.P+PAGE.RW
  test r12, PAGE.US
  jz .store
  or rcx, PAGE.US                  ;// U/S нужен на каждом уровне
  .store:
  mov [rbx], rcx
  jmp .done
  .present:
  test r12, PAGE.US
  jz .read_address
  or qword [rbx], PAGE.US
  .read_address:
  mov rax, [rbx]
  ;// PMM этой версии ограничен 1 GiB, поэтому достаточно
  ;// очистить младшие флаги в EAX; у AND r64 нет кодировки imm64.
  and eax, -PAGE_SIZE
  .done:
  pop r12
  pop rbx
endf

;// Отобразить один кадр в заданном PML4.
;// RDI=pml4_phys, RSI=virtual, RDX=physical, RCX=PAGE.RW/PAGE.US.
function vmm_map_in_space
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8                       ;// 16-байтное выравнивание перед вложенными call
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov r15, rcx

  mov rdi, r12
  mov rsi, r13
  shr rsi, 39
  and esi, 0x1FF
  mov rdx, r15
  call vmm_next_level
  test rax, rax
  jz .failed

  mov rdi, rax
  mov rsi, r13
  shr rsi, 30
  and esi, 0x1FF
  mov rdx, r15
  call vmm_next_level
  test rax, rax
  jz .failed

  mov rdi, rax
  mov rsi, r13
  shr rsi, 21
  and esi, 0x1FF
  mov rdx, r15
  call vmm_next_level
  test rax, rax
  jz .failed

  hhdm_address rbx, rax
  mov rax, r13
  shr rax, 12
  and eax, 0x1FF
  lea rbx, [rbx+rax*8]
  mov rax, r14
  and rax, -PAGE_SIZE
  or rax, r15
  or rax, PAGE.P
  mov [rbx], rax
  mov eax, 1
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Создать пустое пространство задачи. RAX=физ. PML4 или 0.
function vmm_create_space
  call vmm_alloc_table
  test rax, rax
  jz .done
  hhdm_address rdx, rax
  hhdm_address rcx, PT.PML4
  mov rcx, [rcx+256*8]
  mov [rdx+256*8], rcx
  .done:
endf

;// Проверить user-адрес и перевести его в физический.
;// RDI=pml4_phys, RSI=virtual. RAX=physical или 0.
;// Каждый уровень обязан иметь P=1 и U/S=1: проверка только PTE
;// была бы классической ошибкой валидации указателей.
function vmm_translate_user
  push rbx
  push r12
  mov r12, rsi
  mov rax, rdi

  hhdm_address rbx, rax
  mov rcx, r12
  shr rcx, 39
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  mov rdx, rax
  and edx, PAGE.P+PAGE.US
  cmp edx, PAGE.P+PAGE.US
  jne .invalid
  and eax, -PAGE_SIZE

  hhdm_address rbx, rax
  mov rcx, r12
  shr rcx, 30
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  mov rdx, rax
  and edx, PAGE.P+PAGE.US
  cmp edx, PAGE.P+PAGE.US
  jne .invalid
  test al, PAGE.PS
  jnz .invalid                     ;// user-карты микроядра пока только 4 KiB
  and eax, -PAGE_SIZE

  hhdm_address rbx, rax
  mov rcx, r12
  shr rcx, 21
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  mov rdx, rax
  and edx, PAGE.P+PAGE.US
  cmp edx, PAGE.P+PAGE.US
  jne .invalid
  test al, PAGE.PS
  jnz .invalid
  and eax, -PAGE_SIZE

  hhdm_address rbx, rax
  mov rcx, r12
  shr rcx, 12
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  mov rdx, rax
  and edx, PAGE.P+PAGE.US
  cmp edx, PAGE.P+PAGE.US
  jne .invalid
  and eax, -PAGE_SIZE
  mov rdx, r12
  and edx, PAGE_SIZE-1
  add rax, rdx
  jmp .done

  .invalid:
  xor eax, eax
  .done:
  pop r12
  pop rbx
endf

;// Безопасно скопировать данные из произвольного user address space.
;// RDI=kernel destination, RSI=pml4, RDX=user source, RCX=size. RAX=1/0.
;// Копирование побайтное намеренно: код прост для аудита и корректно проходит
;// границы страниц. Оптимизация блоками появится только после тестов механизма.
function vmm_copy_from_user_space
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov r15, rcx
  .byte:
    test r15, r15
    jz .success
    mov rax, USER.limit
    cmp r14, rax
    jae .failed
    mov rdi, r13
    mov rsi, r14
    call vmm_translate_user
    test rax, rax
    jz .failed
    hhdm_address rbx, rax
    mov al, [rbx]
    mov [r12], al
    inc r12
    inc r14
    dec r15
    jmp .byte
  .success:
  mov eax, 1
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Безопасно скопировать данные в произвольный user address space.
;// RDI=pml4, RSI=user destination, RDX=kernel source, RCX=size. RAX=1/0.
function vmm_copy_to_user_space
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov r15, rcx
  .byte:
    test r15, r15
    jz .success
    mov rax, USER.limit
    cmp r13, rax
    jae .failed
    mov rdi, r12
    mov rsi, r13
    call vmm_translate_user
    test rax, rax
    jz .failed
    hhdm_address rbx, rax
    mov al, [r14]
    mov [rbx], al
    inc r13
    inc r14
    dec r15
    jmp .byte
  .success:
  mov eax, 1
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Совместимый со старым демо интерфейс: отобразить в текущем CR3.
function vmm_map_page
  push r12
  sub rsp, 8
  mov r12, rdi
  mov rcx, rdx
  mov rdx, rsi
  mov rsi, rdi
  mov rdi, cr3
  call vmm_map_in_space
  test rax, rax
  jz .done
  invlpg [r12]
  .done:
  add rsp, 8
  pop r12
endf

;// Выделить, обнулить и отобразить user-страницу.
;// RDI=pml4, RSI=virtual, RDX=flags. RAX=physical или 0.
function vmm_alloc_user_page
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov rbx, rdx
  call pmm_alloc_frame
  test rax, rax
  jz .failed
  mov r14, rax
  push rax
  sub rsp, 8
  hhdm_address rdi, rax
  xor esi, esi
  mov edx, PAGE_SIZE
  call memory_set
  add rsp, 8
  pop rdx
  mov rdi, r12
  mov rsi, r13
  mov rcx, rbx
  call vmm_map_in_space
  test rax, rax
  jz .free_frame
  mov rax, r14
  jmp .done
  .free_frame:
  mov rdi, r14
  call pmm_free_frame
  .failed:
  xor eax, eax
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Удалить одну 4-KiB mapping и вернуть физический кадр, но не освобождать его.
;// RDI=pml4, RSI=virtual. RAX=physical или 0.
function vmm_unmap_in_space
  push rbx
  push r12
  mov r12, rsi
  hhdm_address rbx, rdi

  mov rcx, r12
  shr rcx, 39
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  test al, PAGE.P
  jz .missing
  and eax, -PAGE_SIZE
  hhdm_address rbx, rax

  mov rcx, r12
  shr rcx, 30
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  test al, PAGE.P
  jz .missing
  test al, PAGE.PS
  jnz .missing
  and eax, -PAGE_SIZE
  hhdm_address rbx, rax

  mov rcx, r12
  shr rcx, 21
  and ecx, 0x1FF
  mov rax, [rbx+rcx*8]
  test al, PAGE.P
  jz .missing
  test al, PAGE.PS
  jnz .missing
  and eax, -PAGE_SIZE
  hhdm_address rbx, rax

  mov rcx, r12
  shr rcx, 12
  and ecx, 0x1FF
  lea rbx, [rbx+rcx*8]
  mov rax, [rbx]
  test al, PAGE.P
  jz .missing
  mov qword [rbx], 0
  and eax, -PAGE_SIZE
  invlpg [r12]
  jmp .done
  .missing:
  xor eax, eax
  .done:
  pop r12
  pop rbx
endf

;// Освобождение address space идёт снизу вверх: сначала leaf-кадры, затем
;// PT, PD, PDPT и PML4. Верхняя половина не трогается — это общая HHDM-ветвь.
function vmm_destroy_pt
  push rbx
  push r12
  mov r12, rdi
  hhdm_address rbx, r12
  xor ecx, ecx
  .leaf:
    mov rdi, [rbx+rcx*8]
    test dil, PAGE.P
    jz .next
    test rdi, PAGE.SHARED
    jnz .next                     ;// borrowed frame освободит SharedMemory
    and edi, -PAGE_SIZE
    push rcx
    call pmm_free_frame
    pop rcx
  .next:
    inc ecx
    cmp ecx, 512
    jb .leaf
  mov rdi, r12
  call pmm_free_frame
  pop r12
  pop rbx
endf

function vmm_destroy_pd
  push rbx
  push r12
  mov r12, rdi
  hhdm_address rbx, r12
  xor ecx, ecx
  .entry:
    mov rdi, [rbx+rcx*8]
    test dil, PAGE.P
    jz .next
    test dil, PAGE.PS
    jnz .next                    ;// user space микроядра huge pages не создаёт
    and edi, -PAGE_SIZE
    push rcx
    call vmm_destroy_pt
    pop rcx
  .next:
    inc ecx
    cmp ecx, 512
    jb .entry
  mov rdi, r12
  call pmm_free_frame
  pop r12
  pop rbx
endf

function vmm_destroy_pdpt
  push rbx
  push r12
  mov r12, rdi
  hhdm_address rbx, r12
  xor ecx, ecx
  .entry:
    mov rdi, [rbx+rcx*8]
    test dil, PAGE.P
    jz .next
    test dil, PAGE.PS
    jnz .next
    and edi, -PAGE_SIZE
    push rcx
    call vmm_destroy_pd
    pop rcx
  .next:
    inc ecx
    cmp ecx, 512
    jb .entry
  mov rdi, r12
  call pmm_free_frame
  pop r12
  pop rbx
endf

;// RDI=physical PML4. Вызывать только после перехода на другой CR3.
function vmm_destroy_space
  push rbx
  push r12
  mov r12, rdi
  hhdm_address rbx, r12
  xor ecx, ecx
  .lower_half:
    mov rdi, [rbx+rcx*8]
    test dil, PAGE.P
    jz .next
    and edi, -PAGE_SIZE
    push rcx
    call vmm_destroy_pdpt
    pop rcx
  .next:
    inc ecx
    cmp ecx, 256
    jb .lower_half
  mov rdi, r12
  call pmm_free_frame
  pop r12
  pop rbx
endf
