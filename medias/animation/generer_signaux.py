#!/usr/bin/env python3
"""Genere l'animation SVG des signaux du montage (FR et EN):
   medias/animation/signaux-anime.svg et medias/animation/signals-animated.svg.

Huit etats, du RESET a la lecture d'un secteur par le DOS: blocs du montage mis en evidence,
jetons qui circulent sur les liaisons, niveau des signaux de commande et carte de la memoire.
Animation SMIL (opacite discrete), sans script: s'affiche dans GitHub et dans un navigateur.
Decodage d'apres le schema KiCad: ROM CE# = NAND(A19, M), RAM CE# = NAND(/A19, M) (74LS00 IC-6,
M = NOT IO/M), 8255 CS# = NAND(IO, A7), 8259 CS# = NAND(IO, A5) (74LS00 U9).

Usage: python3 medias/animation/generer_signaux.py
"""
import os
from xml.sax.saxutils import escape

W, H = 1000, 790
N = 8                       # etats
DUREE = 6                   # secondes par etat
DUR = '%ds' % (N * DUREE)
KT = ';'.join('%.4f' % (i / N) for i in range(N))

BLEU, VERT, ORANGE, ROUGE, GRIS = '#1d3f8a', '#2e7d32', '#d08a1a', '#c0392b', '#9e9e9e'
FOND_BLOC, TRAIT = '#f4f6fb', '#7d8aa8'

