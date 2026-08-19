;//////////////////////////////////////////////////////////////////////////////
;// Минимальная граница user-space драйверов
;//////////////////////////////////////////////////////////////////////////////
;
;// Микроядро не даёт ring 3 глобальный IOPL. Загрузчик драйвера выдаёт
;// ему две независимые capabilities: IRQ и диапазон I/O-портов. Системный вызов
;// снова проверяет тип, права и границы. Компрометация драйвера не открывает
;// ему остальное железо.

DEVICE_IRQ_COUNT = 16
irq_owner  rb DEVICE_IRQ_COUNT       ;// task index+1
irq_pending rb DEVICE_IRQ_COUNT      ;// один накопленный event

;// RDI=owner, RSI=base port, RDX=length, RCX=CAP_READ/CAP_WRITE. RAX=handle.
function capability_grant_io
  mov rax, rdx
  shl rax, 32
  movzx edx, si
  or rdx, rax                       ;// object = length:32 | base:16
  mov esi, CAP_IO_PORT
  call capability_insert
endf

;// RDI=owner, RSI=IRQ. RAX=handle. Один IRQ маршрутизируется одному драйверу.
function capability_grant_irq
  push rbx
  push r12
  mov r12, rdi
  mov rbx, rsi
  cmp rbx, DEVICE_IRQ_COUNT
  jae .failed
  lea rax, [irq_owner]
  cmp byte [rax+rbx], 0
  jne .failed
  mov edx, ebx
  inc edx                            ;// object=IRQ+1, чтобы ноль остался invalid
  mov esi, CAP_IRQ
  mov ecx, CAP_WAIT
  call capability_insert
  test rax, rax
  jz .failed
  lea edx, [r12+1]
  lea rcx, [irq_owner]
  mov [rcx+rbx], dl
  jmp .done
  .failed:
  xor eax, eax
  .done:
  pop r12
  pop rbx
endf

;// RDI=handle, RSI=offset. RAX=byte или IPC_BAD_HANDLE.
function device_io_read8
  push rbx
  sub rsp, 8
  mov rbx, rsi
  mov esi, CAP_IO_PORT
  mov edx, CAP_READ
  call capability_lookup
  test rax, rax
  jz .denied
  mov r8, rax
  mov rdx, rax
  shr rdx, 32                       ;// length
  cmp rbx, rdx
  jae .denied
  movzx edx, r8w                    ;// base port
  add rdx, rbx
  xor eax, eax
  in al, dx
  jmp .done
  .denied:
  mov rax, IPC_BAD_HANDLE
  .done:
  add rsp, 8
  pop rbx
endf

;// RDI=handle, RSI=offset, RDX=value. RAX=0 или IPC_BAD_HANDLE.
function device_io_write8
  push rbx
  push r12
  mov rbx, rsi
  mov r12b, dl
  mov esi, CAP_IO_PORT
  mov edx, CAP_WRITE
  call capability_lookup
  test rax, rax
  jz .denied
  mov r8, rax
  mov rdx, rax
  shr rdx, 32
  cmp rbx, rdx
  jae .denied
  movzx edx, r8w
  add rdx, rbx
  mov al, r12b
  out dx, al
  xor eax, eax
  jmp .done
  .denied:
  mov rax, IPC_BAD_HANDLE
  .done:
  pop r12
  pop rbx
endf

;// RDI=IRQ. Вызывается interrupt stub-ом и никогда не разыменовывает user-адрес.
function device_irq_notify
  push rbx
  sub rsp, 8
  mov rbx, rdi
  cmp rbx, DEVICE_IRQ_COUNT
  jae .done
  lea rax, [irq_owner]
  movzx edi, byte [rax+rbx]
  test edi, edi
  jz .done
  dec edi
  call task_by_index
  cmp qword [rax+Task.state], TASK_BLOCKED_IRQ
  jne .remember
  cmp [rax+Task.wait_irq], rbx
  jne .remember
  mov rdx, [rax+Task.saved_rsp]
  mov [rdx+Context.rax], rbx
  mov qword [rax+Task.state], TASK_RUNNABLE
  mov qword [rax+Task.wait_irq], -1
  jmp .done
  .remember:
  lea rax, [irq_pending]
  mov byte [rax+rbx], 1
  .done:
  add rsp, 8
  pop rbx
endf

;// RDI=handle. RAX=IRQ и RCX=1, либо RCX=0 и задача уже переведена в BLOCKED.
function device_irq_wait
  mov esi, CAP_IRQ
  mov edx, CAP_WAIT
  call capability_lookup
  test rax, rax
  jz .denied
  dec rax                            ;// object хранит IRQ+1
  lea rdx, [irq_pending]
  cmp byte [rdx+rax], 0
  je .block
  mov byte [rdx+rax], 0
  mov ecx, 1
  jmp .done
  .block:
  push rax
  sub rsp, 8
  mov edi, [current_task]
  call task_by_index
  add rsp, 8
  pop rdx
  mov [rax+Task.wait_irq], rdx
  mov qword [rax+Task.state], TASK_BLOCKED_IRQ
  push rdx
  sub rsp, 8
  mov rdi, rdx
  call pic_unmask_irq                ;// открыть ровно одно следующее событие
  add rsp, 8
  pop rdx
  xor ecx, ecx
  mov rax, rdx
  jmp .done
  .denied:
  mov rax, IPC_BAD_HANDLE
  mov ecx, 1
  .done:
endf
