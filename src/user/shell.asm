format ELF64 executable 3
entry start
include "abi.inc"

;// Первый интерактивный процесс Varania OS. Shell не имеет доступа ни к VGA,
;// ни к PS/2, ни к структурам VaraniaFS: он знает только IPC endpoints сервисов.
;// Это и есть практическая граница между приложением и user-space drivers.
SELF_EP       = 1
NAMESERVER_EP = 2
PATH_CAP      = 64
FS_BUFFER_VA  = 0x0000000064000000

IPC_WOULD_BLOCK = -11

segment readable executable
start:
  mov edi, SERVICE_TERMINAL
  call lookup_service
  test rax, rax
  js fatal
  mov [terminal_endpoint], rax

  mov edi, SERVICE_FILESYSTEM
  call lookup_service
  test rax, rax
  js fatal
  mov [filesystem_endpoint], rax
  call filesystem_attach
  test rax, rax
  jnz fatal

  mov edi, SERVICE_PROCESS
  call lookup_service
  test rax, rax
  js fatal
  mov [process_endpoint], rax

  mov edi, SERVICE_SESSION
  call lookup_service
  test rax, rax
  js fatal
  mov [session_endpoint], rax

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
  lea rdi, [line_buffer]
  lea rsi, [prefix_cat]
  call starts_with
  test eax, eax
  jnz .cat
  lea rdi, [line_buffer]
  lea rsi, [prefix_write]
  call starts_with
  test eax, eax
  jnz .write
  lea rdi, [line_buffer]
  lea rsi, [prefix_append]
  call starts_with
  test eax, eax
  jnz .append
  lea rdi, [line_buffer]
  lea rsi, [prefix_edit]
  call starts_with
  test eax, eax
  jnz .edit
  lea rdi, [line_buffer]
  lea rsi, [prefix_run]
  call starts_with
  test eax, eax
  jnz .run

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
.cat:
  lea rsi, [line_buffer+4]
  call command_cat
  jmp .prompt
.write:
  lea rsi, [line_buffer+6]
  mov edi, FS_WRITE_TRUNCATE
  call command_write
  jmp .prompt
.append:
  lea rsi, [line_buffer+7]
  xor edi, edi
  call command_write
  jmp .prompt
.edit:
  lea rsi, [line_buffer+5]
  call command_edit
  jmp .prompt
.run:
  lea rsi, [line_buffer+4]
  call command_run
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

