# S02PKT : pilote de paquets pour le DOS (Solution-02)

[English version](README.md)

`S02PKT.COM` est un **pilote de paquets** (Packet Driver Specification 1.09, classe 1 =
Ethernet) pour le module Wi-Fi de Solution-02 : un Grove - UART WiFi V2 regravé en routeur
SLIP avec NAT (esp_slip_router), derrière l'ATmega U17. Il donne le réseau aux programmes du
DOS qui passent par un pilote de paquets, en particulier **mTCP** (`PING`, `TELNET`, `FTP`,
`HTGET`, `NC`, `SNTP`, `IRCJR`, `HTTPSERV`…).

## Fonctionnement

- Comme ETHERSL, il présente une **carte Ethernet simulée** (MAC 02:53:30:32:00:02) :
  - trame IPv4 envoyée : en-tête Ethernet retiré, paquet IP envoyé en SLIP au module ;
  - requête ARP : réponse fabriquée sur place, avec l'adresse du « pair » (02:53:30:32:00:01)
    pour toute adresse IP demandée, puisque tout passe par le module. Pas de réponse aux sondes
    de conflit d'adresse (adresse demandée = celle de l'émetteur, ou émetteur en 0.0.0.0) ;
  - paquet IP reçu en SLIP : en-tête Ethernet ajouté, remis au programme abonné au type 0800h.
- Il passe par le **BIOS 3.1** : INT 14h, DX = 1, AH = 08h (lecture d'un bloc) et 09h
  (écriture d'un bloc). Le BIOS partage le bus SPI avec la carte SD.
- Pas d'interruption pour le canal 2 : le module est **scruté à chaque INT 1Ch** (18,2 Hz),
  255 octets au plus par tic (~4,6 Ko/s), sur une pile privée.
- Fonctions de la spécification : `driver_info`, `access_type` (4 abonnés), `release_type`,
  `send_pkt`, `get_address`, `reset_interface`, `get_statistics`. `terminate` est refusé : le
  pilote reste en mémoire (≈ 2,7 Ko).

## Utilisation

```
C:\MTCP\S02PKT               (installe le pilote sur INT 60h)
SET MTCPCFG=C:\MTCP\MTCP.CFG
PING 192.168.240.1           (le module)
PING 8.8.8.8                 (Internet, à travers le NAT)
HTGET http://example.com/
```

`MTCP.CFG` :

```
PACKETINT 0x60
IPADDR 192.168.240.2
NETMASK 255.255.255.0
GATEWAY 192.168.240.1
NAMESERVER 8.8.8.8
MTU 576
```

Il faut le **BIOS 3.1** (ou plus récent) et un **ATmega en version 3** (ou plus) : sinon,
`S02PKT` refuse de s'installer. ELKS et le DOS utilisent les mêmes adresses : un seul des deux
tourne à la fois sur la carte.

## Image de disque dur

`bios/tests/gen_dosnet.py` fabrique `PC-DOS/DOSNET_C.IMG` (32 Mo, hors de git) : MS-DOS 6.22
(comme `gen_dos622.py`), mTCP dans `C:\MTCP` (archive `PC-DOS/mTCP_2026-10-10.zip`, mTCP de
Michael Brutman, GPL : <https://www.brutman.com/mTCP/>), `S02PKT.COM` et `MTCP.CFG` ;
`AUTOEXEC.BAT` charge le pilote et définit `MTCPCFG`.

## Construire et essayer

```
nasm -f bin -o S02PKT.COM s02pkt.asm
python ../bios/tests/gen_dosnet.py
cd ../Simulateur && cargo test --release --test dos_reseau -- --nocapture
```

L'essai du simulateur démarre le DOS depuis C:, vérifie l'installation du pilote, puis
`PING 192.168.240.1` et `PING 8.8.8.8` (le module simulé répond aux pings).

## Limites

- Débit modeste : quelques Ko/s (SPI bit par bit du 8088, scrutation à 18,2 Hz), sans contrôle
  de flux sur le canal 2. MTU 576 conseillée.
- `PING` à travers le NAT de l'ESP8285 marche ; les connexions entrantes demandent une
  redirection dans le module (`portmap`), comme pour ELKS.
