;//////////////////////////////////////////////////////////////////////////////
;// Динамические процессы ring 3 и вытесняющий round-robin
;//////////////////////////////////////////////////////////////////////////////
;
;// В таблице лежат указатели на TCB из slab. Слот переиспользуется после
;// SYS_WAIT, а generation в token защищает от устаревших capabilities:
;// token = generation:32 | (slot+1):32.

Task.state        = 0
Task.saved_rsp    = 8
Task.cr3          = 16
Task.kernel_top   = 24
Task.kernel_frame = 32
Task.token        = 40
Task.parent       = 48
Task.exit_code    = 56
Task.stack_low    = 64
Task.stack_limit  = 72
Task.brk_base     = 80
Task.brk_current  = 88
Task.wait_irq     = 96
Task.waiter       = 104
Task.wait_target  = 112
Task.wait_cap     = 120
Task.cap_target   = 128             ;// CAP_SLOTS qword
Task.cap_rights   = 256
Task.cap_type     = 384
Task.cap_node     = 512             ;// lineage node для revoke descendants
Task.space         = 640            ;// AddressSpace object для low-level create
Task.wait_endpoint = 648            ;// Endpoint object при блокировке IPC
Task.wait_buffer   = 656            ;// user IpcMessage*
Task.size          = 664

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

TASK_MAX          = 16
TASK_EMPTY        = 0
TASK_RUNNABLE     = 1
TASK_BLOCKED_IPC  = 2
TASK_BLOCKED_IRQ  = 3
TASK_BLOCKED_WAIT = 4
TASK_ZOMBIE       = 5               ;// ресурсы ещё принадлежат задаче
TASK_REAPABLE     = 6               ;// ресурсы освобождены, статус ждёт parent
TASK_ZOMBIE_REAP  = 7               ;// waiter получил статус, удалить TCB
TASK_SUSPENDED    = 8

CAP_SLOTS    = 16

;// Узел происхождения capability. Дерево хранится отдельно от object refcount:
;// close освобождает право текущего holder, revoke обходит только потомков.
CapNode.parent       = 0
CapNode.first_child  = 8
CapNode.next_sibling = 16
CapNode.prev_sibling = 24
CapNode.owner        = 32           ;// generation-safe task token или 0
CapNode.slot         = 40           ;// zero-based slot или -1 у ghost node
CapNode.pinned       = 48           ;// очередь IPC временно запрещает prune
CapNode.revoked      = 56           ;// queued descendant уже отозван
CapNode.bytes        = 64

USER.imageMin       = 0x0000000000010000
USER.imageMax       = 0x0000000040000000
USER.bootfsBase     = 0x0000000080000000
USER.stackTop       = 0x00007FFFFFF00000
USER.stackMaxPages  = 16
USER.stackLimit     = USER.stackTop-USER.stackMaxPages*PAGE_SIZE
USER.heapMaxPages   = 256
USER.limit          = 0x0000800000000000

align 16
tasks dq TASK_MAX dup(0)
task_generations dd TASK_MAX dup(0)
task_live_count dd 0
current_task dd -1
current_kernel_stack dq 0
scheduler_is_idle db 0

gdt64_descriptor_high:
  dw GDT64.size-1
  dq HHDM.base+GDT64.base

init_program_name db "procd.elf"
init_program_name.size = $-init_program_name

;// RDI=slot. RAX=TCB или 0.
leaf_function task_by_index
  cmp edi, TASK_MAX
  jae .invalid
  lea rax, [tasks]
  mov rax, [rax+rdi*8]
  ret
  .invalid:
  xor eax, eax
end_leaf

;// RDI=token. Проверяются и slot, и generation. RAX=TCB или 0.
leaf_function task_from_token
  mov rdx, rdi
  mov ecx, edi
  test ecx, ecx
  jz .invalid
  dec ecx
  cmp ecx, TASK_MAX
  jae .invalid
  lea rax, [tasks]
  mov rax, [rax+rcx*8]
  test rax, rax
  jz .invalid
  cmp [rax+Task.token], rdx
  jne .invalid
  ret
  .invalid:
  xor eax, eax
end_leaf

