;//////////////////////////////////////////////////////////////////////////////
;// Capability-based IPC
;//////////////////////////////////////////////////////////////////////////////
;
;// Процесс не может отправить сообщение по простому PID. Он передаёт
;// локальный handle, а ядро проверяет, какому endpoint он соответствует и
;// есть ли право CAP_SEND. Такая модель масштабируется до IRQ/MMIO-capabilities.

IPC_OK          = 0
IPC_BAD_HANDLE  = -9
IPC_WOULD_BLOCK = -11

;// RDI=handle, RSI=value. RAX=IPC_*.
function ipc_send
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rsi
  mov r13, rdi
  test r13, r13
  jz .bad_handle
  cmp r13, CAP_SLOTS
  ja .bad_handle

  mov edi, [current_task]
  call task_by_index
  dec r13
  cmp qword [rax+Task.cap_type+r13*8], CAP_ENDPOINT
  jne .bad_handle
  test qword [rax+Task.cap_rights+r13*8], CAP_SEND
  jz .bad_handle
  mov rbx, [rax+Task.cap_target+r13*8]
  test rbx, rbx
  jz .bad_handle
  dec rbx                           ;// в capability хранится index+1
  mov rdi, rbx
  call task_by_index

  cmp qword [rax+Task.state], TASK_BLOCKED_IPC
  jne .queue
  ;// Прямая доставка: записываем результат в сохранённый context получателя.
  mov rdx, [rax+Task.saved_rsp]
  mov [rdx+Context.rax], r12
  mov ecx, [current_task]
  inc ecx
  mov [rdx+Context.rdx], rcx        ;// sender token (index+1)
  mov qword [rax+Task.state], TASK_RUNNABLE
  xor eax, eax
  jmp .done

  .queue:
  cmp qword [rax+Task.message], 0
  jne .would_block
  mov qword [rax+Task.message], 1
  mov ecx, [current_task]
  inc ecx
  mov [rax+Task.sender], rcx
  mov [rax+Task.value], r12
  xor eax, eax
  jmp .done
  .bad_handle:
  mov rax, IPC_BAD_HANDLE
  jmp .done
  .would_block:
  mov rax, IPC_WOULD_BLOCK
  .done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf
