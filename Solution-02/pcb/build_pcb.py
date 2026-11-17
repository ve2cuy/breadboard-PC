"""Construit Solution02.kicad_pcb a partir de la netliste (net.xml) et de la table de placement (place.py).
A lancer avec le Python de KiCad :  python.exe build_pcb.py <dossier de travail> [--dessin image.png]
- empreintes chargees des bibliotheques de KiCad (et Solution02.pretty), references, valeurs, liens au schema ;
- nets de la netliste attribues aux pastilles ; contour, trous de fixation ; controle des chevauchements.
"""
import sys, os, json, importlib, xml.etree.ElementTree as ET
import pcbnew
from pcbnew import FromMM as MM, ToMM as mm

W = sys.argv[1]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import place
importlib.reload(place)
FPDIR = 'C:/Program Files/KiCad/10.0/share/kicad/footprints/'
OX, OY = 40.0, 40.0                         # origine de la carte dans la feuille

def fpload(name):
    lib, fp = name.split(':')
    d = os.path.join(W, 'Solution02.pretty') if lib == 'Solution02' else FPDIR + lib + '.pretty'
    f = pcbnew.FootprintLoad(d, fp)
    assert f is not None, name
    f.SetFPID(pcbnew.LIB_ID(lib, fp))
    return f

root = ET.parse(os.path.join(W, 'pcb', 'net.xml')).getroot()
comps = {}
for c in root.iter('comp'):
    comps[c.get('ref')] = dict(value=c.findtext('value') or '', fp=c.findtext('footprint'),
                               ts=c.findtext('tstamps'), sheet=c.find('sheetpath').get('tstamps'))
nets = {}
for n in root.iter('net'):
    for nd in n.iter('node'):
        nets[(nd.get('ref'), nd.get('pin'))] = (n.get('name'), nd.get('pinfunction') or '', nd.get('pintype') or '')

# empreintes chargees avant de creer la carte
loaded = {ref: fpload(c['fp']) for ref, c in comps.items()}
holes = {ref: fpload('MountingHole:MountingHole_3.2mm_M3') for ref in place.HOLES}

board = pcbnew.NewBoard(os.path.join(W, 'Solution02.kicad_pcb'))
board.SetCopperLayerCount(2)
ds = board.GetDesignSettings()
ds.SetBoardThickness(MM(1.6))
netinfo = {}
def net(name):
    if name not in netinfo:
        ni = pcbnew.NETINFO_ITEM(board, name)
        board.Add(ni)
        netinfo[name] = ni
    return netinfo[name]

missing = [r for r in comps if r not in place.PLACE]
assert not missing, 'sans placement : %s' % missing
problems = []
for ref, c in sorted(comps.items()):
    f = loaded[ref]
    x, y, rot = place.PLACE[ref][:3]
    f.SetReference(ref)
    f.SetValue(c['value'])
    board.Add(f)
    f.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
    f.SetOrientationDegrees(rot)
    f.SetPath(pcbnew.KIID_PATH(c['sheet'] + c['ts']))
    if ref in getattr(place, 'REFPOS', {}):
        rx, ry = place.REFPOS[ref]
        f.Reference().SetPosition(pcbnew.VECTOR2I(MM(OX + rx), MM(OY + ry)))
        f.Reference().SetTextAngleDegrees(0)
    seen = set()
    for p in f.Pads():
        num = p.GetNumber()
        # bargraphes : pastilles de 1,6 mm au lieu de 2,03 mm (une piste passe entre deux broches)
        if ref in getattr(place, 'PAD_SIZE', {}) and num:
            d = MM(place.PAD_SIZE[ref])
            p.SetSize(pcbnew.F_Cu, pcbnew.VECTOR2I(d, d))
        if not num:
            continue
        seen.add(num)
        k = (ref, num)
        if k in nets:
            name, fn, ty = nets[k]
            p.SetNet(net(name))
            p.SetPinFunction(fn.rsplit('_', 1)[0] if fn.endswith('_' + num) else fn)
            p.SetPinType(ty)
        else:
            problems.append('pastille sans net : %s.%s' % k)
    for (r, pin) in nets:
        if r == ref and pin not in seen:
            problems.append('broche sans pastille : %s.%s (%s)' % (r, pin, nets[(r, pin)][0]))
for ref, (x, y) in place.HOLES.items():
    f = holes[ref]
    f.SetReference(ref)
    f.SetValue('M3')
    board.Add(f)
    f.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
    f.SetAttributes(f.GetAttributes() | pcbnew.FP_BOARD_ONLY | pcbnew.FP_EXCLUDE_FROM_BOM | pcbnew.FP_EXCLUDE_FROM_POS_FILES)
    f.Reference().SetVisible(False)

