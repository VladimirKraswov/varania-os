include "PROC32.INC"
include "STRUCT.INC"
include "IF.INC"
;// Булев тип данных
bool  equ dword
true  equ 1
false equ 0
;// Отсутствие
null  equ 0
NULL  equ null
;// Адрес в памяти
addr  equ dword
;// Числовые данные
uint32 equ dword
uint16 equ word
uint8  equ byte

;// Используется при сохранении всех регистров при создании процедуры 
all_regs equ eax ecx edx ebx esp ebp esi edi 
;// Используется для сохранения всех регистров кроме EAX, для возврата значения
not_eax  equ ecx edx ebx esp ebp esi edi

;// Выход из процедуры с возвратом знасения
macro return result
{
  if result eq eax
    ret
  else
    push dword result
    pop  eax
    ret
  end if
}

;// Прервать цыкл
macro .break { jmp __ENDW }
;// Очистка регистра
macro clr reg { xor reg, reg }
;// Запись байта в порт
macro outb port, data
{
  push eax
  mov al, data
  out port, al
  pop eax
}
;// Запись слова в порт
macro outw port, data
{
  push eax
  mov ax, data
  out port, ax
  pop eax
}
;// Запись двойного слова в порт
macro outd port, data
{
  push eax
  mov eax, data
  out port, eax
  pop eax
}
;// Соответственно чтение данных из портов
macro inb reg, port { in reg, port }
macro inw reg, port { in reg, port }
macro ind reg, port { in reg, port }













