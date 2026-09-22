#!/usr/bin/env python3
"""Harnais de test de lib/basic.asm sous emulateur (Unicorn); voir basic_test.py.

Assemble tests/basic_test.asm (uart_* remplaces par des ports fictifs), l'execute
en mode reel 16 bits et verifie les sorties BASIC, le retour au menu (registres,
SP, DS restaures) et qu'AUCUNE ecriture n'a lieu hors des zones prevues.

Usage: importe par tests/basic_test.py (depuis la racine de Solution-01).
Prerequis: pip install unicorn ; nasm dans le PATH.
"""
import os, re, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, 'build', 'basic_test.bin')
LST = os.path.join(ROOT, 'build', 'basic_test.lst')
BIN_REAL = os.path.join(ROOT, 'build', 'basic_test_real.bin')
LST_REAL = os.path.join(ROOT, 'build', 'basic_test_real.lst')

# adresses physiques du tampon de reception UART du firmware (hardware.inc)
UART_HEAD = 0x10000 + 0xFC3C
UART_TAIL = 0x10000 + 0xFC3D
UART_BUF = 0x10000 + 0xFD00


def build():
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    subprocess.run(['nasm', '-f', 'bin', '-dBASIC_TEST', 'tests/basic_test.asm', '-o', BIN, '-l', LST],
                   cwd=ROOT, check=True)
    subprocess.run(['nasm', '-f', 'bin', '-dBASIC_TEST', '-dBASIC_REAL', 'tests/basic_test.asm',
                    '-o', BIN_REAL, '-l', LST_REAL], cwd=ROOT, check=True)


def labels(real=False):
    """tous les libelles (adresses relatives a CS) depuis le listing nasm"""
    out = []
    pend = []
    for line in open(LST_REAL if real else LST, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*\d+\s+(?:<\d>\s+)?([A-Za-z_.][\w.$]*):\s*(?:;.*)?$',
                     line.replace('<1>', '').rstrip())
        m2 = re.match(r'\s*\d+\s+([0-9A-F]{8})\s+', line)
        if m2:
            for n in pend:
                out.append((int(m2.group(1), 16), n))
            pend = []
        elif m:
            pend.append(m.group(1))
    out.sort()
    return out


def where(addr, lab):
    best = None
    for a, n in lab:
        if a <= addr:
            best = (a, n)
        else:
            break
    return '%04X %s+%d' % (addr, best[1], addr - best[0]) if best else '%04X' % addr


