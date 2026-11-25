#!/usr/bin/env python3
"""Banc d'essai de ramtest-128k.asm (ROM de test de la RAM de 128 Ko, du 8255 et du 8259 SANS RAM) sous Unicorn.

Le 8088 execute la ROM depuis le vecteur de reset. Materiel emule:
  8255 (mode 2)  OUT 81h = canal (verrou relu par IN 81h), OUT 80h = octet vers le pont (canal 1 = commande
                 HD44780, 2 = caractere); IN 82h = mot d'etat: OBF# = 1 (le pont a toujours lu), INTE1 (bit 6),
                 INTE2 (bit 4), INTR (bit 3) = INTE1 (OBF# = 1, ACK# au repos); OUT 83h = mot de mode / bit set-reset.
  8259           ICW1-ICW4 (20h puis 21h), IMR (21h, relu), OCW3 lecture IRR/ISR (20h); IR1 = INTR du 8255.
  LCD 20x4       reconstitue (DDRAM 00h/40h/14h/54h); chaque ecran efface est conserve (ecran de detail).
  RAM 00000h-1FFFFh en MMIO, avec defauts injectes:
    bonne         128 Ko qui fonctionnent
    absente       aucune RAM: lecture = derniere valeur vue sur le bus (bus flottant), ecritures perdues
    bit3          bit de donnees 3 colle a 0 partout
    a12 / a16     ligne d'adresse coupee (collee a 0): recouvrements
    bloc5         defaut dans le bloc 5 (0A000h-0BFFFh): le bit 6 de 0A123h colle a 1
    intermittent  le defaut de bloc5, seulement pendant la 1re passe: '!' a la 2e
  defauts des puces (RAM bonne):
    pb5           bit 5 du port B du 8255 relu a 0
    sans8259      8259 absent: IN 20h/21h = bus flottant (derniere valeur vue sur le bus)
    ir1coupe      liaison INTR (8255) -> IR1 (8259) coupee
    inte          INTE2 du 8255 relu toujours a 0
Pour CHAQUE cas, la ROM doit produire ses ecrans complets (preuve qu'elle n'utilise ni pile ni variable en RAM)
et le bon diagnostic. La ROM est protegee en ecriture, SS:SP = DEAD:BEEF au depart et rien n'est mappe hors
des 128 Ko testes: une pile ou une variable ferait echouer l'emulation.

Usage (depuis la racine de Solution-01): python tests/ramtest_sim.py [-v]
"""
import os, re, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROM = 0xC0000
RAM_SIZE = 0x20000


def build():
    out = os.path.join(ROOT, 'build', 'ramtest-128k.bin')
    lst = os.path.join(ROOT, 'build', 'ramtest-128k.lst')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(['nasm', '-f', 'bin', 'ramtest-128k.asm', '-o', out, '-l', lst], cwd=ROOT, check=True)
    lines = open(lst, encoding='latin-1').read().splitlines()
    for i, l in enumerate(lines):                    # adresse de l'etiquette "passe" (debut d'une passe)
        if re.match(r'^\s*\d+\s+passe:', l):
            for l2 in lines[i + 1:]:
                m = re.match(r'^\s*\d+ ([0-9A-F]{8}) ', l2)
                if m:
                    return out, int(m.group(1), 16)
    raise SystemExit('etiquette passe introuvable')


class Bus:
    """derniere valeur vue sur le bus de donnees (bus flottant d'une puce ou d'une RAM absente)"""
    val = 0xFF


class Ram:
    def __init__(self, mode, bus):
        self.mode, self.mem, self.bus = mode, bytearray(RAM_SIZE), bus
        self.passe = 0

    def phys(self, a):
        if self.mode == 'a12':
            a &= ~0x1000
        if self.mode == 'a16':
            a &= ~0x10000
        return a

    def read(self, uc, off, size, ud):
        val = 0
        for i in range(size):
            a = off + i
            if self.mode == 'absente':
                b = self.bus.val
            else:
                b = self.mem[self.phys(a)]
                if self.mode == 'bit3':
                    b &= ~0x08
                if a == 0xA123 and (self.mode == 'bloc5' or (self.mode == 'intermittent' and self.passe <= 1)):
                    b |= 0x40
            self.bus.val = b
            val |= b << (8 * i)
        return val

    def write(self, uc, off, size, value, ud):
        for i in range(size):
            b = (value >> (8 * i)) & 0xFF
            self.bus.val = b
            if self.mode != 'absente':
                self.mem[self.phys(off + i)] = b


