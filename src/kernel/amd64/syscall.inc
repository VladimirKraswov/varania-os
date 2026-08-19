;//////////////////////////////////////////////////////////////////////////////
;// AMD64 SYSCALL ABI и диспетчер системных вызовов
;//////////////////////////////////////////////////////////////////////////////
;
;// RAX=номер; RDI,RSI,RDX,R10,R8,R9=аргументы; RAX=результат. Возврат через
;// IRETQ намеренно единообразен с IRQ и безопасен для учебного ядра.

SYS_LOG       = 1
SYS_YIELD     = 2
SYS_EXIT      = 5
SYS_IO_READ8  = 6
SYS_IO_WRITE8 = 7
SYS_IRQ_WAIT  = 8
SYS_WAIT      = 10
SYS_BRK       = 11
SYS_MEM_INFO  = 12
SYS_ENDPOINT_CREATE = 13
SYS_IPC_SEND        = 14
SYS_IPC_RECV        = 15
SYS_SPACE_CREATE    = 16
SYS_FRAME_ALLOC     = 17
SYS_FRAME_WRITE     = 18
SYS_SPACE_MAP       = 19
SYS_THREAD_CREATE   = 20
SYS_THREAD_START    = 21
SYS_CAP_CLOSE       = 22
SYS_BOOTFS_INFO     = 23
SYS_PROCESS_KILL    = 24
SYS_SHARED_CREATE   = 25
SYS_SHARED_MAP      = 26
SYS_CAP_REVOKE      = 27
SYS_MMIO_MAP        = 28
SYS_IO_READ32       = 29
SYS_IO_WRITE32      = 30
SYS_MMIO_CREATE     = 31
SYS_DMA_CREATE      = 32
SYS_SHARED_UNMAP    = 33

ERR_NOENT = -2
ERR_BAD_HANDLE = -9
ERR_NO_MEMORY = -12
ERR_FAULT = -14
ERR_BUSY = -16
ERR_INVALID = -22
ERR_NOSYS = -38

SPAWN_MAX_GRANTS = 4
SpawnGrant.handle = 0
SpawnGrant.rights = 8
SpawnGrant.size   = 16

;// Конфигурация low-level thread. Ядро получает уже подготовленное address
;// space и не знает, из какого формата executable появились эти значения.
ThreadConfig.entry       = 0
ThreadConfig.stack_top   = 8
ThreadConfig.stack_low   = 16
ThreadConfig.stack_limit = 24
ThreadConfig.brk_base    = 32
ThreadConfig.grant_count = 40
ThreadConfig.grants      = 48
ThreadConfig.bytes       = ThreadConfig.grants+SPAWN_MAX_GRANTS*SpawnGrant.size

SPACE_MAP_WRITE = 1
SPACE_MAP_EXEC  = 2

syscall_user_rsp dq 0

;// Вывести не более 256 байт в диагностический порт. VGA после bootstrap
;// принадлежит user-space console driver и не должен изменяться SYS_LOG.
function syscall_log
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  cmp r13, 256
  ja .fault
  mov rax, r12
  add rax, r13
  jc .fault
  mov rdx, USER.limit
  cmp rax, rdx
  ja .fault
  mov edi, [current_task]
  call task_by_index
  mov rbx, [rax+Task.cr3]
  .next_byte:
    test r13, r13
    jz .success
    mov rdi, rbx
    mov rsi, r12
    call vmm_translate_user
    test rax, rax
    jz .fault
    hhdm_address rdx, rax
    movzx edi, byte [rdx]
    call debug_put_char
    inc r12
    dec r13
    jmp .next_byte
  .success:
  xor eax, eax
  jmp .done
  .fault:
  mov rax, ERR_FAULT
  .done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf

;// Проверить bootstrap system capability. RDI=handle, RAX=1/0.
function syscall_require_create
  mov esi, CAP_SYSTEM
  mov edx, CAP_CREATE
  call capability_lookup
  test rax, rax
  setnz al
  movzx eax, al
endf

