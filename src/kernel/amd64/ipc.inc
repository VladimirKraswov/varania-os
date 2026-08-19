;//////////////////////////////////////////////////////////////////////////////
;// Endpoint IPC: сообщения из четырёх слов и до двух capabilities
;//////////////////////////////////////////////////////////////////////////////
;
;// User ABI структуры IpcMessage (80 байт):
;//   words[4]                      0..31
;//   capability_count                32
;//   caps[2] = {handle, rights}    40..71
;//   sender_token                    72 (только output)
;//
;// Передаваемые kernel objects удерживаются очередью сильной ссылкой. Бит
;// CAP_MOVE в requested rights просит атомарно закрыть исходный handle после
;// успешной постановки сообщения в очередь.

IPC_OK          = 0
IPC_BAD_HANDLE  = -9
IPC_WOULD_BLOCK = -11

IpcMessage.words       = 0
IpcMessage.cap_count   = 32
IpcMessage.caps        = 40
IpcMessage.sender      = 72
IpcMessage.bytes       = 80
IpcCap.handle          = 0
IpcCap.rights          = 8
IpcCap.bytes           = 16

;// Доставить head-сообщение указанной задаче.
;// RDI=Endpoint, RSI=receiver TCB, RDX=user IpcMessage*. RAX=IPC_*.
function ipc_endpoint_deliver
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 88
  mov rbx, rdi
  mov r12, rsi
  mov r15, rdx
  mov r13, [rbx+Endpoint.head]
  mov r14, [rbx+Endpoint.cap_count+r13*8]

  ;// Сначала убеждаемся, что receiver способен принять все handles.
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
  shl rax, 2
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
    call capability_insert_task
    ;// Свободные slots посчитаны заранее, поэтому ошибка означает corruption.
    test rax, rax
    jz .would_block
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
    inc r15
    jmp .release_cap
  .dequeue:
  inc r13
  and r13d, ENDPOINT_QUEUE_SIZE-1
  mov [rbx+Endpoint.head], r13
  dec qword [rbx+Endpoint.count]
  xor eax, eax
  jmp .done

  ;// Этот путь практически недостижим после предварительной validation, но
  ;// rollback сохраняет инвариант при будущей многопоточности address space.
  .fault_after_caps:
  mov r15, r14
  .rollback:
    test r15, r15
    jz .fault
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
  .fault:
  mov rax, -14
  jmp .done
  .would_block:
  mov rax, IPC_WOULD_BLOCK
  .done:
  add rsp, 88
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
  sub rsp, 152
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
    mov qword [rsp+128+r13*8], -1 ;// source slot, если MOVE не задан
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
    mov [rsp+80+r13*8], rax       ;// target
    mov [rsp+96+r13*8], rdx       ;// type
    mov [rsp+112+r13*8], r12      ;// weakened rights
    mov rax, r13
    shl rax, 4
    bt qword [rsp+IpcMessage.caps+rax+IpcCap.rights], 63
    jnc .next_cap
    mov [rsp+128+r13*8], r8
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
  mov r12, [rbx+Endpoint.tail]
  mov edi, [current_task]
  call task_by_index
  mov rax, [rax+Task.token]
  mov [rbx+Endpoint.sender+r12*8], rax
  mov rax, r12
  shl rax, 2
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
    mov rdx, [rsp+80+r13*8]
    mov rcx, [rsp+96+r13*8]
    mov [rbx+Endpoint.cap_target+rax*8], rdx
    mov [rbx+Endpoint.cap_type+rax*8], rcx
    mov rdx, [rsp+112+r13*8]
    mov [rbx+Endpoint.cap_rights+rax*8], rdx
    mov rdi, rcx
    mov rsi, [rsp+80+r13*8]
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
    mov rsi, [rsp+128+r13*8]
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
  .invalid:
  mov rax, -22
  .done:
  add rsp, 152
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
