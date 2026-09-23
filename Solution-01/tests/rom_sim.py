#!/usr/bin/env python3
"""Simulateur du 8088 AVEC SON MATERIEL (Unicorn): la ROM complete ou le BIOS, avec des IRQ1 ASYNCHRONES.

Difference avec basic_harness.py / bios_test.py: ici, chaque octet du pont et chaque frappe passe par le
VRAI chemin materiel - le 8255 (IBF, etiquettes PC0/PC1 du Port C, octet suivant depose des que le
precedent est lu), le 8259 (masque IMR ecrit sur 21h, une IRQ1 a la fois jusqu'a l'EOI, livree seulement
si IF = 1) puis l'ISR du firmware via l'IVT. Indispensable pour tout ce qui touche l'ISR, le masquage
d'IR1 pendant les commandes au pont (scrutation, lib/bridge.asm) ou le redemarrage a chaud (Ctrl-\\).
Le pont STM32 est BridgeModel (basic_harness.py): horloge, fichiers, secteurs, images de disquette.

Deux usages:
  run_rom(...)   la ROM COMPLETE (solution-01.bin, exactement celle qu'on grave), depuis le vecteur de
                 reset: menu, BASIC, amorcage DOS, Ctrl-\\...
  run_bios(...)  tests/bios_test.asm (BIOS + ISR + pont, sans le moniteur): cas INT n executes "comme
                 un DOS" (voir bios_test.py) - p. ex. monter une image et INT 19h - plus rapide.

Un SCENARIO est une liste de paires (texte attendu sur l'UART, touches a taper): les touches sont tapees
une a une (espacees de `gap` blocs d'instructions) des que le texte attendu est apparu APRES le point
atteint par la paire precedente - comme un utilisateur devant son terminal.

Limites: la logique seulement (aucun timing ni electrique reels); le LCD est ignore; IN sur les ports
non emules = 0.

Usage en ligne de commande (depuis la racine de Solution-01):
  python tests/rom_sim.py --image ../PC-DOS/pcdos2_1.img scenario.txt
      scenario.txt: une paire par ligne, "texte attendu => touches" (sequences \\r \\x1c ... permises;
      "texte attendu =>" seul = attendre sans taper). L'image est offerte au pont sous son nom en
      majuscules (menu USB Disk -> 3) Boot disk image).
Prerequis: pip install unicorn ; nasm dans le PATH.
"""
import os, struct, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tests'))
import basic_harness as H          # BridgeModel (le pont)

ROM = 0xC0000
PC_IBF, PC_TAG_UART, PC_TAG_REPLY = 0x20, 0x01, 0x02
PORTA, PORTB, PORTC, PIO, PIC_CMD, PIC_DATA = 0x80, 0x81, 0x82, 0x83, 0x20, 0x21
CHAN_UART, CHAN_CMD = 0, 3
MENU = b'4) Configuration'         # derniere ligne du menu principal (FR et EN)


def build(src, out, defines=()):
    """assemble `src` (relatif a la racine de Solution-01) -> build/`out`; renvoie le chemin"""
    path = os.path.join(ROOT, 'build', out)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.run(['nasm', '-f', 'bin'] + ['-d' + d for d in defines] + [src, '-o', path], cwd=ROOT, check=True)
    return path


