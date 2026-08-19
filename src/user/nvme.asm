format ELF64 executable 3
entry start
include "abi.inc"

;// NVMe block driver — обычный изолированный ring-3 процесс.
;//
;// Procd уже нашёл PCI function по class/subclass/prog-if, включил Memory Space
;// и Bus Master, и заключил BAR0 в capability. Драйвер не видит чужие PCI-функции,
;// не имеет IOPL и не может отобразить произвольную физическую память.
;//
;// Handles задаёт policy procd:
;//   1 inbox, 2 nameserver, 3 NVMe BAR0, 4 DMA pool.
SELF_EP       = 1
NAMESERVER_EP = 2
MMIO_CAP      = 3
DMA_POOL_CAP  = 4

NVME_MMIO_BASE  = 0x0000000060000000
ADMIN_QUEUE_VA  = 0x0000000061010000 ;// SQ page, затем CQ page
IO_QUEUE_VA     = 0x0000000061020000 ;// SQ page, затем CQ page
DATA_BUFFER_VA  = 0x0000000061040000 ;// 16 pages = 64 KiB
DATA_BUFFER_PAGES = 16
DATA_BUFFER_BYTES = DATA_BUFFER_PAGES*PAGE_SIZE

NVME_QUEUE_SIZE = 32
NVME_ADMIN_SQ_ENTRY = 64
NVME_ADMIN_CQ_ENTRY = 16
NVME_IO_SQ_ENTRY = 64
NVME_IO_CQ_ENTRY = 16

;// Controller registers.
NVME_REG_CAP  = 0x00
NVME_REG_VS   = 0x08
NVME_REG_CC   = 0x14
NVME_REG_CSTS = 0x1C
NVME_REG_AQA  = 0x24
NVME_REG_ASQ  = 0x28
NVME_REG_ACQ  = 0x30
NVME_REG_DOORBELL = 0x1000

;// Admin/NVM opcodes.
NVME_ADMIN_CREATE_SQ = 0x01
NVME_ADMIN_CREATE_CQ = 0x05
NVME_ADMIN_IDENTIFY  = 0x06
NVME_NVM_FLUSH = 0x00
NVME_NVM_WRITE = 0x01
NVME_NVM_READ  = 0x02

NVME_NAMESPACE = 1
BLOCK_FEATURE_FLUSH = 1
BLOCK_FEATURE_SSD   = 2

segment readable executable
start:
  call map_controller
  test rax, rax
  jnz fatal
  call allocate_driver_dma
  test rax, rax
  jnz fatal
  call controller_start
  test rax, rax
  jnz fatal
  call identify_namespace
  test rax, rax
  jnz fatal
  call create_io_queues
  test rax, rax
  jnz fatal
  call storage_self_test
  test rax, rax
  jnz fatal
  call register_block_service
  test rax, rax
  jnz fatal
  log ready_text, ready_text.size
  log ok_marker, ok_marker.size

.serve:
  lea rdi, [request]
  mov ecx, IpcMessage.bytes*2
  call zero_bytes
  ipc_receive SELF_EP, request
  test rax, rax
  jnz fatal
  call dispatch_request
  jmp .serve

fatal:
  log fatal_text, fatal_text.size
  exit_process 1

;// Отобразить весь BAR и проверить обязательные возможности controller.
map_controller:
  mov eax, SYS_MMIO_MAP
  mov edi, MMIO_CAP
  mov rsi, NVME_MMIO_BASE
  syscall
  test rax, rax
  js .done
  mov rax, [NVME_MMIO_BASE+NVME_REG_CAP]
  mov [controller_cap], rax
  mov edx, eax
  and edx, 0xFFFF                 ;// MQES = maximum queue entries - 1
  cmp edx, NVME_QUEUE_SIZE-1
  jb .invalid
  bt rax, 37                      ;// CSS bit 0: NVM command set
  jnc .invalid
  mov rdx, rax
  shr rdx, 48
  and edx, 0x0F                  ;// MPSMIN; driver использует 4 KiB pages
  jnz .invalid
  mov rdx, rax
  shr rdx, 32
  and edx, 0x0F
  mov eax, 4
  mov cl, dl
  shl eax, cl
  mov [doorbell_stride], eax
  mov eax, [NVME_MMIO_BASE+NVME_REG_VS]
  test eax, eax
  jz .invalid
  mov [controller_version], eax
  xor eax, eax
  ret
