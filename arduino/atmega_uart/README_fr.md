# Micrologiciel de l'ATmega328P (Solution-02, U17)

[English version](README.md)

L'ATmega328P (quartz 16 MHz) est l'UART de la carte Solution-02. Il reçoit et émet
lui-même sur J5, garde les octets dans sa RAM, et le 8088 lui parle en SPI sur le bus de
la carte SD (schéma du 2026-11-21, voir `Solution-02/README_fr.md`). Il remplace l'UART
logiciel du BIOS 2.6, qui perd des caractères dès que les interruptions restent masquées
plus d'environ 50 µs.

| ATmega328P | Signal | Carte |
|---|---|---|
| PB2 SS | AVR_SS | U12 PC0 (R21 au +5 V) |
| PB3 MOSI / PB5 SCK | SD_MOSI / SD_SCK | U12 PC6 / PC5, partagés avec la carte SD |
| PB4 MISO | AVR_MISO | U12 PB4 (R20 au +5 V) |
| PD0 RXD / PD1 TXD | UART_RX / UART_TX | J5 broches 2 / 1 |
| PD2 | IRQ4 | IR4 du 8259 (front montant) |
| PD6 / PD7 | RTS / CTS | J8 broches 1 / 2, actifs à 0 (R22 tire CTS à 0) |

## Protocole SPI (version 2)

- SPI mode 0, poids fort en premier, comme pour la carte SD. La carte SD est
  désélectionnée (U12 PC4 = 1) tant que SS (U12 PC0) = 0. Au moins 10 µs entre deux
  octets : l'ATmega prépare l'octet suivant dans son interruption SPI.
- **Transaction** : SS = 0, un octet de commande, des octets de données, SS = 1. L'octet
  que le 8088 reçoit pendant l'octet *n* est celui que l'ATmega a préparé à la fin de
  l'octet *n−1*.
- Pendant l'octet de commande, le 8088 reçoit toujours **A5h**. Sans ATmega, il lit FFh
  (tirage R20) : c'est ainsi que le BIOS le détecte.

| Commande | Octets envoyés par le 8088 après la commande | Octets reçus |
|---|---|---|
| `00h` IDENT | 4 de remplissage | `'S'`, `'2'`, version (2), vitesse en service (code de VITESSE ; version 2) |
| `01h` ETAT | 5 de remplissage | nombre reçus (poids faible, fort), place libre en émission (faible, fort), drapeaux |
| `02h` LIRE | 1 de remplissage, puis *n* | *n* = min(reçus, 255), puis les *n* octets |
| `03h` ECRIRE | 1 de remplissage, puis les octets à émettre | *f* = min(place libre, 255), puis 00h |
| `04h` VITESSE | code de vitesse | 00h |
| `05h` VIDER | A5h (confirmation) | 00h |

- **LIRE** : un octet ne quitte le tampon qu'une fois entièrement transmis. Remonter SS
  plus tôt ne perd rien ; le reste viendra au LIRE suivant.
- **ECRIRE** : les octets au-delà de la place libre sont perdus et mettent le bit 2 des
  drapeaux.
- **Drapeaux d'ETAT** (remis à 0 par la lecture) : bit 0 = un octet reçu a été perdu
  (tampon de réception plein), bit 1 = erreur de trame ou débordement de l'USART,
  bit 2 = un octet à émettre a été perdu (tampon d'émission plein), bit 6 = CTS actif
  (le terminal accepte des octets), bit 7 = RTS actif (l'ATmega accepte des octets).
- **VITESSE** : 0 = 9600 (au démarrage), 1 = 19200, 2 = 38400, 3 = 57600, 4 = 115200,
  5 = 4800, 6 = 2400 bauds, 8N1. Appliquée quand tout ce qui attend est parti. L'ATmega n'est
  pas remis à zéro avec le 8088 (bouton RESET, Ctrl+Alt+Suppr) : il garde sa vitesse, et le BIOS
  2.7 la relit par IDENT (version 2) pour que le terminal reste à la vitesse choisie ; mise sous
  tension = 9600.
- **VIDER** n'agit qu'avec la confirmation A5h : un octet parasite (trafic SPI de la
  carte SD avec SS = 0 par erreur) ne peut pas vider les tampons.

## IRQ et contrôle de flux

- **IRQ (PD2 → IR4)** = 1 quand un octet reçu attend et qu'aucune transaction n'est en
  cours. Elle tombe au début de chaque transaction et remonte à la fin s'il reste des
  octets. Chaque transaction qui laisse des données redonne donc un front montant au
  8259 (mode front).
- **RTS** est retiré à 768 octets en attente (sur 1024) et rendu à 256.
- **CTS** : l'ATmega cesse d'émettre tant que le CTS du terminal est à 1. Sans rien sur
  J8, R22 garde CTS actif.
- Tampons : 1024 octets en réception, 512 en émission.

## Fichiers

| Fichier | Contenu |
|---|---|
| `src/protocole.h`, `src/protocole.c` | protocole et tampons, sans registre de l'AVR (testés sur le PC) |
| `src/main.c` | matériel : USART, SPI esclave, interruption de broche sur SS, IRQ, RTS/CTS |
| `test/test_protocole.c` | 56 vérifications : le 8088 maître simulé octet par octet |
| `fusibles.txt` | lfuse FFh (quartz), hfuse D9h, efuse FDh |

## Construire, essayer, graver

```
make                 # PlatformIO : .pio/build/atmega328p/firmware.hex
make test            # vérifications du protocole sur le PC (gcc de WSL)
make flash PUCE=ok   # TL866CS, puce dans le support ZIF : micrologiciel puis fusibles
make fusibles        # relit les fusibles
```

La puce se programme hors du montage. `minipro` signale *Fuses verify error* : il relit
à 1 le bit SPIEN de hfuse (F9h), qu'on ne peut pas changer dans ce mode de
programmation. Le micrologiciel ne va jamais dans `Z:/Partage/Alain`, réservé aux ROM du
8088.
