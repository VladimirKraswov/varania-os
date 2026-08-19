format ELF64 executable 3
entry start
include "../user/abi.inc"
include "../lib/runtime.inc"

;//////////////////////////////////////////////////////////////////////////////
;// VEdit — учебный полноэкранный редактор Varania OS
;//////////////////////////////////////////////////////////////////////////////
;
;// Редактор является эталонным клиентом libvarania. Он не владеет VGA/NVMe:
;// raw keys, цветные cells, файлы и процессы доступны только через versioned
;// capability services. Документ хранится в private address space редактора.

DOCUMENT_MAX = 128*1024
EDITOR_PATH_MAX = 191
TEXT_FIRST_ROW = 1
TEXT_ROWS      = 21
CODE_LEFT      = 6
CODE_WIDTH     = VGA_TEXT_WIDTH-CODE_LEFT

COLOR_NORMAL     = 0x07
COLOR_TITLE      = 0x1F
COLOR_STATUS     = 0x70
COLOR_HELP       = 0x17
COLOR_LINE       = 0x08
COLOR_COMMENT    = 0x0A
COLOR_STRING     = 0x0E
COLOR_NUMBER     = 0x0B
COLOR_IDENTIFIER = 0x09
COLOR_PUNCTUATION = 0x0D
COLOR_CURSOR     = 0x70

segment readable executable

start:
  mov rbp, rsp
  call editor_parse_arguments
  test rax, rax
  jnz editor_fatal
  call editor_make_output_path
  test rax, rax
  jnz editor_fatal
  call vlib_initialize
  test rax, rax
  jnz editor_fatal
  call editor_open_file
  test rax, rax
  jnz editor_fatal_connected

  call vlib_terminal_clear
  call editor_render
  log editor_ready_marker, editor_ready_marker.size

.event_loop:
  call vlib_terminal_read_key
  test rax, rax
  js editor_fatal_connected
  mov rbx, rax
  call editor_handle_key
  cmp eax, 1
  je editor_exit
  cmp eax, 2
  je .event_loop                 ;// оставить FASM diagnostics до следующей клавиши
  cmp eax, 3
  je .full_render
  call editor_render_fast
  jmp .event_loop
.full_render:
  call editor_render
  jmp .event_loop

editor_exit:
  call vlib_terminal_clear
  call vlib_shutdown
  log editor_exit_marker, editor_exit_marker.size
  exit_process 0

editor_fatal_connected:
  call vlib_terminal_clear
  lea rdi, [fatal_text]
  mov esi, fatal_text.size
  call vlib_terminal_write
  call vlib_shutdown
editor_fatal:
  log editor_failed_marker, editor_failed_marker.size
  exit_process 1

;// RBX=key event. RAX=1 означает завершить редактор.
editor_handle_key:
  mov rax, rbx
  shr rax, 32
  test al, 2                     ;// KEY_MOD_CTRL >> 32
  jnz .control
  mov eax, ebx                   ;// младший key code
  cmp eax, KEY_LEFT
  je .left
  cmp eax, KEY_RIGHT
  je .right
  cmp eax, KEY_UP
  je .up
  cmp eax, KEY_DOWN
  je .down
  cmp eax, KEY_HOME
  je .home
  cmp eax, KEY_END
  je .end
  cmp eax, KEY_DELETE
  je .delete
  cmp eax, KEY_PAGE_UP
  je .page_up
  cmp eax, KEY_PAGE_DOWN
  je .page_down
  cmp eax, KEY_F1
  je .help
  cmp eax, KEY_F2
  je .debug
  cmp eax, KEY_F5
  je .build
  cmp eax, KEY_F6
  je .run
  cmp eax, KEY_F7
  je .template
  cmp eax, KEY_F10
  je .quit
  cmp eax, 27
  je .quit
  cmp eax, 8
  je .backspace
  cmp eax, 10
  je .newline
  cmp eax, 9
  je .tab
  cmp eax, 32
  jb .ignored
  cmp eax, 126
  ja .ignored
  mov dil, al
  call editor_insert_byte
  jmp .continue

.control:
  mov eax, ebx
  or al, 32                     ;// Ctrl+S/Q/O работают в обоих регистрах
  cmp al, 's'
  je .save
  cmp al, 'q'
  je .quit
  jmp .ignored
.save:
  call editor_save_file
  jmp .continue
.quit:
  cmp byte [document_dirty], 0
  je .finish
  mov qword [status_message], unsaved_text
  jmp .continue
.finish:
  mov eax, 1
  ret
.left:
  cmp qword [cursor_offset], 0
  je .continue
  dec qword [cursor_offset]
  jmp .full_render
.right:
  mov rax, [cursor_offset]
  cmp rax, [document_length]
  jae .continue
  inc qword [cursor_offset]
  jmp .full_render
.up:
  call editor_move_up
  jmp .full_render
.down:
  call editor_move_down
  jmp .full_render
.home:
  mov rdi, [cursor_offset]
  call editor_line_start
  mov [cursor_offset], rax
  jmp .full_render
.end:
  mov rdi, [cursor_offset]
  call editor_line_end
  mov [cursor_offset], rax
  jmp .full_render
.delete:
  call editor_delete
  jmp .full_render
.backspace:
  call editor_backspace
  jmp .full_render
.newline:
  mov dil, 10
  call editor_insert_byte
  jmp .full_render
.tab:
  mov dil, ' '
  call editor_insert_byte
  mov dil, ' '
  call editor_insert_byte
  jmp .continue
.page_up:
  mov ecx, TEXT_ROWS
.page_up_loop:
  push rcx
  call editor_move_up
  pop rcx
  loop .page_up_loop
  jmp .full_render
.page_down:
  mov ecx, TEXT_ROWS
.page_down_loop:
  push rcx
  call editor_move_down
  pop rcx
  loop .page_down_loop
  jmp .full_render
.help:
  mov qword [status_message], help_status_text
  jmp .continue
.debug:
  xor byte [debug_mode], 1
  jmp .continue
.template:
  call editor_insert_template
  jmp .full_render
.build:
  call editor_build
  test rax, rax
  jnz .preserve_diagnostics
  jmp .full_render
.run:
  call editor_run
  test rax, rax
  jnz .preserve_diagnostics
  jmp .full_render
.preserve_diagnostics:
  mov eax, 2
  ret
.full_render:
  mov eax, 3
  ret
.continue:
.ignored:
  xor eax, eax
  ret

;// Прочитать argv[1]; без аргумента создаётся /system/new.asm.
editor_parse_arguments:
  mov rax, [rbp]
  cmp rax, 2
  jb .default
  mov rsi, [rbp+16]
  jmp .copy
.default:
  lea rsi, [default_path]
.copy:
  lea rdi, [file_path]
  mov edx, EDITOR_PATH_MAX+1
  call vlib_string_copy
  test rax, rax
  js .done
  xor eax, eax
.done:
  ret

;// output path: name.asm -> name.elf, иначе добавляется .elf.
editor_make_output_path:
  lea rdi, [output_path]
  lea rsi, [file_path]
  mov edx, EDITOR_PATH_MAX+1
  call vlib_string_copy
  test rax, rax
  js .done
  mov rcx, rax
  cmp rcx, 4
  jb .append
  cmp dword [output_path+rcx-4], '.asm'
  jne .append
  mov dword [output_path+rcx-4], '.elf'
  xor eax, eax
  ret
.append:
  cmp rcx, EDITOR_PATH_MAX-4
  ja .too_long
  mov dword [output_path+rcx], '.elf'
  mov byte [output_path+rcx+4], 0
  xor eax, eax
  ret
.too_long:
  mov rax, VLIB_ERR_TOO_LONG
.done:
  ret

;// Открыть существующий файл или создать пустой. Размер редактор намеренно
;// ограничивает 128 KiB: это защищает учебный UI от случайного бинарного файла.
editor_open_file:
  lea rdi, [file_path]
  call vlib_fs_resolve
  cmp rax, VLIB_ERR_NOT_FOUND
  je .create
  test rax, rax
  js .done
  cmp rdx, FS_NODE_FILE
  jne .invalid
  mov [file_object], rax
  mov rdi, rax
  call vlib_fs_stat
  test rax, rax
  jnz .done
  cmp rdx, DOCUMENT_MAX
  ja .too_large
  mov [document_length], rdx
  test rdx, rdx
  jz .success
  mov rdi, [file_object]
  xor esi, esi
  mov r10, document
  call vlib_fs_read
  test rax, rax
  js .done
  cmp rax, [document_length]
  jne .io_error
  jmp .success
.create:
  lea rdi, [file_path]
  call vlib_fs_create
  test rax, rax
  js .done
  mov [file_object], rax
  mov qword [status_message], created_text
.success:
  xor eax, eax
  ret
.invalid:
  mov rax, VLIB_ERR_INVALID
  ret
.too_large:
  mov rax, VLIB_ERR_TOO_LONG
  ret
.io_error:
  mov rax, VLIB_ERR_IO
.done:
  ret

editor_save_file:
  mov rdi, [file_object]
  xor esi, esi
  mov rdx, [document_length]
  mov r10, document
  mov r8d, FS_WRITE_TRUNCATE
  call vlib_fs_write
  test rax, rax
  js .failed
  cmp rax, [document_length]
  jne .failed
  mov byte [document_dirty], 0
  mov qword [status_message], saved_text
  log editor_saved_marker, editor_saved_marker.size
  xor eax, eax
  ret
.failed:
  mov qword [status_message], save_failed_text
  mov rax, VLIB_ERR_IO
  ret

;// F5: save -> /bin/fasm.elf source output. F6 запускает output ELF.
editor_build:
  call editor_save_file
  test rax, rax
  jnz .failed
  call editor_make_fasm_command
  test rax, rax
  jnz .failed
  lea rdi, [fasm_path]
  lea rsi, [command_line]
  call vlib_process_run
  test rax, rax
  jnz .failed
  mov byte [build_ready], 1
  mov qword [status_message], build_ok_text
  log editor_build_marker, editor_build_marker.size
  xor eax, eax
  ret
.failed:
  mov byte [build_ready], 0
  mov qword [status_message], build_failed_text
  mov rax, VLIB_ERR_IO
  ret

editor_run:
  cmp byte [build_ready], 1
  je .start
  call editor_build
  test rax, rax
  jnz .failed
.start:
  lea rdi, [output_path]
  lea rsi, [output_path]
  call vlib_process_run
  test rax, rax
  jnz .failed
  mov qword [status_message], run_ok_text
  log editor_run_marker, editor_run_marker.size
  xor eax, eax
  ret
.failed:
  mov qword [status_message], run_failed_text
  mov rax, VLIB_ERR_IO
  ret

editor_make_fasm_command:
  lea rdi, [command_line]
  lea rsi, [fasm_argv0]
  mov edx, 512
  call vlib_string_copy
  test rax, rax
  js .done
  mov rbx, rax
  mov byte [command_line+rbx], ' '
  inc rbx
  lea rdi, [command_line+rbx]
  lea rsi, [file_path]
  mov rdx, 512
  sub rdx, rbx
  call vlib_string_copy
  test rax, rax
  js .done
  add rbx, rax
  mov byte [command_line+rbx], ' '
  inc rbx
  lea rdi, [command_line+rbx]
  lea rsi, [output_path]
  mov rdx, 512
  sub rdx, rbx
  call vlib_string_copy
  test rax, rax
  js .done
  xor eax, eax
.done:
  ret

;// F7 безопасен: шаблон заменяет только пустой документ.
editor_insert_template:
  cmp qword [document_length], 0
  jne .not_empty
  lea rsi, [program_template]
  lea rdi, [document]
  mov ecx, program_template.size
  rep movsb
  mov qword [document_length], program_template.size
  mov qword [cursor_offset], program_template.size
  mov byte [document_dirty], 1
  mov byte [build_ready], 0
  mov qword [status_message], template_ok_text
  log editor_template_marker, editor_template_marker.size
  ret
.not_empty:
  mov qword [status_message], template_refused_text
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Модель документа
;//////////////////////////////////////////////////////////////////////////////

;// DIL=byte. Вставка сдвигает хвост назад; document остаётся плотным массивом.
;// Сохраняем символ до загрузки адреса назначения в RDI: DIL является младшей
;// частью RDI, поэтому без этого вставка внутри строки зависела бы от младшего
;// байта адреса document+length, а не от нажатой клавиши.
editor_insert_byte:
  mov r8b, dil
  mov rax, [document_length]
  cmp rax, DOCUMENT_MAX
  jae .full
  mov rdx, [cursor_offset]
  mov rcx, rax
  sub rcx, rdx
  jz .store
  lea rsi, [document+rax-1]
  lea rdi, [document+rax]
  std
  rep movsb
  cld
.store:
  mov [document+rdx], r8b
  inc qword [document_length]
  inc qword [cursor_offset]
  mov byte [document_dirty], 1
  mov byte [build_ready], 0
  mov qword [status_message], editing_text
  ret
.full:
  mov qword [status_message], full_text
  ret

editor_backspace:
  mov rdx, [cursor_offset]
  test rdx, rdx
  jz .done
  mov rax, [document_length]
  mov rcx, rax
  sub rcx, rdx
  lea rsi, [document+rdx]
  lea rdi, [document+rdx-1]
  rep movsb
  dec qword [cursor_offset]
  dec qword [document_length]
  mov byte [document_dirty], 1
  mov byte [build_ready], 0
.done:
  ret

editor_delete:
  mov rdx, [cursor_offset]
  mov rax, [document_length]
  cmp rdx, rax
  jae .done
  mov rcx, rax
  sub rcx, rdx
  dec rcx
  lea rsi, [document+rdx+1]
  lea rdi, [document+rdx]
  rep movsb
  dec qword [document_length]
  mov byte [document_dirty], 1
  mov byte [build_ready], 0
.done:
  ret

;// RDI=offset, RAX=начало логической строки.
editor_line_start:
  mov rax, rdi
.scan:
  test rax, rax
  jz .done
  cmp byte [document+rax-1], 10
  je .done
  dec rax
  jmp .scan
.done:
  ret

;// RDI=offset, RAX=позиция newline или EOF.
editor_line_end:
  mov rax, rdi
  mov rdx, [document_length]
.scan:
  cmp rax, rdx
  jae .done
  cmp byte [document+rax], 10
  je .done
  inc rax
  jmp .scan
.done:
  ret

editor_move_up:
  mov rdi, [cursor_offset]
  call editor_line_start
  mov rbx, rax                    ;// current start
  mov rcx, [cursor_offset]
  sub rcx, rbx                    ;// desired column
  test rbx, rbx
  jz .done
  lea rdi, [rbx-1]
  call editor_line_start
  mov r12, rax                    ;// previous start
  mov rdi, r12
  call editor_line_end
  sub rax, r12                    ;// previous length
  cmp rcx, rax
  jbe .column_ready
  mov rcx, rax
.column_ready:
  lea rax, [r12+rcx]
  mov [cursor_offset], rax
.done:
  ret

editor_move_down:
  mov rdi, [cursor_offset]
  call editor_line_start
  mov rbx, rax
  mov rcx, [cursor_offset]
  sub rcx, rbx
  mov rdi, rbx
  call editor_line_end
  cmp rax, [document_length]
  jae .done
  lea r12, [rax+1]                ;// next start
  mov rdi, r12
  call editor_line_end
  sub rax, r12
  cmp rcx, rax
  jbe .column_ready
  mov rcx, rax
.column_ready:
  lea rax, [r12+rcx]
  mov [cursor_offset], rax
.done:
  ret

;//////////////////////////////////////////////////////////////////////////////
;// Renderer: 80x25 VGA cells через terminal.vlib
;//////////////////////////////////////////////////////////////////////////////

editor_render:
  call editor_update_view
  call editor_render_title

  mov r12, [view_offset]
  mov r13, [view_line_number]
  xor r14d, r14d
.source_row:
  cmp r14d, TEXT_ROWS
  jae .source_done
  mov edi, r14d
  add edi, TEXT_FIRST_ROW
  mov rsi, r12
  mov rdx, r13
  call editor_render_source_row
  mov r12, rax
  inc r13
  inc r14d
  jmp .source_row
