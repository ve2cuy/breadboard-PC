# ELKS for Solution-02

[Version française](README_fr.md)

[ELKS](https://github.com/ghaerr/elks) (Embeddable Linux Kernel Subset) 0.9.2, a small
multitasking Unix-like system for the 8086/8088, adapted to the Solution-02 board. The
`src/` folder holds the full ELKS 0.9.2 source tree with the changes below (the
`Screenshots/` folder of the original repository is left out). ELKS is GPL v2, see
`src/LICENSE`.

Status: tested in the Solution-02 simulator (BIOS 2.6), **not yet on the board**. ELKS
boots to `login:` on the LCD and the terminal. Log in as `root` (no password). `uname`,
`ls`, `ps`, `cat`, the shell and redirections work.

## Why the stock images do not work

The official ELKS images drive the PC hardware directly: the screen in video memory
(B800h, which is ROM on Solution-02), the 6845 CRTC (3D4h), the keyboard on port 60h, the
floppy controller and its DMA (ports 00h–0Fh, which is the LCD on Solution-02). The only
other console they offer is an 8250 serial port at 3F8h, which the board does not have.
The kernel still boots from the SD card (through INT 13h), but nothing shows up.

## Changes

| File | Change |
|---|---|
| `src/solution02.config` | Build configuration, based on `ibmpc-1440.config`: **Headless console** (`CONFIG_CONSOLE_HEADLESS`: output through INT 10h AH=0Eh, keyboard polled through INT 16h, so the BIOS 2.6 console works: LCD, UART terminal and PS/2 keyboard), no scan-code keyboard driver, 360 KB floppy image (MINIX file system), `CONFIG_HW_SOLUTION02`. |
| `src/elks/config.in` | New option `CONFIG_HW_SOLUTION02` (Solution-02 board). |
| `src/elks/arch/i86/kernel/irqtab.S` | With `CONFIG_HW_SOLUTION02`: **8259 EOI at the start of each IRQ 0–7** (before `sti`), and no EOI at the end. See below. |
| `src/elkscmd/rootfs_template/bin/top` | New: a small `top` (shell script): `uptime` and `ps` (CPU %, heap, stack, size per task) refreshed every 2 s (`top 5`: every 5 s), Ctrl-C to quit. ELKS has no `top`. |
| `src/elkscmd/rootfs_template/bootopts` | `disable=df0,cfa`: the direct floppy driver (8237 DMA on ports 00h–0Fh) and the CompactFlash driver stay disabled. Disks go through the BIOS (`fd0`, `hda`). These drivers are still compiled in because, without `CONFIG_BLK_DEV_FD`, `directfd.c` does not build in ELKS 0.9.2. |

`solution02.patch` holds the same changes as a diff against ELKS v0.9.2.

### Lost characters at the terminal (8259 EOI)

The BIOS receives the UART in software: IRQ4 signals the start bit, then the bits are
sampled by timed loops. IRQ4 must be served within about half a bit (~50 µs at 9600
baud). ELKS sent the EOI to the 8259 only at the end of each interrupt handler. For the
timer (IRQ0, 100 Hz), that takes about 230 µs, which includes a keyboard poll through
INT 16h. During that time, the 8259 holds back the lower-priority IRQs (IRQ1 keyboard,
IRQ4 UART). Since the 8259 works in edge mode, the start bit was lost and the BIOS
started reading a frame on a later falling edge. The byte was then read shifted by
several bits (`b` → `ECh`), or dropped when it looked like a UTF-8 lead byte. That is how
`root` became `rot`. The BIOS already sends its own IRQ0 EOI at entry for this reason;
the ELKS change does the same.

Measured in the simulator, 400 bytes at random phase: without the change, only 41 IRQ4
were served and most of them late (up to 862 µs). With the change, 399 IRQ4 were served,
18 of them late.

### Remaining limits

- **About 2–3 % of typed characters are still lost or wrong** (simulator, irregular
  typing 100–300 ms apart, UART terminal or PS/2 keyboard). The causes:
  - the start of the ELKS interrupt entry (stack switch with interrupts off, ~120 µs on
    each 10 ms tick);
  - the BIOS software UART, which cannot receive while it sends (echo, and line redraws
    by the shell's line editor past 80 columns).

  A hardware UART (MC6850, 8250…) would remove this limit.
- **Turn the LED animations off** (main menu, key 7) before booting ELKS. ELKS calls the
  BIOS timer every 5th tick, and an animation step masks interrupts long enough to lose a
  character.
- **Ethernet drivers disabled** (`# CONFIG_ETH is not set`). The board decodes only
  address lines A0-A7, so the ISA probes of ELKS landed on its own chips: NE2000 at 300h
  = LCD (it wrote 21h, *function set* 4-bit mode: garbled LCD), WD8003 at 240h = 8253,
  3C509 at 330h = U12. Do not turn them back on.
- The ANSI sequences ELKS sends to the terminal (clear screen, cursor moves) are
  interpreted by BIOS 2.8 instead of being shown on the LCD.
- The date is wrong (1979): ELKS reads the RTC at ports 70h/71h, which the board does
  not have. Use `date` to set it.
- The 360 KB image has the 36 programs of the ELKS `APPS_360K` list (`sh`, `ls`, `cat`,
  `cp`, `mv`, `rm`, `mkdir`, `more`, `edit`, `grep`, `ps`, `mount`, `fdisk`, `mkfs`,
  `tetris`…).

## Use

1. Copy the image (`PC-DOS/ELKS-0.9.2/fd360-minix-s02.img`, outside git, or
   `sortie/elks-solution02-fd360.img` after a build) to the SD card.
2. Main menu: **7** (LED animations OFF), then **1) DOS**, pick the image, Enter.
3. After ~50 s (360 KB read through the SD card): `login:` → `root`, no password.

## Hard disk image (all programs, C compiler)

`PC-DOS/ELKS-0.9.2/hd32-minix-s02.img` (outside git; `sortie/elks-solution02-hd32.img`
after a build): 32 MB, partition table (63 sectors × 16 heads), one MINIX partition
(type 80h), ELKS installed with **every program** of `elkscmd` (about 200 in `/bin`: `vi`,
`edit`, `emacs` (kilomacs), `kilo`, `sed`, `diff`, `find`, `tar`, `gzip`, `bc`, `basic`,
`lua`, `screen`, `ps`, `top`, `meminfo`, `uptime`, games…) and the external applications
that build: the **C86 native C compiler** (`/usr/bin`: `cpp`, `c86`, `as`, `ld`, `ar`,
`make`, `objdump`, `disasm86`; headers in `/usr/include`, `/usr/lib/libc86.a`, examples
in `/usr/src`), the dcc compiler (`/usr/dcc`), Lua, Doom, Moria, Digger, image viewers…
There is no C++ compiler for ELKS. The graphical programs (Nano-X, GEM, paint) need a VGA
card and do not run on the board.

1. Copy the image to the SD card (in one piece: the BIOS refuses a fragmented image).
   The BIOS mounts it as C: (first `.IMG` larger than 1.44 MB).
2. Main menu: **7** (LED animations OFF), **1) DOS**, pick the C: line, Enter.
3. `login:` → `root`. From a MINIX partition on C:, BIOS 2.8 drops the RAM disk B: and
   gives ELKS 507 KB (506K seen by the kernel, ~346 KB free): with the 379 KB announced
   otherwise, `cpp` and `c86` fail (*not enough memory*).

