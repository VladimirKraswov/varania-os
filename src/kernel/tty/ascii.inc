tty.KEY_ENTER        equ 10
tty.KEY_BACKSPACE    equ 8
tty.KEY_RIGHT_SHIFFT equ 0x36
tty.KEY_LEFT_SHIFFT  equ 0x2A
tty.KEY_UP           equ 0x80

;// Таблица преобразования печатаемых скан-кодов в ASCII
align 4
tty.ascii:
  db 0
  db 0                            ;// ESC
  db '1234567890-='
  db 8                            ;// BACKSPACE
  db 0                            ;// TAB
  db 'qwertyuiop[]'
  db 10                           ;// ENTER
  db 0                            ;// CTRL
  db 'asdfghjkl;''`'
  db 0                            ;// LEFT SHIFT
  db '\zxcvbnm,./'
  db 0                            ;//  RIGHT SHIFT
  db '*'                          ;// NUMPAD
  db 0                            ;//  ALT
  db ' '                          ;// SPACE
  db 0                            ;// CAPSLOCK
  db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ;// F1 - F10
  db 0                            ;// NUMLOCK
  db 0                            ;// SCROLLLOCK
  db 0                            ;// HOME
  db 0
  db 0                            ;// PAGE UP
  db '-'                          ;//  NUMPAD
  db 0, 0
  db 0
  db '+'                          ;// NUMPAD
  db 0                            ;// END
  db 0
  db 0                            ;// PAGE DOWN
  db 0                            ;// INS
  db 0                            ;// DEL
  db 0                            ;// SYS RQ
  db 0
  db 0, 0                         ;// F11 - F12
  db 0
  db 0, 0, 0                      ;// F13 - F15
  db 0, 0, 0, 0, 0, 0, 0, 0, 0    ;// F16 - F24
  db 0, 0, 0, 0, 0, 0, 0, 0

align 4
tty.ascii_shifted:
  db 0
  db 0                            ;// ESC
  db '!@#$%^&*()_+'
  db 8                            ;// BACKSPACE
  db 0                            ;// TAB
  db 'QWERTYUIOP{}'
  db 10                           ;// ENTER
  db 0                            ;// CTRL
  db 'ASDFGHJKL:"~'
  db 0                            ;// LEFT SHIFT
  db '|ZXCVBNM<>?'
  db 0                            ;// RIGHT SHIFT
  db '*'                          ;// NUMPAD
  db 0                            ;// ALT
  db ' '                          ;// SPACE
  db 0                            ;// CAPSLOCK
  db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ;// F1 - F10
  db 0                            ;// NUMLOCK
  db 0                            ;// SCROLLLOCK
  db 0                            ;// HOME
  db 0
  db 0                            ;// PAGE UP
  db '-'                          ;// NUMPAD
  db 0, 0
  db 0
  db '+'                          ;// NUMPAD
  db 0                            ;// END
  db 0
  db 0                            ;// PAGE DOWN
  db 0                            ;// INS
  db 0                            ;// DEL
  db 0                            ;// SYS RQ
  db 0
  db 0, 0                         ;// F11 - F12
  db 0
  db 0, 0, 0                      ;// F13 - F15
  db 0, 0, 0, 0, 0, 0, 0, 0, 0    ;// F16 - F24
  db 0, 0, 0, 0, 0, 0, 0, 0
  