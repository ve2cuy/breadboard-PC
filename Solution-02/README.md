# Solution-02 — ordinateur 8088 / NEC V20 autonome (VE2CUY)

Ordinateur 8088 (ou NEC V20) monté sur breadboard, **sans pont STM32** :
le processeur pilote directement son LCD et sa mémoire.

- Horloge : 82C84 + quartz 16 MHz → **5,33 MHz** (16 / 3)
- ROM : 29C020 (W29C020C), 256 Ko
- RAM : HM628512, 512 Ko
- Verrous d'adresses : 2 × 74HC573 (U2 : A0–A7, U3 : A16–A19)
- Décodage : 74LS00 (U5), 74LS138 (U8), 74LS02 (U9)
- Afficheur : LCD 20×4 (HD44780 / ST7066U), bus 8 bits, en écriture seule
- E/S parallèles : 8255 (U7, µPD71055C) en 10h–13h, 24 DEL sur J1–J3
- Clavier et UART : 2e 8255 (U12) en 30h–33h — clavier PS/2 (prise USB-A J4) et UART
  logiciel 9600 8N1 (J5), en bit-bang comme dans Solution-01
- **PC-DOS 2.1 en ROM** : la disquette de 180 Ko est dans la ROM (lecteur A:,
  lecture seule) ; BIOS de type IBM PC (INT 10h, 13h, 16h…) par interruptions
  logicielles, écran DOS de 24 × 80 vu par une fenêtre de 20 × 4 sur le LCD

Schéma : [Solution02.kicad_sch](Solution02.kicad_sch).
Journal des étapes : [Directives.md](Directives.md).

## Carte mémoire

| Adresses | Contenu | Sélection |
|---|---|---|
| 00000h–7FFFFh | RAM 512 Ko | CE# = NAND(/A19, M) — U5 broche 8 |
| 80000h–FFFFFh | ROM 256 Ko | CE# = NAND(A19, M) — U5 broche 6 |

