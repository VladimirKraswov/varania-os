macro mem.addrToPDE _addres 
{  shr _addres, 22 } ;// Сдвигаем номер PDE дескриптора, стирая PTE и OFF

macro mem.addrToPTE _addres: addr
{
  shl _addres, 10 ;// Сдвигаем номер PTE дескриптора, стирая PDE
  shr _addres, 22 ;// Сдвигаем номер PTE дескриптора, стирая OFF
}

macro mem.addrToOffset _addres
{ and _addres, mem.PAGE_OFF_MASK } ;// Обнуляем PDE и PTE

macro mem.descToAddr _desc
{ and _desc, 0xFFFFF000 }