class Machine:
    def __init__(self, binary, adr_passe, mode):
        self.uc = uc = Uc(UC_ARCH_X86, UC_MODE_16)
        self.mode, self.bus = mode, Bus()
        self.ram = Ram(mode, self.bus)
        uc.mmio_map(0, RAM_SIZE, self.ram.read, None, self.ram.write, None)
        uc.mem_map(ROM, 0x40000)
        rom = open(binary, 'rb').read()
        uc.mem_write(ROM, rom)
        uc.mem_protect(ROM, 0x40000, UC_PROT_READ | UC_PROT_EXEC)   # une ecriture (pile?) y echoue
        self.rom = rom
        self.chan, self.portb, self.inte1, self.inte2 = 0, 0, 0, 0
        self.pic = dict(etape=0, imr=0xFF, lire='irr', niveau=False)
        self.addr, self.ddram, self.ecrans = 0, bytearray(b' ' * 0x80), []
        self.passes = 0
        uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_CODE, self._passe, None, ROM + adr_passe, ROM + adr_passe)
        uc.hook_add(UC_HOOK_MEM_READ, self._lecture_rom, None, ROM, ROM + 0x3FFFF)

    def _lecture_rom(self, uc, acces, adr, taille, val, ud):      # une lecture de donnee en ROM passe sur le bus
        self.bus.val = self.rom[adr - ROM + taille - 1]

    def _passe(self, uc, adr, taille, ud):
        self.passes += 1
        self.ram.passe = self.passes
        if self.passes > self.stop_after:
            uc.emu_stop()

    def intr(self):
        return 1 if (self.inte1 and self.mode != 'ir1coupe_8255') else 0

    def _in(self, uc, port, size, ud):
        v = 0
        if port == 0x81:
            v = self.portb & (0xDF if self.mode == 'pb5' else 0xFF)
        elif port == 0x82:
            inte2 = 0 if self.mode == 'inte' else self.inte2
            v = 0x80 | (self.inte1 << 6) | (inte2 << 4) | (self.inte1 << 3)
        elif port in (0x20, 0x21):
            if self.mode == 'sans8259':
                v = self.bus.val
            elif port == 0x21:
                v = self.pic['imr']
            elif self.pic['lire'] == 'isr':
                v = 0
            else:
                ir1 = 0 if self.mode == 'ir1coupe' else self.intr()
                v = ir1 << 1
        self.bus.val = v
        return v

    def _out(self, uc, port, size, value, ud):
        self.bus.val = value
        if port == 0x81:
            self.portb = value
            self.chan = value & 3
        elif port == 0x83:
            if value & 0x80:                        # mot de mode: verrous et INTE remis a 0
                self.portb = self.inte1 = self.inte2 = 0
            else:
                bit, val = (value >> 1) & 7, value & 1
                if bit == 6:
                    self.inte1 = val
                elif bit == 4:
                    self.inte2 = val
        elif port == 0x20 and self.mode != 'sans8259':
            if value & 0x10:                        # ICW1
                self.pic.update(etape=1, niveau=bool(value & 8), icw4=bool(value & 1))
            elif value & 0x08:                      # OCW3
                if value & 2:
                    self.pic['lire'] = 'isr' if value & 1 else 'irr'
        elif port == 0x21 and self.mode != 'sans8259':
            p = self.pic
            if p['etape'] == 1:
                p['etape'] = 2 if p.get('icw4') else 0
            elif p['etape'] == 2:
                p['etape'] = 0
            else:
                p['imr'] = value
        elif port == 0x80:
            if self.chan == 1:
                if value == 0x01:
                    if self.ddram.strip():
                        self.ecrans.append(self.lines())
                    self.ddram[:] = b' ' * 0x80
                    self.addr = 0
                elif value & 0x80:
                    self.addr = value & 0x7F
            elif self.chan == 2:
                self.ddram[self.addr] = value
                self.addr = (self.addr + 1) & 0x7F

    def lines(self):
        d = self.ddram
        return [d[s:s + 20].decode('latin-1') for s in (0x00, 0x40, 0x14, 0x54)]

    def run(self, passes=2, budget=600_000_000):
        self.stop_after = passes
        self.uc.reg_write(UC_X86_REG_CS, 0xFFFF)
        self.uc.reg_write(UC_X86_REG_SS, 0xDEAD)    # valeurs absurdes: la ROM ne doit pas s'en servir
        self.uc.reg_write(UC_X86_REG_SP, 0xBEEF)
        self.uc.emu_start(0xFFFF0, 0, count=budget)
        return self.lines()


