;//////////////////////////////////////////////////////////////////////////////
;// Объекты микроядра с подсчётом ссылок
;//////////////////////////////////////////////////////////////////////////////
;
;// Capability указывает либо на generation-safe process token, либо на
;// настоящий объект kernel heap. Для heap-объектов каждая capability является
;// сильной ссылкой. Это позволяет безопасно передавать endpoint/frame/space
;// через IPC и уничтожать объект после закрытия последнего handle.

CAP_PROCESS  = 1
CAP_IO_PORT  = 2
CAP_IRQ      = 3
CAP_SYSTEM   = 4
CAP_ENDPOINT = 5
CAP_FRAME    = 6
CAP_SPACE    = 7
CAP_BOOTFS   = 8

CAP_SEND     = 1
CAP_READ     = 2
CAP_WRITE    = 4
CAP_WAIT     = 8
CAP_CONTROL  = 32
CAP_MAP      = 64
CAP_CREATE   = 128
CAP_RECV     = 256
CAP_MOVE     = 1 shl 63            ;// флаг передачи, не постоянное право

Object.type = 0
Object.refs = 8

Frame.physical = 16
Frame.bytes    = 32

AddressSpace.cr3   = 16
AddressSpace.bytes = 32

ENDPOINT_QUEUE_SIZE = 8
IPC_WORD_COUNT      = 4
IPC_CAP_COUNT       = 2

Endpoint.waiter       = 16         ;// task token или 0
Endpoint.head         = 24
Endpoint.tail         = 32
Endpoint.count        = 40
Endpoint.sender       = 48         ;// 8 qword
Endpoint.words        = 112        ;// 8 сообщений * 4 qword
Endpoint.cap_count    = 368        ;// 8 qword
Endpoint.cap_target   = 432        ;// 8 * 2 qword
Endpoint.cap_rights   = 560        ;// 8 * 2 qword
Endpoint.cap_type     = 688        ;// 8 * 2 qword
Endpoint.bytes        = 816

;// Тип использует heap object и участвует в refcount.
leaf_function object_is_reference_counted
  cmp edi, CAP_ENDPOINT
  je .yes
  cmp edi, CAP_FRAME
  je .yes
  cmp edi, CAP_SPACE
  je .yes
  xor eax, eax
  ret
  .yes:
  mov eax, 1
end_leaf

;// RDI=type, RSI=target.
leaf_function object_retain
  cmp edi, CAP_ENDPOINT
  je .retain
  cmp edi, CAP_FRAME
  je .retain
  cmp edi, CAP_SPACE
  jne .done
  .retain:
  inc qword [rsi+Object.refs]
  .done:
end_leaf

;// Создать пустой endpoint. RAX=object с одной временной ссылкой или 0.
function endpoint_create
  mov edi, Endpoint.bytes
  call kmalloc
  test rax, rax
  jz .done
  push rax
  mov rdi, rax
  xor eax, eax
  mov ecx, Endpoint.bytes/8
  rep stosq
  pop rax
  mov qword [rax+Object.type], CAP_ENDPOINT
  mov qword [rax+Object.refs], 1
  .done:
endf

;// Создать обнулённый физический frame object.
function frame_create
  push rbx
  sub rsp, 8
  call pmm_alloc_frame
  test rax, rax
  jz .failed
  mov rbx, rax
  hhdm_address rdi, rbx
  xor esi, esi
  mov edx, PAGE_SIZE
  call memory_set
  mov edi, Frame.bytes
  call kmalloc
  test rax, rax
  jz .free_frame
  mov qword [rax+Object.type], CAP_FRAME
  mov qword [rax+Object.refs], 1
  mov [rax+Frame.physical], rbx
  jmp .done
  .free_frame:
  mov rdi, rbx
  call pmm_free_frame
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop rbx
endf

;// Создать пустое address space. RAX=object с одной временной ссылкой или 0.
function address_space_create
  push rbx
  sub rsp, 8
  mov edi, AddressSpace.bytes
  call kmalloc
  test rax, rax
  jz .failed
  mov rbx, rax
  call vmm_create_space
  test rax, rax
  jz .free_object
  mov qword [rbx+Object.type], CAP_SPACE
  mov qword [rbx+Object.refs], 1
  mov [rbx+AddressSpace.cr3], rax
  mov rax, rbx
  jmp .done
  .free_object:
  mov rdi, rbx
  call kfree
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop rbx
endf

;// Освободить последнюю сильную ссылку. RDI=type, RSI=target.
;// Для endpoint дополнительно освобождаются capabilities в недоставленных
;// сообщениях. capability_release объявлена позже в task.inc.
function object_release
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov rbx, rsi
  cmp r12d, CAP_ENDPOINT
  je .decrement
  cmp r12d, CAP_FRAME
  je .decrement
  cmp r12d, CAP_SPACE
  jne .done
  .decrement:
  dec qword [rbx+Object.refs]
  jnz .done
  cmp r12d, CAP_FRAME
  je .destroy_frame
  cmp r12d, CAP_SPACE
  je .destroy_space

  ;// Endpoint: очередь сама удерживает переданные объекты.
  mov r13, [rbx+Endpoint.head]
  mov r14, [rbx+Endpoint.count]
  .message:
    test r14, r14
    jz .free_object
    mov rcx, [rbx+Endpoint.cap_count+r13*8]
    xor edx, edx
  .message_cap:
      cmp rdx, rcx
      jae .next_message
      mov rax, r13
      shl rax, 1
      add rax, rdx
      mov rdi, [rbx+Endpoint.cap_type+rax*8]
      mov rsi, [rbx+Endpoint.cap_target+rax*8]
      push rcx
      push rdx
      call capability_release
      pop rdx
      pop rcx
      inc rdx
      jmp .message_cap
  .next_message:
    inc r13
    and r13d, ENDPOINT_QUEUE_SIZE-1
    dec r14
    jmp .message

  .destroy_frame:
  mov rdi, [rbx+Frame.physical]
  call pmm_free_frame
  jmp .free_object
  .destroy_space:
  mov rdi, [rbx+AddressSpace.cr3]
  call vmm_destroy_space
  .free_object:
  mov rdi, rbx
  call kfree
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf
