"""Controle independant des pistes du PCB de Solution-02 (sans le moteur de connectivite de KiCad).

1. Continuite : a partir de la seule geometrie du cuivre (pastilles, pistes, vias ; les plans de masse
   sont ignores), regroupe tout ce qui se touche, puis compare aux nets de la netliste du schema :
   chaque net doit former un seul ilot (aucune coupure) et aucun ilot ne doit toucher deux nets
   (aucun court-circuit).
2. Isolement : distance minimale entre cuivres de nets differents (pistes, vias, pastilles).
3. Netliste extraite du cuivre = netliste du schema (celle que le simulateur execute).
    python.exe verif_pistes.py <carte.kicad_pcb> <netliste.xml> [rapport.txt]
"""
import sys, math, collections, xml.etree.ElementTree as ET
import pcbnew
from pcbnew import ToMM as mm

PCB, XML = sys.argv[1], sys.argv[2]
OUT = sys.argv[3] if len(sys.argv) > 3 else None
b = pcbnew.LoadBoard(PCB)
root = ET.parse(XML).getroot()
sch = {}                                    # (ref, broche) -> net du schema
for n in root.iter('net'):
    for nd in n.iter('node'):
        sch[(nd.get('ref'), nd.get('pin'))] = n.get('name')

# ---------------------------------------------------------------- objets de cuivre
# forme : ('c', x, y, r, couches) cercle ; ('s', x1, y1, x2, y2, r, couches) segment epais
ALL = frozenset(('F', 'B'))
objs = []           # (forme, etiquette, net attendu ou None)
pads = {}
for f in b.GetFootprints():
    for p in f.Pads():
        num = p.GetNumber()
        if p.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH or not num:
            continue
        pos = p.GetPosition()
        sx, sy = mm(p.GetSize().x), mm(p.GetSize().y)
        lay = ALL if p.GetAttribute() == pcbnew.PAD_ATTRIB_PTH else frozenset(('F',) if p.IsOnLayer(pcbnew.F_Cu) else ('B',))
        x, y = mm(pos.x), mm(pos.y)
        r = min(sx, sy) / 2
        ang = math.radians(p.GetOrientationDegrees() + f.GetOrientationDegrees() * 0)
        # pastille oblongue ou rectangulaire : segment epais sur son grand axe (approximation prudente : inscrite)
        if abs(sx - sy) < 1e-6:
            shape = ('c', x, y, r, lay)
        else:
            d = (max(sx, sy) - min(sx, sy)) / 2
            a = math.radians(-p.GetOrientationDegrees()) + (0 if sx > sy else math.pi / 2)
            shape = ('s', x - d * math.cos(a), y - d * math.sin(a), x + d * math.cos(a), y + d * math.sin(a), r, lay)
        key = (f.GetReference(), num)
        objs.append((shape, '%s.%s' % key, sch.get(key)))
        pads.setdefault(key, []).append(len(objs) - 1)
ntracks = nvias = 0
length = collections.Counter()
viac = collections.Counter()
minw = {}
for t in b.GetTracks():
    if t.Type() == pcbnew.PCB_VIA_T:
        p = t.GetPosition()
        objs.append((('c', mm(p.x), mm(p.y), mm(t.GetWidth(pcbnew.F_Cu)) / 2, ALL), 'via', None))
        nvias += 1
        viac[t.GetNetname()] += 1
    else:
        s, e = t.GetStart(), t.GetEnd()
        lay = frozenset(('F',) if t.GetLayer() == pcbnew.F_Cu else ('B',))
        w = mm(t.GetWidth())
        objs.append((('s', mm(s.x), mm(s.y), mm(e.x), mm(e.y), w / 2, lay), 'piste', None))
        ntracks += 1
        length[t.GetNetname()] += math.hypot(mm(e.x) - mm(s.x), mm(e.y) - mm(s.y))
        minw[t.GetNetname()] = min(minw.get(t.GetNetname(), 9), w)

def seg_pt(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / L))
    return math.hypot(px - x1 - t * dx, py - y1 - t * dy)
def seg_seg(a, c):
    x1, y1, x2, y2 = a; x3, y3, x4, y4 = c
    def ccw(ax, ay, bx, by, cx, cy): return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    d1, d2 = ccw(x3, y3, x4, y4, x1, y1), ccw(x3, y3, x4, y4, x2, y2)
    d3, d4 = ccw(x1, y1, x2, y2, x3, y3), ccw(x1, y1, x2, y2, x4, y4)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and d1 * d2 != 0 and d3 * d4 != 0:
        return 0.0
    return min(seg_pt(x1, y1, *c), seg_pt(x2, y2, *c), seg_pt(x3, y3, *a), seg_pt(x4, y4, *a))
def core(s):
    return (s[1], s[2], s[1], s[2]) if s[0] == 'c' else s[1:5]
def gap(s1, s2):
    """Distance cuivre a cuivre (negative = recouvrement) ; None si aucune couche commune."""
    if not (s1[-1] & s2[-1]):
        return None
    return seg_seg(core(s1), core(s2)) - s1[-2] - s2[-2]

# grille spatiale
CELL = 2.0
grid = collections.defaultdict(list)
def bbox(s):
    x1, y1, x2, y2 = core(s); r = s[-2]
    return min(x1, x2) - r, min(y1, y2) - r, max(x1, x2) + r, max(y1, y2) + r
