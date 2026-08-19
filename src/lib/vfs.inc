;//////////////////////////////////////////////////////////////////////////////
;// libvarania: filesystem.vlib ABI 1
;//////////////////////////////////////////////////////////////////////////////

VLIB_FILESYSTEM_ABI = 1
VLIB_FS_VA           = 0x0000000064000000
VLIB_FS_BYTES        = 64*PAGE_SIZE
VLIB_PATH_MAX        = 255

segment readable executable

vlib_fs_connect:
  mov edi, SERVICE_FILESYSTEM
  mov esi, VLIB_FILESYSTEM_ABI
  call vlib_open
  test rax, rax
  js .done
  mov [vlib_fs_endpoint], rax
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_ATTACH
  call vlib_fs_rpc
  test rax, rax
  jnz .done
  cmp qword [vlib_reply+IpcMessage.cap_count], 1
  jne .protocol
  mov rdx, qword [vlib_reply+IpcMessage.words+8]
  cmp rdx, VLIB_FS_BYTES
  jb .protocol
  mov rdi, qword [vlib_reply+IpcMessage.caps+IpcCap.handle]
  mov [vlib_fs_buffer_cap], rdi
  mov eax, SYS_SHARED_MAP
  mov rsi, VLIB_FS_VA
  mov edx, SPACE_MAP_WRITE
  syscall
  ret
.protocol:
  mov rax, VLIB_ERR_PROTOCOL
.done:
  ret

;// Явно вернуть VFS session slot перед exit короткоживущего приложения.
vlib_fs_disconnect:
  cmp qword [vlib_fs_endpoint], 0
  je .done
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_DETACH
  call vlib_fs_rpc
.done:
  ret

vlib_fs_prepare:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ret

vlib_fs_rpc:
  mov rdi, [vlib_fs_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  ipc_receive VLIB_SELF_EP, vlib_reply
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words]
.done:
  ret

;// RDI=absolute/root-relative path. RAX=object/error, RDX=kind.
vlib_fs_resolve:
  push rbx
  push r12
  push r13
  mov r12, rdi
  xor ebx, ebx
.skip_slash:
  cmp byte [r12], '/'
  jne .component_or_end
  inc r12
  jmp .skip_slash
.component_or_end:
  cmp byte [r12], 0
  je .root_or_last
  xor r13d, r13d
.copy_component:
  mov al, [r12]
  test al, al
  jz .component_ready
  cmp al, '/'
  je .component_ready
  cmp r13, 47
  jae .invalid
  mov [vlib_path_component+r13], al
  inc r13
  inc r12
  jmp .copy_component
.component_ready:
  mov byte [vlib_path_component+r13], 0
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_LOOKUP
  mov qword [vlib_message+IpcMessage.words+8], rbx
  lea rdi, [vlib_message+IpcMessage.words+16]
  lea rsi, [vlib_path_component]
  mov ecx, 48
  rep movsb
  call vlib_fs_rpc
  test rax, rax
  jnz .done
  mov rbx, qword [vlib_reply+IpcMessage.words+8]
  mov rdx, qword [vlib_reply+IpcMessage.words+16]
  jmp .skip_slash
.root_or_last:
  mov rax, rbx
  test rbx, rbx
  jnz .done
  mov edx, FS_NODE_DIR
  jmp .done
.invalid:
  mov rax, VLIB_ERR_INVALID
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=path отсутствующего файла. RAX=object/error.
vlib_fs_create:
  push rbx
  push r12
  push r13
  mov r12, rdi
  lea rdi, [vlib_path_work]
  xor ebx, ebx
  xor ecx, ecx
.copy_path:
  cmp ecx, VLIB_PATH_MAX
  jae .invalid
  mov al, [r12+rcx]
  mov [rdi+rcx], al
  test al, al
  jz .copied
  cmp al, '/'
  jne .next
  lea ebx, [ecx+1]
.next:
  inc ecx
  jmp .copy_path
.copied:
  test ecx, ecx
  jz .invalid
  test ebx, ebx
  jz .root_parent
  cmp ebx, ecx
  jae .invalid
  lea r13, [vlib_path_work+rbx]
  cmp ebx, 1
  je .keep_root
  mov byte [vlib_path_work+rbx-1], 0
  jmp .resolve_parent
