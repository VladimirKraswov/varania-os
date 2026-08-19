;//////////////////////////////////////////////////////////////////////////////
;// AMD64 SYSCALL ABI и диспетчер системных вызовов
;//////////////////////////////////////////////////////////////////////////////
;
;// ABI намеренно близок к Linux/System V:
;//   RAX = номер; RDI, RSI, RDX, R10, R8, R9 = аргументы; RAX = результ.
;// Возврат делаем через IRETQ, а не SYSRET: он медленнее, но для учебного
;// ядра прозрачнее и безопаснее при неканоническом пользовательском RIP/RSP.

SYS_LOG   = 1
SYS_YIELD = 2
SYS_SEND  = 3
SYS_RECV  = 4
SYS_EXIT  = 5
SYS_IO_READ8  = 6
SYS_IO_WRITE8 = 7
SYS_IRQ_WAIT  = 8

ERR_FAULT = -14
ERR_NOSYS = -38

syscall_user_rsp dq 0

;// Вывести не более 256 байт из user-памяти. RDI=address, RSI=size.
;// Каждый байт проходит page-table validation; ядро не разыменовывает user pointer.
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

;// RDI указывает на единый Context. RAX=контекст, который нужно возобновить.
function syscall_dispatch
  push rbx
  push r12
  mov r12, rdi
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

  .receive:
  mov edi, [current_task]
  call task_by_index
  mov rbx, rax
  cmp qword [rbx+Task.message], 0
  je .block_receiver
  mov rax, [rbx+Task.value]
  mov [r12+Context.rax], rax
  mov rax, [rbx+Task.sender]
  mov [r12+Context.rdx], rax
  mov qword [rbx+Task.message], 0
  jmp .resume_current
  .block_receiver:
  mov qword [rbx+Task.state], TASK_BLOCKED_IPC
  jmp .switch

  .yield:
  mov qword [r12+Context.rax], 0
  jmp .switch

  .exit:
  mov edi, [current_task]
  call task_by_index
  mov qword [rax+Task.state], TASK_EXITED
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

;// Запрограммироват STAR/LSTAR/FMASK и включить EFER.SCE.
function syscall_init
  mov ecx, 0xC0000080              ;// IA32_EFER
  rdmsr
  or eax, 1                        ;// SCE — разрешить SYSCALL/SYSRET
  wrmsr

  mov ecx, 0xC0000081              ;// IA32_STAR
  xor eax, eax
  mov edx, (0x20 shl 16)+SEL.code64 ;// user base=0x20, kernel CS=0x18
  wrmsr
  mov ecx, 0xC0000082              ;// IA32_LSTAR
  lea rax, [syscall_entry]
  mov rdx, rax
  shr rdx, 32
  wrmsr
  mov ecx, 0xC0000084              ;// IA32_FMASK
  mov eax, (1 shl 9)+(1 shl 10)    ;// в ядре IF=0 и DF=0
  xor edx, edx
  wrmsr
endf

;// Процессор не меняет RSP при SYSCALL. Первая операция сохраняет user RSP,
;// затем мы переходим на доверенный стек из TCB и строим кадр точно того же
;// формата, что и IRQ. Это объединяет все пути переключения задач.
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