;// Создать endpoint и вернуть handle с правами SEND|RECV.
;// RDI=system capability. RAX=handle/error.
function syscall_endpoint_create
  push rbx
  sub rsp, 8
  call syscall_require_create
  test rax, rax
  jz .bad
  call endpoint_create
  test rax, rax
  jz .no_memory
  mov rbx, rax
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_ENDPOINT
  mov rdx, rbx
  mov ecx, CAP_SEND+CAP_RECV
  call capability_insert_task
  test rax, rax
  jz .release_failed
  push rax
  mov edi, CAP_ENDPOINT
  mov rsi, rbx
  call object_release             ;// убрать временную creator reference
  pop rax
  jmp .done
  .release_failed:
  mov edi, CAP_ENDPOINT
  mov rsi, rbx
  call object_release
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  .done:
  add rsp, 8
  pop rbx
endf

;// Создать пустое address space. RDI=system capability.
function syscall_space_create
  push rbx
  sub rsp, 8
  call syscall_require_create
  test rax, rax
  jz .bad
  call address_space_create
  test rax, rax
  jz .no_memory
  mov rbx, rax
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_SPACE
  mov rdx, rbx
  mov ecx, CAP_MAP
  call capability_insert_task
  test rax, rax
  jz .release_failed
  push rax
  mov edi, CAP_SPACE
  mov rsi, rbx
  call object_release
  pop rax
  jmp .done
  .release_failed:
  mov edi, CAP_SPACE
  mov rsi, rbx
  call object_release
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  .done:
  add rsp, 8
  pop rbx
endf

;// Выделить один обнулённый frame. RDI=system capability.
function syscall_frame_alloc
  push rbx
  sub rsp, 8
  call syscall_require_create
  test rax, rax
  jz .bad
  call frame_create
  test rax, rax
  jz .no_memory
  mov rbx, rax
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_FRAME
  mov rdx, rbx
  mov ecx, CAP_MAP+CAP_WRITE
  call capability_insert_task
  test rax, rax
  jz .release_failed
  push rax
  mov edi, CAP_FRAME
  mov rsi, rbx
  call object_release
  pop rax
  jmp .done
  .release_failed:
  mov edi, CAP_FRAME
  mov rsi, rbx
  call object_release
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  .done:
  add rsp, 8
  pop rbx
endf

;// Записать байты в ещё не отображённый frame.
;// RDI=frame cap, RSI=offset, RDX=user source, RCX=size.
function syscall_frame_write
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov esi, CAP_FRAME
  mov edx, CAP_WRITE
  call capability_lookup
  test rax, rax
  jz .bad
  mov rbx, rax
  mov rax, r12
  add rax, r14
  jc .invalid
  cmp rax, PAGE_SIZE
  ja .invalid
  hhdm_address r15, [rbx+Frame.physical]
  add r15, r12
  mov edi, [current_task]
  call task_by_index
  mov rdi, r15
  mov rsi, [rax+Task.cr3]
  mov rdx, r13
  mov rcx, r14
  call vmm_copy_from_user_space
  test rax, rax
  jz .fault
  xor eax, eax
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  jmp .done
  .fault:
  mov rax, ERR_FAULT
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Передать ownership физического frame отображению address space.
;// RDI=space cap, RSI=frame cap, RDX=virtual, RCX=SPACE_MAP_*.
function syscall_space_map
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
  test r14, PAGE_SIZE-1
  jnz .invalid
  cmp r14, USER.imageMin
  jb .invalid
  mov rax, USER.limit
  cmp r14, rax
  jae .invalid
  cmp r15, SPACE_MAP_WRITE+SPACE_MAP_EXEC
  ja .invalid
  cmp r15, SPACE_MAP_WRITE+SPACE_MAP_EXEC
  je .invalid                       ;// W^X
  mov rdi, r12
  mov esi, CAP_SPACE
  mov edx, CAP_MAP
  call capability_lookup
  test rax, rax
  jz .bad
  mov rbx, rax                      ;// AddressSpace
  mov rdi, r13
  mov esi, CAP_FRAME
  mov edx, CAP_MAP
  call capability_lookup
  test rax, rax
  jz .bad
  mov r12, rax                      ;// Frame
  ;// Mapping забирает кадр безусловно: дублированный frame cap двусмысленен.
  cmp qword [r12+Object.refs], 1
  jne .busy
  mov rdi, [rbx+AddressSpace.cr3]
  mov rsi, r14
  call vmm_translate_user
  test rax, rax
  jnz .busy
  mov rcx, PAGE.US+PAGE.NX
  test r15, SPACE_MAP_WRITE
  jz .not_write
  or rcx, PAGE.RW
  .not_write:
  test r15, SPACE_MAP_EXEC
  jz .flags_ready
  btr rcx, 63
  .flags_ready:
  mov rdi, [rbx+AddressSpace.cr3]
  mov rsi, r14
  mov rdx, [r12+Frame.physical]
  call vmm_map_in_space
  test rax, rax
  jz .no_memory
  mov rdi, r13
  mov esi, CAP_FRAME
  call capability_take_current
  cmp rax, r12
  jne .invalid                       ;// invariant violation, mapping уже создано
  mov qword [r12+Frame.physical], 0  ;// leaf PTE теперь владеет физ. кадром
  mov edi, CAP_FRAME
  mov rsi, r12
  call object_release
  xor eax, eax
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .busy:
  mov rax, ERR_BUSY
  jmp .done
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Создать shared-memory object из нескольких страниц.
;// RDI=system cap, RSI=число страниц. RAX=handle/error.
function syscall_shared_create
  push rbx
  push r12
  mov r12, rsi
  test r12, r12
  jz .invalid
  cmp r12, SHARED_MAX_PAGES
  ja .invalid
  call syscall_require_create
  test rax, rax
  jz .bad
  mov rdi, r12
  call shared_memory_create
  test rax, rax
  jz .no_memory
  mov rbx, rax
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_SHARED
  mov rdx, rbx
  mov ecx, CAP_MAP+CAP_READ+CAP_WRITE
  call capability_insert_task
  test rax, rax
  jz .release_failed
  push rax
  mov edi, CAP_SHARED
  mov rsi, rbx
  call object_release             ;// убрать временную creator reference
  pop rax
  jmp .done
  .release_failed:
  mov edi, CAP_SHARED
  mov rsi, rbx
  call object_release
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  .done:
  pop r12
  pop rbx
