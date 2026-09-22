#!/usr/bin/env python3
# ============================================================
# rom_map.py - plan (MAP) de la ROM et espace disponible.
#
# Assemble solution-01.asm avec un listing (build/rom.lst) puis relit, pour chaque
# module inclus, le decalage du premier octet qu'il genere. Affiche, pour la ROM de 256 Ko
# (physique C0000h-FFFFFh): les zones (adresse, taille, pourcentage), le detail du BASIC,
# l'espace libre avant le vecteur de reset et un histogramme.
#
# Usage (depuis la racine de Solution-01):  python3 rom_map.py      ou      make map
# ============================================================
import os
import re
import subprocess
import sys

ROM_BASE = 0xC0000
ROM_SIZE = 0x40000
RESET_OFF = 0x3FFF0            # vecteur de reset (16 derniers octets)
LST = 'build/rom.lst'
BIN = 'build/rom_map.bin'

# (nom affiche, expression reguliere de la ligne %include dans le listing, niveau d'imbrication)
MODULES = [
    ('lib/common.asm',      r'^\s*\d+\s+%include "lib/common\.asm"'),
    ('lib/lcd.asm',         r'^\s*\d+\s+%include "lib/lcd\.asm"'),
    ('lib/uart.asm',        r'^\s*\d+\s+%include "lib/uart\.asm"'),
    ('lib/utils.asm',       r'^\s*\d+\s+%include "lib/utils\.asm"'),
    ('lib/lcd_i2c.asm',     r'^\s*\d+\s+%include "lib/lcd_i2c\.asm"'),
    ('lib/ps2.asm',         r'^\s*\d+\s+%include "lib/ps2\.asm"'),
    ('lib/bridge.asm',      r'^\s*\d+\s+%include "lib/bridge\.asm"'),
    ('lib/isr.asm (ISR IRQ1)', r'^\s*\d+\s+%include "lib/isr\.asm"'),
    ('lib/bios.asm (BIOS pour DOS: INT 13h, 16h, 1Ah, 19h...)', r'^\s*\d+\s+%include "lib/bios\.asm"'),
    ('lib/tiny_basic.asm',  r'^\s*\d+\s+%include "lib/tiny_basic\.asm"'),
    ('lib/basic.asm (noyau: E/S, jetons, tokeniseur, erreurs)', r'^\s*\d+\s+%include "lib/basic\.asm"'),
]
BASIC_PARTS = [
    ('basic_float.asm  (flottants IEEE-754 32 bits)', r'<1>\s+%include "lib/basic_float\.asm"'),
    ('basic_fmath.asm  (SQR SIN COS TAN ATN LOG EXP)', r'<1>\s+%include "lib/basic_fmath\.asm"'),
    ('basic_eval.asm   (expressions, variables)', r'<1>\s+%include "lib/basic_eval\.asm"'),
    ('basic_str.asm    (chaines, ramasse-miettes)', r'<1>\s+%include "lib/basic_str\.asm"'),
    ('basic_stmt.asm   (instructions, INPUT, EDIT)', r'<1>\s+%include "lib/basic_stmt\.asm"'),
    ('basic_func.asm   (fonctions, horloge)', r'<1>\s+%include "lib/basic_func\.asm"'),
    ('basic_disk.asm   (disque, fichiers, secteurs, USB)', r'<1>\s+%include "lib/basic_disk\.asm"'),
    ('basic_data.asm   (messages, aide, tables)', r'<1>\s+%include "lib/basic_data\.asm"'),
]