.source_done:
  call editor_render_cursor
  call editor_render_status
  call editor_render_help
  xor eax, eax
  ret

;// Обычный printable-ввод меняет только текущую строку, title/status и cursor.
;// Это 12 коротких DRAW вместо примерно 100 IPC-сообщений полного экрана.
;// Если viewport сдвинулся, безопасно возвращаемся к полной перерисовке.
editor_render_fast:
  mov rax, [view_offset]
  mov [previous_view_offset], rax
  mov rax, [horizontal_offset]
  mov [previous_horizontal_offset], rax
  call editor_update_view
  mov rax, [view_offset]
  cmp rax, [previous_view_offset]
  jne .full
  mov rax, [horizontal_offset]
  cmp rax, [previous_horizontal_offset]
  jne .full

  call editor_render_title
  mov edi, dword [cursor_screen_row]
  add edi, TEXT_FIRST_ROW
  mov rsi, [cursor_line_start]
  mov rdx, [view_line_number]
  add rdx, [cursor_screen_row]
  call editor_render_source_row
  call editor_render_cursor
  call editor_render_status
  xor eax, eax
  ret
.full:
  call editor_render
  ret

;// Поддержать cursor внутри вертикального и горизонтального viewport.
editor_update_view:
  mov rdi, [cursor_offset]
  call editor_line_start
  mov [cursor_line_start], rax
  mov rcx, [cursor_offset]
  sub rcx, rax
  mov [cursor_column], rcx
  cmp rax, [view_offset]
  jae .count_rows
  mov [view_offset], rax
.count_rows:
  xor edx, edx
  mov rax, [view_offset]
.row_scan:
  cmp rax, [cursor_line_start]
  jae .row_known
  cmp byte [document+rax], 10
  jne .next_byte
  inc edx
.next_byte:
  inc rax
  jmp .row_scan
.row_known:
  cmp edx, TEXT_ROWS
  jb .vertical_ready
  ;// Сдвигать top на строку, пока cursor не попадёт в последнюю видимую.
  mov rax, [view_offset]
.next_top:
  cmp rax, [document_length]
  jae .vertical_ready
  cmp byte [document+rax], 10
  je .advance_top
  inc rax
  jmp .next_top
.advance_top:
  inc rax
  mov [view_offset], rax
  jmp .count_rows
.vertical_ready:
  mov [cursor_screen_row], rdx
  mov rax, [cursor_column]
  cmp rax, [horizontal_offset]
  jae .right_edge
  mov [horizontal_offset], rax
.right_edge:
  mov rcx, [horizontal_offset]
  add rcx, CODE_WIDTH
  cmp rax, rcx
  jb .horizontal_ready
  sub rax, CODE_WIDTH-1
  mov [horizontal_offset], rax
.horizontal_ready:
  ;// Номер первой видимой строки вычисляется по исходному документу.
  mov rdx, 1
  xor eax, eax
.line_number:
  cmp rax, [view_offset]
  jae .line_number_ready
  cmp byte [document+rax], 10
  jne .line_number_next
  inc rdx
.line_number_next:
  inc rax
  jmp .line_number
.line_number_ready:
  mov [view_line_number], rdx
  ret

editor_render_title:
  mov al, ' '
  mov ah, COLOR_TITLE
  call editor_fill_cells
  lea rsi, [title_text]
  mov edi, 1
  mov ecx, title_text.size
  mov dl, COLOR_TITLE
  call editor_put_bytes
  lea rsi, [file_path]
  mov edi, 15
  mov ecx, 62
  mov dl, COLOR_TITLE
  call editor_put_z
  cmp byte [document_dirty], 0
  je .draw
  mov word [screen_cells+78*2], (COLOR_TITLE shl 8)+'*'
.draw:
  xor esi, esi
  xor edx, edx
  call editor_draw_cells
  ret