.keep_root:
  mov byte [vlib_path_work+1], 0
.resolve_parent:
  lea rdi, [vlib_path_work]
  call vlib_fs_resolve
  test rax, rax
  js .done
  cmp rdx, FS_NODE_DIR
  jne .invalid
  mov rbx, rax
  jmp .create
.root_parent:
  xor ebx, ebx
  lea r13, [vlib_path_work]
.create:
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_CREATE
  mov qword [vlib_message+IpcMessage.words+8], rbx
  lea rdi, [vlib_message+IpcMessage.words+16]
  mov rsi, r13
  mov ecx, 48
.name:
  lodsb
  stosb
  test al, al
  jz .send
  dec ecx
  jnz .name
  jmp .invalid
.send:
  call vlib_fs_rpc
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words+8]
  jmp .done
.invalid:
  mov rax, VLIB_ERR_INVALID
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=object. RAX=status, RDX=size, RCX=kind.
vlib_fs_stat:
  push rbx
  mov rbx, rdi
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_STAT
  mov qword [vlib_message+IpcMessage.words+8], rbx
  call vlib_fs_rpc
  mov rdx, qword [vlib_reply+IpcMessage.words+8]
  mov rcx, qword [vlib_reply+IpcMessage.words+16]
  pop rbx
  ret

;// RDI=object, RSI=offset, RDX=bytes, R10=destination.
;// RAX=фактически прочитанные bytes/error.
vlib_fs_read:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, r10
  xor r15d, r15d
.chunk:
  cmp r15, r13
  jae .success
  mov rdx, r13
  sub rdx, r15
  cmp rdx, VLIB_FS_BYTES
  jbe .size_ready
  mov edx, VLIB_FS_BYTES
.size_ready:
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_READ
  mov qword [vlib_message+IpcMessage.words+8], rbx
  lea rax, [r12+r15]
  mov qword [vlib_message+IpcMessage.words+16], rax
  mov qword [vlib_message+IpcMessage.words+24], rdx
  mov qword [vlib_message+IpcMessage.words+32], 0
  call vlib_fs_rpc
  test rax, rax
  jnz .done
  mov rcx, qword [vlib_reply+IpcMessage.words+8]
  test rcx, rcx
  jz .success
  lea rdi, [r14+r15]
  mov rsi, VLIB_FS_VA
  push rcx
  rep movsb
  pop rcx
  add r15, rcx
  jmp .chunk
.success:
  mov rax, r15
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=object, RSI=offset, RDX=bytes, R10=source, R8=FS_WRITE flags.
;// Данные автоматически режутся на streaming chunks.
vlib_fs_write:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, r10
  mov [rsp], r8
  xor r15d, r15d
  test r13, r13
  jz .empty_write
.chunk:
  cmp r15, r13
  jae .success
  mov rdx, r13
  sub rdx, r15
  cmp rdx, VLIB_FS_BYTES
  jbe .size_ready
  mov edx, VLIB_FS_BYTES
.size_ready:
  mov rsi, r14
  add rsi, r15
  mov rdi, VLIB_FS_VA
  mov rcx, rdx
  rep movsb
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_WRITE
  mov qword [vlib_message+IpcMessage.words+8], rbx
  lea rax, [r12+r15]
  mov qword [vlib_message+IpcMessage.words+16], rax
  mov qword [vlib_message+IpcMessage.words+24], rdx
  mov qword [vlib_message+IpcMessage.words+32], 0
  mov rax, [rsp]
  mov qword [vlib_message+IpcMessage.words+40], rax
  call vlib_fs_rpc
  test rax, rax
  jnz .done
  mov qword [rsp], 0
  add r15, rdx
  jmp .chunk
.empty_write:
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_WRITE
  mov qword [vlib_message+IpcMessage.words+8], rbx
  mov qword [vlib_message+IpcMessage.words+16], r12
  mov qword [vlib_message+IpcMessage.words+24], 0
  mov qword [vlib_message+IpcMessage.words+32], 0
  mov rax, [rsp]
  mov qword [vlib_message+IpcMessage.words+40], rax
  call vlib_fs_rpc
  test rax, rax
  jnz .done
.success:
  mov rax, r15
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
