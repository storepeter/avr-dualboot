#!/bin/bash
# The DualBoot bootloader enables two different firmware on f.ex an ATmega2560
# - The primary firmware is loaded from address 0 no changes to source or binary required
# - The secondary firmware is relocated to an address after the primary firmware during linking
# a copy of the IRQ-vectors from the secondary firmware is copied to the flash-area just below
# the bootloader, 128 bytes for atmega328p, 256 for larger devices
#
# Generaly speaking the secondary firmware kan be relocated to anywhere within
# the first 128k of flash, hence atmega328 atmega64 atmega1284 have no issues here.
# (atmega2560 where only the lower 128k is used is fine too)
#
# When the secondary firmware (or parts of it) is loaded above the first 128k flash
# all kinds of trouble may appear if the code is using pgm_read..() # or a _P() function,
# f.ex  getting access to flash with 16 bit pointer require source-codeange (elpm vs lpm ...)
#
# The state (high/low) of DUALBOOT io-pin, informs the  bootloader either to start
# the primary firmware, or set IVSEL and call the secondary firmware.

# Only AVR with 4 byte irq-vectors, atmega328p and larger is supported for now.
# it is certainly possible to implement on smaller devices, please feel free
# do that is you need it.
#
# space after the copied irq-vector-table is used for further INFO
#   irq-vector table     = i * 4 bytes
#   dualbase             = 2 bytes	(*256)
#  primary-firmware-name = j bytes ending in \0
# secodary-firmware-name = k bytes ending in \0

VERBOSE=${V:=1}
 echo2() { echo "$@" >/dev/stderr; }
 vecho() { if [ $VERBOSE -gt 0 ]; then echo2 "# $*"; fi; }
vvecho() { if [ $VERBOSE -gt 1 ]; then echo2 "# $*"; fi; }
  show_stdout() { echo -n "#";for i in $*;do echo -n " ";eval echo -n "${i}=\${${i}}";done;echo; }
  show() { show_stdout $* >/dev/stderr; }
 vshow() { if [ $VERBOSE -gt 0 ]; then show $*; fi; }
vvshow() { if [ $VERBOSE -gt 1 ]; then show $*; fi; }
 split() { echo $* | sed -e 's/:/ /' -e 's/@/ /'  -e 's,/, ,'  -e 's/@/ /'; }
 vexec() { if [ $VERBOSE -gt 0 ]; then "$@"; fi; }
vvexec() { if [ $VERBOSE -gt 1 ]; then "$@"; fi; }

avrdude_verbose() { vecho avrdude "$@"; avrdude "$@"; }
AVRDUDE=avrdude_verbose

usage()
{
	if [ $# != 0 ]; then
		echo2 "ERROR $@"
	fi
	echo2 "Usage: dualtool.sh [option] [primary_firmware.elf] [secondary_firmware.elf]"
	echo2 "    <nofile>       prints current firmware-map"
	echo2 "    -1 -2          as default jump to primary or secondary firmware"
	echo2 "    file.elf       firmware (primary and/or secondary) to load"
	echo2 "    file.hex       primary firmware can be in hex format"
	echo2 "    -w             program device with given .elf fiiles"
	echo2 "    -e             erase device"
	echo2 "    -E eeprom.hex  program EEPROM        "
	echo2 "    -c usbasp      use usbasp as ISP"
	echo2 "    -b baud"
	echo2 "    -p mcu"
	echo2 "    -v             verbose"
	echo2 "check for trampolines,handle vector_table, suggest DUAL_BASE"
	exit 1
}

read_flash()
{
	if [ ! -f $WORK-flash.hex ]; then
		$AVRDUDE -c $ISP -p $MCU -U flash:r:$WORK-flash.hex:i
	fi
	if [ ! -f $WORK-flash.hex ]; then
		usage svrdude did not read flash neither through optioboot/dualbot nor usbasp
	fi
	avr-objcopy -I ihex $WORK-flash.hex -O binary $WORK.bin

	if [ $(( $(wc -c <$WORK.bin) )) != $(($FLASH)) ]; then
# Optiboot bootloader has version as the last 2 bytes hence we can expect to read a full flash size
		usage "Device is not running a version of optiboot"
	fi
	dd if=$WORK.bin bs=1 skip=$(($FLASH-2)) count=2 of=$WORK-version.bin 2>/dev/null
	VERSION=$(od -A n -d $WORK-version.bin)
	if [ $(($VERSION/256)) -lt 108 ]; then
		usage "Device is not using dualboot please upgrade"
	fi
	vecho "This Device is runing DualBoot based on optiboot $((($VERSION/256)-100)).$(($VERSION%256))"
	dd if=$WORK.bin bs=1 skip=$(($VECT_BASE)) count=$VECT_SZ of=$WORK-vector-info.bin 2>/dev/null
	vvexec hexdump -C $WORK-vector-info.bin
	dd if=$WORK-vector-info.bin bs=4 skip=$nIRQ of=$WORK-info.bin 2>/dev/null
	DUAL_BASE=$(printf "0x%03x00" $(od -A n -N 2 -d $WORK-info.bin) )
	if [ $(($DUAL_BASE)) = 0 -o $(($DUAL_BASE)) = $((0xffff00)) ]; then
		DUAL_BASE=$(printf "0x%05x" $VECT_BASE )
	fi
	dd if=$WORK-vector-info.bin bs=1 skip=$(($VECT_SZ-1)) of=$WORK-default.bin 2>/dev/null
	DEFAULT=$(($(od -A n -d $WORK-default.bin)))
	vvshow DEFAULT
	# extract the names of the firmware on chip
	NAME=($(dd if=$WORK-info.bin bs=1 skip=2 2>/dev/null | strings))
	if [ ${NAME[0]} = void ]; then
		COMMENT[0]=$(printf "void");
	else
		COMMENT[0]=$(printf "flashed with %s" ${NAME[0]})
	fi
	if [ ${NAME[1]} = void ]; then
		DUAL_BASE=$VECT_BASE
		COMMENT[1]=$(printf "void");
	else
		COMMENT[1]=$(printf "flashed with %s" ${NAME[1]})
	fi
}

read_file()
{
	vvecho read_file $1
	if [ ! -f $1 ]; then
		usage "could not open $1"
	elif [[ $1 == *.elf ]]; then
		START=$(avr-objdump -h $1 | awk '/.text/ { print "0x" $4}')
		if [ $(($START)) = 0 ]; then
			I=0
		else
			I=1
			DUAL_BASE=$(printf "0x%05x" $START)
			vvecho new DUAL_BASE=$DUAL_BASE
		fi
		BASE[$I]=$(printf "0x%05x" $START)
		TRAMPOLINES_END[$I]=$(avr-objdump -S $1 | awk '/trampolines_start/ { has_tramp=1; } /trampolines_end/ { if (has_tramp==1) {print "0x" $1; } }')
		TRAMPOLINES_START[$I]=$(avr-objdump -x $1 | awk '/trampolines_start/ { print "0x" $1; }')
		TRAMPOLINES_END[$I]=$(avr-objdump -x $1 | awk '/trampolines_end/ { print "0x" $1; }')
		if [ $((${TRAMPOLINES_START[$I]})) != $((${TRAMPOLINES_END[$I]})) ]; then
			if [ $((${TRAMPOLINES_END[$I]})) -gt $((0x1ffff)) ]; then
				usage "$1: has trampolines outside of the the low FLASH"
			fi
		else 
			vecho "$1 do not have  trampolines"
			unset TRAMPOLINES_END[$I]
		fi
		avr-objcopy -j .text -j .data -O ihex  $1 $WORK-$I.hex
		if [ $(($START)) = 0 ]; then
			PRIMARY=$WORK-$I.hex
		else
			SECONDARY=$WORK-$I.hex
		fi
	elif [[ $1 == *.hex ]]; then
		I=0
		cp $1 $WORK-$I.hex
		PRIMARY=$WORK-$I.hex
	else
		usage cannot check trampolines on secondary hex files
	fi
	if echo $1 | grep -i "marlin.*firmware.elf" >/dev/null; then
		NAME[$I]=marlin
	else
		NAME[$I]=$(basename $(basename $1 .hex) .elf)
	fi
	avr-objcopy -I ihex -O binary $WORK-$I.hex $WORK-$I.bin
	SIZE[$I]=$(($(wc -c < $WORK-$I.bin)))
	if [ $((${BASE[$I]}+${SIZE[$I]})) -gt $((0x20000)) ]; then
		echo2 "WARNING firmware $1 ${BASE[$I]} + ${SIZE[$I]} above 128k"
	fi
	COMMENT[$I]=$(printf "%s %d bytes\n" $1 ${SIZE[$I]} )
	vshow NAME[$I] BASE[$I] SIZE[$I]
	if [ x${TRAMPOLINES_END[$I]} != x ]; then
		vshow TRAMPOLINES_START[$I]
		vshow TRAMPOLINES_END[$I]
	fi
}

# Update vector info block, dependend on new 1st and 2nd firmware and Erase
# 1st 2nd Erase New_vetor_info
#  -   -   -    nothing
#  -   -   E    clear vector names void
#  1   -   -    update names
#  1   -   E    clear vector update names
#  ?   2   ?    update vector update names
update_vector_block()
{
	vvecho update_vector_block DUAL_BASE=$DUAL_BASE
	if [ x$SECONDARY != x ]; then	# new vector table from file
		dd if=$WORK-1.bin ibs=4 count=$nIRQ of=$WORK-new-vector-info.bin 2>/dev/null
	elif [ x$ERASE != x ]; then
		NAME[1]=void
		DUAL_BASE=$VECT_BASE
		dd if=/dev/zero ibs=4 count=$nIRQ 2>/dev/null \
		   | LC_ALL=C tr "\000" "\377" > $WORK-new-vector-info.bin
		if [ x$PRIMARY = x ]; then
			NAME[0]=void
		fi
	elif [ x$PRIMARY = x -a $DEFAULT = $DEFAULT_NEW ]; then
		vecho "no update to vector block required"
		rm -f $WORK-new-vector-info.*
		return
	else				# currently flashed 2nd firmware
		dd if=$WORK-vector-info.bin ibs=4 count=$nIRQ of=$WORK-new-vector-info.bin 2>/dev/null
	fi 
	vvexec hexdump $WORK-new-vector-info.bin
	LSB=$(($DUAL_BASE / 256))
	MSB=$(($LSB / 256))
	LSB=$(($LSB % 256))
	FMT=$(printf "\\\x%02x\\\x%02x%%s\\\x00%%s\\\x00" $LSB $MSB)
	NAME[0]=${NAME[0]:=void}
	NAME[1]=${NAME[1]:=void}
	vvshow MSB LSB FMT DUAL_BASE VECT_BASE NAME[0] NAME[1]
	printf $FMT ${NAME[0]} ${NAME[1]} >> $WORK-new-vector-info.bin
	truncate --size $(($VECT_SZ-1)) $WORK-new-vector-info.bin
	vvshow DEFAULT DEFAULT_NEW
	if [ $DEFAULT_NEW = 0 ]; then
		echo -en "\x00" >> $WORK-new-vector-info.bin
	else
		echo -en "\xff" >> $WORK-new-vector-info.bin
	fi
	vvexec hexdump -C $WORK-new-vector-info.bin
	avr-ld -b binary --section-start=.data=0x3fb00 -r -o $WORK-new-vector-info.elf $WORK-new-vector-info.bin
	avr-objcopy -j .data -O ihex $WORK-new-vector-info.elf $WORK-new-vector-info.hex
	VECTOR_INFO=$WORK-new-vector-info.hex
}

######### Main starts here

MCU=atmega2560
TTY=/dev/serial/by-id/usb-*
BAUD=115200

FILE=()
WORK=/tmp/dualtool
CACHED=$(find $WORK.bin -mmin -60 2>/dev/null)
if [ $WORK.bin -ot $TTY -o x$CACHED = x -o -f $WORK.programmed ]; then
	echo2 clear cache
	rm -f $WORK*
else
	echo2 use cache
fi

if [ x$MCU = "xatmega328p" ]; then
	FLASH=$((32*1024))
	nIRQ=26
	VECT_SZ=128
	BOOT_SZ=512
elif [ x$MCU = "xatmega1284p" ]; then
	FLASH=$((128*1024))
	nIRQ=35
	VECT_SZ=256
	BOOT_SZ=1024
elif [ x$MCU = "xatmega2560" ]; then
	FLASH=$((256*1024))
	nIRQ=57
	VECT_SZ=256
	BOOT_SZ=1024
else
	usage "MCU=$MCU not supported, fell free to add support"
fi
BOOT_BASE=$(printf 0x%x $(($FLASH - $BOOT_SZ)))
VECT_BASE=$(printf 0x%x $(($FLASH - $BOOT_SZ - $VECT_SZ)))

while getopts b:ceE:hpP:vw12 arg;do
	case $arg in
	b) BAUD=$OPTARG;;
	c) ISP=$OPTARG;;
	e) ERASE=1;;
	E) EEPROM=$OPTARG;;
	P) TTY=$OPTARG;;
	p) MCU=$OPTARG;;
	w) DO_PROGRAM=1;;
	v) VERBOSE=$(($VERBOSE+1));;
	1) DEFAULT_NEW=0;;
	2) DEFAULT_NEW=1;;
	h) usage;;
	esac
