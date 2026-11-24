# Raspberry Pi Pico W on the 8088 bus (Solution-02)

*[Version française](README_fr.md)*

The Pico W (A1 on the schematic) is an I/O peripheral of the 8088 on ports **50h-57h**: O5 of the 74LS138, A0-A2.
It sits behind two **SN74LVC245** chips powered at 3.3 V:
- U18 for D0-D7, through RN4;
- U19 for A0-A2, ~SEL, ~RD, ~WR and RESET.

**Q1** pulls RDY1 of the 82C84 low, so the 8088 waits while the Pico answers. The Pico gives the 8088 its own microSD
card (J14), Wi-Fi with TCP/IP, and an interrupt (GP22 → IRQ3 through J16).

| Folder | Content |
|---|---|
| [coeur](coeur) | The firmware's **core**, without any hardware: registers 50h-57h, SD commands, SLIP, TCP/IP relay (smoltcp), the bus PIO program. The firmware and the [simulator](../Simulateur-Pico/README.md) share it. |
| [micrologiciel](micrologiciel) | The **firmware** (Rust, embassy): PIO1 and core 1 for the bus, SPI0 for the card, CYW43439 Wi-Fi with embassy-net, UART1 console. Output: `s02pico-micrologiciel.uf2`. |
| [etude-pico-w_fr.md](etude-pico-w_fr.md) | The study: level shifting, timing, pin map (in French). |

## Registers (port = 50h + n)

| n | Read | Write |
|---|---|---|
| 0 | next byte of the read FIFO (FFh if empty) | byte into the write FIFO |
| 1 | STATUS: 01h data, 02h busy, 04h error, 08h network data, 10h card, 20h Wi-Fi, 40h IRQ (bit 7 always 0) | COMMAND |
| 2-5 | parameters 0-3 (LBA, little-endian; count) | same |
| 6 | signature 50h | interrupt mask (bit 0: network data → GP22) |
| 7 | bytes in the read FIFO (255 at most) | — |

Commands:

| Code | Name | Effect |
|---|---|---|
| 00h | VIDER | clears the FIFOs and the error (immediate) |
| 01h | IDENT | read FIFO ← `S02PICO` + version (01h) |
| 10h | SD_INIT | read FIFO ← 1 (card ready) + sector count (4 bytes) |
| 11h | SD_LIRE | sector at LBA (parameters 0-3) → 512 bytes in the read FIFO |
| 12h | SD_ECRIRE | the first 512 bytes of the write FIFO → sector at LBA |
| 20h | NET_LIRE | read FIFO ← n, then n SLIP bytes for the 8088 (n ≤ parameter 0, 0 = 255) |
| 21h | NET_ECRIRE | write FIFO → SLIP stream from the 8088 |
| 22h | NET_ETAT | bytes waiting (2), Wi-Fi (1), Pico's address (4), RSSI (1) |
| 30h-32h | WIFI_SSID, WIFI_MDP, WIFI_CONNECTER | network name, password (from the write FIFO), join |

To use a command, write it to 51h, wait until bit 02h of 51h is 0, check bit 04h, then read 50h. BIOS 3.3
([../bios/pico.inc](../bios/pico.inc)) uses it for:
- the SD card: `sd_init`, `sd_lire`, `sd_ecrire`;
- `INT 14h DX=1`: blocks AH = 08h/09h, and AH = 0Ah returns AL = 50h when the Pico is present.

## Network: how the Pico relays TCP/IP

The 8088 keeps its own TCP/IP stack (mTCP, ELKS `ktcp`) and talks SLIP: 192.168.240.2, gateway 192.168.240.1 (the Pico).
The core works like slirp:
- **TCP** connections from the 8088 end in the Pico (smoltcp, any destination address). The firmware opens the real
  connection over Wi-Fi and copies the bytes both ways. No NAT is needed, and the home router never sees
  192.168.240.0/24.
- **UDP** (DNS…) and **pings** are relayed as datagrams and echoes.
- `http://192.168.240.1/` is a status page served by the Pico itself.

## The bus PIO program and READY

The program ([coeur/src/bus_pio.rs](coeur/src/bus_pio.rs), 24 instructions) works like this:
1. As soon as ~SEL falls (T1), it raises GP26, which pulls RDY1 low.
2. **Read:** it hands A0-A2 to core 1, puts the returned byte on D0-D7, then releases READY.
3. **Write:** it releases READY at once and samples D0-D7 when ~WR rises. The data is guaranteed for at least 88 ns
   then.

[coeur/tests/pio_bus.rs](coeur/tests/pio_bus.rs) runs the **assembled program** in a PIO emulator (125 MHz, input
synchronizer) against the 8088 at 5.333 MHz with worst-case datasheet timings (82C84, Q1, LVC245). Results:

| Core 1 latency | Average wait states | Max |
|---|---|---|
| 100 ns | 1.7 | 2 |
| 300 ns | 2.4 | 3 |
| 600 ns | 3.7 | 5 |
| 1.5 µs | 6.4 | 9 |

Every byte is right in all cases: READY holds the 8088 as long as needed.

When ~RD rises, U18 turns toward the Pico while the Pico still drives D0-D7 for **≈ 36 ns** (synchronizer + 2
instructions). RN4 (100 Ω) limits that current. Without RN4 it is a short circuit of ≈ 36 ns on every read.

## Build the firmware

```
rustup target add thumbv6m-none-eabi
cd micrologiciel
cargo build --release
python uf2.py target/thumbv6m-none-eabi/release/s02pico-micrologiciel s02pico-micrologiciel.uf2
```

The build uses 343 KB of flash and 141 KB of static RAM (with a 96 KB heap). To program the Pico:
1. Plug in its USB cable while holding **BOOTSEL**.
2. Copy `s02pico-micrologiciel.uf2` to the **RPI-RP2** drive.

The Wi-Fi network is set on the **J15 console** (UART1, 115200 baud, 3.3 V) with `ssid NAME`, `mdp PASSWORD` and
`connecter`. The setting is kept in the last flash sector. The 8088 can also set it with commands 30h-32h. `etat`
shows the Wi-Fi state, the address and the counters.

## Tests

```
cd coeur
cargo test                      # registers, SD, ping, DNS, TCP (a second smoltcp plays the 8088), status page
cargo test --features pio       # cycle-accurate PIO program against the 8088
```

The simulator ([../Simulateur-Pico](../Simulateur-Pico/README.md)) runs the same core with BIOS 3.3, MS-DOS, FreeDOS
(mTCP) and ELKS.

## Status (2026-11-23)

The schematic is done, the SN74LVC245AN chips are ordered, and nothing is wired yet. The firmware builds but has not run
on the Pico yet: it is validated by the simulator and the PIO test.
