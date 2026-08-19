;//////////////////////////////////////////////////////////////////////////////
;// Platform layer FASM 1.73.35 для Varania OS
;//////////////////////////////////////////////////////////////////////////////
;
;// Официальный x64 front end вызывает маленькое Linux-подобное подмножество.
;// Здесь оно переводится в capabilities и IPC:
;//
;//   open/read/write/lseek -> VaraniaFS endpoint + 256-KiB shared window
;//   stdout/stderr         -> terminal endpoint
;//   brk                   -> demand-paged heap микроядра
;//   exit                  -> завершение процесса
;//
;// Никакой код файловой системы не встроен в компилятор. FASM остаётся обычной
;// ring-3 программой и может быть перезапущен/заменён без изменения ядра.

SYS_LOG             = 1
SYS_YIELD           = 2
SYS_EXIT            = 5
SYS_BRK              = 11
SYS_IPC_SEND         = 14
SYS_IPC_RECV         = 15
SYS_SHARED_MAP       = 26

CAP_SEND             = 1
CAP_READ             = 2
CAP_WRITE            = 4
CAP_MAP              = 64

SELF_EP              = 1
NAMESERVER_EP        = 2
NAMESERVER_LOOKUP    = 2
SERVICE_TERMINAL     = 2
SERVICE_FILESYSTEM   = 3

TERM_WRITE           = 1
FS_LOOKUP            = 2
FS_CREATE            = 4
FS_ATTACH            = 5
FS_READ              = 6
FS_WRITE             = 7
FS_STAT              = 8
FS_DETACH            = 9
FS_WRITE_TRUNCATE     = 1
FS_NODE_FILE         = 1

SPACE_MAP_WRITE      = 1
PAGE_SIZE            = 4096
FS_BUFFER_BYTES      = 64*PAGE_SIZE
FASM_FS_VA           = 0x0000000068000000
FD_COUNT             = 16
FD_TRUNCATE_PENDING  = 1
IPC_WOULD_BLOCK      = -11

IPC_WORD_COUNT       = 8
IPC_CAP_COUNT        = 2
IpcMessage.words     = 0
IpcCap.handle        = 0
IpcCap.rights        = 8
IpcCap.bytes         = 16
IpcMessage.cap_count = IPC_WORD_COUNT*8
IpcMessage.caps      = IpcMessage.cap_count+8
IpcMessage.sender    = IpcMessage.caps+IPC_CAP_COUNT*IpcCap.bytes
IpcMessage.bytes     = IpcMessage.sender+8

;// Выполнить настоящий Varania syscall, не попадая повторно в Linux shim.
macro vos_call number
{
  mov eax, number
  db 0Fh,05h
}

;// modes.inc переводит assembler core в 32-bit pointer mode и временно
;// подменяет push/pop/call. Platform ABI использует полноценные регистры x64.
purge push,pop,jmp,call,salc,jcxz
use64

segment readable executable

;// Вход соответствует Linux x86-64 syscall ABI. Это позволяет не менять
;// upstream system.inc и одновременно делает список зависимостей явным.
platform_linux_syscall:
  cmp eax, 0
  je .read
  cmp eax, 1
  je .write
  cmp eax, 2
  je .open
  cmp eax, 3
  je .close
  cmp eax, 8
  je .lseek
  cmp eax, 9
  je .mmap
  cmp eax, 11
  je .munmap
  cmp eax, 12
  je .brk
  cmp eax, 60
  je .exit
  cmp eax, 96
  je .gettimeofday
  cmp eax, 201
  je .time
  mov rax, -38
  ret
.read:
  jmp vos_file_read
.write:
  cmp edi, 2
  jbe vos_console_write
  jmp vos_file_write
.open:
  jmp vos_file_open
.close:
  jmp vos_file_close
.lseek:
  jmp vos_file_seek
.mmap:
  mov rax, -1                    ;// brk всегда доступен ниже 4 GiB
  ret
.munmap:
  xor eax, eax
  ret
