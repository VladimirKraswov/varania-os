format ELF64 executable 3
entry start
include "../user/abi.inc"
include "../lib/runtime.inc"

;// Небольшая системная утилита и минимальный пример libvarania. Аппаратную
;// информацию она получает через безопасный syscall/service API, а не читает
;// kernel memory или device registers.

segment readable executable
start:
  call vlib_initialize
  test rax, rax
  jnz .failed
  lea rdi, [banner]
  mov esi, banner.size
  call vlib_terminal_write

  system_call SYS_MEM_INFO
  lea rdi, [number_buffer+20]
  mov byte [rdi], 10
  mov rcx, 1
  mov rbx, 10
.digit:
  xor edx, edx
  div rbx
  add dl, '0'
  dec rdi
  mov [rdi], dl
  inc rcx
  test rax, rax
  jnz .digit
  mov rsi, rcx
  call vlib_terminal_write
  log sysinfo_marker, sysinfo_marker.size
  call vlib_shutdown
  exit_process 0
.failed:
  exit_process 1

segment readable writeable
banner db "Varania OS amd64 | free 4-KiB frames: "
.size = $-banner
sysinfo_marker db "VARANIA:SYSINFO_OK", 10
.size = $-sysinfo_marker
number_buffer rb 21
