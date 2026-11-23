# ATmega328P firmware (Solution-02, U17)

[Version française](README_fr.md)

The ATmega328P (16 MHz crystal) gives the 8088 of the Solution-02 board two UARTs. The
8088 talks to it over SPI, on the SD card bus (schematic of 2026-11-23, see
`Solution-02/README.md`):

- **channel 1 = terminal** (J5, RTS/CTS on J8): software UART on timer 1, 2400 to
  115200 baud, **57600 at power-up**;
- **channel 2 = Grove - UART WiFi V2 module** (J13, ESP8285, AT firmware): hardware
  USART, 115200 baud, no flow control.

It keeps the bytes in its RAM: the 8088 reads them whenever it wants, with no loss even
when its interrupts stay masked.

| ATmega328P | Signal | Board |
|---|---|---|
| PB0 ICP1 / PB1 OC1A | UART_RX / UART_TX | J5 pins 2 / 1 (terminal; R4 pulls RX idle) |
| PB2 SS | AVR_SS | U12 PC0 (R21 to +5 V) |
| PB3 MOSI / PB5 SCK | SD_MOSI / SD_SCK | U12 PC6 / PC5, shared with the SD card |
| PB4 MISO | AVR_MISO | U12 PB4 (R20 to +5 V) |
| PD0 RXD / PD1 TXD | WIFI_TX / WIFI_RX | J13 pins 1 / 2 (module TX / RX) |
| PD2 | IRQ4 | 8259 IR4 (rising edge) |
| PD6 / PD7 | RTS / CTS | J8 pins 1 / 2, active low (R22 pulls CTS low) |

The Grove module level-shifts its own RX input (2N7002, 1 kΩ pull-up to its 5 V VCC); its
TX output (3.3 V) is enough for the ATmega (VIH = 3.0 V at 5 V). Direct wiring, no divider.

## SPI protocol (version 3)

- SPI mode 0, MSB first, like the SD card. The SD card is deselected (U12 PC4 = 1) while
  SS (U12 PC0) = 0. At least 10 µs between two bytes: the ATmega prepares the next byte in
  its SPI interrupt.
- **Transaction**: SS = 0, one command byte, data bytes, SS = 1. The byte the 8088
  receives during byte *n* is the one the ATmega prepared at the end of byte *n−1*.
- During the command byte the 8088 always receives **A5h**. Without an ATmega it reads
  FFh (R20 pull-up): that is how the BIOS detects it.
- **Command = channel + operation**: bit 4 = 0 for the terminal, 1 for Wi-Fi. Channel 1
  commands are the version 2 ones: BIOS 2.7 or 2.8 works unchanged.

| Command | Bytes sent by the 8088 after the command | Bytes received |
|---|---|---|
| `00h` IDENT | 5 fillers | `'S'`, `'2'`, version (3), channel 1 speed, channel 2 speed |
| `01h` / `11h` STATUS | 5 fillers | received count (low, high), free transmit space (low, high), flags |
| `02h` / `12h` READ | 1 filler, then *n* | *n* = min(received, 255), then the *n* bytes |
| `03h` / `13h` WRITE | 1 filler, then the bytes to send | *f* = min(free space, 255), then 00h |
| `04h` / `14h` SPEED | speed code | 00h |
| `05h` / `15h` FLUSH | A5h (confirmation) | 00h |

- **READ**: a byte leaves the buffer only once fully transferred. Raising SS early loses
  nothing; the rest comes with the next READ.
- **WRITE**: bytes beyond the free space are lost and set flag bit 2.
- **STATUS flags** (cleared by reading): bit 0 = a received byte was lost (receive buffer
  full), bit 1 = framing error or overrun, bit 2 = a byte to send was lost (transmit buffer
  full), bit 6 = CTS active (the terminal accepts bytes), bit 7 = RTS active (the ATmega
  accepts bytes). Channel 2: bits 6 and 7 always 1 (no flow control).
