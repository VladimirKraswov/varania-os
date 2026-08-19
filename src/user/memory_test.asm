format ELF64 executable 3
entry start
include "abi.inc"

segment readable executable
start:
  ;// Переход через более чем страницу NOP заставляет ELF-loader отобразить
  ;// несколько RX-страниц одного PT_LOAD-сегмента.
  jmp code_after_padding
  times 5000 db 0x90
code_after_padding:
  ;// RW-сегмент содержит больше двух страниц BSS и обязан быть обнулён.
  cmp byte [large_bss], 0
  jne .failed
  cmp byte [large_bss+PAGE_SIZE], 0
  jne .failed
  cmp byte [large_bss+2*PAGE_SIZE], 0
  jne .failed
  mov byte [large_bss], 0x11
  mov byte [large_bss+PAGE_SIZE], 0x22
  mov byte [large_bss+2*PAGE_SIZE], 0x33

  ;// Последовательные касания растят user stack по одной странице через #PF.
  mov ecx, 4
.grow_stack:
  sub rsp, PAGE_SIZE
  mov [rsp], rcx
  loop .grow_stack
  add rsp, 4*PAGE_SIZE

  ;// brk(0) возвращает начало heap; затем растим его на три страницы.
  xor edi, edi
  system_call SYS_BRK
  mov r12, rax
  lea rdi, [r12+3*PAGE_SIZE]
  system_call SYS_BRK
  test rax, rax
  js .failed
  mov qword [r12], 0x1111
  mov qword [r12+PAGE_SIZE], 0x2222
  mov qword [r12+2*PAGE_SIZE], 0x3333

  ;// После shrink и повторного grow новый кадр должен быть обнулён.
  mov rdi, r12
  system_call SYS_BRK
  lea rdi, [r12+PAGE_SIZE]
  system_call SYS_BRK
  cmp qword [r12], 0
  jne .failed

  log ok_text, ok_text.size
  exit_process 0
.failed:
  log failed_text, failed_text.size
  exit_process 3

segment readable writeable
large_bss rb 3*PAGE_SIZE+37
ok_text db "VARANIA:MEMORY_OK", 10
.size = $-ok_text
failed_text db "memory-test: failed", 10
.size = $-failed_text