;// EDI=screen row, RSI=document line start, RDX=line number.
;// RAX=начало следующей строки (либо EOF).
editor_render_source_row:
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, 8
  mov [rsp], rdi
  mov r12, rsi
  mov r13, rdx
  mov al, ' '
  mov ah, COLOR_NORMAL
  call editor_fill_cells
  cmp r12, [document_length]
  ja .blank
  mov rax, r13
  mov edi, 0
  mov dl, COLOR_LINE
  call editor_put_decimal4
  mov word [screen_cells+4*2], (COLOR_LINE shl 8)+':'

  xor r14d, r14d                 ;// logical column
  xor r15d, r15d                 ;// quote byte, 0 outside string
.character:
  mov rax, r12
  add rax, r14
  cmp rax, [document_length]
  jae .line_end
  mov bl, [document+rax]
  cmp bl, 10
  je .newline
  mov bh, COLOR_NORMAL
  test r15b, r15b
  jnz .inside_string
  cmp bl, ';'
  je .comment
  cmp bl, 34
  je .begin_string
  cmp bl, 39
  je .begin_string
  cmp bl, '0'
  jb .identifier
  cmp bl, '9'
  jbe .number
.identifier:
  cmp bl, 'A'
  jb .punctuation
  cmp bl, 'Z'
  jbe .identifier_color
  cmp bl, '_'
  je .identifier_color
  cmp bl, 'a'
  jb .punctuation
  cmp bl, 'z'
  jbe .identifier_color
.punctuation:
  cmp bl, ' '
  je .colored
  mov bh, COLOR_PUNCTUATION
  jmp .colored
.identifier_color:
  mov bh, COLOR_IDENTIFIER
  jmp .colored
.number:
  mov bh, COLOR_NUMBER
  jmp .colored
.begin_string:
  mov r15b, bl
  mov bh, COLOR_STRING
  jmp .colored
.inside_string:
  mov bh, COLOR_STRING
  cmp bl, r15b
  jne .colored
  xor r15d, r15d
.colored:
  mov rax, r14
  sub rax, [horizontal_offset]
  js .next
  cmp rax, CODE_WIDTH
  jae .next
  add rax, CODE_LEFT
  mov word [screen_cells+rax*2], bx
.next:
  inc r14
  jmp .character
.comment:
  mov rax, r14
.comment_loop:
  mov rcx, r12
  add rcx, rax
  cmp rcx, [document_length]
  jae .line_end
  mov bl, [document+rcx]
  cmp bl, 10
  je .newline_from_rax
  mov rcx, rax
  sub rcx, [horizontal_offset]
  js .comment_next
  cmp rcx, CODE_WIDTH
  jae .comment_next
  add rcx, CODE_LEFT
  mov bh, COLOR_COMMENT
  mov word [screen_cells+rcx*2], bx
.comment_next:
  inc rax
  jmp .comment_loop
.newline_from_rax:
  mov r14, rax
.newline:
  lea rax, [r12+r14+1]
  jmp .draw
.line_end:
  mov rax, [document_length]
  inc rax                         ;// последующие screen rows уже пусты
  jmp .draw
.blank:
  mov rax, r12
.draw:
  push rax
  xor esi, esi
  mov edx, [rsp+8]
  call editor_draw_cells
  pop rax
  add rsp, 8
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  ret

editor_render_cursor:
  mov rax, [cursor_column]
  sub rax, [horizontal_offset]
  js .done
  cmp rax, CODE_WIDTH
  jae .done
  add rax, CODE_LEFT
  mov rdx, [cursor_screen_row]
  add rdx, TEXT_FIRST_ROW
  cmp rdx, TEXT_FIRST_ROW+TEXT_ROWS
  jae .done
  ;// Перерисовать только cell курсора инверсным атрибутом.
  mov rdi, [cursor_offset]
  mov bl, ' '
  cmp rdi, [document_length]
  jae .have_character
  cmp byte [document+rdi], 10
  je .have_character
  mov bl, [document+rdi]
.have_character:
  mov byte [screen_cells], bl
  mov byte [screen_cells+1], COLOR_CURSOR
  lea rdi, [screen_cells]
  mov esi, eax
  mov ecx, 1
  call vlib_terminal_draw
.done:
  ret

