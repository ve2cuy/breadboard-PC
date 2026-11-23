# Micrologiciel de l'ATmega328P (Solution-02, U17)

[English version](README.md)

L'ATmega328P (quartz 16 MHz) donne deux UART au 8088 de la carte Solution-02, qui lui parle
en SPI sur le bus de la carte SD (schéma du 2026-11-23, voir `Solution-02/README_fr.md`) :

- **canal 1 = terminal** (J5, RTS/CTS sur J8) : UART logiciel sur la minuterie 1, de 2400
  à 115200 bauds, **57600 à la mise sous tension** ;
- **canal 2 = module Grove - UART WiFi V2** (J13, ESP8285, micrologiciel AT) : USART
  matériel, 115200 bauds, sans contrôle de flux.

Il garde les octets dans sa RAM : le 8088 les lit quand il veut, sans perte même si ses
interruptions restent masquées.

| ATmega328P | Signal | Carte |
|---|---|---|
| PB0 ICP1 / PB1 OC1A | UART_RX / UART_TX | J5 broches 2 / 1 (terminal ; R4 tire RX au repos) |
| PB2 SS | AVR_SS | U12 PC0 (R21 au +5 V) |
| PB3 MOSI / PB5 SCK | SD_MOSI / SD_SCK | U12 PC6 / PC5, partagés avec la carte SD |
| PB4 MISO | AVR_MISO | U12 PB4 (R20 au +5 V) |
| PD0 RXD / PD1 TXD | WIFI_TX / WIFI_RX | J13 broches 1 / 2 (TX / RX du module) |
| PD2 | IRQ4 | IR4 du 8259 (front montant) |
| PD6 / PD7 | RTS / CTS | J8 broches 1 / 2, actifs à 0 (R22 tire CTS à 0) |

Le module Grove adapte lui-même son entrée RX (2N7002, tirage de 1 kΩ à son VCC de 5 V) ;
sa sortie TX (3,3 V) suffit à l'ATmega (VIH = 3,0 V à 5 V). Branchement direct, sans
diviseur.

## Protocole SPI (version 4)

- SPI mode 0, poids fort en premier, comme pour la carte SD. La carte SD est
  désélectionnée (U12 PC4 = 1) tant que SS (U12 PC0) = 0. Au moins 10 µs entre deux
  octets : l'ATmega prépare l'octet suivant dans son interruption SPI.
- **Transaction** : SS = 0, un octet de commande, des octets de données, SS = 1. L'octet
  que le 8088 reçoit pendant l'octet *n* est celui que l'ATmega a préparé à la fin de
  l'octet *n−1*.
- Pendant l'octet de commande, le 8088 reçoit toujours **A5h**. Sans ATmega, il lit FFh
  (tirage R20) : c'est ainsi que le BIOS le détecte.
- **Commande = canal + opération** : bit 4 à 0 = terminal, à 1 = Wi-Fi. Les commandes du
  canal 1 sont celles de la version 2 : un BIOS 2.7 ou 2.8 fonctionne tel quel.

| Commande | Octets envoyés par le 8088 après la commande | Octets reçus |
|---|---|---|
| `00h` IDENT | 5 de remplissage | `'S'`, `'2'`, version (4), vitesse du canal 1, vitesse du canal 2 |
| `01h` / `11h` ETAT | 5 de remplissage | nombre reçus (poids faible, fort), place libre en émission (faible, fort), drapeaux |
| `02h` / `12h` LIRE | 1 de remplissage, puis *n* | *n* = min(reçus, 255), puis les *n* octets |
| `03h` / `13h` ECRIRE | 1 de remplissage, puis les octets à émettre | *f* = min(place libre, 255), puis 00h |
| `04h` / `14h` VITESSE | code de vitesse | 00h |
| `05h` / `15h` VIDER | A5h (confirmation) | 00h |
| `06h` PONT (version 4) | A5h : pont ; autre valeur : fin | 00h |

- **LIRE** : un octet ne quitte le tampon qu'une fois entièrement transmis. Remonter SS
  plus tôt ne perd rien ; le reste viendra au LIRE suivant.
- **ECRIRE** : les octets au-delà de la place libre sont perdus et mettent le bit 2 des
  drapeaux.
