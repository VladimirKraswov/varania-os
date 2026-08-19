format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  ;// init передаёт IRQ capability как handle 1, I/O range — как handle 2.
  log ready_text, ready_text.size
.wait:
  mov eax, SYS_IRQ_WAIT
  mov edi, 1
  syscall
  mov eax, SYS_IO_READ8
  mov edi, 2
  xor esi, esi
  syscall
  log handled_text, handled_text.size
  jmp .wait

segment readable writeable
ready_text db "keyboard-driver: waiting for IRQ1", 10
.size = $-ready_text
handled_text db "keyboard-driver: IRQ1 handled", 10
.size = $-handled_text