.invalid:
  mov rax, -22
.done:
  ret

;// Выделить и отобразить physically-contiguous admin queues, I/O queues и data window.
allocate_driver_dma:
  mov edi, 2
  mov rsi, ADMIN_QUEUE_VA
  call allocate_dma
  test rax, rax
  js .done
  mov [admin_dma_cap], rax
  mov [admin_dma_phys], rdx
  mov edi, 2
  mov rsi, IO_QUEUE_VA
  call allocate_dma
  test rax, rax
  js .done
  mov [io_dma_cap], rax
  mov [io_dma_phys], rdx
  mov edi, DATA_BUFFER_PAGES
  mov rsi, DATA_BUFFER_VA
  call allocate_dma
  test rax, rax
  js .done
  mov [data_dma_cap], rax
  mov [data_dma_phys], rdx
  xor eax, eax
.done:
  ret

;// EDI=pages, RSI=virtual. RAX=shared handle/error, RDX=physical base.
allocate_dma:
  push rbx
  push r12
  push r13
  sub rsp, 8
  mov r12, rsi
  mov esi, edi
  mov eax, SYS_DMA_CREATE
  mov edi, DMA_POOL_CAP
  syscall
  test rax, rax
  js .done
  mov rbx, rax
  mov r13, rdx
  mov eax, SYS_SHARED_MAP
  mov rdi, rbx
  mov rsi, r12
  mov edx, SPACE_MAP_WRITE
  syscall
  test rax, rax
  js .done
  mov rax, rbx
  mov rdx, r13
.done:
  add rsp, 8
  pop r13
  pop r12
  pop rbx
  ret

;// Перезапустить controller и передать ему Admin SQ/CQ.
controller_start:
  mov eax, [NVME_MMIO_BASE+NVME_REG_CC]
  and eax, not 1
  mov [NVME_MMIO_BASE+NVME_REG_CC], eax
  mfence
  xor edi, edi
  call wait_ready
  test rax, rax
  jnz .done
  mov dword [NVME_MMIO_BASE+NVME_REG_AQA], ((NVME_QUEUE_SIZE-1) shl 16)+(NVME_QUEUE_SIZE-1)
  mov rax, [admin_dma_phys]
  mov [NVME_MMIO_BASE+NVME_REG_ASQ], rax
  add rax, PAGE_SIZE
  mov [NVME_MMIO_BASE+NVME_REG_ACQ], rax
  mfence
  ;// IOSQES=6 (64 байт), IOCQES=4 (16 байт), MPS=0 (4 KiB), CSS=NVM.
  mov dword [NVME_MMIO_BASE+NVME_REG_CC], (6 shl 16)+(4 shl 20)+1
  mfence
  mov edi, 1
  call wait_ready
.done:
  ret

;// EDI=ожидаемый CSTS.RDY (0/1). RAX=0/error.
wait_ready:
  mov r8d, edi
  mov ecx, 0x1000000
.poll:
  mov eax, [NVME_MMIO_BASE+NVME_REG_CSTS]
  test eax, 2                      ;// CFS — fatal controller status
  jnz .failed
  and eax, 1
  cmp eax, r8d
  je .ready
  pause
  dec ecx
  jnz .poll
  mov rax, -110
  ret
.failed:
  mov rax, -5
  ret
.ready:
  xor eax, eax
  ret

