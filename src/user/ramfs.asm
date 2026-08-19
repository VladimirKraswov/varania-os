format ELF64 executable 3
entry start
include "abi.inc"

;// RAMFS — первый файловый драйвер Varania OS. Ядро не знает о файлах:
;// клиент посылает этому процессу обычные IPC-сообщения. Дисковый драйвер
;// сможет реализовать тот же протокол, не меняя shell и микроядро.
SELF_EP       = 1
NAMESERVER_EP = 2

NODE_MAX  = 32
NAME_SIZE = 16                    ;// 15 ASCII-символов и завершающий NUL

ERR_NOT_FOUND = -2
ERR_INVALID   = -22
ERR_EXISTS    = -17
ERR_NOT_DIR   = -20
ERR_NO_SPACE  = -28
ERR_NOT_IMPL  = -38

segment readable executable
start:
  ;// Публикуем endpoint. Nameserver хранит только SEND-capability.
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [message+IpcMessage.words+8], SERVICE_RAMFS
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  test rax, rax
  jnz fatal
  log ready_text, ready_text.size

.serve:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz fatal

  ;// Каждый запрос является RPC и передаёт ровно один reply endpoint.
  cmp qword [message+IpcMessage.cap_count], 1
  jne .drop
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [reply_handle], rax
  call prepare_reply

  mov rax, qword [message+IpcMessage.words]
  cmp rax, FS_LIST
  je .list
  cmp rax, FS_LOOKUP
  je .lookup
  cmp rax, FS_MKDIR
  je .mkdir
  cmp rax, FS_CREATE
  je .create
  mov qword [reply+IpcMessage.words], ERR_NOT_IMPL
  jmp .reply

.list:
  call handle_list
  jmp .reply
.lookup:
  call handle_lookup
  jmp .reply
.mkdir:
  mov edx, FS_NODE_DIR
  call handle_create
  jmp .reply
.create:
  mov edx, FS_NODE_FILE
  call handle_create

.reply:
  mov eax, SYS_IPC_SEND
  mov rdi, [reply_handle]
  lea rsi, [reply]
  syscall
  push rax
  mov rdi, [reply_handle]
  call close_handle
  mov qword [reply_handle], 0
  pop rax
  test rax, rax
  jnz fatal
  jmp .serve

.drop:
  call close_received_caps
  jmp .serve

fatal:
  log failed_text, failed_text.size
  exit_process 1

;// LIST request: words[1]=directory node, words[2]=cursor.
;// Успешный entry: status=0, words[1].low=next cursor,
;// words[1].high=node type, words[2..3]=name. status=1 означает конец.
handle_list:
  mov rdi, qword [message+IpcMessage.words+8]
  call validate_directory
  test rax, rax
  jnz .error
  mov rbx, qword [message+IpcMessage.words+16]
  cmp rbx, 1                      ;// node 0 — сам корень, его не перечисляем
  jae .scan
  mov ebx, 1
.scan:
  cmp rbx, NODE_MAX
  jae .end
  cmp qword [node_used+rbx*8], 0
  je .next
  mov rax, qword [message+IpcMessage.words+8]
  cmp qword [node_parent+rbx*8], rax
  jne .next
  mov rax, rbx
  inc rax
  mov edx, dword [node_type+rbx*8]
  shl rdx, 32
  or rax, rdx
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rax
  mov rax, rbx
  shl rax, 4
  lea rsi, [node_names+rax]
  lea rdi, [reply+IpcMessage.words+16]
  mov ecx, NAME_SIZE
  rep movsb
  ret
.next:
  inc rbx
  jmp .scan
.end:
  mov qword [reply+IpcMessage.words], 1
  ret
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// LOOKUP request: words[1]=directory node, words[2..3]=name.
;// Response: status, node id, node type. «.» и «..» разрешаются драйвером,
;// поэтому shell не обязан знать внутреннее устройство дерева.
handle_lookup:
  mov rdi, qword [message+IpcMessage.words+8]
  call validate_directory
  test rax, rax
  jnz .error
  lea rsi, [message+IpcMessage.words+16]
  call validate_name
  test rax, rax
  jz .invalid
  lea rsi, [message+IpcMessage.words+16]
  cmp byte [rsi], '.'
  jne .ordinary
  cmp byte [rsi+1], 0
  je .dot
  cmp byte [rsi+1], '.'
  jne .ordinary
  cmp byte [rsi+2], 0
  jne .ordinary
  mov rbx, qword [message+IpcMessage.words+8]
  mov rbx, qword [node_parent+rbx*8]
  jmp .found
.dot:
  mov rbx, qword [message+IpcMessage.words+8]
  jmp .found
.ordinary:
  mov rdi, qword [message+IpcMessage.words+8]
  call find_child
  test rax, rax
  js .error
  mov rbx, rax
.found:
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rbx
  mov rax, qword [node_type+rbx*8]
  mov qword [reply+IpcMessage.words+16], rax
  ret
