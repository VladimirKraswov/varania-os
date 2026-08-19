format ELF64 executable 3
entry start
include "abi.inc"

;// Минимальный сервис, изображающий аварийное завершение. Supervisor считает
;// код 55 отказом и создаёт новый экземпляр из того же ELF64.
segment readable executable
start:
  exit_process 55
