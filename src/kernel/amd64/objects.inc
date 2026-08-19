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
CAP_SHARED   = 9
CAP_MMIO     = 10
CAP_DMA_POOL = 11

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
AddressSpace.shared_head = 24
AddressSpace.bytes = 32

;// 64 pages = 256 KiB: достаточно для файлового окна и ELF bootstrap,
;// но всё ещё мало, чтобы случайно скрыть отсутствие streaming-протокола.
SHARED_MAX_PAGES = 64
SharedMemory.page_count = 16
SharedMemory.frames     = 24       ;// SHARED_MAX_PAGES qword
SharedMemory.bytes      = 152

SharedMapping.next = 0
SharedMapping.shm  = 8
SharedMapping.bytes = 16

ENDPOINT_QUEUE_SIZE = 8
;// Восемь qword дают 56 байт payload после кода операции.
;// Сами блоки файлов ходят через shared memory, а не копируются в IPC.
IPC_WORD_COUNT      = 8
IPC_CAP_COUNT       = 2

Endpoint.waiter       = 16         ;// task token или 0
Endpoint.head         = 24
Endpoint.tail         = 32
Endpoint.count        = 40
Endpoint.sender       = 48
Endpoint.words        = Endpoint.sender+ENDPOINT_QUEUE_SIZE*8
Endpoint.cap_count    = Endpoint.words+ENDPOINT_QUEUE_SIZE*IPC_WORD_COUNT*8
Endpoint.cap_target   = Endpoint.cap_count+ENDPOINT_QUEUE_SIZE*8
Endpoint.cap_rights   = Endpoint.cap_target+ENDPOINT_QUEUE_SIZE*IPC_CAP_COUNT*8
Endpoint.cap_type     = Endpoint.cap_rights+ENDPOINT_QUEUE_SIZE*IPC_CAP_COUNT*8
Endpoint.cap_node     = Endpoint.cap_type+ENDPOINT_QUEUE_SIZE*IPC_CAP_COUNT*8
Endpoint.bytes        = Endpoint.cap_node+ENDPOINT_QUEUE_SIZE*IPC_CAP_COUNT*8

;// Тип использует heap object и участвует в refcount.
leaf_function object_is_reference_counted
  cmp edi, CAP_ENDPOINT
  je .yes
  cmp edi, CAP_FRAME
  je .yes
  cmp edi, CAP_SPACE
  je .yes
  cmp edi, CAP_SHARED
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
  je .retain
  cmp edi, CAP_SHARED
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
  mov qword [rbx+AddressSpace.shared_head], 0
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

;// Создать shared-memory object из 1..16 обнулённых frames. RDI=page count.
function shared_memory_create
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  test r12, r12
  jz .failed
  cmp r12, SHARED_MAX_PAGES
  ja .failed
  mov edi, SharedMemory.bytes
  call kmalloc
  test rax, rax
  jz .failed
  mov rbx, rax
  mov rdi, rax
  xor eax, eax
  mov ecx, SharedMemory.bytes/8
  rep stosq
  mov qword [rbx+Object.type], CAP_SHARED
  mov qword [rbx+Object.refs], 1
  mov [rbx+SharedMemory.page_count], r12
  xor r13d, r13d
  .frame:
    cmp r13, r12
    jae .success
    call pmm_alloc_frame
    test rax, rax
    jz .rollback
    mov [rbx+SharedMemory.frames+r13*8], rax
    mov r14, rax
    hhdm_address rdi, rax
    xor esi, esi
    mov edx, PAGE_SIZE
    call memory_set
    inc r13
    jmp .frame
  .rollback:
    test r13, r13
    jz .free_object
    dec r13
    mov rdi, [rbx+SharedMemory.frames+r13*8]
    call pmm_free_frame
    jmp .rollback
  .free_object:
  mov rdi, rbx
  call kfree
  .failed:
  xor eax, eax
  jmp .done
  .success:
  mov rax, rbx
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf

;// Создать SharedMemory из физически соседних кадров. Объект и mapping lifetime
;// остаются теми же, что у обычной shared memory; отличается только allocator.
;// RDI=pages. RAX=SharedMemory или 0, RDX=физический base при успехе.
function shared_memory_create_contiguous
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  test r12, r12
  jz .failed
  cmp r12, SHARED_MAX_PAGES
  ja .failed
  mov rdi, SharedMemory.bytes
  call kmalloc
  test rax, rax
  jz .failed
  mov rbx, rax
  mov rdi, rax
  xor eax, eax
  mov ecx, SharedMemory.bytes/8
  rep stosq
  mov rdi, r12
  call pmm_alloc_contiguous
  test rax, rax
  jz .free_object
  mov r14, rax
  mov qword [rbx+Object.type], CAP_SHARED
  mov qword [rbx+Object.refs], 1
  mov [rbx+SharedMemory.page_count], r12
  xor r13d, r13d
  .frame:
    cmp r13, r12
    jae .zero
    mov rax, r13
    shl rax, 12
    add rax, r14
    mov [rbx+SharedMemory.frames+r13*8], rax
    inc r13
    jmp .frame
  .zero:
    hhdm_address rdi, r14
    xor esi, esi
    mov rdx, r12
    shl rdx, 12
    call memory_set
    mov rax, rbx
    mov rdx, r14
    jmp .done
  .free_object:
    mov rdi, rbx
    call kfree
  .failed:
    xor eax, eax
    xor edx, edx
  .done:
  pop r14
  pop r13
  pop r12
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
  je .decrement
  cmp r12d, CAP_SHARED
  jne .done
  .decrement:
  dec qword [rbx+Object.refs]
  jnz .done
  cmp r12d, CAP_FRAME
  je .destroy_frame
  cmp r12d, CAP_SPACE
  je .destroy_space
  cmp r12d, CAP_SHARED
  je .destroy_shared

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
      mov rax, r13
      shl rax, 1
      add rax, rdx
      push rcx
      push rdx
      mov rdi, [rbx+Endpoint.cap_node+rax*8]
      mov qword [rdi+CapNode.pinned], 0
      call cap_node_prune
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
  ;// Сначала удаляем borrowed PTE и лишь затем отпускаем SharedMemory. Такой
  ;// порядок гарантирует, что физические кадры живут дольше всех отображений.
  mov r13, [rbx+AddressSpace.shared_head]
  mov rdi, [rbx+AddressSpace.cr3]
  call vmm_destroy_space
  .shared_mapping:
    test r13, r13
    jz .free_object
    mov r14, [r13+SharedMapping.next]
    mov edi, CAP_SHARED
    mov rsi, [r13+SharedMapping.shm]
    call object_release
    mov rdi, r13
    call kfree
    mov r13, r14
    jmp .shared_mapping
  .destroy_shared:
  xor r13d, r13d
  .shared_frame:
    cmp r13, [rbx+SharedMemory.page_count]
    jae .free_object
    mov rdi, [rbx+SharedMemory.frames+r13*8]
    call pmm_free_frame
    inc r13
    jmp .shared_frame
  .free_object:
  mov rdi, rbx
  call kfree
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf
