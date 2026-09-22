#!/usr/bin/env python3
"""Banc d'essai de lib/bios.asm (INT 10h std, 11h, 12h, 13h, 15h, 16h, 19h, 1Ah) et de lib/isr.asm
sous emulateur (Unicorn). Les VRAIES routines s'executent; le 8255 est emule et ce script joue le
role du pont (BridgeModel de basic_harness: horloge + secteurs) et de l'ISR pour les reponses.

Chaque cas est execute comme le ferait un DOS: SS:SP = 3000h:F000h, DS = 2000h... (JAMAIS VAR_SEG),
registres propres au cas, puis INT n. On verifie les registres/indicateurs au retour et que la pile
et les segments du programme sont intacts (le BIOS bascule sur sa pile privee de VAR_SEG).

Usage (depuis la racine de Solution-01):  python3 tests/bios_test.py
"""
import os, struct, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
import basic_harness as H

BIN = os.path.join(ROOT, 'build', 'bios_test.bin')
os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
subprocess.run(['nasm', '-f', 'bin'] + (['-dBIOS_TRACE=1'] if os.environ.get('TRACE') else []) + (['-dBIOS_HIDE_HD=1'] if os.environ.get('HIDEHD') else []) + ['tests/bios_test.asm', '-o', BIN], cwd=ROOT, check=True)

ROM = 0xC0000
CASES = ROM + 0x4000
RESULTS = ROM + 0x6000
PORTC_ADDR = ROM + 0x3F04
PORTA_ADDR = ROM + 0x3F05
SEG = 0x10000
BR_HEAD, BR_TAIL, BR_BUF, BR_EXPECT = SEG + 0xFC52, SEG + 0xFC53, SEG + 0xFC70, SEG + 0xFC64
UART_HEAD, UART_TAIL, UART_BUF = SEG + 0xFC3C, SEG + 0xFC3D, SEG + 0xFD00
PS2_HEAD, PS2_TAIL, PS2_BUF = SEG + 0xFC2A, SEG + 0xFC2B, SEG + 0xFC2C
CF, ZF = 0x0001, 0x0040
IN_DEFAULT = 0
fails = 0
total = 0


def check(name, cond, extra=''):
    global fails, total
    total += 1
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '   -> ' + extra[:240]))
    if not cond:
        fails += 1


def case(n, ax=0, bx=0, cx=0, dx=0, si=0, di=0, es=0x5000, ds=0x2000, bp=0x1234, ss=0x3000, sp=0xF000,
         portc=0x80, porta=0):
    return struct.pack('<BBHHHHHHHHHHHBB', n, 0, ax, bx, cx, dx, si, di, es, ds, bp, ss, sp, portc, porta) + bytes(6)


class Res:
    def __init__(self, raw):
        (self.ax, self.bx, self.cx, self.dx, self.si, self.di, self.es, self.ds, self.bp, self.ss,
         self.sp, self.fl) = struct.unpack('<12H', raw[:24])

    @property
    def ah(self):
        return self.ax >> 8

    @property
    def al(self):
        return self.ax & 0xFF

    @property
    def cf(self):
        return bool(self.fl & CF)

    @property
    def zf(self):
        return bool(self.fl & ZF)


def run(cases, bridge=None, mem=None, uart_in=b'', ps2_in=b'', expect=0, count=400_000_000, stop_after=None, rom_ro=False):
    """cases = liste d'entrees; mem = {adresse physique: octets} ecrits avant l'execution"""
    code = open(BIN, 'rb').read()
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0x00000, 0x80000)
    uc.mem_map(0xC0000, 0x40000)
    uc.mem_write(ROM, code)
    if os.environ.get('GARBAGE'):                       # RAM non nulle au depart (comme le materiel apres une session BASIC): 0500h-1F7FFh
        import random
        uc.mem_write(0x500, random.Random(int(os.environ['GARBAGE'])).randbytes(0x1F800 - 0x500))
    uc.mem_write(CASES, b''.join(cases) + b'\xFF')
    for a, b in (mem or {}).items():
        uc.mem_write(a, bytes(b))
    for i, b in enumerate(uart_in):
        uc.mem_write(UART_BUF + i, bytes([b]))
    if uart_in:
        uc.mem_write(UART_TAIL, bytes([len(uart_in) & 0xFF]))
    for i, b in enumerate(ps2_in):
        uc.mem_write(PS2_BUF + i, bytes([b]))
    if ps2_in:
        uc.mem_write(PS2_TAIL, bytes([len(ps2_in) & 15]))
    uc.mem_write(BR_EXPECT, bytes([expect]))
    if bridge is None:
        bridge = H.BridgeModel()
    st = {'chan': 0, 'uart': bytearray(), 'done': False, 'vbr': False, 'ports': [], 'badports': set()}

    def h_in(uc, port, size, ud):
        st.setdefault('inports', {})[port] = st.get('inports', {}).get(port, 0) + 1
        if port == 0x82:
            return uc.mem_read(PORTC_ADDR, 1)[0]
        if port == 0x80:
            return uc.mem_read(PORTA_ADDR, 1)[0]
        return IN_DEFAULT                                # ports non emules (le vrai materiel peut renvoyer 0FFh...)

    def h_out(uc, port, size, value, ud):
        if port not in (0x20, 0x21, 0x80, 0x81, 0x82, 0x83, 0xFF):
            st['badports'].add(port)                     # ports que le materiel ne decode pas comme il faut (voir bios_patch_sector)
        if port == 0x81:
            st['chan'] = value & 0xFF
        elif port == 0x80:
            chan = st['chan']
            if chan == 0:
                st['uart'].append(value & 0xFF)
                if stop_after and st['uart'].endswith(stop_after):
                    uc.emu_stop()
            elif chan == 3:
                for b in bridge.feed(value & 0xFF):
                    if uc.mem_read(BR_EXPECT, 1)[0] != 1:
                        continue                        # l'ISR ne range que si une reponse est attendue
                    tail = uc.mem_read(BR_TAIL, 1)[0]
                    uc.mem_write(BR_BUF + tail, bytes([b]))
                    uc.mem_write(BR_TAIL, bytes([(tail + 1) & 0x3F]))
        elif port == 0xFF:
            st['done'] = True
            uc.emu_stop()

    st['hipages'] = {}                                  # pages de 4 Ko touchees AU-DELA des 128 Ko de RAM reelle (le materiel les replie sur 0-1FFFFh)

    def h_hi(uc, access, addr, size, value, ud):
        k = (addr >> 12, access == UC_MEM_WRITE)
        st.setdefault('hilog', []).append((uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP), addr, size, access == UC_MEM_WRITE, value if access == UC_MEM_WRITE else None))
        st['hipages'][k] = st['hipages'].get(k, 0) + 1

    uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, h_hi, None, 0x20000, 0x7FFFF)
    uc.hook_add(UC_HOOK_INSN, h_in, None, 1, 0, UC_X86_INS_IN)
    uc.hook_add(UC_HOOK_INSN, h_out, None, 1, 0, UC_X86_INS_OUT)
    def h_intr(uc, intno, ud):
        # Unicorn ne fait pas l'aiguillage du mode reel: on l'emule (IVT en 0000:0000)
        ss, sp = uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP)
        cs, ip, fl = uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP), uc.reg_read(UC_X86_REG_EFLAGS)
        for v in (fl & 0xFFFF, cs, ip):
            sp = (sp - 2) & 0xFFFF
            uc.mem_write(ss * 16 + sp, struct.pack('<H', v))
        off, seg = struct.unpack('<HH', bytes(uc.mem_read(intno * 4, 4)))
        uc.reg_write(UC_X86_REG_SP, sp)
        uc.reg_write(UC_X86_REG_EFLAGS, fl & ~0x300)           # IF = TF = 0
        uc.reg_write(UC_X86_REG_CS, seg)
        uc.reg_write(UC_X86_REG_IP, off)

    uc.hook_add(UC_HOOK_INTR, h_intr)
    if rom_ro:
        # comme le VRAI materiel: la ROM ne s'ecrit pas (les ecritures sont ignorees, sans erreur); on protege les bibliotheques (BIOS, pont...)
        # (l'interprete de cas et ses donnees, avant 7000h, restent ecrivables)
        uc.mem_protect(ROM + 0x7000, 0x40000 - 0x7000, UC_PROT_READ | UC_PROT_EXEC)
        st['romw'] = []

        def h_wprot(uc, access, addr, size, value, ud):
            st['romw'].append((addr, size, value))
            return True                                        # ignore l'ecriture et continue

        uc.hook_add(UC_HOOK_MEM_WRITE_PROT, h_wprot)
    st['starts'] = 0

    def h_code(uc, addr, size, ud):
        st['starts'] += 1                              # passages a l'adresse de depart (0C000h:0000h)

    uc.hook_add(UC_HOOK_CODE, h_code, None, ROM, ROM)
    uc.reg_write(UC_X86_REG_CS, 0xC000)
    try:
        uc.emu_start(ROM, 0, count=count)
    except UcError as e:
        st['err'] = str(e)
    st['res'] = [Res(bytes(uc.mem_read(RESULTS + 32 * i, 32))) for i in range(len(cases))]
    st['uc'] = uc
    st['bridge'] = bridge
    st['cs'] = uc.reg_read(UC_X86_REG_CS)
    st['ip'] = uc.reg_read(UC_X86_REG_IP)
    return st


