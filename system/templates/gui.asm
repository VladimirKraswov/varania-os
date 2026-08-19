format ELF64 executable 3
entry start
include '/system/src/user/abi.inc'
include '/system/lib/runtime.inc'

;//////////////////////////////////////////////////////////////////////////////
;// Минимальное GUI-приложение Varania OS
;//////////////////////////////////////////////////////////////////////////////
;
;// В ELF попадают только маленькие IPC stubs из libvarania. Рисование,
;// hit testing и состояние компонентов остаются в единственном gui.elf.

PANEL_ID  = 1
LABEL_ID  = 2
BUTTON_ID = 3

segment readable executable
start:
  call vlib_initialize
  test rax, rax
  jnz .failed
  call vlib_gui_connect
  test rax, rax
  jnz .failed

  mov edi, PANEL_ID
  mov edx, 390
  mov ecx, 230
  mov r8d, 500
  mov r9d, 210
  xor r10d, r10d
  xor r11d, r11d
  call vlib_ui_panel

  mov edi, LABEL_ID
  mov edx, 430
  mov ecx, 270
  mov r8d, 300
  mov r9d, 28
  xor r10d, r10d
  lea r11, [title]
  call vlib_ui_label

  mov edi, BUTTON_ID
  mov edx, 430
  mov ecx, 340
  mov r8d, 170
  mov r9d, 38
  xor r10d, r10d
  lea r11, [close_text]
  call vlib_ui_button

.events:
  call vlib_ui_wait_event
  test rax, rax
  js .destroy
  cmp rax, GUI_EVENT_ACTION
  jne .events
  cmp rdx, BUTTON_ID
  jne .events

.destroy:
  mov edi, BUTTON_ID
  call vlib_ui_destroy
  mov edi, LABEL_ID
  call vlib_ui_destroy
  mov edi, PANEL_ID
  call vlib_ui_destroy
  call vlib_shutdown
  exit_process 0

.failed:
  exit_process 1

segment readable writeable
title db 'HELLO FROM GUI ABI 1',0
close_text db 'CLOSE',0