endf

;// Отобразить SharedMemory в текущий процесс. В отличие от FRAME_MAP объект
;// сохраняет ownership кадров, поэтому одну область можно безопасно передать
;// другому процессу и отобразить там по иному виртуальному адресу.
;// RDI=shared cap, RSI=virtual, RDX=SPACE_MAP_WRITE или 0.
function syscall_shared_map
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8                       ;// [rsp] = SharedMapping*
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  test r13, PAGE_SIZE-1
  jnz .invalid
  cmp r13, USER.imageMin
  jb .invalid
  cmp r14, SPACE_MAP_WRITE
  ja .invalid                      ;// shared memory всегда NX

  mov rdi, r12
  mov esi, CAP_SHARED
  mov edx, CAP_MAP+CAP_READ
  test r14, SPACE_MAP_WRITE
  jz .lookup
  or edx, CAP_WRITE
  .lookup:
  call capability_lookup
  test rax, rax
  jz .bad
  mov r12, rax                     ;// SharedMemory

  mov rax, [r12+SharedMemory.page_count]
  shl rax, 12
  add rax, r13
  jc .invalid
  mov rdx, USER.limit
  cmp rax, rdx
  ja .invalid

  mov edi, [current_task]
  call task_by_index
  mov rbx, [rax+Task.space]
  test rbx, rbx
  jz .invalid                      ;// только процесс с managed AddressSpace

  ;// Проверяем весь диапазон до изменения таблиц: API либо отображает объект
  ;// целиком, либо не меняет видимое адресное пространство.
  xor r15d, r15d
  .check_page:
    cmp r15, [r12+SharedMemory.page_count]
    jae .allocate_record
    mov rsi, r15
    shl rsi, 12
    add rsi, r13
    mov rdi, [rbx+AddressSpace.cr3]
    call vmm_translate_user
    test rax, rax
    jnz .busy
    inc r15
    jmp .check_page

  .allocate_record:
  mov edi, SharedMapping.bytes
  call kmalloc
  test rax, rax
  jz .no_memory
  mov [rsp], rax
  xor r15d, r15d
  .map_page:
    cmp r15, [r12+SharedMemory.page_count]
    jae .mapped
    mov rsi, r15
    shl rsi, 12
    add rsi, r13
    mov rdi, [rbx+AddressSpace.cr3]
    mov rdx, [r12+SharedMemory.frames+r15*8]
    mov rcx, PAGE.US+PAGE.NX+PAGE.SHARED
    test r14, SPACE_MAP_WRITE
    jz .map
    or rcx, PAGE.RW
    .map:
    call vmm_map_in_space
    test rax, rax
    jz .rollback
    inc r15
    jmp .map_page

  .mapped:
  mov rax, [rsp]
  mov rcx, [rbx+AddressSpace.shared_head]
  mov [rax+SharedMapping.next], rcx
  mov [rax+SharedMapping.shm], r12
  mov [rax+SharedMapping.base], r13
  mov [rbx+AddressSpace.shared_head], rax
  mov edi, CAP_SHARED
  mov rsi, r12
  call object_retain
  xor eax, eax
  jmp .done

  .rollback:
    test r15, r15
    jz .free_record
    dec r15
    mov rsi, r15
    shl rsi, 12
    add rsi, r13
    mov rdi, [rbx+AddressSpace.cr3]
    call vmm_unmap_in_space         ;// frame по-прежнему принадлежит object
    jmp .rollback
  .free_record:
  mov rdi, [rsp]
  call kfree
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .busy:
  mov rax, ERR_BUSY
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Удалить ранее созданное shared mapping по его начальному адресу.
;// Capability на объект закрывать не обязательно: mapping держит отдельную
;// ссылку, а unmap освобождает именно её. Это позволяет долгоживущему procd
;// переиспользовать одно окно для последовательной загрузки ELF.
;// RDI=virtual base. RAX=0/error.
function syscall_shared_unmap
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi
  test r12, PAGE_SIZE-1
  jnz .invalid
  cmp r12, USER.imageMin
  jb .invalid

  mov edi, [current_task]
  call task_by_index
  mov rbx, [rax+Task.space]
  test rbx, rbx
  jz .invalid
  lea r13, [rbx+AddressSpace.shared_head] ;// адрес ссылки на текущую запись
