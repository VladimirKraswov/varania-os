# Драйверы в пользовательском пространстве

## Модель

Драйвер — обычная ring-3 задача. При создании доверенный init/loader должен:

1. создать изолированное address space;
2. выдать endpoint для общения с другими сервисами;
3. выдать capability конкретного IRQ;
4. выдать минимальный диапазон I/O-портов с нужными правами;
5. запустить задачу без IOPL и без доступа к HHDM.

Текущий bootstrap делает это вручную для `user_keyboard_driver`:

| Handle | Тип | Объект | Права |
|---:|---|---|---|
| 1 | IRQ | IRQ1 | wait |
| 2 | I/O ports | `0x60..0x64` | read |

## Цикл PS/2-драйвера

```asm
.wait:
  mov eax, SYS_IRQ_WAIT
  mov edi, 1
  syscall

  mov eax, SYS_IO_READ8
  mov edi, 2
  xor esi, esi              ; base + 0 = 0x60
  syscall
  ; RAX содержит scan code
  jmp .wait
```

IRQ маскируется stub-ом и открывается следующим `SYS_IRQ_WAIT`. Поэтому драйвер
сначала читает/сбрасывает состояние устройства и лишь затем подтверждает
готовность принять следующее событие.

## Как добавить ещё один legacy-драйвер

1. Добавить IRQ stub и IDT gate по образцу `irq_1`.
2. В stub вызвать `pic_mask_irq`, `device_irq_notify`, `pic_send_eoi`.
3. Увеличить/настроить таблицу маршрутизации, если IRQ ещё не представлен.
4. Создать user blob или, после появления loader-а, загрузить ELF.
5. Выдать `capability_grant_irq` и `capability_grant_io` с минимальными правами.
6. Создать endpoint capability для протокола с другими сервисами.
7. Добавить QEMU-тест нормального события и тест отказа в чужом порту.

## Что потребуется для PCI/MMIO

Нельзя просто переиспользовать port I/O capability. Следующий слой должен
добавить отдельные типы объектов:

- read-only PCI configuration capability;
- MMIO range с отображением только в address space драйвера;
- DMA buffer и, на реальном железе, IOMMU domain;
- MSI/MSI-X interrupt object;
- отзыв capability при завершении/перезапуске драйвера.

До появления IOMMU драйвер с bus-master DMA не является полностью изолированным:
устройство способно записывать физическую память вне page tables CPU. Это
важное ограничение безопасности, а не деталь реализации.
