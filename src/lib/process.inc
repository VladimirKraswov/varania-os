;//////////////////////////////////////////////////////////////////////////////
;// libvarania: process.vlib ABI 1
;//////////////////////////////////////////////////////////////////////////////

VLIB_PROCESS_ABI = 1

segment readable executable

vlib_process_connect:
  mov edi, SERVICE_PROCESS
  mov esi, VLIB_PROCESS_ABI
  call vlib_open
  test rax, rax
  js .done
  mov [vlib_process_endpoint], rax
  xor eax, eax
.done:
  ret

;// Асинхронно запустить ELF64 из VaraniaFS.
;// RDI=executable path, RSI=полная command line.
;// RAX=process capability/error, RDX=child endpoint capability.
;// ELF и argv разделяют VFS shared window, поэтому длина argv не ограничена
;// шестью IPC words. Procd получает только MAP|READ capability.
vlib_process_spawn:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov r12, rsi                    ;// command
  call vlib_fs_resolve
  test rax, rax
  js .done
  cmp rdx, FS_NODE_FILE
  jne .invalid
  mov r13, rax                    ;// object
  mov rdi, r13
  call vlib_fs_stat
  test rax, rax
  jnz .done
  test rdx, rdx
  jz .invalid
  cmp rdx, VLIB_FS_BYTES
  jae .too_large
  mov r14, rdx                    ;// exact ELF size

  ;// READ прямо в начало общего окна.
  call vlib_fs_prepare
  mov qword [vlib_message+IpcMessage.words], FS_READ
  mov qword [vlib_message+IpcMessage.words+8], r13
  mov qword [vlib_message+IpcMessage.words+16], 0
  mov qword [vlib_message+IpcMessage.words+24], r14
  mov qword [vlib_message+IpcMessage.words+32], 0
  call vlib_fs_rpc
  test rax, rax
  jnz .done
  cmp qword [vlib_reply+IpcMessage.words+8], r14
  jne .io_error

  mov rdi, r12
  mov esi, 1024
  call vlib_string_length
  test rax, rax
  js .done
  lea r15, [rax+1]                ;// including NUL
  mov rbx, r14
  add rbx, 15
  and rbx, -16                    ;// argv immediately after aligned ELF
  mov rax, rbx
  add rax, r15
  jc .too_large
  cmp rax, VLIB_FS_BYTES
  ja .too_large
  lea rdi, [VLIB_FS_VA+rbx]
  mov rsi, r12
  mov rcx, r15
  rep movsb

  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], PROCD_SPAWN_IMAGE
  mov qword [vlib_message+IpcMessage.words+8], r14
  mov rax, PROCD_ARGS_SHARED
  mov qword [vlib_message+IpcMessage.words+16], rax
  mov qword [vlib_message+IpcMessage.words+24], rbx
  mov qword [vlib_message+IpcMessage.words+32], r15
  mov qword [vlib_message+IpcMessage.cap_count], 2
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rax, [vlib_fs_buffer_cap]
  mov qword [vlib_message+IpcMessage.caps+IpcCap.bytes+IpcCap.handle], rax
  mov qword [vlib_message+IpcMessage.caps+IpcCap.bytes+IpcCap.rights], CAP_MAP+CAP_READ
  mov rdi, [vlib_process_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  ipc_receive VLIB_SELF_EP, vlib_reply
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words]
  test rax, rax
  jnz .done
  cmp qword [vlib_reply+IpcMessage.cap_count], 2
  jne .protocol
  mov r12, qword [vlib_reply+IpcMessage.caps+IpcCap.handle]
  mov r13, qword [vlib_reply+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rax, r12
  mov rdx, r13
  jmp .done
.invalid:
  mov rax, VLIB_ERR_INVALID
  jmp .done
.too_large:
  mov rax, VLIB_ERR_TOO_LONG
  jmp .done
.io_error:
  mov rax, VLIB_ERR_IO
  jmp .done
.protocol:
  mov rax, VLIB_ERR_PROTOCOL
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Синхронная удобная обёртка сохраняет прежний ABI. GUI launcher использует
;// spawn, чтобы одновременно ждать window events и управлять дочерним shell.
vlib_process_run:
  push r12
  push r13
  call vlib_process_spawn
  test rax, rax
  js .done
  mov r12, rax
  mov r13, rdx
  mov rdi, r12
  call vlib_session_push_foreground
  test rax, rax
  jnz .untracked
  mov rdi, r12
  system_call SYS_WAIT
  mov [rsp], rax
  call vlib_session_pop_foreground
  mov rdi, r12
  call vlib_close
  mov rdi, r13
  call vlib_close
  mov rax, [rsp]
  jmp .done
.untracked:
  ;// Не блокируемся на процессе без независимого control path.
  mov eax, SYS_PROCESS_KILL
  mov rdi, r12
  mov esi, SESSION_INTERRUPTED_STATUS
  syscall
  mov rdi, r12
  system_call SYS_WAIT
  mov rdi, r13
  call vlib_close
  mov rax, VLIB_ERR_IO
  jmp .done
.done:
  pop r13
  pop r12
  ret
