cd c:\os
del BOOT.BIN 
del KERNEL.BIN
del VOS.VHD
cd c:\fasm
CWSDPMI.EXE
fasm.exe c:\os\src\boot\boot.asm c:\os\BOOT.BIN
pause
CWSDPMI.EXE
fasm.exe c:\os\src\kernel\kernel.asm c:\os\KERNEL.BIN
CWSDPMI.EXE
fasm.exe c:\os\src\link.asm c:\os\VOS.VHD
cd C:\Program Files (x86)\qemu\
qemu-system-x86_64 -hda c:\os\VOS.VHD -m 1024
pause 
cd c:\os