def sector(n, salt=0):
    return bytes(((n * 7 + i * 3 + salt) & 0xFF) for i in range(512))


def frame_ok(r, c_sp=0xF000):
    """le programme retrouve sa pile, ses segments, BP: rien n'a bouge"""
    return r.ss == 0x3000 and r.sp == c_sp and r.ds == 0x2000 and r.bp == 0x1234


DL = 0x80

# ---------------------------------------------------------------- INT 11h / 12h / reset / extension
st = run([case(0x11), case(0x12), case(0x13, ax=0x0000, dx=DL), case(0x13, ax=0x4100, bx=0x55AA, dx=DL),
          case(0x13, ax=0x4100, bx=0x1111, dx=DL)])
r = st['res']
check('fin normale du banc', st['done'] and 'err' not in st, str(st.get('err')))
check('INT 11h: equipement 0220h (pas de disquette), pile intacte', r[0].ax == 0x0220 and frame_ok(r[0]), hex(r[0].ax))
check('INT 12h: 126 Ko', r[1].ax == 126 and frame_ok(r[1]), str(r[1].ax))
check('INT 13h AH=00h: reinitialisation OK (CF = 0)', r[2].ah == 0 and not r[2].cf and frame_ok(r[2]), hex(r[2].ax))
check('INT 13h AH=41h: acces etendu present (BX = AA55h, CX = 1, AH = 21h)',
      r[3].bx == 0xAA55 and r[3].cx == 1 and r[3].ah == 0x21 and not r[3].cf and frame_ok(r[3]), '%x %x %x' % (r[3].bx, r[3].cx, r[3].ax))
check('INT 13h AH=41h: BX incorrect -> erreur', r[4].cf and r[4].ah == 1)

# ---------------------------------------------------------------- INT 13h: parametres
st = run([case(0x13, ax=0x0800, dx=DL, cx=0x1111, bx=0x2222, si=0x3333, di=0x4444),
          case(0x13, ax=0x1500, dx=DL), case(0x13, ax=0x0800, dx=0x81), case(0x13, ax=0x0800, dx=0x00)])
r = st['res']
check('INT 13h AH=08h: 2 cylindres (dernier = 1), 255 tetes, 63 secteurs, 1 disque',
      not r[0].cf and r[0].ah == 0 and (r[0].cx >> 8) == 1 and (r[0].cx & 0xFF) == 63 and (r[0].dx >> 8) == 254 and (r[0].dx & 0xFF) == 1,
      'cx=%04x dx=%04x ax=%04x' % (r[0].cx, r[0].dx, r[0].ax))
check('INT 13h AH=08h: SI, DI, DS, ES, BP intacts, pile intacte',
      r[0].si == 0x3333 and r[0].di == 0x4444 and r[0].es == 0x5000 and frame_ok(r[0]))
check('INT 13h AH=15h: disque fixe (AH = 3), 16384 secteurs (CX:DX)', r[1].ah == 3 and r[1].cx == 0 and r[1].dx == 16384 and not r[1].cf,
      '%x %x %x' % (r[1].ax, r[1].cx, r[1].dx))
check('INT 13h: disque dur 81h inexistant -> AH = 01h, CF = 1', r[2].cf and r[2].ah == 1)
check('INT 13h: disquette (DL = 0) absente -> AH = 80h, CF = 1', r[3].cf and r[3].ah == 0x80)

# ---------------------------------------------------------------- INT 13h: lecture / ecriture CHS
bridge = H.BridgeModel()
for n in (0, 1, 16258, 16259, 62, 63, 100, 101):
    bridge.sectors[n] = sector(n)
def bufat(off, n=512):
    return bytes(st['uc'].mem_read(0x50000 + off, n))