.brk:
  vos_call SYS_BRK
  ret
.exit:
  push rdi
  call platform_shutdown
  pop rdi
  vos_call SYS_EXIT
  ud2
.gettimeofday:
  test rdi, rdi
  jz .time_ok
  mov qword [rdi], 0
  mov qword [rdi+8], 0
.time_ok:
  xor eax, eax
  ret
.time:
  test rdi, rdi
  jz .time_value
  mov qword [rdi], 0
.time_value:
  xor eax, eax
  ret

;// Ленивый init нужен потому, что upstream печатает logo до init_memory.
;// RAX=0/error.
platform_initialize:
  cmp byte [platform_ready], 1
  je .ready
  mov byte [platform_ready], 2
  mov edi, SERVICE_TERMINAL
  call lookup_service
  test rax, rax
  js .failed
  mov [terminal_endpoint], rax
  mov edi, SERVICE_FILESYSTEM
  call lookup_service
  test rax, rax
  js .failed
  mov [filesystem_endpoint], rax
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_ATTACH
  call fs_rpc
  test rax, rax
  jnz .failed
  cmp qword [platform_reply+IpcMessage.cap_count], 1
  jne .failed
  mov rdi, qword [platform_reply+IpcMessage.caps+IpcCap.handle]
  mov [filesystem_buffer_cap], rdi
  mov rsi, FASM_FS_VA
  mov edx, SPACE_MAP_WRITE
  vos_call SYS_SHARED_MAP
  test rax, rax
  js .failed
  mov byte [platform_ready], 1
.ready:
  xor eax, eax
  ret
.failed:
  mov byte [platform_ready], 0
  mov rax, -5
  ret

;// Вернуть VFS session slot перед нормальным exit. Address-space teardown
;// снимет mapping FASM, а DETACH сразу снимает mapping/handle на стороне VFS.
platform_shutdown:
  cmp byte [platform_ready], 1
  jne .done
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_DETACH
  call fs_rpc
  mov byte [platform_ready], 0
.done:
  ret

;// EDI=service ID, RAX=endpoint/error.
lookup_service:
  push rbx
  mov ebx, edi
