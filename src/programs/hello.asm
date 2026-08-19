format ELF64 executable 3
entry start
include "../user/abi.inc"

;// Эта программа принципиально не входит в initramfs. Shell читает её из
;// VaraniaFS, procd проверяет ELF64 через shared-memory окно и только после
;// этого создаёт address space. Маркер делает весь путь проверяемым в CI.

segment readable executable
start:
  log hello_text, hello_text.size
  exit_process 0

segment readable writeable
hello_text db "VARANIA:DISK_ELF_OK", 10
.size = $-hello_text
