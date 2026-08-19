;//////////////////////////////////////////////////////////////////////////////
;// libvarania: IPC и versioned capability libraries
;//////////////////////////////////////////////////////////////////////////////

VLIB_SELF_EP       = 1
VLIB_NAMESERVER_EP = 2

segment readable executable

;// RDI=endpoint, RSI=IpcMessage. Конечная очередь создаёт backpressure.
vlib_send_retry:
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
.again:
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  mov rsi, r13
  syscall
  cmp rax, VLIB_IPC_WOULD_BLOCK
  jne .done
  system_call SYS_YIELD
  jmp .again
.done:
  pop r13
  pop r12
  ret

;// Открыть динамический .vlib-контракт.
;// EDI=service ID, ESI=minimum ABI; RAX=endpoint/error, RDX=actual ABI.
vlib_open:
  push rbx
  push r12
  mov ebx, edi
  mov r12d, esi
.retry:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [vlib_message+IpcMessage.words+8], rbx
  mov qword [vlib_message+IpcMessage.words+16], r12
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov edi, VLIB_NAMESERVER_EP
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  ipc_receive VLIB_SELF_EP, vlib_reply
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words]
  test rax, rax
  jz .found
  cmp rax, VLIB_ERR_NOT_FOUND
  jne .done
  system_call SYS_YIELD
  jmp .retry
.found:
  mov rdx, qword [vlib_reply+IpcMessage.words+8]
  cmp rdx, r12
  jb .protocol
  cmp qword [vlib_reply+IpcMessage.cap_count], 1
  jne .protocol
  mov rax, qword [vlib_reply+IpcMessage.caps+IpcCap.handle]
  jmp .done
.protocol:
  mov rax, VLIB_ERR_PROTOCOL
.done:
  pop r12
  pop rbx
  ret

vlib_close:
  test rdi, rdi
  jz .done
  close_cap rdi
.done:
  ret