for i, (s, _, _) in enumerate(objs):
    x0, y0, x1, y1 = bbox(s)
    for gx in range(int(x0 // CELL) - 1, int(x1 // CELL) + 2):
        for gy in range(int(y0 // CELL) - 1, int(y1 // CELL) + 2):
            grid[(gx, gy)].append(i)
parent = list(range(len(objs)))
def find(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i
pairs = set()
for cell in grid.values():
    for a in range(len(cell)):
        for c in range(a + 1, len(cell)):
            i, j = cell[a], cell[c]
            if (i, j) in pairs:
                continue
            pairs.add((i, j))
            g = gap(objs[i][0], objs[j][0])
            if g is not None and g < -0.001:          # recouvrement reel du cuivre
                parent[find(i)] = find(j)
# les pastilles multiples d'une meme broche (bouton, blindage) sont reliees par le composant ou par le net
groups = collections.defaultdict(list)
for i in range(len(objs)):
    groups[find(i)].append(i)

# ---------------------------------------------------------------- 1. continuite et courts-circuits
net_of_group = {}
shorts = []
for g, items in groups.items():
    ns = {objs[i][2] for i in items if objs[i][2]}
    if len(ns) > 1:
        shorts.append((sorted(ns), [objs[i][1] for i in items if objs[i][2]][:8]))
    net_of_group[g] = next(iter(ns)) if ns else None
netpads = collections.defaultdict(list)
for key, idx in pads.items():
    if key in sch:
        netpads[sch[key]].append((key, idx))
opens = []
for name, lst in sorted(netpads.items()):
    if len(lst) < 2:
        continue
    # une broche a plusieurs pastilles (bouton a 4 pattes, blindage) compte si l'une d'elles est reliee
    comp = collections.defaultdict(list)
    for key, idx in lst:
        comp[frozenset(find(i) for i in idx)].append(key)
    isl = []
    for gs, keys in comp.items():
        for it in isl:
            if it[0] & gs:
                it[0] |= gs; it[1] += keys
                break
        else:
            isl.append([set(gs), list(keys)])
    # fusion transitive
    changed = True
    while changed:
        changed = False
        for i in range(len(isl)):
            for j in range(i + 1, len(isl)):
                if isl[i][0] & isl[j][0]:
                    isl[i][0] |= isl[j][0]; isl[i][1] += isl[j][1]; del isl[j]; changed = True
                    break
            if changed:
                break
    if len(isl) > 1:
        opens.append((name, [sorted('%s.%s' % k for k in it[1]) for it in isl]))
orphans = [g for g, items in groups.items() if net_of_group[g] is None and any(objs[i][1] != 'via' for i in items)]

# ---------------------------------------------------------------- 2. isolement minimal entre nets differents
gnet = {i: net_of_group[find(i)] for i in range(len(objs))}
worst = (9.0, None, None)
for (i, j) in pairs:
    if find(i) == find(j):
        continue
    g = gap(objs[i][0], objs[j][0])
    if g is not None and g < worst[0]:
        worst = (g, i, j)

# ---------------------------------------------------------------- 3. netliste extraite du cuivre
extracted = collections.defaultdict(set)
for key, idx in pads.items():
    extracted[frozenset(find(i) for i in idx)].add(key)
merged = []
for gs, keys in extracted.items():
    hit = [m for m in merged if m[0] & gs]
    for m in hit:
        gs = gs | m[0]; keys = keys | m[1]; merged.remove(m)
    merged.append((frozenset(gs), set(keys)))
cu = sorted(sorted(k) for _, k in merged)
ref = collections.defaultdict(set)
for k, n in sch.items():
    ref[n].add(k)
want = sorted(sorted(v) for v in ref.values())
same = cu == want

lines = []
P = lines.append
P('Controle independant des pistes : %s' % PCB.replace('\\', '/').split('/')[-1])
P('  cuivre : %d pastilles, %d segments de piste, %d vias ; plans de masse ignores' % (sum(len(v) for v in pads.values()), ntracks, nvias))
P('  netliste du schema : %d nets, dont %d a relier (2 broches ou plus), %d broches' % (len(ref), sum(1 for v in ref.values() if len(v) > 1), len(sch)))
P('1. Continuite : %d net(s) coupe(s) ; courts-circuits : %d ; cuivre sans net : %d' % (len(opens), len(shorts), len(orphans)))
for name, isl in opens[:40]:
    P('   COUPURE %s : %s' % (name, ' | '.join(','.join(i[:6]) + ('...' if len(i) > 6 else '') for i in isl)))
for ns, ex in shorts[:20]:
    P('   COURT-CIRCUIT %s (%s)' % (' + '.join(ns), ', '.join(ex)))
if worst[1] is not None:
    P('2. Isolement minimal entre nets differents : %.3f mm (%s [%s] / %s [%s])' % (
        worst[0], objs[worst[1]][1], gnet[worst[1]], objs[worst[2]][1], gnet[worst[2]]))
P('3. Netliste extraite du cuivre identique a celle du schema : %s' % ('OUI' if same else 'NON'))
tot = sum(length.values())
P('   longueur totale des pistes : %.0f mm ; largeur minimale : %.2f mm ; alimentation (+5V, GND) : %.2f mm minimum' % (
    tot, min(minw.values()) if minw else 0, min(minw.get('+5V', 9), minw.get('GND', 9))))
P('   nets les plus longs : ' + ', '.join('%s %.0f mm' % (n, l) for n, l in length.most_common(6)))
P('RESULTAT : %s' % ('CONFORME' if not opens and not shorts and same else 'NON CONFORME'))
txt = '\n'.join(lines)
print(txt)
if OUT:
    open(OUT, 'w', encoding='utf-8').write(txt + '\n')
sys.exit(0 if not opens and not shorts and same else 1)
