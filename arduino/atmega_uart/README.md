# ATmega328P firmware (Solution-02, U17)

[Version française](README_fr.md)

The ATmega328P (16 MHz crystal) is the UART of the Solution-02 board. It receives and
sends on J5 by itself, keeps the bytes in its RAM, and the 8088 talks to it over SPI on
the SD card bus (schematic of 2026-11-21, see `Solution-02/README.md`). It replaces the
software UART of BIOS 2.6, which loses characters as soon as interrupts stay masked for
more than about 50 µs.

| ATmega328P | Signal | Board |
|---|---|---|
| PB2 SS | AVR_SS | U12 PC0 (R21 to +5 V) |
| PB3 MOSI / PB5 SCK | SD_MOSI / SD_SCK | U12 PC6 / PC5, shared with the SD card |
| PB4 MISO | AVR_MISO | U12 PB4 (R20 to +5 V) |
| PD0 RXD / PD1 TXD | UART_RX / UART_TX | J5 pins 2 / 1 |
| PD2 | IRQ4 | 8259 IR4 (rising edge) |
| PD6 / PD7 | RTS / CTS | J8 pins 1 / 2, active low (R22 pulls CTS low) |

## SPI protocol (version 2)

- SPI mode 0, most significant bit first, as for the SD card. The SD card is deselected
  (U12 PC4 = 1) while SS (U12 PC0) = 0. At least 10 µs between two bytes: the ATmega
  prepares the next byte in its SPI interrupt.
- **Transaction**: SS = 0, a command byte, data bytes, SS = 1. The byte the 8088
  receives during byte *n* is the one the ATmega prepared at the end of byte *n−1*.
- During the command byte, the 8088 always receives **A5h**. Without the ATmega, it reads
  FFh (R20 pull-up): this is how the BIOS detects it.

| Command | Bytes sent by the 8088 after the command | Bytes received |
|---|---|---|
| `00h` IDENT | 4 dummies | `'S'`, `'2'`, version (2), speed in service (VITESSE code; version 2) |
| `01h` ETAT (status) | 5 dummies | received count (low, high), free transmit space (low, high), flags |
| `02h` LIRE (read) | 1 dummy, then *n* dummies | *n* = min(received, 255), then the *n* bytes |
| `03h` ECRIRE (write) | 1 dummy, then the bytes to send | *f* = min(free space, 255), then 00h |
| `04h` VITESSE (speed) | speed code | 00h |
| `05h` VIDER (flush) | A5h (confirmation) | 00h |

- **LIRE**: a byte leaves the buffer only once it has been fully shifted out. Raising SS
  early loses nothing; the rest comes with the next LIRE.
- **ECRIRE**: bytes beyond the free space are dropped and set flag bit 2.
- **ETAT flags** (cleared by reading): bit 0 = a received byte was lost (receive buffer
  full), bit 1 = USART framing error or overrun, bit 2 = a byte to send was lost
  (transmit buffer full), bit 6 = CTS asserted (the terminal accepts bytes), bit 7 = RTS
  asserted (the ATmega accepts bytes).
- **VITESSE**: 0 = 9600 (at power-up), 1 = 19200, 2 = 38400, 3 = 57600, 4 = 115200,
  5 = 4800, 6 = 2400 baud, 8N1. Applied once everything waiting has been sent. The ATmega is
  not reset with the 8088 (RESET button, Ctrl+Alt+Del): it keeps its speed, and BIOS 2.7 reads
  it back through IDENT (version 2) so the terminal stays at the chosen speed; power-up = 9600.
- **VIDER** acts only with the A5h confirmation: a stray byte (SPI traffic for the SD
  card with SS = 0 by mistake) cannot empty the buffers.

## IRQ and flow control

- **IRQ (PD2 → IR4)** = 1 when a received byte is waiting and no transaction is in
  progress. It drops at the start of each transaction and rises again at the end if bytes
  remain. Each transaction that leaves data behind therefore gives the 8259 (edge mode) a
  new rising edge.
- **RTS** is withdrawn at 768 bytes waiting (out of 1024) and given back at 256.
- **CTS**: the ATmega stops sending while the terminal's CTS is high. With nothing on J8,
  R22 keeps CTS asserted.
- Buffers: 1024 bytes for reception, 512 bytes for transmission.

## Files

| File | Contents |
|---|---|
| `src/protocole.h`, `src/protocole.c` | protocol and buffers, no AVR register (tested on the PC) |
| `src/main.c` | hardware: USART, SPI slave, pin-change interrupt on SS, IRQ, RTS/CTS |
| `test/test_protocole.c` | 56 checks: the 8088 master simulated byte by byte |
| `fusibles.txt` | lfuse FFh (crystal), hfuse D9h, efuse FDh |

## Build, test, program

```
make                 # PlatformIO: .pio/build/atmega328p/firmware.hex
make test            # protocol checks on the PC (WSL gcc)
make flash PUCE=ok   # TL866CS, chip in the ZIF socket: firmware then fuses
make fusibles        # reads the fuses back
```

The chip is programmed off the board. `minipro` reports *Fuses verify error*: it reads
back the SPIEN bit of hfuse as 1 (F9h), which cannot be changed in this programming mode.
The firmware never goes to `Z:/Partage/Alain`, which is reserved for the 8088 ROMs.