;// Подготовить нулевую 64-байтную admin command в текущем tail. RDI=command.
prepare_admin_command:
  mov eax, [admin_tail]
  shl rax, 6
  lea rdi, [ADMIN_QUEUE_VA+rax]
  push rdi
  mov ecx, NVME_ADMIN_SQ_ENTRY
  call zero_bytes
  pop rdi
  mov ax, [next_cid]
  inc word [next_cid]
  mov [rdi+2], ax
  ret

;// Опубликовать admin command и синхронно дождаться CQ entry.
submit_admin_command:
  mov eax, [admin_tail]
  inc eax
  and eax, NVME_QUEUE_SIZE-1
  mov [admin_tail], eax
  mfence
  mov [NVME_MMIO_BASE+NVME_REG_DOORBELL], eax
  mov ecx, 0x1000000
.poll:
  mov eax, [admin_head]
  shl rax, 4
  lea rsi, [ADMIN_QUEUE_VA+PAGE_SIZE+rax]
  movzx edx, word [rsi+14]
  mov eax, edx
  and eax, 1
  cmp eax, [admin_phase]
  je .complete
  pause
  dec ecx
  jnz .poll
  mov rax, -110
  ret
.complete:
  mov eax, [rsi]
  mov [completion_result], eax
  shr edx, 1
  and edx, 0x7FFF
  mov eax, [admin_head]
  inc eax
  and eax, NVME_QUEUE_SIZE-1
  mov [admin_head], eax
  jnz .phase_ready
  xor dword [admin_phase], 1
.phase_ready:
  mfence
  mov ecx, [doorbell_stride]
  mov [NVME_MMIO_BASE+NVME_REG_DOORBELL+rcx], eax
  test edx, edx
  jnz .command_error
  xor eax, eax
  ret
.command_error:
  mov rax, -5
  ret

;// EDI=CNS, ESI=namespace. Ответ попадает в первую страницу data window.
admin_identify:
  push r12
  push r13
  mov r12d, edi
  mov r13d, esi
  mov rdi, DATA_BUFFER_VA
  mov ecx, PAGE_SIZE
  call zero_bytes
  call prepare_admin_command
  mov byte [rdi], NVME_ADMIN_IDENTIFY
  mov [rdi+4], r13d
  mov rax, [data_dma_phys]
  mov [rdi+24], rax               ;// PRP1
  mov [rdi+40], r12d              ;// CDW10.CNS
  call submit_admin_command
  pop r13
  pop r12
  ret

;// Прочитать Identify Controller и Identify Namespace 1, выбрать active LBA format.
identify_namespace:
  mov edi, 1                      ;// CNS=Identify Controller
  xor esi, esi
  call admin_identify
  test rax, rax
  jnz .done
  cmp dword [DATA_BUFFER_VA+516], NVME_NAMESPACE ;// NN >= 1
  jb .invalid
  xor edi, edi                    ;// CNS=Identify Namespace
  mov esi, NVME_NAMESPACE
  call admin_identify
  test rax, rax
  jnz .done
  mov rax, [DATA_BUFFER_VA+0]     ;// NSZE, logical blocks
  test rax, rax
  jz .invalid
  mov [namespace_lbas], rax
  movzx eax, byte [DATA_BUFFER_VA+26] ;// FLBAS
  and eax, 0x0F
  shl eax, 2
  movzx ecx, byte [DATA_BUFFER_VA+128+rax+2] ;// LBAF.LBADS
  cmp ecx, 9                      ;// не мельче 512 байт
  jb .invalid
  cmp ecx, 12                     ;// VaraniaFS block = 4096
  ja .invalid
  mov [lba_shift], ecx
  mov eax, 1
  shl eax, cl
  mov [lba_bytes], eax
  mov edx, 12
  sub edx, ecx
  mov eax, 1
  mov ecx, edx
  shl eax, cl
  mov [lbas_per_block], eax
  mov rax, [namespace_lbas]
  mov ecx, edx
  shr rax, cl
  mov [block_count], rax
  cmp rax, 4                      ;// superblocks + хотя бы два data blocks
  jb .invalid
  xor eax, eax
  ret
