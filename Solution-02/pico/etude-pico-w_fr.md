# Étude : Raspberry Pi Pico W sur le bus du 8088 (Solution-02)

Statut : **étude, rien de câblé** (2026-11-23). But : remplacer à terme le SPI logiciel
(≈ 110 µs par octet) par un périphérique d'E/S rapide (≈ 1 µs par octet), qui donne au 8088 la
carte SD, le réseau Wi-Fi et des UART, sans microcontrôleur 5 V intermédiaire.

## 1. Le Pico W

| | |
|---|---|
| Puce | RP2040 (2 × Cortex-M0+, 133 MHz, 264 Ko de RAM) + CYW43439 (Wi-Fi 2,4 GHz, Bluetooth) |
| Broches utilisables | GP0–GP22, GP26–GP28 (26 broches) ; GP23–GP25, GP29 servent au Wi-Fi et à la DEL |
| Périphériques utiles | 2 UART, 2 SPI, **8 automates PIO** (4 par bloc, 125–133 MHz : 1 instruction = 7,5 ns), USB 1.1 appareil/hôte, DMA |
| Tension | **3,3 V : broches NON tolérantes au 5 V** (maximum absolu ≈ 3,3 V + 0,5 V) |

Le RP2040 est éprouvé dans ce rôle : la carte **PicoMEM** (bus ISA 8 bits des PC 8088) l'emploie,
avec un Pico W pour une carte NE2000 émulée en Wi-Fi, derrière des circuits d'adaptation de niveau.

## 2. Pourquoi pas de raccordement direct

Le bus du 8088 et les circuits CMOS de la carte (82C55, 82C84, 74HC573…) montent à **5 V** au
niveau haut. Relié directement, chaque niveau haut ferait passer du courant dans les diodes de
protection du RP2040 : erreurs, échauffement, puce détruite à la longue. Seul le **RP2350
révision A4** (Pico 2 W) a des broches officiellement tolérantes au 5 V.

Dans l'autre sens, aucun problème : un 3,3 V du Pico est vu comme un 1 par les entrées TTL du 8088,
des 8255/8259, des 74LS et des **74HCT** (seuil haut ≈ 2,0 V), mais **pas** par des 74HC alimentés
en 5 V (seuil ≈ 3,5 V).

## 3. Trois façons d'adapter les niveaux

| Voie | Circuits | Avantages | Inconvénients |
|---|---|---|---|
| **A. Pico 2 W (RP2350 A4)** | aucun | raccordement direct, plus rapide (150 MHz, 520 Ko) | à acheter ; vérifier « A4 » sur la puce ; garder l'alimentation 3,3 V présente dès qu'un 5 V touche une broche |
| **B. Pico W + 74LVC245** (recommandée avec le Pico W) | 1 × 74LVC245 (données), 1 × 74LVC245 ou 74LVC541 (adresses, commandes), alimentés en 3,3 V | entrées acceptant le 5 V, sorties suffisantes pour le TTL ; ~5 ns de délai ; ~1 $ pièce | à commander |
| **C. Pico W + pièces courantes** | 2 × **74HC4050 / CD4050** alimentés en 3,3 V (5 V → 3,3 V) + 1 × **74HCT541** ou 74HCT245 en 5 V (Pico → bus, sorties trois-états) | composants très répandus | plus de circuits et de fils ; sens des données géré à part ; 4050 plus lent (~15–30 ns, sans gêne ici) |

Le **74HC4050** (ou CD4050B) est un tampon dont les entrées acceptent plus que son alimentation :
alimenté en 3,3 V, il abaisse proprement le 5 V. Le **74HCT541** alimenté en 5 V lit le 3,3 V du
Pico comme un 1 et attaque le bus du 8088 ; sa validation (OE) s'ouvre seulement quand le 8088 lit
le Pico.

## 4. Décodage et registres

- **O5 du 74LS138 (U8) : ports 50h–5Fh**, libre. (O7, 70h–7Fh, reste libre pour plus tard.)
- Le Pico reçoit : **SEL# = O5**, **RD#**, **WR#**, **A0–A2** (8 registres), **D0–D7**, **RESET**.
- Registres proposés (à affiner) :

