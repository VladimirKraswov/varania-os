@echo off
rem ============================================================================
rem Varania OS (amd64) — сборка и запуск в QEMU (Windows).
rem
rem Использование: c.bat [доп. аргументы QEMU]
rem
rem Требования:
rem   - fasm.exe 1.73.35 (w64): ищется в PATH или в tools\fasm\fasm.exe;
rem   - Python 3: сборка детерминированного initramfs;
rem   - QEMU: qemu-system-x86_64.exe в PATH или в C:\Program Files (x86)\qemu.
rem
rem Состав VOS.VHD (raw): сектор 0 — этап 1 (512 B, org 0x7C00);
rem сектора 1-8 — этап 2; 9-136 — ядро; 137-264 — initramfs с ELF64.
rem ============================================================================
setlocal
cd /d "%~dp0"

set "FASM=fasm.exe"
if exist "tools\fasm\fasm.exe" set "FASM=tools\fasm\fasm.exe"

del /q BOOT.BIN KERNEL.BIN INITRAMFS.BIN VOS.VHD 2>nul
if not exist build\user mkdir build\user

"%FASM%" src\boot\boot.asm BOOT.BIN       || goto :err
"%FASM%" src\kernel\kernel.asm KERNEL.BIN || goto :err
for %%P in (init service client keyboard memory_test isolation_test lifecycle_child) do (
  "%FASM%" src\user\%%P.asm build\user\%%P.elf || goto :err
)
python scripts\mkinitramfs.py --size 65536 INITRAMFS.BIN ^
  init.elf=build\user\init.elf service.elf=build\user\service.elf ^
  client.elf=build\user\client.elf keyboard.elf=build\user\keyboard.elf ^
  memory_test.elf=build\user\memory_test.elf ^
  isolation_test.elf=build\user\isolation_test.elf ^
  lifecycle_child.elf=build\user\lifecycle_child.elf || goto :err
"%FASM%" src\link.asm VOS.VHD             || goto :err

set "QEMU=qemu-system-x86_64"
where %QEMU% >nul 2>nul
if errorlevel 1 (
  if exist "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe" (
    set "QEMU=C:\Program Files (x86)\qemu\qemu-system-x86_64.exe"
  ) else (
    echo QEMU не найден. Установите QEMU и повторите.
    goto :err
  )
)

"%QEMU%" -hda VOS.VHD -m 128 %*
exit /b 0

:err
echo Сборка не удалась.
pause
exit /b 1