# ------------------------------------------------------------------ textes
T = {
    'fr': {
        'titre': 'breadboard-PC : les signaux du montage, du RESET au DOS',
        'etat': 'état',
        'cpu': ['Intel 8088', 'mode minimum', '4,77 à 7,38 MHz'],
        'latch': ['74LS373 ×2', 'A0–A7, A16–A19'],
        'buf': ['74HC245', 'D0–D7'],
        'dec': ['Décodage (74LS00 ×2)', 'ROM  CE# = NAND(A19, M)', 'RAM  CE# = NAND(/A19, M)',
                '8255 CS# = NAND(IO, A7)', '8259 CS# = NAND(IO, A5)', 'M = cycle mémoire (IO/M = 0)'],
        'rom': ['ROM 256 Ko', 'W29C020C', 'C0000h–FFFFFh'],
        'ram': ['RAM 512 Ko', 'AS6C4008', '00000h–7FFFFh'],
        'pio': ['8255A mode 2', 'ports 80h–83h'],
        'pic': ['8259A', 'ports 20h–21h'],
        'pont': ['Pont', 'STM32F411', 'Black Pill', 'firmware 1.6'],
        'ps2': 'Clavier PS/2', 'term': 'Terminal (USB)', 'flash': 'Flash 8 Mo FAT', 'lcd': 'LCD 4×20 I2C',
        'adr': 'adresses', 'don': 'données', 'porta': 'port A + STB#/ACK#', 'intr': 'INTR / INTA#',
        'rst': 'RESET, CLK', 'ir1': 'IR1',
        'sig_titre': 'Signaux (# = actif à 0)', 'carte_titre': 'Carte de la mémoire',
        'carte': [('C0000h–FFFFFh', 'ROM : BIOS, menu, BASIC', 'FFFF0h : vecteur de reset'),
                  ('80000h–BFFFFh', 'aucun circuit', ''),
                  ('70000h–7FFFFh', 'micrologiciel', 'pile et variables : 7000:F800–FFFF'),
                  ('00500h–6FFFFh', 'DOS, programmes', 'tampons de secteurs'),
                  ('00400h–004FFh', 'données du BIOS', ''),
                  ('00000h–003FFh', 'IVT : 256 vecteurs', 'INT 09h en 0024h, INT 13h en 004Ch')],
        'etats': [
            ('RESET', 'Le pont tient RESET à 1 (PB2) : au démarrage, puis pour Ctrl-Alt-Suppr ou Ctrl-\\. '
             'Au relâchement, le 8088 part de FFFF:0000 = FFFF0h, tout en haut de la ROM.'),
            ('Lecture du vecteur de reset', 'Cycle mémoire (IO/M = 0) : ALE verrouille FFFF0h dans les 74LS373. A19 = 1, '
             'donc ROM CE# = NAND(A19, M) = 0 ; RD# lit JMP C000:0000 à travers le 74HC245.'),
            ('Écriture en RAM', 'Le BIOS efface la RAM et place sa pile et ses variables en 7000:F800–FFFF. '
             'A19 = 0, donc RAM CE# = NAND(/A19, M) = 0 ; WR# écrit l\'octet.'),
            ('Programmation du 8259 et de l\'IVT', 'OUT 20h/21h : cycle d\'E/S (IO/M = 1), A5 = 1, donc 8259 CS# = 0 '
             '(ICW1–ICW4 : vecteurs 08h–0Fh, front, EOI manuel). Puis les vecteurs du BIOS sont écrits dans l\'IVT.'),
            ('Une touche au clavier', 'Le pont décode la trame PS/2 et dépose le code dans le port A du 8255 (STB#). '
             'IBF et INTR passent à 1 : IR1 du 8259, qui lève INTR vers le 8088.'),
            ('IRQ1 : INT 09h', 'Deux impulsions INTA# : le 8259 donne le vecteur 09h. Le 8088 lit l\'IVT en 0000:0024 (RAM), '
             'saute dans la ROM : IN 82h (état), IN 80h (octet ; 8255 CS# = NAND(IO, A7)), puis EOI (OUT 20h).'),
            ('Le DOS appelle le BIOS : INT 13h', 'IVT en 0000:004C, puis le BIOS en ROM masque IR1 et envoie la commande : '
             'OUT 80h (OBF#), le pont lit l\'octet (ACK#) et lit le secteur dans l\'image .IMG de sa flash.'),
            ('Réponse en rafale', 'Le pont renvoie les 512 octets en rafale (STB#). Le BIOS scrute IBF (IN 82h), lit chaque '
             'octet (IN 80h) et l\'écrit dans le tampon du DOS en RAM (WR#). Somme de contrôle, IR1 démasquée, IRET.'),
        ],
    },
    'en': {
        'titre': 'breadboard-PC: the signals of the build, from RESET to DOS',
        'etat': 'state',
        'cpu': ['Intel 8088', 'minimum mode', '4.77 to 7.38 MHz'],
        'latch': ['74LS373 ×2', 'A0–A7, A16–A19'],
        'buf': ['74HC245', 'D0–D7'],
        'dec': ['Decoding (74LS00 ×2)', 'ROM  CE# = NAND(A19, M)', 'RAM  CE# = NAND(/A19, M)',
                '8255 CS# = NAND(IO, A7)', '8259 CS# = NAND(IO, A5)', 'M = memory cycle (IO/M = 0)'],
        'rom': ['ROM 256 KB', 'W29C020C', 'C0000h–FFFFFh'],
        'ram': ['RAM 512 KB', 'AS6C4008', '00000h–7FFFFh'],
        'pio': ['8255A mode 2', 'ports 80h–83h'],
        'pic': ['8259A', 'ports 20h–21h'],
        'pont': ['Bridge', 'STM32F411', 'Black Pill', 'firmware 1.6'],
        'ps2': 'PS/2 keyboard', 'term': 'Terminal (USB)', 'flash': '8 MB FAT flash', 'lcd': '4×20 I2C LCD',
        'adr': 'address', 'don': 'data', 'porta': 'port A + STB#/ACK#', 'intr': 'INTR / INTA#',
        'rst': 'RESET, CLK', 'ir1': 'IR1',
        'sig_titre': 'Signals (# = active low)', 'carte_titre': 'Memory map',
        'carte': [('C0000h–FFFFFh', 'ROM: BIOS, menu, BASIC', 'FFFF0h: reset vector'),
                  ('80000h–BFFFFh', 'nothing wired', ''),
                  ('70000h–7FFFFh', 'firmware', 'stack and variables: 7000:F800–FFFF'),
                  ('00500h–6FFFFh', 'DOS, programs', 'sector buffers'),
                  ('00400h–004FFh', 'BIOS data area', ''),
                  ('00000h–003FFh', 'IVT: 256 vectors', 'INT 09h at 0024h, INT 13h at 004Ch')],
        'etats': [
            ('RESET', 'The bridge holds RESET high (PB2): at power-up, then for Ctrl-Alt-Del or Ctrl-\\. '
             'When released, the 8088 starts at FFFF:0000 = FFFF0h, at the very top of the ROM.'),
            ('Fetching the reset vector', 'Memory cycle (IO/M = 0): ALE latches FFFF0h into the 74LS373s. A19 = 1, '
             'so ROM CE# = NAND(A19, M) = 0; RD# reads JMP C000:0000 through the 74HC245.'),
            ('Writing to RAM', 'The BIOS clears the RAM and puts its stack and variables at 7000:F800–FFFF. '
             'A19 = 0, so RAM CE# = NAND(/A19, M) = 0; WR# writes the byte.'),
            ('Programming the 8259 and the IVT', 'OUT 20h/21h: I/O cycle (IO/M = 1), A5 = 1, so 8259 CS# = 0 '
             '(ICW1–ICW4: vectors 08h–0Fh, edge, manual EOI). Then the BIOS vectors are written to the IVT.'),
            ('A key is pressed', 'The bridge decodes the PS/2 frame and drops the code into port A of the 8255 (STB#). '
             'IBF and INTR go high: IR1 of the 8259, which raises INTR to the 8088.'),
            ('IRQ1: INT 09h', 'Two INTA# pulses: the 8259 supplies vector 09h. The 8088 reads the IVT at 0000:0024 (RAM), '
             'jumps into the ROM: IN 82h (status), IN 80h (byte; 8255 CS# = NAND(IO, A7)), then EOI (OUT 20h).'),
            ('DOS calls the BIOS: INT 13h', 'IVT at 0000:004C, then the BIOS in ROM masks IR1 and sends the command: '
             'OUT 80h (OBF#), the bridge reads the byte (ACK#) and reads the sector from the .IMG file on its flash.'),
            ('Burst reply', 'The bridge sends the 512 bytes back in a burst (STB#). The BIOS polls IBF (IN 82h), reads each '
             'byte (IN 80h) and writes it to the DOS buffer in RAM (WR#). Checksum, IR1 unmasked, IRET.'),
        ],
    },
}

