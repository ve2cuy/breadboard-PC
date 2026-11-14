#!/usr/bin/env python3
"""Genere clavier_us.inc : tables de conversion des codes de touche PS/2 (jeu 2) en ASCII,
disposition US (QWERTY), 132 entrees (codes 00h-83h), sans et avec Maj.
Usage : python tests/gen_clavier.py > clavier_us.inc"""

# code : (normal, avec Maj) ; 0 = touche sans caractere
TOUCHES = {
    0x0D: ('\t', '\t'), 0x0E: ('`', '~'), 0x15: ('q', 'Q'), 0x16: ('1', '!'), 0x1A: ('z', 'Z'),
    0x1B: ('s', 'S'), 0x1C: ('a', 'A'), 0x1D: ('w', 'W'), 0x1E: ('2', '@'), 0x21: ('c', 'C'),
    0x22: ('x', 'X'), 0x23: ('d', 'D'), 0x24: ('e', 'E'), 0x25: ('4', '$'), 0x26: ('3', '#'),
    0x29: (' ', ' '), 0x2A: ('v', 'V'), 0x2B: ('f', 'F'), 0x2C: ('t', 'T'), 0x2D: ('r', 'R'),
    0x2E: ('5', '%'), 0x31: ('n', 'N'), 0x32: ('b', 'B'), 0x33: ('h', 'H'), 0x34: ('g', 'G'),
    0x35: ('y', 'Y'), 0x36: ('6', '^'), 0x3A: ('m', 'M'), 0x3B: ('j', 'J'), 0x3C: ('u', 'U'),
    0x3D: ('7', '&'), 0x3E: ('8', '*'), 0x41: (',', '<'), 0x42: ('k', 'K'), 0x43: ('i', 'I'),
    0x44: ('o', 'O'), 0x45: ('0', ')'), 0x46: ('9', '('), 0x49: ('.', '>'), 0x4A: ('/', '?'),
    0x4B: ('l', 'L'), 0x4C: (';', ':'), 0x4D: ('p', 'P'), 0x4E: ('-', '_'), 0x52: ("'", '"'),
    0x54: ('[', '{'), 0x55: ('=', '+'), 0x5A: ('\r', '\r'), 0x5B: (']', '}'), 0x5D: ('\\', '|'),
    0x66: ('\b', '\b'), 0x76: ('\x1b', '\x1b'),
    # pave numerique (Verr Num suppose actif)
    0x69: ('1', '1'), 0x6B: ('4', '4'), 0x6C: ('7', '7'), 0x70: ('0', '0'), 0x71: ('.', '.'),
    0x72: ('2', '2'), 0x73: ('5', '5'), 0x74: ('6', '6'), 0x75: ('8', '8'), 0x79: ('+', '+'),
    0x7A: ('3', '3'), 0x7B: ('-', '-'), 0x7C: ('*', '*'), 0x7D: ('9', '9'),
}
N = 0x84


def table(nom, idx, commentaire):
    print('; %s' % commentaire)
    print('%s:' % nom)
    for base in range(0, N, 16):
        octets = [ord(TOUCHES[c][idx]) if c in TOUCHES else 0 for c in range(base, min(base + 16, N))]
        print('        db      %s   ; %02Xh' % (', '.join('%03Xh' % o for o in octets), base))


print('; clavier_us.inc - GENERE par tests/gen_clavier.py, ne pas modifier a la main.')
print('; Codes de touche PS/2 (jeu 2) 00h-%02Xh -> ASCII, disposition US. 0 = pas de caractere.' % (N - 1))
print('CLAVIER_NB_CODES equ %d' % N)
table('clavier_normal', 0, 'sans Maj')
table('clavier_maj', 1, 'avec Maj')