DETAIL_OK = ['8255 port B : OK    ', '8255 INTE OK INTR OK', '8259 IMR OK ISR OK  ', 'IR1 8255>8259 : OK  ']
L1_OK = '0002 8255:OK 8259:OK'
# cas -> (ecran de detail attendu ou None, ligne 1, lignes 2, 3, 4) apres 2 passes (None = verifie a part)
CAS = {
    'bonne':        (DETAIL_OK, L1_OK, 'Donnees : OK        ', 'Adresses: OK        ', '................ OK '),
    'bit3':         (DETAIL_OK, L1_OK, 'Donnees : KO 08     ', 'Adresses: OK        ', 'XXXXXXXXXXXXXXXX 08 '),
    'a12':          (DETAIL_OK, L1_OK, 'Donnees : OK        ', 'Adresses: KO 01000  ', None),
    'bloc5':        (DETAIL_OK, L1_OK, 'Donnees : OK        ', 'Adresses: OK        ', '.....X.......... 40 '),
    'a16':          (DETAIL_OK, L1_OK, 'Donnees : OK        ', 'Adresses: KO 10000  ', None),
    'intermittent': (DETAIL_OK, L1_OK, 'Donnees : OK        ', 'Adresses: OK        ', '.....!.......... 40 '),
    'absente':      (DETAIL_OK, L1_OK, None, None, None),
    'pb5':          (['8255 port B : KO 20 ', '8255 INTE OK INTR OK', '8259 IMR OK ISR OK  ', 'IR1 8255>8259 : OK  '],
                     '0002 8255:KO 8259:OK', 'Donnees : OK        ', 'Adresses: OK        ', '................ OK '),
    'sans8259':     (None, '0002 8255:OK 8259:KO', 'Donnees : OK        ', 'Adresses: OK        ', '................ OK '),
    'ir1coupe':     (['8255 port B : OK    ', '8255 INTE OK INTR OK', '8259 IMR OK ISR OK  ', 'IR1 8255>8259 : KO  '],
                     '0002 8255:OK 8259:KO', 'Donnees : OK        ', 'Adresses: OK        ', '................ OK '),
    'inte':         (['8255 port B : OK    ', '8255 INTE KO INTR OK', '8259 IMR OK ISR OK  ', 'IR1 8255>8259 : OK  '],
                     '0002 8255:KO 8259:OK', 'Donnees : OK        ', 'Adresses: OK        ', '................ OK '),
}


def main():
    verbose = '-v' in sys.argv
    binary, adr_passe = build()
    echecs = 0
    for mode, (detail_att, *attendu) in CAS.items():
        m = Machine(binary, adr_passe, mode)
        try:
            lignes = m.run()
        except UcError as e:
            print(f'[ECHEC] {mode}: emulation arretee ({e}) - acces hors des 128 Ko (pile/variable?)')
            echecs += 1
            continue
        detail = m.ecrans[0] if m.ecrans else ['(aucun ecran de detail)'] * 4
        ok = all(exp is None or got == exp for got, exp in zip(lignes, attendu))
        if detail_att is not None and detail != detail_att:
            ok = False
        if mode == 'absente':
            ok = ok and lignes[1].startswith('Donnees : KO') and lignes[2].startswith('Adresses: KO') \
                 and lignes[3][:16] == 'X' * 16
        if mode in ('a12', 'a16'):
            ok = ok and 'X' in lignes[3][:16] and lignes[3][17:19] != 'OK'
        if mode == 'sans8259':                      # IMR relu faux ou ISR non nul: le 8259 est KO
            ok = ok and detail[0] == '8255 port B : OK    ' and detail[2] != DETAIL_OK[2]
        print(f"[{'ok' if ok else 'ECHEC'}] {mode}")
        if verbose or not ok:
            for a, b in zip(detail, lignes):
                print(f'       |{a}|   |{b}|')
        echecs += not ok
    print('BILAN:', 'tout est correct' if not echecs else f'{echecs} cas en echec')
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
