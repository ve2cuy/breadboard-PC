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

Contenu de la ROM et de la RAM avec le BIOS 2.1 :

| Adresses | Contenu |
|---|---|
| 00000h–003FFh | table des vecteurs d'interruption (remplie par « Load DOS ») |
| 00400h–004FFh | zone de données du BIOS (BDA) : équipement, mémoire, mode vidéo |
| 00500h–5EFFFh | DOS et programmes (**380 Ko** annoncés par INT 12h ; **508 Ko** quand B: est l'image DOS 2.1 de la carte) |
| 10000h–1FFFFh | (hors DOS) segment du **BASIC** (menu 6) : programme, variables, pile |
| 5F000h–7EFFFh | **lecteur B:** : disque virtuel de 128 Ko (conservé après Ctrl + Alt + Suppr) |
| 7F000h–7FFFFh | données du BIOS (DSEG = 7F00h) : écran 24 × 80, variables, files, copie du LCD, pile des animations (900h–AFFh), pile du menu |
| C0000h–ECFFFh | **disquette PC-DOS 2.1 réduite** (180 Ko : 40 cylindres, 1 tête, 9 secteurs) = décalage 0 de l'image |
| ED000h–EFFFFh | libre (FFh) |
| F0000h–F7FFFh | BIOS |
| F8000h–FFFEFh | **BASIC** (basic_s02.asm : le BASIC de Solution-01, ~25 Ko) |
| FFFF0h | RESET |

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
| O3 | 12 | 30h–3Fh | **2e 8255 (U12, occupé)** : 30h = PA, 31h = PB, 32h = PC, 33h = contrôle (clavier, UART logiciel, lecteur SD) |
| O4 | 11 | 40h–4Fh | **8253-2 (U15)** : 40h–42h = compteurs 0–2, 43h = mode (A0–A1) |
| O5 | 10 | 50h–5Fh | libre |
| O6 | 9 | 60h–6Fh | **verrou du port 61h (U16)** : bit 0 = GATE2, bit 1 = haut-parleur (écriture seule) |
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
  WR# ou RD#, comme pour le LCD : E = NOR(WR#, O0) (U9) et le verrou du port
  61h : horloge = OR(WR#, O6) (U9). Les 4 portes NOR de U9 sont utilisées.
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

**Bargraphes** (comme Solution-01) : trois HDSP-4830 (BAR1–BAR3) en
parallèle sur J1–J3, câblés en **chaîne contiguë de 30 DEL**, comme les lignes
d'adresse de Solution-01 : anode sur la sortie du 8255, cathode à la masse par
**390 Ω** — segments 1 à 9 par un réseau de 9 résistances à point commun
(RN1–RN3, SIP10), segment 10 par une résistance seule (R5–R7).

| Bargraphe | Broches d'anode 1 → 10 | Cathodes |
|---|---|---|
| BAR1 | 1–6 libres (bits 24–29), 7–10 = PC7 → PC4 | RN1 + R5 |
| BAR2 | PC3 → PC0, PA7 → PA2 | RN2 + R6 |
| BAR3 | PA1, PA0, PB7 → PB0 | RN3 + R7 |

Bit 0 (PB0) = broche 10 de BAR3, bit 23 (PC7) = broche 7 de BAR1 : posés de
gauche à droite (BAR1, BAR2, BAR3, broche 1 à gauche), les bargraphes montrent
la rangée du BIOS (PC7 … PB0) avec les 6 DEL de poids fort éteintes à gauche.
Le courant est limité par la sortie du 82C55 (~2,5 mA) plutôt que par les
390 Ω.

Au RESET, le 8255 met ses 3 ports en entrée (sorties flottantes). Le BIOS
envoie le mot de contrôle **80h** (mode 0, PA, PB et PC en sortie) et éteint
les DEL dès le démarrage, juste après l'initialisation du LCD.

## 8253 (U15) : minuterie

**NEC D8253C-2** (horloge jusqu'à **5 MHz**) sélectionné par **O4** du
74LS138 : ports **40h–43h**, comme le PC (répétés jusqu'à 4Fh). L'horloge est
PCLK du 82C84 (16 MHz / 6 = **2,67 MHz**) : il faut une 8253-2 (5 MHz) ou une
8254 (8 MHz) ; une 8253 ou une 8253-5 ordinaire est limitée à 2,6 MHz. Au
schéma, le symbole est celui de la 82C54 (même brochage). Le BIOS n'utilise
que ce qu'ont toutes ces puces : le mode 3 et le verrouillage du compteur
(mot 00h).

| Broche 8253 | Signal | Vient de / va à |
|---|---|---|
| 8 → 1 | D0 → D7 | AD0–AD7 du 8088 |
| 19, 20 | A0, A1 | U2 (74HC573) Q0, Q1 |
| 21 | CS# | U8 (74LS138) broche 11 (O4) |
| 22 / 23 | RD# / WR# | 8088 broches 32 / 29 |
| 9, 15, 18 | CLK0, CLK1, CLK2 | PCLK : U11 (82C84) broche 2 |
| 11, 14 | GATE0, GATE1 | +5 V |
| 16 | GATE2 | bit 0 du port 61h (U16 broche 5) |
| 10 | OUT0 | IR0 du 8259 (U13 broche 18) : **IRQ0, INT 08h** |
| 17 | OUT2 | haut-parleur (par U14 et U9, voir « Son ») |
| 13 | OUT1 | libre |
| 24 / 12 | VCC / GND | +5 V / GND (+ 100 nF) |

Le BIOS programme le compteur 0 en mode 3 (onde carrée) avec le diviseur
**36617** : IRQ0 à 2 666 667 / 36617 = **72,83 Hz**, soit exactement 4 fois la
cadence du PC (18,2065 Hz, erreur 0,002 %). Un top du PC (compteur du BDA,
INT 1Ch) sur 4.

### Son (compteur 2 et port 61h), comme le PC — pas encore câblé

| Élément | Rôle |
|---|---|
| U16 (74LS74) | **verrou du port 61h** : bascule A = bit 0 (D0) → GATE2 ; bascule B = bit 1 (D1) → validation du haut-parleur (~Q = ~SPK_EN) ; ~PRE à +5 V, ~CLR = ~RESET (silence à la mise sous tension) |
| U9 A, B (74LS02) | horloge du verrou CLK_61 = OR(WR#, O6) : front montant à la **fin** de l'écriture (données stables, maintien du 8088 ≥ 88 ns) |
| U14 C (74LS14) | ~RESET = RESET inversé (le RESET du 82C84 est actif haut) |
| U14 D, U9 C | SPK = NOR(~OUT2, ~SPK_EN) = **OUT2 ET bit 1** |
| R8 220 Ω, BZ1 | **buzzer piézo passif** (sans oscillateur intégré) entre SPK (par R8) et la masse |

Fréquence = 2 666 667 / N (compteur 2 en mode 3) : de **40,7 Hz** (N = 65536)
jusqu'au-delà de l'audible ; la 440 Hz = N 6061 (439,97 Hz). Le port 61h est en
**écriture seule** (une lecture rend le bus flottant) : les programmes du PC font
`IN AL,61h / OR AL,3 / OUT 61h,AL` puis `AND AL,0FCh` ; seuls les bits 0 et 1
comptent, ça marche. **Hauteur des sons des programmes du PC** : ils calculent
N pour une horloge de 1,193 MHz ; ici elle vaut 2,667 MHz, leurs notes sortent
**2,235 fois plus aiguës** (~1 octave + 4 demi-tons ; `BEEP`, `SOUND`, `PLAY` de
BASICA). Les sons du BIOS sont justes.

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

## Lecteur de carte SD (J9)

Dans l'esprit des émulateurs de disquette d'époque (Gotek, HxC) : un module
lecteur microSD sur **U12**, le protocole SPI produit **bit par bit par le
8088**, et le BIOS lit la carte (FAT16 ou FAT32) pour démarrer sur une image de
disquette `.IMG`. Aucun microcontrôleur.

| Signal du module (J9) | U12 (8255, mode 0, mot 82h inchangé) | Sens |
|---|---|---|
| 1 CS | **PC4** (broche 13) ; R10 10 kΩ au +5 V (carte désélectionnée pendant le RESET, 8255 en entrée) | sortie |
| 2 SCK | **PC5** (broche 12) | sortie |
| 3 MOSI | **PC6** (broche 11) | sortie |
| 4 MISO | **PB3** (broche 21) ; R9 10 kΩ au +5 V (niveau défini sans carte) | entrée |
| 5 VCC | **+5 V** (le régulateur AMS1117 du module fait le 3,3 V de la carte) | |
| 6 GND | masse | |

Le 74LVC125 du module abaisse CS, SCK et MOSI à 3,3 V ; MISO sort en 3,3 V,
assez pour une entrée du 8255 (seuil 2,2 V). Le clavier (PB0, PB1) et l'UART
logiciel (PA7, PB2) ne changent pas. Débit attendu du SPI logiciel : ~60 µs par
octet, ~15 Ko/s (une disquette d'XT : 25 à 40 Ko/s).

L'ATmega328P proposé comme UART a été **abandonné** au profit de l'esprit
vintage (le projet du micrologiciel de clignotement reste dans
`arduino/atmega_uart/`) ; une vraie puce UART d'époque (8250, 16450, 6850)
pourra venir plus tard.

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
| 18 | IR0 = IRQ0 | OUT0 de la 8253 (U15 broche 10) : minuterie |
| 19 | IR1 = IRQ1 | U14 (74LS14) broche 2 = KBD_CLK inversée |
| 22 | IR4 = IRQ4 | U14 broche 4 = UART_RX inversée |
| 20, 21, 23–25 | IR2, IR3, IR5–IR7 | libres (masquées par le BIOS) |
| 28 / 14 | VCC / GND | +5 V / GND (+ 100 nF) |

Le 8259 réagit au **front montant** (mode front, comme le PC) ; or une trame
PS/2 commence par un front **descendant** de l'horloge et un octet série par un
front descendant de RX (bit de départ). **U14 (74LS14, trigger de Schmitt)
inverse donc KBD_CLK** (broche 1 → 2, vers IR1) **et UART_RX** (broche 3 → 4,
vers IR4) ; porte 3 : RESET → ~RESET (broche 5 → 6, verrou du port 61h) ;
porte 4 : OUT2 → ~OUT2 (broche 9 → 8, son) ; portes 5 et 6 inutilisées, entrées
à la masse (VCC broche 14, GND broche 7). Les bits eux-mêmes restent lus par U12 (PB0, PB1,
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

## BIOS 2.1

Sources : [bios/bios.asm](bios/bios.asm) (démarrage, menu, test de la RAM,
DEL, clavier, UART) et [bios/services.inc](bios/services.inc) (services de
type IBM PC). Déroulement :

1. **Écran d'ouverture** (~2 s) : `SOLUTION-02 BIOS 2.1`,
   `CPU 8088/V20 5.33MHz`, `RAM 512 Ko  LCD 20x4`, `VE2CUY - 2026`.
2. **Vérification rapide** des 4 Ko de données du BIOS (7F000h–7FFFFh) ; en
   cas d'échec, le test complet de la RAM part d'office. Bannière sur l'UART.
   Programmation de la **8253** (compteur 0, mode 3, diviseur 36617) et
   détection : deux lectures verrouillées du compteur, à ~20 µs d'intervalle,
   doivent différer et ne pas dépasser 36617 (sans 8253, le bus flottant rend
   toujours la même valeur).
3. **Menu**, au clavier PS/2 (touches 1 à 5). En entrant au menu, le BIOS
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

   Avec le 8259 **et** la 8253, IR0 est aussi ouverte : **IRQ0 (INT 08h) à
   72,83 Hz**. IRQ0 envoie l'EOI et rétablit les interruptions tout de suite
   (une demande du clavier retombe en ~40 µs : elle ne doit pas attendre), puis :
   - **temps** : un appel sur 4 = un top du PC (18,2065 Hz) : compteur du BDA
     (0040:006C), passage de minuit (1800B0h tops, 0040:0070), INT 1Ch. L'heure
     du DOS avance (`TIME`, dates des fichiers) ;
   - **animations des DEL en arrière-plan**, partout (menu, Info, DOS…) : les
     animations sont une **tâche** sur sa propre pile ; en attendant son pas
     suivant, elle rend la main à IRQ0 (`tache_cede`), qui la reprend le
     nombre de tops voulu plus tard (3 = ~41 ms, 5 = ~69 ms, 12 = ~165 ms).
     Un pas dure quelques dizaines de µs, interruptions permises.
   - **son** : au premier affichage du menu après le démarrage, une petite
     mélodie (do5, mi5, sol5, do6) ; sous DOS, le caractère **BEL** (07h, écrit
     par INT 10h) donne un bip de 880 Hz, ~0,25 s. Durées comptées en IRQ0 :
     sans 8259 ou sans 8253, pas de son.

```
1) Load DOS 6) BASIC
2) Test memory
3) LED Show
4) Info  5) UART:ON
```

La **console sur l'UART** est à **ON au démarrage** (et après Ctrl + Alt +
Suppr ou le test de la RAM) ; la touche **5** la bascule (`UART:ON` ↔
`UART:OFF`). Elle vaut **dans tous les modes** :

- au premier menu après le démarrage (et à chaque passage à ON), un **écran d'accueil en couleur** (séquences ANSI : écran
  effacé, titre en blanc, adresses du dépôt en rouge, logo « 88 // PC » en vert,
  slogans), inspiré de l'accueil de z/OS ([medias/Z88.png](../medias/Z88.png)),
  sans la section LOGON ; il est généré par `tests/gen_accueil.py`
  (`accueil.inc` ; `--apercu` l'affiche dans la console) ;
- les écrans du BIOS (menu, Info, LED Show) sont recopiés sur le terminal : le
  BIOS garde une copie des 4 lignes du LCD (tenue à jour par `lcd_cmd` et
  `lcd_car`) et l'envoie, sans les espaces de fin, quand l'écran est dessiné.
  Avant l'envoi, il attend que le clavier PS/2 soit calme (~130 ms sans
  trame, au plus ~1 s) : l'envoi masque les interruptions et ferait perdre le
  relâchement de la touche qui vient d'être frappée ;
- les octets reçus deviennent des **touches**, comme celles du clavier PS/2 :
  le menu se pilote au terminal (`1` à `5`), Échap quitte le LED Show… ;
- sous DOS : voir « Console UART » plus bas.

### 1) Load DOS

**Carte SD** (J9) : le BIOS initialise la carte (`Carte SD...`), lit la FAT
(FAT16, ou FAT32 : 1er amas de la racine) et liste les images **`.IMG` de la
racine** (16 au plus). S'il en trouve, il propose le choix :

```
Demarrer : Entree
>ROM PC-DOS 2.1
 PCDOS21.IMG  180K
 DOS33.IMG    720K
```

**↑ / ↓** déplacent le choix (la liste défile), **Entrée** démarre, **Échap**
revient au menu ; recopié sur le terminal quand la console UART est à ON
(flèches ANSI). Sans carte, ou sans image, A: est la disquette en ROM, comme
avant. L'image choisie devient **A:** pour INT 13h, en **lecture et écriture**
(les écritures du DOS vont directement dans le fichier de la carte, comme un
Gotek) :

| Taille du fichier | Format | Secteurs/piste, faces, cylindres | DOS |
|---|---|---|---|
| 160 / 180 Ko | 5¼ simple face | 8 ou 9, 1, 40 | 1.0+ / 2.0+ |
| 320 / 360 Ko | 5¼ double face | 8 ou 9, 2, 40 | 1.1+ / 2.0+ |
| 720 Ko | 3½ DD | 9, 2, 80 | 3.2+ |
| 1,2 Mo | 5¼ HD | 15, 2, 80 | 3.0+ |
| 1,44 Mo | 3½ HD | 18, 2, 80 | 3.3+ |

Refus (message 1 s, retour à la liste) : `Taille inconnue !`, `Image
fragmentee !` (le fichier doit être **d'un seul tenant** : le copier sur une
carte fraîchement formatée), `Erreur de lecture !`. INT 13h AH=08h rend la
géométrie et le type de lecteur (BL) de l'image ; AH=05h (formatage), 16h, 17h,
18h répondent « fait ». Débit du SPI logiciel : ~40 ms par secteur (réception
déroulée, ~12 Ko/s).

**Progression et voyant** : pendant le démarrage depuis une image de la carte
(jusqu'à la première attente d'une touche par le DOS), la ligne 4 du LCD montre
`Lecture A: nnn Ko` et le **bargraphe se remplit** (une DEL de plus tous les
8 Ko, il recommence après 24) ; les animations reprennent ensuite.

**Voyants d'accès** (BIOS 1.7, à part du LED Show) : deux DEL sur **U12** —
**D1 sur PA0** pendant chaque accès à une **disquette** de la carte (A: ou B:),
**D2 sur PA1** pendant chaque accès au **disque dur C:** (390 Ω à la masse,
actives à 1, comme les bargraphes). PA est écrit en entier avec PA7 (TX de
l'UART) au repos à 1 ; `uart_tx`, le seul autre à écrire PA, ne tourne jamais
pendant un accès. (BIOS 1.6 : PC7/PC6 du bargraphe et LED Show suspendu,
abandonné : la combinaison avec les animations portait à confusion.)

**Disque dur C:** (BIOS 1.6 ; plusieurs images au 1.7) : chaque fichier `.IMG`
de la racine **plus grand que 1,44 Mo** est une image de disque dur ; elles
s'ajoutent en bas de la liste (16 lignes au plus en tout, disquettes en tête).
L'image qui sera **C:** (INT 13h DL = 80h) porte un `*` : la première trouvée
au départ, **Espace** sur une autre ligne `C:` la choisit.

```
Demarrer : Entree
 ROM PC-DOS 2.1
 DOS33.IMG    360K
*C:DOS622_C.IMG 31M
>C:FREEDOS_C.IMG 31M
```

C: est monté **après le choix**, quel qu'il soit (ligne 1 : `Verification
C:...` ; la vérification de la FAT, image d'un seul tenant, prend quelques
secondes avec le SPI logiciel ; refus : `Image C: refusee !` et retour à la
liste). **Entrée** sur une ligne `C:` choisit cette image et démarre depuis le
disque dur (MBR → secteur d'amorce de
la partition active, DL = 80h ; A: reste la disquette en ROM). Géométrie :
têtes et secteurs par piste lus à la fin de la 1re partition du MBR (sinon 16 ×
63), cylindres = taille / (têtes × secteurs), 1024 au plus (~504 Mo). Le
fichier doit être d'un seul tenant. BDA 0040:0075 = 1 disque fixe, INT 41h →
table des paramètres (DSEG:0C80h). INT 13h pour C: : AH = 02h, 03h, 04h, 08h,
15h (type 3 et nombre de secteurs), 01h ; 00h, 0Ch, 0Dh, 10h, 11h, 14h
répondent « fait » ; le reste, erreur 01h. Le DOS 3.x et plus voit C: dès son
démarrage, même depuis une disquette.

Images prêtes (dans `PC-DOS/`, **hors de git**, à copier à la racine de la
carte fraîchement formatée), produites depuis les disquettes d'installation :

| Image | Contenu | Générateur |
|---|---|---|
| `DOS622_C.IMG` (32 Mo, FAT16) | MS-DOS 6.22 français installé : `IO.SYS`, `MSDOS.SYS`, `COMMAND.COM`, `CONFIG.SYS`, `AUTOEXEC.BAT` à la racine, tout `C:\DOS` (fichiers `*.??_` décompressés : format KWAJ de MS-DOS 6, noms d'origine par `PACKING.LST`) | `python tests/gen_dos622.py` (archive `.7z` des 4 disquettes) |
| `FREEDOS_C.IMG` (32 Mo, FAT16) | FreeDOS 1.4 version 8086 : `KERNEL.SYS` de l'édition disquette (x86), `COMMAND.COM`, `FDCONFIG.SYS`, `FDAUTO.BAT` ; les 50 paquets BASE de l'édition LiteUSB dans `C:\FREEDOS` (sans sources ni paquets 286/386) | `python tests/gen_freedos.py` (`FD14-FloppyEdition.zip`, `FD14-LiteUSB.zip`) |

Console UART (BIOS 2.0) : INT 10h AH=02h (position du curseur) est recopié au
terminal en déplacement relatif (`ESC [ n A/B/C/D`) et AH=09h/0Ah (caractère à
la position) en caractères suivis d'un retour du curseur ; la position du
curseur est aussi tenue dans le BDA (0040:0050), que FreeCOM lit directement
(sans elle, le retour arrière effaçait au mauvais endroit : un espace au
terminal).

`FDCONFIG.SYS` porte **`STACKS=0,0`** : sans lui, le noyau de FreeDOS détourne
IRQ0, IRQ1 et IRQ4 (INT 08h, 09h, 0Ch) par un relais qui change de pile ; ce
délai fait manquer le bit de départ de l'UART logiciel (octets décalés d'un
bit) et les premiers fronts du clavier PS/2, lus bit par bit dès l'interruption.

Les deux ont un MBR 8086 (`tests/mbr8086.asm` : partition active, CHS, 3
essais) et une partition FAT16 active de 16 têtes × 63 secteurs (bibliothèque
`tests/fatlib.py`). Sans KEYB ni HIMEM (8088).

**Changer la disquette de A:** (BIOS 1.7) pendant que le DOS tourne :
**Ctrl+Alt+Inser** au clavier PS/2 ; sur le terminal, la même combinaison quand
il l'envoie (`ESC [ 2 ; 7 ~`, terminaux de type xterm) ou **Ctrl+]** (1Dh). La
touche ne fait que lever une demande ; la liste (`Disquette A: Entree`, la ROM
et les images de disquette, sans les lignes C:) s'ouvre quand le DOS attend
vraiment une touche, jamais au milieu d'un accès disque : INT 16h AH=00h, ou
(BIOS 1.9) une dizaine d'INT 16h AH=01h de suite sans touche et sans INT 13h
entre eux (le DOS au repos interroge AH=01h en boucle et n'appelle AH=00h qu'une
fois la touche là). La
carte est relue (on peut en changer ; C: et B: gardent la position de leur
image). Entrée monte l'image (ou la ROM) en A:, Échap ne change rien ; le LCD
reprend ensuite l'écran du DOS. INT 13h AH=15h annonce maintenant une **ligne
de changement** pour A: et AH=16h rend « disquette changée » (06h) une fois
après chaque changement : le DOS 3.x et plus relit la FAT. (Le DOS 2.1 n'en
tient pas compte et ne lit que les disquettes 5¼ de 160 à 360 Ko.) Le tampon de
la carte (00500h, au DOS) est sauvé puis remis ; pile propre en DSEG.

**B: = image DOS 2.1 de la carte** : si l'on choisit `ROM PC-DOS 2.1` et que la
carte porte une image PC-DOS 2.x (secteur d'amorce OEM `IBM  2.`, la première
trouvée), elle devient **B:** (lecture-écriture) à la place du disque virtuel en
RAM, et le DOS reçoit **508 Ko** au lieu de 380. On a ainsi, à côté de la
disquette réduite de la ROM, la disquette complète (BASICA, utilitaires, et
DEBUG si on l'y ajoute).

**Disquette de la ROM** (`PC-DOS/pcdos2_1_rom.img`, fabriquée par
`tests/gen_dos_rom.py` à partir de `pcdos2_1.img`) : IBMBIO.COM, IBMDOS.COM,
COMMAND.COM, EDLIN.COM, CHKDSK.COM, FORMAT.COM de PC-DOS 2.1, **MASM.EXE**
(Microsoft MACRO Assembler 1.00, 1981) et **LINK.EXE** (Object Linker 1.08)
de `PC-DOS/MASM/` (MASM1.EXE, LINK1.EXE : les versions pour DOS 1.1/2.x) ;
11 Ko libres. Pas de DEBUG : aucun DEBUG pour DOS 2.x dans le dépôt, et il ne
tiendrait pas (il manquerait 2 amas) ; le mettre sur l'image de la carte (B:).

Le BIOS remplit la table des vecteurs (256 vecteurs vers un `IRET`, puis les
siens), la zone de données (BDA : 2 lecteurs de disquette, vidéo 80 colonnes,
380 Ko), prépare le lecteur B:, vide l'écran et amorce A: (INT 19h : secteur 0
en 0000:7C00). Les
services du BIOS rétablissent les interruptions (STI) : IRQ1 et IRQ4 sont
servies même pendant l'affichage. PC-DOS 2.1 demande la date et l'heure (il n'y a
pas d'horloge sauvegardée : le compteur repart de 0:00:00 ; l'heure tapée est
ensuite tenue par IRQ0), puis affiche `A>`.

**Lecteur B:** : disque virtuel de **128 Ko en RAM** (5F000h–7EFFFh), en
lecture-écriture (`COPY`, `DEL`, `MD`…). Le DOS 2.1 ne connaît que des formats
de disquette fixes : B: est donc un **160 Ko** (descripteur FEh : 40 pistes,
1 face, 8 secteurs) dont seuls les 256 premiers secteurs existent ; les amas
au-delà de 128 Ko (251 à 314) sont **marqués défectueux** dans la FAT, le DOS
ne les utilise jamais (`CHKDSK B:` : 32768 octets dans des secteurs
défectueux ; 127 488 octets libres). À chaque Load DOS, le BIOS garde le
contenu s'il porte sa signature (OEM `SOL02 B:`, 55AAh, FEh dans la FAT),
sinon il le formate (amorce, 2 FAT, répertoire vide). Le contenu survit à
Ctrl + Alt + Suppr, pas à la mise hors tension ni au test de la RAM.

| INT | Service |
|---|---|
| 10h | écran : AH = 00h, 02h, 03h, 06h, 07h, 08h, 09h, 0Ah, **0Eh (télétype, recopié sur l'UART si console ON)**, 0Fh |
| 08h / 1Ch | IRQ0 (8253) : temps et animations ; INT 1Ch à chaque top (18,2 Hz) |
| 11h / 12h | équipement (0061h : 2 lecteurs) / mémoire (380 Ko) |
| 13h | A: **en ROM**, lecture seule : AH = 00h, 01h, 02h, 04h, 08h, 15h, 16h ; écriture/formatage → erreur 03h (protégée). B: **en RAM** : lecture, **écriture** (AH = 03h), formatage sans effet ; secteur au-delà de 128 Ko → erreur 04h. Autre lecteur → erreur |
| 09h / 0Ch / 0Fh | IRQ1 clavier / IRQ4 UART / IRQ7 parasite (8259) |
| 14h | AH = 01h : envoi sur l'UART logiciel ; AH = 02h : octet reçu par IRQ4 (attente ~0,5 s, sinon AH = 80h) ; AH = 03h : état (AH bit 0 = octet en attente) — réception seulement avec le 8259 |
| 16h | clavier : AH = 00h, 01h, 02h, 05h (et 10h–12h) ; AH = code XT, AL = ASCII, comme un PC ; file remplie par IRQ1 (et par IRQ4 si console ON) |
| 15h, 17h | sans objet (pas de services AT, pas d'imprimante) |
| 18h | retour au menu |
| 19h | amorçage de A: |
| 1Ah | compteur de tops du BDA, avancé par IRQ0 (AH = 00h, 01h) ; sans 8253, l'heure ne change pas |

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
**Caractères accentués** (page de codes 437 du DOS, 80h–FFh) : sur le
**terminal**, convertis en **UTF-8** (comme Solution-01 ; le terminal doit être
en UTF-8, pas en CP437/CP850) ; sur le **LCD**, dont la ROM (A00) n'a pas ces
lettres, les 8 caractères programmables (CGRAM, chargés par `ecran_init`)
dessinent **é è ê à ç ù ô** et la **barre oblique inverse** (BIOS 1.8 : la ROM
A00 a le symbole yen en 5Ch, d'où un caractère japonais à la place de `\` ; â
devient a pour lui laisser sa place) ; les autres lettres perdent leur accent
(ë → e, ü → u…), quelques symboles viennent de la ROM du LCD (α β µ π Σ ° ÷ √ █)
et les cadres deviennent `+ - | =`. Le tilde (7Eh) reste une flèche → (ROM A00).

**Maj inverse Verr Num**, comme sur un PC : Maj + une touche de déplacement du
pavé numérique (8 2 4 6, 7 1 9 3, 0 .) donne la fonction de curseur (flèche,
Début, Fin, Page…, Inser, Suppr) et non le chiffre. La navigation marche donc
aussi avec les flèches du pavé, et quand le préfixe E0 d'une flèche est perdu
(le BIOS 1.4 et avant écrivait alors « 8 », « 2 »… à l'invite).
La Maj est aussi reconnue par le « relâchement factice » (E0 F0 12h ou
E0 F0 59h) que le clavier envoie juste avant la flèche : la navigation marche
même si l'appui de Maj a été perdu (montage sans diode).

**Console UART** sous DOS (menu 5 à `UART:ON`, terminal 9600 8N1 sans écho local) :

- **sortie** : chaque caractère écrit par INT 10h en télétype (AH = 0Eh, ce
  qu'utilise le DOS) part aussi sur TX, tel quel (CR, LF, BS, BEL ; les
  séquences `ESC [ …` de `CLS` sont donc comprises par le terminal) ;
- **entrée** (avec le 8259) : les octets reçus par IRQ4 deviennent des
  touches d'INT 16h, mêlées à celles du clavier PS/2. CR → Entrée, BS ou DEL
  → retour arrière, TAB, ESC ; LF et NUL ignorés. Séquences ANSI du terminal
  (envoyées d'un trait, lues dans IRQ4 par scrutation) : `ESC [` ou `ESC O`
  suivi de A/B/C/D (flèches), H/F (Début/Fin), P/Q/R/S (F1–F4), ou de 1 à 6
  puis `~` (Début, Inser, Suppr, Fin, Page préc./suiv.). ESC seul (rien dans
  les ~2,7 ms) : Échap.

À `UART:OFF`, rien du DOS ne passe par l'UART (INT 14h reste disponible). Limites
de la console : l'UART est logiciel, chaque caractère envoyé prend ~1 ms
**interruptions masquées** : l'affichage est plus lent (`DIR` : ~1,5 s de plus pour ~1 400 caractères)
et une trame du clavier PS/2 ou un octet reçu qui commence pendant un envoi
peut être perdu (un relâchement de touche perdu peut doubler la touche) ; un
texte collé dans le terminal pendant que le DOS l'écrit en écho perd des
caractères. Sans 8259 : sortie seulement. Ctrl + Alt + Suppr remet la console à
OFF. Une puce UART (8250/16550) est prévue pour la suite.

Limites : pas d'horloge sauvegardée (l'heure repart de 0 à chaque démarrage),
sons des programmes du PC trop aigus (voir « Son »), pas de mémoire vidéo (un programme
qui écrit directement en B800h n'affiche rien), A: en lecture seule (`COPY`,
`DEL`… vers A: → « Write protect error » ; utiliser B:), disposition de
clavier US.

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

9 animations en boucle sur les 24 sorties du 8255 U7 (bargraphes BAR1–BAR3),
vues comme une seule rangée disposée ainsi sur le montage, de gauche à droite :
**PC7 … PC0, PA7 … PA0, PB7 … PB0**. Un cycle complet dure ~35 s.

Avec la 8253, les animations tournent **en permanence, en arrière-plan**
(IRQ0), depuis le démarrage : au menu, sous DOS, partout. Le menu 3 n'est que
leur **écran** : nom de l'animation en cours et nombre de cycles complets
depuis le démarrage, et le terminal ci-dessous. **Échap** ramène au menu (les
DEL continuent). Sans 8253 : les animations tournent seulement dans le menu 3,
au premier plan, comme avant.

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
traités par l'écran du LED Show. Console UART à ON : les octets reçus sont des
touches (ligne 3 et écho), pas la ligne 4. Limites : l'envoi d'un caractère
sur l'UART masque les interruptions (~1 ms) : une trame du clavier ou un octet
qui commence à ce moment peut être perdu (ou donner une IRQ7 parasite), de même
qu'un octet reçu pendant la lecture d'une trame du clavier (et inversement).
Sans 8259 : scrutation, une touche frappée pendant l'envoi d'un caractère ou le
changement d'animation peut être perdue.

### 6) BASIC

Le **BASIC « GW-BASIC-like » de Solution-01** (`Solution-01/lib/basic*.asm`,
inchangé), assemblé à part par `basic_s02.asm` (`build/basic_s02.bin`,
F000:8000) avec une couche d'adaptation : affichage par **INT 10h** (écran
24 × 80, fenêtre du LCD avec Maj + flèches, et le terminal si la console est à
ON), clavier par **INT 16h** (clavier PS/2 et terminal), heure de **TIME$** et
**TIMER** tirée du compteur de tops du BDA (IRQ0), date en RAM. Son segment est
10000h (libre hors DOS). Bannière `VE2CUY 86 BASIC Version 1.0 (inspired by
GW-BASIC)`, puis `Ok` ; **SYSTEM** ramène au menu.

**Fichiers** (BIOS 2.0, `fs_s02.inc`) : à la place du pont STM32 de Solution-01
(même API `fs_*`, voir `Solution-01/lib/bridge.asm`), un petit système **FAT12**
(racine seulement, un fichier ouvert à la fois) sur la **disquette A:** par
INT 13h : `SAVE`, `LOAD`, `MERGE`, `RUN "f"`, `FILES` (avec l'espace libre),
`KILL`, `OPEN`/`PRINT#`/`WRITE#`/`INPUT#`/`LINE INPUT#`/`CLOSE`, `FORMAT "YES"`
(vide la FAT et la racine, garde le BPB), `DSKREAD`/`DSKWRITE` (secteur LBA).
Données en 20000h (FAT et racine entières, tampon d'un secteur) ; la disquette
est relue à la première opération et après un changement (INT 13h AH=16h). A:
est l'image de la carte choisie (Load DOS, **Ctrl+Alt+Inser** ou Ctrl+] au
terminal, ou `BOOT "NOM.IMG"`) ; sinon la disquette en ROM, en lecture seule
(écrire donne *Disk I/O error*). `USB ON/OFF` : *Device unavailable*.

**Charger une disquette** : Ctrl+Alt+Inser (liste des images de la carte) ;
`BOOT "NOM.IMG"` monte l'image (INT 13h **AH=F0h**, propre au projet comme à
Solution-01 ; « .IMG » ajouté sans point ; AH=F1h : la ROM) puis démarre dessus
(INT 19h prépare d'abord le DOS comme Load DOS : BDA, vecteurs, B:).

**Flèche haut** (rappel de la dernière commande au prompt) : les touches
étendues d'INT 16h (flèches, Début, Fin) deviennent les séquences ANSI que
l'éditeur de ligne du BASIC attend (`ESC [ A`…), au clavier PS/2 comme au
terminal.

### 4) Info (SysInfo)

Version du BIOS, processeur (**8088** ou **NEC V20**, reconnu par
l'instruction AAD : le V20 ignore son opérande), mémoire et ROM, et en ligne 4 :
`8259+8253 OK I7 nnnn` (nombre d'IRQ7 parasites, en hexadécimal, depuis le
démarrage), `8259 OK  8253 absent` ou `8259 absent (scrut.)` (le BIOS 1.0
écrivait « 8254 »). Une touche ramène au menu.

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
inversée), la **8253** (compteur 0, lecture verrouillée, OUT0 en onde carrée
vers IR0 ; 8 périodes de PCLK par instruction ; diviseurs du compteur 2 notés),
une **carte SD** sur le SPI de U12 (`CarteSD` : CMD0, 8, 9, 16, 17, 24, 55, 58,
ACMD41 ; contenu creux fabriqué par `tests/gen_sd.py` : SDHC de 64 Mo en FAT32,
MBR et partition en 2048, images d'un seul tenant ou fragmentées),
le port 61h, les interruptions matérielles
servies entre deux instructions quand IF = 1 (pas juste après STI), et
l'aiguillage des interruptions logicielles du mode réel. 25 scénarios : démarrage et
menu (pile, bannière UART) ; Test memory avec RAM saine puis retour au menu ;
cellule 7B3FFh défectueuse, RAM absente (test complet d'office), ligne A15
coupée, puce de 128 Ko ; LED Show (24 DEL vues allumées et éteintes) en
arrière-plan (IRQ0) et **sans 8253** (premier plan) ;
terminal (Maj+a, b, 1, retour arrière, flèche haut, « Hi » reçu, Échap) ;
Info avec 8259 et 8253, **sans 8259** (repli sur la scrutation) et **sans
8253** ; **console UART hors DOS** (menu et Info recopiés sur TX, menu piloté
au terminal) ; **son** (mélodie de démarrage : diviseurs 5096, 4045, 3401,
2548 et port 61h à 3 puis 0 pour chaque note, la dernière plus longue) ; **Load DOS** :
PC-DOS 2.1 (disquette réduite : MASM, LINK…) démarre depuis la ROM, date et heure (Entrée), `DIR`, Maj + ↑ ×3 et
Maj + →, saisie longue, Ctrl + Alt + Suppr, avec vérification qu'aucune trame
du clavier n'est perdue avant Ctrl + Alt + Suppr, qu'aucun vecteur non géré
n'est appelé et qu'aucun `OUT` du DOS n'atteint le LCD ou les 8255 ; **frappe
anticipée** : `rem abc` tapé pendant que `DIR` s'affiche apparaît à l'invite
suivante (IRQ1) ; **console UART** : menu 5 (`UART:ON`), Load DOS, date,
heure, `DIR` tapés au terminal, flèche gauche ANSI (`ESC [ D` d'un trait) et
Échap seul, avec la sortie du DOS vérifiée sur TX ; **temps** : `TIME` après
`DIR` donne une heure qui a avancé, et les DEL changent sous DOS ; **lecteur
B:** : `COPY EDLIN.COM B:` puis `DIR B:` (122 880 octets libres) ; **BASIC**
(menu 6, `PRINT 2+3` au terminal, `SYSTEM`) ; **Maj + flèche sans E0** puis
Maj + 8 du pavé : la fenêtre remonte, aucun chiffre ; **accents** (`PRINT
CHR$(130);CHR$(135);CHR$(129)` : UTF-8 sur le terminal, CGRAM sur le LCD) ; **ROM + carte** : B: = l'image
PC-DOS 2.1 de la carte (`DIR B:` montre BASICA.COM) et 508 Ko pour le DOS ; **carte
SD** : Load DOS, choix de `PCDOS21.IMG` (flèche bas au terminal, Entrée), le DOS
démarre depuis la carte, `dir > liste.txt` écrit dans l'image (relue sur la
carte), l'autre image intacte ; **image fragmentée** refusée. La ROM de
diagnostic a son scénario : `python tests/sim.py build/solution-02-diag-sd.bin
diagsd` (carte à 2 images, puis sans carte). Réception UART sous DOS par INT
14h AH=02h : pas encore de scénario.

Commandes (depuis `bios/`) :

```sh
make            # build/solution-02-bios.bin (image de 256 Ko)
make test       # simulateur tests/sim.py (25 scénarios, ~30 min ; un seul : python tests/sim.py build/solution-02-bios.bin dos)
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

## À Réaliser plus tard

### Carte SD (accès à des fichiers)

Une carte SD peut être reliée sans nouvelle puce logique : on la pilote en
**mode SPI, en bit-bang**, avec les broches libres du 2e 8255 (U12,
30h–33h). Il faut 3 sorties (SCK, MOSI, CS#) et 1 entrée (MISO), ce que
donne déjà le mot de contrôle **82h** (PA et PC en sortie, PB en entrée).
Aucun changement au décodage, rien de plus sur le bus ; O4–O7 du 74LS138
restent libres.

Broches libres de U12 :

| Port | Déjà pris | Libre |
|---|---|---|
| PA (sortie) | PA7 = UART TX | PA0–PA6 |
| PB (entrée) | PB0 horloge clavier, PB1 données, PB2 UART RX | PB3–PB7 |
| PC (sortie) | — (diode de PC0 non posée) | PC0–PC7 |

Câblage proposé :

| Signal SD | 8255 U12 | Broche | Remarque |
|---|---|---|---|
| SCK | PC1 | 15 | |
| MOSI (DI) | PC2 | 16 | |
| CS# | PC3 | 17 | tirage 10 kΩ au +5 V : au RESET, les sorties du 8255 flottent, la carte reste désélectionnée |
| MISO (DO) | PB3 | 21 | |

PC0 est évitée (le BIOS la commande encore par des mots BSR), et PA aussi,
pour ne pas toucher à PA7 (TX de l'UART).

**Niveaux 3,3 V / 5 V** : la carte SD fonctionne en 3,3 V.

- **Recommandé** : un module micro-SD « 5 V » du commerce (type Catalex),
  avec régulateur 3,3 V et 74LVC125 intégrés. Il se branche directement :
  VCC = +5 V, GND, SCK, MOSI, MISO, CS. Éviter les modules sans régulateur
  ni tampon.
- **À monter soi-même** : régulateur 3,3 V (AMS1117/LM1117) et 74HC4050
  alimenté en 3,3 V pour abaisser SCK, MOSI et CS#. MISO (3,3 V) peut aller
  directement au 8255 CMOS (VIH ≈ 2,2 V, à vérifier dans la fiche du
  µPD71055C).

**Logiciel (BIOS)** :

- L'horloge SPI est fournie par le 8088 : la carte attend aussi longtemps
  qu'il le faut. Les interruptions du clavier (IRQ1) et de l'UART (IRQ4)
  peuvent couper un transfert sans dommage ; **aucune section CLI**
  n'est nécessaire.
- Débit estimé : ~80–100 cycles par bit, soit **5 à 8 Ko/s** à 5,33 MHz
  (un secteur de 512 octets ≈ 0,1 s ; 180 Ko ≈ 30 s). La limite de 400 kHz
  de l'initialisation est respectée d'office.
- Pilote : CMD0, CMD8, ACMD41, CMD58, puis CMD17/CMD24 (lecture/écriture
  d'un bloc) ; gérer les cartes SDSC (adresse en octets) et SDHC (adresse
  en blocs).
- Intégration : présenter la carte par **INT 13h** comme 2e lecteur (B:)
  ou disque dur (80h), conversion CHS → numéro de bloc. PC-DOS 2.1 gère
  alors lui-même le FAT et les fichiers. Limites : FAT12 seulement sous
  DOS 2.x (partition ≤ ~16 Mo, ou image de disquette de 360 Ko au début de
  la carte) ; un disque dur demande aussi un MBR et une table de paramètres
  (INT 41h). Un lecteur FAT dans le BIOS (charger des fichiers depuis le
  menu) est possible mais plus long à écrire.

**Plus rapide, plus tard** : un registre à décalage SPI matériel
(74HC595 + 74HC165, ou un compteur) sélectionné par O4 ou O5 du 74LS138
donnerait ~50–100 Ko/s, au prix de 3 ou 4 puces et d'un décodage avec
RD#/WR# (comme pour le LCD). Commencer par la version sur U12 : 4 fils et
un module.

## État

- 2026-11-16 : BIOS 2.1 : BOOT "NOM.IMG" du BASIC corrigé (INT 19h hors Load DOS : DS = CS pour la table des vecteurs). À graver.
- 2026-11-16 : BIOS 2.0 : fichiers du BASIC sur la disquette A: (FAT12 : SAVE, LOAD, FILES, KILL, OPEN…), flèche haut au BASIC, BOOT "NOM.IMG" (INT 13h AH=F0h) ; curseur dans le BDA et recopié au terminal (retour arrière de FreeDOS). Gravé.
- 2026-11-16 : BIOS 1.9 : le changement de A: s'ouvre aussi quand le DOS attend en interrogeant INT 16h AH=01h (sinon jamais) ; image FreeDOS avec `STACKS=0,0` (clavier PS/2 et UART corrects sous FreeDOS). Gravé.
- 2026-11-16 : BIOS 1.8 : la barre oblique inverse s'affiche au LCD (CGRAM 4 ; la ROM A00 a le yen en 5Ch), â → a. Gravé.
- 2026-11-16 : BIOS 1.7 : changement de la disquette de A: sous DOS (Ctrl+Alt+Inser, ou Ctrl+] au terminal) ; plusieurs images de disque dur au choix (Espace), C: vérifié après le choix (liste plus rapide) ; voyants d'accès sur U12 (D1 = PA0 disquettes, D2 = PA1 disque dur ; schéma), LED Show plus suspendu. Gravé.
- 2026-11-16 : BIOS 1.6 : **disque dur C:** = image `.IMG` de plus de 1,44 Mo de la carte SD (INT 13h 80h, démarrage depuis C:, INT 41h) ; voyants : PC7 = disquettes, PC6 = disque dur, LED Show suspendu pendant les accès. Images `DOS622_C.IMG` (MS-DOS 6.22) et `FREEDOS_C.IMG` (FreeDOS 1.4) générées hors de git. Simulé (26 scénarios), gravé.
- 2026-11-16 : schéma : lecteur microSD (J9) sur U12 (PC4 = CS, PC5 = SCK, PC6 = MOSI, PB3 = MISO, R9/R10 10 kΩ), SPI par le 8088 ; ATmega328P retiré (esprit vintage), UART logiciel rétabli.
- 2026-11-16 : BIOS 1.5 : Maj + touche de déplacement du pavé = fonction de curseur (Maj inverse Verr Num) : corrige les chiffres reçus pendant la navigation Maj + flèches (préfixe E0 perdu) ; accents de DOS 6.22 : UTF-8 sur le terminal, CGRAM (é è ê à â ç ù ô) sur le LCD. Gravé.
- 2026-11-16 : BIOS 1.4 : console UART à ON au démarrage (accueil ANSI au premier menu) ; progression du démarrage depuis la carte (LCD et bargraphe) et voyant d'accès (PC7) ; **BASIC** de Solution-01 au menu (6) ; disquette de la ROM réduite (démarrage, EDLIN, CHKDSK, FORMAT, MASM 1.00, LINK 1.08) ; B: = image DOS 2.1 de la carte au démarrage depuis la ROM (508 Ko pour le DOS). Simulé (23 scénarios), gravé.
- 2026-11-16 : BIOS 1.3 : démarrage sur une **image `.IMG` de la carte SD** (choix au Load DOS, A: en lecture-écriture dans l'image, 160 Ko à 1,44 Mo), réception SPI déroulée. Simulé (21 scénarios + diagnostic SD), gravé.
- 2026-11-16 : ROM de diagnostic SD (`make diagsd`) validée sur le montage : la carte et ses 4 images sont reconnues.
- 2026-11-15 : BIOS 1.2 : écran d'accueil ANSI en couleur sur le terminal au passage de la console UART à ON (inspiré de l'accueil de z/OS, sans LOGON). Gravé.
- 2026-11-15 : ATmega328P sur **quartz 16 MHz** (validé sur plaquette, clignotement) ; schéma : Y2 + C5/C6, AVR_CMD → PC4, CTS → PB2, OUT1 de la 8253 libre.
- 2026-11-15 : schéma : UART par **ATmega328P** (U17, RC interne 8 MHz) derrière U12 en mode 2 (PA0–7, poignée de main PC4–PC7, INTRA → IRQ4), OUT1 de la 8253 → référence d'horloge, ISP J7, RTS/CTS J8 ; UART logiciel retiré du schéma. À valider ; BIOS inchangé.
- 2026-11-15 : schéma : sortie du son sur un **buzzer piézo passif** (BZ1, par R8 220 Ω) au lieu du haut-parleur et de son transistor. Le son n'est pas câblé pour l'instant.
- 2026-11-15 : BIOS 1.1 : son (compteur 2 de la 8253, port 61h) : mélodie au démarrage, bip sur BEL ; Info affiche « 8253 ». Simulé (19 scénarios), gravé.
- 2026-11-15 : schéma : son comme le PC : verrou du port 61h (U16 74LS74 sur O6, horloge OR(WR#, O6) par U9 A-B, ~CLR = RESET inversé par U14 C), GATE2 = bit 0, haut-parleur = OUT2 ET bit 1 (U14 D, U9 C) → Q1 PN2222A → LS1 8 Ω (R9 33 Ω, D1 1N4148). 8253 et `TIME` validés sur le montage.
- 2026-11-15 : BIOS 1.0 : 8254 (IRQ0 : heure du DOS qui avance, animations des DEL en arrière-plan partout), console UART dans tous les modes (écrans du BIOS recopiés, menu piloté au terminal), lecteur B: de 128 Ko en RAM (380 Ko pour le DOS). Simulé (18 scénarios), gravé.
- 2026-11-15 : minuterie = NEC D8253C-2 (8253-2, 5 MHz max ; CLK = 2,67 MHz) et non une 8254 : schéma (valeur, ~CS_8253, note) et documentation corrigés.
- 2026-11-15 : schéma : bargraphes en chaîne contiguë de 30 DEL (bits 0–23, 6 DEL de poids fort libres), RN1–RN3 = 9 × 390 Ω (SIP10) + R5–R7 390 Ω, réseaux tournés de 90°.
- 2026-11-15 : schéma : 8254 (U15) sur O4 (40h–43h), CLK = PCLK, OUT0 → IRQ0 ; bargraphes HDSP-4830 (BAR1–BAR3, RN1–RN3 390 Ω) sur PC, PA, PB de U7. BIOS 0.9 validé sur le montage.
- 2026-11-14 : BIOS 0.9 : console du DOS sur l'UART, activée au menu (5) `UART:ON|OFF` : sortie INT 10h télétype sur TX, entrée par IRQ4 dans la file d'INT 16h (séquences ANSI) ; bit d'arrêt lu au quart (octets collés). Simulé (13 scénarios), gravé.
- 2026-11-14 : 8259 (U13) et 74LS14 (U14) câblés : après correction du câblage, SysInfo affiche « 8259 OK   IRQ7 0000 » ; BIOS 0.8 validé (clavier et UART par interruptions).
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
