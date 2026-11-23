/*
 * ELKS serial driver for the Solution-02 breadboard computer (8088, no 8250 UART).
 *
 * ttyS1 (COM2) is the Wi-Fi module (Grove - UART WiFi V2 flashed with esp_slip_router),
 * reached through the ATmega328P U17 (channel 2, SPI slave of the 8088) by the board BIOS:
 * INT 14h DX=1, AH=08h reads a block (ES:BX, CX -> CX read, no wait), AH=09h writes a block
 * (BIOS 3.1 and later). The BIOS serializes access with the SD card on the same SPI bus.
 * There is no interrupt for channel 2: received bytes are polled every clock tick, from the
 * timer bottom half (serial_bh).
 * The line speed is fixed by the module (115200 baud); baud rate settings are ignored.
 * ttyS0 is not available (the terminal is the console, through the BIOS).
 *
 * Usage: net start slip 115200 /dev/ttyS1
 *
 * Nov 2026 Solution-02 project
 */
#include <linuxmt/config.h>
#include <linuxmt/wait.h>
#include <linuxmt/chqueue.h>
#include <linuxmt/sched.h>
#include <linuxmt/errno.h>
#include <linuxmt/mm.h>
#include <linuxmt/ntty.h>
#include <linuxmt/kdev_t.h>
#include <linuxmt/termios.h>
#include <linuxmt/debug.h>
#include <arch/irq.h>

#define S02_PORT        1       /* ttyS1 = COM2 = INT 14h DX=1 */
#define S02_POLL_MAX    64      /* bytes read per clock tick at most (6.4 KB/s at HZ=100) */
#define S02_WRITE_MAX   64

extern int s02_present(void);                   /* serial-s02-asm.S */
extern int s02_read(char *buf, int max);
extern int s02_write(char *buf, int len);

extern struct tty ttys[];

static struct tty *s02_tty;     /* ttyS1 while open */
static int s02_ok;              /* BIOS 3.1 with a version 3 ATmega found at boot */

/* called every clock tick by timer_bh: bytes received from the module */
void serial_bh(void)
{
    struct tty *tty = s02_tty;
    char buf[S02_POLL_MAX];
    int n, i;

    if (!tty)
        return;
    n = s02_read(buf, sizeof(buf));
    for (i = 0; i < n; i++) {
        if (!tty_intcheck(tty, (unsigned char)buf[i]))
            chq_addch(&tty->inq, (unsigned char)buf[i]);
    }
}

/* comirq= in /bootopts: no IRQ here */
void set_serial_irq(int tty, int irq)
{
}

/* printk console out: not used (the console is the BIOS) */
void rs_conout(dev_t dev, int c)
{
    char ch = c;

    if (s02_ok && MINOR(dev) - RS_MINOR_OFFSET == S02_PORT)
        s02_write(&ch, 1);
}

/* serial write: blocks of up to S02_WRITE_MAX bytes, the BIOS waits for room */
static int rs_write(struct tty *tty)
{
    char buf[S02_WRITE_MAX];
    int n, total = 0;

    while (tty->outq.len > 0) {
        for (n = 0; n < S02_WRITE_MAX && tty->outq.len > 0; n++)
            buf[n] = (char)tty_outproc(tty);
        s02_write(buf, n);      /* (bytes the BIOS could not place in ~1 s are lost) */
        total += n;
    }
    return total;
}

static void rs_release(struct tty *tty)
{
    debug_tty("SERIAL close %P\n");
    if (--tty->usecount == 0) {
        s02_tty = NULL;
        tty_freeq(tty);
    }
}

static int rs_open(struct tty *tty)
{
    int err;

    debug_tty("SERIAL open %P\n");
    if (tty->minor - RS_MINOR_OFFSET != S02_PORT || !s02_ok)
        return -ENODEV;
    if (tty->usecount++)
        return 0;

    err = tty_allocq(tty, RSINQ_SIZE, RSOUTQ_SIZE);
    if (err) {
        --tty->usecount;
        return err;
    }
    while (s02_read((char *)tty->inq.base, tty->inq.size) > 0)
        ;                       /* drop what arrived before the open */
    s02_tty = tty;
    return 0;
}

static int rs_ioctl(struct tty *tty, int cmd, char *arg)
{
    switch (cmd) {
    case TCSETS:
    case TCSETSW:
    case TCSETSF:
        return 0;               /* speed fixed by the module */
    default:
        return -EINVAL;
    }
}

void INITPROC serial_init(void)
{
    s02_ok = s02_present();
    if (s02_ok)
        printk("ttyS1 Wi-Fi module via BIOS INT 14h (ATmega U17 channel 2)\n");
    else
        printk("ttyS1 absent (BIOS 3.1 and ATmega v3 needed)\n");
}

#ifdef CONFIG_BOOTOPTS
void INITPROC rs_setbaud(dev_t dev, unsigned long baud)
{
}
#endif

struct tty_ops rs_ops = {
    rs_open,
    rs_release,
    rs_write,
    NULL,
    rs_ioctl,
    rs_conout
};
