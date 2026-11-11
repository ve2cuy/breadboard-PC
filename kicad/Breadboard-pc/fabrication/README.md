# Dossier de fabrication — Breadboard-pc (JLCPCB)

> **Version 1 (commandée le 2026-11-10, commit a56163d).** Le PCB du projet est maintenant la
> v2 (120 x 124,2 mm, condensateurs traversants, J5 bus 2 x 20, JP3) : ces fichiers ne la
> représentent pas. Régénérer le dossier (commandes ci-dessous) avant de commander la v2.

Fichier à téléverser sur jlcpcb.com : **`Breadboard-pc-JLCPCB-110x110.zip`**

Contenu (Gerber RS-274X sans X2, extensions Protel ; perçages Excellon, mm, décimal) :

| Fichier | Couche |
|---|---|
| `Breadboard-pc-F_Cu.gtl` / `B_Cu.gbl` | cuivre dessus / dessous |
| `Breadboard-pc-F_Mask.gts` / `B_Mask.gbs` | vernis épargne |
| `Breadboard-pc-F_Silkscreen.gto` / `B_Silkscreen.gbo` | sérigraphie (C1-C11 sous la carte) |
| `Breadboard-pc-Edge_Cuts.gm1` | contour 110 × 110 mm |
| `Breadboard-pc-PTH.drl` | 749 trous métallisés (vias 0,4 mm ; broches 0,76-1,1 mm ; 2,3 mm) |
| `Breadboard-pc-NPTH.drl` | 4 trous de fixation M3 (3,2 mm, non métallisés) |

`gerbers/` contient aussi les cartes de perçage (`*_map.gbr`) et le fichier de travail (`.gbrjob`), hors du zip.

## Paramètres de commande suggérés

| Paramètre | Valeur |
|---|---|
| Base Material | FR-4 |
| Layers | 2 |
| Dimensions | 110 × 110 mm (détectées depuis le zip) |
| PCB Thickness | 1.6 mm |
| Outer Copper Weight | 1 oz |
| Min via hole / diameter | 0,4 / 0,8 mm (pas de supplément) |
| Min track / spacing | 0,125 / 0,2 mm (≥ 0,10 mm exigé) |
| Surface Finish | HASL (with lead) ou LeadFree HASL — ENIG facultatif |
| Mark on PCB (numéro de commande) | au choix : « Remove Mark » (payant) ou laisser JLCPCB le placer |
| Assembly | non (toutes les pièces sont traversantes, sauf C1-C11 en CMS 1206 à souder à la main) |

## Vérifications faites avant l'export

- DRC KiCad avec contrôle de parité schéma/PCB : 0 erreur, 0 liaison manquante.
- DRC aux limites JLCPCB (piste/isolement 0,10 mm, anneau 0,18 mm, trou PTH-piste 0,28 mm, bord 0,2 mm) : aucune violation cuivre ; restent des avertissements de sérigraphie sans conséquence (traits sur pastilles, rognés par JLCPCB).
- Zones remplies (`--check-zones`).

Régénérer (depuis `kicad/Breadboard-pc`) :

```sh
kicad-cli pcb export gerbers -o fabrication/gerbers -l F.Cu,B.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts \
  --no-x2 --no-netlist --subtract-soldermask --check-zones Breadboard-pc.kicad_pcb
kicad-cli pcb export drill -o fabrication/gerbers/ --format excellon --excellon-units mm --excellon-zeros-format decimal \
  --excellon-separate-th --generate-map --map-format gerberx2 Breadboard-pc.kicad_pcb
```

puis recréer le zip avec les 9 fichiers du tableau ci-dessus.
