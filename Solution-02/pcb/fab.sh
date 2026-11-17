#!/bin/bash
# Dossier de fabrication JLCPCB de Solution-02 : DRC (parite schema/PCB), Gerber, percages, zip.
#   fab.sh <dossier du projet (Solution02.kicad_pcb)> <nom du zip sans extension>
set -e
P="$1"; ZIP="$2"
K="/c/Program Files/KiCad/10.0/bin/kicad-cli.exe"
cd "$P"
mkdir -p fabrication/gerbers
"$K" pcb drc --schematic-parity --severity-all --format json -o fabrication/drc.json Solution02.kicad_pcb | tail -3
rm -f fabrication/gerbers/*
"$K" pcb export gerbers -o fabrication/gerbers -l F.Cu,B.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts \
  --no-x2 --no-netlist --subtract-soldermask --check-zones Solution02.kicad_pcb | tail -1
"$K" pcb export drill -o fabrication/gerbers/ --format excellon --excellon-units mm --excellon-zeros-format decimal \
  --excellon-separate-th --generate-map --map-format gerberx2 Solution02.kicad_pcb | tail -1
cd fabrication/gerbers
rm -f "../$ZIP.zip"
python - "$ZIP" <<'EOF'
import sys, zipfile, glob, os
keep = [f for f in sorted(glob.glob('*')) if f.lower().endswith(('.gtl', '.gbl', '.gts', '.gbs', '.gto', '.gbo', '.gm1', '.drl'))]
with zipfile.ZipFile('../' + sys.argv[1] + '.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for f in keep:
        z.write(f)
print(len(keep), 'fichiers dans le zip :', ', '.join(keep))
EOF