;// Создать lineage node и, если задан parent, вставить первым ребёнком.
;// RDI=parent/0, RSI=owner token/0, RDX=slot/-1. RAX=node/0.
function cap_node_create
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  test r12, r12
  jz .allocate
  cmp qword [r12+CapNode.revoked], 0
  jne .failed
  .allocate:
  mov edi, CapNode.bytes
  call kmalloc
  test rax, rax
  jz .done
  mov rbx, rax
  mov rdi, rax
  xor eax, eax
  mov ecx, CapNode.bytes/8
  rep stosq
  mov [rbx+CapNode.parent], r12
  mov [rbx+CapNode.owner], r13
  mov [rbx+CapNode.slot], r14
  test r12, r12
  jz .return_node
  mov rax, [r12+CapNode.first_child]
  mov [rbx+CapNode.next_sibling], rax
  test rax, rax
  jz .link_head
  mov [rax+CapNode.prev_sibling], rbx
  .link_head:
  mov [r12+CapNode.first_child], rbx
  .return_node:
  mov rax, rbx
  jmp .done
  .failed:
  xor eax, eax
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Удалить ghost node без holder и детей; затем собрать пустых ghost ancestors.
;// RDI=node/0.
function cap_node_prune
  push rbx
  push r12
  push r13
  push r14
  mov rbx, rdi
  .node:
    test rbx, rbx
    jz .done
    cmp qword [rbx+CapNode.owner], 0
    jne .done
    cmp qword [rbx+CapNode.first_child], 0
    jne .done
    cmp qword [rbx+CapNode.pinned], 0
    jne .done
    mov r12, [rbx+CapNode.parent]
    mov r13, [rbx+CapNode.prev_sibling]
    mov r14, [rbx+CapNode.next_sibling]
    test r13, r13
    jz .parent_head
    mov [r13+CapNode.next_sibling], r14
    jmp .link_next
  .parent_head:
    test r12, r12
    jz .link_next
    mov [r12+CapNode.first_child], r14
  .link_next:
    test r14, r14
    jz .free
    mov [r14+CapNode.prev_sibling], r13
  .free:
    mov rdi, rbx
    call kfree
    mov rbx, r12
    jmp .node
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Отозвать node, holder и всё поддерево. RDI=node. RAX=число закрытых handles.
function cap_node_revoke_subtree
  push rbx
  push r12
  push r13
  push r14
  mov rbx, rdi
  xor r14d, r14d
  mov qword [rbx+CapNode.revoked], 1
  inc qword [rbx+CapNode.pinned]    ;// не дать descendant prune удалить parent
  mov r12, [rbx+CapNode.first_child]
  .children:
    test r12, r12
    jz .holder
    mov r13, [r12+CapNode.next_sibling]
    mov rdi, r12
    call cap_node_revoke_subtree
    add r14, rax
    mov r12, r13
    jmp .children
  .holder:
  mov rdi, [rbx+CapNode.owner]
  test rdi, rdi
  jz .prune
  call task_from_token
  test rax, rax
  jz .make_ghost
  mov r12, rax
  mov r13, [rbx+CapNode.slot]
  cmp r13, CAP_SLOTS
  jae .make_ghost
  cmp [r12+Task.cap_node+r13*8], rbx
  jne .make_ghost
  mov rdi, [r12+Task.cap_type+r13*8]
  mov rsi, [r12+Task.cap_target+r13*8]
  mov qword [r12+Task.cap_target+r13*8], 0
  mov qword [r12+Task.cap_rights+r13*8], 0
  mov qword [r12+Task.cap_type+r13*8], 0
  mov qword [r12+Task.cap_node+r13*8], 0
  mov qword [rbx+CapNode.owner], 0
  mov qword [rbx+CapNode.slot], -1
  call capability_release
  inc r14
  jmp .prune
  .make_ghost:
  mov qword [rbx+CapNode.owner], 0
  mov qword [rbx+CapNode.slot], -1
  .prune:
  dec qword [rbx+CapNode.pinned]
  mov rdi, rbx
  call cap_node_prune
  mov rax, r14
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Выделить TCB и свободный slot. RAX=TCB, RDX=token, RCX=slot; либо RAX=0.
function task_allocate
  push rbx
  push r12
  xor ebx, ebx
  lea r12, [tasks]
  .find:
    cmp qword [r12+rbx*8], 0
    je .slot
    inc ebx
    cmp ebx, TASK_MAX
    jb .find
  xor eax, eax
  jmp .done
  .slot:
  mov edi, Task.size
  call kmalloc
  test rax, rax
  jz .done
  mov [r12+rbx*8], rax
  push rax
  mov rdi, rax
  xor eax, eax
  mov ecx, Task.size/8
  rep stosq
  pop rax

  lea rdi, [task_generations]
  inc dword [rdi+rbx*4]
  jnz .generation_ok
  inc dword [rdi+rbx*4]           ;// generation=0 зарезервировано
  .generation_ok:
  mov edx, [rdi+rbx*4]
  shl rdx, 32
  lea ecx, [ebx+1]
  or rdx, rcx
  mov [rax+Task.token], rdx
  mov ecx, ebx
  inc dword [task_live_count]
  .done:
  pop r12
  pop rbx
endf

;// RDI=вершина ядерного стека.
leaf_function task_set_kernel_stack
  mov [current_kernel_stack], rdi
  hhdm_address rax, TSS64.base
  mov [rax+4], rdi
end_leaf

