;//////////////////////////////////////////////////////////////////////////////
;// libvarania umbrella: base + IPC + terminal + VFS + process
;//////////////////////////////////////////////////////////////////////////////
;
;// До include этого файла программа должна include user/abi.inc. Публичные
;// процедуры имеют префикс vlib_, принимают System V-регистры и возвращают
;// отрицательный errno в RAX. Это стабильный учебный ABI 1.

include "base.inc"
include "ipc.inc"
include "terminal.inc"
include "vfs.inc"
include "process.inc"

segment readable executable

;// Подключить минимальный runtime обычного интерактивного приложения.
vlib_initialize:
  call vlib_terminal_connect
  test rax, rax
  jnz .done
  call vlib_fs_connect
  test rax, rax
  jnz .done
  call vlib_process_connect
.done:
  ret

vlib_shutdown:
  call vlib_fs_disconnect
  ret

segment readable writeable
align 8
vlib_terminal_endpoint dq 0
vlib_fs_endpoint dq 0
vlib_process_endpoint dq 0
vlib_fs_buffer_cap dq 0
vlib_path_component rb 48
vlib_path_work rb VLIB_PATH_MAX+1
vlib_message rb IpcMessage.bytes
vlib_reply rb IpcMessage.bytes
