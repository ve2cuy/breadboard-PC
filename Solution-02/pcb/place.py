"""Placement des composants de Solution-02 (mm, origine = coin superieur gauche de la carte).
Position = ancre de l'empreinte (pastille 1), rotation en degres (sens antihoraire).
Le module LCD (98 x 60 mm) couvre le coin superieur gauche ; dessous : composants bas seulement.
"""
BOARD = (172.0, 100.0, 3.0)        # largeur, hauteur, rayon des coins

PLACE = {
    # ---- LCD et, dessous, peripheriques et RAM
    'U10': (11.0, 3.5, 0),
    'C19': (52.5, 3.5, 0),
    'U13': (8.5, 22.74, 90),  'C15': (5.2, 8.5, 270),
    'U15': (49.0, 22.74, 90), 'C17': (45.6, 8.5, 270),
    'U12': (8.5, 42.48, 90),  'C14': (5.2, 28.24, 270),
    'U14': (61.5, 27.24, 0),   'C16': (72.6, 27.74, 270),
    'U7': (8.5, 62.22, 90),  'C10': (5.2, 47.98, 270),
    'U9': (61.5, 46.98, 0),   'C12': (72.6, 47.48, 270),
    'U6':  (96.24, 47.1, 180), 'C9': (81.5, 51.2, 0),
    'R13': (78.0, 54.0, 270), 'R14': (81.2, 54.0, 270), 'R15': (84.4, 54.0, 270), 'R16': (87.6, 54.0, 270), 'R17': (90.8, 54.0, 270),
    'R4': (77.0, 26.74, 270), 'R9': (77.0, 39.2, 270),
    'R2': (4.6, 15.7, 270),  'R3': (4.6, 35.44, 270),
    # ---- bargraphes sous le LCD
    'RN1': (17.46, 67.7, 0), 'RN2': (43.66, 67.7, 0), 'RN3': (69.86, 67.7, 0),
    'BAR1': (20.0, 79.4, 90), 'BAR2': (46.2, 79.4, 90), 'BAR3': (72.4, 79.4, 90),
    'R5': (38.0, 83.4, 0), 'R6': (64.2, 83.4, 0), 'R7': (88.0, 83.4, 0),
    'J1': (28.5, 87.7, 90), 'J2': (55.1, 87.7, 90), 'J3': (81.7, 87.7, 90),
    'D1': (99.3, 72.0, 270), 'D2': (99.3, 78.5, 270),
    # ---- bord inferieur : connecteurs
    'J11': (27.5, 96.6, 90), 'J12': (62.0, 96.6, 90), 'J9': (81.5, 96.6, 90), 'J5': (98.0, 96.6, 90),
    # ---- coin inferieur gauche : clavier et alimentation
    'J4': (12.4, 70.0, 270),
    'J6': (12.2, 87.0, 90),
    'J7': (23.5, 90.0, 0),
    'C20': (21.2, 84.6, 0),
    'D3': (3.0, 84.6, 0), 'R18': (16.83, 70.5, 270),
    # ---- ROM (support ZIF), processeur, verrous
    'U4': (120.2, 47.1, 180), 'C7': (128.9, 38.0, 270),
    'U1': (133.5, 6.5, 0),    'C4': (138.5, 3.0, 0),
    'U3': (153.5, 6.5, 0),    'C6': (155.0, 3.2, 0),
    'U2': (131.0, 67.5, 90),  'C5': (127.4, 60.5, 270),
    'J10': (166.0, 10.0, 0),
    # ---- horloge et RESET
    'U11': (131.0, 81.0, 90), 'C13': (131.5, 85.0, 0),
    'Y1': (126.0, 74.5, 270), 'C2': (120.6, 72.3, 270), 'C3': (120.6, 79.5, 270),
    'SW1': (157.5, 74.5, 0), 'R1': (156.5, 83.5, 0), 'C1': (167.5, 76.0, 0),
    # ---- divers
    'RV1': (113.6, 81.8, 0),
    'R11': (103.7, 72.5, 270), 'R12': (106.9, 72.5, 270),
    'BZ1': (158.0, 66.5, 0), 'R8': (169.9, 62.5, 270), 'R10': (107.9, 88.5, 270),
    # ---- logique, bord inferieur droit
    'U5':  (155.0, 36.0, 0),  'C8': (156.3, 55.5, 0),
    'U8':  (116.0, 96.0, 90), 'C11': (112.4, 89.0, 270),
    'U16': (141.0, 96.0, 90), 'C18': (137.3, 89.0, 270),
}
HOLES = {'H1': (168.2, 4.0), 'H2': (3.8, 96.2), 'H3': (168.2, 96.2)}
# composants trop hauts pour tenir sous le LCD (11 mm)
TALL = {'C1', 'C20', 'BZ1', 'SW1', 'RV1', 'U4', 'Y1', 'D1', 'D2', 'D3', 'BAR1', 'BAR2', 'BAR3',
        'J1', 'J2', 'J3', 'J4', 'J5', 'J6', 'J7', 'J9', 'J10', 'J11', 'J12', 'U1'}
