# VEdit — системный редактор кода

VEdit — полноэкранная ring-3 программа `/bin/edit.elf`. Она не обращается к
VGA, PS/2 или NVMe напрямую: input/rendering, файлы и запуск процессов идут
через `libvarania` и versioned capability services.

## Запуск

Из любого каталога shell:

```text
edit /system/build/hello.asm
```

Если файла нет, VEdit создаёт его через `FS_CREATE`; существующий текст до
128 KiB загружается streaming-read. Относительный путь shell превращает в
абсолютный относительно текущего каталога.

## Клавиши

| Клавиша | Действие |
|---|---|
| стрелки, Home/End | перемещение курсора |
| PageUp/PageDown | переход на 21 строку |
| Backspace/Delete | удаление до/после курсора |
| Enter, Tab | новая строка, два пробела |
| `Ctrl+S` | потоково сохранить файл с атомарным truncate первого chunk |
| `Ctrl+Q` или `F10` | выйти; dirty-документ сначала требует сохранения |
| `F2` | diagnostic debug mode: offset, длина и колонка |
| `F5` | сохранить и собрать системным `/bin/fasm.elf` |
| `F6` | запустить собранный ELF; при необходимости сначала собрать |
| `F7` | вставить минимальный шаблон, только если документ пуст |

Output path получается заменой `.asm` на `.elf`, иначе расширение добавляется.
Например, `/system/build/hello.asm` собирается в
`/system/build/hello.elf`. Пути передаются procd через shared argument area,
поэтому старого ограничения 47 байт для command line здесь нет.

## Подсветка и экран

Текущая подсветка рассчитана на FASM:

- комментарии `;` — зелёные;
- строки в одинарных/двойных кавычках — жёлтые;
- числа — cyan;
- identifiers — синие;
- punctuation — magenta;
- текущая cell курсора инвертируется.

VEdit формирует пары `character/attribute` в собственной памяти и отправляет
terminal до 24 cells за IPC. Terminal проверяет координаты и остаётся
единственным владельцем VGA MMIO. При переходе к GOP этот API будет заменён
surface/font service без выдачи framebuffer capability приложению.

`F2` сейчас является режимом диагностики редактора и build pipeline, не
отладчиком чужого процесса с breakpoints. Полноценному debugger нужны отдельные
debug capability, register snapshot и stop/resume protocol; давать редактору
неограниченный доступ к address space процесса микроядерная модель не будет.

## Проверка

`make test-editor` настоящими PS/2/QMP events выполняет:

1. `edit /system/build/editortest.asm`;
2. F7 и проверку цветных VGA attributes;
3. F2 и проверку debug status;
4. Ctrl+S, F5, F6 и выполнение нового ELF;
5. Ctrl+Q, остановку VM, `fsck --data` и извлечение source/output.

Контрольный ELF печатает `VARANIA:EDITOR_TEMPLATE_OK`. Таким образом тест
покрывает raw keyboard → terminal → VEdit → libvarania → VFS/NVMe → FASM →
procd, а не только отдельную функцию буфера.
