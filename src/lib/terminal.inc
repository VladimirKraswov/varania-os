;//////////////////////////////////////////////////////////////////////////////
;// libvarania: terminal.vlib ABI 1
;//////////////////////////////////////////////////////////////////////////////

VLIB_TERMINAL_ABI = 1
VGA_TEXT_WIDTH     = 80
VGA_TEXT_HEIGHT    = 25

segment readable executable

vlib_terminal_connect:
  mov edi, SERVICE_TERMINAL
  mov esi, VLIB_TERMINAL_ABI
  call vlib_open
  test rax, rax
  js .done
  mov [vlib_terminal_endpoint], rax
  xor eax, eax
.done:
  ret

vlib_terminal_clear:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], TERM_CLEAR
  mov rdi, [vlib_terminal_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  ret

;// RDI=text, RSI=bytes. Plain sequential output for diagnostics.
vlib_terminal_write:
  push rbx
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
.chunk:
  test r13, r13
  jz .success
  mov rbx, r13
  cmp rbx, 16
  jbe .chunk_ready
  mov ebx, 16
.chunk_ready:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], TERM_WRITE
  mov qword [vlib_message+IpcMessage.words+8], rbx
  lea rdi, [vlib_message+IpcMessage.words+16]
  mov rsi, r12
  mov rcx, rbx
  rep movsb
  mov rdi, [vlib_terminal_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  add r12, rbx
  sub r13, rbx
  jmp .chunk
.success:
  xor eax, eax
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// Заблокироваться до следующего key event. RAX=event/error.
vlib_terminal_read_key:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], TERM_READKEY
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rdi, [vlib_terminal_endpoint]
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
  mov rax, qword [vlib_reply+IpcMessage.words+8]
.done:
  ret

;// Абсолютно вывести VGA cells (char,attribute).
;// RDI=cells, ESI=x, EDX=y, ECX=count <= 80. RAX=status.
vlib_terminal_draw:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi
  mov r13d, esi
  mov r14d, edx
  mov r15d, ecx
.chunk:
  test r15d, r15d
  jz .success
  mov ebx, r15d
  cmp ebx, 24
  jbe .ready
  mov ebx, 24
.ready:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], TERM_DRAW
  mov eax, r14d
  shl eax, 8
  or eax, r13d
  mov edx, ebx
  shl edx, 16
  or eax, edx
  mov qword [vlib_message+IpcMessage.words+8], rax
  lea rdi, [vlib_message+IpcMessage.words+16]
  mov rsi, r12
  mov ecx, ebx
  shl ecx, 1
  rep movsb
  mov rdi, [vlib_terminal_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  lea r12, [r12+rbx*2]
  add r13d, ebx
  sub r15d, ebx
  jmp .chunk
.success:
  xor eax, eax
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
