format ELF64 executable 3
entry start
include '/system/src/user/abi.inc'

;// Этот короткий исходник находится на VaraniaFS и собирается самим FASM,
;// запущенным внутри Varania OS. Результат затем загружается обратно с диска.
segment readable executable
start:
  log message, message.size
  exit_process 0

segment readable writeable
message db "VARANIA:SELFHOST_FASM_OK", 10
.size = $-message
