format ELF64 executable 3
entry start
include '/system/src/user/abi.inc'

; Минимальная пользовательская программа Varania OS.
segment readable executable
start:
  log message, message.size
  exit_process 0

segment readable writeable
message db "Hello from Varania OS!", 10
.size = $-message