;// Полностью удалить ещё не запускавшийся процесс после ошибки ELF/grants.
;// RDI=TCB, RSI=slot.
function task_discard_new
  push rbx
  push r12
  mov rbx, rdi
  mov r12, rsi
  mov rdi, rbx
  call capability_clear_all
  mov rsi, [rbx+Task.space]
  test rsi, rsi
  jz .legacy_space
  mov edi, CAP_SPACE
  call object_release
  mov qword [rbx+Task.space], 0
  mov qword [rbx+Task.cr3], 0
  jmp .kernel_stack
  .legacy_space:
  mov rdi, [rbx+Task.cr3]
  test rdi, rdi
  jz .kernel_stack
  call vmm_destroy_space
  .kernel_stack:
  mov rdi, [rbx+Task.kernel_frame]
  test rdi, rdi
  jz .remove
  call pmm_free_frame
  .remove:
  lea rax, [tasks]
  mov qword [rax+r12*8], 0
  mov rdi, rbx
  call kfree
  dec dword [task_live_count]
  pop r12
  pop rbx
endf

;// Создать процесс из проверяемого ELF64-образа.
;// RDI=image, RSI=size, RDX=parent token. RAX=child token, RDX=slot; RAX=0.
function task_spawn_image
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi                     ;// image
  mov r13, rsi                     ;// size
  mov r14, rdx                     ;// parent
  call task_allocate
  test rax, rax
  jz .failed_without_task
  mov r15, rax                     ;// TCB
  mov rbx, rdx                     ;// token
  mov [rsp], rcx                   ;// slot в локальной переменной

  mov [r15+Task.parent], r14
  mov qword [r15+Task.wait_irq], -1
  call vmm_create_space
  test rax, rax
  jz .discard
  mov [r15+Task.cr3], rax

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

  mov rdi, [r15+Task.cr3]
  mov rsi, USER.stackTop-PAGE_SIZE
  mov rdx, PAGE.US+PAGE.RW+PAGE.NX
  call vmm_alloc_user_page
  test rax, rax
  jz .discard
  mov rax, USER.stackTop-PAGE_SIZE
  mov [r15+Task.stack_low], rax
  mov rax, USER.stackLimit
  mov [r15+Task.stack_limit], rax

  mov rdi, r15
  mov rsi, r12
  mov rdx, r13
  call elf_load_process
  test rax, rax
  jz .discard

  mov rdi, [r15+Task.kernel_top]
  sub rdi, Context.size
  mov [r15+Task.saved_rsp], rdi
  mov [rdi+Context.rip], rax
  mov qword [rdi+Context.cs], SEL.userCode64+3
  mov qword [rdi+Context.rflags], 0x202
  mov rax, USER.stackTop
  mov [rdi+Context.rsp], rax
  mov qword [rdi+Context.ss], SEL.userData64+3
  mov qword [r15+Task.state], TASK_RUNNABLE
  mov rdx, [rsp]                     ;// slot
  mov rax, rbx                       ;// token
  jmp .done

  .discard:
  mov rsi, [rsp]                     ;// slot
  mov rdi, r15
  call task_discard_new
  .failed_without_task:
  xor eax, eax
  xor edx, edx
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Освободить объект, на который ссылалась capability.
;// Для специальных kernel token (process/IRQ/I/O/system/bootfs) это no-op.
;// RDI=type, RSI=target.
function capability_release
  call object_release
endf

;// RDI=TCB, RSI=zero-based slot. Закрывает handle и освобождает его ссылку.
function capability_clear_slot
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov rbx, rdi
  mov r12, rsi
  cmp r12, CAP_SLOTS
  jae .done
  mov rsi, [rbx+Task.cap_target+r12*8]
  mov r13, [rbx+Task.cap_node+r12*8]
  mov rdi, [rbx+Task.cap_type+r12*8]
  mov qword [rbx+Task.cap_target+r12*8], 0
  mov qword [rbx+Task.cap_rights+r12*8], 0
  mov qword [rbx+Task.cap_type+r12*8], 0
  mov qword [rbx+Task.cap_node+r12*8], 0
  test r13, r13
  jz .release
  mov qword [r13+CapNode.owner], 0
  mov qword [r13+CapNode.slot], -1
  .release:
  test rsi, rsi
  jz .prune
  call capability_release
  .prune:
  mov rdi, r13
  call cap_node_prune
  .done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf

;// RDI=TCB. Закрыть все capabilities при завершении процесса.
function capability_clear_all
  push rbx
  push r12
  mov rbx, rdi
  xor r12d, r12d
  .next:
    mov rdi, rbx
    mov rsi, r12
    call capability_clear_slot
    inc r12
    cmp r12, CAP_SLOTS
    jb .next
  pop r12
  pop rbx
endf