st = run([
    case(0x13, ax=0x0201, bx=0x0100, cx=0x0001, dx=DL),                  # C0 H0 S1 -> LBA 0
    case(0x13, ax=0x0202, bx=0x1000, cx=0x0001, dx=0x0100 | DL),         # C0 H1 S1 -> LBA 63 (2 secteurs: 63 et 64)
    case(0x13, ax=0x0202, bx=0x3000, cx=0x0105, dx=0x0300 | DL),         # C1 H3 S5 -> LBA 16258
    case(0x13, ax=0x0201, bx=0x5000, cx=0x0000, dx=DL),                  # secteur 0: invalide
    case(0x13, ax=0x0201, bx=0x5000, cx=0x0101, dx=0xC800 | DL),         # C1 H200 S1: hors du disque
    case(0x13, ax=0x0100, dx=DL),                                        # etat = celui de l'erreur precedente
    case(0x13, ax=0x0100, dx=DL),                                        # puis 0
    case(0x13, ax=0x0401, bx=0x5000, cx=0x0001, dx=DL),                  # verification
], bridge=bridge)
r = st['res']
check('INT 13h AH=02h: secteur C0/H0/S1 (LBA 0) lu en ES:BX', not r[0].cf and r[0].ax == 0x0001 and bufat(0x100) == sector(0), hex(r[0].ax))
check('INT 13h AH=02h: registres preserves (BX, CX, DX, DS, BP, pile)',
      r[0].bx == 0x0100 and r[0].cx == 1 and r[0].dx == DL and r[0].es == 0x5000 and frame_ok(r[0]), '%x %x %x' % (r[0].bx, r[0].cx, r[0].dx))
check('INT 13h AH=02h: C0/H1/S1 = LBA 63 (2 secteurs: 63 puis 64, ce dernier vierge)',
      not r[1].cf and r[1].al == 2 and bufat(0x1000) == sector(63) and bufat(0x1200) == bytes(512), hex(r[1].ax))
check('INT 13h AH=02h: C1/H3/S5 = LBA (255+3)*63+4 = 16258 (et 16259)',
      not r[2].cf and r[2].al == 2 and bufat(0x3000) == sector(16258) and bufat(0x3200) == sector(16259), hex(r[2].ax))
check('INT 13h AH=02h: secteur 0 invalide -> AH = 04h, CF = 1', r[3].cf and r[3].ah == 4 and r[3].al == 0, hex(r[3].ax))
check('INT 13h AH=02h: hors du disque -> AH = 04h, CF = 1, 0 secteur', r[4].cf and r[4].ah == 4 and r[4].al == 0, hex(r[4].ax))
check('INT 13h AH=01h: dernier etat (04h) puis 00h', r[5].ah == 4 and r[6].ah == 0 and frame_ok(r[5]), '%x %x' % (r[5].ax, r[6].ax))
check('INT 13h AH=04h: verification OK', not r[7].cf and r[7].ax == 0x0001, hex(r[7].ax))

src = bytes((i * 5 + 1) & 0xFF for i in range(1024))
bridge = H.BridgeModel()
st = run([case(0x13, ax=0x0302, bx=0x0400, cx=0x0001, dx=DL), case(0x13, ax=0x0301, bx=0x0400, cx=0x0101, dx=DL)],
         bridge=bridge, mem={0x50000 + 0x400: src})
r = st['res']
check('INT 13h AH=03h: 2 secteurs ecrits (LBA 0 et 1)', not r[0].cf and r[0].al == 2 and bridge.sectors.get(0) == src[:512] and bridge.sectors.get(1) == src[512:],
      hex(r[0].ax))
check('INT 13h AH=03h: C1/H0/S1 = LBA 16065 (dans le disque)', not r[1].cf and bridge.sectors.get(16065) == src[:512], hex(r[1].ax))

# ---------------------------------------------------------------- INT 13h: acces etendu (DAP)
bridge = H.BridgeModel()
for n in (100, 101, 300):
    bridge.sectors[n] = sector(n, 9)
dap = struct.pack('<BBHHHQ', 16, 0, 2, 0x0000, 0x6000, 100)            # 2 secteurs a 6000:0000, LBA 100
dapw = struct.pack('<BBHHHQ', 16, 0, 1, 0x0000, 0x6000, 500)
dapbig = struct.pack('<BBHHHQ', 16, 0, 1, 0x0000, 0x6000, 20000)
daphi = struct.pack('<BBHHHQ', 16, 0, 1, 0x0000, 0x6000, 1 << 32)
st = run([
    case(0x13, ax=0x4200, dx=DL, si=0x0000, ds=0x2000),
    case(0x13, ax=0x4200, dx=DL, si=0x0080, ds=0x2000),
    case(0x13, ax=0x4200, dx=DL, si=0x00C0, ds=0x2000),
    case(0x13, ax=0x4800, dx=DL, si=0x0100, ds=0x2000),
], bridge=bridge, mem={0x20000: dap, 0x20080: dapbig, 0x200C0: daphi})
r = st['res']
check('INT 13h AH=42h: 2 secteurs a partir de LBA 100 lus en 6000:0000 (DS:SI = DAP)',
      not r[0].cf and r[0].ah == 0 and bytes(st['uc'].mem_read(0x60000, 1024)) == sector(100, 9) + sector(101, 9) and r[0].ds == 0x2000 and r[0].si == 0
      and frame_ok(r[0]), hex(r[0].ax))
st2 = run([case(0x13, ax=0x4300, dx=DL, si=0x0040, ds=0x2000)], bridge=bridge, mem={0x20040: dapw, 0x60000: sector(500, 1)})
check('INT 13h AH=43h: ecriture etendue du secteur 500', not st2['res'][0].cf and bridge.sectors.get(500) == sector(500, 1), hex(st2['res'][0].ax))
check('INT 13h AH=42h: LBA hors du disque -> AH = 04h', r[1].cf and r[1].ah == 4, hex(r[1].ax))
check('INT 13h AH=42h: LBA sur plus de 32 bits -> erreur', r[2].cf and r[2].ah == 4, hex(r[2].ax))
ep = bytes(st['uc'].mem_read(0x20100, 26))
size = struct.unpack('<H', ep[0:2])[0]
cyl = struct.unpack('<I', ep[4:8])[0]
heads = struct.unpack('<I', ep[8:12])[0]
spt = struct.unpack('<I', ep[12:16])[0]
nsec_ep = struct.unpack('<Q', ep[16:24])[0]
bps = struct.unpack('<H', ep[24:26])[0]
check('INT 13h AH=48h: taille 1Ah, 2 cylindres, 255 tetes, 63 secteurs, 16384 secteurs, 512 octets/secteur',
      not r[3].cf and size == 0x1A and cyl == 2 and heads == 255 and spt == 63 and nsec_ep == 16384 and bps == 512,
      '%s' % ((size, cyl, heads, spt, nsec_ep, bps),))

# ---------------------------------------------------------------- INT 13h: somme de controle des secteurs lus (octets alteres en route)
BADSUM = SEG + 0xFBF2
bridge = H.BridgeModel(bad_reads=1)
bridge.sectors[5] = sector(5, 7)
st = run([case(0x13, ax=0x0201, bx=0x0100, cx=0x0006, dx=DL)], bridge=bridge)      # LBA 5 = C0 H0 S6
r = st['res']
check('INT 13h: un octet altere pendant le transfert est DETECTE (somme de controle) et le secteur relu: donnees justes',
      not r[0].cf and r[0].ax == 1 and bufat(0x100) == sector(5, 7), hex(r[0].ax))
