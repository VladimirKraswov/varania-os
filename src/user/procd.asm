format ELF64 executable 3
entry start
include "abi.inc"

;// Первый user-процесс — менеджер процессов, а не часть ядра. Он переводит
;// формат ELF64 и архив initramfs в низкоуровневые операции микроядра:
;// create space → allocate/fill/map frames → create/start thread.

ROOT_CAP    = 1
CONTROL_EP  = 2
BOOTFS_CAP  = 3
IRQ1_CAP    = 4
IO_CAP      = 5
VGA_CAP     = 6
PCI_IO_CAP  = 7
DMA_POOL_CAP = 8

ELF_HEADER_SIZE = 64
ELF_PH_SIZE     = 56
ELF_PT_LOAD     = 1
ELF_PF_X        = 1
ELF_PF_W        = 2
ELF_PF_R        = 4

segment readable executable
start:
  log start_text, start_text.size
  mov eax, SYS_BOOTFS_INFO
  mov edi, BOOTFS_CAP
  syscall
  test rax, rax
  js fatal
  mov [bootfs_base], rax
  mov [bootfs_size], rdx

  ;// До запуска init находим NVMe PCI function и заключаем её BAR0 в
  ;// capability. Драйвер получит только MMIO range и DMA pool, но не весь PCI
  ;// configuration space. Такая точечная policy пока живёт в procd; позже её вынесет devmgr.
  call pci_prepare_nvme
  test rax, rax
  js fatal
  mov [nvme_mmio_cap], rax

  ;// Bootstrap policy: единственный особый запрос procd — запустить init и
  ;// передать ему endpoint самого procd как handle 2.
  lea rdi, [init_name]
  mov esi, init_name.size
  call bootfs_find
  test rax, rax
  jz fatal
  mov rdi, rax
  mov rsi, rdx
  mov edx, CONTROL_EP
  mov ecx, CAP_SEND
  xor r8d, r8d
  xor r9d, r9d
  mov qword [policy_extra3], 0
  mov qword [policy_extra3_rights], 0
  call load_program
  test rax, rax
  js fatal
  mov rdi, rax
  call close_handle
  mov rdi, rdx
  call close_handle

  log ready_text, ready_text.size