.find:
  mov r14, [r13]
  test r14, r14
  jz .missing
  cmp [r14+SharedMapping.base], r12
  je .found
  lea r13, [r14+SharedMapping.next]
  jmp .find

.found:
  mov r15, [r14+SharedMapping.shm]
  xor ecx, ecx
.page:
  cmp rcx, [r15+SharedMemory.page_count]
  jae .unlink
  mov rsi, rcx
  shl rsi, 12
  add rsi, r12
  mov rdi, [rbx+AddressSpace.cr3]
  push rcx
  call vmm_unmap_in_space
  pop rcx
  inc rcx
  jmp .page
.unlink:
  mov rax, [r14+SharedMapping.next]
  mov [r13], rax
  mov edi, CAP_SHARED
  mov rsi, r15
  call object_release
  mov rdi, r14
  call kfree
  xor eax, eax
  jmp .done
.missing:
  mov rax, ERR_NOENT
  jmp .done
.invalid:
  mov rax, ERR_INVALID
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Создать capability на диапазон MMIO. Это может сделать только bootstrap
;// device manager, у которого есть CAP_SYSTEM|CREATE. Обычный драйвер уже получает
;// готовую ослабленную capability и не может выбрать физический адрес.
;// RDI=system cap, RSI=physical base, RDX=pages. RAX=handle/error.
function syscall_mmio_create
  push rbx
  push r12
  push r13
  push r14
  sub rsp, 8
  mov r12, rsi
  mov r13, rdx
  call syscall_require_create
  test rax, rax
  jz .bad
  test r12, PAGE_SIZE-1
  jnz .invalid
  test r13, r13
  jz .invalid
  cmp r13, 0xFFFF
  ja .invalid
  mov rax, r12
  shr rax, 48
  jnz .invalid                     ;// target packing хранит base в 48 битах
  mov rax, r13
  shl rax, 12
  add rax, r12
  jc .invalid
  mov rdx, rax
  shr rdx, 48
  jnz .invalid
  mov r14, r13
  shl r14, 48
  or r14, r12                     ;// pages:16 | physical_base:48
  mov edi, [current_task]
  mov esi, CAP_MMIO
  mov rdx, r14
  mov ecx, CAP_MAP+CAP_READ+CAP_WRITE
  call capability_insert
  test rax, rax
  jz .no_memory
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  jmp .done
  .no_memory:
  mov rax, ERR_NO_MEMORY
  .done:
  add rsp, 8
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Выделить физически непрерывный DMA-буфер и вернуть его как обычную
;// SharedMemory capability. Только держатель CAP_DMA_POOL увидит физический base.
;// RDI=dma-pool cap, RSI=pages. RAX=shared handle/error, RDX=physical base.
function syscall_dma_create
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rsi
  mov esi, CAP_DMA_POOL
  mov edx, CAP_CREATE
  call capability_lookup
  test rax, rax
  jz .bad
  mov rdi, r12
  call shared_memory_create_contiguous
  test rax, rax
  jz .no_memory
  mov rbx, rax
  mov r13, rdx
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_SHARED
  mov rdx, rbx
  mov ecx, CAP_MAP+CAP_READ+CAP_WRITE
  call capability_insert_task
  test rax, rax
  jz .release_failed
  push rax
  mov edi, CAP_SHARED
  mov rsi, rbx
  call object_release
  pop rax
  mov rdx, r13
  jmp .done
  .release_failed:
  mov edi, CAP_SHARED
  mov rsi, rbx
  call object_release
  .no_memory:
  mov rax, ERR_NO_MEMORY
  xor edx, edx
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  xor edx, edx
  .done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf

