;//////////////////////////////////////////////////////////////////////////////
;// libvarania: session.vlib ABI 1
;//////////////////////////////////////////////////////////////////////////////

VLIB_SESSION_ABI = 1

segment readable executable

vlib_session_connect:
  mov edi, SERVICE_SESSION
  mov esi, VLIB_SESSION_ABI
  call vlib_open
  test rax, rax
  js .done
  mov [vlib_session_endpoint], rax
  xor eax, eax
.done:
  ret

;// RDI=process capability с CAP_CONTROL. Sessiond кладёт её поверх текущего
;// foreground: вложенный run можно прервать, не теряя родительский editor.
vlib_session_push_foreground:
  push r12
  mov r12, rdi
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], SESSION_SET_FOREGROUND
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], r12
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_CONTROL
  mov rdi, [vlib_session_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r12
  ret

vlib_session_pop_foreground:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], SESSION_CLEAR_FOREGROUND
  mov rdi, [vlib_session_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  ret
