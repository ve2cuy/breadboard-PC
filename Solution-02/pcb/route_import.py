"""Importe le routage (SES), pose les plans de masse et la serigraphie, enregistre la carte.
    python.exe route_import.py <dossier de travail> <routage.ses>
"""
import sys, os, pcbnew
from pcbnew import FromMM as MM, ToMM as mm
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import place
W, SES = sys.argv[1], sys.argv[2]
OX, OY = 40.0, 40.0
BW, BH, R = place.BOARD
path = os.path.join(W, 'Solution02.kicad_pcb')
b = pcbnew.LoadBoard(path)
assert pcbnew.ImportSpecctraSES(b, SES), 'import SES'
print('pistes :', len(b.GetTracks()))

# ---- noms de nets comme KiCad les ecrit (« / » d'une etiquette -> {slash})
for name, ni in list(b.GetNetsByName().items()):
    name = str(name)
    new = ('/' + name[1:].replace('/', '{slash}')) if name.startswith('/') else name.replace('/', '{slash}')
    if new != name:
        ni.SetNetname(new)
        print('net renomme :', name, '->', new)

# ---- champs du schema (fiche technique, description) recopies dans les empreintes
import xml.etree.ElementTree as ET
for c in ET.parse(os.path.join(W, 'pcb', 'net.xml')).getroot().iter('comp'):
    f = b.FindFootprintByReference(c.get('ref'))
    for fld in c.iter('field'):
        if fld.get('name') in ('Datasheet', 'Description') and fld.text:
            if f.HasField(fld.get('name')):
                f.GetField(fld.get('name')).SetText(fld.text)
            else:
                f.SetField(fld.get('name'), fld.text)

# ---- pistes amincies par le routeur : au moins 0,127 mm (limite JLCPCB pour 2 couches)
n = 0
for t in b.GetTracks():
    if t.Type() != pcbnew.PCB_VIA_T and t.GetWidth() < MM(0.127):
        t.SetWidth(MM(0.127)); n += 1
print('pistes elargies a 0,127 mm :', n)

# ---- plans de masse sur les deux faces
gnd = b.FindNet('GND')
for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
    z = pcbnew.ZONE(b)
    z.SetLayer(layer)
    z.SetNet(gnd)
    o = z.Outline()
    o.NewOutline()
    for x, y in ((0, 0), (BW, 0), (BW, BH), (0, BH)):
        o.Append(MM(OX + x), MM(OY + y))
    z.SetLocalClearance(MM(0.3))
    z.SetMinThickness(MM(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(MM(0.3))
    z.SetThermalReliefSpokeWidth(MM(0.5))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    z.SetZoneName('GND')
    b.Add(z)
pcbnew.ZONE_FILLER(b).Fill(b.Zones())

# ---- serigraphie
def text(s, x, y, size=1.0, layer=pcbnew.F_SilkS, rot=0, bold=False, just=None):
    t = pcbnew.PCB_TEXT(b)
    t.SetText(s)
    t.SetLayer(layer)
    t.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
    t.SetTextSize(pcbnew.VECTOR2I(MM(size), MM(size)))
    t.SetTextThickness(MM(max(0.12, size * (0.2 if bold else 0.15))))
    t.SetTextAngleDegrees(rot)
    if layer == pcbnew.B_SilkS:
        t.SetMirrored(True)
    if just == 'left':
        t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_LEFT)
    elif just == 'right':
        t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_RIGHT)
    b.Add(t)
for s, x, y, kw in place.SILK:
    text(s, x, y, **kw)

pcbnew.SaveBoard(path, b)

# ---- regles de controle : routage fait a 0,18 / 0,25 mm d'isolement, controle a 0,16 / 0,24 mm
#      (pistes elargies a 0,127 mm et arrondis ; limite JLCPCB : 0,127 mm)
import json
pro = os.path.join(W, 'Solution02.kicad_pro')
d = json.load(open(pro, encoding='utf-8'))
for c in d['net_settings']['classes']:
    c['clearance'] = 0.24 if c['name'] == 'Power' else 0.16
json.dump(d, open(pro, 'w', encoding='utf-8'), indent=2)
print('enregistre', path)