.invalid:
  mov rax, -22
.done:
  ret

admin_create_cq:
  call prepare_admin_command
  mov byte [rdi], NVME_ADMIN_CREATE_CQ
  mov rax, [io_dma_phys]
  add rax, PAGE_SIZE
  mov [rdi+24], rax
  mov dword [rdi+40], ((NVME_QUEUE_SIZE-1) shl 16)+1 ;// QSIZE, QID=1
  mov dword [rdi+44], 1           ;// PC=1, interrupts disabled
  call submit_admin_command
  ret

admin_create_sq:
  call prepare_admin_command
  mov byte [rdi], NVME_ADMIN_CREATE_SQ
  mov rax, [io_dma_phys]
  mov [rdi+24], rax
  mov dword [rdi+40], ((NVME_QUEUE_SIZE-1) shl 16)+1
  mov dword [rdi+44], (1 shl 16)+1 ;// CQID=1, PC=1
  call submit_admin_command
  ret

create_io_queues:
  call admin_create_cq
  test rax, rax
  jnz .done
  call admin_create_sq
.done:
  ret

prepare_io_command:
  mov eax, [io_tail]
  shl rax, 6
  lea rdi, [IO_QUEUE_VA+rax]
  push rdi
  mov ecx, NVME_IO_SQ_ENTRY
  call zero_bytes
  pop rdi
  mov ax, [next_cid]
  inc word [next_cid]
  mov [rdi+2], ax
  ret

submit_io_command:
  mov eax, [io_tail]
  inc eax
  and eax, NVME_QUEUE_SIZE-1
  mov [io_tail], eax
  mfence
  mov ecx, [doorbell_stride]
  shl ecx, 1                      ;// SQ1 doorbell index = 2
  mov [NVME_MMIO_BASE+NVME_REG_DOORBELL+rcx], eax
  mov ecx, 0x1000000
.poll:
  mov eax, [io_head]
  shl rax, 4
  lea rsi, [IO_QUEUE_VA+PAGE_SIZE+rax]
  movzx edx, word [rsi+14]
  mov eax, edx
  and eax, 1
  cmp eax, [io_phase]
  je .complete
  pause
  dec ecx
  jnz .poll
  mov rax, -110
  ret
.complete:
  shr edx, 1
  and edx, 0x7FFF
  mov eax, [io_head]
  inc eax
  and eax, NVME_QUEUE_SIZE-1
  mov [io_head], eax
  jnz .phase_ready
  xor dword [io_phase], 1
.phase_ready:
  mfence
  mov ecx, [doorbell_stride]
  imul ecx, 3                     ;// CQ1 doorbell index = 3
  mov [NVME_MMIO_BASE+NVME_REG_DOORBELL+rcx], eax
  test edx, edx
  jnz .command_error
  xor eax, eax
  ret
.command_error:
  mov rax, -5
  ret

;// EDI=opcode READ/WRITE, RSI=4-KiB block, EDX=page-aligned data-window offset.
submit_block_io:
  push r12
  push r13
  push r14
  mov r12d, edi
  mov r13, rsi
  mov r14d, edx
  cmp r13, [block_count]
  jae .invalid
  test r14d, PAGE_SIZE-1
  jnz .invalid
  cmp r14d, DATA_BUFFER_BYTES-PAGE_SIZE
  ja .invalid
  call prepare_io_command
  mov [rdi], r12b
  mov dword [rdi+4], NVME_NAMESPACE
  mov rax, [data_dma_phys]
  add rax, r14
  mov [rdi+24], rax               ;// ровно одна 4-KiB PRP page
  mov eax, [lbas_per_block]
  imul r13, rax
  mov [rdi+40], r13               ;// CDW10+11 = starting LBA
  dec eax
  mov [rdi+48], eax               ;// CDW12.NLB = count - 1
  call submit_io_command
  jmp .done
