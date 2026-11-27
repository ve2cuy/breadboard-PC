# ELKS (Minix) on Solution-01

*[Version française](README_fr.md)*

[ELKS 0.9.2](https://github.com/ghaerr/elks) (a small Linux for the 8086, MINIX file system) built
for the Solution-01 breadboard. The ELKS sources are those of Solution-02 (`../../Solution-02/elks/src`);
only the configuration (`solution01.config`) and a few `CONFIG_HW_SOLUTION01` changes differ.

## Building

Docker Desktop, then from this folder:

```
powershell -ExecutionPolicy Bypass -File construire.ps1
```

The ia16-elf-gcc cross compiler is kept in the Docker volume `elks-s02-cache` (shared with
Solution-02). Output: `sortie/elks-solution01-fd360.img` (360 KB floppy). Copy it to the bridge's
flash (menu *USB Disk → ON*), then boot it with *USB Disk → 3) Boot disk image*. Log in as `root`.

Requires ROM 2.0 and bridge 2.3 (clock tick).

## What is different from Solution-02

Solution-01 has no 8253 timer, and its I/O decoding is minimal: the 8255 that talks to the bridge
answers to every port with A7 = 1, the 8259 to every port with A5 = 1. The ELKS of Solution-02
reached both, which froze the bridge link (cursor stuck at 0,0).

| Problem on Solution-01 | Change |
|---|---|
| No timer interrupt: no scheduling, no keyboard (polled on each tick) | Bridge 2.3 sends a tick every 54.9 ms (command 30h); the ROM BIOS turns it into INT 1Ch, as the PC BIOS does from IRQ 0; ELKS uses `CONFIG_TIMER_INT1C` |
| `outb_p`/`inb_p` pause by writing port 80h = 8255 data port: bytes sent to the bridge as commands | `IO_DELAY_PORT` 4Fh (`include/arch/io.h`, `CONFIG_HW_SOLUTION01`) |
| 8250 probes (3F8h-3FFh, 2F8h, 3E8h, 2E8h; LCR 3FBh = 8255 control word) | `CONFIG_CHAR_DEV_RS` off |
| Floppy motors off (3F2h), direct floppy driver (CMOS 70h, FDC) | `bioshd.c` guarded by `CONFIG_HW_SOLUTION01`; `CONFIG_BLK_DEV_FD` off |
| IDE/CF probes (1F0h-1F7h) | `CONFIG_IDE_PROBE`, `CONFIG_BLK_DEV_ATA_CF` off |
| `clock -s` reads the CMOS (70h/71h = 8259) | `clock` uses INT 1Ah of the BIOS (the bridge's RTC) |
| Speaker (61h = 8259) | `CONFIG_AUDIO` off |

Console: headless (INT 10h / INT 16h of the BIOS), terminal or PS/2 keyboard; the bridge's LCD
console shows it too.

Tested in the simulator (`tests/rom_test.py`, image copied to `PC-DOS/ELKS-0.9.2/fd360-minix-s01.img`):
login, `ls`, `date`, and no access to the 8255/8259 outside the BIOS.
