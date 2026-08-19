;//////////////////////////////////////////////////////////////////////////////
;// Capability-based IPC с ограниченными кольцевыми очередями
;//////////////////////////////////////////////////////////////////////////////
;
;// Каждая задача владеет очередью из восьми пар (sender token, value). Если
;// получатель уже спит в SYS_RECV, используется прямая доставка без очереди.
;// Ограничение размера даёт явный backpressure и не позволяет исчерпать heap.

IPC_OK          = 0
IPC_BAD_HANDLE  = -9
IPC_WOULD_BLOCK = -11

;// RDI=process capability, RSI=value. RAX=IPC_*.
function ipc_send
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rsi
  mov esi, CAP_PROCESS
  mov edx, CAP_SEND
  call capability_lookup
  test rax, rax
  jz .bad_handle
  mov rdi, rax
  call task_from_token
  test rax, rax
  jz .bad_handle
  mov rbx, rax
  mov rax, [rbx+Task.state]
  cmp rax, TASK_ZOMBIE
  jae .bad_handle

  mov edi, [current_task]
  call task_by_index
  mov r13, [rax+Task.token]

  cmp qword [rbx+Task.state], TASK_BLOCKED_IPC
  jne .enqueue
  mov rdx, [rbx+Task.saved_rsp]
  mov [rdx+Context.rax], r12
  mov [rdx+Context.rdx], r13
  mov qword [rbx+Task.state], TASK_RUNNABLE
  xor eax, eax
  jmp .done

  .enqueue:
  cmp qword [rbx+Task.queue_count], IPC_QUEUE_SIZE
  jae .would_block
  mov rcx, [rbx+Task.queue_tail]
  mov [rbx+Task.queue_sender+rcx*8], r13
  mov [rbx+Task.queue_value+rcx*8], r12
  inc rcx
  and ecx, IPC_QUEUE_SIZE-1
  mov [rbx+Task.queue_tail], rcx
  inc qword [rbx+Task.queue_count]
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

;// Получить следующее сообщение текущей задачи.
;// RAX=value, RDX=sender, RCX=1; либо RCX=0 и задача переведена в BLOCKED_IPC.
function ipc_receive
  push rbx
  mov edi, [current_task]
  call task_by_index
  mov rbx, rax
  cmp qword [rbx+Task.queue_count], 0
  je .block
  mov rcx, [rbx+Task.queue_head]
  mov rax, [rbx+Task.queue_value+rcx*8]
  mov rdx, [rbx+Task.queue_sender+rcx*8]
  inc rcx
  and ecx, IPC_QUEUE_SIZE-1
  mov [rbx+Task.queue_head], rcx
  dec qword [rbx+Task.queue_count]
  mov ecx, 1
  jmp .done
  .block:
  mov qword [rbx+Task.state], TASK_BLOCKED_IPC
  xor eax, eax
  xor edx, edx
  xor ecx, ecx
  .done:
  pop rbx
endf
