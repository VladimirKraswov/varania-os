@echo off
rem ============================================================================
rem Varania OS (amd64) — сборка и запуск в QEMU (Windows).
rem
rem Использование: c.bat [доп. аргументы QEMU]
rem
rem Требования:
rem   - fasm.exe 1.73.35 (w64): ищется в PATH или в tools\fasm\fasm.exe;
rem   - QEMU: qemu-system-x86_64.exe в PATH или в C:\Program Files (x86)\qemu.
rem
rem Состав VOS.VHD (raw): сектор 0 — этап 1 (512 B, org 0x7C00);
rem сектора 1-8 — этап 2 (4 KiB, по физ. 0x1000); сектор 9+ — ядро
rem (64 KiB, по физ. 0x100000, 64-bit, виртуальный 0xFFFF800000000000).
rem ============================================================================
setlocal
cd /d "%~dp0"

set "FASM=fasm.exe"
if exist "tools\fasm\fasm.exe" set "FASM=tools\fasm\fasm.exe"

del /q BOOT.BIN KERNEL.BIN VOS.VHD 2>nul

"%FASM%" src\boot\boot.asm BOOT.BIN       || goto :err
"%FASM%" src\kernel\kernel.asm KERNEL.BIN || goto :err
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
