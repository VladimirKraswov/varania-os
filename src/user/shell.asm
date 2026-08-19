format ELF64 executable 3
entry start
include "abi.inc"

;// Первый интерактивный процесс Varania OS. Shell не имеет доступа ни к VGA,
;// ни к PS/2, ни к структурам RAMFS: он знает только IPC endpoints сервисов.
;// Это и есть практическая граница между приложением и user-space drivers.
SELF_EP       = 1
NAMESERVER_EP = 2
PATH_CAP      = 64

IPC_WOULD_BLOCK = -11

segment readable executable
start:
  mov edi, SERVICE_TERMINAL
  call lookup_service
  test rax, rax
  js fatal
  mov [terminal_endpoint], rax

  mov edi, SERVICE_RAMFS
  call lookup_service
  test rax, rax
  js fatal
  mov [filesystem_endpoint], rax

  log ready_text, ready_text.size
  lea rdi, [shell_ready]
  call print_z

.prompt:
  lea rdi, [prompt_prefix]
  call print_z
  lea rdi, [current_path]
  call print_z
  lea rdi, [prompt_suffix]
  call print_z
  call read_line
  test rax, rax
  jnz fatal

  cmp byte [line_buffer], 0
  je .prompt
  lea rdi, [line_buffer]
  lea rsi, [cmd_help]
  call strings_equal
  test eax, eax
  jnz .help
  lea rdi, [line_buffer]
  lea rsi, [cmd_ls]
  call strings_equal
  test eax, eax
  jnz .ls
  lea rdi, [line_buffer]
  lea rsi, [cmd_pwd]
  call strings_equal
  test eax, eax
  jnz .pwd
  lea rdi, [line_buffer]
  lea rsi, [cmd_clear]
  call strings_equal
  test eax, eax
  jnz .clear

  lea rdi, [line_buffer]
  lea rsi, [prefix_cd]
  call starts_with
  test eax, eax
  jnz .cd
  lea rdi, [line_buffer]
  lea rsi, [prefix_mkdir]
  call starts_with
  test eax, eax
  jnz .mkdir
  lea rdi, [line_buffer]
  lea rsi, [prefix_touch]
  call starts_with
  test eax, eax
  jnz .touch

  lea rdi, [unknown_text]
  call print_z
  jmp .prompt

.help:
  lea rdi, [help_text]
  call print_z
  jmp .prompt
.ls:
  call command_ls
  jmp .prompt
.pwd:
  lea rdi, [current_path]
  call print_z
  lea rdi, [newline]
  call print_z
  jmp .prompt
.clear:
  call terminal_clear
  jmp .prompt
.cd:
  lea rsi, [line_buffer+3]
  call command_cd
  jmp .prompt
.mkdir:
  lea rsi, [line_buffer+6]
  mov edi, FS_MKDIR
  call command_create
  jmp .prompt
.touch:
  lea rsi, [line_buffer+6]
  mov edi, FS_CREATE
  call command_create
  jmp .prompt

fatal:
  log failed_text, failed_text.size
  exit_process 1

;// Получить SEND-capability сервиса. EDI=service ID, RAX=handle/error.
lookup_service:
  push rbx
  push r12
  mov r12d, edi
