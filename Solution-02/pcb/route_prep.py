"""Regles du projet (classes de nets comme le PCB de Solution-01) puis export Specctra DSN.
    python.exe route_prep.py <dossier de travail> <sortie.dsn>
"""
import sys, os, json, pcbnew
W, DSN = sys.argv[1], sys.argv[2]
pro = os.path.join(W, 'Solution02.kicad_pro')
d = json.load(open(pro, encoding='utf-8'))
# memes classes de nets et regles que le PCB de Solution-01
ref = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'kicad', 'Breadboard-pc', 'Breadboard-pc.kicad_pro'), encoding='utf-8'))
d['board'] = ref['board']
d['net_settings'] = ref['net_settings']
d['net_settings']['netclass_patterns'] = [{'netclass': 'Power', 'pattern': p} for p in ('+5V', 'GND', 'VCC')]
rs = d['board']['design_settings'].setdefault('rule_severities', {})
rs['lib_footprint_mismatch'] = 'ignore'
rs['lib_footprint_issues'] = 'ignore'
# la masse est deja reliee par des pistes de 0,6 mm : un seul rayon de frein thermique suffit
d['board']['design_settings']['rules']['min_resolved_spokes'] = 1
json.dump(d, open(pro, 'w', encoding='utf-8'), indent=2)
b = pcbnew.LoadBoard(os.path.join(W, 'Solution02.kicad_pcb'))
ok = pcbnew.ExportSpecctraDSN(b, DSN)
print('DSN', ok, os.path.getsize(DSN))
