"""Empreinte et modele 3D du module LCD 20x4 « 2004A » (HD44780 / ST7066U) pour Solution-02.

Module standard : circuit de 98 x 60 mm, 4 trous de 3,5 mm a 93 x 55 mm, barrette 1x16 au pas de
2,54 mm en haut a gauche (broche 1 a 10 mm du bord gauche et 2,5 mm du bord superieur).
Origine de l'empreinte = broche 1. Le module est porte par une barrette femelle de 8,5 mm et
4 entretoises M3 de 12 mm : les circuits integres tiennent dessous.
    python gen_lcd.py <dossier du projet>
"""
import os, sys
D = sys.argv[1]
os.makedirs(os.path.join(D, 'Solution02.pretty'), exist_ok=True)
os.makedirs(os.path.join(D, 'Solution02.3dshapes'), exist_ok=True)

X0, Y0, X1, Y1 = -10.0, -2.5, 88.0, 57.5          # contour du module
HOLES = [(-7.5, 0.0), (85.5, 0.0), (-7.5, 55.0), (85.5, 55.0)]
HAUT = 12.0                                        # dessous du module au-dessus de la carte (entretoises M3 de 12 mm)

def line(x1, y1, x2, y2, layer, w=0.12):
    return '\t(fp_line (start %g %g) (end %g %g) (stroke (width %g) (type default)) (layer "%s"))\n' % (x1, y1, x2, y2, w, layer)
def rect(x1, y1, x2, y2, layer, w=0.12):
    return '\t(fp_rect (start %g %g) (end %g %g) (stroke (width %g) (type default)) (fill none) (layer "%s"))\n' % (x1, y1, x2, y2, w, layer)
def txt(kind, name, val, x, y, layer, hide=False, size=1.0):
    return ('\t(property "%s" "%s" (at %g %g 0) (layer "%s")%s (effects (font (size %g %g) (thickness %g))))\n'
            % (name, val, x, y, layer, ' (hide yes)' if hide else '', size, size, size * 0.15))

f = '(footprint "LCD_2004A"\n\t(version 20240108)\n\t(generator "gen_lcd.py")\n\t(layer "F.Cu")\n'
f += '\t(descr "Module LCD 20x4 2004A (HD44780/ST7066U), 98x60 mm, barrette 1x16 au pas de 2,54 mm, 4 trous M3 a 93x55 mm ; monte sur barrette femelle de 8,5 mm et entretoises M3 de 12 mm")\n'
f += '\t(tags "LCD 2004 2004A HD44780 20x4")\n'
f += txt('p', 'Reference', 'REF**', 39, 27.5, 'F.Fab')
f += txt('p', 'Value', 'LCD_2004A', 39, 59.2, 'F.Fab')
f += txt('p', 'Datasheet', '', 0, 0, 'F.Fab', hide=True)
f += txt('p', 'Description', '', 0, 0, 'F.Fab', hide=True)
f += '\t(attr through_hole)\n'
# contour du module : complet sur F.Fab, coins sur la serigraphie
f += rect(X0, Y0, X1, Y1, 'F.Fab', 0.1)
f += rect(-9.5, 7.5, 87.5, 47.5, 'F.Fab', 0.1)       # cadre metallique
f += rect(0.5, 14.5, 77.5, 40.5, 'F.Fab', 0.1)       # zone visible
L = 6.0
for cx, cy, sx, sy in ((X0, Y0, 1, 1), (X1, Y0, -1, 1), (X0, Y1, 1, -1), (X1, Y1, -1, -1)):
    f += line(cx, cy, cx + sx * L, cy, 'F.SilkS', 0.15) + line(cx, cy, cx, cy + sy * L, 'F.SilkS', 0.15)
# barrette : contour et repere de la broche 1
f += rect(-1.33, -1.33, 39.43, 1.33, 'F.SilkS', 0.12)
f += line(-1.33, 1.33, -1.33, -1.33, 'F.SilkS', 0.3)
f += '\t(fp_text user "LCD 20x4" (at 8 2.45 0) (layer "F.SilkS") (effects (font (size 0.9 0.9) (thickness 0.14))))\n'
f += '\t(fp_text user "1" (at -2.4 0 0) (layer "F.SilkS") (effects (font (size 0.9 0.9) (thickness 0.14))))\n'
f += '\t(fp_text user "16" (at 41.2 -1.6 0) (layer "F.SilkS") (effects (font (size 0.9 0.9) (thickness 0.14))))\n'
f += rect(-1.8, -1.8, 39.9, 1.8, 'F.CrtYd', 0.05)
for i in range(16):
    f += ('\t(pad "%d" thru_hole %s (at %g 0) (size 1.7 1.7) (drill 1) (layers "*.Cu" "*.Mask") (remove_unused_layers no))\n'
          % (i + 1, 'rect' if i == 0 else 'circle', i * 2.54))