;// Общая вставка capability. R8=parent lineage node или 0 для нового root.
;// RDI=TCB, RSI=type, RDX=object, RCX=rights. RAX=handle или 0.
function capability_insert_task_with_parent
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  xor eax, eax
  .find:
    cmp qword [rbx+Task.cap_target+rax*8], 0
    je .found
    inc eax
    cmp eax, CAP_SLOTS
    jb .find
  xor eax, eax
  jmp .done
  .found:
  mov [rsp], rax
  mov rdi, r15
  mov rsi, [rbx+Task.token]
  mov rdx, rax
  call cap_node_create
  test rax, rax
  jz .failed
  mov r15, rax
  mov rdi, r12
  mov rsi, r13
  call object_retain
  mov rax, [rsp]
  mov [rbx+Task.cap_target+rax*8], r13
  mov [rbx+Task.cap_rights+rax*8], r14
  mov [rbx+Task.cap_type+rax*8], r12
  mov [rbx+Task.cap_node+rax*8], r15
  inc eax
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

;// Создать корневую capability без предка.
function capability_insert_task
  xor r8d, r8d
  call capability_insert_task_with_parent
endf

;// Создать attenuated child capability в lineage tree.
;// R8=parent node.
function capability_insert_task_derived
  call capability_insert_task_with_parent
endf

;// RDI=owner slot, остальные аргументы как capability_insert_task.
function capability_insert
  sub rsp, 8
  push rsi
  push rdx
  push rcx
  call task_by_index
  mov rdi, rax
  pop rcx
  pop rdx
  pop rsi
  add rsp, 8
  test rdi, rdi
  jz .failed
  call capability_insert_task
  jmp .done
  .failed:
  xor eax, eax
  .done:
endf

;// RDI=owner slot, RSI=target slot, RDX=rights.
function capability_grant
  push rbx
  push r12
  mov ebx, edi
  mov r12, rdx
  mov edi, esi
  call task_by_index
  test rax, rax
  jz .failed
  mov rdx, [rax+Task.token]
  mov edi, ebx
  mov esi, CAP_PROCESS
  mov rcx, r12
  call capability_insert
  jmp .done
  .failed:
  xor eax, eax
  .done:
  pop r12
  pop rbx
endf

;// RDI=handle, RSI=type, RDX=required rights. RAX=object, RCX=zero-based slot.
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
  test rax, rax
  jz .failed
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

;// Найти capability любого типа у текущей задачи.
;// RDI=handle. RAX=target, RDX=type, RCX=rights, R8=zero-based slot; RAX=0.
function capability_lookup_any_current
  push rbx
  mov rbx, rdi
  test rbx, rbx
  jz .failed
  cmp rbx, CAP_SLOTS
  ja .failed
  dec rbx
  mov edi, [current_task]
  call task_by_index
  test rax, rax
  jz .failed
  mov rdx, [rax+Task.cap_type+rbx*8]
  mov rcx, [rax+Task.cap_rights+rbx*8]
  mov rax, [rax+Task.cap_target+rbx*8]
  test rax, rax
  jz .failed
  mov r8, rbx
  jmp .done
  .failed:
  xor eax, eax
  .done:
  pop rbx
endf

;// Закрыть capability текущего процесса. RDI=handle. RAX=0/-9.
function capability_close_current
  push rbx
  mov rbx, rdi
  test rbx, rbx
  jz .bad
  cmp rbx, CAP_SLOTS
  ja .bad
  dec rbx
  mov edi, [current_task]
  call task_by_index
  test rax, rax
  jz .bad
  cmp qword [rax+Task.cap_target+rbx*8], 0
  je .bad
  mov rdi, rax
  mov rsi, rbx
  call capability_clear_slot
  xor eax, eax
  jmp .done
  .bad:
  mov rax, -9
  .done:
  pop rbx
endf

;// Отозвать все capabilities, выведенные из указанного handle. Сам root
;// остаётся действующим и может снова делегировать право. RDI=handle.
;// RAX=число отозванных handles либо -9.
function capability_revoke_current
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov rbx, rdi
  test rbx, rbx
  jz .bad
  cmp rbx, CAP_SLOTS
  ja .bad
  dec rbx
  mov edi, [current_task]
  call task_by_index
  test rax, rax
  jz .bad
  mov r12, [rax+Task.cap_node+rbx*8]
  test r12, r12
  jz .bad
  xor ebx, ebx
  mov rdi, [r12+CapNode.first_child]
  .child:
    test rdi, rdi
    jz .done
    mov r13, [rdi+CapNode.next_sibling]
    call cap_node_revoke_subtree
    add rbx, rax
    mov rdi, r13
    jmp .child
  .done:
  mov rax, rbx
  jmp .return
  .bad:
  mov rax, -9
  .return:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf

;// Отделить capability без уменьшения refs. Нужен, когда ownership frame или
;// space переходит из handle в mapping/thread. RDI=handle, RSI=expected type.
;// RAX=target или 0.
function capability_take_current
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov rbx, rdi
  mov r12, rsi
  call capability_lookup_any_current
  test rax, rax
  jz .failed
  cmp rdx, r12
  jne .failed
  mov rbx, rax
  mov r13, r8
  mov edi, [current_task]
  call task_by_index
  mov r12, [rax+Task.cap_node+r13*8]
  mov qword [rax+Task.cap_target+r13*8], 0
  mov qword [rax+Task.cap_rights+r13*8], 0
  mov qword [rax+Task.cap_type+r13*8], 0
  mov qword [rax+Task.cap_node+r13*8], 0
  test r12, r12
  jz .taken
  mov qword [r12+CapNode.owner], 0
  mov qword [r12+CapNode.slot], -1
  mov rdi, r12
  call cap_node_prune
  .taken:
  mov rax, rbx
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf

;// RDI=TCB. RAX=число свободных handle slots.
leaf_function capability_free_count
  xor eax, eax
  xor ecx, ecx
  .slot:
    cmp qword [rdi+Task.cap_target+rcx*8], 0
    jne .next
    inc eax
  .next:
    inc ecx
    cmp ecx, CAP_SLOTS
    jb .slot
end_leaf

;// Скопировать capability текущего процесса ребёнку с ослаблением прав.
;// RDI=child TCB, RSI=parent handle, RDX=requested rights. RAX=child handle/0.
function capability_clone_current
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  test r13, r13
  jz .failed
  cmp r13, CAP_SLOTS
  ja .failed
  test r14, r14
  jz .failed
  dec r13
  mov edi, [current_task]
  call task_by_index
  test rax, rax
  jz .failed
  mov rcx, [rax+Task.cap_rights+r13*8]
  mov rdx, rcx
  and rdx, r14
  cmp rdx, r14
  jne .failed
  mov rbx, [rax+Task.cap_type+r13*8]
  mov rdx, [rax+Task.cap_target+r13*8]
  mov r8, [rax+Task.cap_node+r13*8]
  test rdx, rdx
  jz .failed
  mov rdi, r12
  mov rsi, rbx
  mov rcx, r14
  call capability_insert_task_derived
  jmp .done
  .failed:
  xor eax, eax
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// RDI=TCB; текущую задачу сюда передавать нельзя.
function task_release_resources
  push rbx
  sub rsp, 8
  mov rbx, rdi
  mov rdi, [rbx+Task.token]
  call device_release_task
  mov rdi, rbx
  call capability_clear_all

  ;// Low-level THREAD_CREATE передаёт объект пространства задаче. Старый
  ;// bootstrap loader пока заполняет только Task.cr3.
  mov rsi, [rbx+Task.space]
  test rsi, rsi
  jz .legacy_space
  mov edi, CAP_SPACE
  call object_release
  mov qword [rbx+Task.space], 0
  mov qword [rbx+Task.cr3], 0
  jmp .stack
  .legacy_space:
  mov rdi, [rbx+Task.cr3]
  test rdi, rdi
  jz .stack
  call vmm_destroy_space
  mov qword [rbx+Task.cr3], 0
  .stack:
  mov rdi, [rbx+Task.kernel_frame]
  test rdi, rdi
  jz .done
  call pmm_free_frame
  mov qword [rbx+Task.kernel_frame], 0
  mov qword [rbx+Task.kernel_top], 0
  .done:
  add rsp, 8
  pop rbx
endf

;// RDI=slot, RSI=TCB.
function task_remove
  push rbx
  mov ebx, edi
  lea rax, [tasks]
  mov qword [rax+rbx*8], 0
  mov rdi, rsi
  call kfree
  dec dword [task_live_count]
  pop rbx
endf

;// Убрать задачу из wait-структуры перед внешним kill.
;// RDI=TCB. Обычный EXIT вызывается из RUNNABLE и проходит этот код как no-op.
function task_cancel_block
  push rbx
  push r12
  mov rbx, rdi
  cmp qword [rbx+Task.state], TASK_BLOCKED_IPC
  je .ipc
  cmp qword [rbx+Task.state], TASK_BLOCKED_WAIT
  je .wait
  cmp qword [rbx+Task.state], TASK_BLOCKED_IRQ
  je .irq
  jmp .done
  .ipc:
  mov r12, [rbx+Task.wait_endpoint]
  test r12, r12
  jz .clear_ipc
  mov rax, [rbx+Task.token]
  cmp [r12+Endpoint.waiter], rax
  jne .release_endpoint
  mov qword [r12+Endpoint.waiter], 0
  .release_endpoint:
  mov edi, CAP_ENDPOINT
  mov rsi, r12
  call object_release
  .clear_ipc:
  mov qword [rbx+Task.wait_endpoint], 0
  mov qword [rbx+Task.wait_buffer], 0
  jmp .done
  .wait:
  mov rdi, [rbx+Task.wait_target]
  test rdi, rdi
  jz .clear_wait
  call task_from_token
  test rax, rax
  jz .clear_wait
  mov rdx, [rbx+Task.token]
  cmp [rax+Task.waiter], rdx
  jne .clear_wait
  mov qword [rax+Task.waiter], 0
  .clear_wait:
  mov qword [rbx+Task.wait_target], 0
  mov qword [rbx+Task.wait_cap], 0
  jmp .done
  .irq:
  mov qword [rbx+Task.wait_irq], -1
  .done:
  pop r12
  pop rbx
