/*
 * hello.c - testing:
 * interrupts relocated
 * watchdog reset and interrupt
 * PROGMEM
 */
#include <avr/interrupt.h>
#include <avr/pgmspace.h>
#include <avr/wdt.h>
#include <util/delay.h>
#include <stdio.h>

// for atmega2560
#define BOOTLOADEREND 0x3ffff

#define STR_HELPER(s) #s
#define STR(s) STR_HELPER(s)
// IO-pin is referenced as Port,Bit f.ex arduino pin13 is B,7
// hence we only only need one define per pin passed from the Makefile
//, where optiboot uses separate defines for port and bit
// _... macroes unravels the setting needed
// G_... is only used by the _... macroes
#define G_REG(reg,port,bit)	reg ## port
#define G_BIT(port,bit)		bit
#define G_MASK(port,bit)	(1<<bit)
#define G_STR(port,bit)		STR(port) "," STR(bit)
#define _PORT(...)	G_REG(PORT,__VA_ARGS__)
#define _DDR(...)	G_REG(DDR,__VA_ARGS__)
#define _PIN(...)	G_REG(PIN,__VA_ARGS__)
#define _BIT(...)	G_BIT(__VA_ARGS__)
#define _MASK(...)	G_MASK(__VA_ARGS__)
#define _STR(...)	G_STR(__VA_ARGS__)

char volatile *cpt;

ISR(USART0_UDRE_vect)
{
	char c = *cpt++;
	if (*cpt == 0) {			// c was the last char in buffer
		UCSR0B &= ~(1 << UDRIE0);	// disable UDRE interrupt
	}
	UDR0 = c;
}

void uart_init()
{
	uint16_t baud_setting = (F_CPU / 4 / BAUD - 1) / 2;
	if (baud_setting > 4095) {
		UCSR0A = 0;
		baud_setting = (F_CPU / 8 / BAUD - 1) / 2;
	} else {
		UCSR0A = 1 << U2X0;
	}
	UBRR0H = baud_setting >> 8;
	UBRR0L = baud_setting;
	UCSR0B = 1 << TXEN0;
}

void puts_polled(char *str)
{
	while (*str) {
		while (!(UCSR0A & (1 << UDRE0))) ;	// wait for UDR0 empty
		UDR0 = *str++;
	}
}

void puts_irq(char *str)
{
	cpt = str;
	UCSR0B |= (1 << UDRIE0);		// enable UDRE interrupt
	while (UCSR0B & (1 << UDRIE0)) ;	// bit will be cleared by final char interrupt
}

// puts_F( P_STR("hello world");
char copy_of_flash[100];
void puts_F(const char *str_F)
{
	char *cpt = copy_of_flash;
	while ( (*cpt = pgm_read_byte(str_F++)) ) {
		cpt++;
	}
	puts_irq(copy_of_flash);
}

char watchdog_count = 0;
volatile char sleeping;
ISR(WDT_vect)
{
	sleeping = 0;
	watchdog_count++;
	puts_polled("Polled:- Bow Wow - Watchdog IRQ\r\n");
}

void cause_of_reset()
{
	puts_polled("\r\n->Polled ");
	if (MCUSR & (1 << WDRF)) {
		watchdog_count++;
		puts_polled("Watchdog");
	}
	if (MCUSR & (1 << BORF)) {
		puts_polled("Brownout");
	}
	if (MCUSR & (1 << EXTRF)) {
		puts_polled("External");
	}
	if (MCUSR & (1 << PORF)) {
		puts_polled("Power On");
	}
	puts_polled(" Reset\r\n");
	MCUSR = 0;
}

char port_string[16];
char *binary_str(char port, uint8_t value)
{
	char *cpt = port_string;
	*cpt++ = port;
	*cpt++ = '=';
	for (uint8_t i=0; i<8; i++) {
		if (value & (1<<i)) {
			*cpt++ = '1';
		} else {
			*cpt++ = '0';
		}
	}
	*cpt++ = ' ';
	*cpt++ = 0;
	return port_string;
}

void print_all_pins()
{
	puts_irq(binary_str( 'A', PINA));
	puts_irq(binary_str( 'B', PINB));
	puts_irq(binary_str( 'C', PINC));
	puts_irq(binary_str( 'D', PIND));
	puts_irq(binary_str( 'E', PINE));
	puts_irq(binary_str( 'F', PINF));
	puts_irq(binary_str( 'G', PING));
	puts_irq(binary_str( 'H', PINH));
	puts_irq(binary_str( 'J', PINJ));
	puts_irq(binary_str( 'K', PINK));
	puts_irq("\r\n");
}
int main(void)
{
	char buffer[100];
	uint8_t major = pgm_read_byte_far(BOOTLOADEREND);
	uint8_t minor = pgm_read_byte_far(BOOTLOADEREND - 1);

	uart_init();
	cause_of_reset();
	puts_polled("Polled "STR(NAME) " hello polled print, base:" STR(BASE));
	sprintf(buffer, " Optiboot major: %d 0x%x, minor %d 0x%x\r\n\n", major, major, minor, minor);
	puts_polled(buffer);

	wdt_enable(WDTO_2S);
	sei();

	_DDR( DUALBOOT) &= ~_MASK(DUALBOOT);	// 50 k internal pullup
	_PORT(DUALBOOT) |=  _MASK(DUALBOOT);
	while (1) {
		wdt_reset();

		puts_irq("Irq "STR(NAME) " hello IRQ print, base: " STR(BASE));
		sprintf(buffer, ", Port,Bit: " _STR(DUALBOOT) " = %s, watchdog_count=%d\r\n", 
			(_PIN(DUALBOOT) & _MASK(DUALBOOT)) ? "high" : "low",
			 watchdog_count);
		puts_irq(buffer);
		if (watchdog_count==1) {
			puts_irq("Irq: Enable Watchdog IRQ, set WDTCSR = 1<<WDIE, next expect Barking\r\n");
			WDTCSR = 1 << WDIE;	// enable watchdo interrupts 
		}
		puts_F( PSTR("Flash: sleep - watchdog is set to 2 sec\r\n"));
		sleeping = 1;
		while (sleeping);
		puts_irq("Irq: Survived Watchdog\r\n");// WDTCSR.WDIE must be set to enable watchdog interrupt
		wdt_enable(WDTO_8S);
		while (1) {
			//wdt_reset();
			_delay_ms(1000);
			print_all_pins();
		}

	}
}