;// Отобразить весь доверенный device MMIO range в текущий процесс.
;// RDI=cap, RSI=user virtual. RAX=0/error.
function syscall_mmio_map
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rsi
  test r12, PAGE_SIZE-1
  jnz .invalid
  cmp r12, USER.imageMin
  jb .invalid
  mov esi, CAP_MMIO
  ;// x86-64 не умеет write-only PTE: RW mapping неизбежно доступен для чтения.
  ;// Поэтому capability честно обязана содержать READ, WRITE и MAP.
  mov edx, CAP_MAP+CAP_READ+CAP_WRITE
  call capability_lookup
  test rax, rax
  jz .bad
  mov r13, rax
  mov r14, rax
  shr r14, 48                     ;// число страниц
  shl r13, 16
  shr r13, 16                     ;// physical base в младших 48 битах
  test r14, r14
  jz .invalid
  mov rax, r14
  shl rax, 12
  add rax, r12
  jc .invalid
  mov rdx, USER.limit
  cmp rax, rdx
  ja .invalid
  mov edi, [current_task]
  call task_by_index
  mov rbx, [rax+Task.space]
  test rbx, rbx
  jz .invalid
  xor r15d, r15d
  .check_page:
    cmp r15, r14
    jae .map_pages
    mov rsi, r15
    shl rsi, 12
    add rsi, r12
    mov rdi, [rbx+AddressSpace.cr3]
    call vmm_translate_user
    test rax, rax
    jnz .busy
    inc r15
    jmp .check_page
  .map_pages:
    xor r15d, r15d
  .map_page:
    cmp r15, r14
    jae .success
    mov rsi, r15
    shl rsi, 12
    add rsi, r12
    mov rdx, r15
    shl rdx, 12
    add rdx, r13
    mov rdi, [rbx+AddressSpace.cr3]
    mov rcx, PAGE.US+PAGE.RW+PAGE.NX+PAGE.BORROWED
    call vmm_map_in_space
    test rax, rax
    jz .rollback
    inc r15
    jmp .map_page
  .success:
  xor eax, eax
  jmp .done
  .rollback:
    test r15, r15
    jz .no_memory
    dec r15
    mov rsi, r15
    shl rsi, 12
    add rsi, r12
    mov rdi, [rbx+AddressSpace.cr3]
    call vmm_unmap_in_space
    jmp .rollback
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .busy:
  mov rax, ERR_BUSY
  jmp .done
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Создать suspended thread в уже подготовленном address space.
;// RDI=system cap, RSI=space cap, RDX=user ThreadConfig*. RAX=process handle.
function syscall_thread_create
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, ThreadConfig.bytes+24
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  call syscall_require_create
  test rax, rax
  jz .bad
  mov rdi, r13
  mov esi, CAP_SPACE
  mov edx, CAP_MAP
  call capability_lookup
  test rax, rax
  jz .bad
  mov rbx, rax                    ;// AddressSpace
  mov edi, [current_task]
  call task_by_index
  mov rdi, rsp
  mov rsi, [rax+Task.cr3]
  mov rdx, r14
  mov ecx, ThreadConfig.bytes
  call vmm_copy_from_user_space
  test rax, rax
  jz .fault
  cmp qword [rsp+ThreadConfig.grant_count], SPAWN_MAX_GRANTS
  ja .invalid
  mov rax, USER.limit
  cmp [rsp+ThreadConfig.entry], rax
  jae .invalid
  cmp [rsp+ThreadConfig.stack_top], rax
  jae .invalid
  mov rax, [rsp+ThreadConfig.stack_limit]
  cmp rax, [rsp+ThreadConfig.stack_low]
  ja .invalid
  mov rax, [rsp+ThreadConfig.stack_low]
  cmp rax, [rsp+ThreadConfig.stack_top]
  jae .invalid

  call task_allocate
  test rax, rax
  jz .no_memory
  mov r15, rax                    ;// child TCB
  mov [rsp+ThreadConfig.bytes], rdx ;// child token
  mov [rsp+ThreadConfig.bytes+8], rcx ;// child slot
  mov edi, [current_task]
  call task_by_index
  mov rax, [rax+Task.token]
  mov [r15+Task.parent], rax
  mov qword [r15+Task.wait_irq], -1
  mov [r15+Task.space], rbx
  mov rax, [rbx+AddressSpace.cr3]
  mov [r15+Task.cr3], rax
  mov edi, CAP_SPACE
  mov rsi, rbx
  call object_retain              ;// отдельная ownership-ссылка thread

  call pmm_alloc_frame
  test rax, rax
  jz .discard
  mov [r15+Task.kernel_frame], rax
  hhdm_address rdi, rax
  mov [r15+Task.kernel_top], rdi
  add qword [r15+Task.kernel_top], PAGE_SIZE
  xor esi, esi
  mov edx, PAGE_SIZE
  call memory_set

  mov rdi, [r15+Task.kernel_top]
  sub rdi, Context.size
  mov [r15+Task.saved_rsp], rdi
  mov rax, [rsp+ThreadConfig.entry]
  mov [rdi+Context.rip], rax
  mov qword [rdi+Context.cs], SEL.userCode64+3
  mov qword [rdi+Context.rflags], 0x202
  mov rax, [rsp+ThreadConfig.stack_top]
  mov [rdi+Context.rsp], rax
  mov qword [rdi+Context.ss], SEL.userData64+3
  mov rax, [rsp+ThreadConfig.stack_low]
  mov [r15+Task.stack_low], rax
  mov rax, [rsp+ThreadConfig.stack_limit]
  mov [r15+Task.stack_limit], rax
  mov rax, [rsp+ThreadConfig.brk_base]
  mov [r15+Task.brk_base], rax
  mov [r15+Task.brk_current], rax
  mov qword [r15+Task.state], TASK_SUSPENDED

  xor r14d, r14d
  .grant:
    cmp r14, [rsp+ThreadConfig.grant_count]
    jae .parent_cap
    mov rax, r14
    shl rax, 4
    mov rsi, [rsp+ThreadConfig.grants+rax+SpawnGrant.handle]
    mov rdx, [rsp+ThreadConfig.grants+rax+SpawnGrant.rights]
    mov rdi, r15
    call capability_clone_current
    test rax, rax
    jz .bad_grant
    inc r14
    jmp .grant
  .parent_cap:
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_PROCESS
  mov rdx, [rsp+ThreadConfig.bytes]
  mov ecx, CAP_WAIT+CAP_CONTROL
  call capability_insert_task
  test rax, rax
  jz .discard_no_memory
  mov r14, rax
  mov edi, [current_task]
  call task_by_index
  mov rdi, r15
  mov rsi, rax
  call device_commit_irq_transfers
  mov rax, r14
  jmp .done

  .bad_grant:
  mov r14, ERR_BAD_HANDLE
  jmp .discard_with_error
  .discard_no_memory:
  mov r14, ERR_NO_MEMORY
  .discard_with_error:
  mov rdi, r15
  mov rsi, [rsp+ThreadConfig.bytes+8]
  call task_discard_new
  mov rax, r14
  jmp .done
  .discard:
  mov rdi, r15
  mov rsi, [rsp+ThreadConfig.bytes+8]
  call task_discard_new
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .fault:
  mov rax, ERR_FAULT
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  .done:
  add rsp, ThreadConfig.bytes+24
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Сделать suspended process доступным планировщику. RDI=process handle.
function syscall_thread_start
  push rbx
  sub rsp, 8
  mov esi, CAP_PROCESS
  mov edx, CAP_CONTROL
  call capability_lookup
  test rax, rax
  jz .bad
  mov rdi, rax
  call task_from_token
  test rax, rax
  jz .bad
  cmp qword [rax+Task.state], TASK_SUSPENDED
  jne .busy
  mov qword [rax+Task.state], TASK_RUNNABLE
  xor eax, eax
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .busy:
  mov rax, ERR_BUSY
  .done:
  add rsp, 8
  pop rbx
