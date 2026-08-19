;//////////////////////////////////////////////////////////////////////////////
;// Slab allocator для маленьких объектов ядра
;//////////////////////////////////////////////////////////////////////////////
;
;// PMM выдаёт целые страницы, но TCB, capability и IPC-объекты обычно
;// намного меньше 4 KiB. Slab разрезает кадр на объекты одного размера.
;// Первые 16 байт каждого объекта — служебный header:
;//   +0  указатель на SlabClass;
;//   +8  следующий свободный объект.
;// Пока класс хранит один список и не возвращает полностью свободные slab-ы PMM.
;// Это осознанная простая политика для первой однопроцессорной версии.

SlabClass.head = 0
SlabClass.size = 8
SlabClass.bytes = 16
SlabHeader.class = 0
SlabHeader.next = 8
SlabHeader.bytes = 16

;// Одна строка макроса генерирует описатель класса. Число — полный
;// размер с header; полезная нагрузка на 16 байт меньше.
macro slab_class bytes
{
  dq 0, bytes
}

align 16
slab_classes:
  slab_class 32
  slab_class 64
  slab_class 128
  slab_class 256
  slab_class 512
  slab_class 1024
  slab_class 2048
slab_classes_end:
SLAB_CLASS_COUNT = (slab_classes_end-slab_classes)/SlabClass.bytes

function slab_init
  lea rax, [slab_classes]
  mov ecx, SLAB_CLASS_COUNT
  .next:
    mov qword [rax+SlabClass.head], 0 ;// размер, сгенерированный макросом, не трогаем
    add rax, SlabClass.bytes
    loop .next
endf

;// Найти минимальный класс для RDI полезных байт. RAX=SlabClass или 0.
leaf_function slab_find_class
  add rdi, SlabHeader.bytes
  lea rax, [slab_classes]
  mov ecx, SLAB_CLASS_COUNT
  .next:
    cmp rdi, [rax+SlabClass.size]
    jbe .done
    add rax, SlabClass.bytes
    loop .next
  xor eax, eax
  .done:
end_leaf

;// Заполнить пустой класс объектами из нового кадра. RDI=SlabClass. RAX=1/0.
function slab_grow
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rdi
  call pmm_alloc_frame
  test rax, rax
  jz .failed
  hhdm_address rbx, rax
  mov r13, [r12+SlabClass.size]
  mov rax, PAGE_SIZE
  xor edx, edx
  div r13
  mov ecx, eax
  .add_object:
    mov [rbx+SlabHeader.class], r12
    mov rax, [r12+SlabClass.head]
    mov [rbx+SlabHeader.next], rax
    mov [r12+SlabClass.head], rbx
    add rbx, r13
    loop .add_object
  mov eax, 1
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
endf

;// Выделить RDI байт. RAX=16-байтно выровненный указатель или 0.
function kmalloc
  push rbx
  sub rsp, 8
  call slab_find_class
  test rax, rax
  jz .failed
  mov rbx, rax
  cmp qword [rbx+SlabClass.head], 0
  jne .pop
  mov rdi, rbx
  call slab_grow
  test rax, rax
  jz .failed
  .pop:
  mov rax, [rbx+SlabClass.head]
  mov rdx, [rax+SlabHeader.next]
  mov [rbx+SlabClass.head], rdx
  add rax, SlabHeader.bytes
  jmp .done
  .failed:
  xor eax, eax
  .done:
  add rsp, 8
  pop rbx
endf

;// Вернуть RDI в slab. Неверный указатель игнорируется. RAX=1/0.
leaf_function kfree
  test rdi, rdi
  jz .failed
  mov rax, HHDM.base+PMM.memStart
  cmp rdi, rax
  jb .failed
  mov rax, HHDM.base+PMM.memEnd
  cmp rdi, rax
  jae .failed
  sub rdi, SlabHeader.bytes
  mov rdx, [rdi+SlabHeader.class]
  lea rax, [slab_classes]
  cmp rdx, rax
  jb .failed
  lea rcx, [slab_classes_end]
  cmp rdx, rcx
  jae .failed
  mov rax, rdx
  lea rcx, [slab_classes]
  sub rax, rcx
  test rax, SlabClass.bytes-1
  jnz .failed
  mov rax, [rdx+SlabClass.head]
  mov [rdi+SlabHeader.next], rax
  mov [rdx+SlabClass.head], rdi
  mov eax, 1
  ret
  .failed:
  xor eax, eax
end_leaf