for x, y in HOLES:
    f += '\t(pad "" np_thru_hole circle (at %g %g) (size 3.2 3.2) (drill 3.2) (layers "*.Cu" "*.Mask"))\n' % (x, y)
f += '\t(embedded_fonts no)\n'
f += '\t(model "${KIPRJMOD}/Solution02.3dshapes/LCD_2004A.wrl" (offset (xyz 0 0 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0)))\n)\n'
open(os.path.join(D, 'Solution02.pretty', 'LCD_2004A.kicad_mod'), 'w', encoding='utf-8', newline='\n').write(f)

# ---------------------------------------------------------------- modele 3D (VRML 2, unite = 2,54 mm)
K = 1 / 2.54
def box(x0, y0, x1, y1, z0, z1, rgb, shin=0.2, spec=(0.1, 0.1, 0.1)):
    cx, cy, cz = (x0 + x1) / 2 * K, -(y0 + y1) / 2 * K, (z0 + z1) / 2 * K
    return ('Transform { translation %.4f %.4f %.4f children [ Shape { appearance Appearance { material Material { '
            'diffuseColor %g %g %g specularColor %g %g %g shininess %g ambientIntensity 0.3 } } geometry Box { size %.4f %.4f %.4f } } ] }\n'
            % (cx, cy, cz, *rgb, *spec, shin, (x1 - x0) * K, (y1 - y0) * K, (z1 - z0) * K))
w = '#VRML V2.0 utf8\n# Module LCD 2004A sur barrette femelle de 8,5 mm et entretoises de 12 mm\n'
NOIR, VERT, LAITON, ECRAN, OR = (0.07, 0.07, 0.08), (0.05, 0.28, 0.14), (0.75, 0.6, 0.25), (0.55, 0.72, 0.12), (0.85, 0.7, 0.3)
w += box(-1.27, -1.27, 39.37, 1.27, 0, 8.5, NOIR)                         # barrette femelle
w += box(-1.27, -1.27, 39.37, 1.27, 8.5, HAUT, (0.12, 0.12, 0.13))        # isolant de la barrette male
for i in range(16):
    w += box(i * 2.54 - 0.32, -0.32, i * 2.54 + 0.32, 0.32, HAUT + 1.6, HAUT + 2.6, OR, 0.6)   # pointes soudees
for x, y in HOLES:
    w += box(x - 2.4, y - 2.4, x + 2.4, y + 2.4, 0, HAUT, LAITON, 0.5, (0.4, 0.35, 0.2))        # entretoises
    w += box(x - 2.7, y - 2.7, x + 2.7, y + 2.7, HAUT + 1.6, HAUT + 3.6, (0.7, 0.7, 0.72), 0.6)  # vis
w += box(X0, Y0, X1, Y1, HAUT, HAUT + 1.6, VERT, 0.3)                      # circuit du module
w += box(-9.5, 7.5, 87.5, 47.5, HAUT + 1.6, HAUT + 10.6, NOIR, 0.4, (0.3, 0.3, 0.3))    # cadre metallique
w += box(0.5, 14.5, 77.5, 40.5, HAUT + 10.6, HAUT + 10.8, ECRAN, 0.7, (0.5, 0.5, 0.3))  # zone visible
# 4 lignes de 20 caracteres (5x8 points) en plus sombre
for r in range(4):
    for c in range(20):
        x = 4.05 + c * 3.55
        y = 17.4 + r * 5.25
        w += box(x, y, x + 2.95, y + 4.75, HAUT + 10.8, HAUT + 10.85, (0.47, 0.63, 0.1), 0.7)
open(os.path.join(D, 'Solution02.3dshapes', 'LCD_2004A.wrl'), 'w', encoding='utf-8', newline='\n').write(w)
open(os.path.join(D, 'fp-lib-table'), 'w', encoding='utf-8', newline='\n').write(
    '(fp_lib_table\n\t(version 7)\n\t(lib (name "Solution02")(type "KiCad")(uri "${KIPRJMOD}/Solution02.pretty")(options "")(descr "Empreintes propres a Solution-02"))\n)\n')
print('ok')