.retry:
  lea rdi, [platform_message]
  mov ecx, IpcMessage.bytes
  call zero_platform_bytes
  mov qword [platform_message+IpcMessage.words], NAMESERVER_LOOKUP
  mov qword [platform_message+IpcMessage.words+8], rbx
  mov qword [platform_message+IpcMessage.cap_count], 1
  mov qword [platform_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [platform_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov edi, NAMESERVER_EP
  lea rsi, [platform_message]
  call send_retry
  test rax, rax
  jnz .done
  mov edi, SELF_EP
  lea rsi, [platform_reply]
  vos_call SYS_IPC_RECV
  test rax, rax
  jnz .done
  cmp qword [platform_reply+IpcMessage.words], 0
  je .found
  vos_call SYS_YIELD
  jmp .retry
.found:
  cmp qword [platform_reply+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [platform_reply+IpcMessage.caps+IpcCap.handle]
  jmp .done
.invalid:
  mov rax, -22
.done:
  pop rbx
  ret

;// Linux write(fd=1/2, buffer, bytes). Возвращает исходное число байтов.
vos_console_write:
  push rbx
  push r12
  push r13
  push r14
  mov r12, rsi
  mov r13, rdx
  mov r14, rdx
  call platform_initialize
  test rax, rax
  jnz .debug_fallback
.chunk:
  test r13, r13
  jz .success
  mov rbx, r13
  cmp rbx, 16
  jbe .size_ready
  mov ebx, 16
.size_ready:
  lea rdi, [platform_message]
  mov ecx, IpcMessage.bytes
  call zero_platform_bytes
  mov qword [platform_message+IpcMessage.words], TERM_WRITE
  mov qword [platform_message+IpcMessage.words+8], rbx
  lea rdi, [platform_message+IpcMessage.words+16]
  mov rsi, r12
  mov rcx, rbx
  rep movsb
  mov rdi, [terminal_endpoint]
  lea rsi, [platform_message]
  call send_retry
  test rax, rax
  jnz .error
  add r12, rbx
  sub r13, rbx
  jmp .chunk
.debug_fallback:
  mov rdi, r12
  mov rsi, r13
  cmp rsi, 256
  jbe .debug_size
  mov esi, 256
.debug_size:
  vos_call SYS_LOG
  test rax, rax
  jnz .error
.success:
  mov rax, r14
  jmp .done
.error:
  mov rax, -5
.done:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Linux open(path, flags, mode). FASM использует только read-only и
;// create+truncate, но таблица descriptor сохраняет обычные offset/size.
vos_file_open:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12, rdi                    ;// path
  mov r13, rsi                    ;// Linux flags
  call platform_initialize
  test rax, rax
  jnz .failed
  mov rdi, r12
  call resolve_path
  mov r14, rax                    ;// object/error
  mov r15, rdx                    ;// kind
  test r13, 0100o                 ;// O_CREAT
  jz .existing
  test r14, r14
  jns .existing
  cmp r14, -2
  jne .failed
  mov rdi, r12
  call create_path
  mov r14, rax
  mov r15d, FS_NODE_FILE
.existing:
  test r14, r14
  js .failed
  cmp r15, FS_NODE_FILE
  jne .failed
  call allocate_fd
  test rax, rax
  js .done
  mov rbx, rax
  mov [fd_object+rbx*8], r14
  mov qword [fd_position+rbx*8], 0
  mov qword [fd_size+rbx*8], 0
  mov qword [fd_flags+rbx*8], 0
  test r13, 0100o
  jz .read_size
  mov qword [fd_flags+rbx*8], FD_TRUNCATE_PENDING
  jmp .opened
.read_size:
  mov rdi, r14
  call stat_object
  test rax, rax
  js .release_fd
  mov [fd_size+rbx*8], rdx
.opened:
  mov rax, rbx
  jmp .done
.release_fd:
  mov qword [fd_object+rbx*8], 0
.failed:
  mov rax, -2
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Linux close(fd).
vos_file_close:
  cmp edi, 3
  jb .bad
  cmp edi, FD_COUNT
  jae .bad
  cmp qword [fd_object+rdi*8], 0
  je .bad
  mov qword [fd_object+rdi*8], 0
  mov qword [fd_position+rdi*8], 0
  mov qword [fd_size+rdi*8], 0
  mov qword [fd_flags+rdi*8], 0
  xor eax, eax
  ret
.bad:
  mov rax, -9
  ret

;// Linux read(fd, destination, bytes), потоками не больше shared window.
vos_file_read:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov ebx, edi
  mov r12, rsi
  mov r13, rdx
  xor r14d, r14d
  call validate_fd
  test rax, rax
  js .error
.chunk:
  cmp r14, r13
  jae .success
  mov r15, r13
  sub r15, r14
  cmp r15, FS_BUFFER_BYTES
  jbe .size_ready
  mov r15d, FS_BUFFER_BYTES
.size_ready:
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_READ
  mov rax, [fd_object+rbx*8]
  mov qword [platform_message+IpcMessage.words+8], rax
  mov rax, [fd_position+rbx*8]
  mov qword [platform_message+IpcMessage.words+16], rax
  mov qword [platform_message+IpcMessage.words+24], r15
  mov qword [platform_message+IpcMessage.words+32], 0
  call fs_rpc
  test rax, rax
  jnz .error
  mov r15, qword [platform_reply+IpcMessage.words+8]
  test r15, r15
  jz .success
  lea rdi, [r12+r14]
  mov rsi, FASM_FS_VA
  mov rcx, r15
  rep movsb
  add [fd_position+rbx*8], r15
  add r14, r15
  jmp .chunk
.success:
  mov rax, r14
  jmp .done
.error:
  mov rax, -5
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Linux write(fd, source, bytes). Первый chunk после create несёт TRUNCATE,
;// остальные являются обычными offset writes — именно здесь нужен streaming.
vos_file_write:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov ebx, edi
  mov r12, rsi
  mov r13, rdx
  xor r14d, r14d
  call validate_fd
  test rax, rax
  js .error
.chunk:
  cmp r14, r13
  jae .success
  mov r15, r13
  sub r15, r14
  cmp r15, FS_BUFFER_BYTES
  jbe .size_ready
  mov r15d, FS_BUFFER_BYTES
.size_ready:
  mov rsi, r12
  add rsi, r14
  mov rdi, FASM_FS_VA
  mov rcx, r15
  rep movsb
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_WRITE
  mov rax, [fd_object+rbx*8]
  mov qword [platform_message+IpcMessage.words+8], rax
  mov rax, [fd_position+rbx*8]
  mov qword [platform_message+IpcMessage.words+16], rax
  mov qword [platform_message+IpcMessage.words+24], r15
  mov qword [platform_message+IpcMessage.words+32], 0
  mov rax, [fd_flags+rbx*8]
  and eax, FD_TRUNCATE_PENDING
  mov qword [platform_message+IpcMessage.words+40], rax
  call fs_rpc
  test rax, rax
  jnz .error
  mov qword [fd_flags+rbx*8], 0
  add [fd_position+rbx*8], r15
  mov rax, [fd_position+rbx*8]
  cmp rax, [fd_size+rbx*8]
  jbe .position_done
  mov [fd_size+rbx*8], rax
.position_done:
  add r14, r15
  jmp .chunk
.success:
  mov rax, r14
  jmp .done
.error:
  mov rax, -5
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Linux lseek(fd, signed offset, whence).
vos_file_seek:
  push rbx
  mov ebx, edi
  call validate_fd
  test rax, rax
  js .bad
  cmp edx, 0
  je .absolute
  cmp edx, 1
  je .current
  cmp edx, 2
  je .end
  jmp .bad
.absolute:
  mov rax, rsi
  jmp .check
.current:
  mov rax, [fd_position+rbx*8]
  add rax, rsi
  jmp .check
.end:
  mov rax, [fd_size+rbx*8]
  add rax, rsi
.check:
  js .bad
  mov [fd_position+rbx*8], rax
  pop rbx
  ret
.bad:
  mov rax, -1
  pop rbx
  ret

validate_fd:
  cmp ebx, 3
  jb .bad
  cmp ebx, FD_COUNT
  jae .bad
  cmp qword [fd_object+rbx*8], 0
  je .bad
  xor eax, eax
  ret
.bad:
  mov rax, -9
  ret

allocate_fd:
  mov eax, 3
.scan:
  cmp eax, FD_COUNT
  jae .full
  cmp qword [fd_object+rax*8], 0
  je .done
  inc eax
  jmp .scan
.full:
  mov rax, -24
.done:
  ret

;// RDI=path. RAX=object/error, RDX=kind. Relative paths считаются от root.
resolve_path:
  push rbx
  push r12
  push r13
  mov r12, rdi
  xor ebx, ebx                    ;// root object encoded as 0 in protocol
.skip_slash:
  cmp byte [r12], '/'
  jne .component_or_end
  inc r12
  jmp .skip_slash
.component_or_end:
  cmp byte [r12], 0
  je .root_or_last
  xor r13d, r13d
.copy:
  mov al, [r12]
  test al, al
  jz .component_ready
  cmp al, '/'
  je .component_ready
  cmp r13, 47
  jae .invalid
  mov [path_component+r13], al
  inc r13
  inc r12
  jmp .copy
.component_ready:
  mov byte [path_component+r13], 0
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_LOOKUP
  mov qword [platform_message+IpcMessage.words+8], rbx
  lea rdi, [platform_message+IpcMessage.words+16]
  lea rsi, [path_component]
  mov ecx, 48
  rep movsb
  call fs_rpc
  test rax, rax
  jnz .done
  mov rbx, qword [platform_reply+IpcMessage.words+8]
  mov rdx, qword [platform_reply+IpcMessage.words+16]
  jmp .skip_slash
.root_or_last:
  mov rax, rbx
  test rbx, rbx
  jnz .done
  mov edx, 2                     ;// root is a directory
  jmp .done
.invalid:
  mov rax, -22
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=полный path отсутствующего файла. RAX=new object/error.
create_path:
  push rbx
  push r12
  push r13
  mov r12, rdi
  lea rdi, [path_work]
  xor ebx, ebx                    ;// last slash offset+1, 0 если его нет
  xor ecx, ecx
.copy:
  cmp ecx, 1023
  jae .invalid
  mov al, [r12+rcx]
  mov [rdi+rcx], al
  test al, al
  jz .copied
  cmp al, '/'
  jne .next
  lea ebx, [ecx+1]
.next:
  inc ecx
  jmp .copy
.copied:
  test ecx, ecx
  jz .invalid
  test ebx, ebx
  jz .root_parent
  cmp ebx, ecx
  jae .invalid
  lea r13, [path_work+rbx]        ;// basename
  cmp ebx, 1
  je .keep_root_slash
  mov byte [path_work+rbx-1], 0
  jmp .resolve_parent
.keep_root_slash:
  mov byte [path_work+1], 0
.resolve_parent:
  lea rdi, [path_work]
  call resolve_path
  test rax, rax
  js .done
  cmp rdx, 2
  jne .invalid
  mov rbx, rax
  jmp .create
.root_parent:
  xor ebx, ebx
  lea r13, [path_work]
.create:
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_CREATE
  mov qword [platform_message+IpcMessage.words+8], rbx
  lea rdi, [platform_message+IpcMessage.words+16]
  mov rsi, r13
  mov ecx, 48
.name:
  lodsb
  stosb
  test al, al
  jz .send
  dec ecx
  jnz .name
  jmp .invalid
.send:
  call fs_rpc
  test rax, rax
  jnz .done
  mov rax, qword [platform_reply+IpcMessage.words+8]
  jmp .done
.invalid:
  mov rax, -22
.done:
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=object. RAX=status, RDX=size.
stat_object:
  push rbx
  mov rbx, rdi
  call prepare_fs_request
  mov qword [platform_message+IpcMessage.words], FS_STAT
  mov qword [platform_message+IpcMessage.words+8], rbx
  call fs_rpc
  mov rdx, qword [platform_reply+IpcMessage.words+8]
  pop rbx
  ret

prepare_fs_request:
  lea rdi, [platform_message]
  mov ecx, IpcMessage.bytes
  call zero_platform_bytes
  mov qword [platform_message+IpcMessage.cap_count], 1
  mov qword [platform_message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [platform_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ret

fs_rpc:
  mov rdi, [filesystem_endpoint]
  lea rsi, [platform_message]
  call send_retry
  test rax, rax
  jnz .done
  mov edi, SELF_EP
  lea rsi, [platform_reply]
  vos_call SYS_IPC_RECV
  test rax, rax
  jnz .done
  mov rax, qword [platform_reply+IpcMessage.words]
.done:
  ret

send_retry:
  push r12
  push r13
  mov r12, rdi
  mov r13, rsi
.again:
  mov rdi, r12
  mov rsi, r13
  vos_call SYS_IPC_SEND
  cmp rax, IPC_WOULD_BLOCK
  jne .done
  vos_call SYS_YIELD
  jmp .again
.done:
  pop r13
  pop r12
  ret

zero_platform_bytes:
  xor eax, eax
  rep stosb
  ret

segment readable writeable
align 8
platform_ready db 0
align 8
terminal_endpoint dq 0
filesystem_endpoint dq 0
filesystem_buffer_cap dq 0
fd_object rq FD_COUNT
fd_position rq FD_COUNT
fd_size rq FD_COUNT
fd_flags rq FD_COUNT
path_component rb 48
path_work rb 1024
platform_message rb IpcMessage.bytes
platform_reply rb IpcMessage.bytes
