# Dossier de fabrication — Breadboard-pc (JLCPCB)

> **Version 2 (2026-11-11)** : 120 x 124,2 mm, condensateurs traversants, J5 bus 2 x 20, JP3,
> bargraphes d'adresses BAR1/BAR2, U12 (74LS373 pour A8-A11). Le zip de la **v1** (commandée le
> 2026-11-10, commit a56163d), `Breadboard-pc-JLCPCB-110x110.zip`, est conservé à côté ; ses
> Gerber sont dans l'historique git (a56163d).

Fichier à téléverser sur jlcpcb.com : **`Breadboard-pc-JLCPCB-v2-120x124.zip`**

Contenu (Gerber RS-274X sans X2, extensions Protel ; perçages Excellon, mm, décimal) :

| Fichier | Couche |
|---|---|
| `Breadboard-pc-F_Cu.gtl` / `B_Cu.gbl` | cuivre dessus / dessous |
| `Breadboard-pc-F_Mask.gts` / `B_Mask.gbs` | vernis épargne |
| `Breadboard-pc-F_Silkscreen.gto` / `B_Silkscreen.gbo` | sérigraphie (légende de J5 au verso) |
| `Breadboard-pc-Edge_Cuts.gm1` | contour 120 × 124,2 mm |
| `Breadboard-pc-PTH.drl` | 791 trous métallisés (vias 0,4-0,5 mm ; broches 0,76-1,1 mm ; 2,3 mm) |
| `Breadboard-pc-NPTH.drl` | 4 trous de fixation M3 (3,2 mm, non métallisés) |

`gerbers/` contient aussi les cartes de perçage (`*_map.gbr`) et le fichier de travail (`.gbrjob`), hors du zip.

## Paramètres de commande suggérés

| Paramètre | Valeur |
|---|---|
| Base Material | FR-4 |
| Layers | 2 |
| Dimensions | 120 × 124,2 mm (détectées depuis le zip) |
| PCB Thickness | 1.6 mm |
| Outer Copper Weight | 1 oz |
| Min via hole / diameter | 0,4 / 0,8 mm (pas de supplément) |
| Min track / spacing | 0,12 / 0,18 mm (≥ 0,10 mm exigé) |
| Surface Finish | HASL (with lead) ou LeadFree HASL — ENIG facultatif |
| Mark on PCB (numéro de commande) | au choix : « Remove Mark » (payant) ou laisser JLCPCB le placer |
| Assembly | non (toutes les pièces sont traversantes) |

## Vérifications faites avant l'export

- DRC KiCad avec contrôle de parité schéma/PCB : 0 erreur, 0 liaison manquante.
- DRC aux limites JLCPCB (piste/isolement 0,10 mm, anneau 0,18 mm, trou PTH-piste 0,28 mm, trou-trou 0,45 mm, bord 0,2 mm) : aucune violation cuivre (piste min. 0,12 mm, via 0,8/0,4 mm, anneau min. 0,22 mm) ; restent des avertissements de sérigraphie sans conséquence (chevauchements entre contours voisins, traits sur pastilles rognés par JLCPCB, contours standard KiCad de 0,12 mm comme sur la v1, broches du Black Pill en texte de 0,9 mm).
- Contour mesuré dans le Gerber : 120,00 x 124,20 mm.
- Zones remplies (`--check-zones`).

Régénérer (depuis `kicad/Breadboard-pc`) :

```sh
kicad-cli pcb export gerbers -o fabrication/gerbers -l F.Cu,B.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts \
  --no-x2 --no-netlist --subtract-soldermask --check-zones Breadboard-pc.kicad_pcb
kicad-cli pcb export drill -o fabrication/gerbers/ --format excellon --excellon-units mm --excellon-zeros-format decimal \
  --excellon-separate-th --generate-map --map-format gerberx2 Breadboard-pc.kicad_pcb
```

puis recréer le zip (`Breadboard-pc-JLCPCB-v2-120x124.zip`) avec les 9 fichiers du tableau ci-dessus.