.invalid:
  mov rax, -22
.done:
  pop r14
  pop r13
  pop r12
  ret

;// RSI=4-KiB block, EDX=data offset.
read_block:
  mov edi, NVME_NVM_READ
  jmp submit_block_io

write_block:
  mov edi, NVME_NVM_WRITE
  jmp submit_block_io

flush_device:
  call prepare_io_command
  mov byte [rdi], NVME_NVM_FLUSH
  mov dword [rdi+4], NVME_NAMESPACE
  call submit_io_command
  ret

;// Проверить не мок, а настоящие DMA Read/Write/Flush.
;// Для write test берём предпоследний блок: последний занят mirror superblock,
;// а предпоследний не достижим из активного catalog. Исходные байты всегда возвращаем.
storage_self_test:
  push r12
  push r13
  xor esi, esi
  xor edx, edx
  call read_block
  test rax, rax
  jnz .done
  mov rax, 0001000053464156h       ;// little-endian "VAFS\0\0\1\0"
  cmp [DATA_BUFFER_VA], rax
  jne .corrupt
  mov r12, [block_count]
  sub r12, 2
  mov rsi, r12
  xor edx, edx
  call read_block
  test rax, rax
  jnz .done
  ;// Page 1 — снимок для восстановления.
  mov rsi, DATA_BUFFER_VA
  mov rdi, DATA_BUFFER_VA+PAGE_SIZE
  mov ecx, PAGE_SIZE/8
  rep movsq
  mov rdi, DATA_BUFFER_VA
  mov rax, 0A55A11223344CCDDh
  mov ecx, PAGE_SIZE/8
  rep stosq
  mov rsi, r12
  xor edx, edx
  call write_block
  test rax, rax
  jz .written
  mov r13, rax
  jmp .restore
.written:
  call flush_device
  test rax, rax
  jz .flushed
  mov r13, rax
  jmp .restore
.flushed:
  mov rdi, DATA_BUFFER_VA
  mov ecx, PAGE_SIZE/8
  call zero_qwords
  mov rsi, r12
  xor edx, edx
  call read_block
  test rax, rax
  jz .read_back
  mov r13, rax
  jmp .restore
.read_back:
  mov rdx, 0A55A11223344CCDDh
  cmp qword [DATA_BUFFER_VA], rdx
  jne .restore_corrupt
  cmp qword [DATA_BUFFER_VA+PAGE_SIZE-8], rdx
  jne .restore_corrupt
  xor r13d, r13d                 ;// self-test result
  jmp .restore
.restore_corrupt:
  mov r13, -5
.restore:
  mov rsi, DATA_BUFFER_VA+PAGE_SIZE
  mov rdi, DATA_BUFFER_VA
  mov ecx, PAGE_SIZE/8
  rep movsq
  mov rsi, r12
  xor edx, edx
  call write_block
  test rax, rax
  jnz .done
  call flush_device
  test rax, rax
  jnz .done
  mov rax, r13
  jmp .done
.corrupt:
  mov rax, -74
.done:
  pop r13
  pop r12
  ret

register_block_service:
  lea rdi, [request]
  mov ecx, IpcMessage.bytes
  call zero_bytes
  mov qword [request+IpcMessage.words], NAMESERVER_REGISTER
  mov qword [request+IpcMessage.words+8], SERVICE_BLOCK
  mov qword [request+IpcMessage.cap_count], 1
  mov qword [request+IpcMessage.caps+IpcCap.handle], SELF_EP
  mov qword [request+IpcMessage.caps+IpcCap.rights], CAP_SEND
  ipc_send NAMESERVER_EP, request
  ret

dispatch_request:
  cmp qword [request+IpcMessage.cap_count], 1
  jne .without_reply
  mov r12, qword [request+IpcMessage.caps+IpcCap.handle]
  mov rax, qword [request+IpcMessage.words]
  cmp rax, BLOCK_ATTACH
  je .attach
  cmp rax, BLOCK_READ
  je .read
  cmp rax, BLOCK_WRITE
  je .write
  cmp rax, BLOCK_FLUSH
  je .flush
  mov rax, -38
  jmp .reply_status

