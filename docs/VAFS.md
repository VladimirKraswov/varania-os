# VaraniaFS v1

VaraniaFS — собственная файловая система Varania OS. Она одинаково описана
для ring-3 сервера и хостовой утилиты `tools/vafs/vafs.py`. Все числа little-endian,
все номера блоков, object IDs, размеры файлов и generation 64-битные.

## Цели и нецели

- 4 KiB блоки и 64-битная адресация для терабайтных и больших томов;
- последовательные extents и COW-метаданные, хорошие и для SSD, и для HDD;
- атомарный commit через два superblock generation;
- CRC32C каждого блока метаданных и логического содержимого файла;
- имена UTF-8, case-sensitive, компонент до 255 байт, путь до 1024 байт;
- никаких UID/GID/mode/ACL и `sudo`.

Права доступа не закодированы в inode или catalog entry. Доступ к серверу определяет
endpoint capability. Если когда-нибудь появится policy service, on-disk формат менять не
потребуется.

## Транзакция

VaraniaFS v1 — append/COW формат. Изменяемые блоки не перезаписывают активное
поколение:

```text
new data extents
      ↓
new catalog leaves → new internal nodes
      ↓
FLUSH
      ↓
write older superblock copy with generation+1
      ↓
FLUSH
```

После обрыва выбирается целая копия superblock с наибольшим generation. Блоки,
записанные до commit superblock, но не достижимые из него, не становятся файлами.
Следующая транзакция может перезаписать их, потому что старый `alloc_cursor` не был
опубликован.

`FLUSH` — часть block protocol. На NVMe это Flush command, на устройстве с FUA допустима
эквивалентная схема. Сервер не имеет права считать обычный completion доказательством
стойкой записи, если драйв сообщил о volatile cache.

## Размещение тома

VaraniaFS начинается с нулевого блока своего GPT-раздела. Хостовая утилита может
работать и с partition image (`--offset 0`), и с raw disk (`--offset`).

| Блок | Содержимое |
|---:|---|
| 0 | первая копия superblock |
| 1..​`alloc_cursor-1` | достижимые и старые COW data/metadata |
| `alloc_cursor`.. | свободный append space |
| `total_blocks-1` | зеркальная копия superblock |

V1 начинает с monotonic append allocator. Это даёт простое и надёжное crash recovery и
последовательные записи. Segment cleaner/free-space tree будет добавлен до объявления
формата stable: неограниченно расти без reclaim файловая система не должна.

## Superblock

Superblock занимает 4096 байт. Неиспользованный хвост равен нулю и входит в CRC32C.

| Offset | Size | Поле |
|---:|---:|---|
| 0 | 8 | `VAFS\0\0\1\0` |
| 8 | 4 | version = 1 |
| 12 | 4 | block size = 4096 |
| 16 | 8 | generation |
| 24 | 16 | volume UUID |
| 40 | 8 | total blocks |
| 48 | 8 | feature flags |
| 56 | 8 | catalog root block |
| 64 | 4 | catalog height, leaf = 0 |
| 68 | 4 | reserved = 0 |
| 72 | 8 | next object ID |
| 80 | 8 | allocation cursor |
| 88 | 8 | root object ID |
| 96 | 4 | device policy: auto/HDD/SSD |
| 100 | 4 | clean flag |
| 104 | 4 | CRC32C всего блока с нулём в этом поле |

Feature flags v1: COW, CRC32C, case-sensitive и no-permissions. Reader не монтирует том,
если не понимает обязательный feature.

## Catalog B+-tree

Ключ каталога — полный канонический UTF-8 путь. Он намеренно самодостаточен: lookup,
обход каталога и crash fsck не зависят от отдельной цепочки inode blocks.

Каждый B+-node занимает 4096 байт. Его 64-байтный header содержит:

| Offset | Size | Поле |
|---:|---:|---|
| 0 | 4 | `VBTN` |
| 4 | 2 | level, leaf = 0 |
| 6 | 2 | record count |
| 8 | 8 | generation |
| 16 | 8 | next leaf или 0 |
| 24 | 4 | used bytes |
| 28 | 4 | CRC32C всего блока |
| 32 | 4 | flags = 0 |
| 36 | 28 | reserved = 0 |

Internal record: `record_bytes:u16, key_bytes:u16, child_block:u64, key[]`, выровнен
до 8 байт. Ключ равен наибольшему ключу child. Все separators строго возрастают.

Leaf record header занимает 40 байт:

```text
record_bytes:u16, path_bytes:u16, kind:u8, flags:u8, extent_count:u16,
object_id:u64, file_size:u64, mtime_ns:u64, data_crc32c:u32, reserved:u32
```

За header идут extents по 24 байт и path. Extent:

```text
logical_block:u64, physical_block:u64, block_count:u32, reserved:u32
```

Extents полностью покрывают файл без дыр и перекрытий; хвост после `file_size` в
последнем блоке не является частью файла. Каталог не имеет extents, size и data CRC.

## SSD и HDD

Формат один; меняется allocation/scheduling policy:

- обычная запись создаёт большой последовательный extent;
- HDD mode батчит commit и держит связанные данные в одном segment;
- SSD mode не делает in-place metadata writes и передаёт освобождённые segments через discard;
- никакой путь не полагается на 512-байтную atomicity;
- superblock copies разнесены по началу и концу раздела.

## Утилита macOS/Linux

```bash
# Отдельный sparse-образ
python3 tools/vafs/vafs.py format SHARE.VAFS --size 1G --device ssd

python3 tools/vafs/vafs.py mkdir SHARE.VAFS /src -p
python3 tools/vafs/vafs.py put SHARE.VAFS hello.asm /src/hello.asm
python3 tools/vafs/vafs.py ls SHARE.VAFS /src -l
python3 tools/vafs/vafs.py get SHARE.VAFS /src/hello.asm ./hello-copy.asm
python3 tools/vafs/vafs.py fsck SHARE.VAFS --data
```

Для raw system disk передаётся смещение раздела. Пока GPT builder ещё не сменил legacy
bootstrap, тестовое смещение равно 4 MiB:

```bash
python3 tools/vafs/vafs.py ls VOS.VHD --offset 4M /
```

Записывать тот же image одновременно из macOS и из VM запрещено. `flock` защищает
от двух хостовых утилит, но QEMU не делит с ними POSIX lock. Для обмена на запущенной
системе будет отдельный removable image с явным attach/detach или сетевой file service.

## Статус v1

Реализованы:

- host-команды `format`, `info`, `ls`, `tree`, `mkdir`, `put`, `import-tree`,
  `get`, `rm` и `fsck`;
- ring-3 NVMe block backend с DMA и Flush;
- ring-3 mount, проверка обеих копий superblock, CRC и linked leaves;
- чтение extents через per-client shared windows;
- COW `mkdir`, `touch` и атомарная замена содержимого небольшого файла;
- end-to-end recovery check после остановки QEMU.

До объявления формата stable нужны segment cleaner/free-space tree, discard,
streaming writes больше 256 KiB и fault-injection тесты на каждой границе commit.
