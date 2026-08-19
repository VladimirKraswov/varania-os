# История переноса Varania OS

## Исходная система

Версия 2019 года была монолитным 32-битным FASM-ядром: protected mode,
двухуровневый paging, `0xFFC00000`, IDT32, стековые `proc/stdcall`, фиксированные
32 MiB и драйверы VGA/PIC/PIT/PS2 в ring 0.

Исторические файлы сохранены рядом, но активная реализация находится в
`src/kernel/amd64/`.

## Сначала: корректный amd64

В незавершённом порте были найдены причины реальных triple fault:

1. paging включался без `CR4.PAE` и `IA32_EFER.LME`;
2. PML4/PDPT/PD entries считались 4-байтовыми вместо 8-байтовых;
3. очищалась половина 4096-байтовой таблицы;
4. невыровненный `0x100000` помещался в 2-MiB PDE;
5. TSS64 descriptor имел неверную раскладку/размер;
6. RSP0/IST1 записывались не по смещениям TSS64;
7. continuation key E820 принимался за число записей;
8. PMM мог выделить кадр собственной bitmap.

После исправлений загрузка стала воспроизводимой на Mac M1 и Linux/QEMU.

## Затем: от монолита к микроядру

| Область | Промежуточный порт | Текущее микроядро |
|---|---|---|
| direct map | небольшое верхнее окно | HHDM физ. 0..1 GiB |
| процессы | код ring 0 в mapped page | отдельные PML4 и ring 3 |
| syscall | `int 0x30` с raw pointer | `SYSCALL` + validation |
| планирование | только PIT ticks | preemptive round-robin |
| IPC | отсутствовал | capability IPC, очередь 8 сообщений |
| heap | bump allocator | PMM + slab `kmalloc/kfree` |
| драйвер PS/2 | ring 0 | ring 3 + IRQ/I/O caps |
| user fault | останавливал ядро | завершает один процесс |
| программы | встроенные flat blobs | ELF64 из initramfs, user/init |
| lifecycle | фиксированные задачи | spawn/wait, generations, teardown |
| supervision | отсутствовала | external kill + user-space restart policy |
| shared data | только копирование | refcounted shared-memory objects |
| revoke | плоские handles | lineage tree, ghost queue nodes, descendants revoke |

Identity map оставлена только в bootstrap PML4. Пользовательские PML4 получают
свою нижнюю половину и общую supervisor-only HHDM branch. GDT также
перезагружается HHDM-адресом перед первым переключением CR3.

## Ошибка, найденная первым fault-test

Старые stubs были записаны как:

```asm
exception_6: push 0; push 6; jmp exception_common
```

В FASM `;` начинает комментарий, поэтому собирался только `push 0`, а выполнение
проваливалось через последующие labels. Ошибка долго была скрыта, потому что
smoke-test не вызывал CPU exception. Теперь 32 stubs генерируются проверяемым
макросом `exception_stub`, а `isolation_test.elf` гарантированно вызывает #PF
при чтении supervisor HHDM.

## От встроенных blobs к ELF/init

Промежуточное микроядро создавало четыре задачи прямо из labels в
`kernel.asm`. Это доказывало ring 3, но смешивало kernel mechanism и boot policy.
Первый этап добавил raw initramfs, строгий ELF64 loader и system capability:
ядро знало `init.elf`, а состав сервисов определял user/init. Следующий этап
сдвинул границу ещё дальше: kernel bootstrap-ит только `procd.elf`, а procd в
ring 3 проверяет и загружает все остальные ELF через space/frame/map/thread.
Nameserver и endpoint capability transfer заменили передачу process cap как
IPC-канала.

Переход потребовал не только парсера ELF, но и полного lifecycle: частичная
ошибка загрузки обязана откатить frames, exit нельзя разрушать на текущем стеке,
а reuse slot-а требует generation, иначе старая capability создаёт ABA-уязвимость.

## Почему не выполнен механический перевод

Замена `EAX` на `RAX` не переносит ОС. В amd64 отличаются IDT/TSS, interrupt
frame, canonical addresses, page tables, ABI, вход syscall и граница
привилегий. Поэтому активный путь переписан по подсистемам, а старый код служит
учебным материалом для сравнения.
