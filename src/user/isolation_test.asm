format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  log start_text, start_text.size
  ;// HHDM есть в CR3 процесса, но на всех уровнях остаётся supervisor-only.
  ;// Чтение из ring 3 обязано породить #PF и завершить только этот процесс.
  mov rax, 0FFFF80000000000h shl 4
  mov rax, [rax]
  exit_process 99                 ;// сюда исправное ядро не дойдёт

segment readable writeable
start_text db "isolation-test: probing supervisor HHDM", 10
.size = $-start_text
