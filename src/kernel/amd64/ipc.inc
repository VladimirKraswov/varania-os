;//////////////////////////////////////////////////////////////////////////////
;// Endpoint IPC: сообщения из восьми слов и до двух capabilities
;//////////////////////////////////////////////////////////////////////////////
;
;// User ABI структуры IpcMessage (112 байт):
;//   words[8]                       0..63
;//   capability_count                 64
;//   caps[2] = {handle, rights}     72..103
;//   sender_token                     104 (только output)
;//
;// Передаваемые kernel objects удерживаются очередью сильной ссылкой. Бит
;// CAP_MOVE в requested rights просит атомарно закрыть исходный handle после
;// успешной постановки сообщения в очередь.

IPC_OK          = 0
IPC_BAD_HANDLE  = -9
IPC_WOULD_BLOCK = -11

IpcCap.handle          = 0
IpcCap.rights          = 8
IpcCap.bytes           = 16
IpcMessage.words       = 0
IpcMessage.cap_count   = IPC_WORD_COUNT*8
IpcMessage.caps        = IpcMessage.cap_count+8
IpcMessage.sender      = IpcMessage.caps+IPC_CAP_COUNT*IpcCap.bytes
IpcMessage.bytes       = IpcMessage.sender+8

;// Доставить head-сообщение указанной задаче.
;// RDI=Endpoint, RSI=receiver TCB, RDX=user IpcMessage*. RAX=IPC_*.
function ipc_endpoint_deliver
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, IpcMessage.bytes+8
  mov rbx, rdi
  mov r12, rsi
  mov r15, rdx
  mov r13, [rbx+Endpoint.head]
  mov r14, [rbx+Endpoint.cap_count+r13*8]

  ;// Revoke queued capability отменяет сообщение целиком. Это сохраняет
  ;// атомарность: receiver не увидит payload без части ожидаемых handles.
  xor eax, eax
  .scan_revoked:
    cmp rax, r14
    jae .check_slots
    mov rcx, r13
    shl rcx, 1
    add rcx, rax
    mov rdx, [rbx+Endpoint.cap_node+rcx*8]
    cmp qword [rdx+CapNode.revoked], 0
    jne .drop_revoked
    inc rax
    jmp .scan_revoked

  ;// Сначала убеждаемся, что receiver способен принять все handles.
  .check_slots:
  mov rdi, r12
  call capability_free_count
  cmp rax, r14
  jb .would_block

  ;// Формируем понятную ABI-структуру в kernel stack.
  mov rdi, rsp
  xor eax, eax
  mov ecx, IpcMessage.bytes/8
  rep stosq
  mov [rsp+IpcMessage.cap_count], r14
  mov rax, [rbx+Endpoint.sender+r13*8]
  mov [rsp+IpcMessage.sender], rax
  mov rax, r13
  shl rax, 3
  xor ecx, ecx
  .word:
    mov rdx, [rbx+Endpoint.words+rax*8]
    mov [rsp+IpcMessage.words+rcx*8], rdx
    inc rax
    inc ecx
    cmp ecx, IPC_WORD_COUNT
    jb .word

  ;// Предварительная запись валидирует весь output range до изменения caps.
  mov rdi, [r12+Task.cr3]
  mov rsi, r15
  mov rdx, rsp
  mov ecx, IpcMessage.bytes
  call vmm_copy_to_user_space
  test rax, rax
  jz .fault

  xor r15d, r15d                  ;// cap index
  .insert_cap:
    cmp r15, r14
    jae .copy_result
    mov rax, r13
    shl rax, 1
    add rax, r15
    mov rdi, r12
    mov rsi, [rbx+Endpoint.cap_type+rax*8]
    mov rdx, [rbx+Endpoint.cap_target+rax*8]
    mov rcx, [rbx+Endpoint.cap_rights+rax*8]
    mov r8, [rbx+Endpoint.cap_node+rax*8]
    call capability_insert_task_derived
    ;// Slots посчитаны заранее, но allocation lineage node ещё может отказать.
    test rax, rax
    jz .insert_failed
    mov rcx, r15
    shl rcx, 4
    mov [rsp+IpcMessage.caps+rcx+IpcCap.handle], rax
    mov rdx, r13
    shl rdx, 1
    add rdx, r15
    mov rax, [rbx+Endpoint.cap_rights+rdx*8]
    mov [rsp+IpcMessage.caps+rcx+IpcCap.rights], rax
    inc r15
    jmp .insert_cap

  .copy_result:
  mov rdi, [r12+Task.cr3]
  mov rsi, [r12+Task.wait_buffer]
  ;// При немедленном receive wait_buffer временно задаёт вызывающий код.
  mov rdx, rsp
  mov ecx, IpcMessage.bytes
  call vmm_copy_to_user_space
  test rax, rax
  jz .fault_after_caps

  ;// Receiver теперь удерживает свои ссылки — снимаем ссылки очереди.
  xor r15d, r15d
  .release_cap:
    cmp r15, r14
    jae .dequeue
    mov rax, r13
    shl rax, 1
    add rax, r15
    mov rdi, [rbx+Endpoint.cap_type+rax*8]
    mov rsi, [rbx+Endpoint.cap_target+rax*8]
    call capability_release
    mov rax, r13
    shl rax, 1
    add rax, r15
    mov rdi, [rbx+Endpoint.cap_node+rax*8]
    mov qword [rdi+CapNode.pinned], 0
    call cap_node_prune
    inc r15
    jmp .release_cap
  .dequeue:
  inc r13
  and r13d, ENDPOINT_QUEUE_SIZE-1
  mov [rbx+Endpoint.head], r13
  dec qword [rbx+Endpoint.count]
  xor eax, eax
  jmp .done

  .drop_revoked:
  xor r15d, r15d
  .drop_cap:
    cmp r15, r14
    jae .drop_message
    mov rax, r13
    shl rax, 1
    add rax, r15
    mov rdi, [rbx+Endpoint.cap_type+rax*8]
    mov rsi, [rbx+Endpoint.cap_target+rax*8]
    call capability_release
    mov rax, r13
    shl rax, 1
    add rax, r15
    mov rdi, [rbx+Endpoint.cap_node+rax*8]
    mov qword [rdi+CapNode.pinned], 0
    call cap_node_prune
    inc r15
    jmp .drop_cap
  .drop_message:
  inc r13
  and r13d, ENDPOINT_QUEUE_SIZE-1
  mov [rbx+Endpoint.head], r13
  dec qword [rbx+Endpoint.count]
  mov rax, IPC_BAD_HANDLE
  jmp .done

  ;// Этот путь практически недостижим после предварительной validation, но
  ;// rollback сохраняет инвариант при будущей многопоточности address space.
  .fault_after_caps:
  mov qword [rsp+IpcMessage.bytes], -14
  mov r15, r14
  jmp .rollback
  .insert_failed:
  mov qword [rsp+IpcMessage.bytes], -12
  .rollback:
    test r15, r15
    jz .rollback_done
    dec r15
    mov rcx, r15
    shl rcx, 4
    mov rsi, [rsp+IpcMessage.caps+rcx+IpcCap.handle]
    test rsi, rsi
    jz .rollback
    dec rsi
    mov rdi, r12
    call capability_clear_slot
    jmp .rollback
  .rollback_done:
  mov rax, [rsp+IpcMessage.bytes]
  jmp .done
  .fault:
  mov rax, -14
  jmp .done
  .would_block:
  mov rax, IPC_WOULD_BLOCK
  .done:
  add rsp, IpcMessage.bytes+8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Если на endpoint спит receiver, доставить ему head очереди и разбудить.