editor_render_status:
  mov al, ' '
  mov ah, COLOR_STATUS
  call editor_fill_cells
  cmp byte [debug_mode], 0
  jne .debug
  mov rsi, [status_message]
  mov edi, 1
  mov ecx, 78
  mov dl, COLOR_STATUS
  call editor_put_z
  jmp .draw
.debug:
  lea rsi, [debug_text]
  mov edi, 1
  mov ecx, debug_text.size
  mov dl, COLOR_STATUS
  call editor_put_bytes
  mov rax, [cursor_offset]
  mov edi, 11
  mov dl, COLOR_STATUS
  call editor_put_hex64
  lea rsi, [debug_length_text]
  mov edi, 29
  mov ecx, debug_length_text.size
  mov dl, COLOR_STATUS
  call editor_put_bytes
  mov rax, [document_length]
  mov edi, 34
  mov dl, COLOR_STATUS
  call editor_put_hex64
  lea rsi, [debug_column_text]
  mov edi, 52
  mov ecx, debug_column_text.size
  mov dl, COLOR_STATUS
  call editor_put_bytes
  mov rax, [cursor_column]
  mov edi, 57
  mov dl, COLOR_STATUS
  call editor_put_hex64
.draw:
  xor esi, esi
  mov edx, 22
  call editor_draw_cells
  ret

editor_render_help:
  mov al, ' '
  mov ah, COLOR_HELP
  call editor_fill_cells
  lea rsi, [help_line1]
  xor edi, edi
  mov ecx, help_line1.size
  mov dl, COLOR_HELP
  call editor_put_bytes
  xor esi, esi
  mov edx, 23
  call editor_draw_cells
  mov al, ' '
  mov ah, COLOR_HELP
  call editor_fill_cells
  lea rsi, [help_line2]
  xor edi, edi
  mov ecx, help_line2.size
  mov dl, COLOR_HELP
  call editor_put_bytes
  xor esi, esi
  mov edx, 24
  call editor_draw_cells
  ret

;// AL=character, AH=attribute.
editor_fill_cells:
  lea rdi, [screen_cells]
  mov ecx, VGA_TEXT_WIDTH
  rep stosw
  ret

;// RDI=column, RSI=bytes, ECX=count, DL=attribute.
editor_put_bytes:
  xor eax, eax
.byte:
  test ecx, ecx
  jz .done
  cmp edi, VGA_TEXT_WIDTH
  jae .done
  mov al, [rsi]
  mov ah, dl
  mov word [screen_cells+rdi*2], ax
  inc rsi
  inc edi
  dec ecx
  jmp .byte
.done:
  ret

;// RDI=column, RSI=NUL text, ECX=max cells, DL=attribute.
editor_put_z:
  xor eax, eax
.byte:
  test ecx, ecx
  jz .done
  cmp edi, VGA_TEXT_WIDTH
  jae .done
  mov al, [rsi]
  test al, al
  jz .done
  mov ah, dl
  mov word [screen_cells+rdi*2], ax
  inc rsi
  inc edi
  dec ecx
  jmp .byte
.done:
  ret

;// RAX=value, EDI=column, DL=attribute; ровно четыре decimal digits.
editor_put_decimal4:
  push rbx
  push rcx
  push r8
  push r9
  push r10
  push r11
  mov r9b, dl
  xor edx, edx
  mov ebx, 10000
  div rbx
  mov r10, rdx                    ;// показываем последние четыре цифры
  mov ebx, 1000
  mov ecx, 4
.digit:
  mov rax, r10
  xor edx, edx
  div rbx
  mov r10, rdx
  add al, '0'
  mov byte [screen_cells+rdi*2], al
  mov byte [screen_cells+rdi*2+1], r9b
  mov rax, rbx
  xor edx, edx
  mov r11d, 10
  div r11
  mov rbx, rax
  inc edi
  dec ecx
  jnz .digit
  pop r11
  pop r10
  pop r9
  pop r8
  pop rcx
  pop rbx
  ret

;// RAX=value, EDI=column, DL=attribute; 16 hexadecimal digits.
editor_put_hex64:
  push rbx
  push rcx
  push r8
  mov r8b, dl
  mov ecx, 16
.digit:
  rol rax, 4
  mov bl, al
  and bl, 0x0F
  cmp bl, 9
  jbe .number
  add bl, 'A'-10
  jmp .store