Compiling a program on the board:

```
cpp -0 -I/usr/include -I/usr/include/c86 hello.c -o hello.i
c86 -O -bas86 -separate=yes -lang=c99 -stackcheck=no hello.i hello.as
as -0 -j hello.as -o hello.o
ld -0 -i -L/usr/lib -o hello hello.o -lc86
./hello
```

`/usr/src/Makefile` (examples) shows the same steps for `make`.

## Networking (Wi-Fi over SLIP)

The Wi-Fi module on J13 is a SLIP router with NAT (esp_slip_router, see the Solution-02
README). ELKS reaches it through **`/dev/ttyS1`**: driver
`elks/arch/i86/drivers/char/serial-s02.c` (+ `serial-s02-asm.S`), used instead of the 8250
driver when `CONFIG_HW_SOLUTION02` is set. It goes through BIOS 3.1 (INT 14h, DX = 1, AH =
08h/09h: blocks), which shares the SPI bus with the SD card; reception is polled at every
clock tick (`serial_bh`, 64 bytes at most), the speed is set by the module (115200). There is
no `ttyS0`. At boot: `ttyS1 Wi-Fi module via BIOS INT 14h (ATmega U17 channel 2)`.

```
net start slip                 # ktcp -m 512 on /dev/ttyS1, 192.168.240.2, gateway .1; telnetd
ping -c 3 192.168.240.1        # the module
ping -c 3 8.8.8.8              # Internet, through the NAT
ping google.com                # DNS through OpenDNS (208.67.222.222, over TCP)
```