endf

;// Завершить произвольную задачу и немедленно разбудить её waiter.
;// RDI=TCB, RSI=exit code. Ресурсы освободит scheduler на чужом CR3/stack.
function task_mark_exit_tcb
  push rbx
  push r12
  push r13
  mov rbx, rdi
  mov r13, rsi
  mov rdi, rbx
  call task_cancel_block
  mov [rbx+Task.exit_code], r13
  mov qword [rbx+Task.state], TASK_ZOMBIE
  mov rdi, [rbx+Task.waiter]
  test rdi, rdi
  jz .done
  call task_from_token
  test rax, rax
  jz .done
  mov r12, rax
  cmp qword [r12+Task.state], TASK_BLOCKED_WAIT
  jne .done
  mov rdx, [rbx+Task.token]
  cmp [r12+Task.wait_target], rdx
  jne .done
  mov rdx, [r12+Task.saved_rsp]
  mov [rdx+Context.rax], r13
  mov rcx, [r12+Task.wait_cap]
  mov rdi, r12
  mov rsi, rcx
  call capability_clear_slot
  mov qword [r12+Task.wait_target], 0
  mov qword [r12+Task.state], TASK_RUNNABLE
  mov qword [rbx+Task.waiter], 0
  mov qword [rbx+Task.state], TASK_ZOMBIE_REAP
  .done:
  pop r13
  pop r12
  pop rbx
endf

;// Завершить текущий процесс. RDI=exit code.
function task_mark_exit
  push rbx
  mov rbx, rdi
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov rsi, rbx
  call task_mark_exit_tcb
  pop rbx
endf

;// Внешнее завершение по process capability. RDI=handle, RSI=status.
function task_kill
  push rbx
  push r12
  mov r12, rsi
  mov esi, CAP_PROCESS
  mov edx, CAP_CONTROL
  call capability_lookup
  test rax, rax
  jz .bad
  mov rdi, rax
  call task_from_token
  test rax, rax
  jz .bad
  mov rbx, rax
  mov edi, [current_task]
  call task_by_index
  cmp rax, rbx
  je .invalid
  mov rax, [rbx+Task.state]
  cmp rax, TASK_ZOMBIE
  je .busy
  cmp rax, TASK_REAPABLE
  je .busy
  cmp rax, TASK_ZOMBIE_REAP
  je .busy
  mov rdi, rbx
  mov rsi, r12
  call task_mark_exit_tcb
  xor eax, eax
  jmp .done
  .bad:
  mov rax, -9
  jmp .done
  .busy:
  mov rax, -16
  jmp .done
  .invalid:
  mov rax, -22
  .done:
  pop r12
  pop rbx
endf

;// Освободить zombies, кроме текущей задачи, на безопасном чужом CR3/stack.
function task_cleanup_zombies
  push rbx
  push r12
  xor ebx, ebx
  .scan:
    cmp ebx, [current_task]
    je .next
    mov edi, ebx
    call task_by_index
    test rax, rax
    jz .next
    mov r12, rax
    mov rax, [r12+Task.state]
    cmp rax, TASK_ZOMBIE
    je .release_keep_status
    cmp rax, TASK_ZOMBIE_REAP
    jne .next
    mov rdi, r12
    call task_release_resources
    mov edi, ebx
    mov rsi, r12
    call task_remove
    jmp .next
  .release_keep_status:
    mov rdi, r12
    call task_release_resources
    mov qword [r12+Task.state], TASK_REAPABLE
  .next:
    inc ebx
    cmp ebx, TASK_MAX
    jb .scan
  pop r12
  pop rbx
endf

;// RDI=process handle. RAX=status/error; RCX=1 готово, RCX=0 blocked.
function task_wait
  push rbx
  push r12
  push r13
  push r14
  mov esi, CAP_PROCESS
  mov edx, CAP_WAIT
  call capability_lookup
  test rax, rax
  jz .bad
  mov r12, rax                    ;// target token
  mov r13, rcx                    ;// capability slot
  mov rdi, r12
  call task_from_token
  test rax, rax
  jz .bad
  mov rbx, rax                    ;// target TCB
  mov eax, [current_task]
  inc eax
  cmp eax, r12d
  je .bad
  cmp qword [rbx+Task.state], TASK_ZOMBIE
  je .reap_with_resources
  cmp qword [rbx+Task.state], TASK_REAPABLE
  je .reap
  cmp qword [rbx+Task.waiter], 0
  jne .busy

  mov edi, [current_task]
  call task_by_index
  mov r14, rax
  mov qword [r14+Task.state], TASK_BLOCKED_WAIT
  mov [r14+Task.wait_target], r12
  mov [r14+Task.wait_cap], r13
  mov rax, [r14+Task.token]
  mov [rbx+Task.waiter], rax
  xor eax, eax
  xor ecx, ecx
  jmp .done

  .reap_with_resources:
  mov rdi, rbx
  call task_release_resources
  .reap:
  mov r14, [rbx+Task.exit_code]
  mov edi, [current_task]
  call task_by_index
  mov rdi, rax
  mov rsi, r13
  call capability_clear_slot
  mov edi, r12d
  dec edi
  mov rsi, rbx
  call task_remove
  mov rax, r14
  mov ecx, 1
  jmp .done
  .bad:
  mov rax, -9
  mov ecx, 1
  jmp .done
  .busy:
  mov rax, -16
  mov ecx, 1
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Изменить program break текущего процесса. RDI=новый break, 0=query.
function task_set_brk
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r14, rdi
  mov edi, [current_task]
  call task_by_index
  mov r12, rax
  mov r13, [r12+Task.brk_current]
  test r14, r14
  jz .return_current
  cmp r14, [r12+Task.brk_base]
  jb .invalid
  mov rax, [r12+Task.brk_base]
  add rax, USER.heapMaxPages*PAGE_SIZE
  cmp r14, rax
  ja .invalid
  cmp r14, r13
  jb .shrink
  je .return_current

  lea r15, [r13+PAGE_SIZE-1]
  and r15, -PAGE_SIZE
  lea rbx, [r14+PAGE_SIZE-1]
  and rbx, -PAGE_SIZE
  .grow_page:
    cmp r15, rbx
    jae .commit
    mov rdi, [r12+Task.cr3]
    mov rsi, r15
    mov rdx, PAGE.US+PAGE.RW+PAGE.NX
    call vmm_alloc_user_page
    test rax, rax
    jz .rollback
    add r15, PAGE_SIZE
    jmp .grow_page
  .rollback:
    lea rbx, [r13+PAGE_SIZE-1]
    and rbx, -PAGE_SIZE
  .rollback_page:
    cmp rbx, r15
    jae .no_memory
    mov rdi, [r12+Task.cr3]
    mov rsi, rbx
    call vmm_unmap_in_space
    mov rdi, rax
    call pmm_free_frame
    add rbx, PAGE_SIZE
    jmp .rollback_page
  .no_memory:
    mov rax, -12
    jmp .done

  .shrink:
  lea r15, [r14+PAGE_SIZE-1]
  and r15, -PAGE_SIZE
  lea rbx, [r13+PAGE_SIZE-1]
  and rbx, -PAGE_SIZE
  .free_page:
    cmp r15, rbx
    jae .commit
    mov rdi, [r12+Task.cr3]
    mov rsi, r15
    call vmm_unmap_in_space
    test rax, rax
    jz .next_free
    mov rdi, rax
    call pmm_free_frame
  .next_free:
    add r15, PAGE_SIZE
    jmp .free_page

  .commit:
  mov [r12+Task.brk_current], r14
  mov rax, r14
  jmp .done
  .return_current:
  mov rax, r13
  jmp .done
  .invalid:
  mov rax, -22
  .done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Demand-growth user stack. RDI=#PF error. RAX=1 если страница добавлена.
function task_handle_page_fault
  push rbx
  push r12
  test dil, 1
  jnz .not_stack
  mov rbx, cr2
  mov r12, rbx
  and r12, -PAGE_SIZE
  mov edi, [current_task]
  call task_by_index
  test rax, rax
  jz .not_stack
  cmp r12, [rax+Task.stack_limit]
  jb .not_stack
  cmp r12, [rax+Task.stack_low]
  jae .not_stack
  mov rdx, [rax+Task.stack_low]
  sub rdx, PAGE_SIZE
  cmp r12, rdx
  jne .not_stack
  mov rdi, [rax+Task.cr3]
  mov rsi, r12
  mov rdx, PAGE.US+PAGE.RW+PAGE.NX
  push rax
  sub rsp, 8
  call vmm_alloc_user_page
  add rsp, 8
  pop rdx
  test rax, rax
  jz .not_stack
  mov [rdx+Task.stack_low], r12
  mov eax, 1
  jmp .done
  .not_stack:
  xor eax, eax
  .done:
  pop r12
  pop rbx
