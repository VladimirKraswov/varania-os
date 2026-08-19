format ELF64 executable 3
entry start
include "abi.inc"

;//////////////////////////////////////////////////////////////////////////////
;// Varania GUI server: video driver, compositor, window manager и UI runtime
;//////////////////////////////////////////////////////////////////////////////
;
;// Это один user-space сервер, а не код, статически размноженный по программам.
;// Он один отображает capability линейного framebuffer, хранит backbuffer,
;// окна, widgets и pointer focus. Клиенты вызывают versioned IPC ABI.

include "../lib/base.inc"
include "../lib/ipc.inc"
include "../lib/vfs.inc"

SELF_EP         = 1
NAMESERVER_EP   = 2
FRAMEBUFFER_CAP = 3
FRAMEBUFFER_VA  = 0x0000000050000000
MAX_WIDTH       = 1280
MAX_HEIGHT      = 800
MAX_PIXELS      = MAX_WIDTH*MAX_HEIGHT
TASKBAR_HEIGHT  = 48
TITLE_HEIGHT    = 34
TERM_COLS       = 80
TERM_ROWS       = 25
TERM_CELL_W     = 12
TERM_CELL_H     = 18
TERM_VIEW_W     = TERM_COLS*TERM_CELL_W
TERM_VIEW_H     = TERM_ROWS*TERM_CELL_H
WIDGET_COUNT    = 32
WIDGET_BYTES    = 80
UI_CLIENT_COUNT = 8
UI_CLIENT_BYTES = 48

COLOR_DESKTOP_FALLBACK = 0x00132238
COLOR_TASKBAR          = 0xE6182232
COLOR_TASKBAR_LIGHT    = 0xFF26364B
COLOR_PANEL            = 0xFF172335
COLOR_PANEL_LIGHT      = 0xFF26384F
COLOR_TITLE            = 0xFF1D3048
COLOR_TITLE_ACTIVE     = 0xFF24587A
COLOR_TERMINAL         = 0xFF0B111B
COLOR_TERMINAL_ALT     = 0xFF101A28
COLOR_TEXT             = 0xFFE9F2FA
COLOR_MUTED            = 0xFF9EB1C4
COLOR_ACCENT           = 0xFF5BC0EB
COLOR_WARM             = 0xFFFFC857
COLOR_DANGER           = 0xFFFF6B6B
COLOR_GREEN            = 0xFF75D69C
COLOR_SHADOW           = 0xA0000000

segment readable executable
start:
  system_call SYS_PLATFORM_INFO
  test rax, rax
  js fatal
  mov rbx, rax
  mov r12, rdx
  mov [screen_width], ebx
  shr rbx, 32
  mov [screen_height], ebx
  mov [screen_pitch], r12d
  shr r12, 32
  mov [screen_bpp], r12d
  cmp dword [screen_width], MAX_WIDTH
  ja fatal
  cmp dword [screen_height], MAX_HEIGHT
  ja fatal
  cmp dword [screen_bpp], 32
  jne fatal
  mov eax, [screen_width]
  shl eax, 2
  cmp [screen_pitch], eax
  jb fatal

  mov eax, SYS_MMIO_MAP
  mov edi, FRAMEBUFFER_CAP
  mov esi, FRAMEBUFFER_VA
  syscall
  test rax, rax
  jnz fatal

  mov eax, [screen_width]
  shr eax, 1
  mov [pointer_x], eax
  mov eax, [screen_height]
  shr eax, 1
  mov [pointer_y], eax
  call initialize_terminal_cells
  call render_console_scene
  call present_scene
  call register_gui
  test rax, rax
  jnz fatal
  log ready_text, ready_text.size

.serve:
  ipc_receive SELF_EP, message
  test rax, rax
  jnz fatal
  mov rax, qword [message+IpcMessage.words]
  cmp rax, GUI_DESKTOP_ENTER
  je handle_desktop_enter
  cmp rax, GUI_DESKTOP_LEAVE
  je handle_desktop_leave
  cmp rax, GUI_EVENT_WAIT
  je handle_event_wait
  cmp rax, GUI_TERMINAL_OPEN
  je handle_terminal_open
  cmp rax, GUI_TERMINAL_CLOSE
  je handle_terminal_close
  cmp rax, GUI_POINTER
  je handle_pointer
  cmp rax, GUI_TERM_PUT
  je handle_term_put
  cmp rax, GUI_TERM_DRAW
  je handle_term_draw
  cmp rax, GUI_TERM_CLEAR
  je handle_term_clear
  cmp rax, GUI_TERM_SCROLL
  je handle_term_scroll
  cmp rax, GUI_CLOCK_UPDATE
  je handle_clock
  cmp rax, GUI_WIDGET_CREATE
  je handle_widget_create
  cmp rax, GUI_WIDGET_UPDATE
  je handle_widget_update
  cmp rax, GUI_WIDGET_DESTROY
  je handle_widget_destroy
  cmp rax, GUI_WIDGET_EVENT_WAIT
  je handle_widget_event_wait
  cmp rax, GUI_CLIENT_CLOSE
  je handle_client_close
  cmp rax, GUI_SHORTCUT_ADD
  je handle_shortcut_add
  cmp rax, GUI_SHORTCUT_REMOVE
  je handle_shortcut_remove
  cmp rax, GUI_SHORTCUT_MOVE
  je handle_shortcut_move
  cmp rax, GUI_SET_WALLPAPER
  je handle_set_wallpaper
  call close_received_caps
  jmp start.serve

fatal:
  log failed_text, failed_text.size
  exit_process 1

;//////////////////////////////////////////////////////////////////////////////
;// IPC commands
;//////////////////////////////////////////////////////////////////////////////

handle_desktop_enter:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .invalid
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [desktop_enter_reply], rax
  cmp byte [wallpaper_ready], 0
  jne .ready
  call load_default_wallpaper
  test rax, rax
  jz .ready
  call make_fallback_wallpaper