# ------------------------------------------------------------------ geometrie
B = {   # blocs: x, y, w, h
    'cpu': (30, 190, 150, 230), 'latch': (210, 180, 130, 46), 'buf': (210, 240, 130, 42),
    'dec': (210, 300, 160, 120),
    'rom': (420, 175, 180, 52), 'ram': (420, 240, 180, 52), 'pio': (420, 305, 180, 52), 'pic': (420, 370, 180, 50),
    'pont': (650, 250, 150, 120),
    'ps2': (835, 180, 140, 36), 'term': (835, 235, 140, 36), 'flash': (835, 290, 140, 36), 'lcd': (835, 345, 140, 36),
}
LIENS = {   # chemins des jetons (SVG path d)
    'rst': 'M 725 250 L 725 165 L 105 165 L 105 190',
    'adr_rom': 'M 180 203 L 210 203 L 340 203 L 385 203 L 385 201 L 420 201',
    'adr_ram': 'M 180 203 L 210 203 L 340 203 L 385 203 L 385 266 L 420 266',
    'don_rom': 'M 420 214 L 400 214 L 400 261 L 340 261 L 210 261 L 180 261',
    'don_ram_w': 'M 180 261 L 210 261 L 340 261 L 400 261 L 400 276 L 420 276',
    'io_pic': 'M 180 261 L 210 261 L 340 261 L 400 261 L 400 395 L 420 395',
    'adr_pic': 'M 180 203 L 210 203 L 340 203 L 385 203 L 385 385 L 420 385',
    'cle': 'M 835 198 L 815 198 L 815 300 L 800 300 L 650 330 L 600 330',
    'pio_pic': 'M 510 357 L 510 370',
    'pic_cpu': 'M 510 420 L 510 440 L 105 440 L 105 420',
    'pio_cpu': 'M 420 340 L 400 340 L 400 261 L 340 261 L 210 261 L 180 261',
    'cpu_pio': 'M 180 261 L 210 261 L 340 261 L 400 261 L 400 320 L 420 320',
    'pio_pont': 'M 600 330 L 650 330',
    'pont_flash': 'M 800 310 L 835 308',
    'flash_pont': 'M 835 308 L 800 310',
    'pont_pio': 'M 650 330 L 600 330',
    'ivt_rd': 'M 420 270 L 400 270 L 400 261 L 340 261 L 210 261 L 180 261',
}

