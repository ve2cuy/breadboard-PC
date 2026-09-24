#!/usr/bin/env python3
"""Captures du terminal pour README_fr.md: la ROM reelle (Solution-01/solution-01.asm) executee par le
simulateur tests/rom_sim.py, sa sortie UART rendue par un petit emulateur ANSI puis ecrite en SVG.

Usage (depuis la racine du depot):  python medias/captures/generer.py [--en] [menu basic dos21 dos33]
  --en: ROM anglaise (LANG_EN), fichiers <nom>_en.svg (README_en.md)
Prerequis: ceux de tests/rom_sim.py (unicorn, nasm); images PC-DOS dans PC-DOS/.
"""
import os, re, sys
from xml.sax.saxutils import escape

ICI = os.path.dirname(os.path.abspath(__file__))
DEPOT = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, os.path.join(DEPOT, 'Solution-01', 'tests'))
import rom_sim as S
import subprocess

EN = '--en' in sys.argv
ROM = None                                            # None = ROM francaise assemblee par rom_sim
if EN:
    ROM = os.path.join(DEPOT, 'Solution-01', 'build', 'rom_sim_en.bin')
    subprocess.run(['nasm', '-f', 'bin', '-dLANG_EN=1', '-w-error=label-redef-late', 'solution-01.asm',
                    '-o', ROM], cwd=os.path.join(DEPOT, 'Solution-01'), check=True)


def run(script, **kw):
    return S.run_rom(script, rom=ROM, **kw)

COLS = 80
PALETTE = {30: '#4d4d4d', 31: '#f0605a', 32: '#5fd35f', 33: '#e6c84f', 34: '#6aa7ff', 35: '#d17fe0',
           36: '#4fd2d2', 37: '#d8d8d8'}
FG = '#d8d8d8'


def terminal(data):
    """rejoue les octets UART sur une grille de 80 colonnes; renvoie les lignes [(car, couleur), ...]"""
    lignes, r, c, coul = [[]], 0, 0, FG
    txt = data.decode('cp437')
    i = 0
    while i < len(txt):
        ch = txt[i]
        if ch == '\x1b':
            m = re.match(r'\x1b\[([0-9;?]*)([A-Za-z])', txt[i:])
            if not m:
                i += 1
                continue
            args, cmd = m.group(1), m.group(2)
            i += len(m.group(0))
            nums = [int(x) for x in args.replace('?', '').split(';') if x]
            if cmd == 'm':
                for n in nums or [0]:
                    coul = PALETTE.get(n, FG) if n != 0 else FG
            elif cmd == 'J' and 2 in nums:
                lignes, r, c = [[]], 0, 0
            elif cmd in 'Hf':
                r, c = (nums[0] - 1 if nums else 0), (nums[1] - 1 if len(nums) > 1 else 0)
            elif cmd == 'K':
                del lignes[r][c:]
            continue
        i += 1
        if ch == '\r':
            c = 0
        elif ch == '\n':
            r += 1
        elif ch == '\b':
            c = max(0, c - 1)
        elif ch >= ' ':
            if c >= COLS:
                r, c = r + 1, 0
            while len(lignes) <= r:
                lignes.append([])
            ligne = lignes[r]
            while len(ligne) < c:
                ligne.append((' ', FG))
            if c < len(ligne):
                ligne[c] = (ch, coul)
            else:
                ligne.append((ch, coul))
            c += 1
        while len(lignes) <= r:
            lignes.append([])
    while lignes and not ''.join(ch for ch, _ in lignes[-1]).strip():
        lignes.pop()
    return lignes