# contour : rectangle aux coins arrondis
BW, BH, R = place.BOARD
def edge(shape):
    shape.SetLayer(pcbnew.Edge_Cuts)
    shape.SetWidth(MM(0.1))
    board.Add(shape)
def seg(x1, y1, x2, y2):
    s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(pcbnew.VECTOR2I(MM(OX + x1), MM(OY + y1))); s.SetEnd(pcbnew.VECTOR2I(MM(OX + x2), MM(OY + y2)))
    edge(s)
def arc(cx, cy, sx, sy, ex, ey):
    s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_ARC)
    s.SetCenter(pcbnew.VECTOR2I(MM(OX + cx), MM(OY + cy)))
    s.SetStart(pcbnew.VECTOR2I(MM(OX + sx), MM(OY + sy)))
    s.SetEnd(pcbnew.VECTOR2I(MM(OX + ex), MM(OY + ey)))
    edge(s)
seg(R, 0, BW - R, 0); seg(BW, R, BW, BH - R); seg(BW - R, BH, R, BH); seg(0, BH - R, 0, R)
arc(R, R, 0, R, R, 0); arc(BW - R, R, BW - R, 0, BW, R); arc(BW - R, BH - R, BW, BH - R, BW - R, BH); arc(R, BH - R, R, BH, 0, BH - R)

# ---------------------------------------------------------------- controle des chevauchements (cours)
def court(f):
    c = f.GetCourtyard(pcbnew.F_CrtYd)
    b = c.BBox() if not c.IsEmpty() else f.GetBoundingBox(False)
    return (mm(b.GetLeft()) - OX, mm(b.GetTop()) - OY, mm(b.GetRight()) - OX, mm(b.GetBottom()) - OY)
boxes = {f.GetReference(): court(f) for f in board.GetFootprints()}
refs = sorted(boxes)
for i, a in enumerate(refs):
    A = boxes[a]
    if A[0] < 0.3 or A[1] < 0.3 or A[2] > BW - 0.3 or A[3] > BH - 0.3:
        if a not in place.EDGE_OK:
            problems.append('hors carte : %s %s' % (a, [round(v, 2) for v in A]))
    for b in refs[i + 1:]:
        B = boxes[b]
        ox = min(A[2], B[2]) - max(A[0], B[0]); oy = min(A[3], B[3]) - max(A[1], B[1])
        if ox > 0.05 and oy > 0.05:
            problems.append('chevauchement : %s / %s (%.2f x %.2f)' % (a, b, ox, oy))
# zones interdites aux composants hauts (sous le LCD) et entretoises
lcd = board.FindFootprintByReference('U10').GetPosition()
lx, ly = mm(lcd.x) - OX, mm(lcd.y) - OY
LCD = (lx - 10, ly - 2.5, lx + 88, ly + 57.5)
for ref, B in boxes.items():
    if ref == 'U10':
        continue
    ox = min(LCD[2], B[2]) - max(LCD[0], B[0]); oy = min(LCD[3], B[3]) - max(LCD[1], B[1])
    if ox > 0.3 and oy > 0.3 and ref in place.TALL:
        problems.append('composant haut sous le LCD : %s' % ref)
    for hx, hy in ((-7.5, 0), (85.5, 0), (-7.5, 55), (85.5, 55)):
        cx, cy = lx + hx, ly + hy
        dx = max(B[0] - cx, 0, cx - B[2]); dy = max(B[1] - cy, 0, cy - B[3])
        if (dx * dx + dy * dy) ** 0.5 < 3.0:
            problems.append('trop pres d\'une entretoise du LCD : %s' % ref)
print('\n'.join(problems) if problems else 'aucun probleme de placement')
pcbnew.SaveBoard(os.path.join(W, 'Solution02.kicad_pcb'), board)
print('carte %g x %g mm, %d empreintes, %d nets' % (BW, BH, len(board.GetFootprints()), board.GetNetCount()))

# ---------------------------------------------------------------- dessin de controle
if '--dessin' in sys.argv:
    out = sys.argv[sys.argv.index('--dessin') + 1]
    data = dict(board=[BW, BH], lcd=LCD, boxes=boxes,
                pads=[[f.GetReference(), p.GetNumber(), mm(p.GetPosition().x) - OX, mm(p.GetPosition().y) - OY, mm(p.GetSize().x), p.GetNetname()]
                      for f in board.GetFootprints() for p in f.Pads()])
    json.dump(data, open(out, 'w'))