def fmt(n):
    return '%7d o  %6.1f Ko' % (n, n / 1024.0)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)
    os.makedirs('build', exist_ok=True)
    r = subprocess.run(['nasm', '-f', 'bin', 'solution-01.asm', '-o', BIN, '-l', LST],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr)
        sys.exit(1)
    lines = open(LST, encoding='utf-8', errors='replace').read().split('\n')
    off_re = re.compile(r'^\s*\d+\s+([0-9A-F]{8})\s')

    def next_offset(i):
        for j in range(i + 1, min(i + 4000, len(lines))):
            m = off_re.match(lines[j])
            if m:
                return int(m.group(1), 16)
        return None

    def find(rx, first_only=True):
        pat = re.compile(rx)
        for i, l in enumerate(lines):
            if pat.search(l):
                return next_offset(i)
        return None

    # fin du contenu: la ligne "times 03FFF0h - ..." porte le decalage de la fin du code/donnees
    end_off = None
    for i, l in enumerate(lines):
        if re.search(r'times\s+03FFF0h', l):
            m = off_re.match(l)
            end_off = int(m.group(1), 16) if m else next_offset(i)
            break
    data = open(BIN, 'rb').read()
    assert len(data) == ROM_SIZE, len(data)
    # (le remplissage est 0FFh: derniere octet different de 0FFh avant le vecteur de reset)
    last = RESET_OFF - 1
    while last > 0 and data[last] == 0xFF:
        last -= 1
    if end_off is None:
        end_off = last + 1

    starts = [('solution-01.asm (menu, POST, tests RAM, editeur, IVT, ISR)', 0)]
    for name, rx in MODULES:
        o = find(rx)
        if o is not None:
            starts.append((name, o))
    starts.append(('(fin du contenu)', end_off))
    starts.sort(key=lambda t: t[1])

    print('=' * 78)
    print(' PLAN DE LA ROM VE2CUY - 256 Ko, physique %05Xh-%05Xh (solution-01.bin)' % (ROM_BASE, ROM_BASE + ROM_SIZE - 1))
    print('=' * 78)
    print(' %-9s %-9s %-19s %-6s %s' % ('Adresse', 'Decalage', 'Taille', '%ROM', 'Zone'))
    print(' ' + '-' * 76)
    rows = []
    for k in range(len(starts) - 1):
        name, o = starts[k]
        size = starts[k + 1][1] - o
        rows.append((name, o, size))
    for name, o, size in rows:
        print(' %05Xh    %06Xh   %s %5.1f%%  %s' % (ROM_BASE + o, o, fmt(size), 100.0 * size / ROM_SIZE, name))
    used = end_off
    free = RESET_OFF - end_off
    print(' ' + '-' * 76)
    print(' %05Xh    %06Xh   %s %5.1f%%  LIBRE (remplissage 0FFh)' % (ROM_BASE + end_off, end_off, fmt(free), 100.0 * free / ROM_SIZE))
    print(' %05Xh    %06Xh   %s %5.1f%%  vecteur de reset + signature' % (ROM_BASE + RESET_OFF, RESET_OFF, fmt(ROM_SIZE - RESET_OFF), 100.0 * (ROM_SIZE - RESET_OFF) / ROM_SIZE))
    print(' ' + '-' * 76)
    print(' UTILISE : %s (%.1f%%)   LIBRE : %s (%.1f%%)   TOTAL : %d Ko' % (
        fmt(used).strip(), 100.0 * used / ROM_SIZE, fmt(free).strip(), 100.0 * free / ROM_SIZE, ROM_SIZE // 1024))

    # detail du BASIC
    bstart = None
    for name, o, size in rows:
        if name.startswith('lib/basic.asm'):
            bstart = o
    parts = []
    for name, rx in BASIC_PARTS:
        o = find(rx)
        if o is not None:
            parts.append((name, o))
    if bstart is not None and parts:
        parts.sort(key=lambda t: t[1])
        # fin de basic_data = fin du contenu; le noyau va de bstart au premier module
        print()
        print(' DETAIL DU BASIC (lib/basic.asm et ses modules)')
        print(' ' + '-' * 76)
        core = parts[0][1] - bstart
        print(' %05Xh    %06Xh   %s   noyau (E/S, jetons, tokeniseur, erreurs, HIST)' % (ROM_BASE + bstart, bstart, fmt(core)))
        tot = core
        for k, (name, o) in enumerate(parts):
            e = parts[k + 1][1] if k + 1 < len(parts) else end_off
            print(' %05Xh    %06Xh   %s   %s' % (ROM_BASE + o, o, fmt(e - o), name))
            tot += e - o
        print(' ' + '-' * 76)
        print(' BASIC total: %s' % fmt(tot).strip())

    # histogramme (64 cases de 4 Ko)
    print()
    print(' HISTOGRAMME (1 case = 4 Ko ; # = utilise, . = libre, R = reset)')
    cells = ROM_SIZE // 4096
    bar = ''
    for c in range(cells):
        a, b = c * 4096, (c + 1) * 4096
        if a <= RESET_OFF < b:
            ch = 'R'
        elif a < end_off:
            ch = '#'
        else:
            ch = '.'
        bar += ch
        if (c + 1) % 32 == 0:
            print('  %05Xh %s' % (ROM_BASE + (c - 31) * 4096, bar))
            bar = ''
    print()
    print(' Espace libre contigu: %d octets (%.1f Ko) de %05Xh a %05Xh' % (free, free / 1024.0, ROM_BASE + end_off, ROM_BASE + RESET_OFF - 1))


if __name__ == '__main__':
    main()