.serve:
  ipc_receive CONTROL_EP, ipc_request
  test rax, rax
  jnz fatal
  cmp qword [ipc_request+IpcMessage.words], PROCD_SPAWN
  jne .bad_request

  ;// Имя занимает три оставшихся слова и обязательно содержит NUL.
  lea rdi, [ipc_request+IpcMessage.words+8]
  call bounded_name_length
  test rax, rax
  jz .bad_request
  mov r12, rax
  lea rdi, [ipc_request+IpcMessage.words+8]
  mov rsi, r12
  call bootfs_find
  test rax, rax
  jz .not_found
  mov r14, rax
  mov r15, rdx

  ;// Capability 0 — endpoint для ответа. Capability 1, если есть, — ресурс,
  ;// который init просит ослабленно передать новому процессу.
  mov r13, qword [ipc_request+IpcMessage.caps+IpcCap.handle]
  test r13, r13
  jz .bad_request
  mov qword [policy_extra3], 0
  mov qword [policy_extra3_rights], 0
  cmp r12, nvme_name.size
  jne .keyboard_policy
  lea rdi, [ipc_request+IpcMessage.words+8]
  lea rsi, [nvme_name]
  mov edx, nvme_name.size
  call bytes_equal
  test eax, eax
  jz .keyboard_policy
  ;// Handle 2 — nameserver от init, handle 3 — BAR, handle 4 — узкий DMA allocator.
  xor edx, edx
  xor ecx, ecx
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .nvme_devices
  mov rdx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rcx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.rights]
  .nvme_devices:
  mov r8, [nvme_mmio_cap]
  mov r9d, CAP_MAP+CAP_READ+CAP_WRITE
  mov qword [policy_extra3], DMA_POOL_CAP
  mov qword [policy_extra3_rights], CAP_CREATE
  jmp .load_requested

  .keyboard_policy:
  cmp r12, keyboard_name.size
  jne .terminal_policy
  lea rdi, [ipc_request+IpcMessage.words+8]
  lea rsi, [keyboard_name]
  mov edx, keyboard_name.size
  call bytes_equal
  test eax, eax
  jz .terminal_policy
  ;// Первый grant приходит от init (nameserver), ещё два задаёт policy:
  ;// IRQ и минимальный диапазон портов PS/2.
  xor edx, edx
  xor ecx, ecx
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .keyboard_devices
  mov rdx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rcx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.rights]
  .keyboard_devices:
  mov r8d, IRQ1_CAP
  mov r9d, CAP_WAIT
  mov qword [policy_extra3], IO_CAP
  mov qword [policy_extra3_rights], CAP_READ
  jmp .load_requested

  .terminal_policy:
  cmp r12, terminal_name.size
  jne .vafs_policy
  lea rdi, [ipc_request+IpcMessage.words+8]
  lea rsi, [terminal_name]
  mov edx, terminal_name.size
  call bytes_equal
  test eax, eax
  jz .shared_policy
  xor edx, edx
  xor ecx, ecx
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .terminal_mmio
  mov rdx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rcx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.rights]
  .terminal_mmio:
  mov r8d, VGA_CAP
  mov r9d, CAP_MAP+CAP_READ+CAP_WRITE
  jmp .load_requested

  .vafs_policy:
  cmp r12, vafs_name.size
  jne .shared_policy
  lea rdi, [ipc_request+IpcMessage.words+8]
  lea rsi, [vafs_name]
  mov edx, vafs_name.size
  call bytes_equal
  test eax, eax
  jz .shared_policy
  ;// VFS получает nameserver как handle 2 и только CREATE-право системной
  ;// capability как handle 3: этого достаточно для per-client shared windows.
  xor edx, edx
  xor ecx, ecx
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .vafs_root
  mov rdx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rcx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.rights]
  .vafs_root:
  mov r8d, ROOT_CAP
  mov r9d, CAP_CREATE
  jmp .load_requested

  .shared_policy:
  ;// Создавать shared objects может только выбранный bootstrap-политикой
  ;// процесс. Receiver получает уже ослабленную capability через IPC.
  cmp r12, shm_sender_name.size
  jne .ordinary_caps
  lea rdi, [ipc_request+IpcMessage.words+8]
  lea rsi, [shm_sender_name]
  mov edx, shm_sender_name.size
  call bytes_equal
  test eax, eax
  jz .ordinary_caps
  xor edx, edx
  xor ecx, ecx
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .shared_root
  mov rdx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rcx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.rights]
  .shared_root:
  mov r8d, ROOT_CAP
  mov r9d, CAP_CREATE
  jmp .load_requested

  .ordinary_caps:
  xor edx, edx
  xor ecx, ecx
  xor r8d, r8d
  xor r9d, r9d
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .load_requested
  mov rdx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rcx, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.rights]

  .load_requested:
  mov rdi, r14
  mov rsi, r15
  call load_program
  mov qword [response+IpcMessage.words], rax
  test rax, rax
  js .reply_without_caps
  mov qword [response+IpcMessage.words], 0
  mov qword [response+IpcMessage.cap_count], 2
  mov qword [response+IpcMessage.caps+IpcCap.handle], rax
  mov rax, CAP_WAIT+CAP_CONTROL+CAP_MOVE
  mov qword [response+IpcMessage.caps+IpcCap.rights], rax
  mov qword [response+IpcMessage.caps+IpcCap.bytes+IpcCap.handle], rdx
  mov rax, CAP_SEND+CAP_MOVE
  mov qword [response+IpcMessage.caps+IpcCap.bytes+IpcCap.rights], rax
  jmp .reply

  .not_found:
  mov r13, qword [ipc_request+IpcMessage.caps+IpcCap.handle]
  mov qword [response+IpcMessage.words], -2
  jmp .reply_without_caps
  .bad_request:
  mov r13, qword [ipc_request+IpcMessage.caps+IpcCap.handle]
  mov qword [response+IpcMessage.words], -22
  .reply_without_caps:
  mov qword [response+IpcMessage.cap_count], 0
  .reply:
  mov eax, SYS_IPC_SEND
  mov rdi, r13
  lea rsi, [response]
  syscall
  test rax, rax
  jnz fatal

  ;// Полученные reply/extra handles нужны только на время одного запроса.
  mov rdi, r13
  call close_handle
  cmp qword [ipc_request+IpcMessage.cap_count], 2
  jb .clear_messages
  mov rdi, qword [ipc_request+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  call close_handle
  .clear_messages:
  lea rdi, [ipc_request]
  mov ecx, IpcMessage.bytes*2
  call zero_bytes
  jmp .serve

fatal:
  log fatal_text, fatal_text.size
  exit_process 1

;// Найти запись initramfs. RDI=name, RSI=len. RAX=data, RDX=size или RAX=0.
bootfs_find:
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov rbx, [bootfs_base]
  mov ecx, [rbx+12]                ;// entry_count
  lea r14, [rbx+24]
.entry:
  test ecx, ecx
  jz .missing
  xor eax, eax
.compare:
  cmp rax, r13
  je .name_end
  mov dl, [r12+rax]
  cmp dl, [r14+rax]
  jne .next
  inc rax
  jmp .compare
.name_end:
  cmp byte [r14+rax], 0
  jne .next
  mov eax, [r14+32]
  mov edx, [r14+36]
  mov r8, rax
  add r8, rdx
  jc .missing
  cmp r8, [bootfs_size]
  ja .missing
  add rax, rbx
  jmp .done
.next:
  add r14, 48
  dec ecx
  jmp .entry
.missing:
  xor eax, eax
  xor edx, edx
.done:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=24-byte name buffer. RAX=len (1..23) или 0.
bounded_name_length:
  xor eax, eax
.next:
  cmp eax, 24
  jae .invalid
  cmp byte [rdi+rax], 0
  je .end
  inc eax
  jmp .next
.end:
  test eax, eax
  jz .invalid
  ret
.invalid:
  xor eax, eax
  ret

;// RDI=left, RSI=right, RDX=bytes. RAX=1/0.
bytes_equal:
  xor eax, eax
.byte:
  test rdx, rdx
  jz .yes
  mov cl, [rdi+rax]
  cmp cl, [rsi+rax]
  jne .no
  inc rax
  dec rdx
  jmp .byte
.yes:
  mov eax, 1
  ret
.no:
  xor eax, eax
  ret

;// Записать PCI CONFIG_ADDRESS и прочитать CONFIG_DATA.
;// EDI=адрес mechanism #1, RAX=dword/error.
pci_read32:
  push rdi
  mov edx, edi
  mov eax, SYS_IO_WRITE32
  mov edi, PCI_IO_CAP
  xor esi, esi
  syscall
  pop rdi
  test rax, rax
  js .done
  mov eax, SYS_IO_READ32
  mov edi, PCI_IO_CAP
  mov esi, 4
  syscall
.done:
  ret

;// EDI=адрес mechanism #1, ESI=value. RAX=0/error.
pci_write32:
  push rbx
  mov ebx, edi
  mov r10d, esi
  mov eax, SYS_IO_WRITE32
  mov edi, PCI_IO_CAP
  xor esi, esi
  mov edx, ebx
  syscall
  test rax, rax
  js .done
  mov eax, SYS_IO_WRITE32
  mov edi, PCI_IO_CAP
  mov esi, 4
  mov edx, r10d
  syscall
.done:
  pop rbx
  ret

;// Найти class=01h, subclass=08h, prog-if=02h; включить memory/bus master,
;// опросить размер 64-битного BAR0 и создать MMIO capability.
;// RAX=handle/error.
pci_prepare_nvme:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  xor r12d, r12d                  ;// bus
.bus:
  xor r13d, r13d                  ;// device
.device:
  xor r14d, r14d                  ;// function
.function:
  mov edi, 0x80000000
  mov eax, r12d
  shl eax, 16
  or edi, eax
  mov eax, r13d
  shl eax, 11
  or edi, eax
  mov eax, r14d
  shl eax, 8
  or edi, eax
  mov r15d, edi                   ;// config base
  call pci_read32
  test rax, rax
  js .error
  cmp ax, 0xFFFF
  je .next_function
  mov edi, r15d
  or edi, 8
  call pci_read32
  test rax, rax
  js .error
  mov edx, eax
  shr edx, 8
  and edx, 0xFFFFFF
  cmp edx, 0x010802               ;// class/subclass/programming interface
  je .found
.next_function:
  inc r14d
  cmp r14d, 8
  jb .function
  inc r13d
  cmp r13d, 32
  jb .device
  inc r12d
  cmp r12d, 256
  jb .bus
  mov rax, -2
  jmp .done

.found:
  ;// На время size probe запрещаем memory decoding.
  mov edi, r15d
  or edi, 4
  call pci_read32
  test rax, rax
  js .error
  mov [pci_command], eax
  mov esi, eax
  and esi, 0xFFFF
  and esi, not 2
  mov edi, r15d
  or edi, 4
  call pci_write32
  test rax, rax
  js .error

  mov edi, r15d
  or edi, 0x10
  call pci_read32
  test rax, rax
  js .restore_error
  mov [pci_bar_low], eax
  mov edx, eax
  and edx, 7
  cmp edx, 4                       ;// memory BAR, 64-bit
  jne .restore_invalid
  mov edi, r15d
  or edi, 0x14
  call pci_read32
  test rax, rax
  js .restore_error
  mov [pci_bar_high], eax

  mov edi, r15d
  or edi, 0x10
  mov esi, -1
  call pci_write32
  test rax, rax
  js .restore_error
  mov edi, r15d
  or edi, 0x14
  mov esi, -1
  call pci_write32
  test rax, rax
  js .restore_bar_error
  mov edi, r15d
  or edi, 0x10
  call pci_read32
  mov [pci_mask_low], eax
  mov edi, r15d
  or edi, 0x14
  call pci_read32
  mov [pci_mask_high], eax

  ;// Всегда возвращаем BAR до повторного включения device.
  mov edi, r15d
  or edi, 0x10
  mov esi, [pci_bar_low]
  call pci_write32
  mov edi, r15d
  or edi, 0x14
  mov esi, [pci_bar_high]
  call pci_write32
  mov edi, r15d
  or edi, 4
  mov esi, [pci_command]
  and esi, 0xFFFF
  or esi, 6                       ;// memory space + bus master
  call pci_write32
  test rax, rax
  js .error

  mov r12d, [pci_bar_high]
  shl r12, 32
  mov eax, [pci_bar_low]
  and eax, 0xFFFFFFF0
  or r12, rax                     ;// physical base
  mov r13d, [pci_mask_high]
  shl r13, 32
  mov eax, [pci_mask_low]
  and eax, 0xFFFFFFF0
  or r13, rax
  not r13
  inc r13                         ;// BAR bytes
  test r13, r13
  jz .invalid
  add r13, PAGE_SIZE-1
  jc .invalid
  shr r13, 12                    ;// pages
  mov eax, SYS_MMIO_CREATE
  mov edi, ROOT_CAP
  mov rsi, r12
  mov rdx, r13
  syscall
  jmp .done

.restore_bar_error:
  mov edi, r15d
  or edi, 0x10
  mov esi, [pci_bar_low]
  call pci_write32
.restore_error:
  mov edi, r15d
  or edi, 4
  mov esi, [pci_command]
  and esi, 0xFFFF
  call pci_write32
.error:
  mov rax, -5
  jmp .done
.restore_invalid:
  mov edi, r15d
  or edi, 4
  mov esi, [pci_command]
  and esi, 0xFFFF
  call pci_write32
.invalid:
  mov rax, -22
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret
;// Обнулить ECX bytes по RDI.
zero_bytes:
  xor eax, eax
  rep stosb
  ret

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
.done:
  ret

;// Загрузить ELF64 в новый процесс.
;// RDI=image, RSI=size; (RDX,RCX) и (R8,R9) — дополнительные grants.
;// RAX=process cap, RDX=child endpoint cap; RAX<0 при ошибке.
load_program:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov [load_image], rdi
  mov [load_size], rsi
  mov [load_extra1], rdx
  mov [load_extra1_rights], rcx
  mov [load_extra2], r8
  mov [load_extra2_rights], r9
  mov rax, [policy_extra3]
  mov [load_extra3], rax
  mov rax, [policy_extra3_rights]
  mov [load_extra3_rights], rax
  mov qword [load_space], 0
  mov qword [load_endpoint], 0
  mov qword [load_process], 0

  call validate_elf
  test rax, rax
  jz .invalid

  mov eax, SYS_SPACE_CREATE
  mov edi, ROOT_CAP
  syscall
  test rax, rax
  js .return_error
  mov [load_space], rax
  mov eax, SYS_ENDPOINT_CREATE
  mov edi, ROOT_CAP
  syscall
  test rax, rax
  js .cleanup
  mov [load_endpoint], rax

  mov rbx, [load_image]
  movzx r12d, word [rbx+56]
  mov r13, [rbx+32]
  add r13, rbx
.segment:
  cmp dword [r13], ELF_PT_LOAD
  jne .next_segment
  cmp qword [r13+40], 0
  je .next_segment
  mov [load_ph], r13
  call map_segment
  test rax, rax
  js .cleanup
.next_segment:
  add r13, ELF_PH_SIZE
  dec r12d
  jnz .segment

  ;// Первая stack page. Последующие страницы добавляет kernel #PF handler.
  mov eax, SYS_FRAME_ALLOC
  mov edi, ROOT_CAP
  syscall
  test rax, rax
  js .cleanup
  mov r12, rax
  mov eax, SYS_SPACE_MAP
  mov rdi, [load_space]
  mov rsi, r12
  mov rdx, USER_STACK_TOP-PAGE_SIZE
  mov r10d, SPACE_MAP_WRITE
  syscall
  test rax, rax
  js .close_frame_cleanup

  lea rdi, [thread_config]
  mov ecx, ThreadConfig.bytes
  call zero_bytes
  mov rbx, [load_image]
  mov rax, [rbx+24]
  mov qword [thread_config+ThreadConfig.entry], rax
  mov rax, USER_STACK_TOP
  mov qword [thread_config+ThreadConfig.stack_top], rax
  sub rax, PAGE_SIZE
  mov qword [thread_config+ThreadConfig.stack_low], rax
  mov rax, USER_STACK_LIMIT
  mov qword [thread_config+ThreadConfig.stack_limit], rax
  mov rax, [load_max_end]
  add rax, PAGE_SIZE-1
  and rax, -PAGE_SIZE
  mov qword [thread_config+ThreadConfig.brk_base], rax

  mov qword [thread_config+ThreadConfig.grant_count], 1
  mov rax, [load_endpoint]
  mov qword [thread_config+ThreadConfig.grants+SpawnGrant.handle], rax
  mov qword [thread_config+ThreadConfig.grants+SpawnGrant.rights], CAP_SEND+CAP_RECV
  mov rax, [load_extra1]
  test rax, rax
  jz .extra2
  mov qword [thread_config+ThreadConfig.grants+SpawnGrant.bytes+SpawnGrant.handle], rax
  mov rax, [load_extra1_rights]
  mov qword [thread_config+ThreadConfig.grants+SpawnGrant.bytes+SpawnGrant.rights], rax
  inc qword [thread_config+ThreadConfig.grant_count]
.extra2:
  mov rax, [load_extra2]
  test rax, rax
  jz .extra3
  mov rcx, qword [thread_config+ThreadConfig.grant_count]
  shl rcx, 4
  mov qword [thread_config+ThreadConfig.grants+rcx+SpawnGrant.handle], rax
  mov rax, [load_extra2_rights]
  mov qword [thread_config+ThreadConfig.grants+rcx+SpawnGrant.rights], rax
  inc qword [thread_config+ThreadConfig.grant_count]

.extra3:
  mov rax, [load_extra3]
  test rax, rax
  jz .create_thread
  mov rcx, qword [thread_config+ThreadConfig.grant_count]
  shl rcx, 4
  mov qword [thread_config+ThreadConfig.grants+rcx+SpawnGrant.handle], rax
  mov rax, [load_extra3_rights]
  mov qword [thread_config+ThreadConfig.grants+rcx+SpawnGrant.rights], rax
  inc qword [thread_config+ThreadConfig.grant_count]

.create_thread:
  mov eax, SYS_THREAD_CREATE
  mov edi, ROOT_CAP
  mov rsi, [load_space]
  lea rdx, [thread_config]
  syscall
  test rax, rax
  js .cleanup
  mov [load_process], rax
  mov eax, SYS_CAP_CLOSE
  mov rdi, [load_space]
  syscall
  mov qword [load_space], 0
  mov eax, SYS_THREAD_START
  mov rdi, [load_process]
  syscall
  test rax, rax
  js .cleanup
  mov rax, [load_process]
  mov rdx, [load_endpoint]
  jmp .done

.close_frame_cleanup:
  mov rdi, r12
  call close_handle
.cleanup:
  mov r12, rax
  mov rdi, [load_space]
  call close_handle
  mov rdi, [load_endpoint]
  call close_handle
  mov rdi, [load_process]
  call close_handle
  mov rax, r12
  test rax, rax
  js .done
  mov rax, -12
  jmp .done
.invalid:
  mov rax, -22
  jmp .done
.return_error:
  ;// RAX уже содержит errno.
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Строгая проверка поддерживаемого ELF64 ET_EXEC. RAX=1/0.
validate_elf:
  mov rbx, [load_image]
  mov r12, [load_size]
  cmp r12, ELF_HEADER_SIZE
  jb .bad
  cmp dword [rbx], 0x464C457F
  jne .bad
  cmp byte [rbx+4], 2
  jne .bad
  cmp byte [rbx+5], 1
  jne .bad
  cmp word [rbx+16], 2
  jne .bad
  cmp word [rbx+18], 62
  jne .bad
  cmp word [rbx+54], ELF_PH_SIZE
  jne .bad
  movzx r13d, word [rbx+56]
  test r13d, r13d
  jz .bad
  cmp r13d, 16
  ja .bad
  mov rax, r13
  imul rax, ELF_PH_SIZE
  add rax, [rbx+32]
  jc .bad
  cmp rax, r12
  ja .bad
  mov r14, [rbx+32]
  add r14, rbx
  mov qword [load_max_end], 0
  xor r15d, r15d                 ;// entry найден в executable segment
.ph:
  cmp dword [r14], ELF_PT_LOAD
  je .load
  cmp dword [r14], 0
  jne .bad
  jmp .next
.load:
  mov rax, [r14+40]
  test rax, rax
  jz .next
  cmp [r14+32], rax
  ja .bad
  mov rdx, [r14+8]
  add rdx, [r14+32]
  jc .bad
  cmp rdx, r12
  ja .bad
  mov rdx, [r14+16]
  cmp rdx, 0x10000
  jb .bad
  add rax, rdx
  jc .bad
  cmp rax, 0x40000000
  ja .bad
  mov rcx, [r14+8]
  xor rcx, rdx
  test rcx, PAGE_SIZE-1
  jnz .bad
  mov ecx, [r14+4]
  test ecx, ELF_PF_R
  jz .bad
  mov edx, ecx
  and edx, ELF_PF_X+ELF_PF_W
  cmp edx, ELF_PF_X+ELF_PF_W
  je .bad
  cmp rax, [load_max_end]
  jbe .entry
  mov [load_max_end], rax
.entry:
  test ecx, ELF_PF_X
  jz .next
  mov rdx, [rbx+24]
  cmp rdx, [r14+16]
  jb .next
  cmp rdx, rax
  jae .next
  mov r15d, 1
.next:
  add r14, ELF_PH_SIZE
  dec r13d
  jnz .ph
  test r15d, r15d
  jz .bad
  cmp qword [load_max_end], 0
  je .bad
  mov eax, 1
  ret
.bad:
  xor eax, eax
  ret

;// Отобразить один PT_LOAD по одной странице.
map_segment:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov rbx, [load_ph]
  mov r12, [rbx+16]
  and r12, -PAGE_SIZE
  mov r13, [rbx+16]
  add r13, [rbx+40]
  add r13, PAGE_SIZE-1
  and r13, -PAGE_SIZE
.page:
  cmp r12, r13
  jae .ok
  mov eax, SYS_FRAME_ALLOC
  mov edi, ROOT_CAP
  syscall
  test rax, rax
  js .done
  mov r14, rax

  ;// Пересечение текущей страницы с файловой частью сегмента.
  mov r15, r12
  cmp r15, [rbx+16]
  jae .copy_start_ready
  mov r15, [rbx+16]
.copy_start_ready:
  mov rcx, r12
  add rcx, PAGE_SIZE
  mov rdx, [rbx+16]
  add rdx, [rbx+32]
  cmp rcx, rdx
  jbe .copy_end_ready
  mov rcx, rdx
.copy_end_ready:
  cmp r15, rcx
  jae .map
  mov rdx, [load_image]
  add rdx, [rbx+8]
  mov rax, r15
  sub rax, [rbx+16]
  add rdx, rax
  mov rsi, r15
  sub rsi, r12
  mov r10, rcx
  sub r10, r15
  mov eax, SYS_FRAME_WRITE
  mov rdi, r14
  syscall
  test rax, rax
  js .close_frame
.map:
  xor r10d, r10d
  test dword [rbx+4], ELF_PF_W
  jz .not_write
  or r10d, SPACE_MAP_WRITE
.not_write:
  test dword [rbx+4], ELF_PF_X
  jz .flags
  or r10d, SPACE_MAP_EXEC
.flags:
  mov eax, SYS_SPACE_MAP
  mov rdi, [load_space]
  mov rsi, r14
  mov rdx, r12
  syscall
  test rax, rax
  js .close_frame
  add r12, PAGE_SIZE
  jmp .page
.close_frame:
  mov r15, rax
  mov rdi, r14
  call close_handle
  mov rax, r15
  jmp .done
.ok:
  xor eax, eax
.done:
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

segment readable writeable
start_text db "procd: user-space ELF64 loader starting", 10
.size = $-start_text
ready_text db "procd: init started; process service ready", 10
.size = $-ready_text
fatal_text db "procd: fatal bootstrap or IPC error", 10
.size = $-fatal_text
init_name db "init.elf"
.size = $-init_name
keyboard_name db "keyboard.elf"
.size = $-keyboard_name
terminal_name db "terminal.elf"
.size = $-terminal_name
nvme_name db "nvme.elf"
.size = $-nvme_name
vafs_name db "vafs.elf"
.size = $-vafs_name
shm_sender_name db "shm_sender.elf"
.size = $-shm_sender_name

align 8
bootfs_base dq 0
bootfs_size dq 0
nvme_mmio_cap dq 0
pci_command dd 0
pci_bar_low dd 0
pci_bar_high dd 0
pci_mask_low dd 0
pci_mask_high dd 0
load_image dq 0
load_size dq 0
load_space dq 0
load_endpoint dq 0
load_process dq 0
load_extra1 dq 0
load_extra1_rights dq 0
load_extra2 dq 0
load_extra2_rights dq 0
load_extra3 dq 0
load_extra3_rights dq 0
policy_extra3 dq 0
policy_extra3_rights dq 0
load_ph dq 0
load_max_end dq 0
thread_config rb ThreadConfig.bytes
ipc_request rb IpcMessage.bytes
response rb IpcMessage.bytes