- **Drapeaux d'ETAT** (remis à 0 par la lecture) : bit 0 = un octet reçu a été perdu
  (tampon de réception plein), bit 1 = erreur de trame ou débordement, bit 2 = un octet à
  émettre a été perdu (tampon d'émission plein), bit 6 = CTS actif (le terminal accepte
  des octets), bit 7 = RTS actif (l'ATmega accepte des octets). Canal 2 : bits 6 et 7
  toujours à 1 (pas de contrôle de flux).
- **VITESSE** : 0 = 9600, 1 = 19200, 2 = 38400, 3 = 57600, 4 = 115200, 5 = 4800,
  6 = 2400 bauds, 8N1. Appliquée quand tout ce qui attend est parti. Mise sous tension :
  canal 1 à 57600, canal 2 à 115200 (vitesse du micrologiciel AT). L'ATmega n'est pas remis
  à zéro avec le 8088 (bouton RESET, Ctrl+Alt+Suppr) : il garde ses vitesses, que le BIOS
  relit par IDENT.
- **PONT** : les octets reçus du terminal partent au module et ceux du module au terminal,
  sans passer par le 8088. Sert à graver le module avec esptool à travers la carte (BIOS 3.0,
  menu 9, Ctrl+B) : les adaptateurs USB-série à résistance en série ne savent pas tirer à 0
  l'entrée du module (tirage de 1 kΩ). Les deux canaux doivent être à la même vitesse.
- **VIDER** n'agit qu'avec la confirmation A5h : un octet parasite (trafic SPI de la
  carte SD avec SS = 0 par erreur) ne peut pas vider les tampons.

## IRQ et contrôle de flux

- **IRQ (PD2 → IR4)** = 1 quand un octet reçu **du terminal** attend et qu'aucune
  transaction n'est en cours. Elle tombe au début de chaque transaction et remonte à la fin
  s'il reste des octets : chaque transaction qui laisse des données redonne un front
  montant au 8259 (mode front). Le canal 2 se lit par scrutation (ETAT / LIRE `11h`/`12h`).
- **RTS** (canal 1) est retiré à 384 octets en attente et rendu à 128.
- **CTS** (canal 1) : l'ATmega cesse d'émettre tant que le CTS du terminal est à 1 (à un
  octet près). Sans rien sur J8, R22 garde CTS actif.
- Tampons (2 Ko de RAM en tout) : canal 1, 512 octets en réception et 64 en émission ;
  canal 2, 1024 en réception (le module n'a pas de contrôle de flux) et 128 en émission.

## UART logiciel du terminal

- **Réception** : la capture d'entrée (ICP1) date chaque front de la ligne au cycle près ;
  l'interruption range la date et le niveau dans une file de 16 fronts. La boucle
  principale décode les trames à partir de ces dates (chaque bit = niveau de la ligne au
  milieu du bit) : aucune contrainte de latence sur le décodage.
- **Émission** : la comparaison A (OC1A) pose chaque bit au cycle près ; l'interruption
  choisit le bit suivant. Durée d'un bit : 139 cycles à 115200 bauds (erreur 0,08 %).
- Les deux interruptions de la minuterie sont en assembleur (`src/uart_isr.S`) et gardent
  leur état dans des registres réservés (r2 à r10, `-ffixed-…`, sans LTO) ; les
  interruptions SPI et PCINT masquent SPI et PCINT puis rendent la main (`sei`) avant de
  sauver leurs registres. Ainsi la minuterie n'attend jamais plus de ~15 cycles.
- **Limite** : à 115200 bauds en duplex intégral continu (collage dans le terminal pendant
  que le 8088 renvoie l'écho), le processeur de l'ATmega est presque plein. Le banc d'essai
  passe avec un 8088 à sa vitesse réelle (~110 µs par octet SPI), pas avec un 8088 deux
  fois plus rapide. À 57600 bauds (vitesse par défaut), il passe même avec un 8088 3,6 fois
  plus rapide.

## Fichiers

| Fichier | Contenu |
|---|---|
| `src/protocole.h`, `src/protocole.c` | protocole et tampons des deux canaux, sans registre de l'AVR (testés sur le PC) |
| `src/main.c` | matériel : décodage et émission du terminal, USART du module, SPI esclave, IRQ, RTS/CTS |
| `src/uart_isr.S`, `src/uart_logiciel.h` | interruptions en assembleur (minuterie 1, entrées SPI et PCINT), registres réservés |
| `test/test_protocole.c` | 73 vérifications : le 8088 maître simulé octet par octet |
| `test/banc_simavr.c` | micrologiciel complet sous simavr, au cycle près : terminal, module, 8088 |
| `fusibles.txt` | lfuse FFh (quartz), hfuse D9h, efuse FDh |

## Construire, essayer, graver

```
make                 # PlatformIO : .pio/build/atmega328p/firmware.hex
make test            # vérifications du protocole sur le PC (gcc de WSL)
make banc            # banc simavr : 300 octets en écho dans chaque sens, 115200, 57600, 9600
make flash PUCE=ok   # TL866CS, puce dans le support ZIF : micrologiciel puis fusibles
make fusibles        # relit les fusibles
```

`make banc` demande simavr dans WSL, extrait sans `sudo` (voir le Makefile). Le banc remplit
les registres au hasard avant le départ (le vrai AVR ne les met pas à zéro) et compense
plusieurs écarts de simavr 1.6 avec le vrai AVR : une interruption démasquée alors
que son drapeau est levé n'y est pas déclenchée ; écrire dans TIFR1 y efface tous les
drapeaux de la minuterie (le matériel n'efface que les bits écrits à 1) ; la broche OC1A y
change dès l'écriture de TCCR1A. L'USART de simavr compte en outre un bit de parité
dans chaque octet et n'a pas de double tampon d'émission : le banc corrige le premier point ;
le second rend ses mesures du sens terminal → module, en mode pont, pessimistes. Variables :
`BANC_VITESSES` (codes de vitesse), `BANC_OCTETS`, `BANC_US` (µs par octet SPI), `BANC_PONT`
(1 : pont en duplex, 2 : un sens puis l'autre), `BANC_V2` (vitesse du module), `BANC_GRAINE`.

La puce se programme hors du montage. `minipro` signale *Fuses verify error* : il relit
à 1 le bit SPIEN de hfuse (F9h), qu'on ne peut pas changer dans ce mode de
programmation. Le micrologiciel ne va jamais dans `Z:/Partage/Alain`, réservé aux ROM du
8088.