# etats: blocs en evidence (couleur), jetons (chemin, couleur, retard), signaux, zones de la carte
SIGNAUX = ['RESET', 'ALE', 'IO/M', 'A19', 'RD#', 'WR#', 'ROM CE#', 'RAM CE#', '8255 CS#', '8259 CS#',
           'IR1 (INTR 8255)', 'INTR', 'INTA#', 'STB# (pont)']
#            RESET ALE  IO/M A19  RD#  WR#  ROM  RAM  8255 8259 IR1  INTR INTA STB
V = [
    ['1*', '0', '–', '–', '1', '1', '1', '1', '1', '1', '0', '0', '1', '1'],
    ['0', '⊓*', '0*', '1*', '0*', '1', '0*', '1', '1', '1', '0', '0', '1', '1'],
    ['0', '⊓*', '0*', '0*', '1', '0*', '1', '0*', '1', '1', '0', '0', '1', '1'],
    ['0', '⊓*', '1*', '0', '1', '0*', '1', '1', '1', '0*', '0', '0', '1', '1'],
    ['0', '0', '–', '–', '1', '1', '1', '1', '1', '1', '1*', '1*', '1', '⊔*'],
    ['0', '⊓*', '1*', '0', '0*', '1', '1', '0*', '0*', '1', '1→0*', '1→0*', '⊔⊔*', '1'],
    ['0', '⊓*', '1*', '0', '1', '0*', '1', '0*', '0*', '1', '0', '0', '1', '1'],
    ['0', '⊓*', '1/0*', '0', '0*', '0*', '1', '0*', '0*', '1', '–', '0', '1', '⊔⊔⊔*'],
]
ETATS = [
    dict(blocs={'pont': ORANGE, 'cpu': ORANGE}, jetons=[('rst', ROUGE, 0)], carte=[0]),
    dict(blocs={'cpu': BLEU, 'latch': BLEU, 'dec': BLEU, 'rom': VERT, 'buf': BLEU},
         jetons=[('adr_rom', BLEU, 0), ('don_rom', VERT, 0.9)], carte=[0], dec=1),
    dict(blocs={'cpu': BLEU, 'latch': BLEU, 'dec': BLEU, 'ram': VERT, 'buf': BLEU},
         jetons=[('adr_ram', BLEU, 0), ('don_ram_w', ORANGE, 0.9)], carte=[2], dec=2),
    dict(blocs={'cpu': BLEU, 'latch': BLEU, 'dec': BLEU, 'pic': VERT, 'ram': VERT, 'buf': BLEU},
         jetons=[('adr_pic', BLEU, 0), ('io_pic', ORANGE, 0.9), ('don_ram_w', ORANGE, 1.8)], carte=[5], dec=4),
    dict(blocs={'ps2': ORANGE, 'pont': ORANGE, 'pio': VERT, 'pic': VERT, 'cpu': ROUGE},
         jetons=[('cle', ORANGE, 0), ('pio_pic', ROUGE, 1.2), ('pic_cpu', ROUGE, 1.5)], carte=[]),
    dict(blocs={'cpu': BLEU, 'pic': VERT, 'ram': VERT, 'rom': VERT, 'pio': VERT, 'dec': BLEU},
         jetons=[('pic_cpu', ROUGE, 0), ('ivt_rd', VERT, 0.8), ('pio_cpu', ORANGE, 1.6)], carte=[5, 0], dec=3),
    dict(blocs={'cpu': BLEU, 'ram': VERT, 'rom': VERT, 'pio': VERT, 'pont': ORANGE, 'flash': ORANGE, 'dec': BLEU},
         jetons=[('ivt_rd', VERT, 0), ('cpu_pio', ORANGE, 0.8), ('pio_pont', ORANGE, 1.4), ('pont_flash', ORANGE, 1.8)],
         carte=[5, 0], dec=3),
    dict(blocs={'flash': ORANGE, 'pont': ORANGE, 'pio': VERT, 'cpu': BLEU, 'ram': VERT, 'dec': BLEU, 'buf': BLEU},
         jetons=[('flash_pont', ORANGE, 0), ('pont_pio', ORANGE, 0.3), ('pio_cpu', ORANGE, 0.6),
                 ('don_ram_w', VERT, 1.2), ('pont_pio', ORANGE, 0.9), ('pio_cpu', ORANGE, 1.5)], carte=[3], dec=3),
]


