format ELF64 executable 3
entry start
include "abi.inc"

;//////////////////////////////////////////////////////////////////////////////
;// Узкий platform service: RTC и безопасное выключение QEMU/ACPI
;//////////////////////////////////////////////////////////////////////////////
;
;// У сервиса нет CAP_SYSTEM и произвольного I/O. Procd выдаёт ровно CMOS
;// 0x70..0x71 и ACPI sleep control 0x604..0x607. GUI видит только IPC ABI.

SELF_EP       = 1
NAMESERVER_EP = 2
RTC_CAP       = 3
ACPI_CAP      = 4

segment readable executable
start:
  call lookup_gui
  test rax, rax
  js failed
  mov [gui_endpoint], rax
  call register_service
  test rax, rax
  jnz failed
  call publish_time
  log ready_text, ready_text.size
.serve:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz failed
  mov rax, qword [message+IpcMessage.words]
  cmp rax, PLATFORM_POWER_OFF
  je .power_off
  cmp rax, PLATFORM_POLL_TIME
  jne .clear
  call publish_time
  jmp .clear
.power_off:
  log shutdown_text, shutdown_text.size
  mov eax, SYS_IO_WRITE32
  mov edi, ACPI_CAP
  xor esi, esi
  mov edx, 0x2000                ;// SLP_EN for QEMU PIIX4 PM
  syscall
.clear:
  call close_received_caps
  jmp .serve

failed:
  log failed_text, failed_text.size
  exit_process 1

publish_time:
  call read_clock
  mov ebx, eax                   ;// low8=hour, next8=minute
  lea rdi, [out_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [out_message+IpcMessage.words], GUI_CLOCK_UPDATE
  mov qword [out_message+IpcMessage.words+8], rbx
  cmp byte [endpoint_announced], 0
  jne .retry
  mov byte [endpoint_announced], 1
  mov qword [out_message+IpcMessage.cap_count], 1
  mov qword [out_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [out_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
.retry:
  mov eax, SYS_IPC_SEND
  mov rdi, [gui_endpoint]
  lea rsi, [out_message]
  syscall
  cmp rax, -11
  jne .done
  system_call SYS_YIELD
  jmp .retry
.done:
  ret

;// Вернуть AL=hour, AH=minute. CMOS может хранить BCD и 12-hour time;
;// преобразование выполняет драйвер, compositor получает нормальные числа.
read_clock:
  mov dl, 0x0B
  call rtc_read
  mov bl, al                    ;// status B
  mov dl, 0x04
  call rtc_read
  mov bh, al                    ;// hours + optional PM bit
  mov dl, 0x02
  call rtc_read
  mov cl, al                    ;// minutes
  test bl, 0x04                 ;// binary mode
  jnz .hour_mode
  mov al, cl
  call bcd_to_binary
  mov cl, al
  mov al, bh
  and al, 0x7F
  call bcd_to_binary
  and bh, 0x80
  or bh, al
.hour_mode:
  test bl, 0x02                 ;// already 24-hour
  jnz .pack
  mov al, bh
  and al, 0x7F
  cmp al, 12
  jne .not_twelve
  xor al, al
.not_twelve:
  test bh, 0x80                 ;// PM
  jz .store_hour
  add al, 12
.store_hour:
  mov bh, al
.pack:
  movzx eax, cl
  shl eax, 8
  mov al, bh
  ret

rtc_read:
  mov eax, SYS_IO_WRITE8
  mov edi, RTC_CAP
  xor esi, esi
  syscall
  mov eax, SYS_IO_READ8
  mov edi, RTC_CAP
  mov esi, 1
  syscall
  ret

bcd_to_binary:
  movzx edx, al
  mov eax, edx
  and eax, 0x0F
  shr edx, 4
  and edx, 0x0F
  imul edx, 10
  add eax, edx
  ret

register_service:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [message+IpcMessage.words+8], SERVICE_PLATFORM
  mov qword [message+IpcMessage.words+16], 1
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
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

close_received_caps:
  mov rcx, qword [message+IpcMessage.cap_count]
  xor ebx, ebx
.next:
  cmp rbx, rcx
  jae .done
  mov rax, rbx
  shl rax, 4
  mov rdi, qword [message+IpcMessage.caps+rax+IpcCap.handle]
  push rcx
  close_cap rdi
  pop rcx
  inc rbx
  jmp .next
.done:
  ret

segment readable writeable
ready_text db "platform: RTC and ACPI service ready", 10
.size = $-ready_text
shutdown_text db "VARANIA:GUI_POWER_OFF", 10
.size = $-shutdown_text
failed_text db "platform: isolated platform service failure", 10
.size = $-failed_text
align 8
gui_endpoint dq 0
endpoint_announced db 0
align 8
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
out_message rb IpcMessage.bytes