.ready:
  mov byte [desktop_active], 1
  mov byte [start_menu_open], 0
  call initialize_shortcuts
  call render_desktop_scene
  call present_scene
  log desktop_ready_text, desktop_ready_text.size
  lea rdi, [out_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
.reply_retry:
  mov eax, SYS_IPC_SEND
  mov rdi, [desktop_enter_reply]
  lea rsi, [out_message]
  syscall
  cmp rax, -11
  jne .reply_close
  system_call SYS_YIELD
  jmp .reply_retry
.reply_close:
  mov rdi, [desktop_enter_reply]
  call close_handle
  mov qword [desktop_enter_reply], 0
  jmp start.serve
.invalid:
  call close_received_caps
  jmp start.serve

handle_desktop_leave:
  call close_received_caps
  mov byte [desktop_active], 0
  mov byte [terminal_open], 0
  call render_console_scene
  call present_scene
  jmp start.serve

handle_terminal_open:
  call close_received_caps
  mov byte [terminal_open], 1
  mov byte [terminal_state], 1
  mov dword [window_x], 120
  mov dword [window_y], 86
  mov dword [window_w], 1040
  mov dword [window_h], 560
  call render_desktop_scene
  call present_scene
  log terminal_ready_text, terminal_ready_text.size
  jmp start.serve

handle_terminal_close:
  call close_received_caps
  mov byte [terminal_open], 0
  call render_desktop_scene
  call present_scene
  jmp start.serve

;// Клиент передаёт временную SEND capability своего endpoint и блокируется.
;// У desktop и terminal раздельные waiter slots: окно не может украсть событие
;// launcher-а и наоборот.
handle_event_wait:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .bad
  mov rax, qword [message+IpcMessage.words+8]
  cmp rax, GUI_ROLE_DESKTOP
  je .desktop
  cmp rax, GUI_ROLE_TERMINAL
  jne .bad
  mov rdi, qword [terminal_event_reply]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [terminal_event_reply], rax
  mov rax, qword [terminal_pending_event]
  test rax, rax
  jz start.serve
  mov qword [terminal_pending_event], 0
  mov edi, GUI_ROLE_TERMINAL
  mov esi, eax
  call deliver_event
  jmp start.serve
.desktop:
  mov rdi, qword [desktop_event_reply]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [desktop_event_reply], rax
  mov rax, qword [desktop_pending_event]
  test rax, rax
  jz start.serve
  mov qword [desktop_pending_event], 0
  mov edi, GUI_ROLE_DESKTOP
  mov esi, eax
  call deliver_event
  jmp start.serve
.bad:
  call close_received_caps
  jmp start.serve

handle_pointer:
  call close_received_caps
  mov eax, [pointer_x]
  mov [old_pointer_x], eax
  mov eax, [pointer_y]
  mov [old_pointer_y], eax
  mov rax, qword [message+IpcMessage.words+8]
  add [pointer_x], eax
  mov rax, qword [message+IpcMessage.words+16]
  add [pointer_y], eax
  cmp dword [pointer_x], 0
  jge .x_high
  mov dword [pointer_x], 0
.x_high:
  mov eax, [screen_width]
  dec eax
  cmp [pointer_x], eax
  jle .y_low
  mov [pointer_x], eax
.y_low:
  cmp dword [pointer_y], 0
  jge .y_high
  mov dword [pointer_y], 0
.y_high:
  mov eax, [screen_height]
  dec eax
  cmp [pointer_y], eax
  jle .buttons
  mov [pointer_y], eax
.buttons:
  inc qword [pointer_serial]
  mov eax, dword [message+IpcMessage.words+24]
  mov ebx, [pointer_buttons]
  mov [pointer_buttons], eax
  test eax, 1
  jz .released
  test ebx, 1
  jnz .drag
  call pointer_left_press
  jmp .poll_clock
.drag:
  call pointer_drag
  jmp .poll_clock
.released:
  test ebx, 1
  jz .move_only
  call pointer_left_release
  jmp .poll_clock
.move_only:
  call present_pointer_move
.poll_clock:
  mov rax, qword [pointer_serial]
  and eax, 63
  jnz start.serve
  call request_clock_update
  jmp start.serve

handle_term_put:
  call close_received_caps
  mov eax, dword [message+IpcMessage.words+8]
  cmp eax, TERM_COLS
  jae start.serve
  mov ebx, dword [message+IpcMessage.words+16]
  cmp ebx, TERM_ROWS
  jae start.serve
  imul ebx, TERM_COLS
  add ebx, eax
  mov ax, word [message+IpcMessage.words+24]
  mov word [terminal_cells+rbx*2], ax
  mov edi, ebx
  call render_terminal_cell_index
  jmp start.serve

handle_term_draw:
  call close_received_caps
  mov rax, qword [message+IpcMessage.words+8]
  movzx ebx, al                  ;// x
  shr rax, 8
  movzx r12d, al                ;// y
  shr rax, 8
  movzx r13d, al                ;// count
  cmp ebx, TERM_COLS
  jae start.serve
  cmp r12d, TERM_ROWS
  jae start.serve
  test r13d, r13d
  jz start.serve
  cmp r13d, 24
  ja start.serve
  mov eax, ebx
  add eax, r13d
  cmp eax, TERM_COLS
  ja start.serve
  imul r12d, TERM_COLS
  add r12d, ebx
  xor ebx, ebx
.cell:
  cmp ebx, r13d
  jae start.serve
  mov ax, word [message+IpcMessage.words+16+rbx*2]
  mov word [terminal_cells+r12*2], ax
  mov edi, r12d
  push rbx
  push r12
  push r13
  call render_terminal_cell_index
  pop r13
  pop r12
  pop rbx
  inc r12d
  inc ebx
  jmp .cell

handle_term_clear:
  call close_received_caps
  call initialize_terminal_cells
  cmp byte [desktop_active], 0
  je .console
  cmp byte [terminal_open], 0
  je start.serve
  call render_desktop_scene
  call present_scene
  jmp start.serve
.console:
  call render_console_scene
  call present_scene
  jmp start.serve

handle_term_scroll:
  call close_received_caps
  lea rsi, [terminal_cells+TERM_COLS*2]
  lea rdi, [terminal_cells]
  mov ecx, TERM_COLS*(TERM_ROWS-1)*2/8
  rep movsq
  mov ax, 0x0720
  mov ecx, TERM_COLS
  rep stosw
  cmp byte [desktop_active], 0
  je .console
  cmp byte [terminal_open], 0
  je start.serve
  call render_desktop_scene
  call present_scene
  jmp start.serve
.console:
  call render_console_scene
  call present_scene
  jmp start.serve

handle_clock:
  mov rax, qword [message+IpcMessage.cap_count]
  test rax, rax
  jz .no_endpoint
  cmp rax, 1
  jne .close_extra
  cmp qword [platform_endpoint], 0
  jne .close_extra
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [platform_endpoint], rax
  jmp .no_endpoint
.close_extra:
  call close_received_caps
.no_endpoint:
  mov eax, dword [message+IpcMessage.words+8]
  mov [clock_hour], al
  mov [clock_minute], ah
  cmp byte [desktop_active], 0
  je start.serve
  call render_desktop_scene
  call present_scene
  jmp start.serve

handle_set_wallpaper:
  call close_received_caps
  mov eax, dword [message+IpcMessage.words+8]
  cmp eax, 1
  je .default
  cmp eax, 2
  jne start.serve
  call make_fallback_wallpaper
  jmp .render
.default:
  mov byte [wallpaper_ready], 0
  call load_default_wallpaper
  test rax, rax
  jz .render
  call make_fallback_wallpaper
.render:
  cmp byte [desktop_active], 0
  je start.serve
  call render_desktop_scene
  call present_scene
  jmp start.serve

;//////////////////////////////////////////////////////////////////////////////
;// Central UI component object store
;//////////////////////////////////////////////////////////////////////////////

;// Wire layout: word1=id, word2=type, word3=x|y<<32, word4=w|h<<32,
;// word5=state, words6..7=16 UTF-8/ASCII bytes. Owner берётся из IPC sender.
handle_widget_create:
  call close_received_caps
  mov rdi, qword [message+IpcMessage.sender]
  call ensure_ui_client
  test rax, rax
  jz start.serve
  xor ebx, ebx
.slot:
  cmp ebx, WIDGET_COUNT
  jae start.serve
  imul rax, rbx, WIDGET_BYTES
  cmp byte [widgets+rax], 0
  je .store
  inc ebx
  jmp .slot
.store:
  lea rdi, [widgets+rax]
  mov byte [rdi], 1
  mov rax, qword [message+IpcMessage.sender]
  mov [rdi+8], rax
  mov rax, qword [message+IpcMessage.words+8]
  mov [rdi+16], rax
  mov rax, qword [message+IpcMessage.words+16]
  mov [rdi+24], rax
  mov rax, qword [message+IpcMessage.words+24]
  mov [rdi+32], eax
  shr rax, 32
  mov [rdi+36], eax
  mov rax, qword [message+IpcMessage.words+32]
  mov [rdi+40], eax
  shr rax, 32
  mov [rdi+44], eax
  mov rax, qword [message+IpcMessage.words+40]
  mov [rdi+48], rax
  mov rax, qword [message+IpcMessage.words+48]
  mov [rdi+56], rax
  mov rax, qword [message+IpcMessage.words+56]
  mov [rdi+64], rax
  mov byte [rdi+72], 0
  call redraw_if_desktop
  jmp start.serve

handle_widget_update:
  call close_received_caps
  mov rdi, qword [message+IpcMessage.words+8]
  call find_owned_widget
  test rax, rax
  jz start.serve
  mov rdx, qword [message+IpcMessage.words+24]
  mov [rax+32], edx
  shr rdx, 32
  mov [rax+36], edx
  mov rdx, qword [message+IpcMessage.words+32]
  mov [rax+40], edx
  shr rdx, 32
  mov [rax+44], edx
  mov rdx, qword [message+IpcMessage.words+40]
  mov [rax+48], rdx
  mov rdx, qword [message+IpcMessage.words+48]
  mov [rax+56], rdx
  mov rdx, qword [message+IpcMessage.words+56]
  mov [rax+64], rdx
  call redraw_if_desktop
  jmp start.serve

handle_widget_destroy:
  call close_received_caps
  mov rdi, qword [message+IpcMessage.words+8]
  call find_owned_widget
  test rax, rax
  jz start.serve
  mov byte [rax], 0
  call redraw_if_desktop
  jmp start.serve

;// Один ожидающий reply endpoint на GUI-клиент. Token отправителя выдаёт
;// микроядро, поэтому приложение не может подписаться на чужие widgets.
handle_widget_event_wait:
  cmp qword [message+IpcMessage.cap_count], 1
  jne .bad
  mov rdi, qword [message+IpcMessage.sender]
  call ensure_ui_client
  test rax, rax
  jz .bad
  mov r12, rax
  mov rdi, qword [r12+8]
  call close_handle
  mov rax, qword [message+IpcMessage.caps+IpcCap.handle]
  mov [r12+8], rax
  cmp qword [r12+16], 0
  je start.serve
  mov rdi, r12
  call deliver_widget_event
  jmp start.serve
.bad:
  call close_received_caps
  jmp start.serve

;// Нормальное завершение GUI-клиента. Удаляем его object store и waiter;
;// следующий процесс не наследует состояние только из-за повторного запуска.
handle_client_close:
  call close_received_caps
  mov r12, qword [message+IpcMessage.sender]
  xor ebx, ebx
.widget:
  cmp ebx, WIDGET_COUNT
  jae .client
  imul rax, rbx, WIDGET_BYTES
  lea rax, [widgets+rax]
  cmp byte [rax], 0
  je .next_widget
  cmp qword [rax+8], r12
  jne .next_widget
  mov byte [rax], 0
.next_widget:
  inc ebx
  jmp .widget
.client:
  mov rdi, r12
  call find_ui_client
  test rax, rax
  jz .redraw
  mov rbx, rax
  mov rdi, qword [rbx+8]
  call close_handle
  mov rdi, rbx
  xor eax, eax
  mov ecx, UI_CLIENT_BYTES/8
  rep stosq
.redraw:
  call redraw_if_desktop
  jmp start.serve

;// RDI=kernel-provided sender token. RAX=client record или 0.
;// Свободная запись создаётся лениво при первом widget/wait запросе.
ensure_ui_client:
  push rbx
  push r12
  mov r12, rdi
  xor ebx, ebx
  xor edx, edx
.next:
  cmp ebx, UI_CLIENT_COUNT
  jae .allocate
  imul rax, rbx, UI_CLIENT_BYTES
  lea rax, [ui_clients+rax]
  cmp qword [rax], r12
  je .done
  cmp qword [rax], 0
  jne .advance
  test rdx, rdx
  cmovz rdx, rax
.advance:
  inc ebx
  jmp .next
.allocate:
  mov rax, rdx
  test rax, rax
  jz .done
  mov [rax], r12
  mov qword [rax+8], 0
  mov qword [rax+16], 0
  mov qword [rax+24], 0
  mov qword [rax+32], 0
  mov qword [rax+40], 0
.done:
  pop r12
  pop rbx
  ret

;// RDI=owner token. Только поиск, без создания.
find_ui_client:
  xor eax, eax
.next:
  cmp eax, UI_CLIENT_COUNT
  jae .missing
  imul rdx, rax, UI_CLIENT_BYTES
  lea rdx, [ui_clients+rdx]
  cmp qword [rdx], rdi
  je .found
  inc eax
  jmp .next
.found:
  mov rax, rdx
  ret
.missing:
  xor eax, eax
  ret

;// RDI=widget record. Последнее действие хранится, пока клиент не поставит
;// EVENT_WAIT; быстрый клиент получает его сразу через reply capability.
queue_widget_event:
  push r12
  mov r12, rdi
  mov rdi, qword [r12+8]
  call find_ui_client
  test rax, rax
  jz .done
  mov qword [rax+16], 1
  mov rdx, qword [r12+16]
  mov [rax+24], rdx
  mov edx, dword [r12+24]
  mov [rax+32], rdx
  mov rdx, qword [r12+48]
  mov [rax+40], rdx
  cmp qword [rax+8], 0
  je .done
  mov rdi, rax
  call deliver_widget_event
.done:
  pop r12
  ret

;// RDI=client record. Reply: status, ACTION, id, type, state.
deliver_widget_event:
  push rbx
  mov rbx, rdi
  lea rdi, [out_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [out_message+IpcMessage.words+8], GUI_EVENT_ACTION
  mov rax, qword [rbx+24]
  mov qword [out_message+IpcMessage.words+16], rax
  mov rax, qword [rbx+32]
  mov qword [out_message+IpcMessage.words+24], rax
  mov rax, qword [rbx+40]
  mov qword [out_message+IpcMessage.words+32], rax
.retry:
  mov eax, SYS_IPC_SEND
  mov rdi, qword [rbx+8]
  lea rsi, [out_message]
  syscall
  cmp rax, -11
  jne .close
  system_call SYS_YIELD
  jmp .retry
.close:
  mov rdi, qword [rbx+8]
  call close_handle
  mov qword [rbx+8], 0
  mov qword [rbx+16], 0
  pop rbx
  ret

;// RDI=id; RAX=owned widget/0.
find_owned_widget:
  xor ebx, ebx
.next:
  cmp ebx, WIDGET_COUNT
  jae .missing
  imul rax, rbx, WIDGET_BYTES
  lea rax, [widgets+rax]
  cmp byte [rax], 0
  je .advance
  cmp [rax+16], rdi
  jne .advance
  mov rdx, qword [message+IpcMessage.sender]
  cmp [rax+8], rdx
  je .done
.advance:
  inc ebx
  jmp .next
.missing:
  xor eax, eax
.done:
  ret

handle_shortcut_add:
  call close_received_caps
  ;// ABI резервирует 16 shortcuts; MVP использует два системных и принимает
  ;// ещё до 14 записей с type/x/y. Label остаётся server-owned ресурсом.
  mov eax, [shortcut_count]
  cmp eax, 16
  jae start.serve
  imul rdx, rax, 16
  mov rcx, qword [message+IpcMessage.words+8]
  mov dword [shortcuts+rdx], ecx
  mov rcx, qword [message+IpcMessage.words+16]
  mov dword [shortcuts+rdx+4], ecx
  shr rcx, 32
  mov dword [shortcuts+rdx+8], ecx
  inc dword [shortcut_count]
  call redraw_if_desktop
  jmp start.serve

handle_shortcut_remove:
  call close_received_caps
  mov eax, dword [message+IpcMessage.words+8]
  cmp eax, 2                    ;// Terminal и Trash системные
  jb start.serve
  cmp eax, [shortcut_count]
  jae start.serve
  dec dword [shortcut_count]
  mov ecx, [shortcut_count]
.shift:
  cmp eax, ecx
  jae .done
  mov edx, eax
  inc edx
  imul rdx, 16
  imul rbx, rax, 16
  mov r8, qword [shortcuts+rdx]
  mov r9, qword [shortcuts+rdx+8]
  mov qword [shortcuts+rbx], r8
  mov qword [shortcuts+rbx+8], r9
  inc eax
  jmp .shift
.done:
  call redraw_if_desktop
  jmp start.serve

handle_shortcut_move:
  call close_received_caps
  mov eax, dword [message+IpcMessage.words+8]
  cmp eax, [shortcut_count]
  jae start.serve
  imul rax, 16
  mov rdx, qword [message+IpcMessage.words+16]
  mov dword [shortcuts+rax+4], edx
  shr rdx, 32
  mov dword [shortcuts+rax+8], edx
  call redraw_if_desktop
  jmp start.serve

redraw_if_desktop:
  cmp byte [desktop_active], 0
  je .done
  call render_desktop_scene
  call present_scene
.done:
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Pointer focus, window controls, shortcuts and Start menu
;//////////////////////////////////////////////////////////////////////////////

pointer_left_press:
  cmp byte [desktop_active], 0
  je .done
  mov eax, [screen_height]
  sub eax, TASKBAR_HEIGHT
  cmp [pointer_y], eax
  jl .menu_or_window
  ;// Start button.
  cmp dword [pointer_x], 8
  jl .task_item
  cmp dword [pointer_x], 116
  jg .task_item
  xor byte [start_menu_open], 1
  call render_desktop_scene
  call present_scene
  jmp .done
.task_item:
  cmp byte [terminal_open], 0
  je .done
  cmp dword [pointer_x], 132
  jl .done
  cmp dword [pointer_x], 360
  jg .done
  mov byte [terminal_state], 1
  call render_desktop_scene
  call present_scene
  jmp .done
.menu_or_window:
  cmp byte [start_menu_open], 0
  je .window
  mov eax, [screen_height]
  sub eax, TASKBAR_HEIGHT+154
  cmp [pointer_y], eax
  jl .window
  cmp dword [pointer_x], 8
  jl .window
  cmp dword [pointer_x], 248
  jg .window
  mov edx, [screen_height]
  sub edx, TASKBAR_HEIGHT+142
  cmp [pointer_y], edx
  jl .window
  add edx, 60
  cmp [pointer_y], edx
  jl .launch_terminal
  add edx, 60
  cmp [pointer_y], edx
  jl .power_off
  jmp .window
.launch_terminal:
  mov byte [start_menu_open], 0
  mov edi, GUI_ROLE_DESKTOP
  mov esi, GUI_EVENT_LAUNCH_TERMINAL
  call queue_event
  call render_desktop_scene
  call present_scene
  jmp .done
.power_off:
  call request_power_off
  jmp .done
.window:
  cmp byte [terminal_open], 0
  je .icons
  cmp byte [terminal_state], 2
  je .icons
  call hit_window_control
  test eax, eax
  jnz .done
.icons:
  ;// Видимое окно перекрывает desktop widgets: click не должен проходить
  ;// сквозь terminal client area в лежащий под ним компонент.
  cmp byte [terminal_open], 0
  je .widgets
  cmp byte [terminal_state], 2
  je .widgets
  call pointer_inside_terminal_window
  test eax, eax
  jnz .done
.widgets:
  call hit_widget
  test eax, eax
  jnz .done
  call hit_shortcut
  cmp eax, -1
  je .done
  mov [drag_shortcut], eax
  mov edx, eax
  imul rdx, 16
  mov ecx, [pointer_x]
  sub ecx, dword [shortcuts+rdx+4]
  mov [drag_offset_x], ecx
  mov ecx, [pointer_y]
  sub ecx, dword [shortcuts+rdx+8]
  mov [drag_offset_y], ecx
  cmp eax, 0
  jne .done
  mov rdx, qword [pointer_serial]
  sub rdx, [last_icon_click]
  cmp rdx, 80
  ja .first
  mov qword [last_icon_click], 0
  mov dword [drag_shortcut], -1
  mov edi, GUI_ROLE_DESKTOP
  mov esi, GUI_EVENT_LAUNCH_TERMINAL
  call queue_event
  jmp .done
.first:
  mov rdx, qword [pointer_serial]
  mov [last_icon_click], rdx
.done:
  ret

;// EAX=1, если pointer находится внутри видимого terminal window.
pointer_inside_terminal_window:
  call effective_window_rect
  xor eax, eax
  mov ecx, [pointer_x]
  cmp ecx, [effective_x]
  jl .done
  mov edx, [effective_x]
  add edx, [effective_w]
  cmp ecx, edx
  jge .done
  mov ecx, [pointer_y]
  cmp ecx, [effective_y]
  jl .done
  mov edx, [effective_y]
  add edx, [effective_h]
  cmp ecx, edx
  jge .done
  mov eax, 1
.done:
  ret

;// Найти верхний server-side widget и сформировать semantic action.
;// Panel/label/image прозрачны для hit testing; остальные компоненты активны.
hit_widget:
  mov ebx, WIDGET_COUNT-1
.next:
  imul rax, rbx, WIDGET_BYTES
  lea r12, [widgets+rax]
  cmp byte [r12], 0
  je .advance
  mov eax, [r12+24]
  cmp eax, UI_PANEL
  je .advance
  cmp eax, UI_LABEL
  je .advance
  cmp eax, UI_IMAGE
  je .advance
  mov ecx, [pointer_x]
  cmp ecx, [r12+32]
  jl .advance
  mov edx, [r12+32]
  add edx, [r12+40]
  cmp ecx, edx
  jge .advance
  mov ecx, [pointer_y]
  cmp ecx, [r12+36]
  jl .advance
  mov edx, [r12+36]
  add edx, [r12+44]
  cmp ecx, edx
  jge .advance
  mov eax, [r12+24]
  cmp eax, UI_CHECKBOX
  je .toggle
  cmp eax, UI_TOGGLE
  je .toggle
  cmp eax, UI_RADIO
  jne .notify
  mov qword [r12+48], 1
  jmp .notify
.toggle:
  xor qword [r12+48], 1
.notify:
  mov rdi, r12
  call queue_widget_event
  call redraw_if_desktop
  mov eax, 1
  ret
.advance:
  dec ebx
  jns .next
  xor eax, eax
  ret

;// EAX=1 если control/titlebar обработан.
hit_window_control:
  xor eax, eax
  mov ebx, [window_x]
  mov ecx, [pointer_x]
  cmp ecx, ebx
  jl .done
  add ebx, [window_w]
  cmp ecx, ebx
  jg .done
  mov edx, [window_y]
  cmp [pointer_y], edx
  jl .done
  add edx, TITLE_HEIGHT
  cmp [pointer_y], edx
  jg .done
  sub ebx, 34
  cmp ecx, ebx
  jge .close
  sub ebx, 34
  cmp ecx, ebx
  jge .maximize
  sub ebx, 34
  cmp ecx, ebx
  jge .minimize
  mov dword [drag_window], 1
  mov eax, [pointer_x]
  sub eax, [window_x]
  mov [drag_offset_x], eax
  mov eax, [pointer_y]
  sub eax, [window_y]
  mov [drag_offset_y], eax
  mov eax, 1
  ret
.minimize:
  mov byte [terminal_state], 2
  call render_desktop_scene
  call present_scene
  mov eax, 1
  ret
.maximize:
  cmp byte [terminal_state], 3
  je .restore
  mov byte [terminal_state], 3
  jmp .redraw
.restore:
  mov byte [terminal_state], 1
.redraw:
  call render_desktop_scene
  call present_scene
  mov eax, 1
  ret
.close:
  mov byte [terminal_open], 0
  mov edi, GUI_ROLE_TERMINAL
  mov esi, GUI_EVENT_CLOSE
  call queue_event
  call render_desktop_scene
  call present_scene
  mov eax, 1
.done:
  ret

pointer_drag:
  cmp dword [drag_window], 0
  je .shortcut
  cmp byte [terminal_state], 1
  jne .done
  mov eax, [pointer_x]
  sub eax, [drag_offset_x]
  cmp eax, 0
  jge .x_high
  xor eax, eax
.x_high:
  mov edx, [screen_width]
  sub edx, [window_w]
  cmp eax, edx
  jle .store_x
  mov eax, edx
.store_x:
  mov [window_x], eax
  mov eax, [pointer_y]
  sub eax, [drag_offset_y]
  cmp eax, 0
  jge .y_high
  xor eax, eax
.y_high:
  mov edx, [screen_height]
  sub edx, TASKBAR_HEIGHT+TITLE_HEIGHT
  cmp eax, edx
  jle .store_y
  mov eax, edx
.store_y:
  mov [window_y], eax
  call render_desktop_scene
  call present_scene
  ret
.shortcut:
  mov eax, [drag_shortcut]
  cmp eax, -1
  je .move_cursor
  imul rax, 16
  mov edx, [pointer_x]
  sub edx, [drag_offset_x]
  cmp edx, 0
  jge .sx
  xor edx, edx
.sx:
  mov ecx, [screen_width]
  sub ecx, 80
  cmp edx, ecx
  jle .store_sx
  mov edx, ecx
.store_sx:
  mov dword [shortcuts+rax+4], edx
  mov edx, [pointer_y]
  sub edx, [drag_offset_y]
  cmp edx, 0
  jge .sy
  xor edx, edx
.sy:
  mov ecx, [screen_height]
  sub ecx, TASKBAR_HEIGHT+92
  cmp edx, ecx
  jle .store_sy
  mov edx, ecx
.store_sy:
  mov dword [shortcuts+rax+8], edx
  call render_desktop_scene
  call present_scene
  ret
.move_cursor:
  call present_pointer_move
.done:
  ret

pointer_left_release:
  mov dword [drag_window], 0
  mov dword [drag_shortcut], -1
  call present_pointer_move
  ret

;// EAX=shortcut index/-1.
hit_shortcut:
  xor eax, eax
.next:
  cmp eax, [shortcut_count]
  jae .missing
  imul rdx, rax, 16
  mov ecx, [pointer_x]
  sub ecx, dword [shortcuts+rdx+4]
  cmp ecx, 0
  jl .advance
  cmp ecx, 72
  jg .advance
  mov ecx, [pointer_y]
  sub ecx, dword [shortcuts+rdx+8]
  cmp ecx, 0
  jl .advance
  cmp ecx, 88
  jle .done
.advance:
  inc eax
  jmp .next
.missing:
  mov eax, -1
.done:
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Scenes and software compositor
;//////////////////////////////////////////////////////////////////////////////

render_console_scene:
  mov edi, 0
  mov esi, 0
  mov edx, [screen_width]
  mov ecx, [screen_height]
  mov r8d, COLOR_TERMINAL
  call fill_rect
  call render_all_terminal_cells
  ret

render_desktop_scene:
  call copy_wallpaper_to_scene
  call draw_shortcuts
  call draw_widgets
  cmp byte [terminal_open], 0
  je .taskbar
  cmp byte [terminal_state], 2
  je .taskbar
  call draw_terminal_window
.taskbar:
  call draw_taskbar
  cmp byte [start_menu_open], 0
  je .done
  call draw_start_menu
.done:
  ret

copy_wallpaper_to_scene:
  cmp byte [wallpaper_ready], 0
  je make_fallback_wallpaper
  mov eax, [screen_width]
  imul eax, [screen_height]
  mov ecx, eax
  lea rsi, [wallpaper_buffer]
  lea rdi, [backbuffer]
  rep movsd
  ret

make_fallback_wallpaper:
  ;// Детеминированный low-frequency gradient — fallback для другого VBE mode
  ;// или повреждённого asset. Он остаётся комфортным и не маскирует ошибку I/O.
  xor r12d, r12d
.row:
  cmp r12d, [screen_height]
  jae .done
  mov eax, r12d
  imul eax, 22
  xor edx, edx
  div dword [screen_height]
  mov ebx, eax
  add ebx, 18                   ;// blue component contribution
  xor r13d, r13d
.pixel:
  cmp r13d, [screen_width]
  jae .next_row
  mov eax, r13d
  imul eax, 18
  xor edx, edx
  div dword [screen_width]
  mov r8d, eax
  add r8d, 13
  mov eax, ebx
  add eax, 30
  shl eax, 16
  mov edx, r8d
  add edx, 28
  shl edx, 8
  or eax, edx
  mov edx, ebx
  add edx, r8d
  add edx, 42
  or eax, edx
  mov edx, r12d
  imul edx, [screen_width]
  add edx, r13d
  mov dword [wallpaper_buffer+rdx*4], eax
  inc r13d
  jmp .pixel
.next_row:
  inc r12d
  jmp .row
.done:
  mov byte [wallpaper_ready], 1
  call copy_wallpaper_to_scene
  xor eax, eax
  ret

load_default_wallpaper:
  cmp dword [screen_width], 1280
  jne .invalid
  cmp dword [screen_height], 800
  jne .invalid
  cmp byte [filesystem_connected], 0
  jne .connected
  call vlib_fs_connect
  test rax, rax
  jnz .done
  mov byte [filesystem_connected], 1
.connected:
  lea rdi, [wallpaper_path]
  call vlib_fs_resolve
  test rax, rax
  js .done
  cmp rdx, FS_NODE_FILE
  jne .invalid
  mov r12, rax
  mov rdi, r12
  call vlib_fs_stat
  test rax, rax
  jnz .done
  cmp rdx, MAX_PIXELS*4
  jne .invalid
  mov rdi, r12
  xor esi, esi
  mov edx, MAX_PIXELS*4
  lea r10, [wallpaper_buffer]
  call vlib_fs_read
  cmp rax, MAX_PIXELS*4
  jne .io
  mov byte [wallpaper_ready], 1
  xor eax, eax
  ret
.invalid:
  mov rax, -22
  ret
.io:
  mov rax, -5
.done:
  ret

draw_taskbar:
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT
  mov edi, 0
  mov edx, [screen_width]
  mov ecx, TASKBAR_HEIGHT
  mov r8d, COLOR_TASKBAR
  call fill_rect
  mov edi, 8
  mov esi, [screen_height]
  sub esi, 40
  mov edx, 108
  mov ecx, 34
  mov r8d, COLOR_TASKBAR_LIGHT
  call fill_rect
  call draw_start_symbol
  mov edi, 43
  mov esi, [screen_height]
  sub esi, 31
  lea rdx, [text_start]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
  cmp byte [terminal_open], 0
  je .clock
  mov edi, 132
  mov esi, [screen_height]
  sub esi, 40
  mov edx, 228
  mov ecx, 34
  mov r8d, COLOR_PANEL_LIGHT
  cmp byte [terminal_state], 2
  je .task_fill
  mov r8d, COLOR_TITLE_ACTIVE
.task_fill:
  call fill_rect
  mov edi, 142
  mov esi, [screen_height]
  sub esi, 31
  lea rdx, [text_terminal]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
.clock:
  call draw_clock
  ret

draw_start_symbol:
  mov edi, 18
  mov esi, [screen_height]
  sub esi, 34
  mov edx, 8
  mov ecx, 8
  mov r8d, COLOR_ACCENT
  call fill_rect
  mov edi, 28
  mov esi, [screen_height]
  sub esi, 34
  mov edx, 8
  mov ecx, 8
  mov r8d, COLOR_GREEN
  call fill_rect
  mov edi, 18
  mov esi, [screen_height]
  sub esi, 24
  mov edx, 8
  mov ecx, 8
  mov r8d, COLOR_WARM
  call fill_rect
  mov edi, 28
  mov esi, [screen_height]
  sub esi, 24
  mov edx, 8
  mov ecx, 8
  mov r8d, COLOR_DANGER
  call fill_rect
  ret

draw_clock:
  movzx eax, byte [clock_hour]
  mov ebx, 10
  xor edx, edx
  div ebx
  add al, '0'
  add dl, '0'
  mov [clock_text], al
  mov [clock_text+1], dl
  movzx eax, byte [clock_minute]
  xor edx, edx
  div ebx
  add al, '0'
  add dl, '0'
  mov [clock_text+3], al
  mov [clock_text+4], dl
  mov edi, [screen_width]
  sub edi, 78
  mov esi, [screen_height]
  sub esi, 31
  lea rdx, [clock_text]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
  ret

draw_start_menu:
  mov edi, 8
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+154
  mov edx, 240
  mov ecx, 148
  mov r8d, COLOR_PANEL
  call fill_rect
  mov edi, 8
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+154
  mov edx, 6
  mov ecx, 148
  mov r8d, COLOR_ACCENT
  call fill_rect
  call draw_terminal_menu_icon
  mov edi, 64
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+128
  lea rdx, [text_terminal]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
  call draw_power_icon
  mov edi, 64
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+66
  lea rdx, [text_power]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
  ret

draw_shortcuts:
  xor ebx, ebx
.next:
  cmp ebx, [shortcut_count]
  jae .done
  imul rax, rbx, 16
  mov edi, dword [shortcuts+rax+4]
  mov esi, dword [shortcuts+rax+8]
  cmp dword [shortcuts+rax], 1
  je .terminal
  cmp dword [shortcuts+rax], 2
  je .trash
  call draw_generic_icon
  jmp .advance
.terminal:
  call draw_terminal_icon
  jmp .advance
.trash:
  call draw_trash_icon
.advance:
  inc ebx
  jmp .next
.done:
  ret

;// EDI=x, ESI=y.
draw_terminal_icon:
  push rdi
  push rsi
  add edi, 8
  add esi, 5
  mov edx, 54
  mov ecx, 40
  mov r8d, COLOR_PANEL
  call fill_rect
  pop rsi
  pop rdi
  push rdi
  push rsi
  add edi, 13
  add esi, 10
  mov edx, 44
  mov ecx, 27
  mov r8d, COLOR_TERMINAL_ALT
  call fill_rect
  pop rsi
  pop rdi
  push rdi
  push rsi
  add edi, 18
  add esi, 16
  lea rdx, [text_prompt]
  mov ecx, COLOR_GREEN
  mov r8d, 2
  call draw_text
  pop rsi
  pop rdi
  add edi, 3
  add esi, 53
  lea rdx, [text_terminal]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  ret

draw_trash_icon:
  push rdi
  push rsi
  add edi, 18
  add esi, 12
  mov edx, 34
  mov ecx, 38
  mov r8d, 0xFFB7C8D8
  call fill_rect
  pop rsi
  pop rdi
  push rdi
  push rsi
  add edi, 14
  add esi, 8
  mov edx, 42
  mov ecx, 7
  mov r8d, COLOR_TEXT
  call fill_rect
  pop rsi
  pop rdi
  add edi, 16
  add esi, 57
  lea rdx, [text_trash]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  ret

draw_generic_icon:
  push rdi
  push rsi
  add edi, 10
  add esi, 7
  mov edx, 48
  mov ecx, 45
  mov r8d, COLOR_ACCENT
  call fill_rect
  pop rsi
  pop rdi
  add edi, 16
  add esi, 59
  lea rdx, [text_app]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  ret

draw_terminal_menu_icon:
  mov edi, 24
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+140
  mov edx, 30
  mov ecx, 24
  mov r8d, COLOR_TERMINAL_ALT
  call fill_rect
  mov edi, 29
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+134
  lea rdx, [text_prompt]
  mov ecx, COLOR_GREEN
  mov r8d, 1
  call draw_text
  ret

draw_power_icon:
  mov edi, 27
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+78
  mov edx, 24
  mov ecx, 24
  mov r8d, COLOR_DANGER
  call fill_rect
  mov edi, 34
  mov esi, [screen_height]
  sub esi, TASKBAR_HEIGHT+74
  lea rdx, [text_power_symbol]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
  ret

draw_terminal_window:
  call effective_window_rect
  ;// shadow
  mov edi, [effective_x]
  add edi, 8
  mov esi, [effective_y]
  add esi, 8
  mov edx, [effective_w]
  mov ecx, [effective_h]
  mov r8d, 0xFF07101A
  call fill_rect
  mov edi, [effective_x]
  mov esi, [effective_y]
  mov edx, [effective_w]
  mov ecx, [effective_h]
  mov r8d, COLOR_PANEL
  call fill_rect
  mov edi, [effective_x]
  mov esi, [effective_y]
  mov edx, [effective_w]
  mov ecx, TITLE_HEIGHT
  mov r8d, COLOR_TITLE_ACTIVE
  call fill_rect
  mov edi, [effective_x]
  add edi, 14
  mov esi, [effective_y]
  add esi, 10
  lea rdx, [text_terminal_title]
  mov ecx, COLOR_TEXT
  mov r8d, 2
  call draw_text
  call draw_window_buttons
  call terminal_origin
  mov edi, [terminal_origin_x]
  sub edi, 10
  mov esi, [terminal_origin_y]
  sub esi, 8
  mov edx, TERM_VIEW_W+20
  mov ecx, TERM_VIEW_H+16
  mov r8d, COLOR_TERMINAL
  call fill_rect
  call render_all_terminal_cells
  ret

effective_window_rect:
  cmp byte [terminal_state], 3
  jne .normal
  mov dword [effective_x], 0
  mov dword [effective_y], 0
  mov eax, [screen_width]
  mov [effective_w], eax
  mov eax, [screen_height]
  sub eax, TASKBAR_HEIGHT
  mov [effective_h], eax
  ret
.normal:
  mov eax, [window_x]
  mov [effective_x], eax
  mov eax, [window_y]
  mov [effective_y], eax
  mov eax, [window_w]
  mov [effective_w], eax
  mov eax, [window_h]
  mov [effective_h], eax
  ret

draw_window_buttons:
  mov edi, [effective_x]
  add edi, [effective_w]
  sub edi, 96
  mov esi, [effective_y]
  add esi, 6
  mov edx, 26
  mov ecx, 22
  mov r8d, COLOR_PANEL_LIGHT
  call fill_rect
  mov edi, [effective_x]
  add edi, [effective_w]
  sub edi, 62
  mov esi, [effective_y]
  add esi, 6
  mov edx, 26
  mov ecx, 22
  mov r8d, COLOR_PANEL_LIGHT
  call fill_rect
  mov edi, [effective_x]
  add edi, [effective_w]
  sub edi, 28
  mov esi, [effective_y]
  add esi, 6
  mov edx, 24
  mov ecx, 22
  mov r8d, COLOR_DANGER
  call fill_rect
  mov edi, [effective_x]
  add edi, [effective_w]
  sub edi, 88
  mov esi, [effective_y]
  add esi, 10
  lea rdx, [text_minimize]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  mov edi, [effective_x]
  add edi, [effective_w]
  sub edi, 55
  mov esi, [effective_y]
  add esi, 10
  lea rdx, [text_maximize]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  mov edi, [effective_x]
  add edi, [effective_w]
  sub edi, 22
  mov esi, [effective_y]
  add esi, 10
  lea rdx, [text_close]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  ret

terminal_origin:
  cmp byte [desktop_active], 0
  je .console
  call effective_window_rect
  mov eax, [effective_x]
  mov edx, [effective_w]
  sub edx, TERM_VIEW_W
  sar edx, 1
  add eax, edx
  mov [terminal_origin_x], eax
  mov eax, [effective_y]
  add eax, TITLE_HEIGHT
  mov edx, [effective_h]
  sub edx, TITLE_HEIGHT+TERM_VIEW_H
  sar edx, 1
  add eax, edx
  mov [terminal_origin_y], eax
  ret
.console:
  mov eax, [screen_width]
  sub eax, TERM_VIEW_W
  sar eax, 1
  mov [terminal_origin_x], eax
  mov eax, [screen_height]
  sub eax, TERM_VIEW_H
  sar eax, 1
  mov [terminal_origin_y], eax
  ret

render_all_terminal_cells:
  call terminal_origin
  xor ebx, ebx
.cell:
  cmp ebx, TERM_COLS*TERM_ROWS
  jae .done
  mov edi, ebx
  push rbx
  call draw_terminal_cell
  pop rbx
  inc ebx
  jmp .cell
.done:
  ret

;// EDI=cell index; repaint backbuffer and present only this cell when visible.
render_terminal_cell_index:
  push rdi
  cmp byte [desktop_active], 0
  je .visible
  cmp byte [terminal_open], 0
  je .hidden
  cmp byte [terminal_state], 2
  je .hidden
.visible:
  call terminal_origin
  pop rdi
  push rdi
  call draw_terminal_cell
  pop rdi
  mov eax, edi
  xor edx, edx
  mov ecx, TERM_COLS
  div ecx
  imul edx, TERM_CELL_W
  add edx, [terminal_origin_x]
  imul eax, TERM_CELL_H
  add eax, [terminal_origin_y]
  mov edi, edx
  mov esi, eax
  mov edx, TERM_CELL_W
  mov ecx, TERM_CELL_H
  call present_rect
  call draw_pointer
  ret
.hidden:
  pop rdi
  ret

;// EDI=cell index, origins already computed.
draw_terminal_cell:
  mov eax, edi
  xor edx, edx
  mov ecx, TERM_COLS
  div ecx
  mov r12d, eax                  ;// row
  mov r13d, edx                  ;// col
  movzx ebx, word [terminal_cells+rdi*2]
  mov eax, ebx
  shr eax, 12
  and eax, 7
  mov r9d, [vga_palette+rax*4]   ;// background
  mov edi, r13d
  imul edi, TERM_CELL_W
  add edi, [terminal_origin_x]
  mov esi, r12d
  imul esi, TERM_CELL_H
  add esi, [terminal_origin_y]
  mov edx, TERM_CELL_W
  mov ecx, TERM_CELL_H
  mov r8d, r9d
  call fill_rect
  mov edi, r13d
  imul edi, TERM_CELL_W
  add edi, [terminal_origin_x]
  inc edi
  mov esi, r12d
  imul esi, TERM_CELL_H
  add esi, [terminal_origin_y]
  add esi, 2
  movzx edx, bl
  mov eax, ebx
  shr eax, 8
  and eax, 15
  mov ecx, [vga_palette+rax*4]
  mov r8d, 2
  call draw_char
  ret

initialize_terminal_cells:
  lea rdi, [terminal_cells]
  mov ax, 0x0720
  mov ecx, TERM_COLS*TERM_ROWS
  rep stosw
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Shared UI widget renderer. Все типы рисуются здесь, не в приложении.
;//////////////////////////////////////////////////////////////////////////////

draw_widgets:
  xor ebx, ebx
.next:
  cmp ebx, WIDGET_COUNT
  jae .done
  imul rax, rbx, WIDGET_BYTES
  lea r12, [widgets+rax]
  cmp byte [r12], 0
  je .advance
  mov eax, [r12+24]
  cmp eax, UI_PANEL
  je .panel
  cmp eax, UI_LABEL
  je .label
  cmp eax, UI_IMAGE
  je .image
  cmp eax, UI_CHECKBOX
  je .checkbox
  cmp eax, UI_RADIO
  je .radio
  cmp eax, UI_TOGGLE
  je .toggle
  cmp eax, UI_TABS
  je .tabs
  cmp eax, UI_SCROLL_VIEW
  je .scroll
  cmp eax, UI_LIST_VIEW
  je .list
  ;// BUTTON, ICON_BUTTON и TEXT_EDIT используют общий rounded-like panel.
  mov r8d, COLOR_PANEL_LIGHT
  cmp qword [r12+48], 0
  je .box
  mov r8d, COLOR_TITLE_ACTIVE
.box:
  call widget_box
  call widget_label
  jmp .advance
.panel:
  mov r8d, COLOR_PANEL
  call widget_box
  jmp .advance
.label:
  call widget_label
  jmp .advance
.image:
  mov r8d, COLOR_ACCENT
  call widget_box
  jmp .advance
.checkbox:
  mov edi, [r12+32]
  mov esi, [r12+36]
  mov edx, 18
  mov ecx, 18
  mov r8d, COLOR_PANEL_LIGHT
  call fill_rect
  cmp qword [r12+48], 0
  je .checkbox_label
  mov edi, [r12+32]
  add edi, 5
  mov esi, [r12+36]
  add esi, 5
  mov edx, 8
  mov ecx, 8
  mov r8d, COLOR_GREEN
  call fill_rect
.checkbox_label:
  call widget_label_offset
  jmp .advance
.radio:
  mov edi, [r12+32]
  mov esi, [r12+36]
  mov edx, 18
  mov ecx, 18
  mov r8d, COLOR_PANEL_LIGHT
  call fill_rect
  cmp qword [r12+48], 0
  je .radio_label
  mov edi, [r12+32]
  add edi, 6
  mov esi, [r12+36]
  add esi, 6
  mov edx, 6
  mov ecx, 6
  mov r8d, COLOR_ACCENT
  call fill_rect
.radio_label:
  call widget_label_offset
  jmp .advance
.toggle:
  mov r8d, COLOR_PANEL_LIGHT
  cmp qword [r12+48], 0
  je .toggle_box
  mov r8d, COLOR_GREEN
.toggle_box:
  call widget_box
  call widget_label
  jmp .advance
.tabs:
  mov r8d, COLOR_PANEL
  call widget_box
  mov edi, [r12+32]
  mov esi, [r12+36]
  mov edx, [r12+40]
  mov ecx, 28
  mov r8d, COLOR_TITLE_ACTIVE
  call fill_rect
  call widget_label
  jmp .advance
.scroll:
.list:
  mov r8d, COLOR_TERMINAL_ALT
  call widget_box
  mov edi, [r12+32]
  add edi, [r12+40]
  sub edi, 8
  mov esi, [r12+36]
  add esi, 4
  mov edx, 4
  mov ecx, [r12+44]
  sub ecx, 8
  mov r8d, COLOR_MUTED
  call fill_rect
  call widget_label
.advance:
  inc ebx
  jmp .next
.done:
  ret

widget_box:
  mov edi, [r12+32]
  mov esi, [r12+36]
  mov edx, [r12+40]
  mov ecx, [r12+44]
  call fill_rect
  ret

widget_label:
  mov edi, [r12+32]
  add edi, 8
  mov esi, [r12+36]
  add esi, 7
  lea rdx, [r12+56]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  ret

widget_label_offset:
  mov edi, [r12+32]
  add edi, 26
  mov esi, [r12+36]
  add esi, 5
  lea rdx, [r12+56]
  mov ecx, COLOR_TEXT
  mov r8d, 1
  call draw_text
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Primitive rasterizer and 5x7 readable font
;//////////////////////////////////////////////////////////////////////////////

;// EDI=x, ESI=y, EDX=w, ECX=h, R8D=ARGB/XRGB. Coordinates are clipped.
fill_rect:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12d, edi
  mov r13d, esi
  mov r14d, edx
  mov r15d, ecx
  mov ebx, r8d
  test r14d, r14d
  jle .done
  test r15d, r15d
  jle .done
  cmp r12d, 0
  jge .clip_y
  add r14d, r12d
  xor r12d, r12d
.clip_y:
  cmp r13d, 0
  jge .right
  add r15d, r13d
  xor r13d, r13d
.right:
  mov eax, [screen_width]
  sub eax, r12d
  cmp r14d, eax
  jle .bottom
  mov r14d, eax
.bottom:
  mov eax, [screen_height]
  sub eax, r13d
  cmp r15d, eax
  jle .valid
  mov r15d, eax
.valid:
  test r14d, r14d
  jle .done
  test r15d, r15d
  jle .done
.row:
  mov eax, r13d
  imul eax, [screen_width]
  add eax, r12d
  lea rdi, [backbuffer+rax*4]
  mov eax, ebx
  mov ecx, r14d
  rep stosd
  inc r13d
  dec r15d
  jnz .row
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// EDI=x, ESI=y, DL=ASCII, ECX=color, R8D=scale(1/2).
draw_char:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12d, edi
  mov r13d, esi
  mov r14b, dl
  mov r15d, ecx
  mov ebx, r8d
  xor r11d, r11d                ;// row
.row:
  cmp r11d, 7
  jae .done
  mov dil, r14b
  mov esi, r11d
  call glyph_row
  mov r10b, al
  xor r9d, r9d                  ;// column
.column:
  cmp r9d, 5
  jae .next_row
  mov eax, 4
  sub eax, r9d
  bt r10d, eax
  jnc .skip
  mov edi, r9d
  imul edi, ebx
  add edi, r12d
  mov esi, r11d
  imul esi, ebx
  add esi, r13d
  mov edx, ebx
  mov ecx, ebx
  mov r8d, r15d
  push r9
  push r10
  push r11
  call fill_rect
  pop r11
  pop r10
  pop r9
.skip:
  inc r9d
  jmp .column
.next_row:
  inc r11d
  jmp .row
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// RDI=x, RSI=y, RDX=NUL text, ECX=color, R8D=scale.
draw_text:
  push rbx
  push r12
  push r13
  push r14
  push r15
  mov r12d, edi
  mov r13d, esi
  mov r14, rdx
  mov r15d, ecx
  mov ebx, r8d
.next:
  movzx edx, byte [r14]
  test dl, dl
  jz .done
  mov edi, r12d
  mov esi, r13d
  mov ecx, r15d
  mov r8d, ebx
  call draw_char
  imul eax, ebx, 6             ;// 6*scale advance
  add r12d, eax
  inc r14
  jmp .next
.done:
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

;// DIL=ASCII, ESI=row 0..6, AL=five bits. Lowercase uses uppercase glyphs.
glyph_row:
  movzx eax, dil
  cmp al, 'a'
  jb .digit
  cmp al, 'z'
  ja .digit
  sub al, 32
.digit:
  cmp al, '0'
  jb .letter
  cmp al, '9'
  ja .letter
  sub eax, '0'
  imul eax, 7
  add eax, esi
  mov al, [font_digits+rax]
  ret
.letter:
  movzx eax, dil
  cmp al, 'a'
  jb .upper_ready
  cmp al, 'z'
  ja .upper_ready
  sub al, 32
.upper_ready:
  cmp al, 'A'
  jb .punctuation
  cmp al, 'Z'
  ja .punctuation
  sub eax, 'A'
  imul eax, 7
  add eax, esi
  mov al, [font_letters+rax]
  ret
.punctuation:
  xor eax, eax
  cmp dil, '.'
  jne .comma
  cmp esi, 6
  sete al
  shl al, 2
  ret
.comma:
  cmp dil, ','
  jne .colon
  cmp esi, 5
  je .dot
  cmp esi, 6
  jne .zero
  mov al, 8
  ret
.colon:
  cmp dil, ':'
  jne .dash
  cmp esi, 2
  je .dot
  cmp esi, 5
  je .dot
  ret
.dot:
  mov al, 4
  ret
.dash:
  cmp dil, '-'
  jne .underscore
  cmp esi, 3
  jne .zero
  mov al, 14
  ret
.underscore:
  cmp dil, '_'
  jne .equal
  cmp esi, 6
  jne .zero
  mov al, 31
  ret
.equal:
  cmp dil, '='
  jne .plus
  cmp esi, 2
  je .full
  cmp esi, 4
  jne .zero
.full:
  mov al, 31
  ret
.plus:
  cmp dil, '+'
  jne .slash
  cmp esi, 3
  je .full
  cmp esi, 1
  jb .zero
  cmp esi, 5
  ja .zero
  mov al, 4
  ret
.slash:
  cmp dil, '/'
  jne .backslash
  mov ecx, esi
  shr ecx, 1
  mov eax, 1
  shl eax, cl
  ret
.backslash:
  cmp dil, 92
  jne .greater
  mov ecx, 6
  sub ecx, esi
  shr ecx, 1
  mov eax, 1
  shl eax, cl
  ret
.greater:
  cmp dil, '>'
  jne .less
  cmp esi, 1
  jb .zero
  cmp esi, 5
  ja .zero
  mov ecx, esi
  cmp ecx, 3
  jle .gshift
  mov ecx, 6
  sub ecx, esi
.gshift:
  mov eax, 16
  shr eax, cl
  ret
.less:
  cmp dil, '<'
  jne .bar
  cmp esi, 1
  jb .zero
  cmp esi, 5
  ja .zero
  mov ecx, esi
  cmp ecx, 3
  jle .lshift
  mov ecx, 6
  sub ecx, esi
.lshift:
  mov eax, 1
  shl eax, cl
  ret
.bar:
  cmp dil, '|'
  jne .exclamation
  mov al, 4
  ret
.exclamation:
  cmp dil, '!'
  jne .question
  cmp esi, 5
  je .zero
  mov al, 4
  ret
.question:
  cmp dil, '?'
  jne .brackets
  mov al, [font_question+rsi]
  ret
.brackets:
  cmp dil, '['
  je .left_bracket
  cmp dil, ']'
  je .right_bracket
  cmp dil, '('
  je .left_paren
  cmp dil, ')'
  je .right_paren
  cmp dil, '"'
  je .quote
  cmp dil, 39
  je .apostrophe
  cmp dil, '#'
  je .hash
  cmp dil, '*'
  je .star
  cmp dil, '^'
  je .caret
  cmp dil, '~'
  je .tilde
  ret
.left_bracket:
  cmp esi, 0
  je .bracket_full
  cmp esi, 6
  je .bracket_full
  mov al, 8
  ret
.right_bracket:
  cmp esi, 0
  je .bracket_full
  cmp esi, 6
  je .bracket_full
  mov al, 2
  ret
.bracket_full:
  mov al, 14
  ret
.left_paren:
  cmp esi, 0
  je .paren_top_l
  cmp esi, 6
  je .paren_top_l
  mov al, 8
  ret
.paren_top_l:
  mov al, 4
  ret
.right_paren:
  cmp esi, 0
  je .paren_top_r
  cmp esi, 6
  je .paren_top_r
  mov al, 2
  ret
.paren_top_r:
  mov al, 4
  ret
.quote:
  cmp esi, 1
  ja .zero
  mov al, 10
  ret
.apostrophe:
  cmp esi, 1
  ja .zero
  mov al, 4
  ret
.hash:
  cmp esi, 2
  je .full
  cmp esi, 4
  je .full
  mov al, 10
  ret
.star:
  cmp esi, 3
  je .full
  cmp esi, 2
  je .star_side
  cmp esi, 4
  jne .zero
.star_side:
  mov al, 10
  ret
.caret:
  cmp esi, 0
  jne .zero
  mov al, 4
  ret
.tilde:
  cmp esi, 3
  jne .zero
  mov al, 13
.zero:
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Presentation and software cursor
;//////////////////////////////////////////////////////////////////////////////

present_scene:
  call present_full
  call draw_pointer
  ret

present_full:
  xor ebx, ebx
.row:
  cmp ebx, [screen_height]
  jae .done
  mov eax, ebx
  imul eax, [screen_width]
  lea rsi, [backbuffer+rax*4]
  mov eax, ebx
  imul eax, [screen_pitch]
  lea rdi, [FRAMEBUFFER_VA+rax]
  mov ecx, [screen_width]
  rep movsd
  inc ebx
  jmp .row
.done:
  ret

present_pointer_move:
  mov edi, [old_pointer_x]
  mov esi, [old_pointer_y]
  mov edx, 14
  mov ecx, 20
  call present_rect
  mov edi, [pointer_x]
  mov esi, [pointer_y]
  mov edx, 14
  mov ecx, 20
  call present_rect
  call draw_pointer
  ret

;// EDI=x ESI=y EDX=w ECX=h, backbuffer -> framebuffer with clipping.
present_rect:
  push rbx
  push r12
  push r13
  push r14
  mov r12d, edi
  mov r13d, esi
  mov r14d, edx
  mov ebx, ecx
  cmp r12d, 0
  jl .done
  cmp r13d, 0
  jl .done
  mov eax, [screen_width]
  sub eax, r12d
  cmp r14d, eax
  jle .height
  mov r14d, eax
.height:
  mov eax, [screen_height]
  sub eax, r13d
  cmp ebx, eax
  jle .valid
  mov ebx, eax
.valid:
  test r14d, r14d
  jle .done
  test ebx, ebx
  jle .done
.row:
  mov eax, r13d
  imul eax, [screen_width]
  add eax, r12d
  lea rsi, [backbuffer+rax*4]
  mov eax, r13d
  imul eax, [screen_pitch]
  lea rdi, [FRAMEBUFFER_VA+rax]
  lea rdi, [rdi+r12*4]
  mov ecx, r14d
  rep movsd
  inc r13d
  dec ebx
  jnz .row
.done:
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

draw_pointer:
  xor ebx, ebx
.row:
  cmp ebx, 18
  jae .done
  mov ecx, ebx
  shr ecx, 1
  add ecx, 2
  xor r12d, r12d
.column:
  cmp r12d, ecx
  jae .next
  mov edi, [pointer_x]
  add edi, r12d
  mov esi, [pointer_y]
  add esi, ebx
  cmp edi, [screen_width]
  jae .skip
  cmp esi, [screen_height]
  jae .skip
  mov r8d, COLOR_TEXT
  test r12d, r12d
  jz .pixel
  mov eax, ecx
  dec eax
  cmp r12d, eax
  je .pixel
  mov r8d, 0xFF142335
.pixel:
  call framebuffer_pixel
.skip:
  inc r12d
  jmp .column
.next:
  inc ebx
  jmp .row
.done:
  ret

;// EDI=x, ESI=y, R8D=color.
framebuffer_pixel:
  mov eax, esi
  imul eax, [screen_pitch]
  lea rdx, [FRAMEBUFFER_VA+rax]
  mov [rdx+rdi*4], r8d
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Events, platform and registration
;//////////////////////////////////////////////////////////////////////////////

;// EDI=role, ESI=event.
queue_event:
  cmp edi, GUI_ROLE_DESKTOP
  je .desktop
  cmp qword [terminal_event_reply], 0
  jne deliver_event
  mov [terminal_pending_event], rsi
  ret
.desktop:
  cmp qword [desktop_event_reply], 0
  jne deliver_event
  mov [desktop_pending_event], rsi
  ret

deliver_event:
  push rbx
  push r12
  mov ebx, edi
  mov r12d, esi
  lea rdi, [out_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [out_message+IpcMessage.words], 0
  mov qword [out_message+IpcMessage.words+8], r12
  cmp ebx, GUI_ROLE_DESKTOP
  je .desktop
  mov rdi, qword [terminal_event_reply]
  jmp .send
.desktop:
  mov rdi, qword [desktop_event_reply]
.send:
  mov eax, SYS_IPC_SEND
  lea rsi, [out_message]
  syscall
  cmp rax, -11
  jne .close
  system_call SYS_YIELD
  jmp .send
.close:
  test rax, rax
  jnz .send_failed
  jmp .close_role
.send_failed:
  log event_send_failed_text, event_send_failed_text.size
.close_role:
  cmp ebx, GUI_ROLE_DESKTOP
  je .close_desktop
  mov rdi, qword [terminal_event_reply]
  call close_handle
  mov qword [terminal_event_reply], 0
  pop r12
  pop rbx
  ret
.close_desktop:
  mov rdi, qword [desktop_event_reply]
  call close_handle
  mov qword [desktop_event_reply], 0
  pop r12
  pop rbx
  ret

request_clock_update:
  cmp qword [platform_endpoint], 0
  je .done
.send:
  lea rdi, [platform_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [platform_message+IpcMessage.words], PLATFORM_POLL_TIME
  mov eax, SYS_IPC_SEND
  mov rdi, qword [platform_endpoint]
  lea rsi, [platform_message]
  syscall
  ret
.done:
  ret

request_power_off:
  cmp qword [platform_endpoint], 0
  jne .send
  jmp .done
.send:
  lea rdi, [platform_message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [platform_message+IpcMessage.words], PLATFORM_POWER_OFF
  mov eax, SYS_IPC_SEND
  mov rdi, qword [platform_endpoint]
  lea rsi, [platform_message]
  syscall
.done:
  ret

register_gui:
  lea rdi, [message]
  mov ecx, IpcMessage.bytes
  xor eax, eax
  rep stosb
  mov qword [message+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [message+IpcMessage.words+8], SERVICE_GUI
  mov qword [message+IpcMessage.words+16], 1
  mov qword [message+IpcMessage.cap_count], 1
  mov qword [message+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [message+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, message
  ret

initialize_shortcuts:
  cmp dword [shortcut_count], 0
  jne .done
  mov dword [shortcut_count], 2
  mov dword [shortcuts+0], 1       ;// Terminal
  mov dword [shortcuts+4], 34
  mov dword [shortcuts+8], 42
  mov dword [shortcuts+16], 2      ;// Trash
  mov dword [shortcuts+20], 34
  mov dword [shortcuts+24], 146
.done:
  ret

close_received_caps:
  mov rcx, qword [message+IpcMessage.cap_count]
  xor ebx, ebx
.next:
  cmp rbx, rcx
  jae .done
  mov rax, rbx
  shl rax, 4
  mov rdi, qword [message+IpcMessage.caps+rax+IpcCap.handle]
  push rcx
  call close_handle
  pop rcx
  inc rbx
  jmp .next
.done:
  ret

close_handle:
  test rdi, rdi
  jz .done
  close_cap rdi
.done:
  ret

segment readable
ready_text db "gui: VBE32 software compositor and UI ABI 1 ready", 10
.size = $-ready_text
desktop_ready_text db "VARANIA:DESKTOP_READY", 10
.size = $-desktop_ready_text
terminal_ready_text db "VARANIA:GTERM_WINDOW_READY", 10
.size = $-terminal_ready_text
failed_text db "gui: isolated framebuffer/compositor failure", 10
.size = $-failed_text
event_send_failed_text db "gui: event reply capability failed", 10
.size = $-event_send_failed_text
font_digits:
db 14,17,19,21,25,17,14, 4,12,4,4,4,4,14
db 14,17,1,2,4,8,31, 30,1,1,14,1,1,30
db 2,6,10,18,31,2,2, 31,16,16,30,1,1,30
db 14,16,16,30,17,17,14, 31,1,2,4,8,8,8
db 14,17,17,14,17,17,14, 14,17,17,15,1,1,14
font_letters:
db 14,17,17,31,17,17,17, 30,17,17,30,17,17,30
db 14,17,16,16,16,17,14, 30,17,17,17,17,17,30
db 31,16,16,30,16,16,31, 31,16,16,30,16,16,16
db 14,17,16,23,17,17,15, 17,17,17,31,17,17,17
db 14,4,4,4,4,4,14, 7,2,2,2,18,18,12
db 17,18,20,24,20,18,17, 16,16,16,16,16,16,31
db 17,27,21,21,17,17,17, 17,25,21,19,17,17,17
db 14,17,17,17,17,17,14, 30,17,17,30,16,16,16
db 14,17,17,17,21,18,13, 30,17,17,30,20,18,17
db 15,16,16,14,1,1,30, 31,4,4,4,4,4,4
db 17,17,17,17,17,17,14, 17,17,17,17,17,10,4
db 17,17,17,21,21,21,10, 17,17,10,4,10,17,17
db 17,17,10,4,4,4,4, 31,1,2,4,8,16,31
font_question db 14,17,1,2,4,0,4

text_start db "START",0
text_terminal db "TERMINAL",0
text_terminal_title db "VARANIA TERMINAL",0
text_trash db "TRASH",0
text_power db "POWER OFF",0
text_prompt db ">_",0
text_power_symbol db "!",0
text_minimize db "_",0
text_maximize db "[]",0
text_close db "X",0
text_app db "APP",0
wallpaper_path db "/system/assets/wallpapers/varania-default.bgra",0

align 4
vga_palette:
dd 0xFF0B111B,0xFF355CDE,0xFF3FB950,0xFF39C5CF
dd 0xFFE05252,0xFFB875D6,0xFFD19A3D,0xFFC9D1D9
dd 0xFF59636E,0xFF58A6FF,0xFF75D69C,0xFF79E2EA
dd 0xFFFF7B72,0xFFD2A8FF,0xFFFFC857,0xFFF0F6FC

segment readable writeable
align 8
screen_width dd 0
screen_height dd 0
screen_pitch dd 0
screen_bpp dd 0
desktop_active db 0
wallpaper_ready db 0
filesystem_connected db 0
start_menu_open db 0
terminal_open db 0
terminal_state db 1             ;// 1 normal, 2 minimized, 3 maximized
clock_hour db 0
clock_minute db 0
align 4
pointer_x dd 0
pointer_y dd 0
old_pointer_x dd 0
old_pointer_y dd 0
pointer_buttons dd 0
drag_window dd 0
drag_shortcut dd -1
drag_offset_x dd 0
drag_offset_y dd 0
window_x dd 120
window_y dd 86
window_w dd 1040
window_h dd 560
effective_x dd 0
effective_y dd 0
effective_w dd 0
effective_h dd 0
terminal_origin_x dd 0
terminal_origin_y dd 0
shortcut_count dd 0
align 8
pointer_serial dq 0
last_icon_click dq -1000
desktop_event_reply dq 0
terminal_event_reply dq 0
desktop_enter_reply dq 0
desktop_pending_event dq 0
terminal_pending_event dq 0
platform_endpoint dq 0
clock_text db "00:00",0
align 8
shortcuts rb 16*16
widgets rb WIDGET_COUNT*WIDGET_BYTES
ui_clients rb UI_CLIENT_COUNT*UI_CLIENT_BYTES
terminal_cells rb TERM_COLS*TERM_ROWS*2
message rb IpcMessage.bytes
out_message rb IpcMessage.bytes
platform_message rb IpcMessage.bytes

;// State, необходимый включённым vlib IPC/VFS. Это только ABI stubs;
;// renderer и компоненты выше остаются единственной server-side копией.
vlib_fs_endpoint dq 0
vlib_fs_buffer_cap dq 0
vlib_path_component rb 48
vlib_path_work rb VLIB_PATH_MAX+1
vlib_message rb IpcMessage.bytes
vlib_reply rb IpcMessage.bytes

align 4096
wallpaper_buffer rb MAX_PIXELS*4
backbuffer rb MAX_PIXELS*4
