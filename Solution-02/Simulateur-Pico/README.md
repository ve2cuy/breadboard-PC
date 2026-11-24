# Solution-02 simulator with the Pico W

*[Version française](README_fr.md)*

This is the simulator of the **current Solution-02 board**: the [original simulator](../Simulateur/README.md)
(8088, LCD, LEDs, PS/2 keyboard, scope, logic analyzer, debugger…) plus everything added on 2026-11-23:

- the **ATmega328P U17**: J5 terminal at 57600 baud, Grove Wi-Fi module on J13;
- the **Raspberry Pi Pico W** (A1) on ports **50h-57h**, behind two **SN74LVC245** (U18 data, U19 address and control)
  and **RN4** (8 × 100 Ω);
- **READY**: Q1 pulls RDY1 of the 82C84 low, so the 8088 inserts wait states while the Pico answers;
- **J16** (GP22 → IRQ3), **J14** (the Pico's microSD reader) and **J15** (the Pico's UART1).

**Try it online: <https://ve2cuy.github.io/breadboard-PC/pico/>**

## What runs inside

| Part | What the simulator runs |
|---|---|
| 8088, 8259, 8253, 8255, LCD, ATmega | the models of the original simulator |
| BIOS | **BIOS 3.3** ([../bios](../bios)): it detects the Pico, reads the SD card through it and routes `INT 14h DX=1` (S02PKT, ELKS `ttyS1`) through it |
| Pico W | the **core of its real firmware** ([../pico/coeur](../pico/coeur)), compiled to WebAssembly: registers 50h-57h, SD commands, SLIP and the TCP/IP relay (smoltcp) |
| Pico timing | wait states per read (READY, 3 by default, from the cycle-accurate PIO test), command durations (sector read ≈ 0.4 ms) |
| Internet | built-in Internet, DNS-over-HTTPS, HTTP through the browser, optional TCP relay (see below) |

## Network

The 8088 sends IP packets over SLIP (192.168.240.2, gateway 192.168.240.1 = the Pico). The Pico terminates the 8088's
TCP connections itself, like slirp, and asks its host to open the real ones. In the page, that host is:

1. **Built-in Internet**, always available:
   - pings to any address are answered (a browser cannot send real pings);
   - zone `s02`: `www.s02` (10.83.0.80, test pages and a 64 KB file), `pico.s02`;
   - `http://192.168.240.1/` is the Pico's own status page.
2. **DNS-over-HTTPS** (Cloudflare) for real names, over UDP (mTCP) or TCP (ELKS).
3. **HTTP through the browser** (`fetch()`), without a relay. It only works for sites that allow cross-origin requests
   (CORS).
   The end-to-end page test (`node outils/essai_page.mjs`, Edge without a window) checks this path: DNS-over-HTTPS
   then `fetch()` from the page itself.
4. **TCP relay**, for real TCP/IP to any site (telnet, ftp, http…). Run `python outils/relais.py` on the computer, then
   click **Connect** in the **Pico W · Network** tab. The relay listens on `ws://127.0.0.1:8765` and uses only the
   Python standard library.

NTP (UDP 123) is answered with the computer's clock. While a real network operation is in progress (DNS-over-HTTPS,
fetch, relay), the page slows the simulation down to real time. At Max speed, the 8088's network timeouts would
expire before the Internet answers.

## Quick start

1. Power on. The BIOS shows `CPU 8088    Pico v01` on the Info screen.
2. **1) Load DOS**, choose **FDNET.IMG** (FreeDOS 1.4 + mTCP + S02PKT, loaded from J14 through the Pico).
3. Try these commands:
   - `PING 8.8.8.8`, `HTGET http://www.s02/`, `HTGET http://192.168.240.1/`;
   - without the relay, sites that allow CORS: `HTGET http://api.ipify.org/` (your public address on the LCD),
     `HTGET http://wttr.in/Montreal?format=3` (the weather);
   - with the relay, any site: `HTGET http://example.com/`.

**ELKSNET.IMG** (ELKS 0.9.2) works the same way: `root`, `net start slip`, `ping 8.8.8.8`,
`urlget http://www.s02/texte.txt`.

The **Pico W · Network** tab has:
- the status register (51h) and the bus accesses;
- the board options: Pico fitted, which reader holds the card (J14 or J9), J16, number of wait states;
- the Wi-Fi state, network counters and relay;
- the network log.

Right-click A1, U18, U19 or Q1 to inspect them.

## Measured in the simulator

| | Without Pico (SPI on U12) | With the Pico |
|---|---|---|
| DOS boot from C: to the packet driver | 37.4 s | 19.9 s |
| 64 KB HTTP download written to C: | — (≈ 2.7 KB/s through the ATmega) | 5.8 KB/s |

The download is limited by polling at 18.2 Hz in S02PKT (16 blocks of 255 bytes per tick with the Pico), not by the bus.

## Build and tests

```
.\construire.ps1 -Essais      # BIOS copy, netlist, WebAssembly, then cargo test
.\lancer.cmd                  # local server http://localhost:8088/
python outils\relais.py       # TCP relay for the page
node outils\essai_reseau.mjs [--relais ws://127.0.0.1:8765]   # the page's network path, end to end, with Node
node outils\essai_page.mjs [--relais ws://127.0.0.1:8765]     # the real page in Edge without a window (server on port 8099)
.\publier.ps1                 # publishes both simulators (gh-pages: / and /pico/)
```

`cargo test --release` runs the original simulator's tests on BIOS 3.3, plus [tests/pico.rs](tests/pico.rs):
- BIOS detection and the Info screen;
- MS-DOS 6.22 booted from the Pico's card, with mTCP `PING`, DNS and `HTGET` (including a 64 KB file written to C:);
- sector speed with and without the Pico;
- FreeDOS + mTCP;
- ELKS (`ping`, DNS over TCP, `urlget`).

The Pico's own tests are in [../pico/coeur](../pico/coeur): `cargo test`, and `cargo test --features pio` for the
cycle-accurate PIO test against the 8088 timings.

## Limits

- A snapshot restores the 8088 and the board, but the Pico restarts: its TCP connections are lost.
- Without the relay, UDP other than DNS and NTP is not forwarded, and incoming connections are not possible.
- The firmware's hardware layer (PIO, SPI0, CYW43439 Wi-Fi) is not simulated. It is checked by the PIO test and will be
  checked on the board.