EDGE_OK = {'J4', 'J6', 'U10'}
# diametre des pastilles a reduire (l'empreinte HDSP-4830 de KiCad a des pastilles de 2,03 mm :
# 0,51 mm entre deux broches, aucune piste ne passe)
PAD_SIZE = {'BAR1': 1.6, 'BAR2': 1.6, 'BAR3': 1.6}
# position du texte de reference (serigraphie) quand celle de la bibliotheque sort de la carte
REFPOS = {'C4': (146.3, 3.0), 'C6': (162.7, 3.2), 'R8': (169.9, 60.45)}

# ---------------------------------------------------------------- serigraphie
def _silk():
    import pcbnew
    F, B = pcbnew.F_SilkS, pcbnew.B_SilkS
    out = []
    T = lambda s, x, y, **kw: out.append((s, x, y, kw))
    bw, bh, _ = BOARD
    # titre
    x, y = bw - 7.2, 88.4
    T('SOLUTION-02', x, y, size=1.25, bold=True)
    T('8088 / NEC V20', x - 0.3, y + 2.1, size=0.85)
    T('VE2CUY 2026 rev. A', x - 1.6, y + 3.8, size=0.8)
    # J10 (bus du 8088) : tableau des broches au verso, entre les rangees de U1
    bus = ['+5V', 'GND'] + ['A%d' % i for i in range(20)] + ['D%d' % i for i in range(8)] +           ['ALE', 'IO/M', '/RD', '/WR', '/INTA', 'INTR', 'CLK', 'RESET', 'GND', 'PCLK']
    ux, uy, _r = PLACE['U1']
    cx = ux + 7.62
    T('J10 BUS 8088', cx, uy + 0.9, size=0.8, layer=B, bold=True)
    for i in range(20):
        # colonne des broches impaires du cote de leur rangee sur J10 (a gauche vu de dessus)
        T('%d %s' % (2 * i + 1, bus[2 * i]), cx - 3.3, uy + 3.1 + i * 2.3, size=0.8, layer=B)
        T('%d %s' % (2 * i + 2, bus[2 * i + 1]), cx + 3.3, uy + 3.1 + i * 2.3, size=0.8, layer=B)
    # J11 (ports de U7) : legende au verso, au-dessus et au-dessous des broches
    ports = ['+5V', 'GND'] + ['P%s%d' % (p, i) for p in 'ABC' for i in range(8)]
    jx, jy, _r = PLACE['J11']
    for i, n in enumerate(ports):
        odd = i % 2 == 0
        T(n, jx + (i // 2) * 2.54, jy + 1.9 if odd else jy - 2.54 - 1.9, size=0.8, layer=B)
    # connecteurs simples : legende au recto, texte vertical au-dessus des broches
    for ref, names in (('J12', ['5V', 'IR2', 'IR3', 'IR5', 'IR6', 'IR7', 'GND']),
                       ('J9', ['CS', 'SCK', 'MOSI', 'MISO', '5V', 'GND']),
                       ('J5', ['TX', 'RX', 'GND'])):
        jx, jy, _r = PLACE[ref]
        for i, n in enumerate(names):
            T(n, jx + i * 2.54, jy - 3.5, size=0.8, rot=90)
    jx, jy, _r = PLACE['J7']
    T('+5V', jx - 3.0, jy, size=0.8)
    T('GND', jx - 3.0, jy + 2.54, size=0.8)
    jx, jy, _r = PLACE['J6']
    T('5V DC', jx + 1.0, jy - 3.2, size=0.9)
    x, y, _r = PLACE['SW1']
    T('RESET', x + 3.25, y - 2.4, size=1.0)
    x, y, _r = PLACE['D1']
    T('A:', x, y - 1.7, size=0.8)
    x, y, _r = PLACE['D2']
    T('C:', x, y + 4.3, size=0.8)
    x, y, _r = PLACE['D3']
    T('5V', x + 1.27, y - 2.9, size=0.8)
    return out
SILK = _silk()