endf

;// Вернуть user mapping initramfs, доступный только владельцу CAP_BOOTFS.
;// RDI=bootfs handle. RAX=base/error, RDX=used bytes.
function syscall_bootfs_info
  mov esi, CAP_BOOTFS
  mov edx, CAP_READ
  call capability_lookup
  test rax, rax
  jz .bad
  mov rax, USER.bootfsBase
  mov edx, [initramfs_used]
  jmp .done
  .bad:
  mov rax, ERR_BAD_HANDLE
  xor edx, edx
  .done:
endf

;// RDI указывает на единый Context. RAX=контекст для возобновления.
function syscall_dispatch
  push rbx
  push r12
  mov r12, rdi
  ;// Текущая задача уже работает на чужом по отношению к zombies стеке,
  ;// поэтому здесь безопасно завершить отложенный teardown.
  call task_cleanup_zombies
  mov rax, [r12+Context.rax]
  cmp rax, SYS_LOG
  je .log
  cmp rax, SYS_YIELD
  je .yield
  cmp rax, SYS_EXIT
  je .exit
  cmp rax, SYS_IO_READ8
  je .io_read8
  cmp rax, SYS_IO_WRITE8
  je .io_write8
  cmp rax, SYS_IRQ_WAIT
  je .irq_wait
  cmp rax, SYS_WAIT
  je .wait
  cmp rax, SYS_BRK
  je .brk
  cmp rax, SYS_MEM_INFO
  je .memory_info
  cmp rax, SYS_ENDPOINT_CREATE
  je .endpoint_create
  cmp rax, SYS_IPC_SEND
  je .endpoint_send
  cmp rax, SYS_IPC_RECV
  je .endpoint_receive
  cmp rax, SYS_SPACE_CREATE
  je .space_create
  cmp rax, SYS_FRAME_ALLOC
  je .frame_alloc
  cmp rax, SYS_FRAME_WRITE
  je .frame_write
  cmp rax, SYS_SPACE_MAP
  je .space_map
  cmp rax, SYS_THREAD_CREATE
  je .thread_create
  cmp rax, SYS_THREAD_START
  je .thread_start
  cmp rax, SYS_CAP_CLOSE
  je .cap_close
  cmp rax, SYS_BOOTFS_INFO
  je .bootfs_info
  cmp rax, SYS_PROCESS_KILL
  je .process_kill
  cmp rax, SYS_SHARED_CREATE
  je .shared_create
  cmp rax, SYS_SHARED_MAP
  je .shared_map
  cmp rax, SYS_CAP_REVOKE
  je .cap_revoke
  cmp rax, SYS_MMIO_MAP
  je .mmio_map
  cmp rax, SYS_IO_READ32
  je .io_read32
  cmp rax, SYS_IO_WRITE32
  je .io_write32
  cmp rax, SYS_MMIO_CREATE
  je .mmio_create
  cmp rax, SYS_DMA_CREATE
  je .dma_create
  cmp rax, SYS_SHARED_UNMAP
  je .shared_unmap
  mov qword [r12+Context.rax], ERR_NOSYS
  jmp .resume_current

  .log:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call syscall_log
  mov [r12+Context.rax], rax
  jmp .resume_current

  .wait:
  mov rdi, [r12+Context.rdi]
  call task_wait
  test rcx, rcx
  jz .switch
  mov [r12+Context.rax], rax
  jmp .resume_current

  .brk:
  mov rdi, [r12+Context.rdi]
  call task_set_brk
  mov [r12+Context.rax], rax
  jmp .resume_current

  .memory_info:
  mov rax, [pmm_free_count]
  mov [r12+Context.rax], rax
  jmp .resume_current

  .endpoint_create:
  mov rdi, [r12+Context.rdi]
  call syscall_endpoint_create
  mov [r12+Context.rax], rax
  jmp .resume_current

  .endpoint_send:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call ipc_endpoint_send
  mov [r12+Context.rax], rax
  jmp .resume_current

  .endpoint_receive:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call ipc_endpoint_receive
  test rcx, rcx
  jz .switch
  mov [r12+Context.rax], rax
  jmp .resume_current

  .space_create:
  mov rdi, [r12+Context.rdi]
  call syscall_space_create
  mov [r12+Context.rax], rax
  jmp .resume_current

  .frame_alloc:
  mov rdi, [r12+Context.rdi]
  call syscall_frame_alloc
  mov [r12+Context.rax], rax
  jmp .resume_current

  .frame_write:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  mov rcx, [r12+Context.r10]
  call syscall_frame_write
  mov [r12+Context.rax], rax
  jmp .resume_current

  .space_map:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  mov rcx, [r12+Context.r10]
  call syscall_space_map
  mov [r12+Context.rax], rax
  jmp .resume_current

  .thread_create:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  call syscall_thread_create
  mov [r12+Context.rax], rax
  jmp .resume_current

  .thread_start:
  mov rdi, [r12+Context.rdi]
  call syscall_thread_start
  mov [r12+Context.rax], rax
  jmp .resume_current

  .cap_close:
  mov rdi, [r12+Context.rdi]
  call capability_close_current
  mov [r12+Context.rax], rax
  jmp .resume_current

  .bootfs_info:
  mov rdi, [r12+Context.rdi]
  call syscall_bootfs_info
  mov [r12+Context.rax], rax
  mov [r12+Context.rdx], rdx
  jmp .resume_current

  .process_kill:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call task_kill
  mov [r12+Context.rax], rax
  jmp .resume_current

  .shared_create:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call syscall_shared_create
  mov [r12+Context.rax], rax
  jmp .resume_current

  .shared_map:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  call syscall_shared_map
  mov [r12+Context.rax], rax
  jmp .resume_current

  .shared_unmap:
  mov rdi, [r12+Context.rdi]
  call syscall_shared_unmap
  mov [r12+Context.rax], rax
  jmp .resume_current

  .cap_revoke:
  mov rdi, [r12+Context.rdi]
  call capability_revoke_current
  mov [r12+Context.rax], rax
  jmp .resume_current

  .mmio_map:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call syscall_mmio_map
  mov [r12+Context.rax], rax
  jmp .resume_current

  .mmio_create:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  call syscall_mmio_create
  mov [r12+Context.rax], rax
  jmp .resume_current

  .dma_create:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call syscall_dma_create
  mov [r12+Context.rax], rax
  mov [r12+Context.rdx], rdx
  jmp .resume_current

  .io_read8:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call device_io_read8
  mov [r12+Context.rax], rax
  jmp .resume_current

  .io_write8:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  call device_io_write8
  mov [r12+Context.rax], rax
  jmp .resume_current

  .io_read32:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call device_io_read32
  mov [r12+Context.rax], rax
  jmp .resume_current

  .io_write32:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  call device_io_write32
  mov [r12+Context.rax], rax
  jmp .resume_current

  .irq_wait:
  mov rdi, [r12+Context.rdi]
  call device_irq_wait
  test ecx, ecx
  jz .switch
  mov [r12+Context.rax], rax
  jmp .resume_current

  .yield:
  mov qword [r12+Context.rax], 0
  jmp .switch

  .exit:
  mov rdi, [r12+Context.rdi]
  call task_mark_exit
  .switch:
  mov rdi, r12
  call scheduler_switch
  jmp .done

  .resume_current:
  mov rax, r12
  .done:
  pop r12
  pop rbx
endf

;// Включить SYSCALL и NX, затем запрограммировать STAR/LSTAR/FMASK.
function syscall_init
  mov ecx, 0xC0000080              ;// IA32_EFER
  rdmsr
  or eax, 1+(1 shl 11)             ;// SCE + NXE
  wrmsr
  mov ecx, 0xC0000081              ;// IA32_STAR
  xor eax, eax
  mov edx, (0x20 shl 16)+SEL.code64
  wrmsr
  mov ecx, 0xC0000082              ;// IA32_LSTAR
  lea rax, [syscall_entry]
  mov rdx, rax
  shr rdx, 32
  wrmsr
  mov ecx, 0xC0000084              ;// IA32_FMASK
  mov eax, (1 shl 9)+(1 shl 10)    ;// IF=0, DF=0 внутри ядра
  xor edx, edx
  wrmsr
endf

align 16
syscall_entry:
  mov [syscall_user_rsp], rsp
  mov rsp, [current_kernel_stack]
  push SEL.userData64+3
  push qword [syscall_user_rsp]
  push r11
  push SEL.userCode64+3
  push rcx
  push_all_registers
  mov rdi, rsp
  call syscall_dispatch
  mov rsp, rax
  pop_all_registers
  iretq