.number:
  add bl, '0'
.store:
  mov byte [screen_cells+rdi*2], bl
  mov byte [screen_cells+rdi*2+1], r8b
  inc edi
  dec ecx
  jnz .digit
  pop r8
  pop rcx
  pop rbx
  ret

;// RSI=x, EDX=y; вывести полную prepared row.
editor_draw_cells:
  lea rdi, [screen_cells]
  mov ecx, VGA_TEXT_WIDTH
  call vlib_terminal_draw
  ret

segment readable writeable

editor_ready_marker db "VARANIA:EDITOR_READY", 10
.size = $-editor_ready_marker
editor_saved_marker db "VARANIA:EDITOR_SAVED", 10
.size = $-editor_saved_marker
editor_template_marker db "VARANIA:EDITOR_TEMPLATE_INSERTED", 10
.size = $-editor_template_marker
editor_build_marker db "VARANIA:EDITOR_BUILD_OK", 10
.size = $-editor_build_marker
editor_run_marker db "VARANIA:EDITOR_RUN_OK", 10
.size = $-editor_run_marker
editor_exit_marker db "VARANIA:EDITOR_EXIT", 10
.size = $-editor_exit_marker
editor_failed_marker db "VARANIA:EDITOR_FAILED", 10
.size = $-editor_failed_marker

title_text db "VEdit ABI 1 | ", 0
.size = $-title_text-1
help_line1 db " Ctrl+S Save | Ctrl+Q Quit | F2 Debug | F5 Build | F6 Run | F7 Template"
.size = $-help_line1
help_line2 db " Arrows/Home/End/PgUp/PgDn | Backspace/Delete | Tab = two spaces"
.size = $-help_line2
debug_text db "DEBUG off="
.size = $-debug_text
debug_length_text db " len="
.size = $-debug_length_text
debug_column_text db " col="
.size = $-debug_column_text

opened_text db "File opened. F1 shows shortcuts.", 0
created_text db "New empty file created. Press F7 for a minimal program.", 0
editing_text db "Modified", 0
saved_text db "Saved to VaraniaFS", 0
unsaved_text db "Unsaved changes: Ctrl+S to save, then Ctrl+Q", 0
help_status_text db "F5 saves+builds; F6 runs the last build; F2 shows offsets", 0
full_text db "Document limit is 128 KiB", 0
save_failed_text db "Save failed", 0
build_ok_text db "Build completed successfully", 0
build_failed_text db "Build failed; press any key after reading FASM diagnostics", 0
run_ok_text db "Program exited successfully", 0
run_failed_text db "Program could not be built or started", 0
template_ok_text db "Minimal Varania program inserted", 0
template_refused_text db "Template is inserted only into an empty document", 0
fatal_text db "VEdit: cannot initialize services or open file", 10
.size = $-fatal_text

default_path db "/system/new.asm", 0
fasm_path db "/bin/fasm.elf", 0
fasm_argv0 db "fasm.elf", 0

program_template:
db "format ELF64 executable 3", 10
db "entry start", 10
db "include '/system/src/user/abi.inc'", 10, 10
db "; Minimal Varania OS program", 10
db "segment readable executable", 10
db "start:", 10
db "  log message, message.size", 10
db "  exit_process 0", 10, 10
db "segment readable writeable", 10
db 'message db "VARANIA:EDITOR_TEMPLATE_OK", 10', 10
db ".size = $-message", 10
.size = $-program_template

align 8
file_object dq 0
document_length dq 0
cursor_offset dq 0
cursor_line_start dq 0
cursor_column dq 0
cursor_screen_row dq 0
view_offset dq 0
view_line_number dq 1
horizontal_offset dq 0
previous_view_offset dq 0
previous_horizontal_offset dq 0
status_message dq opened_text
document_dirty db 0
debug_mode db 0
build_ready db 0
align 8
file_path rb EDITOR_PATH_MAX+1
output_path rb EDITOR_PATH_MAX+1
command_line rb 512
screen_cells rb VGA_TEXT_WIDTH*2
document rb DOCUMENT_MAX
