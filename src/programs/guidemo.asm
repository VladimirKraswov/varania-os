format ELF64 executable 3
entry start
include "../user/abi.inc"
include "../lib/runtime.inc"

;//////////////////////////////////////////////////////////////////////////////
;// Небольшой пример и end-to-end проверка событий gui.vlib
;//////////////////////////////////////////////////////////////////////////////
;
;// Программа не содержит rasterizer. Она создаёт описания компонентов, ждёт
;// semantic events на собственном endpoint и удаляет server-side state перед
;// выходом. Ярлык desktop ей не нужен: пример запускается из terminal.

PANEL_ID    = 1
LABEL_ID    = 2
CHECKBOX_ID = 3
BUTTON_ID   = 4

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
  mov r9d, 220
  xor r10d, r10d
  xor r11d, r11d
  call vlib_ui_panel

  mov edi, LABEL_ID
  mov edx, 430
  mov ecx, 270
  mov r8d, 320
  mov r9d, 28
  xor r10d, r10d
  lea r11, [title]
  call vlib_ui_label

  mov edi, CHECKBOX_ID
  mov edx, 430
  mov ecx, 320
  mov r8d, 220
  mov r9d, 28
  xor r10d, r10d
  lea r11, [check_text]
  call vlib_ui_checkbox

  mov edi, BUTTON_ID
  mov edx, 430
  mov ecx, 370
  mov r8d, 170
  mov r9d, 38
  xor r10d, r10d
  lea r11, [close_text]
  call vlib_ui_button
  log ready_text, ready_text.size

.events:
  call vlib_ui_wait_event
  test rax, rax
  js .destroy
  cmp rax, GUI_EVENT_ACTION
  jne .events
  cmp rdx, CHECKBOX_ID
  jne .button
  cmp r8, 1
  jne .events
  log state_text, state_text.size
  jmp .events
.button:
  cmp rdx, BUTTON_ID
  jne .events
  log event_text, event_text.size

.destroy:
  mov edi, BUTTON_ID
  call vlib_ui_destroy
  mov edi, CHECKBOX_ID
  call vlib_ui_destroy
  mov edi, LABEL_ID
  call vlib_ui_destroy
  mov edi, PANEL_ID
  call vlib_ui_destroy
  call vlib_shutdown
  exit_process 0

.failed:
  log failed_text, failed_text.size
  exit_process 1

segment readable writeable
title db 'GUI ABI 1 EVENT DEMO',0
check_text db 'SERVER STATE',0
close_text db 'CLOSE',0
ready_text db 'VARANIA:GUI_DEMO_READY',10
.size = $-ready_text
state_text db 'VARANIA:UI_STATE_OK',10
.size = $-state_text
event_text db 'VARANIA:UI_EVENT_OK',10
.size = $-event_text
failed_text db 'gui-demo: service failure',10
.size = $-failed_text