class Machine:
    """8088 + RAM + ROM + 8255 + 8259 + pont simule. st: etat observable apres run()."""

    def __init__(self, binary, bridge=None, mem=None, script=(), gap=300, tail_blocks=3_000_000,
                 stop_on=None, verbose=False):
        self.bridge = bridge or H.BridgeModel()
        self.uc = uc = Uc(UC_ARCH_X86, UC_MODE_16)
        uc.mem_map(0, 0x80000)                          # RAM (le materiel n'en a que 128 Ko)
        uc.mem_map(ROM, 0x40000)
        uc.mem_write(ROM, open(binary, 'rb').read())
        for a, b in (mem or {}).items():
            uc.mem_write(a, bytes(b))
        self.gap, self.tail_blocks, self.stop_on, self.verbose = gap, tail_blocks, stop_on, verbose
        self.st = dict(uart=bytearray(), chan=0, q=[], keys=[], script=list(script), mark=0, new=True,
                       insvc=False, pend=False, mask=0xFF, masks={}, portc=0x80, porta=0, blocks=0,
                       nextkey=0, irqs=0, end=None, badports=set(), err=None)
        uc.hook_add(UC_HOOK_INSN, self._in, None, 1, 0, UC_X86_INS_IN)
        uc.hook_add(UC_HOOK_INSN, self._out, None, 1, 0, UC_X86_INS_OUT)
        uc.hook_add(UC_HOOK_INTR, lambda uc, n, ud: self._vector(n))
        uc.hook_add(UC_HOOK_BLOCK, self._block)

    # --- aiguillage des interruptions du mode reel (Unicorn ne le fait pas): IVT en 0000:0000 ---
    def _push(self, v):
        uc = self.uc
        ss, sp = uc.reg_read(UC_X86_REG_SS), (uc.reg_read(UC_X86_REG_SP) - 2) & 0xFFFF
        uc.mem_write(ss * 16 + sp, struct.pack('<H', v))
        uc.reg_write(UC_X86_REG_SP, sp)

    def _vector(self, n):
        uc = self.uc
        off, seg = struct.unpack('<HH', bytes(uc.mem_read(n * 4, 4)))
        fl = uc.reg_read(UC_X86_REG_EFLAGS)
        self._push(fl & 0xFFFF); self._push(uc.reg_read(UC_X86_REG_CS)); self._push(uc.reg_read(UC_X86_REG_IP))
        uc.reg_write(UC_X86_REG_EFLAGS, fl & ~0x300)                     # IF = TF = 0
        uc.reg_write(UC_X86_REG_CS, seg)
        uc.reg_write(UC_X86_REG_IP, off)

    # --- 8255 (ports 80h-83h) et 8259 (20h/21h) ---
    def _in(self, uc, port, size, ud):
        st = self.st
        if port == PORTC:
            return st['portc']
        if port == PORTA:
            st['portc'] &= ~PC_IBF                                     # lire le Port A efface IBF/INTR
            st['pend'] = False
            return st['porta']
        return 0

    def _out(self, uc, port, size, value, ud):
        st, value = self.st, value & 0xFF
        if port not in (PIC_CMD, PIC_DATA, PORTA, PORTB, PORTC, PIO, 0xFF):
            st['badports'].add(port)
        if port == PORTB:
            st['chan'] = value
        elif port == PORTA:
            if st['chan'] == CHAN_UART:
                st['uart'].append(value)
                st['new'] = True
                if self.verbose:
                    sys.stdout.write(chr(value)); sys.stdout.flush()
                if self.stop_on and st['uart'].endswith(self.stop_on):
                    uc.emu_stop()
            elif st['chan'] == CHAN_CMD:
                st['q'].extend((PC_TAG_REPLY, b) for b in self.bridge.feed(value))
        elif port == PIO and value & 0x80:
            st['portc'] &= ~PC_IBF                                     # mot de mode: drapeaux remis a 0
            st['pend'] = False
        elif port == PIC_CMD and (value == 0x20 or value & 0x10):
            st['insvc'] = False                                        # EOI, ou ICW1 (8259 reinitialise)
        elif port == PIC_DATA:
            st['mask'] = value
            st['masks'][value] = st['masks'].get(value, 0) + 1
        elif port == 0xFF:                                             # fin (bios_test.asm)
            uc.emu_stop()

    def _block(self, uc, addr, size, ud):
        st = self.st
        st['blocks'] += 1
        if st['new'] and not st['keys'] and st['script']:            # scenario: texte attendu vu?
            st['new'] = False
            want, keys = st['script'][0]
            i = st['uart'].find(want, st['mark'])
            if i >= 0:
                st['mark'] = i + len(want)
                st['script'].pop(0)
                st['keys'] = list(keys)
                st['nextkey'] = st['blocks'] + 20 * self.gap
                st['new'] = True                                       # la paire suivante est peut-etre deja la
        if st['keys'] and not st['q'] and st['blocks'] >= st['nextkey']:
            st['q'].append((PC_TAG_UART, st['keys'].pop(0)))           # une frappe au terminal
            st['nextkey'] = st['blocks'] + self.gap
        if st['q'] and not (st['portc'] & PC_IBF):                    # le pont depose l'octet suivant
            tag, b = st['q'].pop(0)
            st['portc'], st['porta'], st['pend'] = 0x80 | PC_IBF | tag, b, True
        if (st['pend'] and not st['insvc'] and not (st['mask'] & 2)
                and uc.reg_read(UC_X86_REG_EFLAGS) & 0x200):            # IRQ1 -> INT 09h
            st['pend'], st['insvc'] = False, True
            st['irqs'] += 1
            self._vector(9)
        if not st['script'] and not st['keys'] and st['end'] is None:
            st['end'] = st['blocks'] + self.tail_blocks               # scenario fini: encore un peu
        if st['end'] is not None and st['blocks'] > st['end']:
            uc.emu_stop()

    def run(self, count=3_000_000_000):
        try:
            self.uc.reg_write(UC_X86_REG_CS, ROM >> 4)
            self.uc.emu_start(ROM, 0, count=count)
        except UcError as e:
            self.st['err'] = str(e)
        st = self.st
        st['out'] = bytes(st['uart'])
        st['done'] = not st['script'] and not st['keys']
        st['cs'], st['ip'] = self.uc.reg_read(UC_X86_REG_CS), self.uc.reg_read(UC_X86_REG_IP)
        return st