- **SPEED**: 0 = 9600, 1 = 19200, 2 = 38400, 3 = 57600, 4 = 115200, 5 = 4800,
  6 = 2400 baud, 8N1. Applied once everything pending has been sent. Power-up: channel 1 at
  57600, channel 2 at 115200 (AT firmware speed). The ATmega is not reset with the 8088
  (RESET button, Ctrl+Alt+Del): it keeps its speeds, which the BIOS reads back with IDENT.
- **FLUSH** acts only with the A5h confirmation: a stray byte (SD card SPI traffic with
  SS = 0 by mistake) cannot flush the buffers.

## IRQ and flow control

- **IRQ (PD2 → IR4)** = 1 when a byte received **from the terminal** is waiting and no
  transaction is in progress. It drops at the start of every transaction and rises again at
  the end if bytes remain: each transaction that leaves data gives the 8259 a new rising
  edge (edge mode). Channel 2 is polled (STATUS / READ `11h`/`12h`).
- **RTS** (channel 1) is dropped at 384 waiting bytes and raised again at 128.
- **CTS** (channel 1): the ATmega stops sending while the terminal's CTS is 1 (within one
  byte). With nothing on J8, R22 keeps CTS active.
- Buffers (2 KB of RAM in all): channel 1, 512 bytes receive and 64 transmit; channel 2,
  1024 receive (the module has no flow control) and 128 transmit.

## Terminal software UART

- **Receive**: input capture (ICP1) timestamps every line edge to the cycle; the interrupt
  stores time and level in a 16-edge queue. The main loop decodes frames from these
  timestamps (each bit = line level at mid-bit): no latency constraint on decoding.
- **Transmit**: compare A (OC1A) sets each bit to the cycle; the interrupt picks the next
  bit. One bit = 139 cycles at 115200 baud (0.08 % error).
- Both timer interrupts are in assembly (`src/uart_isr.S`) and keep their state in reserved
  registers (r2 to r10, `-ffixed-…`, no LTO); the SPI and PCINT interrupts mask SPI and
  PCINT, then re-enable interrupts (`sei`) before saving their registers. The timer thus
  never waits more than ~15 cycles.
- **Limit**: at 115200 baud in continuous full duplex (pasting into the terminal while the
  8088 echoes), the ATmega's CPU is nearly full. The test bench passes with an 8088 at its
  real speed (~110 µs per SPI byte), not with an 8088 twice as fast. At 57600 baud (the
  default) it passes even with an 8088 3.6 times as fast.

## Files

| File | Contents |
|---|---|
| `src/protocole.h`, `src/protocole.c` | protocol and buffers of both channels, no AVR register (tested on the PC) |
| `src/main.c` | hardware: terminal decoding and transmit, module USART, SPI slave, IRQ, RTS/CTS |
| `src/uart_isr.S`, `src/uart_logiciel.h` | assembly interrupts (timer 1, SPI and PCINT entries), reserved registers |
| `test/test_protocole.c` | 73 checks: the 8088 master simulated byte by byte |
| `test/banc_simavr.c` | full firmware under simavr, cycle-accurate: terminal, module, 8088 |
| `fusibles.txt` | lfuse FFh (crystal), hfuse D9h, efuse FDh |

## Build, test, program

```
make                 # PlatformIO: .pio/build/atmega328p/firmware.hex
make test            # protocol checks on the PC (WSL gcc)
make banc            # simavr bench: 300 bytes echoed each way, 115200, 57600, 9600
make flash PUCE=ok   # TL866CS, chip in the ZIF socket: firmware then fuses
make fusibles        # read the fuses back
```

`make banc` needs simavr in WSL, extracted without `sudo` (see the Makefile). The bench
makes up for three differences between simavr 1.6 and the real AVR: an interrupt unmasked
while its flag is set is not triggered there; writing TIFR1 clears all timer flags there
(the hardware clears only the bits written as 1); the OC1A pin changes there as soon as
TCCR1A is written. Variables: `BANC_VITESSES` (speed codes), `BANC_OCTETS`, `BANC_US`
(µs per SPI byte).

The chip is programmed out of circuit. `minipro` reports *Fuses verify error*: it reads
back hfuse's SPIEN bit as 1 (F9h), which cannot be changed in this programming mode. The
firmware never goes to `Z:/Partage/Alain`, which is reserved for the 8088 ROMs.
