"""Convertit la netliste KiCad (XML) de Solution-02 en module JavaScript pour le simulateur.

    kicad-cli sch export netlist --format kicadxml -o outils/solution02.xml ../Solution02.kicad_sch
    python outils/netlist.py            -> www/js/netlist.js
"""
import json
import os
import xml.etree.ElementTree as ET

ICI = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ICI, 'solution02.xml')
DST = os.path.join(ICI, '..', 'www', 'js', 'netlist.js')


def main():
    r = ET.parse(SRC).getroot()
    libparts = {}
    for lp in r.find('libparts'):
        cle = (lp.get('lib'), lp.get('part'))
        pins = {}
        pe = lp.find('pins')
        if pe is not None:
            for p in pe:
                pins[p.get('num')] = (p.get('name'), p.get('type'))
        libparts[cle] = pins
    nets = {}
    pin_net = {}
    for n in r.find('nets'):
        nom = n.get('name').lstrip('/')
        noeuds = []
        for x in n:
            cle = '%s.%s' % (x.get('ref'), x.get('pin'))
            noeuds.append(cle)
            pin_net[cle] = (nom, x.get('pinfunction'), x.get('pintype'))
        nets[nom] = noeuds
    comps = []
    for c in r.find('components'):
        ref = c.get('ref')
        ls = c.find('libsource')
        cle = (ls.get('lib'), ls.get('part'))
        broches = []
        lpins = libparts.get(cle, {})
        nums = set(lpins.keys()) | {k.split('.', 1)[1] for k in pin_net if k.split('.', 1)[0] == ref}
        for num in nums:
            nom, typ = lpins.get(num, (None, None))
            net, fn, pt = pin_net.get('%s.%s' % (ref, num), (None, None, None))
            if not nom or nom == '~':
                nom = fn or ''
                if nom.endswith('_' + num):
                    nom = nom[:-len(num) - 1]
            if not nom or nom == '~':
                nom = num
            broches.append({'n': num, 'name': nom, 'type': pt or typ or '', 'net': net})
        broches.sort(key=lambda b: (len(b['n']), b['n']))
        desc = ''
        for f in c.iter('field'):
            if f.get('name') in ('Description',):
                desc = f.text or ''
        comps.append({
            'ref': ref,
            'value': c.findtext('value'),
            'footprint': c.findtext('footprint') or '',
            'part': ls.get('part'),
            'desc': desc or (c.findtext('description') or ''),
            'pins': broches,
        })
    out = {'components': comps, 'nets': nets}
    with open(DST, 'w', encoding='utf-8') as f:
        f.write('// Genere par outils/netlist.py depuis le schema KiCad de Solution-02 (ne pas modifier).\n')
        f.write('export const NETLIST = ')
        json.dump(out, f, ensure_ascii=False, separators=(',', ':'))
        f.write(';\n')
    print(len(comps), 'composants,', len(nets), 'nets ->', os.path.normpath(DST))


if __name__ == '__main__':
    main()