def run_rom(script, bridge=None, rom=None, **kw):
    """la ROM complete (build/rom_sim.bin, assemblee depuis solution-01.asm, ou `rom`) + scenario"""
    rom = rom or build('solution-01.asm', 'rom_sim.bin', kw.pop('defines', ()))
    count = kw.pop('count', 3_000_000_000)
    return Machine(rom, bridge=bridge, script=script, **kw).run(count)


def case(n, ax=0, bx=0, cx=0, dx=0, si=0, di=0, es=0x5000, ds=0x2000, bp=0x1234, ss=0x3000, sp=0xF000):
    """un cas de tests/bios_test.asm (meme format que bios_test.py)"""
    return struct.pack('<BBHHHHHHHHHHHBB', n, 0, ax, bx, cx, dx, si, di, es, ds, bp, ss, sp, 0x80, 0) + bytes(6)


def boot_image(name):
    """cas bios_test.asm: monter l'image `name` (INT 13h AH=F0h, nom en 2000:0000) puis INT 19h"""
    return [case(0x13, ax=0xF000, si=0x0000, ds=0x2000), case(0x19)], {0x20000: name.encode() + b'\0'}


def run_bios(cases, mem, script, bridge=None, defines=(), **kw):
    """tests/bios_test.asm (BIOS + ISR + pont) + table de cas + scenario"""
    binary = build('tests/bios_test.asm', 'rom_sim_bios.bin', defines)
    mem = dict(mem)
    mem[ROM + 0x4000] = b''.join(cases) + b'\xFF'
    count = kw.pop('count', 2_000_000_000)
    return Machine(binary, bridge=bridge, mem=mem, script=script, **kw).run(count)


def dos_script(dos3, commands, fin=b'FIN_OK'):
    """scenario DOS: date/heure par defaut, puis chaque commande a l'invite A>, puis 'echo FIN_OK'"""
    s = [(b'(mm-dd-yy): ', b'09-20-2026\r'), (b'time: ', b'\r')] if dos3 else \
        [(b'Enter new date: ', b'\r'), (b'Enter new time: ', b'\r')]
    for c in commands:
        s.append((b'A>', c))
    s.append((b'A>', b'echo ' + fin + b'\r'))
    s.append((fin + b'\r\n', b''))
    return s


# ------------------------------------------------------------------ ligne de commande
def _parse(path):
    out = []
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\r\n')
        if not line.strip() or line.lstrip().startswith('#') or '=>' not in line:
            continue
        want, keys = line.split('=>', 1)
        dec = lambda t: t.encode('latin-1').decode('unicode_escape').encode('latin-1')
        out.append((dec(want.strip()), dec(keys.strip())))
    return out


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description='ROM complete sous emulateur, scenario pilote par l\'UART')
    ap.add_argument('scenario', help='fichier "texte attendu => touches", une paire par ligne')
    ap.add_argument('--image', action='append', default=[], help='fichier offert au pont (repetable)')
    ap.add_argument('--rom', help='ROM a executer (defaut: assemblee depuis solution-01.asm)')
    ap.add_argument('--quiet', action='store_true', help='ne pas afficher l\'UART en direct')
    a = ap.parse_args()
    files = {os.path.basename(p).upper(): open(p, 'rb').read() for p in a.image}
    st = run_rom(_parse(a.scenario), H.BridgeModel(files=files), rom=a.rom, verbose=not a.quiet)
    print('\n--- fin: scenario %s, IRQ1 %d, erreur %s, CS:IP %04X:%04X' %
          ('termine' if st['done'] else 'INACHEVE', st['irqs'], st['err'], st['cs'], st['ip']))