def vis(i):
    """valeurs d'opacite: visible seulement a l'etat i"""
    return ';'.join('1' if k == i else '0' for k in range(N))


def anim(i):
    return ('<animate attributeName="opacity" calcMode="discrete" dur="%s" repeatCount="indefinite" '
            'keyTimes="%s" values="%s"/>' % (DUR, KT, vis(i)))


FIGE = os.environ.get('ETAT')   # ETAT=k: image fixe de l'etat k (verification), sans animation d'opacite


def groupe(i, contenu):
    if FIGE is not None:
        return '<g opacity="%d">%s</g>' % (1 if i == int(FIGE) - 1 else 0, contenu)
    return '<g opacity="%d">%s%s</g>' % (1 if i == 0 else 0, anim(i), contenu)


def txt(x, y, s, taille=13, coul='#333', ancre='middle', gras=False, mono=False):
    return ('<text x="%g" y="%g" text-anchor="%s" fill="%s" font-size="%g"%s%s>%s</text>'
            % (x, y, ancre, coul, taille, ' font-weight="bold"' if gras else '',
               ' font-family="Consolas, Menlo, monospace"' if mono else '', escape(s)))


def bloc(nom, lignes, haut=False):
    x, y, w, h = B[nom]
    out = ['<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s" stroke="%s"/>' % (x, y, w, h, FOND_BLOC, TRAIT)]
    if isinstance(lignes, str):
        lignes = [lignes]
    pas = 15
    y0 = y + 26 if haut else y + h / 2 - (len(lignes) - 1) * pas / 2 + 5
    for k, l in enumerate(lignes):
        out.append(txt(x + w / 2, y0 + k * pas, l, 13 if k == 0 else 11, BLEU if k == 0 else '#444', gras=(k == 0)))
    return ''.join(out)