check('INT 13h: la relecture est signalee (\'!\' sur l\'UART, BIOS_BADSUM = 1)',
      bytes(st['uart']) == b'!' and st['uc'].mem_read(BADSUM, 1)[0] == 1, repr(bytes(st['uart'])))
bridge = H.BridgeModel(bad_reads=1)
for n in (10, 11, 12):
    bridge.sectors[n] = sector(n, 2)
st = run([case(0x13, ax=0x0203, bx=0x0100, cx=0x000B, dx=DL)], bridge=bridge)      # LBA 10..12, la 1re lecture est fausse
check('INT 13h: 3 secteurs dont la 1re lecture est alteree: tous justes', not st['res'][0].cf and st['res'][0].al == 3
      and bufat(0x100, 1536) == sector(10, 2) + sector(11, 2) + sector(12, 2), hex(st['res'][0].ax))
bridge = H.BridgeModel(bad_reads=3)
bridge.sectors[5] = sector(5, 7)
st = run([case(0x13, ax=0x0201, bx=0x0100, cx=0x0006, dx=DL)], bridge=bridge)
check('INT 13h: somme fausse 3 fois de suite: erreur AH = 20h (jamais de donnees fausses rendues), CF = 1',
      st['res'][0].cf and st['res'][0].ah == 0x20 and st['res'][0].al == 0 and bytes(st['uart']) == b'!!!', '%x %r' % (st['res'][0].ax, bytes(st['uart'])))
img = b''.join(sector(n, 3) for n in range(360))
bridge = H.BridgeModel(files={'DISK.IMG': img}, bad_reads=1)
st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x13, ax=0x0201, bx=0x0100, cx=0x0101, dx=0)], bridge=bridge, mem={0x20000: b'DISK.IMG\0'})
check('INT 13h: meme controle sur les secteurs de l\'IMAGE de disquette (relue, donnees justes)',
      not st['res'][1].cf and bufat(0x100) == sector(9, 3) and bytes(st['uart']) == b'!', hex(st['res'][1].ax))

# ---------------------------------------------------------------- INT 13h: pont muet, USB ON, pas de disque
st = run([case(0x13, ax=0x0201, bx=0x0100, cx=0x0001, dx=DL)], bridge=H.BridgeModel(mute=True), count=900_000_000)
check('INT 13h: pont muet -> AH = 80h (delai), CF = 1, pile intacte', st['done'] and st['res'][0].cf and st['res'][0].ah == 0x80 and frame_ok(st['res'][0]),
      hex(st['res'][0].ax))
b = H.BridgeModel()
b.usb = True
st = run([case(0x13, ax=0x0201, bx=0x0100, cx=0x0001, dx=DL)], bridge=b)
check('INT 13h: USB ON (le PC a le disque) -> AH = AAh (unite non prete)', st['res'][0].cf and st['res'][0].ah == 0xAA, hex(st['res'][0].ax))
st = run([case(0x13, ax=0x0800, dx=DL)], bridge=H.BridgeModel(ready=False))
check('INT 13h AH=08h: pas de disque -> AH = AAh', st['res'][0].cf and st['res'][0].ah == 0xAA, hex(st['res'][0].ax))

# ---------------------------------------------------------------- INT 1Ah: horloge
bridge = H.BridgeModel()                       # 2026-09-20 12:34:56.78
total_cs = ((12 * 3600 + 34 * 60 + 56) * 100 + 78)
ticks = total_cs * 91 // 500
st = run([case(0x1A, ax=0x0000), case(0x1A, ax=0x0200), case(0x1A, ax=0x0400),
          case(0x1A, ax=0x0300, cx=0x2359, dx=0x3000), case(0x1A, ax=0x0500, cx=0x2031, dx=0x1225),
          case(0x1A, ax=0x0900)], bridge=bridge)
r = st['res']
check('INT 1Ah AH=00h: ticks depuis minuit (18,2 par seconde), AL = 0', not r[0].cf and r[0].al == 0 and (r[0].cx << 16 | r[0].dx) == ticks and frame_ok(r[0]),
      '%x:%x vs %x' % (r[0].cx, r[0].dx, ticks))
check('INT 1Ah AH=02h: heure BCD 12:34:56', not r[1].cf and r[1].cx == 0x1234 and (r[1].dx >> 8) == 0x56 and (r[1].dx & 0xFF) == 0, '%x %x' % (r[1].cx, r[1].dx))
check('INT 1Ah AH=04h: date BCD 20 26-09-20', not r[2].cf and r[2].cx == 0x2026 and r[2].dx == 0x0920, '%x %x' % (r[2].cx, r[2].dx))
check('INT 1Ah AH=03h (23:59:30) puis AH=05h (2031-12-25): la RTC du pont est reglee, l\'heure conservee par le reglage de la date',
      not r[3].cf and not r[4].cf and list(bridge.clock[:7]) == [0xEF, 0x07, 12, 25, 23, 59, 30], str(list(bridge.clock)))
check('INT 1Ah: fonction inconnue -> CF = 1', r[5].cf)
st = run([case(0x1A, ax=0x0200)], bridge=H.BridgeModel(mute=True), count=900_000_000)
check('INT 1Ah: pont muet -> CF = 1', st['res'][0].cf and frame_ok(st['res'][0]))

# ---------------------------------------------------------------- INT 16h: clavier (terminal UART)
st = run([case(0x16, ax=0x0100)], uart_in=b'')
check('INT 16h AH=01h: rien -> ZF = 1', st['res'][0].zf and frame_ok(st['res'][0]))
st = run([case(0x16, ax=0x0100), case(0x16, ax=0x0100), case(0x16, ax=0x0000), case(0x16, ax=0x0100)], uart_in=b'a')
r = st['res']
check('INT 16h AH=01h: touche presente (ZF = 0, AX = 1E61h) et NON consommee', not r[0].zf and r[0].ax == 0x1E61 and not r[1].zf and r[1].ax == 0x1E61, '%x %x' % (r[0].ax, r[1].ax))
check('INT 16h AH=00h: la touche est lue puis consommee (AH=01h: ZF = 1)', r[2].ax == 0x1E61 and r[3].zf, '%x %s' % (r[2].ax, r[3].zf))
st = run([case(0x16, ax=0x0000)] * 6 + [case(0x16, ax=0x0200)], uart_in=b'\x1b[A\x1b[D\x7f\rA\x03')
r = st['res']
check('INT 16h: fleche haut (ESC [ A) = 4800h, gauche = 4B00h', r[0].ax == 0x4800 and r[1].ax == 0x4B00, '%x %x' % (r[0].ax, r[1].ax))
check('INT 16h: DEL -> retour arriere 0E08h, Entree 1C0Dh, A = 1E41h', r[2].ax == 0x0E08 and r[3].ax == 0x1C0D and r[4].ax == 0x1E41, '%x %x %x' % (r[2].ax, r[3].ax, r[4].ax))
check('INT 16h: Ctrl-C = 2E03h; indicateurs (AH=02h) = 0', r[5].ax == 0x2E03 and r[6].al == 0, '%x %x' % (r[5].ax, r[6].ax))
check('INT 16h: ESC seul (ESC puis rien) = 011Bh', run([case(0x16, ax=0x0000)], uart_in=b'\x1b')['res'][0].ax == 0x011B)
check('INT 16h AH=10h (clavier etendu) = AH=00h', run([case(0x16, ax=0x1000)], uart_in=b'z')['res'][0].ax == 0x2C7A)