A18 n'est pas reliée à la ROM : l'image de 256 Ko apparaît deux fois
(80000h–BFFFFh et C0000h–FFFFFh). Le BIOS occupe les 64 derniers Ko de
l'image (décalage 30000h), vus en **F000:0000**. Au reset, le 8088 démarre
en FFFF:0000 = FFFF0h = F000:FFF0 (décalage 3FFF0h de l'image), où se trouve
un `JMP F000:0000`.

Contenu de la ROM et de la RAM avec le BIOS 0.8 :

| Adresses | Contenu |
|---|---|
| 00000h–003FFh | table des vecteurs d'interruption (remplie par « Load DOS ») |
| 00400h–004FFh | zone de données du BIOS (BDA) : équipement, mémoire, mode vidéo |
| 00500h–7EFFFh | DOS et programmes (**508 Ko** annoncés par INT 12h) |
| 7F000h–7FFFFh | données du BIOS (DSEG = 7F00h) : écran 24 × 80, variables, file du clavier, pile du menu |
| C0000h–ECFFFh | **disquette PC-DOS 2.1** (180 Ko : 40 cylindres, 1 tête, 9 secteurs) = décalage 0 de l'image |
| ED000h–EFFFFh | libre (FFh) |
| F0000h–FFFFFh | BIOS |

La broche PGM (WE#) de la ROM est au +5 V : une écriture du DOS ou d'un
programme dans la zone de la ROM (par exemple en B8000h, la mémoire vidéo d'un
PC) est sans effet.

## Ports d'E/S (74LS138, U8)

U8 décode **A7 = 0**, **IO/M = 1** (E1# = E2# = A7, E3 = IO/M) et
**A6–A4** (entrées A, B, C). Chaque sortie, active au niveau bas, couvre un
bloc de 16 ports :

| Sortie | Broche U8 | Ports | Usage |
|---|---|---|---|
| O0 | 15 | 00h–0Fh | **LCD (occupé)** : 00h = commande, 01h = donnée (RS = A0) |
| O1 | 14 | 10h–1Fh | **8255 (U7, occupé)** : 10h = PA, 11h = PB, 12h = PC, 13h = contrôle (A0–A1) |
| O2 | 13 | 20h–2Fh | **8259A (U13)** : 20h = ICW1/OCW2/OCW3 (A0 = 0), 21h = ICW2-4/OCW1 (masque) — comme le PC |
| O3 | 12 | 30h–3Fh | **2e 8255 (U12, occupé)** : 30h = PA, 31h = PB, 32h = PC, 33h = contrôle |
| O4 | 11 | 40h–4Fh | libre (8253 dans un PC) |
| O5 | 10 | 50h–5Fh | libre |
| O6 | 9 | 60h–6Fh | libre (8255 dans un PC) |
| O7 | 7 | 70h–7Fh | libre |

À savoir :

- **A0–A3 ne passent pas par le 138.** Elles vont directement au
  périphérique pour choisir ses registres. Un périphérique qui n'en utilise
  que quelques-unes, comme un 8255 (A0–A1), apparaît plusieurs fois dans
  son bloc : 60h–63h, puis 64h–67h, etc.
- **A8–A15 ne sont pas décodées.** Avec `IN/OUT port, AL` (port sur 8 bits),
  elles valent 0. Avec `IN/OUT DX`, chaque bloc se répète tous les 256 ports.
- **Les ports 80h–FFh (A7 = 1) ne sont pas décodés.** Un second 138 activé
  par A7 = 1 et IO/M = 1 fournirait 8 blocs de plus.
- **Pas de RD#/WR# dans le 138.** Ses sorties ne dépendent que de l'adresse.
  Elles conviennent telles quelles au CS# des puces qui reçoivent RD# et WR#
  séparément (8255, 8253, 8259, 16550…). Pour un simple verrou
  (74LS374/573) ou un tampon (74LS244), il faut combiner la sortie avec
  WR# ou RD#, comme pour le LCD : E = NOR(WR#, O0) (U9). Il reste 3 portes
  NOR libres sur U9.
- Le décodage tombe sur les mêmes blocs qu'un PC/XT : un 8259 sur O2, un
  8253 sur O4 et un 8255 sur O6 seraient aux adresses standard (20h, 40h,
  60h), ce qui facilitera un BIOS compatible.

## LCD 20×4

- Bus de données DB0–DB7 relié directement à AD0–AD7 du 8088.
- RS = A0 (verrouillée par U2), E = NOR(WR#, O0) (U9 broche 13).
- R/W à la masse : le drapeau « occupé » ne peut pas être lu, chaque
  écriture est suivie d'un délai logiciel.
- Contraste réglé par RV1 (broche VO).
- L'impulsion E dure environ 2 cycles (≈ 375 ns à 5,33 MHz) : suffisant pour
  un HD44780U (230 ns minimum), à surveiller avec un contrôleur plus lent.

## 8255 (U7) et DEL

8255 CMOS (µPD71055C) sélectionné par **O1** du 74LS138 : ports **10h–13h**
(répétés jusqu'à 1Fh, car seules A0–A1 vont au 8255).

| Broche 8255 | Signal | Vient de |
|---|---|---|
| 34, 33, 32, 31, 30, 29, 28, 27 | D0–D7 | AD0–AD7 du 8088 |
| 9, 8 | A0, A1 | U2 (74HC573) Q0, Q1 |
| 6 | CS# | U8 (74LS138) broche 14 (O1) |
| 5 | RD# | RD# (8088 broche 32) |
| 36 | WR# | WR# (8088 broche 29) |
| 35 | RESET | RESET du 82C84 (U11 broche 10, 8088 broche 21) |
| 26 / 7 | VCC / GND | +5 V / GND (+ 100 nF) |
| 4, 3, 2, 1, 40, 39, 38, 37 | PA0–PA7 | J1 broches 1–8 |
| 18–25 | PB0–PB7 | J2 broches 1–8 |
| 14, 15, 16, 17, 13, 12, 11, 10 | PC0–PC7 | J3 broches 1–8 |

J1, J2 et J3 (1×10) : broches 1–8 = PA/PB/PC 0–7, broche 9 = +5 V,
broche 10 = GND.

DEL : une sortie à 1 allume la DEL si elle est câblée **sortie → 1 kΩ →
anode, cathode → GND** (broche 10). Le 82C55 ne fournit que ~2,5 mA par
sortie : pour des DEL plus brillantes, passer par un ULN2803 ou un 74HC245.

Au RESET, le 8255 met ses 3 ports en entrée (sorties flottantes). Le BIOS
envoie le mot de contrôle **80h** (mode 0, PA, PB et PC en sortie) et éteint
les DEL dès le démarrage, juste après l'initialisation du LCD.

## 2e 8255 (U12) : clavier PS/2 et UART

8255 CMOS (µPD71055C) sélectionné par **O3** du 74LS138 : ports **30h–33h**
(20h = 8259, U13 ; 40h et 60h restent libres pour un futur 8253 ou 8255 aux
adresses d'un PC/XT). Mot de contrôle **82h** : PA et PC en sortie, PB en
entrée. Mêmes bits que Solution-01 pour le clavier.

| Broche 8255 | Signal | Vient de / va à |
|---|---|---|
| 34, 33, 32, 31, 30, 29, 28, 27 | D0–D7 | AD0–AD7 du 8088 (**dans l'ordre**) |
| 9, 8 | A0, A1 | U2 (74HC573) Q0, Q1 |
| 6 | CS# | U8 (74LS138) broche **12** (O3) |
| 5 / 36 | RD# / WR# | 8088 broches 32 / 29 |
| 35 | RESET | RESET du 82C84 (U11 broche 10) |
| 26 / 7 | VCC / GND | +5 V / GND (+ 100 nF) |
| 18 | PB0 = KBD_CLK | J4 D+ (horloge PS/2), tirage R2 10 kΩ au +5 V |
| 14 | PC0 = blocage du clavier | diode Schottky prévue en 0.6, **non posée** (voir ci-dessous) ; PC0 libre |
| 19 | PB1 = KBD_DATA | J4 D− (données PS/2), tirage R3 10 kΩ au +5 V |
| 20 | PB2 = UART_RX | J5 broche 2, tirage R4 10 kΩ au +5 V |
| 37 | PA7 = UART_TX | J5 broche 1 |

- **J4, prise USB-A femelle** : pour un clavier USB **à repli PS/2** (la
  plupart des claviers USB ordinaires). VBUS = +5 V, **D+ = horloge,
  D− = données** (comme Solution-01), GND et blindage à la masse. Les tirages R2/R3 sont
  indispensables : c'est en voyant D+ et D− tirés au +5 V que le clavier
  choisit le mode PS/2. Un clavier PS/2 natif se branche sur les mêmes
  signaux (horloge, données, +5 V, GND).
- **J5, UART TTL 5 V** : 1 = TX (sortie), 2 = RX (entrée), 3 = GND. Avec un
  adaptateur USB-série 5 V : **RX de l'adaptateur sur J5-1, TX de
  l'adaptateur sur J5-2**, GND sur J5-3. Terminal : 9600 bauds, 8N1, sans
  contrôle de flux.

### Blocage du clavier (diode sur PC0) — abandonné

Sous DOS, le BIOS n'écoute le clavier que pendant les appels de INT 16h ; à
l'invite, PC-DOS 2.1 boucle sur INT 16h AH=01h puis INT 28h. Une trame qui
commence entre deux appels serait perdue (une touche qui manque, ou un code de
relâchement perdu qui fait répéter la touche). Comme le contrôleur de clavier
du PC/AT, le BIOS (depuis la version 0.6) **bloque l'horloge du clavier** quand il n'écoute pas :
PC0 = 0 tire KBD_CLK à la masse par la diode ; le clavier garde alors ses
touches en mémoire et les envoie dès que l'horloge est relâchée (une trame
interrompue avant son 10e bit est renvoyée). PC0 est commandé par les mots de
mise à 0/1 d'un bit du 8255 (BSR) : PA7 (TX de l'UART) n'est pas touché.

Sans la diode, rien ne change (PC0 n'est relié à rien) : le BIOS compense en
écoutant plus longtemps (~8 ms) quand DOS attend sans rien afficher, mais une
touche peut encore se perdre de temps en temps. **Décision (2026-11-14) : la
diode ne sera pas posée** ; le 8259 (U13, ci-dessous) signale le début de
chaque trame du clavier et de chaque octet de l'UART par une interruption.

## 8259A (U13) : interruptions du clavier et de l'UART

8259A sélectionné par **O2** du 74LS138 : ports **20h–21h**, comme dans un
PC (A0 du bus = A0 du 8259). Contrôleur unique (maître) : SP/EN au +5 V,
CAS0–CAS2 libres. Le 8088 n'avait aucune interruption matérielle : **INTR
(broche 18) est détachée de la masse** et reçoit INT du 8259 ; INTA (broche
24, mode minimum) va au 8259. NMI, TEST et HOLD restent à la masse.

| Broche 8259 | Signal | Vient de / va à |
|---|---|---|
| 11, 10, 9, 8, 7, 6, 5, 4 | D0–D7 | AD0–AD7 du 8088 (**dans l'ordre**) |
| 27 | A0 | U2 (74HC573) Q0 |
| 1 | CS# | U8 (74LS138) broche **13** (O2) |
| 3 / 2 | RD# / WR# | 8088 broches 32 / 29 |
| 17 | INT | 8088 broche **18** (INTR) |
| 26 | INTA# | 8088 broche **24** (INTA#) |
| 16 | SP#/EN# | +5 V (maître unique) |
| 12, 13, 15 | CAS0–CAS2 | libres |
| 19 | IR1 = IRQ1 | U14 (74LS14) broche 2 = KBD_CLK inversée |
| 22 | IR4 = IRQ4 | U14 broche 4 = UART_RX inversée |
| 18, 20, 21, 23–25 | IR0, IR2, IR3, IR5–IR7 | libres (masquées par le BIOS) |
| 28 / 14 | VCC / GND | +5 V / GND (+ 100 nF) |

Le 8259 réagit au **front montant** (mode front, comme le PC) ; or une trame
PS/2 commence par un front **descendant** de l'horloge et un octet série par un
front descendant de RX (bit de départ). **U14 (74LS14, trigger de Schmitt)
inverse donc KBD_CLK** (broche 1 → 2, vers IR1) **et UART_RX** (broche 3 → 4,
vers IR4) ; les portes 3 à 6 sont inutilisées, entrées à la masse (VCC
broche 14, GND broche 7). Les bits eux-mêmes restent lus par U12 (PB0, PB1,
PB2) : la routine d'interruption lit la trame ou l'octet entier par
scrutation, comme le BIOS 0.7, mais elle démarre dès le premier front, même
quand le DOS ne demande rien (BIOS 0.8). Numéros comme le PC : IRQ1 = INT 09h (clavier),
IRQ4 = INT 0Ch (COM1).

À retenir pour le logiciel : le 8259 doit servir l'interruption pendant que
l'entrée est encore haute (horloge du clavier basse, ~40 µs ; bit de départ,
104 µs) ; sinon il produit une interruption « IRQ7 » parasite. Le BIOS doit
donc éviter les longues sections sans interruptions (CLI).

### Calibration de l'UART

L'UART est logiciel : la durée d'un bit dépend du processeur et de son
horloge. `UART_N` (dans `bios.asm`, valeur par défaut 29 pour un 8088 à
5,33 MHz) est une **estimation** à vérifier :

1. Brancher l'oscilloscope sur J5-1 (TX) et redémarrer : la bannière est
   émise juste après le test de la RAM.
2. Mesurer la largeur d'un bit (le plus court palier) : il faut
   **104,2 µs** (9600 bauds).
3. Trop long → diminuer `UART_N` ; trop court → l'augmenter. Une unité
   ≈ 3,2 µs (3 % d'un bit) sur un 8088 à 5,33 MHz. Le récepteur utilise la
   même constante.
4. Recompiler avec la nouvelle valeur, sans modifier le source :
   `make clean && make UART_N=28` (puis graver). Un V20 (instructions plus
   rapides) demande une valeur plus grande.

## BIOS 0.8

Sources : [bios/bios.asm](bios/bios.asm) (démarrage, menu, test de la RAM,
DEL, clavier, UART) et [bios/services.inc](bios/services.inc) (services de
type IBM PC). Déroulement :

1. **Écran d'ouverture** (~2 s) : `SOLUTION-02 BIOS 0.8`,
   `CPU 8088/V20 5.33MHz`, `RAM 512 Ko  LCD 20x4`, `VE2CUY - 2026`.
2. **Vérification rapide** des 4 Ko de données du BIOS (7F000h–7FFFFh) ; en
   cas d'échec, le test complet de la RAM part d'office. Bannière sur l'UART.
3. **Menu**, au clavier PS/2 (touches 1 à 4). En entrant au menu, le BIOS
   installe les vecteurs, réinitialise le 8259 et le **détecte** en relisant
   son registre de masque (A5h puis 5Ah) :
   - **8259 présent** : le clavier (IRQ1, INT 09h) et la réception de l'UART
     (IRQ4, INT 0Ch) passent par les **interruptions**. La routine lit la trame
     ou l'octet par scrutation de U12 dès le premier front, le décode et le met
     dans une file (16 touches, 32 octets). Rien n'est perdu pendant que le
     programme fait autre chose (affichage, `DIR`…). IRQ7 (INT 0Fh) compte les
     interruptions parasites (demande retombée avant INTA) ;
   - **8259 absent** (pas encore câblé) : scrutation pendant les attentes,
     comme le BIOS 0.7.

```
1) Load DOS
2) Test memory
3) LED Show
4) SysInfo
```

### 1) Load DOS

Le BIOS remplit la table des vecteurs (256 vecteurs vers un `IRET`, puis les
siens), la zone de données (BDA : 1 lecteur de disquette, vidéo 80 colonnes,
508 Ko), vide l'écran et amorce A: (INT 19h : secteur 0 en 0000:7C00). Les
services du BIOS rétablissent les interruptions (STI) : IRQ1 et IRQ4 sont
servies même pendant l'affichage. PC-DOS 2.1 demande la date et l'heure (Entrée, Entrée ; il n'y a
pas d'horloge), puis affiche `A>`.

| INT | Service |
|---|---|
| 10h | écran : AH = 00h, 02h, 03h, 06h, 07h, 08h, 09h, 0Ah, **0Eh (télétype)**, 0Fh |
| 11h / 12h | équipement (0021h) / mémoire (508 Ko) |
| 13h | disquette A: **en ROM**, lecture seule : AH = 00h, 01h, 02h, 04h, 08h, 15h, 16h ; écriture/formatage → erreur 03h (protégée) ; autre lecteur → erreur |
| 09h / 0Ch / 0Fh | IRQ1 clavier / IRQ4 UART / IRQ7 parasite (8259) |
| 14h | AH = 01h : envoi sur l'UART logiciel ; AH = 02h : octet reçu par IRQ4 (attente ~0,5 s, sinon AH = 80h) ; AH = 03h : état (AH bit 0 = octet en attente) — réception seulement avec le 8259 |
| 16h | clavier : AH = 00h, 01h, 02h, 05h (et 10h–12h) ; AH = code XT, AL = ASCII, comme un PC ; file remplie par IRQ1 |
| 15h, 17h | sans objet (pas de services AT, pas d'imprimante) |
| 18h | retour au menu |
| 19h | amorçage de A: |
| 1Ah | compteur de tops du BDA — **pas de minuterie** : l'heure du DOS ne change pas |

**Écran** : le DOS écrit dans un tampon de **24 lignes × 80 colonnes** (en
7F000h), en mode télétype (retour à la ligne en colonne 80, défilement en bas).
Le LCD montre une **fenêtre de 20 × 4** de ce tampon. Verticalement, elle suit
le curseur : ce sont les dernières lignes écrites par le programme.
Horizontalement, elle ne bouge pas pendant l'affichage : seuls les caractères
de ses 20 colonnes sont envoyés au LCD (les autres ne vont que dans le tampon).
Quand le DOS attend une touche (lecture INT 16h AH=00h, ou 10 appels AH=01h de
suite sans affichage), la fenêtre se place, par pas de 10 colonnes, pour
montrer le curseur s'il est hors champ (par exemple en tapant une commande de
plus de 20 caractères). Le curseur du LCD (souligné) marque la position du
curseur quand elle est dans la fenêtre.

**Navigation** (sous DOS, pendant que le clavier est lu, par exemple à l'invite
`A>`) :

| Touches | Effet |
|---|---|
| Maj (gauche ou droite) + ↑ / ↓ | fenêtre d'une ligne vers le haut / le bas |
| Maj (gauche ou droite) + ← / → | fenêtre de 10 colonnes vers la gauche / la droite |
| Ctrl + Alt + Suppr | redémarrage du BIOS (écran d'ouverture, menu) |

Le prochain affichage ramène la fenêtre sur la ligne du curseur ; la colonne
choisie reste jusqu'à la prochaine attente du clavier qui suit un affichage.
La Maj est aussi reconnue par le « relâchement factice » (E0 F0 12h ou
E0 F0 59h) que le clavier envoie juste avant la flèche : la navigation marche
même si l'appui de Maj a été perdu (montage sans diode).

Limites : pas de minuterie (heure figée, pas de `INT 08h`), pas de mémoire
vidéo (un programme qui écrit directement en B800h n'affiche rien), disque en
lecture seule (`COPY`, `DEL`… vers A: → « Write protect error »), un seul
lecteur (B: = A: pour le DOS), disposition de clavier US.

### 2) Test memory

Test complet de la RAM, fait **sans pile ni variables** (macros seulement),
donc fiable même si la RAM est défectueuse :

- **motifs** : chaque bloc de 1 Ko est rempli puis relu avec 55AAh, AA55h,
  0000h et FFFFh, de sorte que chaque octet voit AAh, 55h, 00h et FFh
  (mêmes motifs que Solution-01). Environ 7 s pour 512 Ko ;
- **lignes d'adresse A0–A18** (méthode de Solution-01) : 5Ah à l'adresse
  de base 35555h, puis k+1 à 35555h xor 2ᵏ, et relecture. Une ligne
  coupée ou en court-circuit fait tomber deux adresses sur la même case ;
  une puce de 128 ou 256 Ko vendue pour 512 Ko échoue sur A17/A18.

RAM bonne : effacement à 0, pile en 7F00:1000 vérifiée par PUSH/POP,
`PILE OK  Touche=menu`. RAM défectueuse : le résultat reste affiché avec un
compteur (pas de retour au menu : il faut une RAM saine).

### 3) LED Show

9 animations en boucle sur les 24 sorties du 8255 U7, vues comme une seule
rangée disposée ainsi sur le montage, de gauche à droite : **PC7 … PC0,
PA7 … PA0, PB7 … PB0**. Un cycle complet dure ~35 s. **Échap** ramène au menu.

| Animation | Effet |
|---|---|
| Chenillard | une DEL parcourt la rangée de gauche à droite (2 tours) |
| Balayage | 3 DEL font l'aller-retour, de gauche à droite puis retour (3 fois) |
| Remplissage | la rangée se remplit de gauche à droite, puis se vide (2 fois) |
| Explosion | 2 DEL partent du centre vers les bouts, puis reviennent (2 fois) |
| Alternance | damier qui s'inverse (10 pas lents) |
| Compteur/Gray | PB (droite) = compteur binaire, PA (centre) = son code de Gray, PC (gauche) = compteur / 8 |
| Ports C A B | PC, PA puis PB allumés à tour de rôle (de gauche à droite), puis tout clignote |
| Etincelles | DEL allumées au hasard (~1 sur 4) |
| Vu-metre | une barre partie de la gauche (0 à 24 DEL) monte et descend vers des niveaux aléatoires |

Pendant les animations, terminal clavier / UART :

- **touche** → ligne 3 du LCD et envoi sur l'UART (Entrée = CR LF et
  efface la ligne, retour arrière = efface le dernier caractère,
  flèches = séquences ANSI `ESC [ A/B/C/D`) ;
- **octet reçu sur l'UART** → ligne 4 du LCD et **écho** sur l'UART.

Écran : `LED SHOW  Echap=menu`, le nom de l'animation et le nombre de cycles
complets, puis `Clavier PS/2 >` et `UART 9600 8N1 >`, remplacés par le texte
au premier caractère.

Avec le 8259, les touches et les octets reçus arrivent par IRQ1/IRQ4 et sont
traités pendant les attentes des animations. Limites : l'envoi d'un caractère
sur l'UART masque les interruptions (~1 ms) : une trame du clavier ou un octet
qui commence à ce moment peut être perdu (ou donner une IRQ7 parasite), de même
qu'un octet reçu pendant la lecture d'une trame du clavier (et inversement).
Sans 8259 : scrutation, une touche frappée pendant l'envoi d'un caractère ou le
changement d'animation peut être perdue.

### 4) SysInfo

Version du BIOS, processeur (**8088** ou **NEC V20**, reconnu par
l'instruction AAD : le V20 ignore son opérande), mémoire et ROM, et le 8259 :
`8259 OK   IRQ7 nnnn` (nombre d'IRQ7 parasites, en hexadécimal, depuis le
démarrage) ou `8259 absent (scrut.)`. Une touche ramène au menu.

### Clavier

Disposition **US** (tables `clavier_us.inc`, générées par
`tests/gen_clavier.py` : ASCII sans et avec Maj, et code XT rendu dans AH par
INT 16h), Maj, Ctrl (Ctrl+lettre = 01h–1Ah), Alt (ASCII 0), Verr Maj (sans
voyant), pavé numérique (Verr Num supposé actif), touches de fonction F1–F12,
flèches, Inser, Suppr, Début, Fin, Page préc./suiv. (ASCII 0, code XT dans
AH). Les Maj « factices » que le clavier envoie autour des flèches (E0 12,
E0 F0 12) sont ignorées.

Écran du test :

| Ligne | Pendant le test | RAM bonne | RAM défectueuse |
|---|---|---|---|
| 1 | `TEST MEMOIRE 512 Ko` | `MEMOIRE 512 Ko : OK` | `RAM DEFAUT  CPT nnnn` |
| 2 | `Ko: nnn  Defauts nnn` (Ko testés, Ko défectueux) | idem | idem |
| 3 | — | `Adresses A0-A18: OK` | `Adresses: ERR Ann` ou `Adresses: ERR base` |
| 4 | premier défaut : `ERR aaaaa ee/ll` | `PILE OK  Touche=menu` | premier défaut |

Le compteur hexadécimal (CPT) montre que le processeur tourne malgré le défaut. Lecture des
erreurs :

- `ERR aaaaa ee/ll` : premier octet fautif, à l'adresse physique aaaaa ;
  ee = valeur attendue, ll = valeur lue. Si ee et ll diffèrent d'un seul bit,
  vérifier la ligne de données correspondante ;
- `Adresses: ERR Ann` : ligne d'adresse Ann coupée, collée ou en
  court-circuit ;
- `Adresses: ERR base` : la case de base ne retient rien (RAM absente ou
  non sélectionnée).

Le simulateur (`make test`, [bios/tests/sim.py](bios/tests/sim.py)) modélise le
LCD, les deux 8255, un **vrai clavier PS/2** et l'UART (la trame part à son
heure, que le BIOS écoute ou non ; perdue si PB n'est pas lu pendant la trame),
le **8259** (ICW, masque, EOI, mode front : demande mémorisée au front montant,
valable seulement si l'entrée est encore haute ; INT levée jusqu'à INTA ; IRQ7
parasite sinon) relié par le 74LS14 (IR1 = horloge inversée, IR4 = RX
inversée), les interruptions matérielles servies entre deux instructions quand
IF = 1 (pas juste après STI), et l'aiguillage des interruptions logicielles du
mode réel. 12 scénarios : démarrage et
menu (pile, bannière UART) ; Test memory avec RAM saine puis retour au menu ;
cellule 7B3FFh défectueuse, RAM absente (test complet d'office), ligne A15
coupée, puce de 128 Ko ; LED Show (24 DEL vues allumées et éteintes) ;
terminal (Maj+a, b, 1, retour arrière, flèche haut, « Hi » reçu, Échap) ;
SysInfo avec et **sans 8259** (repli sur la scrutation) ; **Load DOS** :
PC-DOS 2.1 démarre depuis la ROM, date et heure (Entrée), `DIR`, Maj + ↑ ×3 et
Maj + →, saisie longue, Ctrl + Alt + Suppr, avec vérification qu'aucune trame
du clavier n'est perdue avant Ctrl + Alt + Suppr, qu'aucun vecteur non géré
n'est appelé et qu'aucun `OUT` du DOS n'atteint le LCD ou les 8255 ; **frappe
anticipée** : `rem abc` tapé pendant que `DIR` s'affiche apparaît à l'invite
suivante (IRQ1). Réception UART sous DOS (INT 14h AH=02h) : pas encore de
scénario.

Commandes (depuis `bios/`) :

```sh
make            # build/solution-02-bios.bin (image de 256 Ko)
make test       # simulateur tests/sim.py (12 scénarios, ~4 min ; un seul : python tests/sim.py build/solution-02-bios.bin dos)
make diag       # ROM de diagnostic du 8255 U7 (écritures en rafale) ; graver : make flash PUCE=ok GRAVER=diag
make diag2      # ROM de diagnostic de U12 (PC/PA clignotent, PB et trames PS/2 au LCD) ; GRAVER=diag2
make flash PUCE=ok   # graver la W29C020C (TL866CS, minipro sous WSL) — insérer la puce d'abord
```

## Câblage de la RAM (HM628512, U6)

| Broche RAM | Signal | Vient de |
|---|---|---|
| 12, 11, 10, 9, 8, 7, 6, 5 | A0–A7 | U2 (74HC573) Q0–Q7 |
| 27, 26, 23, 25, 4, 28, 3, 31 | A8–A15 | 8088 broches 8, 7, 6, 5, 4, 3, 2, 39 |
| 2, 30, 1 | A16, A17, A18 | U3 (74HC573) Q4, Q5, Q6 |
| 13, 14, 15, 17–21 | DQ0–DQ7 | AD0–AD7 du 8088 |
| 22 | CE# | U5 broche 8 (NAND(/A19, M)) |
| 24 | OE# | RD# (8088 broche 32) |
| 29 | WE# | WR# (8088 broche 29) |
| 32 / 16 | VCC / VSS | +5 V / GND |

Attention : sur la RAM, A14 est à la broche 3 et A15 à la broche 31 ; sur la
ROM, A14 est à la broche 29 et A15 à la broche 3.

## État

- 2026-11-14 : 8259 (U13) et 74LS14 (U14) câblés, mais le BIOS 0.8 ne détecte pas le 8259 (SysInfo : « 8259 absent ») : fonctionne en scrutation, câblage à vérifier.
- 2026-11-14 : U14 = 74LS14 (au lieu de 74HC14), testée au TL866 (6 inverseurs OK) ; BIOS 0.8 gravé.
- 2026-11-14 : BIOS 0.8 : clavier (IRQ1) et réception UART (IRQ4) par le 8259, détecté au menu (sinon scrutation comme le 0.7) ; INT 14h AH=02h/03h ; SysInfo : 8259 et IRQ7 parasites. Simulé (12 scénarios), pas encore gravé.
- 2026-11-14 : schéma : 8259A (U13) sur O2 (20h–21h), INT → INTR, INTA ; 74HC14 (U14) : IRQ1 = KBD_CLK inversée, IRQ4 = UART_RX inversée. Pas encore câblé ; BIOS 0.8 à venir.
- 2026-11-14 : BIOS 0.7 : sous DOS, seules les 20 colonnes de la fenêtre vont au LCD (la fenêtre ne suit plus le curseur horizontalement pendant l'affichage) ; Maj gauche reconnue pour la navigation (Maj gauche/droite suivies séparément, Maj factice). Pas de diode : 8259 à venir.
- 2026-11-14 : BIOS 0.6 : menu, PC-DOS 2.1 en ROM (Load DOS), services INT 10h/13h/16h…, écran 24 × 80 vu par le LCD (Maj + flèches), Test memory, LED Show, SysInfo. Diode de blocage du clavier (PC0) à ajouter.
- 2026-11-14 : clavier PS/2 et UART validés sur le montage (BIOS 0.5) après correction de J4 (D+ = horloge) et pose de R4.
- 2026-11-14 : 2e 8255 (U12) au schéma avec J4 (clavier USB/PS/2) et J5 (UART) ; BIOS 0.5 (clavier + UART) prêt, `UART_N` à calibrer.
- 2026-11-13 : 8255 fonctionnel (D0–D7 avaient été inversés au câblage). BIOS 0.4 (animations adaptées à la disposition des DEL : C7…C0, A7…A0, B7…B0) gravé.
- 2026-11-13 : BIOS 0.2 essayé sur le montage : test complet de la RAM, lignes d'adresse et pile OK.
- 2026-11-13 : 8255 (U7) ajouté au schéma en 10h–13h, avec J1–J3 pour les DEL ; BIOS 0.3 (animations) gravé.
- 2026-11-13 : RAM câblée, `RAM 512 Ko : OK` avec le BIOS 0.1. BIOS 0.2 (test complet + pile) gravé.
- 2026-11-13 : montage fonctionnel avec un **8088 NMOS** et les **74HC573
  sans résistances de tirage** (cause des premiers échecs : A8–A10 non
  reliées). Les 4 lignes s'affichent et le compteur s'incrémente.
- À ajouter au schéma : condensateurs de découplage (100 nF par circuit
  intégré) et connecteur d'alimentation.
