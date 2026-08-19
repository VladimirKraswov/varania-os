;//////////////////////////////////////////////////////////////////////////////
;// Задачи ring 3 и вытесняющий round-robin планировщик
;//////////////////////////////////////////////////////////////////////////////
;
;// Task здесь — минимальный TCB (task control block). Макросы FASM
;// позволяют описывать поля символьными именами, как в C-структуре,
;// но на выходе остаются обычные константы смещений.

Task.state       = 0
Task.saved_rsp   = 8
Task.cr3         = 16
Task.kernel_top  = 24
Task.id          = 32
Task.message     = 40
Task.sender      = 48
Task.value       = 56
Task.cap_target  = 64               ;// 4 qword: index+1, ноль = пусто
Task.cap_rights  = 96               ;// 4 qword: маска прав
Task.cap_type    = 128              ;// 4 qword: тип объекта
Task.wait_irq    = 160              ;// IRQ, которого ждёт драйвер
Task.size        = 192

Context.r15      = 0
Context.r14      = 8
Context.r13      = 16
Context.r12      = 24
Context.r11      = 32
Context.r10      = 40
Context.r9       = 48
Context.r8       = 56
Context.rdi      = 64
Context.rsi      = 72
Context.rbp      = 80
Context.rdx      = 88
Context.rcx      = 96
Context.rbx      = 104
Context.rax      = 112
Context.rip      = 120
Context.cs       = 128
Context.rflags   = 136
Context.rsp      = 144
Context.ss       = 152
Context.size     = 160

TASK_MAX         = 4
TASK_EMPTY       = 0
TASK_RUNNABLE    = 1
TASK_BLOCKED_IPC = 2
TASK_EXITED      = 3
TASK_BLOCKED_IRQ = 4

CAP_SLOTS        = 4
CAP_SEND         = 1
CAP_READ         = 2
CAP_WRITE        = 4
CAP_WAIT         = 8
CAP_ENDPOINT     = 1
CAP_IO_PORT      = 2
CAP_IRQ          = 3

USER.code        = 0x0000000000400000
USER.stackPage   = 0x00007FFFFFFFE000
USER.stackTop    = USER.stackPage+PAGE_SIZE
USER.limit       = 0x0000800000000000

align 16
tasks rb TASK_MAX*Task.size
task_count dd 0
current_task dd -1
current_kernel_stack dq 0
scheduler_is_idle db 0

gdt64_descriptor_high:
  dw GDT64.size-1
  dq HHDM.base+GDT64.base

;// RDI=index. RAX=указатель на TCB.
leaf_function task_by_index
  mov rax, rdi
  imul rax, Task.size
  lea rdx, [tasks]
  add rax, rdx
end_leaf

;// Перезагрузить GDTR адресом HHDM и обновить RSP0 в TSS.
;// RDI=вершина ядерного стека.
leaf_function task_set_kernel_stack
  mov [current_kernel_stack], rdi
  hhdm_address rax, TSS64.base
  mov [rax+4], rdi
end_leaf

;// Создать задачу из позиционно-независимого блоба не больше одной страницы.
;// RDI=источник, RSI=размер. RAX=index или -1.
function task_create
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  cmp r13, PAGE_SIZE
  ja .failed
  mov eax, [task_count]
  cmp eax, TASK_MAX
  jae .failed
  mov r14d, eax
  mov edi, eax
  call task_by_index
  mov r15, rax

  ;// Обнуляем TCB, чтобы невыданные capabilities точно были закрыты.
  mov rdi, r15
  xor eax, eax
  mov ecx, Task.size/8
  rep stosq

  call vmm_create_space
  test rax, rax
  jz .failed
  mov [r15+Task.cr3], rax

  call pmm_alloc_frame             ;// user code
  test rax, rax
  jz .failed
  mov rbx, rax
  call pmm_alloc_frame             ;// user stack
  test rax, rax
  jz .failed
  mov [r15+Task.sender], rax        ;// временное поле до запуска IPC
  call pmm_alloc_frame             ;// kernel stack
  test rax, rax
  jz .failed
  mov rdx, rax
  hhdm_address rcx, rax
  add rcx, PAGE_SIZE
  mov [r15+Task.kernel_top], rcx

  ;// Код доступен ring 3 только для чтения/исполнения, стек — для записи.
  mov rdi, [r15+Task.cr3]
  mov rsi, USER.code
  mov rdx, rbx
  mov ecx, PAGE.US
  call vmm_map_in_space
  test rax, rax
  jz .failed
  mov rdi, [r15+Task.cr3]
  mov rsi, USER.stackPage
  mov rdx, [r15+Task.sender]
  mov ecx, PAGE.US+PAGE.RW
  call vmm_map_in_space
  test rax, rax
  jz .failed

  ;// Копируем через HHDM, не делая user-страницу записываемой в её собственном PML4.
  hhdm_address rdi, rbx
  mov rsi, r12
  mov rdx, r13
  call memory_copy
  mov rax, [r15+Task.sender]
  hhdm_address rdi, rax
  xor eax, eax
  mov ecx, PAGE_SIZE/8
  rep stosq
  ;// memory_copy имеет право изменить RDX, поэтому берём вершину из TCB.
  mov rdi, [r15+Task.kernel_top]
  sub rdi, PAGE_SIZE
  xor eax, eax
  mov ecx, PAGE_SIZE/8
  rep stosq

  ;// Искусственный interrupt frame позволяет запустить новую задачу тем же
  ;// путём, как возобновить вытесненную: pop_all_registers + IRETQ.
  mov rdi, [r15+Task.kernel_top]
  sub rdi, Context.size
  mov [r15+Task.saved_rsp], rdi
  mov qword [rdi+Context.rip], USER.code
  mov qword [rdi+Context.cs], SEL.userCode64+3
  mov qword [rdi+Context.rflags], 0x202
  mov rax, USER.stackTop
  mov [rdi+Context.rsp], rax
  mov qword [rdi+Context.ss], SEL.userData64+3
  mov [r15+Task.id], r14
  mov qword [r15+Task.sender], 0
  mov qword [r15+Task.state], TASK_RUNNABLE
  inc dword [task_count]
  mov eax, r14d
  jmp .done

  .failed:
  mov rax, -1
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Вставить типизированную capability в первый свободный слот.
;// RDI=owner, RSI=type, RDX=object, RCX=rights. RAX=handle или 0.
function capability_insert
  push rbx
  push r12
  push r13
  push r14
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  call task_by_index
  xor ecx, ecx
  .find_slot:
    cmp qword [rax+Task.cap_target+rcx*8], 0
    je .found
    inc ecx
    cmp ecx, CAP_SLOTS
    jb .find_slot
    xor eax, eax
    jmp .done
  .found:
    mov [rax+Task.cap_target+rcx*8], r13
    mov [rax+Task.cap_rights+rcx*8], r14
    mov [rax+Task.cap_type+rcx*8], r12
    lea eax, [ecx+1]                ;// нуль никогда не является capability
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Выдать endpoint capability. RDI=owner, RSI=target, RDX=rights.
function capability_grant
  mov rcx, rdx
  lea rdx, [rsi+1]                  ;// в слоте index+1, чтобы object=0 означал пустоту
  mov esi, CAP_ENDPOINT
  call capability_insert