# ---------------------------------------------------------------- INT 10h standard, INT 15h
st = run([case(0x10, ax=0x0E41), case(0x10, ax=0x0F00), case(0x10, ax=0x0200, bx=0x0000, dx=0x0509), case(0x10, ax=0x0600, cx=0, dx=0x184F),
          case(0x10, ax=0x0A2A, cx=3), case(0x15, ax=0x8800), case(0x15, ax=0x8600)])
r = st['res']
out = bytes(st['uart'])
check('INT 10h AH=0Eh: teletype -> UART', out.startswith(b'A'), repr(out))
check('INT 10h AH=0Fh: 80 colonnes, mode 3, page 0', r[1].ax == 0x5003 and (r[1].bx >> 8) == 0, hex(r[1].ax))
check('INT 10h AH=02h: positionnement ANSI ESC[6;10H', b'\x1b[6;10H' in out, repr(out))
check('INT 10h AH=06h AL=0: efface l\'ecran (ESC[2J ESC[H)', b'\x1b[2J\x1b[H' in out, repr(out))
check('INT 10h AH=0Ah: caractere repete 3 fois', out.endswith(b'***'), repr(out))
check('INT 15h AH=88h: pas de memoire etendue (AX = 0, CF = 0)', r[5].ax == 0 and not r[5].cf)
check('INT 15h: fonction non geree -> CF = 1, AH = 86h', r[6].cf and r[6].ah == 0x86)
check('les registres du programme survivent a INT 10h (pile, DS, BP)', all(frame_ok(x) for x in r[:5]))

# ---------------------------------------------------------------- ISR IRQ1: independante de la pile et de DS
st = run([case(0x09, portc=0xA1, porta=0x41), case(0x09, portc=0xA0, porta=0x1C), case(0x09, portc=0xA2, porta=0x77),
          case(0x09, portc=0xA2, porta=0x78), case(0x09, portc=0x80, porta=0x99)], expect=1)
r = st['res']
uc = st['uc']
check('ISR: octet UART (PC0 = 1) range dans le tampon UART', bytes(uc.mem_read(UART_BUF, 1)) == b'A' and uc.mem_read(UART_TAIL, 1)[0] == 1, '')
check('ISR: scan code (PC0 = 0) range dans le tampon PS/2', bytes(uc.mem_read(PS2_BUF, 1)) == bytes([0x1C]) and uc.mem_read(PS2_TAIL, 1)[0] == 1, '')
check('ISR: reponse du pont (PC1 = 1, BRIDGE_EXPECT = 1) rangee dans le tampon du pont',
      bytes(uc.mem_read(BR_BUF, 2)) == bytes([0x77, 0x78]) and uc.mem_read(BR_TAIL, 1)[0] == 2, repr(bytes(uc.mem_read(BR_BUF, 2))))
check('ISR: interruption parasite (IBF = 0): rien ecrit', uc.mem_read(UART_TAIL, 1)[0] == 1 and uc.mem_read(PS2_TAIL, 1)[0] == 1, '')
check('ISR: pile et DS du programme interrompu INTACTS (SS = 3000h, DS = 2000h) pour les 5 cas',
      all(x.ss == 0x3000 and x.sp == 0xF000 and x.ds == 0x2000 and x.bp == 0x1234 for x in r), str([(hex(x.ss), hex(x.ds)) for x in r]))
st = run([case(0x09, portc=0xA2, porta=0x55)], expect=0)
check('ISR: PC1 = 1 sans reponse attendue (BRIDGE_EXPECT = 0) = scan code, pas une reponse',
      st['uc'].mem_read(BR_TAIL, 1)[0] == 0 and st['uc'].mem_read(PS2_TAIL, 1)[0] == 1)

# ---------------------------------------------------------------- interruptions non implementees: le message donne le NUMERO
st = run([case(0x60, ax=0x1234, bx=0x5678, cx=0x9ABC, dx=0xDEF0), case(0x18, ax=0x0400), case(0xFE, ax=0xFE00)])
r = st['res']
out = bytes(st['uart'])
check('INT non implementee: le message donne le numero, la fonction (AH) et l\'appelant (INT 60h, AH=12h)',
      b'INT 60h, AH=12h, appelee depuis C000:' in out, repr(out[:120]))
check('INT non implementee: INT 18h (BASIC en ROM du PC IBM) et INT FEh sont nommes aussi',
      b'INT 18h, AH=04h' in out and b'INT FEh, AH=FEh' in out, repr(out))
check('INT non implementee: les 8 octets de code qui precedent l\'appelant sont affiches (instruction INT n)', b', code ' in out and b'CD 60' in out, repr(out[:200]))
check('INT non implementee: tous les registres, la pile et les segments de l\'appelant intacts',
      r[0].ax == 0x1234 and r[0].bx == 0x5678 and r[0].cx == 0x9ABC and r[0].dx == 0xDEF0 and frame_ok(r[0]) and r[0].es == 0x5000,
      '%x %x %x %x' % (r[0].ax, r[0].bx, r[0].cx, r[0].dx))

# ---------------------------------------------------------------- redemarrage a chaud (Ctrl-\ = retour au menu)
st = run([case(0x09, portc=0xA1, porta=0x41), case(0x09, portc=0xA1, porta=0x18)])
check('ISR: octets UART ordinaires (A, Ctrl-X) rangés, pas de redemarrage', st['starts'] == 1 and st['uc'].mem_read(UART_TAIL, 1)[0] == 2, str(st['starts']))
st = run([case(0x09, portc=0xA1, porta=0x1C)], count=6000)
check('ISR: Ctrl-\\ (1Ch) reçu par l\'UART = redémarrage a chaud (saut a 0C000h:0000h), l\'octet n\'est pas range',
      st['starts'] >= 2 and st['uc'].mem_read(UART_TAIL, 1)[0] == 0, '%d %d' % (st['starts'], st['uc'].mem_read(UART_TAIL, 1)[0]))
st = run([case(0x09, portc=0xA0, porta=0x1C)])
check('ISR: 1Ch venant du clavier PS/2 (PC0 = 0) est un scan code ordinaire, pas un redemarrage', st['starts'] == 1 and st['uc'].mem_read(PS2_TAIL, 1)[0] == 1)

# ---------------------------------------------------------------- INT 19h: amorcage
def mbr(active=True, ptype=0x06, lba=63, sig=True):
    b = bytearray(512)
    e = bytearray(16)
    e[0] = 0x80 if active else 0x00
    e[4] = ptype
    e[8:12] = struct.pack('<I', lba)
    e[12:16] = struct.pack('<I', 16000)
    b[0x1BE:0x1CE] = e
    if sig:
        b[510:512] = b'\x55\xAA'
    return bytes(b)


def vbr(sig=True):
    b = bytearray(512)
    code = bytes([0x88, 0x16, 0x00, 0x05,          # mov [0500h], dl
                  0x89, 0x26, 0x02, 0x05,          # mov [0502h], sp
                  0x8C, 0x16, 0x04, 0x05,          # mov [0504h], ss
                  0xB0, 0x01, 0xE6, 0xFF, 0xF4])   # mov al,1 / out 0FFh,al / hlt
    b[:len(code)] = code
    if sig:
        b[510:512] = b'\x55\xAA'
    return bytes(b)


def boot(bridge):
    st = run([case(0x19, dx=0x0000)], bridge=bridge)
    uc = st['uc']
    return st, bytes(uc.mem_read(0x500, 6))


bridge = H.BridgeModel()
bridge.sectors[0] = mbr()
bridge.sectors[63] = vbr()
st, mem = boot(bridge)
dl, sp, ss = mem[0], mem[2] | mem[3] << 8, mem[4] | mem[5] << 8
check('INT 19h: la partition active est amorcee (le VBR s\'execute a 0000:7C00)', st['done'] and dl == 0x80 and ss == 0 and sp == 0x7C00,
      '%x %x %x %s' % (dl, sp, ss, st.get('err')))
check('INT 19h: message d\'amorcage sur l\'UART', b'Amorce: disque flash' in bytes(st['uart']), repr(bytes(st['uart'])))
check('INT 19h: le VBR est bien charge (0000:7C00 = code, 55AA a la fin)', bytes(st['uc'].mem_read(0x7C00, 4)) == vbr()[:4] and bytes(st['uc'].mem_read(0x7DFE, 2)) == b'\x55\xAA')

bridge = H.BridgeModel()
bridge.sectors[0] = mbr(active=False, ptype=0x0E, lba=63)
bridge.sectors[63] = vbr()
st, mem = boot(bridge)
check('INT 19h: sans partition active, la premiere partition FAT (type 0Eh) est amorcee', st['done'] and mem[0] == 0x80, str(st.get('err')))

bridge = H.BridgeModel()
bridge.sectors[0] = mbr(sig=False)
st = run([case(0x19)], bridge=bridge)
check('INT 19h: MBR sans signature 55AA -> retour CF = 1 + message', st['res'][0].cf and b'signature de demarrage absente' in bytes(st['uart']) and frame_ok(st['res'][0]),
      repr(bytes(st['uart'])))
bridge = H.BridgeModel()
bridge.sectors[0] = mbr()
bridge.sectors[63] = vbr(sig=False)
st = run([case(0x19)], bridge=bridge)
check('INT 19h: VBR sans signature -> retour CF = 1', st['res'][0].cf and b'signature de demarrage absente' in bytes(st['uart']))
st = run([case(0x19)], bridge=H.BridgeModel(mute=True), count=900_000_000)
check('INT 19h: pont muet -> retour CF = 1 + message', st['res'][0].cf and b'le pont ne repond pas' in bytes(st['uart']))
bridge = H.BridgeModel()
sup = bytearray(512)
body = vbr()[:17]
sup[0:2] = b'\xEB\x00'                     # jmp short +0 puis le code
sup[2:2 + len(body)] = body
sup[510:512] = b'\x55\xAA'
bridge.sectors[0] = bytes(sup)
st, mem = boot(bridge)
check('INT 19h: secteur 0 sans table de partitions mais avec un saut (EB) = amorce lui-meme', st['done'] and mem[0] == 0x80, str(st.get('err')))

# --- INT 1Ah AH=00h: indicateur de passage de minuit (le DOS incremente alors la date)
LASTTICK = SEG + 0xFCEC
st = run([case(0x1A, ax=0x0000), case(0x1A, ax=0x0000)], mem={LASTTICK: bytes([0x00, 0x00, 0xFF, 0x00])})
r = st['res']
check('INT 1Ah AH=00h: compteur plus petit que le precedent = minuit passe (AL = 1), puis AL = 0', r[0].al == 1 and r[1].al == 0, '%d %d' % (r[0].al, r[1].al))

# ---------------------------------------------------------------- image de disquette (lecteur A:) montee depuis un fichier
img180 = b''.join(sector(n, 3) for n in range(360))                       # 180 Ko: 40 cylindres, 1 tete, 9 secteurs
NAME = b'DISK.IMG\0'
bridge = H.BridgeModel(files={'DISK.IMG': img180, 'BAD.IMG': bytes(1000)})
wsrc = bytes((i * 11 + 5) & 0xFF for i in range(512))
st = run([
    case(0x11),                                                           # 0: equipement sans image
    case(0x13, ax=0x0201, bx=0x0100, cx=0x0001, dx=0),                    # 1: A: absente -> 80h
    case(0x13, ax=0xF000, si=0x0000, ds=0x2000),                          # 2: monter DISK.IMG
    case(0x11),                                                           # 3: 1 disquette
    case(0x13, ax=0x0800, dx=0),                                          # 4: parametres de A:
    case(0x13, ax=0x0201, bx=0x0100, cx=0x0001, dx=0),                    # 5: C0 H0 S1 -> LBA 0
    case(0x13, ax=0x0201, bx=0x1000, cx=0x0101, dx=0),                    # 6: C1 H0 S1 -> LBA 9
    case(0x13, ax=0x0201, bx=0x2000, cx=0x0001, dx=0x0100),               # 7: tete 1: disquette a une face -> erreur
    case(0x13, ax=0x0201, bx=0x2000, cx=0x2801, dx=0),                    # 8: cylindre 40: hors de l'image
    case(0x13, ax=0x0201, bx=0x2000, cx=0x000A, dx=0),                    # 9: secteur 10 (> 9)
    case(0x13, ax=0x0301, bx=0x3000, cx=0x0203, dx=0),                    # 10: ecriture C2 H0 S3 -> LBA 20
    case(0x13, ax=0x1500, dx=0),                                          # 11: type: disquette
    case(0x13, ax=0x4100, bx=0x55AA, dx=0),                               # 12: acces etendu: disque dur seulement
    case(0x13, ax=0x0201, bx=0x4000, cx=0x0001, dx=DL),                   # 13: le disque dur (pas d'image) reste separe
    case(0x13, ax=0xF100),                                                # 14: demonter
    case(0x11),                                                           # 15
    case(0x13, ax=0x0201, bx=0x0100, cx=0x0001, dx=0),                    # 16: A: de nouveau absente
], bridge=bridge, mem={0x20000: NAME, 0x50000 + 0x3000: wsrc})
r = st['res']
check('INT 11h: sans image, pas de disquette (0220h)', r[0].ax == 0x0220 and frame_ok(r[0]), hex(r[0].ax))
check('INT 13h: A: sans image montee -> AH = 80h, CF = 1', r[1].cf and r[1].ah == 0x80)
check('INT 13h AH=F0h: image montee (AH = 0), taille 184320 = CX:DX 0002:D000h, pile intacte',
      not r[2].cf and r[2].ah == 0 and r[2].cx == 2 and r[2].dx == 0xD000 and frame_ok(r[2]), '%x %x %x' % (r[2].ax, r[2].cx, r[2].dx))