.attach:
  mov qword [reply+IpcMessage.words], 0
  mov rax, [block_count]
  mov qword [reply+IpcMessage.words+8], rax
  mov qword [reply+IpcMessage.words+16], PAGE_SIZE
  mov qword [reply+IpcMessage.words+24], DATA_BUFFER_BYTES
  mov qword [reply+IpcMessage.words+32], BLOCK_FEATURE_FLUSH+BLOCK_FEATURE_SSD
  mov qword [reply+IpcMessage.cap_count], 1
  mov rax, [data_dma_cap]
  mov qword [reply+IpcMessage.caps+IpcCap.handle], rax
  mov qword [reply+IpcMessage.caps+IpcCap.rights], CAP_MAP+CAP_READ+CAP_WRITE
  jmp .send

.read:
  call validate_block_request
  test rax, rax
  jnz .reply_status
  mov rsi, qword [request+IpcMessage.words+8]
  mov edx, dword [request+IpcMessage.words+24]
  call read_block
  jmp .reply_status
.write:
  call validate_block_request
  test rax, rax
  jnz .reply_status
  mov rsi, qword [request+IpcMessage.words+8]
  mov edx, dword [request+IpcMessage.words+24]
  call write_block
  jmp .reply_status
.flush:
  call flush_device
.reply_status:
  mov qword [reply+IpcMessage.words], rax
  mov qword [reply+IpcMessage.cap_count], 0
.send:
  ipc_send r12d, reply
  push rax
  mov rdi, r12
  close_cap rdi
  pop rax
  ret
.without_reply:
  call close_request_caps
  ret

;// В v1 один RPC переносит один 4-KiB block; bulk pipeline сможет занять все 16 pages.
validate_block_request:
  cmp qword [request+IpcMessage.words+16], 1
  jne .invalid
  mov rax, qword [request+IpcMessage.words+8]
  cmp rax, [block_count]
  jae .invalid
  mov eax, dword [request+IpcMessage.words+24]
  test eax, PAGE_SIZE-1
  jnz .invalid
  cmp eax, DATA_BUFFER_BYTES-PAGE_SIZE
  ja .invalid
  xor eax, eax
  ret
.invalid:
  mov rax, -22
  ret

close_request_caps:
  push rbx
  mov rbx, qword [request+IpcMessage.cap_count]
.next:
  test rbx, rbx
  jz .done
  dec rbx
  mov rax, rbx
  shl rax, 4
  mov rdi, qword [request+IpcMessage.caps+rax+IpcCap.handle]
  close_cap rdi
  jmp .next
.done:
  pop rbx
  ret

zero_bytes:
  xor eax, eax
  rep stosb
  ret

zero_qwords:
  xor eax, eax
  rep stosq
  ret

segment readable writeable
ready_text db "nvme: namespace 1 ready; 4-KiB block service online", 10
.size = $-ready_text
ok_marker db "VARANIA:NVME_OK", 10
.size = $-ok_marker
fatal_text db "nvme: controller, queue or DMA failure", 10
.size = $-fatal_text

align 8
controller_cap dq 0
controller_version dd 0
doorbell_stride dd 0
admin_dma_cap dq 0
admin_dma_phys dq 0
io_dma_cap dq 0
io_dma_phys dq 0
data_dma_cap dq 0
data_dma_phys dq 0
namespace_lbas dq 0
block_count dq 0
lba_shift dd 0
lba_bytes dd 0
lbas_per_block dd 0
admin_tail dd 0
admin_head dd 0
admin_phase dd 1
io_tail dd 0
io_head dd 0
io_phase dd 1
next_cid dw 1
align 4
completion_result dd 0
align 8
request rb IpcMessage.bytes
reply rb IpcMessage.bytes
