 	
mouse.MOUSE_PORT   equ 0x60
mouse.MOUSE_STATUS equ 0x64
mouse.MOUSE_ABIT   equ 0x02
mouse.MOUSE_BBIT   equ 0x01
mouse.MOUSE_F_BIT  equ 0x20
mouse.MOUSE_V_BIT  equ 0x08


mouse.x dd 300 ;//начальное положение курсора
mouse.y dd 300 ;

mouse.lastX dd ?;
mouse.lastY dd ?;

mouse.cycle db 0 ;// uint8_t mouse_cycle=0;
mouse.byte rb 3  ;// int8_t mouse_byte[3]

mouse._x dd ? ;
mouse._y dd ? ;


proc mouse_wait uses eax, a_type: byte
  .if [a_type] = 0
    mov ecx, 100000
    @@:
      in al, 0x64
      and al, 1
      .if al = 1
        ret
      .endif
      loop @b
    ret
  .else
  mov ecx, 100000
  @@:
    in al, 0x64
    and al, 2
    .if al = 0
      ret
    .endif
    loop @b
  ret
  .endif
endp

proc mouse_write a_write: byte
  //Wait to be able to send a command
  stdcall mouse_wait, 1
  //Tell the mouse we are sending a command
  outb 0x64, 0xD4
  //Wait for the final part
  stdcall mouse_wait, 1
  //Finally write
  outb 0x60, [a_write]
endp


proc mouse_read
  clr eax
  //Get's response from mouse
  stdcall mouse_wait, 1
  in al, 0x60
  return eax
endp

mouse_handler(struct regs *r)
{

uint8_t status = inportb(MOUSE_STATUS);
while (status & MOUSE_BBIT) 
{
  int8_t mouse_in = inportb(MOUSE_PORT);
  if (status & MOUSE_F_BIT) 
  {
    switch(mouse_cycle)
    {
      case 0:
        mouse_byte[0]=inportb(0x60);
        mouse_cycle++;
        break;
      case 1:
        mouse_byte[1]=inportb(0x60);
        mouse_cycle++;
        break;
      case 2:
        mouse_byte[2]=inportb(0x60);
        if (mouse_byte[0] & 0x80 || mouse_byte[0] & 0x40)
        {
          /* x/y overflow? bad packet! */
          break;
        }
        mouse_x=mouse_byte[1];
        mouse_y=mouse_byte[2];

        if (mouse_byte[0] & 0x01) {
          PutLineh();
        }
        if (mouse_byte[0] & 0x02) {
        }
        if (mouse_byte[0] & 0x04) {
        }
        mousex=mousex+mouse_x; //получаем координаты курсора
        mousey=mousey-mouse_y;

        .if [mouse.x] < 0
          [mov mouse.x], 0
        .endif
        .if [mouse.y] < 0
          [mov mouse.y], 0
        .endif
        .if [mouse.x] > 1024
          [mov mouse.x], 1024
        .endif
        .if [mouse.y] > 768
          mov [mouse.y], 768
        .endif

        .if (mousex!=lastmousex || mousey!=lastmousey) //рисование курсора
          "movl lastmousex,%eax\n\t"
          "movl %eax,(xm)\n\t"
          "movl lastmousey,%ebx\n\t"
          "movl %ebx,(ym)\n\t"

           DelMouse(); //удаляем курсор, востанавливаем фон

          "movl mousex,%eax\n\t"
          "movl %eax,(xm)\n\t"
          "movl mousey,%ebx\n\t"
          "movl %ebx,(ym)\n\t"
          CopyFon(); //копируем фон под курсором
          PutMouse(); //выводим курсор
          lastmousex=mousex;
          lastmousey=mousey;
        .endif

        mouse_cycle=0;
        break;
      }
    }
    status = inportb(MOUSE_STATUS);
  }
  ret
endp


macro mouse_l.install
{
unsigned char _status; //unsigned char
cli
//Enable the auxiliary mouse device
mouse_wait(1);
outportb(0x64, 0xA8);

//Enable the interrupts
mouse_wait(1);
outportb(0x64, 0x20);
mouse_wait(0);
_status=(inportb(0x60) | 2);
mouse_wait(1);
outportb(0x64, 0x60);
mouse_wait(1);
outportb(0x60, _status);

//Tell the mouse to use default settings
mouse_write(0xF6);
mouse_read(); //Acknowledge

//Enable the mouse
mouse_write(0xF4);
mouse_read(); //Acknowledge

__asm__ __volatile__ ("sti");
irq_install_handler(12, mouse_handler);
}