endf

;// Активировать slot RDI. RAX=сохранённый RSP.
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

;// Сохранить RDI=context и выбрать следующий TASK_RUNNABLE.
function scheduler_switch
  push rbx
  push r12
  mov r12, rdi
  call task_cleanup_zombies
  mov ebx, [current_task]
  cmp ebx, 0
  jl .search_zero
  mov edi, ebx
  call task_by_index
  test rax, rax
  jz .advance
  mov [rax+Task.saved_rsp], r12
  .advance:
  inc ebx
  cmp ebx, TASK_MAX
  jb .search
  .search_zero:
  xor ebx, ebx
  .search:
  mov ecx, TASK_MAX
  .try:
    mov edi, ebx
    push rcx
    call task_by_index
    pop rcx
    test rax, rax
    jz .next
    cmp qword [rax+Task.state], TASK_RUNNABLE
    je .activate
  .next:
    inc ebx
    cmp ebx, TASK_MAX
    jb .continue
    xor ebx, ebx
  .continue:
    dec ecx
    jnz .try
  mov byte [scheduler_is_idle], 1
  sti
  hlt
  cli
  mov byte [scheduler_is_idle], 0
  call task_cleanup_zombies
  jmp .search
  .activate:
  mov edi, ebx
  call scheduler_activate
  pop r12
  pop rbx
endf

;// Первый запуск ищет init как обычную RUNNABLE-задачу.
leaf_function scheduler_start
  xor edi, edi
  .find:
    push rdi
    call task_by_index
    pop rdi
    test rax, rax
    jz .next
    cmp qword [rax+Task.state], TASK_RUNNABLE
    je .start
  .next:
    inc edi
    cmp edi, TASK_MAX
    jb .find
    jmp cpu_halt_forever
  .start:
  call scheduler_activate
  mov rsp, rax
  pop_all_registers
  iretq
end_leaf

;// Создать единственный процесс, ELF которого знает kernel: user/procd.
;// Procd получает механизмы создания объектов и read-only mapping bootfs;
;// загрузка всех остальных ELF уже является политикой user space.
function task_create_init
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  lea rdi, [init_program_name]
  mov esi, init_program_name.size
  call initramfs_find
  test rax, rax
  jz .failed
  mov rdi, rax
  mov rsi, rdx
  xor edx, edx
  call task_spawn_image
  test rax, rax
  jz .failed
  mov r12d, edx                    ;// init slot
  mov rbx, rax                     ;// init token
  mov edi, r12d
  call task_by_index
  mov r15, rax

  ;// Архив загружен ниже PMM.memStart и поэтому остаётся immutable bootstrap
  ;// storage. В user space он отображается read-only и NX.
  xor r14d, r14d
  .map_bootfs:
    mov rdi, [r15+Task.cr3]
    mov rsi, USER.bootfsBase
    add rsi, r14
    mov rdx, INITRAMFS.physBase
    add rdx, r14
    mov rcx, PAGE.US+PAGE.NX
    call vmm_map_in_space
    test rax, rax
    jz .failed
    add r14, PAGE_SIZE
    cmp r14, INITRAMFS.size
    jb .map_bootfs

  mov edi, r12d
  mov esi, CAP_SYSTEM
  mov edx, 1
  mov ecx, CAP_CREATE
  call capability_insert
  cmp eax, 1
  jne .failed

  call endpoint_create
  test rax, rax
  jz .failed
  mov r13, rax
  mov rdi, r15
  mov esi, CAP_ENDPOINT
  mov rdx, r13
  mov ecx, CAP_SEND+CAP_RECV
  call capability_insert_task
  cmp eax, 2
  jne .release_endpoint_failed
  mov edi, CAP_ENDPOINT
  mov rsi, r13
  call object_release

  mov rdi, r15
  mov esi, CAP_BOOTFS
  mov edx, 1
  mov ecx, CAP_READ
  call capability_insert_task
  cmp eax, 3
  jne .failed
  mov edi, r12d
  mov esi, 1
  call capability_grant_irq
  cmp eax, 4
  jne .failed
  mov edi, r12d
  mov esi, 0x60
  mov edx, 5
  mov ecx, CAP_READ
  call capability_grant_io
  cmp eax, 5
  jne .failed
  ;// VGA text buffer — единственный MMIO range первой console policy. Driver
  ;// получает не физический адрес, а ослабляемую capability на одну страницу.
  mov rdi, r15
  mov esi, CAP_MMIO
  mov edx, 0x000B8000
  mov ecx, CAP_MAP+CAP_READ+CAP_WRITE
  call capability_insert_task
  cmp eax, 6
  jne .failed
  mov eax, 1
  jmp .done
  .release_endpoint_failed:
  mov edi, CAP_ENDPOINT
  mov rsi, r13
  call object_release
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