check('INT 11h: une image montee = 1 lecteur de disquette (0221h)', r[3].ax == 0x0221, hex(r[3].ax))
check('INT 13h AH=08h DL=0: 40 cylindres, 1 tete, 9 secteurs, 1 lecteur, type 1',
      not r[4].cf and (r[4].cx >> 8) == 39 and (r[4].cx & 0xFF) == 9 and (r[4].dx >> 8) == 0 and (r[4].dx & 0xFF) == 1 and (r[4].bx & 0xFF) == 1,
      'cx=%04x dx=%04x bx=%04x' % (r[4].cx, r[4].dx, r[4].bx))
check('INT 13h AH=08h DL=0: ES:DI = table des parametres de disquette (11 octets en ROM)', r[4].es == 0xC000 and r[4].di != 0, '%x:%x' % (r[4].es, r[4].di))
check('INT 13h AH=02h DL=0: C0/H0/S1 = secteur 0 de l\'image lu en ES:BX', not r[5].cf and r[5].ax == 1 and bufat(0x100) == sector(0, 3), hex(r[5].ax))
check('INT 13h AH=02h DL=0: C1/H0/S1 = LBA 9 (9 secteurs par piste, 1 tete)', not r[6].cf and bufat(0x1000) == sector(9, 3), hex(r[6].ax))
check('INT 13h AH=02h DL=0: tete 1 sur une disquette a une face -> AH = 04h', r[7].cf and r[7].ah == 4, hex(r[7].ax))
check('INT 13h AH=02h DL=0: cylindre 40 (hors image) -> AH = 04h', r[8].cf and r[8].ah == 4, hex(r[8].ax))
check('INT 13h AH=02h DL=0: secteur 10 (> 9) -> AH = 04h', r[9].cf and r[9].ah == 4, hex(r[9].ax))
check('INT 13h AH=03h DL=0: ecriture C2/H0/S3 = LBA 20 dans le FICHIER image',
      not r[10].cf and r[10].al == 1 and bytes(bridge.files['DISK.IMG'][20 * 512:21 * 512]) == wsrc and bytes(bridge.files['DISK.IMG'][19 * 512:20 * 512]) == sector(19, 3),
      hex(r[10].ax))
check('INT 13h AH=15h DL=0: disquette (AH = 1)', r[11].ah == 1 and not r[11].cf)
check('INT 13h AH=41h DL=0: l\'acces etendu est pour le disque dur seulement', r[12].cf and r[12].ah == 1, hex(r[12].ax))
check('INT 13h: le disque dur (DL = 80h) reste distinct de la disquette', not r[13].cf and bufat(0x4000) == bytes(512), hex(r[13].ax))
check('INT 13h AH=F1h: image demontee; INT 11h = 0220h; A: de nouveau absente',
      not r[14].cf and r[15].ax == 0x0220 and r[16].cf and r[16].ah == 0x80 and bridge.img is None, '%x %x %x' % (r[14].ax, r[15].ax, r[16].ax))

bridge = H.BridgeModel(files={'DISK.IMG': img180, 'BAD.IMG': bytes(1000)})
st = run([case(0x13, ax=0xF000, si=0x0100, ds=0x2000), case(0x13, ax=0xF000, si=0x0200, ds=0x2000), case(0x11),
          case(0x13, ax=0xF000, si=0x0300, ds=0x2000)],
         bridge=bridge, mem={0x20100: b'NOPE.IMG\0', 0x20200: b'BAD.IMG\0', 0x20300: b'A/B.IMG\0'})
r = st['res']
check('INT 13h AH=F0h: image introuvable -> AH = E2h, CF = 1', r[0].cf and r[0].ah == 0xE2, hex(r[0].ax))
check('INT 13h AH=F0h: taille non reconnue (1000 octets) -> AH = EFh, non montee (INT 11h = 0220h)',
      r[1].cf and r[1].ah == 0xEF and r[2].ax == 0x0220 and bridge.img is None, '%x %x' % (r[1].ax, r[2].ax))
check('INT 13h AH=F0h: nom invalide -> AH = E5h', r[3].cf and r[3].ah == 0xE5, hex(r[3].ax))
b = H.BridgeModel(files={'DISK.IMG': img180})
b.usb = True
st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000)], bridge=b, mem={0x20000: NAME})
check('INT 13h AH=F0h: USB ON (le PC a le disque) -> AH = E1h', st['res'][0].cf and st['res'][0].ah == 0xE1, hex(st['res'][0].ax))
st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000)], bridge=H.BridgeModel(mute=True), mem={0x20000: NAME}, count=900_000_000)
check('INT 13h AH=F0h: pont muet -> AH = 80h', st['res'][0].cf and st['res'][0].ah == 0x80)

# --- amorcage de la disquette A: (secteur 0 de l'image, sans signature 55AA)
boot = bytearray(img180)
code = vbr()[:17]
boot[0:len(code)] = code
boot[510:512] = b'\x00\x00'
bridge = H.BridgeModel(files={'DISK.IMG': bytes(boot)})
st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x19)], bridge=bridge, mem={0x20000: NAME})
mem = bytes(st['uc'].mem_read(0x500, 6))
check('INT 19h: image montee -> amorce la DISQUETTE A: (DL = 0, 0000:7C00, sans signature)', st['done'] and mem[0] == 0 and mem[2] | mem[3] << 8 == 0x7C00 and mem[4] | mem[5] << 8 == 0
      and b'image disquette (A:)' in bytes(st['uart']), '%s %s' % (mem.hex(), st.get('err')))

