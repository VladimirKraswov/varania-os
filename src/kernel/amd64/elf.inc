;//////////////////////////////////////////////////////////////////////////////
;// Строгий загрузчик ELF64 ET_EXEC для пользовательских процессов
;//////////////////////////////////////////////////////////////////////////////
;
;// Поддерживается ровно тот поднабор, который полезен микроядру: little-endian
;// x86-64, PT_LOAD, 4-KiB alignment, отдельные W^X-сегменты и BSS. Relocations,
;// interpreter и dynamic linking сознательно оставлены будущему user loader.

ELF64.header_size = 64
ELF64.ph_size     = 56
ELF64.PT_LOAD     = 1
ELF64.ET_EXEC     = 2
ELF64.EM_X86_64   = 62
ELF64.PF_X        = 1
ELF64.PF_W        = 2
ELF64.PF_R        = 4
ELF64.max_ph      = 16

;// Скопировать диапазон в уже отображённые user-страницы.
;// RDI=TCB, RSI=user destination, RDX=kernel source, RCX=length. RAX=1/0.
function elf_copy_to_user
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov r15, rcx
  .page:
    test r15, r15
    jz .success
    mov rdi, [r12+Task.cr3]
    mov rsi, r13
    call vmm_translate_user
    test rax, rax
    jz .failed
    hhdm_address rdi, rax
    mov rbx, r13
    and ebx, PAGE_SIZE-1
    mov edx, PAGE_SIZE
    sub rdx, rbx
    cmp rdx, r15
    jbe .chunk_ready
    mov rdx, r15
  .chunk_ready:
    mov rsi, r14
    mov rbx, rdx
    call memory_copy
    add r13, rbx
    add r14, rbx
    sub r15, rbx
    jmp .page
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