;// RDI=Endpoint.
function ipc_endpoint_try_wake
  push rbx
  push r12
  push r13
  push r14
  mov rbx, rdi
  cmp qword [rbx+Endpoint.count], 0
  je .done
  mov rdi, [rbx+Endpoint.waiter]
  test rdi, rdi
  jz .done
  call task_from_token
  test rax, rax
  jz .forget_waiter
  mov r12, rax
  cmp qword [r12+Task.state], TASK_BLOCKED_IPC
  jne .forget_waiter
  cmp [r12+Task.wait_endpoint], rbx
  jne .forget_waiter
  mov rdi, rbx
  mov rsi, r12
  mov rdx, [r12+Task.wait_buffer]
  call ipc_endpoint_deliver
  mov r13, rax
  cmp r13, IPC_WOULD_BLOCK
  je .done                        ;// receiver сначала должен закрыть handles
  mov r14, [r12+Task.saved_rsp]
  mov [r14+Context.rax], r13
  mov qword [r12+Task.wait_endpoint], 0
  mov qword [r12+Task.wait_buffer], 0
  mov qword [r12+Task.state], TASK_RUNNABLE
  mov qword [rbx+Endpoint.waiter], 0
  mov edi, CAP_ENDPOINT
  mov rsi, rbx
  call object_release             ;// ссылка, удерживаемая blocked task
  jmp .done
  .forget_waiter:
  mov qword [rbx+Endpoint.waiter], 0
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// RDI=endpoint handle, RSI=user IpcMessage*. RAX=IPC_*.
function ipc_endpoint_send
  push rbx
  push r12
  push r13
  push r14
  push r15
  ;// IpcMessage, затем шесть массивов по IPC_CAP_COUNT qword и padding.
  sub rsp, IpcMessage.bytes+6*IPC_CAP_COUNT*8+8
  mov r12, rdi
  mov r13, rsi
  mov esi, CAP_ENDPOINT
  mov edx, CAP_SEND
  call capability_lookup
  test rax, rax
  jz .bad_handle
  mov rbx, rax
  cmp qword [rbx+Endpoint.count], ENDPOINT_QUEUE_SIZE
  jae .would_block

  mov edi, [current_task]
  call task_by_index
  mov r14, rax                    ;// sender TCB
  mov rdi, rsp
  mov rsi, [r14+Task.cr3]
  mov rdx, r13
  mov ecx, IpcMessage.bytes
  call vmm_copy_from_user_space
  test rax, rax
  jz .fault
  mov r15, [rsp+IpcMessage.cap_count]
  cmp r15, IPC_CAP_COUNT
  ja .invalid

  ;// Сначала проверяем все capabilities, не меняя состояние процесса.
  xor r13d, r13d
  .validate_cap:
    cmp r13, r15
    jae .enqueue
    mov rax, r13
    shl rax, 4
    mov rdi, [rsp+IpcMessage.caps+rax+IpcCap.handle]
    mov r12, [rsp+IpcMessage.caps+rax+IpcCap.rights]
    mov qword [rsp+IpcMessage.bytes+3*IPC_CAP_COUNT*8+r13*8], -1 ;// source slot, если MOVE не задан
    bt r12, 63
    jnc .without_move
    btr r12, 63
    .without_move:
    test r12, r12
    jz .invalid
    call capability_lookup_any_current
    test rax, rax
    jz .bad_handle
    mov r9, rcx
    and r9, r12
    cmp r9, r12
    jne .bad_handle
    mov [rsp+IpcMessage.bytes+0*IPC_CAP_COUNT*8+r13*8], rax ;// target
    mov [rsp+IpcMessage.bytes+1*IPC_CAP_COUNT*8+r13*8], rdx ;// type
    mov [rsp+IpcMessage.bytes+2*IPC_CAP_COUNT*8+r13*8], r12 ;// weakened rights
    mov r10, r8
    mov edi, [current_task]
    call task_by_index
    mov rax, [rax+Task.cap_node+r10*8]
    test rax, rax
    jz .bad_handle
    mov [rsp+IpcMessage.bytes+4*IPC_CAP_COUNT*8+r13*8], rax ;// lineage source
    mov rax, r13
    shl rax, 4
    bt qword [rsp+IpcMessage.caps+rax+IpcCap.rights], 63
    jnc .next_cap
    mov [rsp+IpcMessage.bytes+3*IPC_CAP_COUNT*8+r13*8], r8
    .next_cap:
    inc r13
    jmp .validate_cap

  .enqueue:
  ;// Не ставим недоставимое сообщение перед уже спящим receiver: иначе cap с
  ;// большим числом handles навсегда заблокировал бы head очереди.
  mov rdi, [rbx+Endpoint.waiter]
  test rdi, rdi
  jz .enqueue_ready
  call task_from_token
  test rax, rax
  jz .enqueue_ready
  mov rdi, rax
  call capability_free_count
  cmp rax, r15
  jb .would_block
  .enqueue_ready:
  ;// Queue получает ghost child каждого source node. Он переживает MOVE/close
  ;// отправителя и становится родителем handle, созданного receiver-у.
  xor r13d, r13d
  .lineage_node:
    cmp r13, r15
    jae .lineage_ready
    mov rdi, [rsp+IpcMessage.bytes+4*IPC_CAP_COUNT*8+r13*8]
    xor esi, esi
    mov rdx, -1
    call cap_node_create
    test rax, rax
    jz .lineage_failed
    mov [rsp+IpcMessage.bytes+5*IPC_CAP_COUNT*8+r13*8], rax
    mov qword [rax+CapNode.pinned], 1
    inc r13
    jmp .lineage_node
  .lineage_failed:
    test r13, r13
    jz .no_memory
    dec r13
    mov rdi, [rsp+IpcMessage.bytes+5*IPC_CAP_COUNT*8+r13*8]
    mov qword [rdi+CapNode.pinned], 0
    call cap_node_prune
    jmp .lineage_failed
  .lineage_ready:
  mov r12, [rbx+Endpoint.tail]
  mov edi, [current_task]
  call task_by_index
  mov rax, [rax+Task.token]
  mov [rbx+Endpoint.sender+r12*8], rax
  mov rax, r12
  shl rax, 3
  xor ecx, ecx
  .copy_word:
    mov rdx, [rsp+IpcMessage.words+rcx*8]
    mov [rbx+Endpoint.words+rax*8], rdx
    inc rax
    inc ecx
    cmp ecx, IPC_WORD_COUNT
    jb .copy_word
  mov [rbx+Endpoint.cap_count+r12*8], r15

  xor r13d, r13d
  .queue_cap:
    cmp r13, r15
    jae .commit
    mov rax, r12
    shl rax, 1
    add rax, r13
    mov rdx, [rsp+IpcMessage.bytes+0*IPC_CAP_COUNT*8+r13*8]
    mov rcx, [rsp+IpcMessage.bytes+1*IPC_CAP_COUNT*8+r13*8]
    mov [rbx+Endpoint.cap_target+rax*8], rdx
    mov [rbx+Endpoint.cap_type+rax*8], rcx
    mov rdx, [rsp+IpcMessage.bytes+2*IPC_CAP_COUNT*8+r13*8]
    mov [rbx+Endpoint.cap_rights+rax*8], rdx
    mov rdx, [rsp+IpcMessage.bytes+5*IPC_CAP_COUNT*8+r13*8]
    mov [rbx+Endpoint.cap_node+rax*8], rdx
    mov rdi, rcx
    mov rsi, [rsp+IpcMessage.bytes+0*IPC_CAP_COUNT*8+r13*8]
    call object_retain            ;// queue ownership
    inc r13
    jmp .queue_cap

  .commit:
  mov rax, r12
  inc rax
  and eax, ENDPOINT_QUEUE_SIZE-1
  mov [rbx+Endpoint.tail], rax
  inc qword [rbx+Endpoint.count]

  ;// MOVE применяется только после успешного enqueue.
  xor r13d, r13d
  .move_cap:
    cmp r13, r15
    jae .wake
    mov rsi, [rsp+IpcMessage.bytes+3*IPC_CAP_COUNT*8+r13*8]
    cmp rsi, -1
    je .next_move
    mov edi, [current_task]
    call task_by_index
    mov rdi, rax
    call capability_clear_slot
    .next_move:
    inc r13
    jmp .move_cap
  .wake:
  mov rdi, rbx
  call ipc_endpoint_try_wake
  xor eax, eax
  jmp .done

  .bad_handle:
  mov rax, IPC_BAD_HANDLE
  jmp .done
  .would_block:
  mov rax, IPC_WOULD_BLOCK
  jmp .done
  .fault:
  mov rax, -14
  jmp .done
  .no_memory:
  mov rax, -12
  jmp .done
  .invalid:
  mov rax, -22
  .done:
  add rsp, IpcMessage.bytes+6*IPC_CAP_COUNT*8+8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// RDI=endpoint handle, RSI=user IpcMessage*.