.retry:
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [ipc_message+IpcMessage.words+8], r12
  mov qword [ipc_message+IpcMessage.cap_count], 1
  mov qword [ipc_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [ipc_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov edi, NAMESERVER_EP
  lea rsi, [ipc_message]
  call send_retry
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, ipc_reply
  test rax, rax
  jnz .done
  cmp qword [ipc_reply+IpcMessage.words], 0
  je .found
  system_call SYS_YIELD
  jmp .retry
.found:
  cmp qword [ipc_reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [ipc_reply+IpcMessage.caps+IpcCap.handle]
  jmp .done
.invalid:
  mov rax, -22
.done:
  pop r12
  pop rbx
  ret

;// Напечатать NUL-terminated строку. RDI=address.
print_z:
  push rbx
  mov rbx, rdi
  xor esi, esi
.length:
  cmp byte [rbx+rsi], 0
  je .write
  inc rsi
  cmp rsi, 255
  jb .length
.write:
  mov rdi, rbx
  call terminal_write
  pop rbx
  ret

;// Отправлять текст кусками по 16 байт — столько помещается в IPC payload.
;// RDI=buffer, RSI=len.
terminal_write:
  push rbx
  push r12
  push r13
  push r14
  mov r12, rdi
  mov r13, rsi
.chunk:
  test r13, r13
  jz .done
  mov r14, r13
  cmp r14, 16
  jbe .size_ready
  mov r14d, 16
.size_ready:
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], TERM_WRITE
  mov qword [ipc_message+IpcMessage.words+8], r14
  lea rdi, [ipc_message+IpcMessage.words+16]
  mov rsi, r12
  mov rcx, r14
  rep movsb
  mov rdi, [terminal_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  test rax, rax
  jnz .done
  add r12, r14
  sub r13, r14
  jmp .chunk
.done:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

terminal_clear:
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], TERM_CLEAR
  mov rdi, [terminal_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  ret

;// Запросить у terminal одну строку. Редактирование и echo выполняет terminal,
;// shell получает уже готовые 0..15 байт.
read_line:
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], TERM_READLINE
  mov qword [ipc_message+IpcMessage.cap_count], 1
  mov qword [ipc_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [ipc_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rdi, [terminal_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  test rax, rax
  jnz .done
  ;// Маркер ставится после enqueue READLINE. End-to-end тест теперь может
  ;// подавать key events без гонки с отрисовкой приветствия и prompt.
  log prompt_ready_text, prompt_ready_text.size
  ipc_receive SELF_EP, ipc_reply
  test rax, rax
  jnz .done
  mov rdx, qword [ipc_reply+IpcMessage.words+8]
  cmp rdx, 15
  ja .invalid
  lea rdi, [line_buffer]
  mov ecx, 16
  xor eax, eax
  rep stosb
  lea rsi, [ipc_reply+IpcMessage.words+16]
  lea rdi, [line_buffer]
  mov rcx, rdx
  rep movsb
  xor eax, eax
  ret
.invalid:
  mov rax, -22
.done:
  ret

;// LIST текущего каталога.
command_ls:
  push rbx
  mov ebx, 1
.next:
  mov rdi, rbx
  call fs_list_request
  cmp rax, 1
  je .complete
  test rax, rax
  jnz .error
  mov rax, qword [ipc_reply+IpcMessage.words+8]
  mov ebx, eax                    ;// low dword — следующий cursor
  lea rdi, [ipc_reply+IpcMessage.words+16]
  call print_z
  mov rax, qword [ipc_reply+IpcMessage.words+8]
  shr rax, 32
  cmp eax, FS_NODE_DIR
  jne .line_end
  lea rdi, [slash]
  call print_z
.line_end:
  lea rdi, [newline]
  call print_z
  jmp .next
.complete:
  log ls_ok_text, ls_ok_text.size
  xor eax, eax
  jmp .done
.error:
  lea rdi, [fs_error_text]
  call print_z
.done:
  pop rbx
  ret

;// EDI=FS_MKDIR/FS_CREATE, RSI=name.
command_create:
  push rbx
  mov ebx, edi
  call fs_named_request
  test rax, rax
  jnz .error
  cmp ebx, FS_MKDIR
  jne .file
  lea rdi, [mkdir_ok]
  call print_z
  log mkdir_ok_text, mkdir_ok_text.size
  jmp .done
.file:
  lea rdi, [touch_ok]
  call print_z
  log touch_ok_text, touch_ok_text.size
  jmp .done
.error:
  lea rdi, [fs_error_text]
  call print_z
.done:
  pop rbx
  ret

;// RSI=name. Смена каталога выполняется через LOOKUP, а не через локальное
;// знание RAMFS. Это сохранит команду при появлении другого FS-драйвера.
command_cd:
  push rbx
  push r12
  mov r12, rsi
  cmp byte [r12], '/'
  jne .lookup
  cmp byte [r12+1], 0
  jne .error
  mov qword [current_node], 0
  mov qword [path_length], 1
  mov byte [current_path], '/'
  mov byte [current_path+1], 0
  jmp .success
.lookup:
  mov edi, FS_LOOKUP
  mov rsi, r12
  call fs_named_request
  test rax, rax
  jnz .error
  cmp qword [ipc_reply+IpcMessage.words+16], FS_NODE_DIR
  jne .not_dir
  mov rbx, qword [ipc_reply+IpcMessage.words+8]
  cmp byte [r12], '.'
  jne .down
  cmp byte [r12+1], 0
  je .store
  cmp byte [r12+1], '.'
  jne .down
  cmp byte [r12+2], 0
  jne .down
  call path_up
  jmp .store
.down:
  mov rsi, r12
  call path_down
  test eax, eax
  jz .too_long
.store:
  mov qword [current_node], rbx
.success:
  log cd_ok_text, cd_ok_text.size
  jmp .done
.not_dir:
  lea rdi, [not_dir_text]
  call print_z
  jmp .done
.too_long:
  lea rdi, [path_long_text]
  call print_z
  jmp .done
.error:
  lea rdi, [fs_error_text]
  call print_z
.done:
  pop r12
  pop rbx
  ret

;// LIST RPC. RDI=cursor, RAX=status.
fs_list_request:
  push r12
  mov r12, rdi
  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_LIST
  mov rax, [current_node]
  mov qword [ipc_message+IpcMessage.words+8], rax
  mov qword [ipc_message+IpcMessage.words+16], r12
  call fs_rpc
  pop r12
  ret

;// Named RPC. EDI=operation, RSI=name, RAX=status.
fs_named_request:
  push rbx
  push r12
  mov ebx, edi
  mov r12, rsi
  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], rbx
  mov rax, [current_node]
  mov qword [ipc_message+IpcMessage.words+8], rax
  lea rdi, [ipc_message+IpcMessage.words+16]
  mov rsi, r12
  mov ecx, 16
.copy_name:
  mov al, byte [rsi]
  mov byte [rdi], al
  inc rsi
  inc rdi
  test al, al
  jz .send
  dec ecx
  jnz .copy_name
.send:
  call fs_rpc
  pop r12
  pop rbx
  ret

prepare_fs_request:
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.cap_count], 1
  mov qword [ipc_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [ipc_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ret

fs_rpc:
  mov rdi, [filesystem_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  test rax, rax
  jnz .done
  ipc_receive SELF_EP, ipc_reply
  test rax, rax
  jnz .done
  mov rax, qword [ipc_reply+IpcMessage.words]
.done:
  ret

;// Очередь endpoint конечна. Yield превращает временное заполнение в обычный
;// backpressure, а не в падение драйвера или приложения.
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

;// Добавить компонент к printable path. RSI=name, RAX=1/0.
path_down:
  push rbx
  push r12
  mov r12, rsi
  xor ebx, ebx
.measure:
  cmp byte [r12+rbx], 0
  je .measured
  inc rbx
  cmp rbx, 15
  jbe .measure
  jmp .bad
.measured:
  mov rax, [path_length]
  cmp rax, 1
  je .space
  inc rax                         ;// разделитель между компонентами
.space:
  add rax, rbx
  cmp rax, PATH_CAP
  jae .bad
  mov rdx, [path_length]
  cmp rdx, 1
  je .copy
  mov byte [current_path+rdx], '/'
  inc rdx
.copy:
  xor ecx, ecx
.byte:
  cmp rcx, rbx
  jae .finish
  mov al, byte [r12+rcx]
  mov byte [current_path+rdx], al
  inc rcx
  inc rdx
  jmp .byte
.finish:
  mov byte [current_path+rdx], 0
  mov [path_length], rdx
  mov eax, 1
  jmp .done
.bad:
  xor eax, eax
.done:
  pop r12
  pop rbx
  ret

;// Удалить последний компонент printable path.
path_up:
  mov rax, [path_length]
  cmp rax, 1
  jbe .done
  dec rax
.scan:
  cmp rax, 0
  je .root
  cmp byte [current_path+rax], '/'
  je .cut
  dec rax
  jmp .scan
.root:
  mov eax, 1
.cut:
  mov [path_length], rax
  mov byte [current_path+rax], 0
.done:
  ret

;// Полное сравнение двух NUL-terminated строк. RAX=1/0.
strings_equal:
  xor ecx, ecx
.byte:
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

;// Проверить только префикс RSI (например, "mkdir ").
starts_with:
  xor ecx, ecx
.byte:
  mov al, byte [rsi+rcx]
  test al, al
  jz .yes
  cmp al, byte [rdi+rcx]
  jne .no
  inc ecx
  jmp .byte
.yes:
  mov eax, 1
  ret
.no:
  xor eax, eax
  ret

segment readable writeable
ready_text db "VARANIA:SHELL_READY", 10
.size = $-ready_text
prompt_ready_text db "VARANIA:SHELL_PROMPT_READY", 10
.size = $-prompt_ready_text
ls_ok_text db "VARANIA:SHELL_LS_OK", 10
.size = $-ls_ok_text
mkdir_ok_text db "VARANIA:SHELL_MKDIR_OK", 10
.size = $-mkdir_ok_text
cd_ok_text db "VARANIA:SHELL_CD_OK", 10
.size = $-cd_ok_text
touch_ok_text db "VARANIA:SHELL_TOUCH_OK", 10
.size = $-touch_ok_text
failed_text db "shell: fatal service or IPC error", 10
.size = $-failed_text

shell_ready db "Shell is ready. Type 'help' for commands.", 10, 10, 0
prompt_prefix db "varania:", 0
prompt_suffix db "$ ", 0
help_text db "Commands: ls, cd DIR, mkdir DIR, touch FILE, pwd, clear, help", 10, 0
unknown_text db "Unknown command. Type 'help'.", 10, 0
fs_error_text db "Filesystem operation failed.", 10, 0
not_dir_text db "cd: target is not a directory.", 10, 0
path_long_text db "cd: displayed path is too long.", 10, 0
mkdir_ok db "Directory created.", 10, 0
touch_ok db "File created.", 10, 0
slash db "/", 0
newline db 10, 0

cmd_help db "help", 0
cmd_ls db "ls", 0
cmd_pwd db "pwd", 0
cmd_clear db "clear", 0
prefix_cd db "cd ", 0
prefix_mkdir db "mkdir ", 0
prefix_touch db "touch ", 0

align 8
terminal_endpoint dq 0
filesystem_endpoint dq 0
current_node dq 0
path_length dq 1
current_path db '/', 0
times PATH_CAP-2 db 0
line_buffer rb 16
ipc_message rb IpcMessage.bytes
ipc_reply rb IpcMessage.bytes
