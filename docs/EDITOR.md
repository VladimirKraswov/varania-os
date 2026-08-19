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
terminal до 24 cells за IPC. Terminal проверяет координаты, сохраняет
compatibility VGA mirror и пересылает cells в GUI. Только `gui.elf` владеет VBE
framebuffer и rasterizer; VEdit framebuffer capability не получает. При
переходе к GOP изменится video backend GUI, а terminal/editor ABI останется тем
же.

При обычном наборе VEdit перерисовывает только текущую строку, title, status и
cursor — 12 коротких сообщений вместо примерно 100 для полного экрана.
Keyboard повторяет `TERM_KEY` при `-11`, а terminal хранит 64 события между
`READKEY`, поэтому быстрый autorepeat не завершает драйвер и не теряется.

`Ctrl+C` намеренно не обрабатывается кодом VEdit. Terminal передаёт interrupt
в `sessiond`, который владеет только `CAP_CONTROL` foreground-процесса. Даже
если редактор зациклился или заблокирован, микроядро завершит его status 130,
разбудит shell и освободит address space. Вложенные программы образуют стек:
пока VEdit ждёт запущенный FASM/ELF, прерывается верхняя задача.

`F2` сейчас является режимом диагностики редактора и build pipeline, не
отладчиком чужого процесса с breakpoints. Полноценному debugger нужны отдельные
debug capability, register snapshot и stop/resume protocol; давать редактору
неограниченный доступ к address space процесса микроядерная модель не будет.

## Проверка

`make test-editor` настоящими PS/2/QMP events выполняет:

1. `edit /system/build/editortest.asm`;
2. F7 и проверку точных цветов syntax highlighting на VBE framebuffer;
3. burst из 12 одинаковых клавиш внутри строки без потерь/искажения;
4. F2, Ctrl+S, F5, F6 и выполнение нового ELF;
5. запуск бесконечного `/bin/hang.elf`, Ctrl+C и возврат к рабочему `ls`;
6. остановку VM, `fsck --data` и извлечение source/output.

Контрольный ELF печатает `VARANIA:EDITOR_TEMPLATE_OK`. Таким образом тест
покрывает raw keyboard → terminal → VEdit → libvarania → VFS/NVMe → FASM →
procd, а не только отдельную функцию буфера.