;// RAX=IPC_*; RCX=1 если ответ готов, RCX=0 если задача заблокирована.
function ipc_endpoint_receive
  push rbx
  push r12
  push r13
  push r14
  mov r12, rsi
  mov esi, CAP_ENDPOINT
  mov edx, CAP_RECV
  call capability_lookup
  test rax, rax
  jz .bad_handle
  mov rbx, rax
  mov edi, [current_task]
  call task_by_index
  mov r13, rax
  cmp qword [rbx+Endpoint.count], 0
  je .block
  mov [r13+Task.wait_buffer], r12
  mov rdi, rbx
  mov rsi, r13
  mov rdx, r12
  call ipc_endpoint_deliver
  mov qword [r13+Task.wait_buffer], 0
  mov ecx, 1
  jmp .done

  .block:
  cmp qword [rbx+Endpoint.waiter], 0
  jne .busy
  ;// Валидируем output buffer до сна; нули не являются сообщением, поскольку
  ;// syscall ещё не вернулся пользователю.
  sub rsp, IpcMessage.bytes
  mov rdi, rsp
  xor eax, eax
  mov ecx, IpcMessage.bytes/8
  rep stosq
  mov rdi, [r13+Task.cr3]
  mov rsi, r12
  mov rdx, rsp
  mov ecx, IpcMessage.bytes
  call vmm_copy_to_user_space
  add rsp, IpcMessage.bytes
  test rax, rax
  jz .fault
  mov rax, [r13+Task.token]
  mov [rbx+Endpoint.waiter], rax
  mov [r13+Task.wait_endpoint], rbx
  mov [r13+Task.wait_buffer], r12
  mov qword [r13+Task.state], TASK_BLOCKED_IPC
  mov edi, CAP_ENDPOINT
  mov rsi, rbx
  call object_retain              ;// endpoint жив, даже если handle закрыли
  xor eax, eax
  xor ecx, ecx
  jmp .done
  .bad_handle:
  mov rax, IPC_BAD_HANDLE
  mov ecx, 1
  jmp .done
  .busy:
  mov rax, -16
  mov ecx, 1
  jmp .done
  .fault:
  mov rax, -14
  mov ecx, 1
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf
