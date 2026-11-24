# Raspberry Pi Pico W sur le bus du 8088 (Solution-02)

*[English version](README.md)*

Le Pico W (A1 au schéma) est un périphérique d'E/S du 8088 sur les ports **50h-57h** : O5 du 74LS138, A0-A2. Il est
derrière deux **SN74LVC245** alimentés en 3,3 V :
- U18 pour D0-D7, à travers RN4 ;
- U19 pour A0-A2, ~SEL, ~RD, ~WR et RESET.

**Q1** met RDY1 du 82C84 à 0 : le 8088 attend pendant que le Pico répond. Le Pico donne au 8088 sa propre carte
microSD (J14), le Wi-Fi avec TCP/IP, et une interruption (GP22 → IRQ3 par J16).

| Dossier | Contenu |
|---|---|
| [coeur](coeur) | Le **cœur** du micrologiciel, sans matériel : registres 50h-57h, commandes de la carte SD, SLIP, relais TCP/IP (smoltcp), programme PIO du bus. Le micrologiciel et le [simulateur](../Simulateur-Pico/README_fr.md) le partagent. |
| [micrologiciel](micrologiciel) | Le **micrologiciel** (Rust, embassy) : PIO1 et cœur 1 pour le bus, SPI0 pour la carte, Wi-Fi CYW43439 avec embassy-net, console sur UART1. Produit : `s02pico-micrologiciel.uf2`. |
| [etude-pico-w_fr.md](etude-pico-w_fr.md) | L'étude : adaptation de niveaux, temps, répartition des broches. |

## Registres (port = 50h + n)

| n | Lecture | Écriture |
|---|---|---|
| 0 | octet suivant de la file de lecture (FFh si vide) | octet dans la file d'écriture |
| 1 | ETAT : 01h donnée, 02h occupé, 04h erreur, 08h réseau, 10h carte, 20h Wi-Fi, 40h IRQ (bit 7 toujours à 0) | COMMANDE |
| 2-5 | paramètres 0-3 (LBA en petit-boutiste, nombre) | idem |
| 6 | signature 50h | masque d'interruption (bit 0 : données réseau → GP22) |
| 7 | octets dans la file de lecture (255 au plus) | — |

Commandes :

| Code | Nom | Effet |
|---|---|---|
| 00h | VIDER | vide les files, efface l'erreur (immédiate) |
| 01h | IDENT | file de lecture ← `S02PICO` + version (01h) |
| 10h | SD_INIT | file de lecture ← 1 (carte prête) + nombre de secteurs (4 octets) |
| 11h | SD_LIRE | secteur LBA (paramètres 0-3) → 512 octets dans la file de lecture |
| 12h | SD_ECRIRE | les 512 premiers octets de la file d'écriture → secteur LBA |
| 20h | NET_LIRE | file de lecture ← n, puis n octets SLIP pour le 8088 (n ≤ paramètre 0, 0 = 255) |
| 21h | NET_ECRIRE | file d'écriture → flux SLIP venant du 8088 |
| 22h | NET_ETAT | octets en attente (2), Wi-Fi (1), adresse du Pico (4), RSSI (1) |
| 30h-32h | WIFI_SSID, WIFI_MDP, WIFI_CONNECTER | nom du réseau, mot de passe (file d'écriture), connexion |

Pour une commande : l'écrire en 51h, attendre que le bit 02h de 51h soit à 0, vérifier le bit 04h, puis lire 50h. Le
BIOS 3.3 ([../bios/pico.inc](../bios/pico.inc)) s'en sert pour :
- la carte SD : `sd_init`, `sd_lire`, `sd_ecrire` ;
- `INT 14h DX=1` : blocs AH = 08h/09h, et AH = 0Ah qui rend AL = 50h quand le Pico est là.

## Réseau : comment le Pico relaie TCP/IP

Le 8088 garde sa propre pile TCP/IP (mTCP, `ktcp` d'ELKS) et parle SLIP : 192.168.240.2, passerelle 192.168.240.1
(le Pico). Le cœur fonctionne comme slirp :
- les connexions **TCP** du 8088 se terminent dans le Pico (smoltcp, toute adresse de destination). Le micrologiciel
  ouvre la vraie connexion par le Wi-Fi et recopie les octets dans les deux sens. Pas de NAT à faire, et le routeur de
  la maison ne voit jamais 192.168.240.0/24 ;
- l'**UDP** (DNS…) et les **pings** sont relayés comme datagrammes et échos ;
- `http://192.168.240.1/` est une page d'état servie par le Pico lui-même.

## Le programme PIO du bus et READY

Le programme ([coeur/src/bus_pio.rs](coeur/src/bus_pio.rs), 24 instructions) fonctionne ainsi :
1. Dès que ~SEL tombe (T1), il met GP26 à 1, ce qui met RDY1 à 0.
2. **Lecture :** il passe A0-A2 au cœur 1, pose l'octet rendu sur D0-D7, puis libère READY.
3. **Écriture :** il libère READY tout de suite et prend D0-D7 à la remontée de ~WR. La donnée y est garantie au moins
   88 ns.

[coeur/tests/pio_bus.rs](coeur/tests/pio_bus.rs) exécute le **programme assemblé** dans un émulateur de PIO (125 MHz,
synchroniseur d'entrée) face au 8088 à 5,333 MHz, avec les pires temps des fiches (82C84, Q1, LVC245). Résultats :

| Latence du cœur 1 | États d'attente en moyenne | Max |
|---|---|---|
| 100 ns | 1,7 | 2 |
| 300 ns | 2,4 | 3 |
| 600 ns | 3,7 | 5 |
| 1,5 µs | 6,4 | 9 |

Tous les octets sont justes, dans tous les cas : READY retient le 8088 aussi longtemps qu'il faut.

À la remontée de ~RD, U18 se retourne vers le Pico pendant que celui-ci pilote encore D0-D7, **≈ 36 ns** (synchroniseur
+ 2 instructions). RN4 (100 Ω) limite ce courant. Sans RN4, c'est un court-circuit de ≈ 36 ns à chaque lecture.

## Construire le micrologiciel

```
rustup target add thumbv6m-none-eabi
cd micrologiciel
cargo build --release
python uf2.py target/thumbv6m-none-eabi/release/s02pico-micrologiciel s02pico-micrologiciel.uf2
```

Il occupe 343 Ko de flash et 141 Ko de RAM statique (avec un tas de 96 Ko). Pour programmer le Pico :
1. Brancher son câble USB en tenant **BOOTSEL** enfoncé.
2. Copier `s02pico-micrologiciel.uf2` sur le disque **RPI-RP2**.

Le réseau Wi-Fi se règle sur la **console J15** (UART1, 115200 bauds, 3,3 V) avec `ssid NOM`, `mdp MOT_DE_PASSE` et
`connecter`. Le réglage est gardé dans le dernier secteur de la flash. Le 8088 peut aussi le régler par les commandes
30h-32h. `etat` montre l'état du Wi-Fi, l'adresse et les compteurs.

## Essais

```
cd coeur
cargo test                      # registres, SD, ping, DNS, TCP (une seconde pile smoltcp joue le 8088), page d'état
cargo test --features pio       # programme PIO au cycle près face au 8088
```

Le simulateur ([../Simulateur-Pico](../Simulateur-Pico/README_fr.md)) fait tourner le même cœur avec le BIOS 3.3,
MS-DOS, FreeDOS (mTCP) et ELKS.

## État (2026-11-23)

Le schéma est fait, les SN74LVC245AN sont commandés, et rien n'est encore câblé. Le micrologiciel se construit mais n'a
pas encore tourné sur le Pico : il est validé par le simulateur et par l'essai du PIO.
