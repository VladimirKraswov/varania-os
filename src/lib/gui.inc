;//////////////////////////////////////////////////////////////////////////////
;// libvarania: gui.vlib ABI 1 — только client stubs, renderer живёт в gui.elf
;//////////////////////////////////////////////////////////////////////////////

VLIB_GUI_ABI = 1

segment readable executable

vlib_gui_connect:
  mov edi, SERVICE_GUI
  mov esi, VLIB_GUI_ABI
  call vlib_open
  test rax, rax
  js .done
  mov [vlib_gui_endpoint], rax
  xor eax, eax
.done:
  ret

;// Завершить client session и удалить все принадлежащие sender widgets.
;// В отличие от process teardown это явный нормальный lifecycle сервиса.
vlib_gui_disconnect:
  cmp qword [vlib_gui_endpoint], 0
  je .done
  mov edi, GUI_CLIENT_CLOSE
  call vlib_gui_command
  mov rdi, [vlib_gui_endpoint]
  call vlib_close
  mov qword [vlib_gui_endpoint], 0
.done:
  ret

;// RDI=command. Простые lifecycle-команды не требуют ответа.
vlib_gui_command:
  push r12
  mov r12, rdi
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], r12
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r12
  ret

vlib_gui_desktop_enter:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_DESKTOP_ENTER
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  ipc_receive VLIB_SELF_EP, vlib_reply
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words]
.done:
  ret

vlib_gui_desktop_leave:
  mov edi, GUI_DESKTOP_LEAVE
  jmp vlib_gui_command

vlib_gui_terminal_open:
  mov edi, GUI_TERMINAL_OPEN
  jmp vlib_gui_command

vlib_gui_terminal_close:
  mov edi, GUI_TERMINAL_CLOSE
  jmp vlib_gui_command

;// EDI=GUI_ROLE_*. RAX=semantic event/error.
vlib_gui_wait_event:
  push r12
  mov r12d, edi
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_EVENT_WAIT
  mov qword [vlib_message+IpcMessage.words+8], r12
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  ipc_receive VLIB_SELF_EP, vlib_reply
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words]
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words+8]
.done:
  pop r12
  ret

;// Создать server-side компонент.
;// RDI=id, RSI=UI_*, EDX=x, ECX=y, R8D=w, R9D=h, R10=state,
;// R11 -> NUL text (копируются первые 16 bytes). RAX=send status.
vlib_ui_create:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov rbx, rdi
  mov r12, rsi
  mov r13d, edx
  mov r14d, ecx
  mov r15d, r8d
  mov edx, r9d
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_WIDGET_CREATE
  mov qword [vlib_message+IpcMessage.words+8], rbx
  mov qword [vlib_message+IpcMessage.words+16], r12
  mov eax, r14d
  shl rax, 32
  or rax, r13
  mov qword [vlib_message+IpcMessage.words+24], rax
  mov eax, edx
  shl rax, 32
  or rax, r15
  mov qword [vlib_message+IpcMessage.words+32], rax
  mov qword [vlib_message+IpcMessage.words+40], r10
  test r11, r11
  jz .send
  lea rdi, [vlib_message+IpcMessage.words+48]
  mov rsi, r11
  mov ecx, 15
.text:
  lodsb
  stosb
  test al, al
  jz .send
  loop .text
.send:
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// Конструкторы сохраняют единый ABI vlib_ui_create, но на стороне приложения
;// выглядят как обычные функции. Ни один из них не содержит renderer.
macro define_ui_constructor routine, component
{
routine:
  mov esi, component
  jmp vlib_ui_create
}

define_ui_constructor vlib_ui_button,      UI_BUTTON
define_ui_constructor vlib_ui_radio,       UI_RADIO
define_ui_constructor vlib_ui_toggle,      UI_TOGGLE
define_ui_constructor vlib_ui_checkbox,    UI_CHECKBOX
define_ui_constructor vlib_ui_text_edit,   UI_TEXT_EDIT
define_ui_constructor vlib_ui_scroll_view, UI_SCROLL_VIEW
define_ui_constructor vlib_ui_list_view,   UI_LIST_VIEW
define_ui_constructor vlib_ui_tabs,        UI_TABS
define_ui_constructor vlib_ui_panel,       UI_PANEL
define_ui_constructor vlib_ui_icon_button, UI_ICON_BUTTON
define_ui_constructor vlib_ui_label,       UI_LABEL
define_ui_constructor vlib_ui_image,       UI_IMAGE

