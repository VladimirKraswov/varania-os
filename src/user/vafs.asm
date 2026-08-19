format ELF64 executable 3
entry start
include "abi.inc"

;// VaraniaFS — файловый сервер в пользовательском пространстве.
;//
;// Граница микроядра остаётся строгой:
;//   shell --FS RPC--> vafs --block RPC--> nvme --DMA--> SSD image
;//
;// Ядро не разбирает пути, B+tree и superblock. Процесс vafs получает только
;// SEND-capability nameserver; capability NVMe buffer приходит от block service.
;// Все структуры ниже совпадают с docs/VAFS.md и tools/vafs/vafs.py.

SELF_EP       = 1
NAMESERVER_EP = 2
ROOT_CREATE_CAP = 3

VAFS_IO_VA = 0x0000000062000000

MAX_ENTRIES   = 512
MAX_PATH      = 1024
MAX_NAME      = 47              ;// 48 IPC bytes, последний байт нужен для NUL
SESSION_MAX   = 4
FS_BUFFER_PAGES = 64
FS_BUFFER_BYTES = FS_BUFFER_PAGES*PAGE_SIZE
FS_BUFFER_BASE  = 0x0000000063000000
RECORD_SLOT   = 4096            ;// сохраняем любую допустимую leaf record как есть
DESC_SLOT     = 1040            ;// len:u16, block:u64, key[1024]
NODE_HEADER   = 64
ENTRY_HEADER  = 40
EXTENT_BYTES  = 24

VAFS_REQUIRED_FEATURES = 0x0F   ;// COW | CRC32C | case-sensitive | no-permissions

ERR_NOT_FOUND = -2
ERR_IO        = -5
ERR_EXISTS    = -17
ERR_NOT_DIR   = -20
ERR_INVALID   = -22
ERR_NO_SPACE  = -28
ERR_NOT_IMPL  = -38
ERR_CORRUPT   = -74
ERR_NAME_LONG = -36
IPC_WOULD_BLOCK = -11

segment readable executable
start:
  call allocate_working_memory
  test rax, rax
  jnz fatal
  mov edi, SERVICE_BLOCK
  call lookup_service
  test rax, rax
  js fatal
  mov [block_endpoint], rax

  call attach_block_device
  test rax, rax
  jnz fatal
  call mount_volume
  test rax, rax
  jnz corrupt
  call register_filesystem
  test rax, rax
  jnz fatal

  log ready_text, ready_text.size
  log mount_marker, mount_marker.size

.serve:
  lea rdi, [request]
  mov ecx, IpcMessage.bytes*2
  call zero_bytes
  ipc_receive SELF_EP, request
  test rax, rax
  jnz fatal
  call dispatch_request
  jmp .serve

corrupt:
  log corrupt_text, corrupt_text.size
  exit_process 2
fatal:
  log fatal_text, fatal_text.size
  exit_process 1

;// Большие таблицы — runtime heap, а не мегабайты нулей в bootstrap ELF.
;// brk выделяет 2 MiB для raw catalog records и по 520 KiB для двух уровней
;// descriptors. Фиксированный максимум делает расход памяти очевидным.
allocate_working_memory:
  xor edi, edi
  system_call SYS_BRK
  test rax, rax
  js .done
  add rax, PAGE_SIZE-1
  and rax, -PAGE_SIZE
  mov [entry_records_base], rax
  add rax, MAX_ENTRIES*RECORD_SLOT
  mov [descriptors_a_base], rax
  add rax, MAX_ENTRIES*DESC_SLOT
  mov [descriptors_b_base], rax
  add rax, MAX_ENTRIES*DESC_SLOT
  add rax, PAGE_SIZE-1
  and rax, -PAGE_SIZE
  mov rdi, rax
  system_call SYS_BRK
  test rax, rax
  js .done
  xor eax, eax
.done:
  ret

;// Найти сервис через nameserver. EDI=service, RAX=SEND handle/error.
lookup_service:
  push r12
  mov r12d, edi
