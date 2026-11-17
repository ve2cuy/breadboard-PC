# Dossier de fabrication — PCB de Solution-02 (JLCPCB)

*[English version](README.md)*

Carte de **172 × 100 mm**, 2 couches, 1,6 mm, entièrement en composants traversants (aucun
assemblage à commander). Révision A, 2026-11-17.

Fichier à téléverser sur jlcpcb.com : **`Solution02-JLCPCB-revA-172x100.zip`**

Contenu (Gerber RS-274X sans X2, extensions Protel ; perçages Excellon, mm, décimal) :

| Fichier | Couche |
|---|---|
| `Solution02-F_Cu.gtl` / `B_Cu.gbl` | cuivre dessus / dessous |
| `Solution02-F_Mask.gts` / `B_Mask.gbs` | vernis épargne |
| `Solution02-F_Silkscreen.gto` / `B_Silkscreen.gbo` | sérigraphie (au verso : brochage de J10 et de J11) |
| `Solution02-Edge_Cuts.gm1` | contour 172 × 100 mm, coins arrondis de 3 mm |
| `Solution02-PTH.drl` | 915 trous métallisés (vias de 0,4 mm, broches de 0,8 à 1,1 mm, prises) |
| `Solution02-NPTH.drl` | 7 trous non métallisés de 3,2 mm : 3 de fixation de la carte, 4 du module LCD |

`gerbers/` contient aussi les cartes de perçage (`*_map.gbr`) et le fichier de travail (`.gbrjob`), hors du zip.
`drc.json` est le rapport du DRC de KiCad, `verif_pistes.txt` celui du contrôle indépendant des pistes.

## Paramètres de commande suggérés

| Paramètre | Valeur |
|---|---|
| Base Material | FR-4 |
| Layers | 2 |
| Dimensions | 172 × 100 mm (détectées depuis le zip) |
| PCB Thickness | 1.6 mm |
| Outer Copper Weight | 1 oz |
| Min via hole / diameter | 0,4 / 0,8 mm (pas de supplément) |
| Min track / spacing | 0,127 / 0,18 mm (JLCPCB : 0,127 / 0,127 mm) |
| Surface Finish | HASL (with lead) ou LeadFree HASL — ENIG facultatif |
| Mark on PCB (numéro de commande) | au choix : « Remove Mark » (payant) ou laisser JLCPCB le placer |
| Assembly | non (toutes les pièces sont traversantes) |

## Vérifications faites avant l'export

1. **DRC de KiCad avec contrôle de parité schéma/PCB** : 0 erreur, 0 liaison manquante, 0 écart de parité ; 104 avertissements de sérigraphie sans conséquence (contours voisins qui se chevauchent, traits rognés sur des pastilles, prises J4 et J6 en débord du bord).
2. **Contrôle indépendant des pistes** (`pcb/verif_pistes.py`, sans le moteur de connectivité de
   KiCad) : à partir de la seule géométrie du cuivre — 688 pastilles, 4247 segments de
   piste, 227 vias, plans de masse ignorés — chaque net de la netliste du schéma forme un seul
   îlot (**0 coupure**), aucun îlot ne touche deux nets (**0 court-circuit**), et
   l'isolement minimal mesuré entre deux nets est de **0,182 mm**.
3. **Netliste extraite du cuivre = netliste du schéma** (183 nets, 685 broches). Pour
   les 57 composants d'origine, c'est aussi, net pour net, celle du simulateur, qui démarre le
   BIOS, PC-DOS et MS-DOS avec ce câblage : la carte est donc câblée comme le montage simulé.
4. Limites de JLCPCB : piste minimale 0,127 mm, isolement minimal 0,18 mm, vias 0,8 / 0,4 mm,
   cuivre à 0,5 mm au moins du bord, trous de 0,4 à 3,5 mm (les fentes de la prise jack sont des
   trous oblongs métallisés).
5. Mécanique : aucun composant haut sous le module LCD, entretoises dégagées (rayon de 3 mm),
   prises USB et jack en débord du bord gauche et du bord inférieur.

## Montage

- **LCD 20×4 (2004A, 98 × 60 mm)** : barrette femelle 1 × 16 de 8,5 mm soudée sur la carte, barrette
  mâle sous le module, **4 entretoises M3 de 12 mm** (trous à 93 × 55 mm). Sous le module : U6, U7,
  U9, U12–U15 et des résistances. **Avant de commander, vérifier sur votre module** la position de
  la barrette (broche 1 à 10 mm du bord gauche et 2,5 mm du bord supérieur) et l'entraxe des trous :
  ces cotes varient d'un fabricant à l'autre.
- Supports : sous le LCD, des supports tulipe ou à profil bas (ou les puces soudées) ; 12 mm
  laissent environ 9,5 mm sous le module.
- **U4** : support ZIF 32 broches (3M 232-1285 ou équivalent), levier vers le bas de la carte.
- **Alimentation : 5 V régulés seulement** (J6, jack 2,1 mm à centre positif, ou J7). Il n'y a ni
  régulateur ni protection contre l'inversion.
- Ordre conseillé : résistances, condensateurs de découplage (C4–C19, 100 nF), supports, barrettes,
  bargraphes (broche 1 à gauche, côté des connecteurs J1–J3), prises, puis les pièces hautes.

## Régénérer

Depuis `Solution-02/` (KiCad 10 ; Freerouting 2.5 sous WSL pour le routage) :

```sh
kicad-cli sch export netlist --format kicadxml -o pcb/net.xml Solution02.kicad_sch
python.exe pcb/build_pcb.py .                 # Python de KiCad : empreintes, nets, contour (placement : pcb/place.py)
python.exe pcb/route_prep.py . s02.dsn        # règles du projet et export Specctra
freerouting -de s02.dsn -do s02.ses           # routage (sous WSL)
python.exe pcb/route_import.py . s02.ses      # pistes, plans de masse, sérigraphie
python.exe pcb/verif_pistes.py Solution02.kicad_pcb pcb/net.xml fabrication/verif_pistes.txt
bash pcb/fab.sh . Solution02-JLCPCB-revA-172x100                     # DRC, Gerber, perçages, zip
```

`pcb/gen_lcd.py` produit l'empreinte et le modèle 3D du module LCD (`Solution02.pretty`,
`Solution02.3dshapes`).