;// RDI=TCB, RSI=image, RDX=size. RAX=entry или 0.
function elf_load_process
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 40
  mov r12, rdi                    ;// TCB
  mov r13, rsi                    ;// image
  mov r14, rdx                    ;// image size

  cmp r14, ELF64.header_size
  jb .failed
  cmp dword [r13+0], 0x464C457F  ;// 7F 'E' 'L' 'F'
  jne .failed
  cmp byte [r13+4], 2             ;// ELFCLASS64
  jne .failed
  cmp byte [r13+5], 1             ;// ELFDATA2LSB
  jne .failed
  cmp byte [r13+6], 1             ;// EV_CURRENT
  jne .failed
  cmp word [r13+16], ELF64.ET_EXEC
  jne .failed
  cmp word [r13+18], ELF64.EM_X86_64
  jne .failed
  cmp dword [r13+20], 1
  jne .failed
  cmp word [r13+52], ELF64.header_size
  jne .failed
  cmp word [r13+54], ELF64.ph_size
  jne .failed
  movzx ebx, word [r13+56]
  test ebx, ebx
  jz .failed
  cmp ebx, ELF64.max_ph
  ja .failed
  mov rax, [r13+32]               ;// e_phoff
  mov rcx, rbx
  imul rcx, ELF64.ph_size
  add rcx, rax
  jc .failed
  cmp rcx, r14
  ja .failed
  add rax, r13
  mov r15, rax                    ;// program header cursor
  mov qword [rsp+0], 0            ;// max end address
  mov qword [rsp+8], 0            ;// entry belongs to executable PT_LOAD

  ;// Первый проход ничего не выделяет: malformed ELF не оставляет mappings.
  mov ecx, ebx
  .validate:
    cmp dword [r15+0], ELF64.PT_LOAD
    je .validate_load
    cmp dword [r15+0], 0           ;// PT_NULL разрешён как пустая запись
    jne .failed                    ;// INTERP/DYNAMIC требуют другого loader-а
    jmp .validate_next
  .validate_load:
    mov rax, [r15+40]             ;// p_memsz
    test rax, rax
    jz .validate_next
    cmp [r15+32], rax             ;// p_filesz <= p_memsz
    ja .failed
    mov rdx, [r15+8]              ;// p_offset + p_filesz <= image
    add rdx, [r15+32]
    jc .failed
    cmp rdx, r14
    ja .failed
    mov rdx, [r15+16]             ;// p_vaddr
    cmp rdx, USER.imageMin
    jb .failed
    add rax, rdx                   ;// first address after segment
    jc .failed
    cmp rax, USER.imageMax
    ja .failed
    mov r8, [r15+8]
    xor r8, rdx
    test r8, PAGE_SIZE-1           ;// одинаковое смещение внутри страницы
    jnz .failed
    mov r8, [r15+48]               ;// p_align
    test r8, r8
    jz .alignment_ok
    cmp r8, 1
    je .alignment_ok
    cmp r8, PAGE_SIZE
    jne .failed
  .alignment_ok:
    mov eax, [r15+4]
    test eax, ELF64.PF_R
    jz .failed
    mov edx, eax
    and edx, ELF64.PF_X+ELF64.PF_W
    cmp edx, ELF64.PF_X+ELF64.PF_W ;// W^X
    je .failed

    mov rax, [r15+16]
    add rax, [r15+40]
    cmp rax, [rsp+0]
    jbe .check_entry
    mov [rsp+0], rax
  .check_entry:
    test dword [r15+4], ELF64.PF_X
    jz .validate_next
    mov rdx, [r13+24]              ;// e_entry
    cmp rdx, [r15+16]
    jb .validate_next
    cmp rdx, rax
    jae .validate_next
    mov qword [rsp+8], 1
  .validate_next:
    add r15, ELF64.ph_size
    dec ecx
    jnz .validate
  cmp qword [rsp+8], 1
  jne .failed
  cmp qword [rsp+0], 0
  je .failed

  ;// Второй проход создаёт страницы, выставляя RW и NX по p_flags.
  mov rax, [r13+32]
  add rax, r13
  mov r15, rax
  mov r14d, ebx
  .load:
    cmp dword [r15+0], ELF64.PT_LOAD
    jne .load_next
    cmp qword [r15+40], 0
    je .load_next
    mov rbx, [r15+16]
    and rbx, -PAGE_SIZE
    mov rax, [r15+16]
    add rax, [r15+40]
    add rax, PAGE_SIZE-1
    and rax, -PAGE_SIZE
    mov [rsp+16], rax              ;// segment page end
  .map_page:
    cmp rbx, [rsp+16]
    jae .copy_file
    mov rdi, [r12+Task.cr3]
    mov rsi, rbx
    call vmm_translate_user
    test rax, rax
    jnz .failed                    ;// перекрывающиеся PT_LOAD запрещены
    mov rdx, PAGE.US
    test dword [r15+4], ELF64.PF_W
    jz .not_writable
    or rdx, PAGE.RW
  .not_writable:
    test dword [r15+4], ELF64.PF_X
    jnz .flags_ready
    bts rdx, 63
  .flags_ready:
    mov rdi, [r12+Task.cr3]
    mov rsi, rbx
    call vmm_alloc_user_page
    test rax, rax
    jz .failed
    add rbx, PAGE_SIZE
    jmp .map_page

  .copy_file:
    cmp qword [r15+32], 0
    jz .load_next
    mov rdi, r12
    mov rsi, [r15+16]
    mov rdx, [r15+8]
    add rdx, r13
    mov rcx, [r15+32]
    call elf_copy_to_user
    test rax, rax
    jz .failed
  .load_next:
    add r15, ELF64.ph_size
    dec r14d
    jnz .load

  mov rax, [rsp+0]
  add rax, PAGE_SIZE-1
  and rax, -PAGE_SIZE
  mov [r12+Task.brk_base], rax
  mov [r12+Task.brk_current], rax
  mov rax, [r13+24]
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 40
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
endf