def symbols(real=False):
    """offsets des variables 'saved_*' du banc d'essai (depuis le listing nasm)"""
    syms = {}
    for line in open(LST_REAL if real else LST, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*\d+\s+([0-9A-F]{8})\s+\S+\s+(saved_\w+)\s+dw', line)
        if m:
            syms[m.group(2)] = int(m.group(1), 16)
    return syms


# zones ecrites autorisees (adresses PHYSIQUES)
ALLOWED = [
    (0x10100, 0x1F420),      # espace de travail du BASIC + pile (1000:0100-F41F)
    (0x1F420, 0x1F600),      # zone libre pour l'utilisateur (POKE/DSKREAD de 512 octets a 1000:F400+)
    (0x1FF00, 0x20000),      # pile de l'appelant (SS=1000h, SP=0 -> FFxx)
    (0xC0000, 0xC0100),      # variables du banc d'essai (saved_*), "ROM" mappee RW
    (0x1FC29, 0x1FC2A),      # ARD_TX_STATE_OFF (arduino_send)
    (0x1FC3C, 0x1FC3D),      # UART_RX_HEAD_OFF (uart_rx_byte), mode reel
    (0x1FC52, 0x1FC53),      # BRIDGE_RX_HEAD_OFF (bridge_rx_get_t)
    (0x1FC64, 0x1FC65),      # BRIDGE_EXPECT_OFF (rtc_get / fs_*)
]

# tampon des reponses du pont (hardware.inc): 64 octets, l'ISR ne range que si EXPECT = 1
BR_HEAD = 0x10000 + 0xFC52
BR_TAIL = 0x10000 + 0xFC53
BR_BUF = 0x10000 + 0xFC70
BR_EXPECT = 0x10000 + 0xFC64


class BridgeModel:
    """Le PONT (STM32) vu du 8088: automate des commandes du canal 3 (lib/bridge.asm).
    Horloge (00h PING, 01h LIRE, 02h REGLER) et disque (10h-19h) avec un dictionnaire de
    fichiers. mute = pont absent (aucune reponse); ready = False: 'disque non pret'."""
    def __init__(self, files=None, mute=False, ready=True, free=1_000_000, nsec=16384, usb_ok=True, bad_reads=0):
        self.clock = [0xEA, 0x07, 9, 20, 12, 34, 56, 78]     # 2026-09-20 12:34:56.78
        self.files = {k.upper(): bytearray(v) for k, v in (files or {}).items()}
        self.mute, self.ready, self.free = mute, ready, free
        self.cmd = []
        self.cur = None          # [nom, mode, position]
        self.dir = []
        self.log = []            # (operation, argument) pour les tests
        self.nsec = nsec         # secteurs de 512 octets (acces direct, commandes 20h-24h)
        self.sectors = {}        # lba -> 512 octets (absent = zeros)
        self.secbuf = bytearray(512)
        self.usb_ok = usb_ok     # le pont sait offrir le disque au PC (USB ON/OFF)
        self.usb = False         # True: le PC a le disque
        self.img = None          # nom du fichier monte comme image de disquette (commandes 27h-2Ah)
        self.bad_reads = bad_reads   # nombre de LECTURES de secteur dont un octet est altere en route (test des sommes de controle)
        self.corrupt_now = False

    def _need(self):
        c = self.cmd
        op = c[0]
        if op in (0x00, 0x01, 0x10, 0x11, 0x15, 0x16, 0x17, 0x19, 0x20):
            return 1
        if op == 0x02:
            return 8
        if op in (0x21, 0x24):
            return 5
        if op in (0x25, 0x26, 0x28, 0x2B):
            return 1
        if op == 0x27:
            return 2 + c[1] if len(c) >= 2 else 2
        if op in (0x29, 0x2A):
            return 5
        if op == 0x22:
            return 2
        if op == 0x23:
            return 34
        if op == 0x13:
            return 2
        if op == 0x12:
            return 3 + c[2] if len(c) >= 3 else 3
        if op == 0x14:
            return 2 + c[1] if len(c) >= 2 else 2
        if op == 0x18:
            return 2 + c[1] if len(c) >= 2 else 2
        return 1                                              # operation inconnue: ignoree

    def feed(self, b):
        """un octet du canal 3 -> liste des octets de reponse"""
        self.cmd.append(b)
        if len(self.cmd) < self._need():
            return []
        c, self.cmd = self.cmd, []
        rep = self._exec(c)
        return [] if self.mute else rep

    def _name(self, raw):
        n = bytes(raw).decode('latin-1').upper()
        return n if 1 <= len(n) <= 12 else None

    def _exec(self, c):
        op = c[0]
        self.log.append((op, bytes(c[1:])))
        if op == 0x00:
            return [0xB1, 3, 0x1F]
        if op == 0x01:
            return list(self.clock)
        if op == 0x02:
            self.clock[0:7] = c[1:8]
            return []
        if op in (0x25, 0x26):
            if not self.usb_ok:
                return [9]
            if op == 0x25:
                self.cur = None
            self.usb = (op == 0x25)
            return [0]
        if op == 0x2B:
            total = sum(self.secbuf) & 0xFFFF
            return [total & 0xFF, total >> 8]
        if op in (0x27, 0x28, 0x29, 0x2A):
            if self.usb:
                return [1, 0, 0, 0, 0] if op == 0x27 else [1]
            if op == 0x27:
                name = bytes(c[2:2 + c[1]]).decode('latin-1').upper()
                self.img = None
                if not 1 <= len(name) <= 12 or not all(ch.isalnum() or ch in '._-$~' for ch in name):
                    return [5, 0, 0, 0, 0]
                if name not in self.files:
                    return [2, 0, 0, 0, 0]
                self.img = name
                return [0] + list(len(self.files[name]).to_bytes(4, 'little'))
            if op == 0x28:
                self.img = None
                return [0]
            if self.img is None:
                return [7]
            lba = int.from_bytes(bytes(c[1:5]), 'little')
            data = self.files[self.img]
            if (lba + 1) * 512 > len(data):
                return [4]
            if op == 0x29:
                self.secbuf = bytearray(data[lba * 512:(lba + 1) * 512])
                if self.bad_reads > 0:
                    self.bad_reads -= 1
                    self.corrupt_now = True
            else:
                data[lba * 512:(lba + 1) * 512] = self.secbuf
            return [0]
        if self.usb and 0x10 <= op <= 0x24:
            if op in (0x13, 0x17):
                return [0xFF]
            if op == 0x19:
                return [0xFF] * 4
            if op == 0x20:
                return [0] * 4
            if op == 0x22:
                return [0] * 32
            return [1]
        if 0x20 <= op <= 0x24:
            lba = int.from_bytes(bytes(c[1:5]), 'little') if op in (0x21, 0x24) else 0
            if op == 0x20:
                return list((self.nsec if self.ready else 0).to_bytes(4, 'little'))
            if op == 0x22:
                i = c[1]
                chunk = list(self.secbuf[i * 32:(i + 1) * 32]) if i < 16 else [0] * 32
                if self.corrupt_now and i == 3:
                    chunk[5] ^= 0x40                    # un octet altere pendant le transfert
                if i == 15:
                    self.corrupt_now = False
                return chunk
            if not self.ready:
                return [1]
            if op == 0x23:
                i = c[1]
                if i > 15:
                    return [4]
                self.secbuf[i * 32:(i + 1) * 32] = bytes(c[2:34])
                return [0]
            if lba >= self.nsec:
                return [4]
            if op == 0x21:
                self.secbuf = bytearray(self.sectors.get(lba, bytes(512)))
                if self.bad_reads > 0:
                    self.bad_reads -= 1
                    self.corrupt_now = True
            else:
                self.sectors[lba] = bytes(self.secbuf)
            return [0]
        if op in (0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19) and not self.ready:
            if op == 0x13 or op == 0x17:
                return [0xFF]
            if op == 0x19:
                return [0xFF] * 4
            if op == 0x11:
                self.ready = True
                self.files.clear()
                return [0]
            return [1]
        if op == 0x10:
            return [0]
        if op == 0x11:
            self.files.clear()
            self.cur = None
            return [0]
        if op == 0x12:
            mode, name = c[1], self._name(c[3:3 + c[2]])
            if name is None or not all(ch.isalnum() or ch in '._-' for ch in name):
                return [5]
            self.cur = None
            if mode == 0:
                if name not in self.files:
                    return [2]
                self.cur = [name, 0, 0]
            elif mode == 1:
                self.files[name] = bytearray()
                self.cur = [name, 1, 0]
            else:
                self.files.setdefault(name, bytearray())
                self.cur = [name, 2, len(self.files[name])]
            return [0]
        if op == 0x13:
            if not self.cur or self.cur[1] != 0:
                return [0xFF]
            name, _, pos = self.cur
            n = min(c[1], 32)
            data = self.files[name][pos:pos + n]
            self.cur[2] += len(data)
            return [len(data)] + list(data)
        if op == 0x14:
            if not self.cur or self.cur[1] == 0:
                return [7]
            n = c[1]
            data = bytes(c[2:2 + n])
            if sum(len(v) for v in self.files.values()) + n > self.free:
                return [8]
            self.files[self.cur[0]].extend(data)
            return [0]
        if op == 0x15:
            if not self.cur:
                return [7]
            self.cur = None
            return [0]
        if op == 0x16:
            self.dir = sorted(self.files)
            return [0]
        if op == 0x17:
            if not self.dir:
                return [0]
            name = self.dir.pop(0)
            sz = len(self.files[name])
            return [len(name)] + list(name.encode()) + list(sz.to_bytes(4, 'little'))
        if op == 0x18:
            name = self._name(c[2:2 + c[1]])
            if name is None:
                return [5]
            if name not in self.files:
                return [2]
            del self.files[name]
            return [0]
        if op == 0x19:
            used = sum(len(v) for v in self.files.values())
            return list(max(self.free - used, 0).to_bytes(4, 'little'))
        return []


def run(text, max_idle=3000, max_insns=30_000_000, real=False, trace=0, stop_at=None, poke=None, paced=0,
        bridge=None):
    """Execute basic_run avec `text` (str ou bytes) comme entree UART."""
    data = text.encode('latin-1') if isinstance(text, str) else bytes(text)
    # Le texte est livre par "paquets" (une ligne = jusqu'au CR inclus; Ctrl-C/Ctrl-X
    # = un paquet a eux), comme un utilisateur qui tape: un paquet n'est livre que
    # lorsque l'interpreteur ATTEND (getln scrute l'UART sans rien afficher). Sinon
    # les octets d'avance seraient avales par le test Ctrl-C de chaque instruction
    # ('chkio'), comme dans le PATB86 d'origine. Les paquets Ctrl-C/Ctrl-X sont livres
    # apres 300 scrutations meme si le programme tourne (pas d'attente).
    chunks = []
    cur = b''
    for b in data:
        if b in (0x03, 0x18):
            if cur:
                chunks.append(cur); cur = b''
            chunks.append(bytes([b]))
        else:
            cur += bytes([b])
            if b == 0x0D:
                chunks.append(cur); cur = b''
    if cur:
        chunks.append(cur)
    code = open(BIN_REAL if real else BIN, 'rb').read()
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0x00000, 0x20000)
    uc.mem_map(0xC0000, 0x40000)
    uc.mem_write(0xC0000, code)
    for name, val in (poke or {}).items():          # octets ecrits dans le banc avant le depart
        off = [a for a, n in labels(real) if n == name][0]
        uc.mem_write(0xC0000 + off, bytes(val))
    st = {'rem': b'', 'idle': 0, 'polls': 0, 'out': bytearray(), 'done': False,
          'bad': [], 'stopped': 'insns'}

    def ring_feed(uc):
        # emule irq1_arduino_handler/uart_rx_push: un octet a la fois dans le tampon
        # circulaire UART de 16 octets (tete = queue -> vide)
        head = uc.mem_read(UART_HEAD, 1)[0]
        tail = uc.mem_read(UART_TAIL, 1)[0]
        if head == tail and st['rem']:
            uc.mem_write(UART_BUF + tail, bytes([st['rem'][0]]))
            uc.mem_write(UART_TAIL, bytes([(tail + 1) & 0xFF]))
            st['rem'] = st['rem'][1:]
            st['idle'] = 0
            return True
        return False

    def h_poll(uc, access, addr, size, value, ud):
        # lecture de UART_RX_HEAD_OFF = un uart_rx_available: meme logique d'attente
        if not st['rem'] and chunks:
            st['polls'] += 1
            c = chunks[0]
            if (c[0] in (0x03, 0x18) and st['polls'] >= 300) or st['idle'] >= 20:
                st['rem'] = chunks.pop(0)
                st['polls'] = 0
        if not ring_feed(uc):
            st['idle'] += 1
            if not chunks and not st['rem'] and st['idle'] > max_idle:
                st['stopped'] = 'idle'
                uc.emu_stop()

    lab = labels()
    chk_lo = [x for x, n in lab if n == 'bas_chkbrk'][0]
    chk_hi = [x for x, n in lab if n == 'bas_break'][0]

    if bridge is None:
        bridge = BridgeModel()
    st['bridge'] = bridge

    def h_in(uc, port, size, ud):
        if port == 0x82:
            return 0x80                                  # PORTC: OBF# = 1 (tampon libre)
        if real:
            return 0
        if port == 0xE1:
            # appelant de uart_rx_available: bas_chkbrk = un programme s'execute (les lignes
            # saisies ne sont livrees que lorsque l'interpreteur ATTEND une ligne)
            sp = uc.reg_read(UC_X86_REG_SP)
            ret = int.from_bytes(uc.mem_read(uc.reg_read(UC_X86_REG_SS) * 16 + sp, 2), 'little')
            busy = chk_lo <= ret < chk_hi
            if not st['rem'] and chunks:
                st['polls'] += 1
                c = chunks[0]
                if (c[0] in (0x03, 0x18) and st['polls'] >= 300) or (st['idle'] >= 20 and not busy):
                    st['rem'] = chunks.pop(0)
                    st['polls'] = 0
            if st['rem']:
                return 1
            st['idle'] += 1
            if not chunks and st['idle'] > max_idle:
                st['stopped'] = 'idle'
                uc.emu_stop()
            return 0
        if port == 0xE2:
            b = st['rem'][0]
            st['rem'] = st['rem'][1:]
            st['idle'] = 0
            return b
        return 0

    def h_out(uc, port, size, value, ud):
        if port == 0x81:
            st['chan'] = value & 0xFF                   # PORTB: canal
        elif port == 0x80:
            chan = st.get('chan', 0)
            if chan == 0 and real:                      # canal 0 = octet UART emis
                st['out'].append(value & 0xFF)
                st['idle'] = 0
            elif chan == 3:                             # commandes du pont (horloge, disque)
                for b in bridge.feed(value & 0xFF):
                    if uc.mem_read(BR_EXPECT, 1)[0] != 1:
                        continue                        # l'ISR ne classe en reponse que si attendue
                    tail = uc.mem_read(BR_TAIL, 1)[0]
                    uc.mem_write(BR_BUF + tail, bytes([b]))
                    uc.mem_write(BR_TAIL, bytes([(tail + 1) & 0x3F]))
        elif port == 0xE0:
            st['out'].append(value & 0xFF)
            st['idle'] = 0
        elif port == 0xFF:
            st['done'] = True
            st['stopped'] = 'done'
            uc.emu_stop()

    def h_write(uc, access, addr, size, value, ud):
        if not any(a <= addr and addr + size <= b for a, b in ALLOWED):
            st['bad'].append((addr, size))

    st['uc'] = uc
    if paced:
        # collage a debit FIXE (comme le pont): 1 octet toutes les `paced` instructions, sans
        # attendre l'interpreteur; le tampon UART est ecrase par le plus recent s'il deborde
        # (mode reel seulement)
        pace = {'data': bytearray(data), 'n': 0, 'lost': 0}
        chunks.clear()

        def _pace(uc, a, sz, ud):
            pace['n'] += 1
            if pace['n'] % paced == 0 and pace['data']:
                head = uc.mem_read(UART_HEAD, 1)[0]
                tail = uc.mem_read(UART_TAIL, 1)[0]
                uc.mem_write(UART_BUF + tail, bytes([pace['data'].pop(0)]))
                tail = (tail + 1) & 0xFF
                uc.mem_write(UART_TAIL, bytes([tail]))
                if tail == head:                         # tampon plein: l'octet le plus ancien est perdu
                    uc.mem_write(UART_HEAD, bytes([(head + 1) & 0xFF]))
                    pace['lost'] += 1
                st['idle'] = 0
        st['pace'] = pace
        uc.hook_add(UC_HOOK_CODE, _pace)
    uc.hook_add(UC_HOOK_INSN, h_in, None, 1, 0, UC_X86_INS_IN)
    uc.hook_add(UC_HOOK_INSN, h_out, None, 1, 0, UC_X86_INS_OUT)

    def h_intr(uc, intno, ud):
        st.setdefault('ints', []).append(intno)          # INT n: enregistre et arrete (BOOT = INT 19h)
        st['stopped'] = 'int %02X' % intno
        uc.emu_stop()

    uc.hook_add(UC_HOOK_INTR, h_intr)
    uc.hook_add(UC_HOOK_MEM_WRITE, h_write)
    if trace:
        import collections
        ring = collections.deque(maxlen=trace)
        st['trace'] = ring
        def _tr(uc, a, sz, ud):
            ring.append(a - 0xC0000)
            if stop_at is not None and a - 0xC0000 == stop_at:
                st['stopped'] = 'stop_at'
                uc.emu_stop()
        uc.hook_add(UC_HOOK_CODE, _tr)
    if real:
        uc.hook_add(UC_HOOK_MEM_READ, h_poll, None, UART_HEAD, UART_HEAD)
    uc.reg_write(UC_X86_REG_CS, 0xC000)
    try:
        uc.emu_start(0xC0000, 0, count=max_insns)
    except UcError as e:
        st['stopped'] = 'error: %s (cs:ip=%04X:%04X)' % (
            e, uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP))
    out = st['out'].decode('latin-1').replace('\r\n', '\n').replace('\r', '\n')
    regs = {}
    if st['done']:
        for name, off in symbols(real).items():
            regs[name[6:]] = int.from_bytes(uc.mem_read(0xC0000 + off, 2), 'little')
    return out, st, regs


fails = 0
total = 0


def check(name, cond, extra=''):
    global fails, total
    total += 1
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '   -> ' + extra))
    if not cond:
        fails += 1


def has(out, *subs):
    return all(s in out for s in subs)


def results(out, text=''):
    """sortie SANS l'echo des lignes saisies, la banniere et les 'Ok'"""
    NL = chr(10)
    CR = chr(13)
    echoed = set(text.replace(CR, NL).split(NL))
    keep = []
    for ln in out.replace(CR, '').split(NL):
        if ln == 'Ok' or ln in echoed or ln.startswith('VE2CUY BASIC') or ln.startswith('Chaines') or ln.startswith('VE2CUY 86 BASIC') or ln.startswith('HELP: help') or ln.startswith('Edit last command'):
            continue
        keep.append(ln)
    return NL.join(keep).strip(NL)


def R(text, **kw):
    """execute `text`; retourne la sortie utile (echo/Ok/banniere retires)"""
    kw.setdefault('max_idle', 200000)
    out, st, regs = run(text, **kw)
    R.st = st
    R.out = out
    R.regs = regs
    return results(out, text)


def numbers(out):
    return [int(x) for x in re.findall(r'-?\d+', results(out))]



build()
