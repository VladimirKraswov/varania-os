format ELF64 executable 3
entry start
include "../user/abi.inc"
include "../lib/runtime.inc"

;//////////////////////////////////////////////////////////////////////////////
;// Graphical terminal window client
;//////////////////////////////////////////////////////////////////////////////
;
;// Terminal model остаётся существующим SERVICE_TERMINAL, поэтому shell,
;// VEdit, FASM и любые старые программы автоматически работают в окне.
;// gterm управляет lifecycle отдельного shell и window close event.

segment readable executable
start:
  call vlib_initialize
  test rax, rax
  jnz fatal
  call vlib_gui_connect
  test rax, rax
  jnz fatal
  lea rdi, [shell_path]
  lea rsi, [shell_command]
  call vlib_process_spawn
  test rax, rax
  js fatal
  mov r12, rax                   ;// WAIT|CONTROL capability shell
  mov r13, rdx                   ;// endpoint, закрывается вместе с окном
  call vlib_gui_terminal_open
  test rax, rax
  jnz terminate_shell
  log ready_text, ready_text.size

.events:
  mov edi, GUI_ROLE_TERMINAL
  call vlib_gui_wait_event
  test rax, rax
  js terminate_shell
  cmp rax, GUI_EVENT_CLOSE
  jne .events

terminate_shell:
  ;// Window close не оставляет background shell с pending READLINE.
  mov eax, SYS_PROCESS_KILL
  mov rdi, r12
  xor esi, esi
  syscall
  mov rdi, r12
  system_call SYS_WAIT
  mov rdi, r13
  call vlib_close
  call vlib_gui_terminal_close
  call vlib_shutdown
  log closed_text, closed_text.size
  exit_process 0

fatal:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
ready_text db "VARANIA:GTERM_READY", 10
.size = $-ready_text
closed_text db "VARANIA:GTERM_CLOSED", 10
.size = $-closed_text
failed_text db "gterm: cannot create graphical shell window", 10
.size = $-failed_text
shell_path db "/system/build/user/shell.elf",0
shell_command db "shell",0
