# Fabrication files — Solution-02 PCB (JLCPCB)

*[Version française](README_fr.md)*

A **172 × 100 mm** board, 2 layers, 1.6 mm, through-hole parts only (no assembly to order).
Revision A, 2026-11-17.

File to upload to jlcpcb.com: **`Solution02-JLCPCB-revA-172x100.zip`**

Contents (RS-274X Gerber without X2, Protel extensions; Excellon drills, mm, decimal):

| File | Layer |
|---|---|
| `Solution02-F_Cu.gtl` / `B_Cu.gbl` | top / bottom copper |
| `Solution02-F_Mask.gts` / `B_Mask.gbs` | solder mask |
| `Solution02-F_Silkscreen.gto` / `B_Silkscreen.gbo` | silkscreen (on the back: J10 and J11 pinouts) |
| `Solution02-Edge_Cuts.gm1` | 172 × 100 mm outline, 3 mm rounded corners |
| `Solution02-PTH.drl` | 915 plated holes (0.4 mm vias, 0.8 to 1.1 mm pins, sockets) |
| `Solution02-NPTH.drl` | 7 non-plated 3.2 mm holes: 3 for mounting the board, 4 for the LCD module |

`gerbers/` also holds the drill maps (`*_map.gbr`) and the job file (`.gbrjob`), not in the zip.
`drc.json` is the KiCad DRC report, `verif_pistes.txt` the independent trace check report.

## Suggested order settings

| Setting | Value |
|---|---|
| Base Material | FR-4 |
| Layers | 2 |
| Dimensions | 172 × 100 mm (detected from the zip) |
| PCB Thickness | 1.6 mm |
| Outer Copper Weight | 1 oz |
| Min via hole / diameter | 0.4 / 0.8 mm (no extra charge) |
| Min track / spacing | 0.127 / 0.18 mm (JLCPCB: 0.127 / 0.127 mm) |
| Surface Finish | HASL (with lead) or LeadFree HASL — ENIG optional |
| Mark on PCB (order number) | your choice: "Remove Mark" (paid) or let JLCPCB place it |
| Assembly | no (all parts are through-hole) |

## Checks done before export

1. **KiCad DRC with schematic/PCB parity check**: 0 errors, 0 unconnected items, 0 parity issues; 104 harmless silkscreen warnings (overlapping neighbor outlines, lines clipped over pads, J4 and J6 sockets overhanging the edge).
2. **Independent trace check** (`pcb/verif_pistes.py`, without KiCad's connectivity engine): from
   the copper geometry alone — 688 pads, 4247 track segments, 227 vias, ground
   planes ignored — each net of the schematic netlist forms a single island (**0 open**),
   no island touches two nets (**0 short**), and the smallest measured spacing between
   two nets is **0.182 mm**.
3. **Netlist extracted from the copper = schematic netlist** (183 nets, 685 pins). For
   the 57 original components it is also, net for net, the simulator's netlist, which boots the
   BIOS, PC-DOS and MS-DOS with this wiring: the board is wired like the simulated build.
4. JLCPCB limits: minimum track 0.127 mm, minimum spacing 0.18 mm, 0.8 / 0.4 mm vias,
   copper at least 0.5 mm from the edge, holes from 0.4 to 3.5 mm (the barrel jack slots are
   plated oblong holes).
5. Mechanical: no tall part under the LCD module, standoffs cleared (3 mm radius), USB socket and
   barrel jack overhanging the left and bottom edges.

## Assembly

- **20×4 LCD (2004A, 98 × 60 mm)**: 8.5 mm 1 × 16 female header soldered on the board, male header
  under the module, **four 12 mm M3 standoffs** (holes at 93 × 55 mm). Under the module: U6, U7,
  U9, U12–U15 and resistors. **Before ordering, check on your module** the header position (pin 1
  at 10 mm from the left edge and 2.5 mm from the top edge) and the hole spacing: these dimensions
  vary between manufacturers.
- Sockets: under the LCD, machined or low-profile sockets (or soldered chips); 12 mm leaves about
  9.5 mm under the module.
- **U4**: 32-pin ZIF socket (3M 232-1285 or equivalent), lever toward the bottom of the board.
- **Power: regulated 5 V only** (J6, 2.1 mm center-positive barrel jack, or J7). There is no
  regulator and no reverse-polarity protection.
- Suggested order: resistors, decoupling capacitors (C4–C19, 100 nF), sockets, headers, bar graphs
  (pin 1 on the left, on the J1–J3 side), connectors, then the tall parts.

## Regenerating

From `Solution-02/` (KiCad 10; Freerouting 2.5 under WSL for routing):

```sh
kicad-cli sch export netlist --format kicadxml -o pcb/net.xml Solution02.kicad_sch
python.exe pcb/build_pcb.py .                 # KiCad's Python: footprints, nets, outline (placement: pcb/place.py)
python.exe pcb/route_prep.py . s02.dsn        # project rules and Specctra export
freerouting -de s02.dsn -do s02.ses           # routing (under WSL)
python.exe pcb/route_import.py . s02.ses      # tracks, ground planes, silkscreen
python.exe pcb/verif_pistes.py Solution02.kicad_pcb pcb/net.xml fabrication/verif_pistes.txt
bash pcb/fab.sh . Solution02-JLCPCB-revA-172x100                     # DRC, Gerbers, drills, zip
```

`pcb/gen_lcd.py` generates the footprint and 3D model of the LCD module (`Solution02.pretty`,
`Solution02.3dshapes`).
