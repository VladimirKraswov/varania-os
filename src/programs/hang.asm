format ELF64 executable 3
entry start
include "../user/abi.inc"

;// Намеренно бесконечная пользовательская программа для проверки Ctrl+C.
;// Таймер продолжает вытеснять её, а sessiond завершает по CAP_CONTROL.
segment readable executable
start:
  log ready_text, ready_text.size
.forever:
  jmp .forever

segment readable writeable
ready_text db "VARANIA:HANG_READY", 10
.size = $-ready_text
