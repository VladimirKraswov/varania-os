;//////////////////////////////////////////////////////////////////////////////
;// Пользовательский ABI Varania OS
;//////////////////////////////////////////////////////////////////////////////
;
;// Программы собираются как обычные ELF64 ET_EXEC. Соглашение syscall близко
;// к System V/Linux: номер в RAX, аргументы в RDI, RSI, RDX, R10, R8, R9.
;// Этот файл намеренно не содержит зависимостей от внутренних структур ядра.

SYS_LOG       = 1
SYS_YIELD     = 2
SYS_SEND      = 3
SYS_RECV      = 4
SYS_EXIT      = 5
SYS_IO_READ8  = 6
SYS_IO_WRITE8 = 7
SYS_IRQ_WAIT  = 8
SYS_SPAWN     = 9
SYS_WAIT      = 10
SYS_BRK       = 11
SYS_MEM_INFO  = 12

CAP_SEND  = 1
CAP_READ  = 2
CAP_WRITE = 4
CAP_WAIT  = 8

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
