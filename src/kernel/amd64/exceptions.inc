;//////////////////////////////////////////////////////////////////////////////
;// Исключения процессора amd64
;//////////////////////////////////////////////////////////////////////////////

exception_title db 10, "CPU EXCEPTION", 10, 0
exception_vector_text db "Vector: ", 0
exception_error_text  db "  Error: ", 0
exception_rip_text    db "  RIP: ", 0
exception_unknown     db "Unknown exception", 0
exception_user_text   db "microkernel: terminated user task ", 0
exception_user_vector db " after exception ", 0

exception_name_0  db "#DE: divide error", 0
exception_name_1  db "#DB: debug", 0
exception_name_2  db "NMI", 0
exception_name_3  db "#BP: breakpoint", 0
exception_name_4  db "#OF: overflow", 0
exception_name_5  db "#BR: bound range", 0
exception_name_6  db "#UD: invalid opcode", 0
exception_name_7  db "#NM: device not available", 0
exception_name_8  db "#DF: double fault", 0
exception_name_9  db "legacy coprocessor exception", 0
exception_name_10 db "#TS: invalid TSS", 0
exception_name_11 db "#NP: segment not present", 0
exception_name_12 db "#SS: stack fault", 0
exception_name_13 db "#GP: general protection", 0
exception_name_14 db "#PF: page fault", 0
exception_name_15 db "reserved", 0
exception_name_16 db "#MF: x87 error", 0
exception_name_17 db "#AC: alignment check", 0
exception_name_18 db "#MC: machine check", 0
exception_name_19 db "#XM: SIMD error", 0
exception_name_20 db "#VE: virtualization", 0
exception_name_21 db "#CP: control protection", 0
exception_name_22 db "reserved", 0
exception_name_23 db "reserved", 0
exception_name_24 db "reserved", 0
exception_name_25 db "reserved", 0
exception_name_26 db "reserved", 0
exception_name_27 db "reserved", 0
exception_name_28 db "#HV: hypervisor injection", 0
exception_name_29 db "#VC: VMM communication", 0
exception_name_30 db "#SX: security", 0
exception_name_31 db "reserved", 0

exception_names:
  dq exception_name_0,  exception_name_1,  exception_name_2,  exception_name_3
  dq exception_name_4,  exception_name_5,  exception_name_6,  exception_name_7
  dq exception_name_8,  exception_name_9,  exception_name_10, exception_name_11
  dq exception_name_12, exception_name_13, exception_name_14, exception_name_15
  dq exception_name_16, exception_name_17, exception_name_18, exception_name_19
  dq exception_name_20, exception_name_21, exception_name_22, exception_name_23
  dq exception_name_24, exception_name_25, exception_name_26, exception_name_27
  dq exception_name_28, exception_name_29, exception_name_30, exception_name_31

;// Общий обработчик: RDI=вектор, RSI=код ошибки, RDX=адрес инструкции.
;// После ошибки продолжать исполнение небезопасно, поэтому показываем полный
;// минимум диагностики и останавливаем процессор. #DF использует IST1.
exception_dispatch:
  cli
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx

  mov edi, VGA.white
  mov esi, VGA.red
  call print_set_colors
  lea rdi, [exception_title]
  call print_string

  cmp r12, 32
  jae .unknown
  lea rax, [exception_names]
  mov rdi, [rax+r12*8]
  jmp .print_name
  .unknown:
  lea rdi, [exception_unknown]
  .print_name:
  call print_string
  mov edi, PRINT.newline
  call print_char

  lea rdi, [exception_vector_text]
  call print_string
  mov rdi, r12
  call print_hex64
  lea rdi, [exception_error_text]
  call print_string
  mov rdi, r13
  call print_hex64
  lea rdi, [exception_rip_text]
  call print_string
  mov rdi, r14
  call print_hex64
  mov edi, PRINT.newline
  call print_char
  jmp cpu_halt_forever

;// Исключение из ring 3 — ошибка одного сервиса, а не ошибка всей ОС.
;// RDI=vector. Статус 128+vector сможет получить родитель через SYS_WAIT.
function exception_terminate_user
  push rbx
  sub rsp, 8
  mov ebx, edi
  lea rdi, [exception_user_text]
  call print_string
  mov edi, [current_task]
  call print_udec64
  lea rdi, [exception_user_vector]
  call print_string
  mov edi, ebx
  call print_hex64
  mov edi, PRINT.newline
  call print_char
  lea edi, [ebx+128]
  call task_mark_exit
  add rsp, 8
  pop rbx
endf
