;//////////////////////////////////////////////////////////////////////////////
;// Пользовательский ABI Varania OS
;//////////////////////////////////////////////////////////////////////////////
;
;// Программы собираются как обычные ELF64 ET_EXEC. Соглашение syscall близко
;// к System V/Linux: номер в RAX, аргументы в RDI, RSI, RDX, R10, R8, R9.
;// Этот файл намеренно не содержит зависимостей от внутренних структур ядра.

SYS_LOG       = 1
SYS_YIELD     = 2
SYS_EXIT      = 5
SYS_IO_READ8  = 6
SYS_IO_WRITE8 = 7
SYS_IRQ_WAIT  = 8
SYS_WAIT      = 10
SYS_BRK       = 11
SYS_MEM_INFO  = 12
SYS_ENDPOINT_CREATE = 13
SYS_IPC_SEND        = 14
SYS_IPC_RECV        = 15
SYS_SPACE_CREATE    = 16
SYS_FRAME_ALLOC     = 17
SYS_FRAME_WRITE     = 18
SYS_SPACE_MAP       = 19
SYS_THREAD_CREATE   = 20
SYS_THREAD_START    = 21
SYS_CAP_CLOSE       = 22
SYS_BOOTFS_INFO     = 23
SYS_PROCESS_KILL    = 24
SYS_SHARED_CREATE   = 25
SYS_SHARED_MAP      = 26
SYS_CAP_REVOKE      = 27
SYS_MMIO_MAP        = 28
SYS_IO_READ32       = 29
SYS_IO_WRITE32      = 30
SYS_MMIO_CREATE     = 31
SYS_DMA_CREATE      = 32
SYS_SHARED_UNMAP    = 33

CAP_SEND  = 1
CAP_READ  = 2
CAP_WRITE = 4
CAP_WAIT  = 8
CAP_CONTROL = 32
CAP_MAP     = 64
CAP_CREATE  = 128
CAP_RECV    = 256
CAP_MOVE    = 1 shl 63

SPACE_MAP_WRITE = 1
SPACE_MAP_EXEC  = 2

IPC_WORD_COUNT = 8
IPC_CAP_COUNT  = 2
IpcMessage.words     = 0
IpcCap.handle        = 0
IpcCap.rights        = 8
IpcCap.bytes         = 16
IpcMessage.cap_count = IPC_WORD_COUNT*8
IpcMessage.caps      = IpcMessage.cap_count+8
IpcMessage.sender    = IpcMessage.caps+IPC_CAP_COUNT*IpcCap.bytes
IpcMessage.bytes     = IpcMessage.sender+8

SpawnGrant.handle = 0
SpawnGrant.rights = 8
SpawnGrant.bytes  = 16

ThreadConfig.entry       = 0
ThreadConfig.stack_top   = 8
ThreadConfig.stack_low   = 16
ThreadConfig.stack_limit = 24
ThreadConfig.brk_base    = 32
ThreadConfig.grant_count = 40
ThreadConfig.grants      = 48
ThreadConfig.bytes       = ThreadConfig.grants+4*SpawnGrant.bytes

USER_STACK_TOP   = 0x00007FFFFFF00000
USER_STACK_LIMIT = USER_STACK_TOP-16*PAGE_SIZE

PROCD_SPAWN       = 1            ;// ELF из bootstrap initramfs по имени
PROCD_SPAWN_IMAGE = 2            ;// ELF в переданном shared-memory объекте
PROCD_CONFIGURE   = 3            ;// одноразовый bootstrap: endpoint nameserver
;// Расширенная командная строка лежит после ELF в том же shared window.
;// words[3]=offset, words[4]=bytes including NUL. Это снимает старый лимит
;// 47 байт, не добавляя третью capability в IPC-сообщение.
PROCD_ARGS_SHARED = 0x5652414E49414152
NAMESERVER_REGISTER = 1
NAMESERVER_LOOKUP   = 2

SERVICE_DEMO     = 1
SERVICE_TERMINAL = 2
SERVICE_RAMFS    = 3
SERVICE_FILESYSTEM = 3           ;// совместимый ID постоянного VFS-сервиса
SERVICE_BLOCK    = 4
SERVICE_PROCESS  = 5

BLOCK_ATTACH = 1
BLOCK_READ   = 2
BLOCK_WRITE  = 3
BLOCK_FLUSH  = 4

TERM_WRITE    = 1
TERM_KEY      = 2
TERM_READLINE = 3
TERM_CLEAR    = 4
TERM_READKEY  = 5
TERM_DRAW     = 6

;// Значение TERM_KEY/TERM_READKEY: младшие 32 бита — Unicode/служебный key,
;// старшие биты — независимые модификаторы. Пока раскладка ASCII, но формат
;// не придётся менять при появлении полноценного input method.
KEY_UP       = 0x100
KEY_DOWN     = 0x101
KEY_LEFT     = 0x102
KEY_RIGHT    = 0x103
KEY_HOME     = 0x104
KEY_END      = 0x105
KEY_DELETE   = 0x106
KEY_PAGE_UP  = 0x107
KEY_PAGE_DOWN = 0x108
KEY_INSERT   = 0x109
KEY_F1       = 0x201
KEY_F2       = 0x202
KEY_F3       = 0x203
KEY_F4       = 0x204
KEY_F5       = 0x205
KEY_F6       = 0x206
KEY_F7       = 0x207
KEY_F8       = 0x208
KEY_F9       = 0x209
KEY_F10      = 0x20A
KEY_MOD_SHIFT = 1 shl 32
KEY_MOD_CTRL  = 1 shl 33
KEY_MOD_ALT   = 1 shl 34

FS_LIST   = 1
FS_LOOKUP = 2
FS_MKDIR  = 3
FS_CREATE = 4
FS_ATTACH = 5
FS_READ   = 6
FS_WRITE  = 7
FS_STAT   = 8
FS_DETACH = 9
;// Обычная WRITE сохраняет байты вне записываемого диапазона. TRUNCATE
;// начинает новое содержимое и публикует его одной COW-транзакцией.
FS_WRITE_TRUNCATE = 1
FS_NODE_FILE = 1
FS_NODE_DIR  = 2

PAGE_SIZE = 4096

;// Компактные обёртки делают код похожим на вызовы функций, но оставляют
;// регистровый ABI на виду. Для вызовов с аргументами регистры заполняются
;// перед макросом — это полезнее для обучения, чем скрытая псевдомагия.
macro system_call number
{
  mov eax, number
  syscall
}

macro log address, bytes
{
  mov eax, SYS_LOG
  lea rdi, [address]
  mov esi, bytes
  syscall
}

macro exit_process code
{
  mov eax, SYS_EXIT
  mov edi, code
  syscall
}

;// Эти небольшие wrappers оставляют ABI видимым, но убирают повторение
;// последовательностей mov/syscall из прикладных программ.
macro ipc_send endpoint, message
{
  mov eax, SYS_IPC_SEND
  mov edi, endpoint
  lea rsi, [message]
  syscall
}

macro ipc_receive endpoint, message
{
  mov eax, SYS_IPC_RECV
  mov edi, endpoint
  lea rsi, [message]
  syscall
}

macro close_cap handle
{
  mov eax, SYS_CAP_CLOSE
  mov rdi, handle
  syscall
}
