macro cmd.init
{
  mov eax, 0
  mov ecx, 1
  mov edx, 2
  mov ebx, 3
  mov esi, 6
  mov edi, 7
}


macro cmd.loop
{
  CMD_LOOP:
    tty.setTextColor tty.LIGHT_GREEN
    tty.prints "cmd:>"
    tty.setTextColor tty.WHITE

    tty.getLine strBuff, strBuff.lenght
    
    com.strcmp strBuff, help
    .if eax = true
      tty.prints "help - help", tty.ENDL
      tty.prints "clear - Clear screen", tty.ENDL
      tty.prints "pr - Print registers", tty.ENDL
      tty.prints "int - Call interrupt 3", tty.ENDL
    .endif

    com.strcmp strBuff, clear
    .if eax = true
      error.PANIC "ERROR!"
      tty.clear
    .endif

    com.strcmp strBuff, pr
    .if eax = true
      stdcall cmd_printReg
    .endif

    com.strcmp strBuff, _int_
    .if eax = true
      int 11
    .endif
  jmp CMD_LOOP
  
  strBuff rb 81
  strBuff.lenght  = $ - strBuff
  
  help   db "cmd:>help", 0
  clear  db "cmd:>clear"  , 0
  pr     db "cmd:>pr"  , 0
  _int_  db "cmd:>int", 0
}

proc cmd_printReg
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "EAX="
  tty.setTextColor tty.WHITE
  tty.printh eax, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "ECX="
  tty.setTextColor tty.WHITE
  tty.printh ecx, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "EDX="
  tty.setTextColor tty.WHITE
  tty.printh edx, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "EBX="
  tty.setTextColor tty.WHITE
  tty.printh ebx, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "ESP="
  tty.setTextColor tty.WHITE
  tty.printh esp, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "EBP="
  tty.setTextColor tty.WHITE
  tty.printh ebp, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "ESI="
  tty.setTextColor tty.WHITE
  tty.printh esi, tty.ENDL
  tty.setTextColor tty.LIGHT_BLUE
  tty.prints "EDI="
  tty.setTextColor tty.WHITE
  tty.printh edi, tty.ENDL
  ret
endp







    