| Port | Lecture | Écriture |
|---|---|---|
| 50h | donnée suivante (FIFO de lecture : secteur SD, paquet reçu, octet UART) | donnée (FIFO d'écriture) |
| 51h | état : FIFO prête, nombre d'octets, interruption en attente | commande (lire secteur, écrire secteur, envoyer paquet, choisir canal…) |
| 52h–53h | paramètres (n° de secteur, longueur) | paramètres |
| 54h–57h | réservés (UART, réseau, horloge, diagnostic) | |

- **Lecture d'un secteur SD** : `OUT` commande + numéro, puis attente de l'état, puis 512 × `IN AL,
  50h` (`REP INSB` n'existe pas sur 8088 : boucle `IN`/`STOSB`, ≈ 30 cycles ≈ 6 µs par octet ;
  déroulée : ≈ 3–4 µs). **≈ 2–3 ms par secteur au lieu de 56 ms.**
- Interruption : une sortie du Pico vers une entrée libre du 8259 (**J12, IR2/IR3/IR5**) pour
  « données réseau reçues » : fin de la scrutation à 18,2 Hz.

## 5. Le cycle d'E/S du 8088 face aux PIO

8088 à 5,33 MHz : un état T = 187,5 ns ; un `IN`/`OUT` sans attente dure T1–T4.

| Instant | Signal |
|---|---|
| T1 | adresse verrouillée (74HC573), IO/M# = 1 → **SEL# (O5) tombe ~T1 + 60 ns** |
| début T2 | **RD#** ou **WR#** tombe |
| fin T3 | le 8088 lit D0–D7 (lecture) ; données d'écriture stables de T2 à T4 |
| T4 | RD#/WR# remontent |

- **Lecture** : le Pico dispose de RD# bas → fin de T3 moins l'établissement, soit **≈ 290 ns**, et
  voit SEL# dès T1. Un automate PIO qui attend SEL# et RD#, puis pose sur D0–D7 l'octet déjà
  préparé dans sa FIFO (`out pins`), répond en ≈ 20–40 ns, plus ≈ 20–30 ns d'adaptation de niveau.
  Large marge, **sans état d'attente**, à condition que l'octet soit préparé d'avance (FIFO
  remplie par le DMA ou le cœur).
- **Écriture** : un automate attend WR#, puis échantillonne D0–D7 et A0–A2 (stables jusqu'à T4) et
  les pousse dans sa FIFO de réception. Aucune contrainte.
- **Registres dont la valeur dépend de l'adresse** (état, paramètres) : l'automate lit A0–A2 et
  saute vers la bonne source (`jmp` sur une table : ≈ 10 instructions, < 100 ns). Faisable sans
  attente.
- **READY (option de sûreté)** : aujourd'hui la sortie READY du 82C84 n'est pas reliée (RDY1/RDY2 à
  la masse). Pour insérer des états d'attente : READY du 82C84 → broche 22 du 8088, **RDY1** ← une
  sortie du Pico (1 = prêt), AEN1# à la masse. Le Pico ne retient alors le 8088 que s'il n'a pas
  l'octet. À prévoir au schéma, même si la première version s'en passe.

## 6. Répartition des broches du Pico W (26 disponibles)

| Fonction | Broches | Nombre |
|---|---|---|
| D0–D7 (bus) | GP0–GP7 (consécutives : obligatoire pour `in pins`/`out pins` des PIO) | 8 |
| A0–A2, SEL#, RD#, WR# | GP8–GP13 (consécutives) | 6 |
| Validation du tampon vers le bus (OE du 74HCT541, voie C) | GP14 | 1 |
| RESET (lu : réinitialisation des FIFO) | GP15 | 1 |
| Carte SD (SPI0 matériel : RX GP16, CS GP17, SCK GP18, TX GP19) | GP16–GP19 | 4 |
| UART1 matériel (terminal) | GP20 (TX), GP21 (RX) | 2 |
| Interruption vers le 8259 (J12) | GP22 | 1 |
| RDY1 du 82C84 (option) | GP26 | 1 |
| Second UART (au choix) | GP27/GP28, par PIO | 2 |
| **Total** | | **26** |

Les UART et SPI matériels du RP2040 n'existent que sur certaines broches : GP0/GP1 (UART0) étant
pris par le bus, le terminal va sur l'UART1 (GP20/GP21) et un second UART passerait par un
automate PIO (il en reste plusieurs de libres).

## 7. Rôle de chacun pendant la transition

1. **Étape 1** : le Pico sur O5 avec la **carte SD** (sa propre fente microSD en SPI matériel). Le
   BIOS lit les secteurs par le port 50h quand il trouve le Pico (détection par un registre
   d'identification), et garde le SPI de U12 sinon : une seule ROM, comme pour l'ATmega.
2. **Étape 2** : le **Wi-Fi** du Pico (lwIP, NAT ou passerelle) remplace le module Grove ; pilotes
   ELKS (`ttyS1` ou interface dédiée) et DOS (`S02PKT`) adaptés au port 50h, avec interruption.
3. **Étape 3** (option) : **terminal** sur un UART du Pico ; l'ATmega U17 devient superflu.
4. **Option NE2000** (pilotes du DOS et d'ELKS tels quels) : il faut 32 ports consécutifs (base +
   00h–1Fh). Avec le décodage actuel sur 8 bits, un bloc libre de 32 ports n'existe pas (60h–6Fh =
   verrou du haut-parleur, 80h–FFh non décodés) : il faudrait compléter le décodage. À étudier à
   part.

## 8. Essais prévus

- Simulateur : modèle du périphérique (registres 50h–57h, temps de réponse, interruption) pour
  écrire et éprouver le BIOS et les pilotes avant le câblage.
- Micrologiciel du Pico (C, Pico SDK) : programmes PIO vérifiés avec le simulateur de PIO du SDK,
  puis à l'analyseur logique sur le montage (RD#, SEL#, D0–D7).
- Mesures : cycles par octet, secteur SD, débit réseau (ping, transfert TCP).

## 9. À décider

- Voie A (Pico 2 W), B (74LVC245) ou C (74HC4050 + 74HCT541) selon les pièces disponibles.
- Câbler READY dès la première version (recommandé : quelques fils, et une sûreté).
- Fente microSD : sur le Pico (recommandé : la carte SD actuelle de U12 resterait pour la transition).