done
vshow MCU FLASH VECT_BASE VECT_SZ BOOT_BASE BOOT_SZ
if [ x$ISP = x ]; then
	if [ -c $TTY ]; then
		ISP="arduino -P $TTY -b $BAUD"
	else 
		vecho2 "No serial connection to board, trying via USBasp"
		ISP="usbasp"
	fi
fi
shift $((OPTIND-1))

read_flash

while [ $# -gt 0 ]; do
	read_file $1
	shift
done

if [ x$DEFAULT_NEW = x ]; then
	DEFAULT_NEW=$DEFAULT
fi
if [ $DEFAULT != $DEFAULT_NEW ]; then
	vecho changing default firmware
fi
if [ $DEFAULT_NEW = 0 ]; then
	DEFAULT0="DEFAULT"
	DEFAULT1=""
else
	DEFAULT0=""
	DEFAULT1="DEFAULT"
fi

update_vector_block

### print partition table
printf " 0x%05x - 0x%05x 1st %s %s\n" 0 $DUAL_BASE "${COMMENT[0]}" $DEFAULT0
if [ $DUAL_BASE != $VECT_BASE ]; then
	printf " 0x%05x - 0x%05x 2nd %s %s\n" $DUAL_BASE $VECT_BASE "${COMMENT[1]}" $DEFAULT1
fi
printf " 0x%05x - 0x%05x irq vector table... %d bytes\n" $VECT_BASE $BOOT_BASE $VECT_SZ
printf " 0x%05x - 0x%05x DualBoot bootloader %d bytes\n" $BOOT_BASE $FLASH $BOOT_SZ

# print posible values for DUAL_BASE
if [ x$PRIMARY != x ]; then
	vecho Replace primary firmware, 
	DUAL_BASE_MIN=${SIZE[0]}
	printf " DUAL_BASE min 0x%05x -> 0x%05x\n" ${SIZE[0]} $((0xfff00 & (${SIZE[0]} + 255)))
elif [ x$ERASE = x ]; then
	vecho "Keep primary firmware, not erasing"
fi
if [ x$SECONDARY != x ]; then
	vecho Replace secondary firmware, 
	if [ $((${SIZE[0]})) -gt $(($DUAL_BASE)) ]; then
		usage "primary size=${SIZE[0]} overlaps DUAL_BASE=$DUAL_BASE"
	fi
	if [ $(($DUAL_BASE + ${SIZE[1]})) -gt $(($VECT_BASE)) ]; then
		usage secondary size=${SIZE[1]} overlaps VECT_BASE=$VECT_BASE
	fi
	if [ x${TRAMPOLINES_END[1]} = x ]; then
		echo2 "no trampolines in secondary firmware"
		DUAL_BASE_MAX=$(($VECT_BASE-${SIZE[1]}))
	else
		if [ $((${TRAMPOLINES_END[1]}+$DUAL_BASE)) -gt $((0x20000)) ]; then
			vshow TRAMPOLINES_END[1]
			usage "ERROR: secondary firmware uses trampolines which needs to be in low FLASH"
		fi
		DUAL_BASE_MAX=$((0x20000-${TRAMPOLINES_END[1]}+$DUAL_BASE))
	fi
	printf " DUAL_BASE max 0x%05x -> 0x%05x\n" $DUAL_BASE_MAX $((($DUAL_BASE_MAX/256)*256))
elif [ x$ERASE = x ]; then
	vecho "Keep secondary firmware, not erasing"
fi


## write to flash
if [ x$DO_PROGRAM = x1 ]; then
	if [ x$PRIMARY = x -a x$SECONDARY = x -a x$EEPROM = x -a x$ERASE = x -a $DEFAULT = $DEFAULT_NEW]; then
		usage "no elf/hex or change for flash/eeprom"
	fi
	if [ x$ERASE != x ]; then
		AVRDUDE_ARGS="-e"
	fi
	if [ x$PRIMARY != x ]; then
		AVRDUDE_ARGS="$AVRDUDE_ARGS -U flash:w:$PRIMARY:i"
	fi
	if [ x$SECONDARY != x ]; then
		AVRDUDE_ARGS="$AVRDUDE_ARGS -U flash:w:$SECONDARY:i"
	fi
	if [ x$VECTOR_INFO != x ]; then
		AVRDUDE_ARGS="$AVRDUDE_ARGS -U flash:w:$VECTOR_INFO:i"
	fi
	if [ x$EEPROM != x ]; then
		AVRDUDE_ARGS="$AVRDUDE_ARGS -U eeprom:w:$EEPROM:i"
	fi
	$AVRDUDE -c $ISP -p $MCU $AVRDUDE_ARGS
	touch $WORK.programmed
fi
