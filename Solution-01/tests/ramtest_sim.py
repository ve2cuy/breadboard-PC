#!/usr/bin/env python3
"""Banc d'essai de ramtest-128k.asm (ROM de test de la RAM de 128 Ko SANS RAM) sous Unicorn.

Le 8088 execute la ROM depuis le vecteur de reset; le 8255 et le pont sont emules juste assez pour le LCD:
OUT 81h = canal, OUT 80h = octet (canal 1 = commande HD44780, 2 = caractere), IN 82h = OBF# libre. Le LCD
20x4 est reconstitue (adresses DDRAM 00h/40h/14h/54h). La RAM 00000h-1FFFFh est un modele en MMIO:
  bonne         128 Ko qui fonctionnent
  absente       aucune RAM: lecture = derniere valeur vue sur le bus (bus flottant), ecritures perdues
  bit3          bit de donnees 3 colle a 0 partout
  a12           ligne d'adresse A12 coupee (collee a 0): 1000h-1FFFh retombe sur 0000h-0FFFh, etc.
  bloc5         defaut dans le bloc 5 (0A000h-0BFFFh): le bit 6 de 0A123h colle a 1
  a16           A16 collee a 0: 10000h-1FFFFh retombe sur 00000h-0FFFFh
  intermittent  le defaut de bloc5, seulement pendant la 1re passe: '!' a la 2e (fautif a une passe precedente)
Pour CHAQUE cas, la ROM doit produire son ecran complet (preuve qu'elle n'utilise ni pile ni variable en
RAM: la RAM absente ou fausse ne l'arrete pas) et le bon diagnostic. Aucun acces hors des 128 Ko testes
(pile, variables) n'est tolere: la memoire au-dela n'est pas mappee et ferait echouer l'emulation.

Usage (depuis la racine de Solution-01): python tests/ramtest_sim.py [-v]
"""
import os, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROM = 0xC0000
RAM_SIZE = 0x20000


def build():
    out = os.path.join(ROOT, 'build', 'ramtest-128k.bin')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(['nasm', '-f', 'bin', 'ramtest-128k.asm', '-o', out], cwd=ROOT, check=True)
    return out


class Ram:
    """modele de RAM 128 Ko avec defauts injectes"""

    def __init__(self, mode):
        self.mode, self.mem, self.bus = mode, bytearray(RAM_SIZE), 0xFF
        self.passe = 0                              # tenu a jour par Machine

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
                b = self.bus
            else:
                b = self.mem[self.phys(a)]
                if self.mode == 'bit3':
                    b &= ~0x08
                if a == 0xA123 and (self.mode == 'bloc5' or (self.mode == 'intermittent' and self.passe <= 1)):
                    b |= 0x40
            self.bus = b
            val |= b << (8 * i)
        return val

    def write(self, uc, off, size, value, ud):
        for i in range(size):
            b = (value >> (8 * i)) & 0xFF
            self.bus = b
            if self.mode != 'absente':
                self.mem[self.phys(off + i)] = b


class Machine:
    def __init__(self, binary, mode):
        self.uc = uc = Uc(UC_ARCH_X86, UC_MODE_16)
        self.ram = Ram(mode)
        uc.mmio_map(0, RAM_SIZE, self.ram.read, None, self.ram.write, None)
        uc.mem_map(ROM, 0x40000)
        uc.mem_write(ROM, open(binary, 'rb').read())
        uc.mem_protect(ROM, 0x40000, UC_PROT_READ | UC_PROT_EXEC)   # une ecriture (pile?) y echoue
        self.chan, self.addr = 0, 0
        self.ddram = bytearray(b' ' * 0x80)
        self.passes = 0
        uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)

    def _in(self, uc, port, size, ud):
        return 0x80 if port == 0x82 else 0          # OBF# = 1: le pont a toujours lu

    def _out(self, uc, port, size, value, ud):
        if port == 0x81:
            self.chan = value & 3
        elif port == 0x80:
            if self.chan == 1:
                if value == 0x01:
                    self.ddram[:] = b' ' * 0x80
                    self.addr = 0
                elif value & 0x80:
                    self.addr = value & 0x7F
                    if self.addr == 0x10:               # curseur sur le compteur: une passe commence
                        self.passes += 1
                        self.ram.passe = self.passes
                        if self.passes > self.stop_after:
                            uc.emu_stop()
            elif self.chan == 2:
                self.ddram[self.addr] = value
                self.addr = (self.addr + 1) & 0x7F

    def lines(self):
        d = self.ddram
        return [d[s:s + 20].decode('latin-1') for s in (0x00, 0x40, 0x14, 0x54)]

    def run(self, passes=2, budget=400_000_000):
        self.stop_after = passes
        self.uc.reg_write(UC_X86_REG_CS, 0xFFFF)
        self.uc.reg_write(UC_X86_REG_SS, 0xDEAD)    # valeurs absurdes: la ROM ne doit pas s'en servir
        self.uc.reg_write(UC_X86_REG_SP, 0xBEEF)
        self.uc.emu_start(0xFFFF0, 0, count=budget)
        return self.lines()


# cas -> lignes 2, 3, 4 attendues apres 2 passes (la ligne 1 est verifiee a part)
CAS = {
    'bonne':   ('Donnees : OK        ', 'Adresses: OK        ', '................ OK '),
    'bit3':    ('Donnees : KO 08     ', 'Adresses: OK        ', 'XXXXXXXXXXXXXXXX 08 '),
    'a12':     ('Donnees : OK        ', 'Adresses: KO 01000  ', None),
    'bloc5':   ('Donnees : OK        ', 'Adresses: OK        ', '.....X.......... 40 '),
    'a16':     ('Donnees : OK        ', 'Adresses: KO 10000  ', None),
    'intermittent': ('Donnees : OK        ', 'Adresses: OK        ', '.....!.......... 40 '),
    'absente': (None, None, None),
}


def main():
    verbose = '-v' in sys.argv
    binary = build()
    echecs = 0
    for mode, attendu in CAS.items():
        m = Machine(binary, mode)
        try:
            lignes = m.run()
        except UcError as e:
            print(f'[ECHEC] {mode}: emulation arretee ({e}) - acces hors des 128 Ko (pile/variable?)')
            echecs += 1
            continue
        ok = lignes[0] == 'Test RAM 128K P:0002'
        for got, exp in zip(lignes[1:], attendu):
            if exp is not None and got != exp:
                ok = False
        if mode == 'absente':                       # tout doit etre declare fautif, ecran complet
            ok = ok and lignes[1].startswith('Donnees : KO') and lignes[2].startswith('Adresses: KO') \
                 and lignes[3][:16] == 'X' * 16
        if mode in ('a12', 'a16'):                  # recouvrement: des blocs fautifs, bits non nuls
            ok = ok and 'X' in lignes[3][:16] and lignes[3][17:19] != 'OK'
        print(f"[{'ok' if ok else 'ECHEC'}] {mode}")
        if verbose or not ok:
            for l in lignes:
                print('       |' + l + '|')
        echecs += not ok
    print('BILAN:', 'tout est correct' if not echecs else f'{echecs} cas en echec')
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