# --- OUT parasites (ports 2F2h-2F7h de MS-DOS 3.30, qui reprogrammeraient le 8255): neutralises (NOP) dans les secteurs LUS
blk1 = bytes.fromhex('50 53 52 06 B0 FF BA F2 02 EE 42 EE 42 EE 42 EE 42 EE 42 EE B8 00 F0 8E C0')
blk2 = bytes.fromhex('B0 FF BA F2 06 EE 42 EE 42 EE 42 42 EE 42 EE 07 5A')
ok1 = blk1.replace(b'\xEE', b'\x90')
ok2 = blk2.replace(b'\xEE', b'\x90')
decoy = bytes.fromhex('BA 80 00 EE 42 EE BA F2 02 90 EE BA F2 05 EE')            # ports 80h (legitime), OUT sans motif, port 2F5h: intacts
sec = bytearray(sector(9, 5))
sec[100:100 + len(blk1)] = blk1
sec[200:200 + len(blk2)] = blk2
sec[300:300 + len(decoy)] = decoy
sec[512 - 12:512] = bytes.fromhex('BA F2 02 EE 42 EE 42 EE 42 EE 42 EE')[:12]     # motif a cheval sur la fin du secteur: on n'y touche pas
want = bytearray(sec)
want[100:100 + len(blk1)] = ok1
want[200:200 + len(blk2)] = ok2
bridge = H.BridgeModel()
bridge.sectors[9] = bytes(sec)
st = run([case(0x13, ax=0x0201, bx=0x0100, cx=0x000A, dx=DL)], bridge=bridge)     # LBA 9 = C0 H0 S10
got = bufat(0x100)
check('INT 13h lecture: les OUT (EEh) des suites 2F2h et 2F6h de MS-DOS 3.30 deviennent des NOP (90h), rien d\'autre ne change',
      not st['res'][0].cf and got == bytes(want), [i for i in range(512) if got[i] != want[i]][:10])
check('INT 13h lecture: 6 + 5 OUT neutralises, signales par \'+\' (BIOS_NPATCH), les leurres et le motif tronque intacts',
      bytes(st['uart']) == b'+' * 11 and st['uc'].mem_read(SEG + 0xFBF4, 1)[0] == 11, '%r %d' % (bytes(st['uart']), st['uc'].mem_read(SEG + 0xFBF4, 1)[0]))

# --- interruption non implementee appelee depuis la RAM d'un programme (DS/CS != segment de la ROM): les octets de code s'affichent
boot = bytearray(img180)
boot[0:9] = bytes([0xEB, 0x00, 0xB4, 0xA0, 0xCD, 0x60, 0xF4, 0xEB, 0xFE])          # jmp $+2 / mov ah,A0h / int 60h / hlt / jmp $
boot[510:512] = b'\x00\x00'
bridge = H.BridgeModel(files={'DISK.IMG': bytes(boot)})
st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x19)], bridge=bridge, mem={0x20000: NAME}, stop_after=b'***\x1b[0m\r\n')
out = bytes(st['uart'])
check('INT non implementee appelee depuis la RAM (0000:7C06): message complet avec les 8 octets de code (EB 00 B4 A0 CD 60)',
      b'INT 60h, AH=A0h, appelee depuis 0000:7C06, code ' in out and b'EB 00 B4 A0 CD 60 ' in out, repr(out[-120:]))

# --- MS-DOS 3.30 (image de la disquette d'origine): amorcage sans OUT sur des ports que le materiel decode mal
dos33_img = os.path.join(ROOT, '..', 'PC-DOS', 'Dos33-d1.IMG')
if os.path.exists(dos33_img):
    bridge = H.BridgeModel(files={'DOS33.IMG': open(dos33_img, 'rb').read()})
    st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x19)], bridge=bridge, mem={0x20000: b'DOS33.IMG'+bytes(1)},
             uart_in=b'09-20-2026\r\rver'+bytes([13]), count=700_000_000, stop_after=b'MS-DOS(R)  Version 3')
    out = bytes(st['uart'])
    check('MS-DOS 3.30: amorcage jusqu a la commande VER (Version 3.xx), sans interruption non implementee',
          b'MS-DOS(R)  Version 3' in out and b'non implementee' not in out, repr(out[-160:]))
    check('MS-DOS 3.30: aucun OUT sur un port hors 20h/21h/80h-83h (les OUT de IO.SYS vers 2F2h-2F7h sont neutralises)',
          not st['badports'] and st['uc'].mem_read(SEG + 0xFBF4, 1)[0] > 0, sorted(hex(x) for x in st['badports']))

# --- PC-DOS 2.1 (image de la disquette d'origine): amorcage, invite, commandes, jusqu'au repertoire. Plus
# --- d'injection automatique de la date/heure (retiree: posait probleme a certains DOS - voir Directives.md):
# --- la date/heure est desormais TAPEE comme un utilisateur le ferait (09-20-2026 puis Entree pour l'heure
# --- proposee par defaut).
dos_img = os.path.join(ROOT, '..', 'PC-DOS', 'pcdos2_1.img')
if os.path.exists(dos_img):
    dos = open(dos_img, 'rb').read()
    bridge = H.BridgeModel(files={'PCDOS2_1.IMG': dos})
    st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x19)], bridge=bridge, mem={0x20000: b'PCDOS2_1.IMG\0'},
             uart_in=b'09-20-2026\r\rver\rdir\r', count=600_000_000, stop_after=b'CHKDSK   COM')
    out = bytes(st['uart'])
    check('PC-DOS 2.1: la disquette s\'amorce (IBMBIO/IBMDOS chargees par INT 13h), date puis heure demandees',
          b'Enter new date:' in out and b'Enter new time:' in out, repr(out[:200]))
    check('PC-DOS 2.1: la date tapee (09-20-2026) et l\'heure par defaut (Entree) sont acceptees: 1re commande = ver',
          b'A>ver' in out and out.count(b'A>') >= 2 and b'Enter new date:' in out, repr(out[:300]))
    check('PC-DOS 2.1: bandeau "The IBM Personal Computer DOS Version 2.10" et invite A>', b'Version 2.10 (C)Copyright IBM Corp' in out and b'\r\nA>' in out, repr(out[-200:]))
    check('PC-DOS 2.1: VER puis DIR fonctionnent (COMMAND COM, FORMAT COM, CHKDSK COM dans le repertoire)',
          b'A>ver' in out and b'Version  2.10' in out and b'COMMAND  COM    17792' in out and b'CHKDSK   COM' in out, repr(out[-300:]))
    bridge = H.BridgeModel(files={'PCDOS2_1.IMG': dos})
    st = run([case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x19)], bridge=bridge, mem={0x20000: b'PCDOS2_1.IMG\0'},
             uart_in=b'09-20-2026\r\rdate\r', count=600_000_000, stop_after=b'Sun  9-20-2026')
    out = bytes(st['uart'])
    check('PC-DOS 2.1: la commande DATE affiche la date TAPEE (Sun  9-20-2026)', b'Current date is Sun  9-20-2026' in out, repr(out[-250:]))
else:
    print('(image PC-DOS absente: test d\'amorcage non execute)')

print('\n%d verification(s), %d echec(s)' % (total, fails))
sys.exit(1 if fails else 0)
