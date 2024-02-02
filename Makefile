# Copyright (C) StorePeter.dk  2024 license:  https://en.wikipedia.org/wiki/Beerware
# DUALBOOT is based on optiboot-8.3,
# see changes under Patches

ifeq ($(wildcard optiboot/*),)
$(warning To download the source-code plase type: make clone)
endif

DUAL_BASE := 0x30000	# relocated seecondary.elf to this address
TTY       := $(wildcard /dev/serial/by-id/usb-*)
$(warning DUAL_BASE=$(DUAL_BASE))
DUALBOOT  := G,0
# on my 3D printers a good choise was the KILL_PIN (41) Port-G bit-0
PRIMARY   := primary.elf
SECONDARY := secondary.elf
MCU       := atmega2560
FREQ      := 16000000
BAUD      := 115200

# a backup of the original firmware will be saved to the dir below
FIRMWARE_DIR   := Preserved_Firmware/$(notdir $(TTY))
ISP      = $(AVRDUDE) -c arduino -P $(TTY) -b $(BAUD) -p $(MCU)
DUAL_DEFS      += -DDUALBOOT_BASE=$(DUAL_BASE)
DUAL_DEFS      += -DDUALBOOT=$(DUALBOOT)
OPTIBOOT_DIR   := optiboot/optiboot/bootloaders/optiboot
OPTIBOOT_FLAGS += BIGBOOT=1
OPTIBOOT_FLAGS += UART=0 BAUD_RATE=$(BAUD)
OPTIBOOT_FLAGS += LED=B7 LED_START_FLASHES=3
OPTIBOOT_FLAGS += ISPTOOL=usbasp ISPPORT= ISPSPEED= LOCKFUSE=FF
OPTIBOOT_DUAL  += DEFS="$(DUAL_DEFS)" CUSTOM_VERSION=100 SUPPORT_EEPROM=1
OPTIBOOT_SRC   := $(OPTIBOOT_DIR)/optiboot.c
OPTIBOOT_ELF   := $(OPTIBOOT_DIR)/optiboot_$(MCU).elf

CFLAGS  += -Os
CFLAGS  += -mmcu=$(MCU)
CFLAGS  += -DF_CPU=$(FREQ)L
CFLAGS  += -DBAUD=$(BAUD)
CFLAGS  += $(DUAL_DEFS)
LDFLAGS	+= -Wl,--section-start=.text=$(DUAL_BASE)
AVRDUDE := avrdude

default:
	./dualtool.sh

clone: optiboot/optiboot/bootloaders/optiboot

optiboot/optiboot/bootloaders/optiboot:
	@if [ -d  $@ ]; then echo Source code already downloaded; false; fi
	git clone https://github.com/Optiboot/optiboot.git
	cd optiboot; patch -p1 < ../Patches/optiboot.patch

compile: primary.elf secondary.elf optiboot.elf dualboot.elf

primary.elf: hello.c
	avr-gcc -DNAME=$(@:.elf=) -DBASE=0 $(CFLAGS) -o $@ $<

secondary.elf: hello.c
	avr-gcc -DNAME=$(@:.elf=) -DBASE=$(DUAL_BASE) $(CFLAGS) $(LDFLAGS) -o $@ $<

.PHONY: optiboot.flash dualboot.flash

# .elf   -> make $(MCU) compiles to .elf
# .flash -> make $(MCU)_isp will flash bootloader to device too
# optiboot -> compile and flash unmodified version of optiboot
# dualboot -> adds dualboot capability, forwarding interrupt to secondary firmware
optiboot.flash optiboot.elf dualboot.flash dualboot.elf: $(OPTIBOOT_SRC) Makefile $(FIRMWARE_DIR)/orig-app.bin
	make -C $(OPTIBOOT_DIR) $(OPTIBOOT_FLAGS) \
		$(if $(filter dualboot.%,$@), $(OPTIBOOT_DUAL)) \
		clean \
		$(MCU)$(if $(filter %.flash,$@),_isp)
	cp $(OPTIBOOT_ELF) $(@:flash=elf)
	$(if $(filter %.flash,$@), mkdir -p  $(FIRMWARE_DIR); cp $(@:flash=elf) $(FIRMWARE_DIR))

backup: $(FIRMWARE_DIR)/orig-app.bin

restore: $(FIRMWARE_DIR)/orig-app.hex  $(FIRMWARE_DIR)/eeprom.hex
	./dualtool.sh -b $(BAUD) -e -E $(FIRMWARE_DIR)/eeprom.hex -w $<

flash: $(PRIMARY) $(SECONDARY)
	./dualtool.sh -b $(BAUD) -w $(PRIMARY) $(SECONDARY)

$(FIRMWARE_DIR)/flash.hex:
	mkdir -p $(FIRMWARE_DIR)
	avrdude -c usbasp -p atmega2560 -U flash:r:$@:i -U eeprom:r:$(@D)/eeprom.hex:i

$(FIRMWARE_DIR)/orig-app.hex: $(FIRMWARE_DIR)/flash.bin $(FIRMWARE_DIR)/eeprom.bin
	dd if=$< bs=1k count=248 2>/dev/null | sed '$$ s/\xff*$$//' > $(@:hex=bin)
	avr-objcopy -I binary $(@:hex=bin) -O ihex $@

%.hex: %.elf
	avr-objcopy  -j .text -j .data -O ihex $< $@

%.bin: %.hex
	avr-objcopy -I ihex $^ -O binary $@

%.list: %.elf
	avr-objdump -h -S $< | more

clean:
	rm -f *.bin *.hex *.elf

%.patch:
	mkdir -p Patches
	cd $(basename $@); git diff --diff-filter=M > ../Patches/$(basename $@).patch

Patches: optiboot.patch

commit: Patches
	git commit -a

cu:
	picocom -l $(TTY) -b $(BAUD) --imap=lfcrlf

