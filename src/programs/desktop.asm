format ELF64 executable 3
entry start
include "../user/abi.inc"
include "../lib/runtime.inc"

;//////////////////////////////////////////////////////////////////////////////
;// Desktop shell — policy client поверх GUI server
;//////////////////////////////////////////////////////////////////////////////
;
;// Программа не рисует pixels и не содержит widgets. Она просит системный
;// GUI-сервис открыть desktop session и запускает приложения по semantic event.

segment readable executable
start:
  call vlib_initialize
  test rax, rax
  jnz fatal
  call vlib_gui_connect
  test rax, rax
  jnz fatal
  call vlib_gui_desktop_enter
  test rax, rax
  jnz fatal
  log ready_text, ready_text.size
.events:
  mov edi, GUI_ROLE_DESKTOP
  call vlib_gui_wait_event
  test rax, rax
  js fatal
  cmp rax, GUI_EVENT_LAUNCH_TERMINAL
  jne .events
  log launch_text, launch_text.size
  lea rdi, [terminal_path]
  lea rsi, [terminal_command]
  call vlib_process_run
  test rax, rax
  jz .events
  log launch_failed_text, launch_failed_text.size
  ;// Закрытие окна — обычный успешный lifecycle; ошибка приложения не должна
  ;// завершать desktop session или разрушать compositor.
  jmp .events

fatal:
  call vlib_gui_desktop_leave
  call vlib_shutdown
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
ready_text db "VARANIA:DESKTOP_CLIENT_READY", 10
.size = $-ready_text
failed_text db "desktop: GUI/session service failure", 10
.size = $-failed_text
launch_text db "VARANIA:DESKTOP_LAUNCH_TERMINAL", 10
.size = $-launch_text
launch_failed_text db "desktop: gterm lifecycle failed", 10
.size = $-launch_failed_text
terminal_path db "/bin/gterm.elf",0
terminal_command db "gterm",0