- Image settings: `/etc/net.cfg` (`link=slip`, `device=/dev/ttyS1`, `baud=115200`,
  `mtu="-m 512"`: TCP segments of 472 bytes at most, within the ATmega's 1 KB buffer,
  `netstart="telnetd"`), `/bin/net` (passes the MTU to ktcp over SLIP), `/bootopts`
  (`LOCALIP=192.168.240.2`, `GATEWAY=192.168.240.1`, `NETMASK=255.255.255.0`, `buf=24`).
- **Memory**: `buf=24` (disk buffers 64 → 24 KB) and no `ftpd`: with 64 buffers and ftpd, a
  telnet session left no block large enough to run `ls`.
- **Telnet from the PC**: ELKS is behind the module's NAT. Add a port forward in the module
  (console `telnet 192.168.240.1 7777` from ELKS: `portmap add TCP 23 192.168.240.2 23`,
  `save`), then `telnet <module Wi-Fi address>` from the PC. Give root a password (`passwd`):
  without one, the whole Wi-Fi network gets a root session.
- Throughput: the 8088 reads the module at ~6 KB/s at most, with no flow control: ping, telnet
  and small transfers work well; large transfers will see TCP retransmissions.
- Simulator: `tests/elks_reseau.rs` (simulated SLIP module answering pings, local telnet
  session).

## Build

From Windows, with Docker Desktop running:

```
powershell -ExecutionPolicy Bypass -File construire.ps1
```

`construire.sh` runs in an Ubuntu 24.04 container. It installs the tools (`xxd` is
needed: without it `bootblocks/mbr_autogen.c` stays empty and `makeboot.c` does not
build), builds the ia16-elf-gcc 6.3.0 cross toolchain once (~20 min, kept in the Docker
volume `elks-s02-cache`), then the kernel, the programs and the image:
`sortie/elks-solution02-fd360.img` and `sortie/elks-solution02-noyau.bin`. The full
`make` ends with an error on the full image (too many files for 360 KB); the script
expects this and then builds the reduced image (`make fd360-minix`).

Hard disk image:

```
powershell -ExecutionPolicy Bypass -File construire-hd.ps1
```

`construire-hd.sh` runs `construire.sh`, then downloads OpenWatcom v2 (Linux snapshot,
kept in the volume), clones and builds the external applications with `buildext.sh`
(C86, dcc, Lua, Doom…; a failing project is only left out of the image, see
`sortie/externes.log`), and builds `make hd32mbr-minix` (`CONFIG_APPS_HD`: every program):
`sortie/elks-solution02-hd32.img`. Files left out: `sortie/absents-hd.log`.
