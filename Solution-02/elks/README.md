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
- The LCD gets garbled after a while: it receives a *function set 21h* command (4-bit
  mode). Not yet investigated.
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