endf

;// Найти capability текущей задачи.
;// RDI=handle, RSI=type, RDX=required rights. RAX=object, RCX=slot; RAX=0 при ошибке.
function capability_lookup
  push rbx
  push r12
  mov rbx, rdi
  mov r12, rdx
  test rbx, rbx
  jz .failed
  cmp rbx, CAP_SLOTS
  ja .failed
  dec rbx
  mov edi, [current_task]
  call task_by_index
  cmp [rax+Task.cap_type+rbx*8], rsi
  jne .failed
  mov rcx, [rax+Task.cap_rights+rbx*8]
  and rcx, r12
  cmp rcx, r12
  jne .failed
  mov rax, [rax+Task.cap_target+rbx*8]
  mov rcx, rbx
  jmp .done
  .failed:
  xor eax, eax
  .done:
  pop r12
  pop rbx
endf

;// Активировать задачу RDI. RAX=сохранённый RSP.
function scheduler_activate
  mov [current_task], edi
  call task_by_index
  push rax
  sub rsp, 8
  mov rdi, [rax+Task.kernel_top]
  call task_set_kernel_stack
  add rsp, 8
  pop rax
  mov rdx, [rax+Task.cr3]
  mov cr3, rdx
  mov rax, [rax+Task.saved_rsp]
endf

;// Сохранить RDI=context и выбрать следующую TASK_RUNNABLE. RAX=новый context.
function scheduler_switch
  push rbx
  push r12
  mov r12, rdi
  mov ebx, [current_task]
  cmp ebx, 0
  jl .search_from_zero
  mov edi, ebx
  call task_by_index
  mov [rax+Task.saved_rsp], r12
  inc ebx
  jmp .normalize
  .search_from_zero:
  xor ebx, ebx
  .normalize:
  cmp ebx, [task_count]
  jb .search
  xor ebx, ebx
  .search:
  mov ecx, [task_count]
  .try_task:
    test ecx, ecx
    jz .no_runnable
    mov edi, ebx
    call task_by_index
    cmp qword [rax+Task.state], TASK_RUNNABLE
    je .activate
    inc ebx
    cmp ebx, [task_count]
    jb .next
    xor ebx, ebx
  .next:
    dec ecx
    jmp .try_task
  .activate:
    mov edi, ebx
    call scheduler_activate
    jmp .done
  .no_runnable:
    ;// Все задачи ждут событий. Остаёмся на текущем kernel stack,
    ;// разрешаем IRQ и останавливаем CPU. IRQ1 может сделать драйвер
    ;// RUNNABLE; IRQ0 в idle только увеличивает ticks и возвращается сюда.
    mov byte [scheduler_is_idle], 1
    sti
    hlt
    cli
    mov byte [scheduler_is_idle], 0
    xor ebx, ebx
    jmp .search
  .done:
  pop r12
  pop rbx
endf

;// Первый запуск не возвращается: IRETQ одновременно загружает RIP, CS,
;// RFLAGS, RSP и SS новой ring-3 задачи.
leaf_function scheduler_start
  cmp dword [task_count], 0
  je cpu_halt_forever
  xor edi, edi
  call scheduler_activate
  mov rsp, rax
  pop_all_registers
  iretq