.retry:
  call prepare_request
  mov qword [request+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [request+IpcMessage.words+8], r12
  call add_reply_cap
  mov edi, NAMESERVER_EP
  lea rsi, [request]
  call send_retry
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, reply
  test rax, rax
  jnz .done
  cmp qword [reply+IpcMessage.words], 0
  jne .wait
  cmp qword [reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [reply+IpcMessage.caps+IpcCap.handle]
  jmp .done
.wait:
  system_call SYS_YIELD
  jmp .retry
.invalid:
  mov rax, ERR_INVALID
.done:
  pop r12
  ret

;// Получить геометрию namespace и общий DMA buffer block-драйвера.
attach_block_device:
  call prepare_request
  mov qword [request+IpcMessage.words], BLOCK_ATTACH
  call add_reply_cap
  call block_rpc
  test rax, rax
  jnz .done
  cmp qword [reply+IpcMessage.cap_count], 1
  jne .invalid
  cmp qword [reply+IpcMessage.words+16], PAGE_SIZE
  jne .invalid
  cmp qword [reply+IpcMessage.words+24], PAGE_SIZE
  jb .invalid
  mov rax, qword [reply+IpcMessage.words+8]
  cmp rax, 4
  jb .invalid
  mov [volume_blocks], rax
  mov rdi, qword [reply+IpcMessage.caps+IpcCap.handle]
  mov [io_buffer_cap], rdi
  mov eax, SYS_SHARED_MAP
  mov rsi, VAFS_IO_VA
  mov edx, SPACE_MAP_WRITE
  syscall
  ret
.invalid:
  mov rax, ERR_INVALID
.done:
  ret

register_filesystem:
  call prepare_request
  mov qword [request+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [request+IpcMessage.words+8], SERVICE_FILESYSTEM
  mov qword [request+IpcMessage.cap_count], 1
  mov qword [request+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [request+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov edi, NAMESERVER_EP
  lea rsi, [request]
  call send_retry
  ret

;// BLOCK_READ одного 4-KiB блока в VAFS_IO_VA. RDI=block.
block_read:
  push r12
  mov r12, rdi
  call prepare_request
  mov qword [request+IpcMessage.words], BLOCK_READ
  mov qword [request+IpcMessage.words+8], r12
  mov qword [request+IpcMessage.words+16], 1
  mov qword [request+IpcMessage.words+24], 0
  call add_reply_cap
  call block_rpc
  pop r12
  ret

;// BLOCK_WRITE одного блока из VAFS_IO_VA. RDI=block.
block_write:
  push r12
  mov r12, rdi
  call prepare_request
  mov qword [request+IpcMessage.words], BLOCK_WRITE
  mov qword [request+IpcMessage.words+8], r12
  mov qword [request+IpcMessage.words+16], 1
  mov qword [request+IpcMessage.words+24], 0
  call add_reply_cap
  call block_rpc
  pop r12
  ret

block_flush:
  call prepare_request
  mov qword [request+IpcMessage.words], BLOCK_FLUSH
  call add_reply_cap
  jmp block_rpc

;// Отправить request block-сервису и вернуть reply.words[0].
block_rpc:
  mov rdi, [block_endpoint]
  lea rsi, [request]
  call send_retry
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, reply
  test rax, rax
  jnz .done
  mov rax, qword [reply+IpcMessage.words]
.done:
  ret

prepare_request:
  lea rdi, [request]
  mov ecx, IpcMessage.bytes*2
  call zero_bytes
  ret

add_reply_cap:
  mov qword [request+IpcMessage.cap_count], 1
  mov qword [request+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [request+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ret

;// ------------------------------------------------------------
;// Mount и строгая проверка metadata
;// ------------------------------------------------------------

mount_volume:
  mov byte [primary_valid], 0
  mov byte [mirror_valid], 0

  xor edi, edi
  call block_read
  test rax, rax
  jnz .primary_done
  mov rsi, VAFS_IO_VA
  lea rdi, [primary_super]
  call copy_page
  lea rdi, [primary_super]
  call validate_superblock
  test rax, rax
  jnz .primary_done
  mov byte [primary_valid], 1
.primary_done:
  mov rdi, [volume_blocks]
  dec rdi
  call block_read
  test rax, rax
  jnz .mirror_done
  mov rsi, VAFS_IO_VA
  lea rdi, [mirror_super]
  call copy_page
  lea rdi, [mirror_super]
  call validate_superblock
  test rax, rax
  jnz .mirror_done
  mov byte [mirror_valid], 1
.mirror_done:
  cmp byte [primary_valid], 0
  jne .have_primary
  cmp byte [mirror_valid], 0
  je .corrupt
  lea rsi, [mirror_super]
  mov byte [active_slot], 1
  jmp .selected
.have_primary:
  lea rsi, [primary_super]
  mov byte [active_slot], 0
  cmp byte [mirror_valid], 0
  je .selected
  mov rax, qword [mirror_super+16]
  cmp rax, qword [primary_super+16]
  jbe .selected
  lea rsi, [mirror_super]
  mov byte [active_slot], 1
.selected:
  lea rdi, [active_super]
  call copy_page
  mov rax, qword [active_super+16]
  mov [generation], rax
  mov rax, qword [active_super+56]
  mov [catalog_root], rax
  mov eax, dword [active_super+64]
  mov [catalog_height], eax
  mov rax, qword [active_super+72]
  mov [next_object_id], rax
  mov rax, qword [active_super+80]
  mov [allocation_cursor], rax
  mov rax, qword [active_super+88]
  mov [root_object_id], rax
  call load_catalog
  ret
.corrupt:
  mov rax, ERR_CORRUPT
  ret

;// RDI=superblock. Проверить CRC и все поля, влияющие на безопасность адресов.
validate_superblock:
  push rbx
  push r12
  mov r12, rdi
  mov rax, 0001000053464156h      ;// little-endian "VAFS\0\0\1\0"
  cmp qword [r12], rax
  jne .bad
  cmp dword [r12+8], 1
  jne .bad
  cmp dword [r12+12], PAGE_SIZE
  jne .bad
  mov rax, [volume_blocks]
  cmp qword [r12+40], rax
  jne .bad
  mov rax, [r12+48]
  and eax, VAFS_REQUIRED_FEATURES
  cmp eax, VAFS_REQUIRED_FEATURES
  jne .bad
  mov rax, [r12+56]
  cmp rax, 1
  jb .bad
  mov rdx, [volume_blocks]
  dec rdx
  cmp rax, rdx
  jae .bad
  cmp dword [r12+64], 15
  ja .bad
  cmp dword [r12+68], 0
  jne .bad
  cmp qword [r12+72], 2
  jb .bad
  mov rcx, [r12+80]
  cmp rcx, rax
  jbe .bad
  cmp rcx, rdx
  ja .bad
  cmp qword [r12+88], 0
  je .bad
  cmp dword [r12+96], 2
  ja .bad
  cmp dword [r12+100], 1
  ja .bad
  mov ebx, [r12+104]
  mov dword [r12+104], 0
  mov rdi, r12
  mov esi, PAGE_SIZE
  call crc32c
  mov [r12+104], ebx
  cmp eax, ebx
  jne .bad
  xor eax, eax
  jmp .done
.bad:
  mov rax, ERR_CORRUPT
.done:
  pop r12
  pop rbx
  ret

;// Найти самый левый leaf, затем читать связанный список leaves.
load_catalog:
  mov qword [entry_count], 0
  mov r12, [catalog_root]
  mov r13d, [catalog_height]
.descend:
  mov rdi, r12
  call block_read
  test rax, rax
  jnz .done
  mov rdi, VAFS_IO_VA
  mov esi, r13d
  call validate_node
  test rax, rax
  jnz .done
  test r13d, r13d
  jz .leaf
  movzx eax, word [VAFS_IO_VA+NODE_HEADER]
  cmp eax, 16
  jb .corrupt
  test eax, 7
  jnz .corrupt
  mov r12, [VAFS_IO_VA+NODE_HEADER+4]
  cmp r12, 1
  jb .corrupt
  mov rax, [volume_blocks]
  dec rax
  cmp r12, rax
  jae .corrupt
  dec r13d
  jmp .descend

.leaf:
  xor r14d, r14d                 ;// защита от цикла next_leaf
.next_leaf:
  inc r14d
  cmp r14d, MAX_ENTRIES
  ja .corrupt
  movzx r15d, word [VAFS_IO_VA+6]
  mov ebx, NODE_HEADER
.record:
  test r15d, r15d
  jz .leaf_done
  mov eax, [VAFS_IO_VA+24]
  cmp ebx, eax
  jae .corrupt
  lea rdi, [VAFS_IO_VA+rbx]
  call load_leaf_record
  test rax, rax
  js .done
  add ebx, eax
  dec r15d
  jmp .record
.leaf_done:
  cmp ebx, [VAFS_IO_VA+24]
  jne .corrupt
  mov r12, [VAFS_IO_VA+16]
  test r12, r12
  jz .complete
  cmp r12, 1
  jb .corrupt
  mov rax, [volume_blocks]
  dec rax
  cmp r12, rax
  jae .corrupt
  mov rdi, r12
  call block_read
  test rax, rax
  jnz .done
  mov rdi, VAFS_IO_VA
  xor esi, esi
  call validate_node
  test rax, rax
  jnz .done
  jmp .next_leaf
.complete:
  cmp qword [entry_count], 0
  je .corrupt
  mov rax, [entry_object_ids]
  cmp rax, [root_object_id]
  jne .corrupt
  cmp byte [entry_kinds], FS_NODE_DIR
  jne .corrupt
  xor eax, eax
  ret
.corrupt:
  mov rax, ERR_CORRUPT
.done:
  ret

;// RDI=node, ESI=expected level.
validate_node:
  push rbx
  push r12
  push r13
  mov r12, rdi
  mov r13d, esi
  cmp dword [r12], 04E544256h    ;// little-endian "VBTN"
  jne .bad
  cmp word [r12+4], r13w
  jne .bad
  cmp word [r12+6], 0
  je .bad
  mov rax, [generation]
  cmp [r12+8], rax
  jne .bad
  mov eax, [r12+24]
  cmp eax, NODE_HEADER
  jbe .bad
  cmp eax, PAGE_SIZE
  ja .bad
  cmp dword [r12+32], 0
  jne .bad
  mov rdi, r12
  add rdi, 36
  mov ecx, 28
.reserved:
  cmp byte [rdi], 0
  jne .bad
  inc rdi
  dec ecx
  jnz .reserved
  mov ebx, [r12+28]
  mov dword [r12+28], 0
  mov rdi, r12
  mov esi, PAGE_SIZE
  call crc32c
  mov [r12+28], ebx
  cmp eax, ebx
  jne .bad
  xor eax, eax
  jmp .done
.bad:
  mov rax, ERR_CORRUPT
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// Загрузить одну leaf record. RDI=record, RAX=record bytes/error.
load_leaf_record:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi
  movzx ebx, word [r12]
  cmp ebx, ENTRY_HEADER
  jb .bad
  test ebx, 7
  jnz .bad
  mov rax, [entry_count]
  cmp rax, MAX_ENTRIES
  jae .full
  movzx r13d, word [r12+2]       ;// path bytes
  test r13d, r13d
  jz .bad
  cmp r13d, MAX_PATH
  ja .bad
  movzx r14d, word [r12+6]       ;// extent count
  mov eax, r14d
  imul eax, EXTENT_BYTES
  add eax, ENTRY_HEADER
  mov r15d, eax                  ;// path offset
  add eax, r13d
  cmp eax, ebx
  ja .bad
  cmp byte [r12+5], 0
  jne .bad
  cmp dword [r12+36], 0
  jne .bad
  movzx eax, byte [r12+4]
  cmp eax, FS_NODE_FILE
  je .type_ok
  cmp eax, FS_NODE_DIR
  jne .bad
.type_ok:
  cmp qword [r12+8], 0
  je .bad

  ;// Extents обязаны последовательно покрывать logical blocks файла.
  xor r10, r10
  lea rdi, [r12+ENTRY_HEADER]
  mov ecx, r14d
.extent:
  test ecx, ecx
  jz .extents_done
  cmp qword [rdi], r10
  jne .bad
  mov rax, [rdi+8]
  cmp rax, 1
  jb .bad
  mov edx, [rdi+16]
  test edx, edx
  jz .bad
  cmp dword [rdi+20], 0
  jne .bad
  add rax, rdx
  mov r9, [volume_blocks]
  dec r9
  cmp rax, r9
  ja .bad
  add r10, rdx
  add rdi, EXTENT_BYTES
  dec ecx
  jmp .extent
.extents_done:
  cmp byte [r12+4], FS_NODE_DIR
  jne .file
  cmp qword [r12+16], 0
  jne .bad
  test r14d, r14d
  jnz .bad
  cmp dword [r12+32], 0
  jne .bad
  jmp .path
.file:
  mov rax, [r12+16]
  add rax, PAGE_SIZE-1
  shr rax, 12
  cmp rax, r10
  jne .bad

.path:
  lea rdi, [r12+r15]
  mov esi, r13d
  call validate_path
  test rax, rax
  jnz .bad

  ;// Каталог отсортирован строго, object ID уникальны.
  mov r11, [entry_count]
  test r11, r11
  jz .root_path
  mov rdi, r11
  dec rdi
  call entry_path
  mov rdi, rax
  mov rsi, rdx
  lea rdx, [r12+r15]
  mov ecx, r13d
  call compare_paths
  cmp eax, 0
  jge .bad
  xor r9d, r9d
.object_unique:
  cmp r9, r11
  jae .parent
  mov rax, [r12+8]
  cmp [entry_object_ids+r9*8], rax
  je .bad
  inc r9
  jmp .object_unique
.root_path:
  cmp r13d, 1
  jne .bad
  cmp byte [r12+r15], '/'
  jne .bad
  mov rax, [root_object_id]
  cmp [r12+8], rax
  jne .bad

.parent:
  ;// Родитель уже встретился: полный путь сортируется после своего prefix.
  mov rax, [r12+8]
  mov r8, rax
  cmp r13d, 1
  je .parent_ready
  lea rdi, [r12+r15]
  mov esi, r13d
  call parent_length
  mov rsi, rax
  lea rdi, [r12+r15]
  call find_entry_by_path
  test rax, rax
  js .bad
  cmp byte [entry_kinds+rax], FS_NODE_DIR
  jne .bad
  mov r8, [entry_object_ids+rax*8]
.parent_ready:
  mov rax, [entry_count]
  mov rcx, [r12+8]
  mov [entry_object_ids+rax*8], rcx
  mov [entry_parent_ids+rax*8], r8
  mov dl, [r12+4]
  mov [entry_kinds+rax], dl
  mov [entry_path_lengths+rax*2], r13w
  mov [entry_record_sizes+rax*2], bx
  shl rax, 12
  mov rdi, [entry_records_base]
  add rdi, rax
  mov rsi, r12
  mov ecx, ebx
  rep movsb
  inc qword [entry_count]
  mov eax, ebx
  jmp .done
.full:
  mov rax, ERR_NO_SPACE
  jmp .done
.bad:
  mov rax, ERR_CORRUPT
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Проверка канонического absolute UTF-8 byte path без декодирования Unicode.
;// NUL и пустые/. /.. компоненты запрещены; байты >= 0x80 сохраняются прозрачно.
validate_path:
  cmp esi, 1
  jb .bad
  cmp byte [rdi], '/'
  jne .bad
  cmp esi, 1
  je .good
  cmp byte [rdi+rsi-1], '/'
  je .bad
  mov ecx, 1
  xor r8d, r8d                   ;// длина компонента
.byte:
  cmp ecx, esi
  jae .good
  mov al, [rdi+rcx]
  test al, al
  jz .bad
  cmp al, '/'
  je .separator
  inc r8d
  cmp r8d, 255
  ja .bad
  inc ecx
  jmp .byte
.separator:
  test r8d, r8d
  jz .bad
  cmp r8d, 1
  jne .maybe_dotdot
  cmp byte [rdi+rcx-1], '.'
  je .bad
.maybe_dotdot:
  cmp r8d, 2
  jne .next_component
  cmp byte [rdi+rcx-1], '.'
  jne .next_component
  cmp byte [rdi+rcx-2], '.'
  je .bad
.next_component:
  xor r8d, r8d
  inc ecx
  jmp .byte
.good:
  ;// Последний компонент тоже не может быть "." или "..".
  cmp r8d, 1
  jne .final_dotdot
  cmp byte [rdi+rsi-1], '.'
  je .bad
.final_dotdot:
  cmp r8d, 2
  jne .canonical
  cmp byte [rdi+rsi-1], '.'
  jne .canonical
  cmp byte [rdi+rsi-2], '.'
  je .bad
.canonical:
  xor eax, eax
  ret
.bad:
  mov rax, ERR_CORRUPT
  ret

;// ------------------------------------------------------------
;// FS protocol
;// ------------------------------------------------------------

dispatch_request:
  cmp qword [request+IpcMessage.cap_count], 1
  jne .drop
  mov r12, qword [request+IpcMessage.caps+IpcCap.handle]
  lea rdi, [reply]
  mov ecx, IpcMessage.bytes
  call zero_bytes
  mov rax, qword [request+IpcMessage.words]
  cmp rax, FS_LIST
  je .list
  cmp rax, FS_LOOKUP
  je .lookup
  cmp rax, FS_MKDIR
  je .mkdir
  cmp rax, FS_CREATE
  je .create
  cmp rax, FS_ATTACH
  je .attach
  cmp rax, FS_READ
  je .read
  cmp rax, FS_WRITE
  je .write
  cmp rax, FS_STAT
  je .stat
  cmp rax, FS_DETACH
  je .detach
  mov qword [reply+IpcMessage.words], ERR_NOT_IMPL
  jmp .send
.list:
  call handle_list
  jmp .send
.lookup:
  call handle_lookup
  jmp .send
.mkdir:
  mov edx, FS_NODE_DIR
  call handle_create
  jmp .send
.create:
  mov edx, FS_NODE_FILE
  call handle_create
  jmp .send
.attach:
  call handle_attach
  jmp .send
.read:
  call handle_read
  jmp .send
.write:
  call handle_write
  jmp .send
.stat:
  call handle_stat
  jmp .send
.detach:
  call handle_detach
.send:
  ipc_send r12d, reply
  push rax
  mov rdi, r12
  close_cap rdi
  pop rax
  ret
.drop:
  call close_request_caps
  ret

;// Создать отдельное 256-KiB окно для клиента. Владелец определяется полем
;// sender, которое ядро заполняет при IPC receive; клиент не может его подделать.
handle_attach:
  mov rdi, qword [request+IpcMessage.sender]
  call session_for_sender
  test rax, rax
  jns .reply_existing
  xor ebx, ebx
.free:
  cmp ebx, SESSION_MAX
  jae .no_space
  cmp qword [session_handles+rbx*8], 0
  je .create
  inc ebx
  jmp .free
.create:
  mov eax, SYS_SHARED_CREATE
  mov edi, ROOT_CREATE_CAP
  mov esi, FS_BUFFER_PAGES
  syscall
  test rax, rax
  js .error
  mov [session_handles+rbx*8], rax
  mov rdx, rbx
  shl rdx, 18                    ;// 256 KiB per slot
  add rdx, FS_BUFFER_BASE
  mov [session_bases+rbx*8], rdx
  mov rdi, rax
  mov rsi, rdx
  mov edx, SPACE_MAP_WRITE
  mov eax, SYS_SHARED_MAP
  syscall
  test rax, rax
  js .map_error
  mov rax, qword [request+IpcMessage.sender]
  mov [session_owners+rbx*8], rax
  mov rax, rbx
.reply_existing:
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], FS_BUFFER_BYTES
  mov qword [reply+IpcMessage.cap_count], 1
  mov rdx, [session_handles+rax*8]
  mov qword [reply+IpcMessage.caps+IpcCap.handle], rdx
  mov qword [reply+IpcMessage.caps+IpcCap.rights], CAP_MAP+CAP_READ+CAP_WRITE
  ret

.map_error:
  push rax
  mov rdi, [session_handles+rbx*8]
  close_cap rdi
  mov qword [session_handles+rbx*8], 0
  pop rax
  jmp .error
.no_space:
  mov rax, ERR_NO_SPACE
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// Освободить per-client shared window. Нормально завершающиеся short-lived
;// программы (например FASM) не должны навсегда занимать один из четырёх slots.
handle_detach:
  mov rdi, qword [request+IpcMessage.sender]
  call session_for_sender
  test rax, rax
  js .error
  mov rbx, rax
  mov rdi, [session_bases+rbx*8]
  mov eax, SYS_SHARED_UNMAP
  syscall
  test rax, rax
  js .error
  mov rdi, [session_handles+rbx*8]
  close_cap rdi
  mov qword [session_owners+rbx*8], 0
  mov qword [session_handles+rbx*8], 0
  mov qword [session_bases+rbx*8], 0
  mov qword [reply+IpcMessage.words], 0
  ret
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// STAT: words[1]=object. Ответ: status, size, type, object ID.
handle_stat:
  mov rdi, qword [request+IpcMessage.words+8]
  test rdi, rdi
  jnz .lookup
  mov rdi, [root_object_id]
.lookup:
  call object_to_index
  test rax, rax
  js .error
  mov rbx, rax
  mov rdi, rbx
  call entry_record
  mov rdx, [rax+16]
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rdx
  movzx edx, byte [entry_kinds+rbx]
  mov qword [reply+IpcMessage.words+16], rdx
  mov rdx, [entry_object_ids+rbx*8]
  mov qword [reply+IpcMessage.words+24], rdx
  ret
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// READ: object, file offset, byte count, window offset. Ответ status, bytes.
handle_read:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov rdi, qword [request+IpcMessage.sender]
  call session_for_sender
  test rax, rax
  js .error
  mov rbx, [session_bases+rax*8]
  mov r12, qword [request+IpcMessage.words+8]
  mov r13, qword [request+IpcMessage.words+16]
  mov r14, qword [request+IpcMessage.words+24]
  mov r15, qword [request+IpcMessage.words+32]
  cmp r14, FS_BUFFER_BYTES
  ja .invalid
  cmp r15, FS_BUFFER_BYTES
  ja .invalid
  mov rax, r15
  add rax, r14
  jc .invalid
  cmp rax, FS_BUFFER_BYTES
  ja .invalid
  mov rdi, r12
  call object_to_index
  test rax, rax
  js .error
  cmp byte [entry_kinds+rax], FS_NODE_FILE
  jne .not_file
  mov r12, rax                   ;// дальше нужен catalog index
  mov rdi, r12
  call entry_record
  mov rdx, [rax+16]
  cmp r13, rdx
  jae .eof
  sub rdx, r13
  cmp r14, rdx
  jbe .length_ready
  mov r14, rdx
.length_ready:
  add rbx, r15                   ;// destination in session window
  xor r15d, r15d                 ;// completed bytes
.block:
  cmp r15, r14
  jae .success
  mov rdi, r12
  call entry_record
  movzx ecx, word [rax+6]
  lea r8, [rax+ENTRY_HEADER]
  mov rdx, r13
  shr rdx, 12                    ;// logical file block
.extent:
  test ecx, ecx
  jz .corrupt
  mov r9, [r8]
  cmp rdx, r9
  jb .corrupt
  mov eax, [r8+16]
  add r9, rax
  cmp rdx, r9
  jb .extent_found
  add r8, EXTENT_BYTES
  dec ecx
  jmp .extent
.extent_found:
  sub rdx, [r8]
  add rdx, [r8+8]
  mov rdi, rdx
  call block_read
  test rax, rax
  jnz .error
  mov rcx, r13
  and ecx, PAGE_SIZE-1
  mov rdx, PAGE_SIZE
  sub rdx, rcx
  mov rax, r14
  sub rax, r15
  cmp rdx, rax
  jbe .chunk_ready
  mov rdx, rax
.chunk_ready:
  lea rsi, [VAFS_IO_VA+rcx]
  lea rdi, [rbx+r15]
  mov rcx, rdx
  rep movsb
  add r13, rdx
  add r15, rdx
  jmp .block
.success:
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], r15
  jmp .done
.eof:
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], 0
  jmp .done
.not_file:
  mov rax, ERR_INVALID
  jmp .error
.invalid:
  mov rax, ERR_INVALID
  jmp .error
.corrupt:
  mov rax, ERR_CORRUPT
.error:
  mov qword [reply+IpcMessage.words], rax
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Потоковая WRITE: object, file offset, byte count, window offset, flags.
;//
;// Частичная запись остаётся одной COW-транзакцией. Сервис собирает новую
;// последовательность блоков, смешивая старые байты с новым диапазоном, и
;// только потом публикует catalog. Текущая простая версия переписывает весь
;// файл; extent log позже ускорит append, не меняя IPC ABI.
handle_write:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov rdi, qword [request+IpcMessage.sender]
  call session_for_sender
  test rax, rax
  js .error
  mov rbx, [session_bases+rax*8]
  mov r12, qword [request+IpcMessage.words+8]
  mov rax, qword [request+IpcMessage.words+16]
  mov [write_file_offset], rax
  mov r13, qword [request+IpcMessage.words+24]
  mov r14, qword [request+IpcMessage.words+32]
  mov rax, qword [request+IpcMessage.words+40]
  mov [write_flags], rax
  test rax, not FS_WRITE_TRUNCATE
  jnz .invalid
  cmp r13, FS_BUFFER_BYTES
  ja .invalid
  cmp r14, FS_BUFFER_BYTES
  ja .invalid
  mov rax, r14
  add rax, r13
  jc .invalid
  cmp rax, FS_BUFFER_BYTES
  ja .invalid
  add rbx, r14
  mov [write_source], rbx
  mov [write_input_size], r13
  mov rax, [write_file_offset]
  add rax, r13
  jc .invalid
  mov [write_range_end], rax

  mov rdi, r12
  call object_to_index
  test rax, rax
  js .error
  cmp byte [entry_kinds+rax], FS_NODE_FILE
  jne .invalid
  mov [write_entry_index], rax
  mov rdi, rax
  call entry_record
  mov rdx, [rax+16]
  mov [write_old_size], rdx
  mov r15, [write_range_end]
  test qword [write_flags], FS_WRITE_TRUNCATE
  jnz .size_ready
  cmp r15, rdx
  jae .size_ready
  mov r15, rdx
.size_ready:
  mov [write_new_size], r15
  mov dword [write_checksum], 0
  add r15, PAGE_SIZE-1
  jc .no_space
  shr r15, 12
  mov rax, [allocation_cursor]
  mov [write_data_start], rax
  add rax, r15
  jc .no_space
  mov rdx, [volume_blocks]
  dec rdx
  cmp rax, rdx
  ja .no_space

  xor r15d, r15d                 ;// logical block number
.data_block:
  mov rax, [write_new_size]
  add rax, PAGE_SIZE-1
  shr rax, 12
  cmp r15, rax
  jae .data_done
  mov rdi, VAFS_IO_VA
  mov ecx, PAGE_SIZE
  call zero_bytes

  ;// Обычная WRITE начинает со старого блока. TRUNCATE и sparse gap уже нулевые.
  test qword [write_flags], FS_WRITE_TRUNCATE
  jnz .overlay
  mov rax, r15
  shl rax, 12
  cmp rax, [write_old_size]
  jae .overlay
  mov rdi, [write_entry_index]
  mov rsi, r15
  call write_read_old_block
  test rax, rax
  jnz .reload_error
  ;// После старого EOF страница может содержать не относящийся к файлу мусор.
  mov rax, [write_old_size]
  mov rdx, r15
  shl rdx, 12
  sub rax, rdx
  cmp rax, PAGE_SIZE
  jae .overlay
  lea rdi, [VAFS_IO_VA+rax]
  mov ecx, PAGE_SIZE
  sub rcx, rax
  call zero_bytes

.overlay:
  ;// Пересечение [block, block+4096) и [offset, offset+count).
  mov r8, r15
  shl r8, 12
  mov r9, r8
  add r9, PAGE_SIZE
  mov rax, [write_file_offset]
  cmp rax, r8
  jae .overlay_start_ready
  mov rax, r8
.overlay_start_ready:
  mov rdx, [write_range_end]
  cmp rdx, r9
  jbe .overlay_end_ready
  mov rdx, r9
.overlay_end_ready:
  cmp rax, rdx
  jae .checksum_block
  mov rcx, rdx
  sub rcx, rax
  mov rsi, rax
  sub rsi, [write_file_offset]
  add rsi, [write_source]
  mov rdi, rax
  sub rdi, r8
  add rdi, VAFS_IO_VA
  rep movsb

.checksum_block:
  mov rsi, [write_new_size]
  sub rsi, r8
  cmp rsi, PAGE_SIZE
  jbe .checksum_length_ready
  mov esi, PAGE_SIZE
.checksum_length_ready:
  mov rdi, VAFS_IO_VA
  mov eax, [write_checksum]
  call crc32c_update
  mov [write_checksum], eax
  mov rdi, [write_data_start]
  add rdi, r15
  call block_write
  test rax, rax
  jnz .reload_error
  inc r15
  jmp .data_block
.data_done:
  mov rax, [write_data_start]
  add rax, r15
  mov [allocation_cursor], rax

  ;// Сохранить canonical path до замены raw record.
  mov rdi, [write_entry_index]
  call entry_path
  mov [new_path_length], dx
  mov rsi, rax
  lea rdi, [new_path]
  mov rcx, rdx
  rep movsb
  lea rdi, [new_record]
  mov ecx, ENTRY_HEADER+EXTENT_BYTES+MAX_PATH+8
  call zero_bytes
  mov eax, ENTRY_HEADER
  cmp qword [write_new_size], 0
  jz .record_path
  add eax, EXTENT_BYTES
  mov word [new_record+6], 1
  mov qword [new_record+ENTRY_HEADER], 0
  mov rdx, [write_data_start]
  mov qword [new_record+ENTRY_HEADER+8], rdx
  mov rdx, [write_new_size]
  add rdx, PAGE_SIZE-1
  shr rdx, 12
  mov dword [new_record+ENTRY_HEADER+16], edx
.record_path:
  mov edx, eax
  movzx ecx, word [new_path_length]
  add eax, ecx
  add eax, 7
  and eax, not 7
  mov word [new_record], ax
  mov cx, [new_path_length]
  mov word [new_record+2], cx
  mov byte [new_record+4], FS_NODE_FILE
  mov r12, [write_entry_index]
  mov rax, [entry_object_ids+r12*8]
  mov qword [new_record+8], rax
  mov rax, [write_new_size]
  mov qword [new_record+16], rax
  mov eax, [write_checksum]
  mov dword [new_record+32], eax
  lea rdi, [new_record+rdx]
  lea rsi, [new_path]
  movzx ecx, word [new_path_length]
  rep movsb
  mov rdi, r12
  call entry_record
  mov rdi, rax
  lea rsi, [new_record]
  movzx ecx, word [new_record]
  mov [entry_record_sizes+r12*2], cx
  rep movsb

  call commit_catalog
  test rax, rax
  jnz .reload_error
  mov qword [reply+IpcMessage.words], 0
  mov rax, [write_input_size]
  mov qword [reply+IpcMessage.words+8], rax
  jmp .done
.reload_error:
  push rax
  call mount_volume
  pop rax
  jmp .error
.no_space:
  mov rax, ERR_NO_SPACE
  jmp .error
.invalid:
  mov rax, ERR_INVALID
.error:
  mov qword [reply+IpcMessage.words], rax
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=catalog index, RSI=logical block. Читает старый блок в VAFS_IO_VA.
write_read_old_block:
  push rbx
  push r12
  mov r12, rsi
  call entry_record
  movzx ecx, word [rax+6]
  lea rbx, [rax+ENTRY_HEADER]
.extent:
  test ecx, ecx
  jz .corrupt
  mov rdx, [rbx]
  cmp r12, rdx
  jb .corrupt
  mov eax, [rbx+16]
  add rdx, rax
  cmp r12, rdx
  jb .found
  add rbx, EXTENT_BYTES
  dec ecx
  jmp .extent
.found:
  mov rdi, r12
  sub rdi, [rbx]
  add rdi, [rbx+8]
  call block_read
  jmp .done
.corrupt:
  mov rax, ERR_CORRUPT
.done:
  pop r12
  pop rbx
  ret

handle_list:
  mov rdi, qword [request+IpcMessage.words+8]
  call directory_object
  test rax, rax
  js .error
  mov r10, rax                   ;// canonical parent object
  mov rbx, qword [request+IpcMessage.words+16]
  cmp rbx, 1                     ;// entry 0 — корень
  jae .scan
  mov ebx, 1
.scan:
  cmp rbx, [entry_count]
  jae .end
  cmp [entry_parent_ids+rbx*8], r10
  jne .next
  cmp [entry_object_ids+rbx*8], r10
  je .next
  mov rdi, rbx
  call entry_basename
  cmp rdx, MAX_NAME
  ja .name_long
  mov rax, rbx
  inc eax
  movzx ecx, byte [entry_kinds+rbx]
  shl rcx, 32
  or rax, rcx
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rax
  lea rdi, [reply+IpcMessage.words+16]
  mov rcx, rdx
  rep movsb
  ret
.next:
  inc rbx
  jmp .scan
.end:
  mov qword [reply+IpcMessage.words], 1
  ret
.name_long:
  mov rax, ERR_NAME_LONG
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

handle_lookup:
  mov rdi, qword [request+IpcMessage.words+8]
  call directory_object
  test rax, rax
  js .error
  mov r10, rax
  lea rdi, [request+IpcMessage.words+16]
  call request_name_length
  test rax, rax
  js .error
  mov r11, rax
  cmp r11, 1
  jne .dotdot
  cmp byte [request+IpcMessage.words+16], '.'
  je .self
.dotdot:
  cmp r11, 2
  jne .ordinary
  cmp word [request+IpcMessage.words+16], '..'
  jne .ordinary
  mov rdi, r10
  call object_to_index
  test rax, rax
  js .error
  mov r10, [entry_parent_ids+rax*8]
  jmp .found_object
.self:
  jmp .found_object
.ordinary:
  xor ebx, ebx
.scan:
  cmp rbx, [entry_count]
  jae .missing
  cmp [entry_parent_ids+rbx*8], r10
  jne .next
  mov rdi, rbx
  call entry_basename
  cmp rdx, r11
  jne .next
  mov rcx, rdx
  lea rdi, [request+IpcMessage.words+16]
  call bytes_equal
  test eax, eax
  jnz .found_index
.next:
  inc rbx
  jmp .scan
.found_index:
  mov r10, [entry_object_ids+rbx*8]
  jmp .found_object
.missing:
  mov rax, ERR_NOT_FOUND
  jmp .error
.found_object:
  mov rdi, r10
  call object_to_index
  test rax, rax
  js .error
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], r10
  movzx rdx, byte [entry_kinds+rax]
  mov qword [reply+IpcMessage.words+16], rdx
  ret
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// EDX=FS_NODE_*, request содержит parent и name.
handle_create:
  push r12
  push r13
  mov r12d, edx
  mov rdi, qword [request+IpcMessage.words+8]
  call directory_object
  test rax, rax
  js .error
  mov r13, rax
  lea rdi, [request+IpcMessage.words+16]
  call request_name_length
  test rax, rax
  js .error
  cmp rax, 1
  jne .dotdot
  cmp byte [request+IpcMessage.words+16], '.'
  je .invalid
.dotdot:
  cmp rax, 2
  jne .name_ok
  cmp word [request+IpcMessage.words+16], '..'
  je .invalid
.name_ok:
  mov r8, rax                    ;// name length
  mov rdi, r13
  call object_to_index
  test rax, rax
  js .error
  mov rdi, rax
  call entry_path
  mov r9, rdx                    ;// parent path length
  mov r10, rax                   ;// parent path
  mov rax, r9
  cmp r9, 1
  je .root_parent
  inc rax
.root_parent:
  add rax, r8
  cmp rax, MAX_PATH
  ja .name_long
  mov [new_path_length], ax
  lea rdi, [new_path]
  mov rsi, r10
  mov rcx, r9
  rep movsb
  cmp r9, 1
  je .copy_name
  mov byte [rdi], '/'
  inc rdi
.copy_name:
  lea rsi, [request+IpcMessage.words+16]
  mov rcx, r8
  rep movsb

  lea rdi, [new_path]
  movzx esi, word [new_path_length]
  call find_entry_by_path
  cmp rax, ERR_NOT_FOUND
  jne .exists
  cmp qword [entry_count], MAX_ENTRIES
  jae .no_space

  ;// Новая directory/empty-file record. Данные появятся отдельной FS_WRITE.
  lea rdi, [new_record]
  mov ecx, ENTRY_HEADER+MAX_PATH
  call zero_bytes
  movzx eax, word [new_path_length]
  add eax, ENTRY_HEADER+7
  and eax, not 7
  mov word [new_record], ax
  mov cx, [new_path_length]
  mov word [new_record+2], cx
  mov byte [new_record+4], r12b
  mov rdx, [next_object_id]
  mov qword [new_record+8], rdx
  lea rdi, [new_record+ENTRY_HEADER]
  lea rsi, [new_path]
  movzx ecx, word [new_path_length]
  rep movsb
  lea rdi, [new_record]
  movzx esi, word [new_record]
  mov rdx, r13
  call insert_record
  test rax, rax
  jnz .error
  inc qword [next_object_id]
  call commit_catalog
  test rax, rax
  jz .created
  ;// Не публикуем расходящиеся RAM-копии: перечитать последнее целое поколение.
  push rax
  call mount_volume
  pop rax
  jmp .error
.created:
  mov qword [reply+IpcMessage.words], 0
  mov rax, [next_object_id]
  dec rax
  mov qword [reply+IpcMessage.words+8], rax
  jmp .done
.exists:
  mov rax, ERR_EXISTS
  jmp .error
.invalid:
  mov rax, ERR_INVALID
  jmp .error
.name_long:
  mov rax, ERR_NAME_LONG
  jmp .error
.no_space:
  mov rax, ERR_NO_SPACE
.error:
  mov qword [reply+IpcMessage.words], rax
.done:
  pop r13
  pop r12
  ret

;// Вставить отсортированную record.
;// RDI=record, RSI=size, RDX=parent object. RAX=0/error.
insert_record:
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  xor ebx, ebx
.find:
  cmp rbx, [entry_count]
  jae .position
  mov rdi, rbx
  call entry_path
  mov rdi, rax
  mov rsi, rdx
  lea rdx, [new_path]
  movzx ecx, word [new_path_length]
  call compare_paths
  cmp eax, 0
  jg .position
  je .exists
  inc rbx
  jmp .find
.position:
  mov r8, [entry_count]
.shift:
  cmp r8, rbx
  jbe .store
  mov rax, r8
  dec rax
  mov rdx, [entry_object_ids+rax*8]
  mov [entry_object_ids+r8*8], rdx
  mov rdx, [entry_parent_ids+rax*8]
  mov [entry_parent_ids+r8*8], rdx
  mov dl, [entry_kinds+rax]
  mov [entry_kinds+r8], dl
  mov dx, [entry_path_lengths+rax*2]
  mov [entry_path_lengths+r8*2], dx
  mov dx, [entry_record_sizes+rax*2]
  mov [entry_record_sizes+r8*2], dx
  shl rax, 12
  mov rdx, r8
  shl rdx, 12
  mov rsi, [entry_records_base]
  add rsi, rax
  mov rdi, [entry_records_base]
  add rdi, rdx
  mov ecx, RECORD_SLOT/8
  rep movsq
  dec r8
  jmp .shift
.store:
  mov rax, [r12+8]
  mov [entry_object_ids+rbx*8], rax
  mov [entry_parent_ids+rbx*8], r14
  mov al, [r12+4]
  mov [entry_kinds+rbx], al
  mov ax, [r12+2]
  mov [entry_path_lengths+rbx*2], ax
  mov [entry_record_sizes+rbx*2], r13w
  mov rax, rbx
  shl rax, 12
  mov rdi, [entry_records_base]
  add rdi, rax
  mov rsi, r12
  mov rcx, r13
  rep movsb
  inc qword [entry_count]
  xor eax, eax
  jmp .done
.exists:
  mov rax, ERR_EXISTS
.done:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// ------------------------------------------------------------
;// COW commit: leaves -> internal levels -> FLUSH -> older super -> FLUSH
;// ------------------------------------------------------------

commit_catalog:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov rax, [generation]
  inc rax
  mov [commit_generation], rax
  mov rax, [allocation_cursor]
  mov [commit_cursor], rax
  xor r12d, r12d                ;// entry index
  xor r14d, r14d                ;// descriptor count

.leaf_group:
  cmp r12, [entry_count]
  jae .leaves_done
  call begin_node
  xor r13d, r13d                ;// records in node
  mov r15d, NODE_HEADER         ;// used bytes
.leaf_record:
  cmp r12, [entry_count]
  jae .leaf_write
  movzx eax, word [entry_record_sizes+r12*2]
  mov edx, r15d
  add edx, eax
  cmp edx, PAGE_SIZE
  ja .leaf_write
  mov rcx, r12
  shl rcx, 12
  mov rsi, [entry_records_base]
  add rsi, rcx
  lea rdi, [VAFS_IO_VA+r15]
  mov ecx, eax
  rep movsb
  mov r15d, edx
  inc r13d
  inc r12
  jmp .leaf_record
.leaf_write:
  test r13d, r13d
  jz .no_space
  mov word [VAFS_IO_VA+6], r13w
  mov dword [VAFS_IO_VA+24], r15d
  cmp r12, [entry_count]
  jae .last_leaf
  mov rax, [commit_cursor]
  inc rax
  mov [VAFS_IO_VA+16], rax
.last_leaf:
  call finish_node
  test rax, rax
  jnz .done
  mov rbx, r12
  dec rbx
  mov rdi, [descriptors_a_base]
  mov rsi, r14
  call descriptor_address
  mov r8, rax
  mov rdi, rbx
  call entry_path
  mov [r8], dx
  mov rax, [commit_cursor]
  mov [r8+8], rax
  mov rcx, rdx
  mov rsi, rax                   ;// entry_path pointer был в RAX — восстановим
  mov rdi, rbx
  call entry_path
  mov rsi, rax
  lea rdi, [r8+16]
  mov rcx, rdx
  rep movsb
  inc r14
  inc qword [commit_cursor]
  jmp .leaf_group

.leaves_done:
  mov [descriptor_count], r14
  mov rax, [descriptors_a_base]
  mov [descriptor_source], rax
  mov rax, [descriptors_b_base]
  mov [descriptor_target], rax
  mov dword [commit_height], 0
.level:
  cmp qword [descriptor_count], 1
  jbe .tree_ready
  inc dword [commit_height]
  xor r12d, r12d                ;// source descriptor index
  xor r14d, r14d                ;// target descriptor count
.internal_group:
  cmp r12, [descriptor_count]
  jae .level_done
  call begin_node
  mov eax, [commit_height]
  mov [VAFS_IO_VA+4], ax
  xor r13d, r13d
  mov r15d, NODE_HEADER
.internal_record:
  cmp r12, [descriptor_count]
  jae .internal_write
  mov rdi, [descriptor_source]
  mov rsi, r12
  call descriptor_address
  mov r8, rax
  movzx eax, word [r8]
  add eax, 12+7
  and eax, not 7
  mov edx, r15d
  add edx, eax
  cmp edx, PAGE_SIZE
  ja .internal_write
  lea rdi, [VAFS_IO_VA+r15]
  mov [rdi], ax
  mov cx, [r8]
  mov [rdi+2], cx
  mov rcx, [r8+8]
  mov [rdi+4], rcx
  movzx ecx, word [r8]
  lea rsi, [r8+16]
  add rdi, 12
  rep movsb
  mov r15d, edx
  inc r13d
  inc r12
  jmp .internal_record
.internal_write:
  test r13d, r13d
  jz .no_space
  mov word [VAFS_IO_VA+6], r13w
  mov dword [VAFS_IO_VA+24], r15d
  call finish_node
  test rax, rax
  jnz .done
  mov rbx, r12
  dec rbx
  mov rdi, [descriptor_source]
  mov rsi, rbx
  call descriptor_address
  mov r8, rax
  mov rdi, [descriptor_target]
  mov rsi, r14
  call descriptor_address
  mov r9, rax
  mov ax, [r8]
  mov [r9], ax
  mov rax, [commit_cursor]
  mov [r9+8], rax
  movzx ecx, word [r8]
  lea rsi, [r8+16]
  lea rdi, [r9+16]
  rep movsb
  inc r14
  inc qword [commit_cursor]
  jmp .internal_group
.level_done:
  mov [descriptor_count], r14
  mov rax, [descriptor_source]
  xchg rax, [descriptor_target]
  mov [descriptor_source], rax
  jmp .level

.tree_ready:
  mov rdi, [descriptor_source]
  xor esi, esi
  call descriptor_address
  mov rax, [rax+8]
  mov [commit_root], rax
  call block_flush
  test rax, rax
  jnz .done

  ;// Новый superblock создаём из активного: неизвестные совместимые поля не теряются.
  lea rsi, [active_super]
  mov rdi, VAFS_IO_VA
  call copy_page
  mov rax, [commit_generation]
  mov [VAFS_IO_VA+16], rax
  mov rax, [commit_root]
  mov [VAFS_IO_VA+56], rax
  mov eax, [commit_height]
  mov [VAFS_IO_VA+64], eax
  mov rax, [next_object_id]
  mov [VAFS_IO_VA+72], rax
  mov rax, [commit_cursor]
  mov [VAFS_IO_VA+80], rax
  mov dword [VAFS_IO_VA+100], 1
  mov dword [VAFS_IO_VA+104], 0
  mov rdi, VAFS_IO_VA
  mov esi, PAGE_SIZE
  call crc32c
  mov [VAFS_IO_VA+104], eax

  ;// Invalid copy сначала; иначе копия с меньшим generation.
  cmp byte [primary_valid], 0
  je .write_primary
  cmp byte [mirror_valid], 0
  je .write_mirror
  mov rax, qword [primary_super+16]
  cmp rax, qword [mirror_super+16]
  jbe .write_primary
.write_mirror:
  mov rdi, [volume_blocks]
  dec rdi
  call block_write
  test rax, rax
  jnz .done
  call block_flush
  test rax, rax
  jnz .done
  mov rsi, VAFS_IO_VA
  lea rdi, [mirror_super]
  call copy_page
  mov byte [mirror_valid], 1
  mov byte [active_slot], 1
  jmp .published
.write_primary:
  xor edi, edi
  call block_write
  test rax, rax
  jnz .done
  call block_flush
  test rax, rax
  jnz .done
  mov rsi, VAFS_IO_VA
  lea rdi, [primary_super]
  call copy_page
  mov byte [primary_valid], 1
  mov byte [active_slot], 0
.published:
  mov rsi, VAFS_IO_VA
  lea rdi, [active_super]
  call copy_page
  mov rax, [commit_generation]
  mov [generation], rax
  mov rax, [commit_root]
  mov [catalog_root], rax
  mov eax, [commit_height]
  mov [catalog_height], eax
  mov rax, [commit_cursor]
  mov [allocation_cursor], rax
  log commit_marker, commit_marker.size
  xor eax, eax
  jmp .done
.no_space:
  mov rax, ERR_NO_SPACE
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

begin_node:
  mov rdi, VAFS_IO_VA
  mov ecx, PAGE_SIZE
  call zero_bytes
  mov dword [VAFS_IO_VA], 04E544256h
  mov rax, [commit_generation]
  mov [VAFS_IO_VA+8], rax
  ret

;// Посчитать CRC и записать node в commit_cursor.
finish_node:
  mov rax, [commit_cursor]
  mov rdx, [volume_blocks]
  dec rdx
  cmp rax, rdx
  jae .full
  mov dword [VAFS_IO_VA+28], 0
  mov rdi, VAFS_IO_VA
  mov esi, PAGE_SIZE
  call crc32c
  mov [VAFS_IO_VA+28], eax
  mov rdi, [commit_cursor]
  call block_write
  ret
.full:
  mov rax, ERR_NO_SPACE
  ret

;// ------------------------------------------------------------
;// Небольшие чистые helpers
;// ------------------------------------------------------------

;// RDI=object (0 означает virtual root), RAX=canonical object/error.
directory_object:
  test rdi, rdi
  jnz .have
  mov rdi, [root_object_id]
.have:
  push rdi
  call object_to_index
  pop rdx
  test rax, rax
  js .done
  cmp byte [entry_kinds+rax], FS_NODE_DIR
  jne .not_dir
  mov rax, rdx
  ret
.not_dir:
  mov rax, ERR_NOT_DIR
.done:
  ret

object_to_index:
  xor eax, eax
.scan:
  cmp rax, [entry_count]
  jae .missing
  cmp [entry_object_ids+rax*8], rdi
  je .done
  inc rax
  jmp .scan
.missing:
  mov rax, ERR_NOT_FOUND
.done:
  ret

;// RDI=index, RAX=raw leaf record.
entry_record:
  mov rax, rdi
  shl rax, 12
  add rax, [entry_records_base]
  ret

;// RDI=kernel sender ID, RAX=session index/-2.
session_for_sender:
  xor eax, eax
.scan:
  cmp eax, SESSION_MAX
  jae .missing
  cmp qword [session_handles+rax*8], 0
  je .next
  cmp [session_owners+rax*8], rdi
  je .done
.next:
  inc eax
  jmp .scan
.missing:
  mov rax, ERR_NOT_FOUND
.done:
  ret

;// RDI=index, RAX=path pointer, RDX=length.
entry_path:
  mov rax, rdi
  shl rax, 12
  add rax, [entry_records_base]
  movzx ecx, word [rax+6]
  imul ecx, EXTENT_BYTES
  add rax, ENTRY_HEADER
  add rax, rcx
  movzx edx, word [entry_path_lengths+rdi*2]
  ret

;// RDI=index, RSI=basename pointer, RDX=length.
entry_basename:
  call entry_path
  mov rsi, rax
  mov rcx, rdx
.scan:
  test rcx, rcx
  jz .root
  dec rcx
  cmp byte [rax+rcx], '/'
  jne .scan
  lea rsi, [rax+rcx+1]
  sub rdx, rcx
  dec rdx
  ret
.root:
  xor edx, edx
  ret

;// RDI=path, RSI=len. RAX=index/-2.
find_entry_by_path:
  push rbx
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
  xor ebx, ebx
.scan:
  cmp rbx, [entry_count]
  jae .missing
  mov rdi, rbx
  call entry_path
  cmp rdx, r13
  jne .next
  mov rcx, rdx
  mov rdi, r12
  mov rsi, rax
  call bytes_equal
  test eax, eax
  jnz .found
.next:
  inc rbx
  jmp .scan
.found:
  mov rax, rbx
  jmp .done
.missing:
  mov rax, ERR_NOT_FOUND
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=path, RSI=len, RAX=parent len (root -> 1).
parent_length:
  mov rax, rsi
.scan:
  dec rax
  cmp byte [rdi+rax], '/'
  jne .scan
  test rax, rax
  jnz .done
  mov eax, 1
.done:
  ret

;// Lexicographic compare: (RDI,RSI) vs (RDX,RCX), EAX=-1/0/1.
compare_paths:
  push rbx
  xor ebx, ebx
.byte:
  cmp rbx, rsi
  jae .left_end
  cmp rbx, rcx
  jae .greater
  mov al, [rdi+rbx]
  cmp al, [rdx+rbx]
  jb .less
  ja .greater
  inc rbx
  jmp .byte
.left_end:
  cmp rbx, rcx
  jb .less
  xor eax, eax
  jmp .done
.less:
  mov eax, -1
  jmp .done
.greater:
  mov eax, 1
.done:
  pop rbx
  ret

;// RDI и RSI, RCX bytes. EAX=1/0.
bytes_equal:
  xor eax, eax
.byte:
  test rcx, rcx
  jz .yes
  mov dl, [rdi]
  cmp dl, [rsi]
  jne .no
  inc rdi
  inc rsi
  dec rcx
  jmp .byte
.yes:
  mov eax, 1
.no:
  ret

;// Имя из request words[2..7]. RAX=len/error.
request_name_length:
  xor eax, eax
.byte:
  cmp rax, MAX_NAME+1
  jae .long
  mov dl, [rdi+rax]
  test dl, dl
  jz .end
  cmp dl, 32
  jbe .invalid
  cmp dl, '/'
  je .invalid
  inc rax
  jmp .byte
.end:
  test rax, rax
  jz .invalid
  ret
.long:
  mov rax, ERR_NAME_LONG
  ret
.invalid:
  mov rax, ERR_INVALID
  ret

;// RDI=base, RSI=index, RAX=descriptor address.
descriptor_address:
  mov rax, rsi
  imul rax, DESC_SLOT
  add rax, rdi
  ret

copy_page:
  mov ecx, PAGE_SIZE/8
  rep movsq
  ret

zero_bytes:
  xor eax, eax
  rep stosb
  ret

;// CRC32C Castagnoli. crc32c начинает новую сумму, crc32c_update продолжает
;// её по следующему фрагменту. Так checksum считается потоком страниц.
crc32c:
  xor eax, eax
crc32c_update:
  not eax
.next_byte:
  test esi, esi
  jz .finish
  movzx edx, byte [rdi]
  xor eax, edx
  mov ecx, 8
.bit:
  mov edx, eax
  and edx, 1
  neg edx
  and edx, 082F63B78h
  shr eax, 1
  xor eax, edx
  dec ecx
  jnz .bit
  inc rdi
  dec esi
  jmp .next_byte
.finish:
  not eax
  ret

send_retry:
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
.again:
  mov eax, SYS_IPC_SEND
  mov rdi, r12
  mov rsi, r13
  syscall
  cmp rax, IPC_WOULD_BLOCK
  jne .done
  system_call SYS_YIELD
  jmp .again
.done:
  pop r13
  pop r12
  ret

close_request_caps:
  push rbx
  mov rbx, qword [request+IpcMessage.cap_count]
.next:
  test rbx, rbx
  jz .done
  dec rbx
  mov rax, rbx
  shl rax, 4
  mov rdi, qword [request+IpcMessage.caps+rax+IpcCap.handle]
  close_cap rdi
  jmp .next
.done:
  pop rbx
  ret

segment readable writeable
ready_text db "vafs: persistent COW filesystem service ready", 10
.size = $-ready_text
mount_marker db "VARANIA:VAFS_MOUNT_OK", 10
.size = $-mount_marker
commit_marker db "VARANIA:VAFS_COMMIT_OK", 10
.size = $-commit_marker
corrupt_text db "vafs: no valid superblock or catalog", 10
.size = $-corrupt_text
fatal_text db "vafs: block service or IPC failure", 10
.size = $-fatal_text

align 8
block_endpoint dq 0
io_buffer_cap dq 0
volume_blocks dq 0
write_data_start dq 0
write_checksum dd 0
align 8
write_source dq 0
write_input_size dq 0
write_file_offset dq 0
write_range_end dq 0
write_old_size dq 0
write_new_size dq 0
write_entry_index dq 0
write_flags dq 0
session_owners rq SESSION_MAX
session_handles rq SESSION_MAX
session_bases rq SESSION_MAX

primary_valid db 0
mirror_valid db 0
active_slot db 0
align 8
generation dq 0
catalog_root dq 0
catalog_height dd 0
align 8
next_object_id dq 0
allocation_cursor dq 0
root_object_id dq 0

entry_count dq 0
entry_object_ids rq MAX_ENTRIES
entry_parent_ids rq MAX_ENTRIES
entry_kinds rb MAX_ENTRIES
align 2
entry_path_lengths rw MAX_ENTRIES
entry_record_sizes rw MAX_ENTRIES
align PAGE_SIZE
entry_records_base dq 0

align 8
commit_generation dq 0
commit_cursor dq 0
commit_root dq 0
commit_height dd 0
align 8
descriptor_count dq 0
descriptor_source dq 0
descriptor_target dq 0
descriptors_a_base dq 0
descriptors_b_base dq 0

align PAGE_SIZE
primary_super rb PAGE_SIZE
mirror_super rb PAGE_SIZE
active_super rb PAGE_SIZE
new_record rb ENTRY_HEADER+EXTENT_BYTES+MAX_PATH+8
new_path_length dw 0
new_path rb MAX_PATH

align 8
request rb IpcMessage.bytes
reply rb IpcMessage.bytes
