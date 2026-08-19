;//////////////////////////////////////////////////////////////////////////////
;// Read-only initramfs, подготовленный scripts/mkinitramfs.py
;//////////////////////////////////////////////////////////////////////////////

InitramfsHeader.magic       = 0
InitramfsHeader.version     = 8
InitramfsHeader.entry_count = 12
InitramfsHeader.total_size  = 16
InitramfsHeader.bytes       = 24

InitramfsEntry.name   = 0
InitramfsEntry.offset = 32
InitramfsEntry.size   = 36
InitramfsEntry.bytes  = 48
INITRAMFS_MAX_FILES   = 32

initramfs_base dq 0
initramfs_used dd 0
initramfs_count dd 0

;// Проверить весь заголовок до первого поиска файла. RAX=1/0.
function initramfs_init
  hhdm_address rdx, INITRAMFS.physBase
  cmp dword [rdx+0], 0x4E524156   ;// "VARN"
  jne .failed
  cmp dword [rdx+4], 0x31305249   ;// "IR01"
  jne .failed
  cmp dword [rdx+InitramfsHeader.version], 1
  jne .failed
  mov ecx, [rdx+InitramfsHeader.entry_count]
  test ecx, ecx
  jz .failed
  cmp ecx, INITRAMFS_MAX_FILES
  ja .failed
  mov eax, ecx
  imul eax, InitramfsEntry.bytes
  add eax, InitramfsHeader.bytes
  cmp eax, [rdx+InitramfsHeader.total_size]
  ja .failed
  mov eax, [rdx+InitramfsHeader.total_size]
  cmp eax, INITRAMFS.size
  ja .failed
  mov [initramfs_base], rdx
  mov [initramfs_used], eax
  mov [initramfs_count], ecx
  mov eax, 1
  jmp .done
  .failed:
  xor eax, eax
  .done:
endf

;// Найти файл по имени без завершающего NUL.
;// RDI=name, RSI=length (1..31). RAX=data, RDX=size; RAX=0 при ошибке.
function initramfs_find
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  test r13, r13
  jz .missing
  cmp r13, 31
  ja .missing
  mov rbx, [initramfs_base]
  test rbx, rbx
  jz .missing
  lea r14, [rbx+InitramfsHeader.bytes]
  mov ecx, [initramfs_count]
  .entry:
    xor eax, eax
  .compare:
    cmp rax, r13
    je .name_end
    mov dl, [r12+rax]
    cmp dl, [r14+InitramfsEntry.name+rax]
    jne .next
    inc rax
    jmp .compare
  .name_end:
    cmp byte [r14+InitramfsEntry.name+rax], 0
    jne .next
    mov eax, [r14+InitramfsEntry.offset]
    mov edx, [r14+InitramfsEntry.size]
    mov r8, rax
    add r8, rdx
    jc .missing
    cmp r8d, [initramfs_used]
    ja .missing
    add rax, rbx
    jmp .done
  .next:
    add r14, InitramfsEntry.bytes
    dec ecx
    jnz .entry
  .missing:
  xor eax, eax
  xor edx, edx
  .done:
  pop r14
  pop r13
  pop r12
  pop rbx
endf
