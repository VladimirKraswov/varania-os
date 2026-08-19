format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  ;// Ненулевой статус нужен init для проверки SYS_WAIT.
  exit_process 37

segment readable writeable
reserved_data rb PAGE_SIZE+17