;// RDI=id, EDX=x, ECX=y, R8D=w, R9D=h, R10=state, R11=text.
vlib_ui_update:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov rbx, rdi
  mov r12d, edx
  mov r13d, ecx
  mov r14d, r8d
  mov r15d, r9d
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_WIDGET_UPDATE
  mov qword [vlib_message+IpcMessage.words+8], rbx
  mov eax, r13d
  shl rax, 32
  or rax, r12
  mov qword [vlib_message+IpcMessage.words+24], rax
  mov eax, r15d
  shl rax, 32
  or rax, r14
  mov qword [vlib_message+IpcMessage.words+32], rax
  mov qword [vlib_message+IpcMessage.words+40], r10
  test r11, r11
  jz .send
  lea rdi, [vlib_message+IpcMessage.words+48]
  mov rsi, r11
  mov ecx, 15
.text:
  lodsb
  stosb
  test al, al
  jz .send
  loop .text
.send:
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=id.
vlib_ui_destroy:
  push r12
  mov r12, rdi
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_WIDGET_DESTROY
  mov qword [vlib_message+IpcMessage.words+8], r12
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r12
  ret

;// Блокироваться до semantic action над компонентом этого процесса.
;// RAX=GUI_EVENT_ACTION/error, RDX=widget id, RCX=UI_*, R8=новое state.
;// Reply endpoint передаётся capability, поэтому GUI не получает скрытого
;// глобального callback и не может ответить чужому приложению.
vlib_ui_wait_event:
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_WIDGET_EVENT_WAIT
  mov qword [vlib_message+IpcMessage.cap_count], 1
  mov qword [vlib_message+IpcMessage.caps+IpcCap.handle], VLIB_SELF_EP
  mov qword [vlib_message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  test rax, rax
  jnz .done
  ipc_receive VLIB_SELF_EP, vlib_reply
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words]
  test rax, rax
  jnz .done
  mov rax, qword [vlib_reply+IpcMessage.words+8]
  mov rdx, qword [vlib_reply+IpcMessage.words+16]
  mov rcx, qword [vlib_reply+IpcMessage.words+24]
  mov r8, qword [vlib_reply+IpcMessage.words+32]
.done:
  ret

;// EDI=shortcut type, ESI=x, EDX=y.
vlib_gui_shortcut_add:
  push r12
  push r13
  push r14
  mov r12d, edi
  mov r13d, esi
  mov r14d, edx
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_SHORTCUT_ADD
  mov qword [vlib_message+IpcMessage.words+8], r12
  mov eax, r14d
  shl rax, 32
  or rax, r13
  mov qword [vlib_message+IpcMessage.words+16], rax
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r14
  pop r13
  pop r12
  ret

;// EDI=index, ESI=x, EDX=y.
vlib_gui_shortcut_move:
  push r12
  push r13
  push r14
  mov r12d, edi
  mov r13d, esi
  mov r14d, edx
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_SHORTCUT_MOVE
  mov qword [vlib_message+IpcMessage.words+8], r12
  mov eax, r14d
  shl rax, 32
  or rax, r13
  mov qword [vlib_message+IpcMessage.words+16], rax
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r14
  pop r13
  pop r12
  ret

;// EDI=index (system shortcuts 0 и 1 защищены server policy).
vlib_gui_shortcut_remove:
  push r12
  mov r12d, edi
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_SHORTCUT_REMOVE
  mov qword [vlib_message+IpcMessage.words+8], r12
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r12
  ret

;// EDI=1 generated wallpaper, 2 procedural low-contrast wallpaper.
vlib_gui_set_wallpaper:
  push r12
  mov r12d, edi
  lea rdi, [vlib_message]
  mov ecx, IpcMessage.bytes
  call vlib_zero
  mov qword [vlib_message+IpcMessage.words], GUI_SET_WALLPAPER
  mov qword [vlib_message+IpcMessage.words+8], r12
  mov rdi, [vlib_gui_endpoint]
  lea rsi, [vlib_message]
  call vlib_send_retry
  pop r12
  ret