;// Получить собственное shared file window у VFS и отобразить его.
filesystem_attach:
  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_ATTACH
  call fs_rpc
  test rax, rax
  jnz .done
  cmp qword [ipc_reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rdx, qword [ipc_reply+IpcMessage.words+8]
  cmp rdx, PAGE_SIZE
  jb .invalid
  mov [filesystem_buffer_size], rdx
  mov rdi, qword [ipc_reply+IpcMessage.caps+IpcCap.handle]
  mov [filesystem_buffer_cap], rdi
  mov eax, SYS_SHARED_MAP
  mov rsi, FS_BUFFER_VA
  mov edx, SPACE_MAP_WRITE
  syscall
  ret
.invalid:
  mov rax, -22
.done:
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
  cmp rdx, 47
  ja .invalid
  lea rdi, [line_buffer]
  mov ecx, 48
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

;// RSI=name. LOOKUP получает object ID, READ переносит данные через отдельное
;// shared window; IPC остаётся control plane и не копирует байты файла.
command_cat:
  push rbx
  push r12
  push r13
  mov edi, FS_LOOKUP
  call fs_named_request
  test rax, rax
  jnz .error
  cmp qword [ipc_reply+IpcMessage.words+16], FS_NODE_FILE
  jne .error
  mov r12, qword [ipc_reply+IpcMessage.words+8]
  xor r13d, r13d
.read:
  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_READ
  mov qword [ipc_message+IpcMessage.words+8], r12
  mov qword [ipc_message+IpcMessage.words+16], r13
  mov qword [ipc_message+IpcMessage.words+24], PAGE_SIZE
  mov qword [ipc_message+IpcMessage.words+32], 0
  call fs_rpc
  test rax, rax
  jnz .error
  mov rbx, qword [ipc_reply+IpcMessage.words+8]
  test rbx, rbx
  jz .success
  mov rdi, FS_BUFFER_VA
  mov rsi, rbx
  call terminal_write
  add r13, rbx
  cmp rbx, PAGE_SIZE
  je .read
.success:
  lea rdi, [newline]
  call print_z
  log cat_ok_text, cat_ok_text.size
  jmp .done
.error:
  lea rdi, [fs_error_text]
  call print_z
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// EDI=FS_WRITE flags, RSI="NAME TEXT". write начинает файл заново, append
;// сначала запрашивает текущий размер и пишет с этого offset.
command_write:
  push rbx
  push r12
  push r13
  push r15
  mov r15, rdi
  mov r12, rsi
  mov r13, rsi
.separator:
  mov al, [r13]
  test al, al
  jz .error
  cmp al, ' '
  je .split
  inc r13
  jmp .separator
.split:
  mov byte [r13], 0
  inc r13
  mov edi, FS_LOOKUP
  mov rsi, r12
  call fs_named_request
  test rax, rax
  jnz .error
  cmp qword [ipc_reply+IpcMessage.words+16], FS_NODE_FILE
  jne .error
  mov rbx, qword [ipc_reply+IpcMessage.words+8]
  xor r12d, r12d
  test r15, FS_WRITE_TRUNCATE
  jnz .measure
  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_STAT
  mov qword [ipc_message+IpcMessage.words+8], rbx
  call fs_rpc
  test rax, rax
  jnz .error
  mov r12, qword [ipc_reply+IpcMessage.words+8]
.measure:
  xor ecx, ecx
.length:
  cmp byte [r13+rcx], 0
  je .copy
  inc ecx
  cmp rcx, 47
  jbe .length
  jmp .error
.copy:
  mov rsi, r13
  mov rdi, FS_BUFFER_VA
  push rcx
  rep movsb
  pop rdx
  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_WRITE
  mov qword [ipc_message+IpcMessage.words+8], rbx
  mov qword [ipc_message+IpcMessage.words+16], r12
  mov qword [ipc_message+IpcMessage.words+24], rdx
  mov qword [ipc_message+IpcMessage.words+32], 0
  mov qword [ipc_message+IpcMessage.words+40], r15
  call fs_rpc
  test rax, rax
  jnz .error
  lea rdi, [write_ok]
  call print_z
  log write_ok_text, write_ok_text.size
  jmp .done
.error:
  lea rdi, [fs_error_text]
  call print_z
.done:
  pop r15
  pop r13
  pop r12
  pop rbx
  ret

;// Запустить ELF64 непосредственно из текущего каталога VaraniaFS.
;// Файл целиком читается в 256-KiB окно только один раз; procd получает shared
;// capability, а не копию байтов. RDX в ответе — обычный exit status процесса.
command_run:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r15, rsi                    ;// полная строка: executable [arguments]
  mov r13, rsi
  xor r14d, r14d
.find_argument:
  mov al, [r13]
  test al, al
  jz .lookup
  cmp al, ' '
  je .split_command
  inc r13
  jmp .find_argument
.split_command:
  mov byte [r13], 0
  mov r14d, 1
.lookup:
  mov edi, FS_LOOKUP
  mov rsi, r15
  call fs_named_request
  test r14d, r14d
  jz .lookup_done
  mov byte [r13], ' '
.lookup_done:
  test rax, rax
  jnz .error
  cmp qword [ipc_reply+IpcMessage.words+16], FS_NODE_FILE
  jne .error
  mov rbx, qword [ipc_reply+IpcMessage.words+8]

  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_STAT
  mov qword [ipc_message+IpcMessage.words+8], rbx
  call fs_rpc
  test rax, rax
  jnz .error
  mov r12, qword [ipc_reply+IpcMessage.words+8]
  test r12, r12
  jz .error
  cmp r12, [filesystem_buffer_size]
  ja .too_large

  call prepare_fs_request
  mov qword [ipc_message+IpcMessage.words], FS_READ
  mov qword [ipc_message+IpcMessage.words+8], rbx
  mov qword [ipc_message+IpcMessage.words+16], 0
  mov qword [ipc_message+IpcMessage.words+24], r12
  mov qword [ipc_message+IpcMessage.words+32], 0
  call fs_rpc
  test rax, rax
  jnz .error
  cmp qword [ipc_reply+IpcMessage.words+8], r12
  jne .error

  ;// Командная строка размещается после ELF в том же shared window. Это
  ;// оставляет IPC control-plane компактным и позволяет библиотечным tools
  ;// передавать абсолютные пути существенно длиннее прежних 47 байт.
  xor r14d, r14d
.measure_command:
  cmp r14, 1023
  jae .error
  cmp byte [r15+r14], 0
  je .command_measured
  inc r14
  jmp .measure_command
.command_measured:
  inc r14                       ;// включая NUL
  mov rbx, r12
  add rbx, 15
  and rbx, -16
  mov rax, rbx
  add rax, r14
  jc .too_large
  cmp rax, [filesystem_buffer_size]
  ja .too_large
  lea rdi, [FS_BUFFER_VA+rbx]
  mov rsi, r15
  mov rcx, r14
  rep movsb

  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], PROCD_SPAWN_IMAGE
  mov qword [ipc_message+IpcMessage.words+8], r12
  mov rax, PROCD_ARGS_SHARED
  mov qword [ipc_message+IpcMessage.words+16], rax
  mov qword [ipc_message+IpcMessage.words+24], rbx
  mov qword [ipc_message+IpcMessage.words+32], r14
  mov qword [ipc_message+IpcMessage.cap_count], 2
  mov qword [ipc_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [ipc_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rax, [filesystem_buffer_cap]
  mov qword [ipc_message+IpcMessage.caps+IpcCap.bytes+IpcCap.handle], rax
  mov qword [ipc_message+IpcMessage.caps+IpcCap.bytes+IpcCap.rights], CAP_MAP+CAP_READ
  mov rdi, [process_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  test rax, rax
  jnz .error
  ipc_receive SELF_EP, ipc_reply
  test rax, rax
  jnz .error
  cmp qword [ipc_reply+IpcMessage.words], 0
  jne .error
  cmp qword [ipc_reply+IpcMessage.cap_count], 2
  jne .error
  mov r12, qword [ipc_reply+IpcMessage.caps+IpcCap.handle]
  mov r13, qword [ipc_reply+IpcMessage.caps+IpcCap.bytes+IpcCap.handle]
  mov rdi, r12
  call session_set_foreground
  test rax, rax
  jnz .terminate_untracked
  mov rdi, r12
  system_call SYS_WAIT
  mov rbx, rax
  call session_clear_foreground
  mov rdi, r12
  call close_handle
  mov rdi, r13
  call close_handle
  cmp rbx, SESSION_INTERRUPTED_STATUS
  je .interrupted
  test rbx, rbx
  jnz .error
  lea rdi, [run_ok]
  call print_z
  log run_ok_text, run_ok_text.size
  jmp .done
.terminate_untracked:
  ;// Не оставляем процесс, который нельзя независимо прервать.
  mov eax, SYS_PROCESS_KILL
  mov rdi, r12
  mov esi, SESSION_INTERRUPTED_STATUS
  syscall
  mov rdi, r12
  system_call SYS_WAIT
  mov rdi, r13
  call close_handle
  jmp .error
.interrupted:
  call terminal_clear
  lea rdi, [interrupted_user_text]
  call print_z
  log interrupted_marker, interrupted_marker.size
  jmp .done
.too_large:
  lea rdi, [elf_large_text]
  call print_z
  jmp .done
.error:
  lea rdi, [run_error_text]
  call print_z
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Делегировать sessiond только право завершения текущего foreground child.
;// WAIT capability остаётся у shell, поэтому обычный lifecycle не меняется.
session_set_foreground:
  push r12
  mov r12, rdi
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], SESSION_SET_FOREGROUND
  mov qword [ipc_message+IpcMessage.cap_count], 1
  mov qword [ipc_message+IpcMessage.caps+IpcCap.handle], r12
  mov qword [ipc_message+IpcMessage.caps+IpcCap.rights], CAP_CONTROL
  mov rdi, [session_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  pop r12
  ret

session_clear_foreground:
  lea rdi, [ipc_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [ipc_message+IpcMessage.words], SESSION_CLEAR_FOREGROUND
  mov rdi, [session_endpoint]
  lea rsi, [ipc_message]
  call send_retry
  ret

;// RSI=путь. Системный editor всегда ищется в /bin, а относительный путь
;// превращается в абсолютный относительно текущего каталога shell.
command_edit:
  push rbx
  push r12
  push r13
  mov r12, rsi
  lea rdi, [edit_command]
  lea rsi, [edit_argv0]
  mov ecx, edit_argv0.size
  rep movsb
  mov r13d, edit_argv0.size
  cmp byte [r12], '/'
  je .copy_argument
  lea rsi, [current_path]
.copy_cwd:
  mov al, [rsi]
  test al, al
  jz .cwd_ready
  cmp r13, 250
  jae .error
  mov [edit_command+r13], al
  inc r13
  inc rsi
  jmp .copy_cwd
.cwd_ready:
  cmp r13, edit_argv0.size+1      ;// root уже заканчивается '/'
  je .copy_argument
  mov byte [edit_command+r13], '/'
  inc r13
.copy_argument:
  mov al, [r12]
  cmp r13, 255
  jae .error
  mov [edit_command+r13], al
  inc r13
  inc r12
  test al, al
  jnz .copy_argument

  mov rbx, [current_node]
  mov qword [current_node], 0
  mov edi, FS_LOOKUP
  lea rsi, [bin_name]
  call fs_named_request
  test rax, rax
  jnz .restore_error
  cmp qword [ipc_reply+IpcMessage.words+16], FS_NODE_DIR
  jne .restore_error
  mov rax, qword [ipc_reply+IpcMessage.words+8]
  mov [current_node], rax
  lea rsi, [edit_command]
  call command_run
  mov [current_node], rbx
  jmp .done
.restore_error:
  mov [current_node], rbx
.error:
  lea rdi, [run_error_text]
  call print_z
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// RSI=name. Смена каталога выполняется через LOOKUP, а не через локальное
;// знание on-disk VaraniaFS. Это сохраняет команду при смене FS-драйвера.
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
  mov ecx, 48
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

close_handle:
  test rdi, rdi
  jz .done
  mov eax, SYS_CAP_CLOSE
  syscall
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
  cmp rbx, 47
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
cat_ok_text db "VARANIA:SHELL_CAT_OK", 10
.size = $-cat_ok_text
write_ok_text db "VARANIA:SHELL_WRITE_OK", 10
.size = $-write_ok_text
run_ok_text db "VARANIA:SHELL_RUN_OK", 10
.size = $-run_ok_text
interrupted_marker db "VARANIA:SHELL_INTERRUPT_OK", 10
.size = $-interrupted_marker
failed_text db "shell: fatal service or IPC error", 10
.size = $-failed_text

shell_ready db "Shell is ready. Type 'help' for commands.", 10, 10, 0
prompt_prefix db "varania:", 0
prompt_suffix db "$ ", 0
help_text db "Commands: ls, cd, mkdir, touch, cat, write, append, edit, run, pwd, clear, help", 10, 0
unknown_text db "Unknown command. Type 'help'.", 10, 0
fs_error_text db "Filesystem operation failed.", 10, 0
not_dir_text db "cd: target is not a directory.", 10, 0
path_long_text db "cd: displayed path is too long.", 10, 0
mkdir_ok db "Directory created.", 10, 0
touch_ok db "File created.", 10, 0
write_ok db "File written atomically.", 10, 0
run_ok db "Program exited successfully.", 10, 0
run_error_text db "run: cannot load ELF64 program.", 10, 0
interrupted_user_text db "Foreground program interrupted (status 130).", 10, 0
elf_large_text db "run: ELF is larger than the 256 KiB loader window.", 10, 0
slash db "/", 0
newline db 10, 0

cmd_help db "help", 0
cmd_ls db "ls", 0
cmd_pwd db "pwd", 0
cmd_clear db "clear", 0
prefix_cd db "cd ", 0
prefix_mkdir db "mkdir ", 0
prefix_touch db "touch ", 0
prefix_cat db "cat ", 0
prefix_write db "write ", 0
prefix_append db "append ", 0
prefix_edit db "edit ", 0
prefix_run db "run ", 0
edit_argv0 db "edit.elf ", 0
.size = $-edit_argv0-1
bin_name db "bin", 0

align 8
terminal_endpoint dq 0
filesystem_endpoint dq 0
process_endpoint dq 0
session_endpoint dq 0
filesystem_buffer_cap dq 0
filesystem_buffer_size dq 0
current_node dq 0
path_length dq 1
current_path db '/', 0
times PATH_CAP-2 db 0
line_buffer rb 48
edit_command rb 256
ipc_message rb IpcMessage.bytes
ipc_reply rb IpcMessage.bytes
