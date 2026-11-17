"""Genere accueil.inc : ecran d'accueil de la console UART (sequences ANSI en couleur), envoye
quand la console passe a ON (menu 5). Inspire de l'ecran d'accueil de z/OS (medias/Z88.png),
sans la section LOGON. ASCII seulement (pas d'accents : le terminal peut ne pas etre en UTF-8).

    python tests/gen_accueil.py            -> accueil.inc (francais) et accueil_en.inc (anglais)
    python tests/gen_accueil.py --apercu   -> apercu dans la console (couleurs ANSI)
"""
import sys

ESC = '\x1b'
EFFACE = ESC + '[2J' + ESC + '[H'
BLANC, ROUGE, VERT, NORMAL = ESC + '[0;97m', ESC + '[0;91m', ESC + '[0;92m', ESC + '[0m'


def logo():
    """'88 // PC' en lettres penchees (chaque ligne decalee d'une colonne vers la gauche)."""
    huit = [None, None, '888888', '88  88', '888888', '88  88', '888888']
    p = ['PPPPPPP ', 'PP    PP', 'PP    PP', 'PPPPPPP ', 'PP      ', 'PP      ', 'PP      ']
    c = [' CCCCCCC', 'CC      ', 'CC      ', 'CC      ', 'CC      ', 'CC      ', ' CCCCCCC']
    lignes = []
    for r in range(7):
        base = 19 + (6 - r)
        h = (huit[r] or '').ljust(6)
        lignes.append((' ' * base + h + '  //  ' + p[r] + '  ' + c[r]).rstrip())
    return lignes


TEXTES = {
    'fr': ("Solution-02 : un PC 8088 sur platine d'essai", ' ' * 22 + '8088 / NEC V20 a 5,33 MHz, 512 Ko de RAM',
           ' ' * 17 + "PC-DOS 2.1 fait tourner la platine d'essai"),
    'en': ('Solution-02: an 8088 PC on a breadboard', ' ' * 22 + '8088 / NEC V20 at 5.33 MHz, 512 KB of RAM',
           ' ' * 20 + 'PC-DOS 2.1 runs on the breadboard'),
}


def ecran(langue='fr'):
    """Liste de (couleur, texte) ; couleur None = ligne vide."""
    titre, cpu, dos = TEXTES[langue]
    l = [(BLANC, titre), (None, ''), (None, ''), (None, '')]
    l += [(ROUGE, ' ' * 20 + 'https://github.com/ve2cuy/breadboard-PC'),
          (ROUGE, ' ' * 20 + 'https://github.com/ve2cuy/breadboard-PC/tree/master/Solution-02'), (None, '')]
    l += [(VERT, x) for x in logo()]
    l += [(None, ''), (VERT, cpu), (None, ''), (ROUGE, dos), (None, '')]
    return l


def octets(langue='fr'):
    s = EFFACE
    for coul, txt in ecran(langue):
        s += (coul + txt if coul else '') + '\r\n'
    return (s + NORMAL).encode('ascii')


def asm(b):
    out = ['; accueil.inc - GENERE par tests/gen_accueil.py (ne pas modifier a la main).',
           '; Ecran d\'accueil de la console UART (ANSI, couleurs), termine par 0.', 'txt_accueil:']
    ligne = []
    for octet in b:
        ligne.append('%03Xh' % octet if octet >= 0xA0 else '%02Xh' % octet)
        if octet == 10:
            out.append('            db  ' + ', '.join(ligne))
            ligne = []
    ligne.append('0')
    out.append('            db  ' + ', '.join(ligne))
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    b = octets()
    if '--apercu' in sys.argv:
        sys.stdout.write(b.decode('ascii').replace(EFFACE, ''))
        print()
    else:
        for langue, nom in (('fr', 'accueil.inc'), ('en', 'accueil_en.inc')):
            b = octets(langue)
            open(nom, 'w', encoding='ascii', newline='\n').write(asm(b))
            print('%s : %d octets' % (nom, len(b)))