.invalid:
  mov rax, ERR_INVALID
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// MKDIR/CREATE: words[1]=parent, words[2..3]=name. EDX содержит тип.
handle_create:
  mov r12, rdx
  mov rdi, qword [message+IpcMessage.words+8]
  call validate_directory
  test rax, rax
  jnz .error
  lea rsi, [message+IpcMessage.words+16]
  call validate_name
  test rax, rax
  jz .invalid
  cmp byte [message+IpcMessage.words+16], '.'
  jne .unique
  cmp byte [message+IpcMessage.words+17], 0
  je .invalid
  cmp byte [message+IpcMessage.words+17], '.'
  jne .unique
  cmp byte [message+IpcMessage.words+18], 0
  je .invalid
.unique:
  mov rdi, qword [message+IpcMessage.words+8]
  lea rsi, [message+IpcMessage.words+16]
  call find_child
  cmp rax, ERR_NOT_FOUND
  jne .exists

  mov ebx, 1
.free:
  cmp rbx, NODE_MAX
  jae .no_space
  cmp qword [node_used+rbx*8], 0
  je .store
  inc rbx
  jmp .free
.store:
  mov qword [node_used+rbx*8], 1
  mov qword [node_type+rbx*8], r12
  mov rax, qword [message+IpcMessage.words+8]
  mov qword [node_parent+rbx*8], rax
  mov rax, rbx
  shl rax, 4
  lea rdi, [node_names+rax]
  lea rsi, [message+IpcMessage.words+16]
  mov ecx, NAME_SIZE
  rep movsb
  mov qword [reply+IpcMessage.words], 0
  mov qword [reply+IpcMessage.words+8], rbx
  ret
.exists:
  mov rax, ERR_EXISTS
  jmp .error
.no_space:
  mov rax, ERR_NO_SPACE
  jmp .error
.invalid:
  mov rax, ERR_INVALID
.error:
  mov qword [reply+IpcMessage.words], rax
  ret

;// Проверить, что RDI указывает на существующий каталог. RAX=0/error.
validate_directory:
  cmp rdi, NODE_MAX
  jae .missing
  cmp qword [node_used+rdi*8], 0
  je .missing
  cmp qword [node_type+rdi*8], FS_NODE_DIR
  jne .not_dir
  xor eax, eax
  ret
.missing:
  mov rax, ERR_NOT_FOUND
  ret
.not_dir:
  mov rax, ERR_NOT_DIR
  ret

;// Имя — 1..15 печатных ASCII без '/'. RAX=1/0.
validate_name:
  xor eax, eax
.next:
  cmp rax, NAME_SIZE
  jae .bad
  mov dl, byte [rsi+rax]
  test dl, dl
  jz .end
  cmp dl, 32
  jbe .bad
  cmp dl, '/'
  je .bad
  inc rax
  jmp .next
.end:
  test rax, rax
  jz .bad
  mov eax, 1
  ret
.bad:
  xor eax, eax
  ret

;// Найти дочерний узел: RDI=parent, RSI=name, RAX=node/ERR_NOT_FOUND.
find_child:
  push rbx
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
  mov ebx, 1
.scan:
  cmp rbx, NODE_MAX
  jae .missing
  cmp qword [node_used+rbx*8], 0
  je .next
  cmp qword [node_parent+rbx*8], r12
  jne .next
  mov rax, rbx
  shl rax, 4
  lea rdi, [node_names+rax]
  mov rsi, r13
  call names_equal
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

;// Сравнить два NUL-terminated имени длиной не более 15. RAX=1/0.
names_equal:
  xor ecx, ecx
.byte:
  cmp ecx, NAME_SIZE
  jae .yes
  mov al, byte [rdi+rcx]
  cmp al, byte [rsi+rcx]
  jne .no
  test al, al
  jz .yes
  inc ecx
  jmp .byte
.yes:
  mov eax, 1
  ret
.no:
  xor eax, eax
  ret

prepare_reply:
  lea rdi, [reply]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
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
  call close_handle
  pop rcx
  inc rbx
  jmp .next
.done:
  ret

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
.done:
  ret

segment readable writeable
ready_text db "ramfs: user-space filesystem service ready", 10
.size = $-ready_text
failed_text db "ramfs: fatal IPC error", 10
.size = $-failed_text

align 8
reply_handle dq 0

;// Небольшое начальное дерево нужно, чтобы первый `ls /` был полезен.
;// Все изменения живут до перезагрузки; постоянное хранилище появится как
;// другой драйвер того же FS-протокола.
node_used:
  dq 1, 1, 1, 1, 1
  times NODE_MAX-5 dq 0
node_type:
  dq FS_NODE_DIR, FS_NODE_DIR, FS_NODE_DIR, FS_NODE_DIR, FS_NODE_FILE
  times NODE_MAX-5 dq 0
node_parent:
  dq 0, 0, 0, 0, 0
  times NODE_MAX-5 dq 0
node_names:
  times NAME_SIZE db 0
  db "bin", 0
  times NAME_SIZE-4 db 0
  db "etc", 0
  times NAME_SIZE-4 db 0
  db "home", 0
  times NAME_SIZE-5 db 0
  db "README", 0
  times NAME_SIZE-7 db 0
  times (NODE_MAX-5)*NAME_SIZE db 0

align 8
message rb IpcMessage.bytes
reply rb IpcMessage.bytes
