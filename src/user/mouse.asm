format ELF64 executable 3
entry start
include "abi.inc"

;//////////////////////////////////////////////////////////////////////////////
;// PS/2 mouse driver — отдельный ring-3 процесс
;//////////////////////////////////////////////////////////////////////////////
;
;// Ядро выдаёт только IRQ12 и пять портов контроллера 8042. Драйвер собирает
;// трёхбайтовые пакеты, нормализует смещение и отправляет pointer events GUI.

SELF_EP       = 1
NAMESERVER_EP = 2
IRQ12_CAP     = 3
PS2_IO_CAP    = 4

segment readable executable
start:
  call lookup_gui
  test rax, rax
  js failed
  mov [gui_endpoint], rax
  call ps2_mouse_initialize
  test rax, rax
  jnz failed
  log ready_text, ready_text.size

.wait_input:
  ;// QEMU headless не всегда поднимает IRQ12 после VBE mode switch. До общего
  ;// wait-set (IRQ + timeout) используем cooperative fallback: читаем только
  ;// AUX bytes и немедленно уступаем CPU, если пакет ещё не готов.
  mov eax, SYS_IO_READ8
  mov edi, PS2_IO_CAP
  mov esi, 4                    ;// status port 0x64
  syscall
  test al, 1
  jz .yield
  test al, 0x20
  jz .yield
  mov eax, SYS_IO_READ8
  mov edi, PS2_IO_CAP
  xor esi, esi                  ;// data port 0x60
  syscall
  mov rcx, [packet_index]
  test rcx, rcx
  jnz .store
  test al, 0x08                 ;// первый byte всегда содержит sync bit
  jz .wait_input
.store:
  mov [packet+rcx], al
  inc rcx
  cmp rcx, 3
  jb .remember
  mov qword [packet_index], 0
  call send_packet
  jmp .wait_input
.remember:
  mov [packet_index], rcx
  jmp .wait_input
.yield:
  system_call SYS_YIELD
  jmp .wait_input

failed:
  log failed_text, failed_text.size
  exit_process 1

;// Преобразовать signed PS/2 delta в GUI coordinate system: Y вниз.
send_packet:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], GUI_POINTER
  movsx rax, byte [packet+1]
  mov qword [message+IpcMessage.words+8], rax
  movsx rax, byte [packet+2]
  neg rax
  mov qword [message+IpcMessage.words+16], rax
  movzx eax, byte [packet]
  and eax, 7
  mov qword [message+IpcMessage.words+24], rax
.retry:
  mov eax, SYS_IPC_SEND
  mov rdi, [gui_endpoint]
  lea rsi, [message]
  syscall
  cmp rax, -11
  jne .done
  system_call SYS_YIELD
  jmp .retry
.done:
  ret

;// Включить auxiliary port, IRQ12 и streaming packets. Все ожидания имеют
;// конечный budget: неисправная мышь завершает только драйвер, не всю ОС.
ps2_mouse_initialize:
  mov dl, 0xA8
  call controller_command
  test rax, rax
  jnz .done
  mov dl, 0x20
  call controller_command
  call wait_output
  test rax, rax
  jnz .done
  call read_data
  or al, 0x02                   ;// enable IRQ12
  and al, 0xDF                  ;// enable auxiliary clock
  mov bl, al
  mov dl, 0x60
  call controller_command
  mov dl, bl
  call write_data
  mov dl, 0xF6                  ;// defaults
  call mouse_command
  test rax, rax
  jnz .done
  mov dl, 0xF4                  ;// enable streaming
  call mouse_command
.done:
  ret

mouse_command:
  push rdx
  mov dl, 0xD4
  call controller_command
  pop rdx
  test rax, rax
  jnz .done
  call write_data
  call wait_output
  test rax, rax
  jnz .done
  call read_data
  cmp al, 0xFA                  ;// ACK
  je .ok
  mov rax, -5
  ret
.ok:
  xor eax, eax
.done:
  ret

controller_command:
  call wait_input
  test rax, rax
  jnz .done
  mov eax, SYS_IO_WRITE8
  mov edi, PS2_IO_CAP
  mov esi, 4
  syscall
.done:
  ret

write_data:
  call wait_input
  test rax, rax
  jnz .done
  mov eax, SYS_IO_WRITE8
  mov edi, PS2_IO_CAP
  xor esi, esi
  syscall
.done:
  ret

read_data:
  mov eax, SYS_IO_READ8
  mov edi, PS2_IO_CAP
  xor esi, esi
  syscall
  ret

wait_input:
  mov ecx, 100000
.poll:
  mov eax, SYS_IO_READ8
  mov edi, PS2_IO_CAP
  mov esi, 4
  syscall
  test al, 2
  jz .ready
  loop .poll
  mov rax, -5
  ret
.ready:
  xor eax, eax
  ret

wait_output:
  mov ecx, 100000
.poll:
  mov eax, SYS_IO_READ8
  mov edi, PS2_IO_CAP
  mov esi, 4
  syscall
  test al, 1
  jnz .ready
  loop .poll
  mov rax, -5
  ret
.ready:
  xor eax, eax
  ret

lookup_gui:
.retry:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes*2
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [message+IpcMessage.words+8], SERVICE_GUI
  mov qword [message+IpcMessage.words+16], 1
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, reply
  test rax, rax
  jnz .done
  cmp qword [reply+IpcMessage.words], 0
  je .found
  system_call SYS_YIELD
  jmp .retry
.found:
  cmp qword [reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [reply+IpcMessage.caps+IpcCap.handle]
  ret
.invalid:
  mov rax, -22
.done:
  ret

segment readable writeable
ready_text db "mouse-driver: PS/2 IRQ12 streaming ready", 10
.size = $-ready_text
failed_text db "mouse-driver: isolated PS/2 initialization failure", 10
.size = $-failed_text
align 8
gui_endpoint dq 0
packet_index dq 0
packet rb 3
align 8
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
