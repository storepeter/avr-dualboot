You can read more about this on my BLOG

	http://storepeter.dk/3d-printer/avr-dualboot-bootloader

First you should backup the Firmware currently on the MCU

Connect your favorite ISP tool, I use USBasp (see README.USBasp)

	$ make backup

has created a full backup of the current firmware including bootloader
but not fuse settings in my case

	$ ls -l Preserved_Firmware/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0
```
total 580
-rw-rw-r-- 1 peter peter   4096 Jan 29 16:32 eeprom.bin
-rw-rw-r-- 1 peter peter   9740 Jan 29 16:32 eeprom.hex
-rw-rw-r-- 1 peter peter 261406 Jan 29 16:32 flash.bin
-rw-rw-r-- 1 peter peter 620900 Jan 29 16:32 flash.hex
-rw-rw-r-- 1 peter peter 108572 Jan 29 16:32 orig-app.bin
-rw-rw-r-- 1 peter peter 305392 Jan 29 16:32 orig-app.hex
```

Defaults is for a bootloader on an ATmega2560 16 Mhz,
see Makefile for further details.

Get hold of the sources of OptiBoot from Gihub, and apply
the patches that turns optiboot into a  dualboot bootloader

	$ make clone

To compile a new DualBoot bootloader

	$ make dualboot.elf

To flash that to the device

	$ make dualboot.flash

To access the new bootloader I have written a small tool:

	$ ./dualtool.sh  -h

```
Usage: dualtool.sh [option] [primary_firmware.elf] [secondary_firmware.elf]
    <nofile>       prints current firmware-map
    -1 -2          as default jump to primary or secondary firmware
    file.elf       firmware (primary and/or secondary) to load
    file.hex       primary firmware can be in hex format
    -w             program device with given .elf fiiles
    -e             erase device
    -E eeprom.hex  program EEPROM        
    -c usbasp      use usbasp as ISP
    -b baud
    -p mcu
    -v             verbose
check for trampolines,handle vector_table, suggest DUAL_BASE
```

Without options it will show you a map of the flash on the MCU

	$ dualtool.sh 

```
# MCU=atmega2560 FLASH=262144 VECT_BASE=0x3fb00 VECT_SZ=256 BOOT_BASE=0x3fc00 BOOT_SZ=1024
# This Device is runing DualBoot based on optiboot 8.3
# no update to vector block required
 0x00000 - 0x3fb00 1st void 
 0x3fb00 - 0x3fc00 irq vector table... 256 bytes
 0x3fc00 - 0x40000 DualBoot bootloader 1024 bytes

```

Check the new bootloader by downloading primary.elf and secondary.elf

	$ make flash

CCeck what is on MCU using

	$ ./dualtool.sh
```
# This Device is runing DualBoot based on optiboot 8.3
# no update to vector block required
 0x00000 - 0x30000 1st flashed with primary 
 0x30000 - 0x3fb00 2nd flashed with secondary DEFAULT
 0x3fb00 - 0x3fc00 irq vector table... 256 bytes
 0x3fc00 - 0x40000 DualBoot bootloader 1024 bytes
# Keep primary firmware, not erasing
# Keep secondary firmware, not erasing
```

To restore the original Firmware with the newly install DualBoot bootloader

	$ make restore

Now you should have system that works as before, with the difference that it now has a bootloader

Best Regards

StorePeter (C) 2024 Beerware
