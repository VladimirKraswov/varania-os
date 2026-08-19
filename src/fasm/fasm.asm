;// Varania OS platform wrapper for the unmodified FASM 1.73.35 x64 core.
;//
;// Upstream's Linux front end is deliberately reused: it contains the mature
;// command-line parser and all assembler-core includes. We replace only the
;// `syscall` instruction with a call into platform.inc. Thus open/read/write,
;// brk, console and process exit cross the Varania capability ABI, while the
;// official parser/assembler/formatter remains byte-for-byte upstream.

macro syscall
{
  call platform_linux_syscall
}

include '../../build/fasm-source/source/linux/x64/fasm.asm'
include 'platform.inc'
