;//////////////////////////////////////////////////////////////////////////////
;// AMD64 SYSCALL ABI и диспетчер системных вызовов
;//////////////////////////////////////////////////////////////////////////////
;
;// RAX=номер; RDI,RSI,RDX,R10,R8,R9=аргументы; RAX=результат. Возврат через
;// IRETQ намеренно единообразен с IRQ и безопасен для учебного ядра.

SYS_LOG       = 1
SYS_YIELD     = 2
SYS_SEND      = 3
SYS_RECV      = 4
SYS_EXIT      = 5
SYS_IO_READ8  = 6
SYS_IO_WRITE8 = 7
SYS_IRQ_WAIT  = 8
SYS_SPAWN     = 9
SYS_WAIT      = 10
SYS_BRK       = 11
SYS_MEM_INFO  = 12

ERR_NOENT = -2
ERR_BAD_HANDLE = -9
ERR_NO_MEMORY = -12
ERR_FAULT = -14
ERR_BUSY = -16
ERR_INVALID = -22
ERR_NOSYS = -38

SPAWN_MAX_NAME   = 31
SPAWN_MAX_GRANTS = 4
SpawnGrant.handle = 0
SpawnGrant.rights = 8
SpawnGrant.size   = 16

syscall_user_rsp dq 0

;// Копировать только после page-table validation.
;// RDI=kernel destination, RSI=user source, RDX=size. RAX=1/0.
function syscall_copy_from_user
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov edi, [current_task]
  call task_by_index
  mov r15, [rax+Task.cr3]
  .byte:
    test r14, r14
    jz .success
    mov rax, USER.limit
    cmp r13, rax
    jae .failed
    mov rdi, r15
    mov rsi, r13
    call vmm_translate_user
    test rax, rax
    jz .failed
    hhdm_address rbx, rax
    mov al, [rbx]
    mov [r12], al
    inc r12
    inc r13
    dec r14
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

;// Вывести не более 256 байт из user-памяти.
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
    call print_char
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

;// Создать ELF-процесс и передать до четырёх ослабленных capabilities.
;// RDI=system cap, RSI=name, RDX=name len, RCX=grants, R8=count.
function syscall_spawn
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 104                    ;// name[32], grants[64], child token
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov r15, rcx
  mov rbx, r8

  mov rdi, r12
  mov esi, CAP_SYSTEM
  mov edx, CAP_SPAWN
  call capability_lookup
  test rax, rax
  jz .bad_handle
  test r14, r14
  jz .invalid
  cmp r14, SPAWN_MAX_NAME
  ja .invalid
  cmp rbx, SPAWN_MAX_GRANTS
  ja .invalid

  mov rdi, rsp
  mov rsi, r13
  mov rdx, r14
  call syscall_copy_from_user
  test rax, rax
  jz .fault
  test rbx, rbx
  jz .find_image
  lea rdi, [rsp+32]
  mov rsi, r15
  mov rdx, rbx
  shl rdx, 4
  call syscall_copy_from_user
  test rax, rax
  jz .fault

  .find_image:
  mov rdi, rsp
  mov rsi, r14
  call initramfs_find
  test rax, rax
  jz .not_found
  mov r12, rax                    ;// image
  mov r13, rdx                    ;// image size
  mov edi, [current_task]
  call task_by_index
  mov rdx, [rax+Task.token]
  mov rdi, r12
  mov rsi, r13
  call task_spawn_image
  test rax, rax
  jz .no_memory
  mov [rsp+96], rax               ;// generation-safe child token
  mov r14d, edx                   ;// child slot
  mov edi, r14d
  call task_by_index
  mov r12, rax                    ;// child TCB

  xor r13d, r13d
  .grant:
    cmp r13, rbx
    jae .parent_capability
    ;// Записи по 16 байт: индекс удваивается для qword addressing.
    mov rax, r13
    shl rax, 4
    mov rsi, [rsp+32+rax+SpawnGrant.handle]
    mov rdx, [rsp+32+rax+SpawnGrant.rights]
    mov rdi, r12
    call capability_clone_current
    test rax, rax
    jz .discard_bad_grant
    inc r13
    jmp .grant

  .parent_capability:
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov esi, CAP_PROCESS
  mov rdx, [rsp+96]
  mov ecx, CAP_SEND+CAP_WAIT
  call capability_insert_task
  test rax, rax
  jz .discard_no_memory
  mov r13, rax                    ;// вернуть handle после commit IRQ transfer
  mov edi, [current_task]
  call task_by_index
  mov rdi, r12                    ;// child
  mov rsi, rax                    ;// parent
  call device_commit_irq_transfers
  mov rax, r13
  jmp .done

  .discard_bad_grant:
  mov r15, ERR_BAD_HANDLE
  jmp .discard_child
  .discard_no_memory:
  mov r15, ERR_NO_MEMORY
  .discard_child:
  mov rdi, r12
  mov esi, r14d
  call task_discard_new
  mov rax, r15
  jmp .done
  .bad_handle:
  mov rax, ERR_BAD_HANDLE
  jmp .done
  .not_found:
  mov rax, ERR_NOENT
  jmp .done
  .no_memory:
  mov rax, ERR_NO_MEMORY
  jmp .done
  .fault:
  mov rax, ERR_FAULT
  jmp .done
  .invalid:
  mov rax, ERR_INVALID
  .done:
  add rsp, 104
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
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
  cmp rax, SYS_SEND
  je .send
  cmp rax, SYS_RECV
  je .receive
  cmp rax, SYS_EXIT
  je .exit
  cmp rax, SYS_IO_READ8
  je .io_read8
  cmp rax, SYS_IO_WRITE8
  je .io_write8
  cmp rax, SYS_IRQ_WAIT
  je .irq_wait
  cmp rax, SYS_SPAWN
  je .spawn
  cmp rax, SYS_WAIT
  je .wait
  cmp rax, SYS_BRK
  je .brk
  cmp rax, SYS_MEM_INFO
  je .memory_info
  mov qword [r12+Context.rax], ERR_NOSYS
  jmp .resume_current

  .log:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call syscall_log
  mov [r12+Context.rax], rax
  jmp .resume_current

  .send:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  call ipc_send
  mov [r12+Context.rax], rax
  jmp .resume_current

  .receive:
  call ipc_receive
  test rcx, rcx
  jz .switch
  mov [r12+Context.rax], rax
  mov [r12+Context.rdx], rdx
  jmp .resume_current

  .spawn:
  mov rdi, [r12+Context.rdi]
  mov rsi, [r12+Context.rsi]
  mov rdx, [r12+Context.rdx]
  mov rcx, [r12+Context.r10]
  mov r8, [r12+Context.r8]
  call syscall_spawn
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
