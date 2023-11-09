#!/bin/bash
#Удаляем прошлые бинарники и виртуальный диск
rm ./BOOT.BIN 
rm ./KERNEL.BIN
rm ./VOS.VHD
fasm src/boot/boot.asm BOOT.BIN        #Склеиваем загрузчик с ядром в виртуальный диск
fasm src/kernel/kernel.asm KERNEL.BIN  #Склеиваем загрузчик с ядром в виртуальный диск
fasm src/link.asm VOS.VHD
qemu-system-x86_64 -hda VOS.VHD -m 128  #Запускаем QEMU с нашего виртуального диска            


