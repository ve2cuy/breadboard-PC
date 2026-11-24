# S02PKT: DOS packet driver (Solution-02)

[Version française](README_fr.md)

`S02PKT.COM` is a **packet driver** (Packet Driver Specification 1.09, class 1 = Ethernet)
for the Solution-02 Wi-Fi module: a Grove - UART WiFi V2 reflashed as a SLIP router with NAT
(esp_slip_router), behind the ATmega U17. It brings networking to DOS programs that use a
packet driver, in particular **mTCP** (`PING`, `TELNET`, `FTP`, `HTGET`, `NC`, `SNTP`,
`IRCJR`, `HTTPSERV`…).

## How it works

- Like ETHERSL, it presents a **simulated Ethernet card** (MAC 02:53:30:32:00:02):
  - IPv4 frame sent: Ethernet header removed, IP packet sent to the module over SLIP;
  - ARP request: reply built on the spot, with the "peer" address (02:53:30:32:00:01) for any
    IP address asked, since everything goes through the module. No reply to address conflict
    probes (asked address = sender's own, or sender at 0.0.0.0);
  - IP packet received over SLIP: Ethernet header added, handed to the program registered for
    type 0800h.
- It goes through **BIOS 3.1**: INT 14h, DX = 1, AH = 08h (block read) and 09h (block write).
  The BIOS shares the SPI bus with the SD card.
- There is no interrupt for channel 2: the module is **polled at every INT 1Ch** (18.2 Hz),
  255 bytes per tick at most (~4.6 KB/s), on a private stack.
- **With the Pico W** (BIOS 3.3, ports 50h-57h, [../pico](../pico/README.md)), the same calls go through
  the Pico. `INT 14h DX=1 AH=0Ah` returns AL = 50h, so S02PKT reads up to **16 blocks per tick**: one
  block takes ≈ 1 ms through the Pico.
- Specification functions: `driver_info`, `access_type` (4 handles), `release_type`,
  `send_pkt`, `get_address`, `reset_interface`, `get_statistics`. `terminate` is refused: the
  driver stays resident (≈ 2.7 KB).

## Use

```
C:\MTCP\S02PKT               (installs the driver on INT 60h)
SET MTCPCFG=C:\MTCP\MTCP.CFG
PING 192.168.240.1           (the module)
PING 8.8.8.8                 (Internet, through the NAT)
HTGET http://example.com/
```

`MTCP.CFG`:

```
PACKETINT 0x60
IPADDR 192.168.240.2
NETMASK 255.255.255.0
GATEWAY 192.168.240.1
NAMESERVER 8.8.8.8
MTU 576
```

It needs **BIOS 3.1** (or later) and an **ATmega at version 3** (or later): otherwise
`S02PKT` refuses to install. ELKS and DOS use the same addresses: only one of them runs on
the board at a time.

## Hard disk image

`bios/tests/gen_dosnet.py` builds `PC-DOS/DOSNET_C.IMG` (32 MB, not in git): MS-DOS 6.22
(like `gen_dos622.py`), mTCP in `C:\MTCP` (archive `PC-DOS/mTCP_2026-10-10.zip`, mTCP by
Michael Brutman, GPL: <https://www.brutman.com/mTCP/>), `S02PKT.COM` and `MTCP.CFG`;
`AUTOEXEC.BAT` loads the driver and sets `MTCPCFG`.

## Build and test

```
nasm -f bin -o S02PKT.COM s02pkt.asm
python ../bios/tests/gen_dosnet.py
cd ../Simulateur && cargo test --release --test dos_reseau -- --nocapture
```

The simulator test boots DOS from C:, checks the driver installation, then
`PING 192.168.240.1` and `PING 8.8.8.8` (the simulated module answers pings).

## Limits

- Modest throughput: a few KB/s (bit-banged SPI on the 8088, polling at 18.2 Hz), no flow
  control on channel 2. MTU 576 recommended.
- `PING` through the ESP8285's NAT works; incoming connections need a port forward in the
  module (`portmap`), as for ELKS.
