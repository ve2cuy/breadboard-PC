#!/usr/bin/env python3
"""Modele 3D (STEP) du support ZIF 32 broches 3M Textool 232-1285-00-0602J, pour l'empreinte KiCad
Socket:DIP_Socket-32_W11.9mm_W12.7mm_W15.24mm_W17.78mm_W18.5mm_3M_232-1285-00-0602J.

Vue de dessus reprise du contour F.Fab de cette empreinte (boitier, chanfrein, levier et poignee):
le modele s'aligne donc exactement sur les pastilles. Origine = pastille 1, broches a 2,54 mm, rangees
a 15,24 mm. Les HAUTEURS ne figurent pas dans l'empreinte: valeurs typiques d'un ZIF Textool, a
ajuster ci-dessous si besoin (fiche 3M TS-0365).

Usage (CadQuery requis):  python zif32_3m_232-1285.py   -> <nom de l'empreinte>.step (et .wrl)
"""
import os
import cadquery as cq

NOM = 'DIP_Socket-32_W11.9mm_W12.7mm_W15.24mm_W17.78mm_W18.5mm_3M_232-1285-00-0602J'
ICI = os.path.dirname(os.path.abspath(__file__))

# --- vue de dessus (mm, reperes de l'empreinte KiCad: X a droite, Y vers le BAS) ---
N_PAR_RANGEE, PAS, ENTRAXE = 16, 2.54, 15.24
BOITIER = (-3.83, -10.56, 19.07, 44.94)        # xmin, ymin, xmax, ymax (F.Fab)
CHANFREIN = 1.0                                 # coin superieur gauche (F.Fab)
BRAS = (-3.5, -15.86, -1.9, -9.75)              # bras du levier hors du boitier (F.Fab)
POIGNEE = (-5.0, -22.86, -0.4, -15.86)          # poignee du levier (F.Fab)
PIVOT = (-3.2, -6.35)                           # axe du levier (cercle de la serigraphie)

# --- hauteurs (hypotheses, voir en-tete) ---
H_BOITIER = 10.2          # dessus du boitier au-dessus du circuit imprime
H_FENTES = 1.5            # profondeur des fentes d'insertion
H_BRAS = 1.6              # epaisseur du bras du levier
R_PIVOT = 2.5             # rayon du moyeu du levier
L_BROCHE, D_BROCHE = 3.5, 0.55   # broches sous la carte


def y(v):                  # empreinte (Y vers le bas) -> modele 3D (Y vers le haut)
    return -v


def boite(x0, y0, x1, y1, z0, z1):
    return (cq.Workplane('XY').box(x1 - x0, abs(y1 - y0), z1 - z0, centered=False)
            .translate((x0, min(y(y0), y(y1)), z0)))


# boitier, coin chanfreine, fentes d'insertion (universel: 11,9 a 18,5 mm entre rangees)
x0, y0, x1, y1 = BOITIER
corps = boite(x0, y0, x1, y1, 0, H_BOITIER).edges('|Z').edges('<X and >Y').chamfer(CHANFREIN)
for i in range(N_PAR_RANGEE):
    yy = y(i * PAS)
    for xa, xb in ((-1.9, 1.9), (ENTRAXE - 1.9, ENTRAXE + 1.9)):
        corps = corps.cut(boite(xa, -yy - 0.5, xb, -yy + 0.5, H_BOITIER - H_FENTES, H_BOITIER + 1))

# levier: moyeu (axe selon X), bras le long du bord gauche, poignee
zc = H_BOITIER - R_PIVOT
moyeu = (cq.Workplane('YZ').circle(R_PIVOT).extrude(BRAS[2] - BRAS[0])
         .translate((BRAS[0], y(PIVOT[1]), zc)))
bx0, by0, bx1, by1 = BRAS
bras = boite(bx0, by0, bx1, PIVOT[1], zc - H_BRAS / 2, zc + H_BRAS / 2)
px0, py0, px1, py1 = POIGNEE
poignee = boite(px0, py0, px1, py1, zc - 2.0, zc + 2.0).edges('|X').fillet(0.8)
levier = moyeu.union(bras)

# broches (rondes), de sous la carte jusque dans le boitier
broches = None
for i in range(N_PAR_RANGEE):
    for xx in (0.0, ENTRAXE):
        b = (cq.Workplane('XY').circle(D_BROCHE / 2).extrude(L_BROCHE + 1.0)
             .translate((xx, y(i * PAS), -L_BROCHE)))
        broches = b if broches is None else broches.union(b)

assy = cq.Assembly(name=NOM)
assy.add(corps, name='boitier', color=cq.Color(0.10, 0.42, 0.22))       # vert Textool
assy.add(levier, name='levier', color=cq.Color(0.75, 0.75, 0.78))       # metal
assy.add(poignee, name='poignee', color=cq.Color(0.08, 0.08, 0.08))     # noir
assy.add(broches, name='broches', color=cq.Color(0.85, 0.68, 0.25))     # dore
assy.export(os.path.join(ICI, NOM + '.step'))
try:
    assy.export(os.path.join(ICI, NOM + '.wrl'), 'VRML')
except Exception as e:                           # VRML facultatif (selon la version de CadQuery)
    print('VRML non produit:', e)
print('ecrit', NOM + '.step')