def svg(lignes, titre, chemin, depuis=None, hauteur_max=36):
    if depuis:                                        # commence a la derniere ligne contenant `depuis`
        idx = [n for n, l in enumerate(lignes) if any(d in ''.join(ch for ch, _ in l) for d in depuis)]
        lignes = lignes[idx[-1]:] if idx else lignes
    lignes = lignes[-hauteur_max:]
    cw, lh, px, top = 8.4, 18, 16, 44
    w = int(COLS * cw + 2 * px)
    h = int(top + len(lignes) * lh + 16)
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">' % (w, h, w, h),
           '<rect width="100%" height="100%" rx="8" fill="#1e1e1e"/>',
           '<rect width="100%" height="28" rx="8" fill="#323232"/><rect y="20" width="100%" height="8" fill="#323232"/>',
           '<circle cx="18" cy="14" r="5" fill="#ff5f57"/><circle cx="36" cy="14" r="5" fill="#febc2e"/>'
           '<circle cx="54" cy="14" r="5" fill="#28c840"/>',
           '<text x="%d" y="18" fill="#bbbbbb" font-family="Segoe UI, Helvetica, Arial, sans-serif" '
           'font-size="12" text-anchor="middle">%s</text>' % (w // 2, escape(titre)),
           '<g font-family="Cascadia Mono, Consolas, DejaVu Sans Mono, Menlo, monospace" font-size="14" '
           'xml:space="preserve">']
    for n, ligne in enumerate(lignes):
        y = top + n * lh
        col = 0
        while col < len(ligne):                       # une ligne = des passages de meme couleur
            coul = ligne[col][1]
            fin = col
            while fin < len(ligne) and ligne[fin][1] == coul:
                fin += 1
            morceau = ''.join(ch for ch, _ in ligne[col:fin])
            if morceau.strip():
                out.append('<text x="%.1f" y="%d" fill="%s">%s</text>' % (px + col * cw, y, coul, escape(morceau.replace(' ', '\u00a0'))))
            col = fin
    out.append('</g></svg>')
    open(chemin, 'w', encoding='utf-8').write('\n'.join(out))
    print('ecrit', os.path.relpath(chemin, DEPOT), '(%d lignes)' % len(lignes))


def image(nom):
    return open(os.path.join(DEPOT, 'PC-DOS', nom), 'rb').read()


def boot(nom_img):
    return [(S.MENU, b'3'), (b'Boot disk image', b'3'), (b'): ', b'1')]


PROG = [b'10 PRINT "Carres et racines"', b'20 FOR I=1 TO 5', b'30 PRINT I, I*I, SQR(I)', b'40 NEXT',
        b'50 PRINT "PI ="; 4*ATN(1); "  Date: "; DATE$']

CAPTURES = {
    'menu': (('Menu principal', 'Main menu'), None, lambda: run([(S.MENU, b'')], tail_blocks=100_000)),
    'basic': ('BASIC', ('BASIC Version',), lambda: run(
        [(S.MENU, b'1'), (b'2) BASIC', b'2'), (b'Ok', b'\r'.join(PROG) + b'\rRUN\r'), (b'Date:', b''),
         (b'Ok', b'PRINT FRE(0)\r'), (b'Ok', b'')], tail_blocks=100_000)),
    'dos21': ('PC-DOS 2.1', ('Amorce:', 'Boot:'), lambda: run(
        boot('PCDOS2_1.IMG') + [(b'Enter new date: ', b'\r'), (b'Enter new time: ', b'\r'),
                                (b'A>', b'ver\r'), (b'A>', b'dir /w\r'), (b'A>', b'')],
        bridge=S.H.BridgeModel(files={'PCDOS2_1.IMG': image('pcdos2_1.img')}), tail_blocks=200_000)),
    'dos33': ('MS-DOS 3.30', ('Amorce:', 'Boot:'), lambda: run(
        boot('DOS33.IMG') + [(b'(mm-dd-yy): ', b'09-24-2026\r'), (b'time: ', b'\r'),
                             (b'A>', b'ver\r'), (b'A>', b'dir /w\r'), (b'A>', b'')],
        bridge=S.H.BridgeModel(files={'DOS33.IMG': image('Dos33-d1.IMG')}), tail_blocks=200_000)),
}

if __name__ == '__main__':
    for nom in [a for a in sys.argv[1:] if a != '--en'] or list(CAPTURES):
        titre, depuis, lancer = CAPTURES[nom]
        st = lancer()
        if not st['done'] or st['err']:
            print('ECHEC', nom, st['err'], st['out'][-300:])
            continue
        entete = 'Bridge terminal (USB serial port) — ' if EN else 'Terminal du pont (port série USB) — '
        if isinstance(titre, tuple):                  # (francais, anglais)
            titre = titre[1] if EN else titre[0]
        svg(terminal(st['out']), entete + titre, os.path.join(ICI, nom + ('_en' if EN else '') + '.svg'), depuis)
