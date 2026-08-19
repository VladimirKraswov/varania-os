format ELF64 executable 3
entry start
include "abi.inc"

;// Тестовая задача сразу блокируется в IPC. Supervisor завершает её извне;
;// этим проверяется не только SYS_PROCESS_KILL, но и снятие endpoint waiter.
SELF_EP = 1

segment readable executable
start:
  ipc_receive SELF_EP, message
  ;// Без внешнего kill эта строка недостижима.
  exit_process 99

segment readable writeable
align 8
message rb IpcMessage.bytes