def generer(lang, chemin):
    t = T[lang]
    o = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" font-family="Helvetica, Arial, sans-serif" '
         'font-size="14" role="img" aria-labelledby="t d">' % (W, H)]
    o.append('<title id="t">%s</title>' % escape(t['titre']))
    o.append('<desc id="d">%s</desc>' % escape(' '.join('%d. %s.' % (k + 1, e[0]) for k, e in enumerate(t['etats']))))
    o.append('<rect width="%d" height="%d" rx="12" fill="#ffffff"/>' % (W, H))
    o.append(txt(W / 2, 34, t['titre'], 19, BLEU, gras=True))
    # barre des etats
    lb, gap = 101, 6
    x0 = (W - N * lb) / 2
    for i in range(N):
        x = x0 + i * lb
        coul = [ORANGE, BLEU, BLEU, BLEU, ORANGE, ROUGE, BLEU, VERT][i]
        o.append('<rect x="%g" y="50" width="%d" height="8" rx="4" fill="#e2e2e2"/>' % (x, lb - gap))
        o.append(groupe(i, '<rect x="%g" y="50" width="%d" height="8" rx="4" fill="%s"/>' % (x, lb - gap, coul)))
        o.append(txt(x + (lb - gap) / 2, 74, '%s %d' % (t['etat'], i + 1), 11, '#666'))
    # encadre d'explication
    o.append('<rect x="30" y="86" width="940" height="66" rx="10" fill="#f7f7f7" stroke="#cccccc"/>')
    for i, (titre, texte) in enumerate(t['etats']):
        lignes = couper(texte, 150)
        c = txt(50, 110, '%d · %s' % (i + 1, titre), 16, BLEU, 'start', True)
        for k, l in enumerate(lignes[:2]):
            c += txt(50, 130 + k * 16, l, 12.5, '#333', 'start')
        o.append(groupe(i, c))
    # liaisons fixes
    traits = [
        'M 180 203 L 210 203', 'M 340 203 L 385 203 L 385 385 L 420 385', 'M 385 201 L 420 201', 'M 385 266 L 420 266',
        'M 385 320 L 420 320',
        'M 180 261 L 210 261', 'M 340 261 L 400 261 L 400 395 L 420 395', 'M 400 214 L 420 214', 'M 400 276 L 420 276',
        'M 400 340 L 420 340',
        'M 600 330 L 650 330', 'M 510 357 L 510 370', 'M 510 420 L 510 440 L 105 440 L 105 420',
        'M 725 250 L 725 165 L 105 165 L 105 190',
        'M 800 270 L 815 270 L 815 198 L 835 198', 'M 800 253 L 835 253', 'M 800 310 L 835 308', 'M 800 355 L 815 355 L 815 363 L 835 363',
    ]
    for d in traits:
        o.append('<path d="%s" fill="none" stroke="#b9c1d6" stroke-width="2.5"/>' % d)
    o.append(txt(360, 196, t['adr'], 10, '#777'))
    o.append(txt(370, 254, t['don'], 10, '#777'))
    o.append(txt(625, 322, 'port A', 10, '#777'))
    o.append(txt(626, 348, 'STB#/ACK#', 8.5, '#777'))
    o.append(txt(522, 367, t['ir1'], 10, '#777', 'start'))
    o.append(txt(300, 454, t['intr'], 10, '#777'))
    o.append(txt(420, 160, t['rst'], 10, '#777'))
    # blocs
    o.append(bloc('cpu', t['cpu'], haut=True))
    cx, cy = B['cpu'][0], B['cpu'][1]
    for k, p in enumerate(['AD0–AD7', 'A8–A15', 'A16–A19', 'ALE', 'IO/M', 'RD#', 'WR#', 'INTR', 'INTA#', 'RESET']):
        o.append(txt(cx + 142, cy + 80 + k * 14.5, p, 10, '#666', 'end', mono=True))
    o.append(bloc('latch', t['latch']))
    o.append(bloc('buf', t['buf']))
    x, y, w, h = B['dec']
    o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s" stroke="%s"/>' % (x, y, w, h, FOND_BLOC, TRAIT))
    o.append(txt(x + w / 2, y + 18, t['dec'][0], 12, BLEU, gras=True))
    for k, l in enumerate(t['dec'][1:5]):
        o.append(txt(x + 8, y + 38 + k * 17, l, 10.5, '#333', 'start', mono=True))
    o.append(txt(x + w / 2, y + h - 6, t['dec'][5], 9.5, '#666'))
    for nom in ('rom', 'ram', 'pio', 'pic', 'pont'):
        o.append(bloc(nom, t[nom]))
    for nom in ('ps2', 'term', 'flash', 'lcd'):
        o.append(bloc(nom, t[nom]))
    # mises en evidence et jetons, par etat
    for i, e in enumerate(ETATS):
        c = ''
        for nom, coul in e['blocs'].items():
            x, y, w, h = B[nom]
            c += ('<rect x="%d" y="%d" width="%d" height="%d" rx="8" fill="%s" fill-opacity="0.10" stroke="%s" '
                  'stroke-width="3"/>' % (x - 2, y - 2, w + 4, h + 4, coul, coul))
        if 'dec' in e:
            x, y, w, h = B['dec']
            k = e['dec'] - 1
            c += ('<rect x="%d" y="%d" width="%d" height="15" rx="3" fill="%s" fill-opacity="0.18"/>'
                  % (x + 4, y + 27 + k * 17, w - 8, VERT))
        for chemin_id, coul, retard in e['jetons']:
            c += ('<circle r="6" fill="%s" stroke="#fff" stroke-width="1.5"><animateMotion dur="2.4s" begin="%gs" '
                  'repeatCount="indefinite" path="%s"/></circle>' % (coul, retard, LIENS[chemin_id]))
        o.append(groupe(i, c))
    # panneau des signaux
    px, py, pw, ph = 30, 470, 520, 305
    o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="#fafbfd" stroke="#cccccc"/>' % (px, py, pw, ph))
    o.append(txt(px + 16, py + 24, t['sig_titre'], 14, BLEU, 'start', True))
    for r, nom in enumerate(SIGNAUX):
        yy = py + 50 + r * 18
        if r % 2 == 0:
            o.append('<rect x="%d" y="%d" width="%d" height="18" fill="#eef1f7"/>' % (px + 8, yy - 13, pw - 16))
        o.append(txt(px + 18, yy, nom, 12, '#333', 'start', mono=True))
    for i in range(N):
        c = ''
        for r, val in enumerate(V[i]):
            yy = py + 50 + r * 18
            actif = val.endswith('*')
            v = val.rstrip('*')
            if actif:
                c += ('<rect x="%d" y="%d" width="120" height="15" rx="7" fill="%s" fill-opacity="0.18"/>'
                      % (px + 300, yy - 12, VERT))
            c += txt(px + 360, yy, v, 12.5, VERT if actif else GRIS, gras=actif, mono=True)
        o.append(groupe(i, c))
    # carte de la memoire
    mx, my, mw, mh = 580, 470, 390, 305
    o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="#fafbfd" stroke="#cccccc"/>' % (mx, my, mw, mh))
    o.append(txt(mx + 16, my + 24, t['carte_titre'], 14, BLEU, 'start', True))
    haut = [50, 26, 44, 42, 24, 42]
    couls = ['#dfe8f7', '#f0f0f0', '#fbe9d0', '#e3f1e4', '#eeeeee', '#f6dede']
    zones = []
    yy = my + 38
    for k, (adr, nom, det) in enumerate(t['carte']):
        hh = haut[k]
        o.append('<rect x="%d" y="%d" width="%d" height="%d" fill="%s" stroke="#bbbbbb"/>' % (mx + 14, yy, mw - 28, hh, couls[k]))
        o.append(txt(mx + 24, yy + 16, adr, 11, '#555', 'start', mono=True))
        o.append(txt(mx + 140, yy + 16, nom, 12.5, '#222', 'start', True))
        if det:
            o.append(txt(mx + 140, yy + 32, det, 10.5, '#555', 'start'))
        zones.append((yy, hh))
        yy += hh + 4
    for i, e in enumerate(ETATS):
        c = ''
        for k in e['carte']:
            zy, zh = zones[k]
            c += ('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="3.5" rx="3"/>'
                  % (mx + 12, zy - 2, mw - 24, zh + 4, ROUGE))
            c += '<path d="M %d %d l -12 -7 l 0 14 z" fill="%s"/>' % (mx + 10, zy + zh / 2, ROUGE)
        o.append(groupe(i, c))
    o.append('</svg>')
    os.makedirs(os.path.dirname(chemin), exist_ok=True)
    with open(chemin, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(o) + '\n')


def couper(s, n):
    mots, lignes, cur = s.split(), [], ''
    for m in mots:
        if len(cur) + len(m) + 1 > n:
            lignes.append(cur)
            cur = m
        else:
            cur = (cur + ' ' + m).strip()
    lignes.append(cur)
    return lignes


if __name__ == '__main__':
    ici = os.path.dirname(os.path.abspath(__file__))
    generer('fr', os.path.join(ici, 'signaux-anime.svg'))
    generer('en', os.path.join(ici, 'signals-animated.svg'))
    print('ok')
