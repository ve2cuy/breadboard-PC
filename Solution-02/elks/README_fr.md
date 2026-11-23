# ELKS pour Solution-02

[English version](README.md)

[ELKS](https://github.com/ghaerr/elks) (Embeddable Linux Kernel Subset) 0.9.2 est un petit
système multitâche de type Unix pour le 8086/8088, adapté ici à la carte Solution-02. Le
dossier `src/` contient l'arbre complet des sources d'ELKS 0.9.2 avec les modifications
ci-dessous (sans le dossier `Screenshots/` du dépôt d'origine). ELKS est sous licence
GPL v2, voir `src/LICENSE`.

État : essayé dans le simulateur de Solution-02 (BIOS 2.6), **pas encore sur le
montage**. ELKS démarre jusqu'à `login:` au LCD et au terminal. On ouvre une session
avec `root`, sans mot de passe. `uname`, `ls`, `ps`, `cat`, le shell et les redirections
fonctionnent.

## Pourquoi les images officielles ne marchent pas

Les images officielles d'ELKS pilotent directement le matériel du PC : l'écran en mémoire
vidéo (B800h, de la ROM sur Solution-02), le CRTC 6845 (3D4h), le clavier au port 60h, le
contrôleur de disquette et son DMA (ports 00h–0Fh, ceux du LCD sur Solution-02). La seule
autre console prévue est un port série 8250 en 3F8h, absent de la carte. Le noyau démarre
quand même depuis la carte SD (par INT 13h), mais rien ne s'affiche.

## Modifications

| Fichier | Modification |
|---|---|
| `src/solution02.config` | Configuration de compilation, tirée de `ibmpc-1440.config` : **console Headless** (`CONFIG_CONSOLE_HEADLESS` : sortie par INT 10h AH=0Eh, clavier scruté par INT 16h, donc la console du BIOS 2.6 fonctionne : LCD, terminal UART et clavier PS/2), sans pilote de clavier à scan codes, image de disquette de 360 Ko (système de fichiers MINIX), `CONFIG_HW_SOLUTION02`. |
| `src/elks/config.in` | Nouvelle option `CONFIG_HW_SOLUTION02` (carte Solution-02). |
| `src/elks/arch/i86/kernel/irqtab.S` | Avec `CONFIG_HW_SOLUTION02` : **EOI du 8259 au début de chaque IRQ 0–7** (avant le `sti`), et plus d'EOI à la fin. Voir plus bas. |
| `src/elkscmd/rootfs_template/bin/top` | Nouveau : un petit `top` (script) : `uptime` et `ps` (CPU %, tas, pile, taille par tâche) rafraîchis toutes les 2 s (`top 5` : toutes les 5 s), Ctrl-C pour quitter. ELKS n'a pas de `top`. |
| `src/elkscmd/rootfs_template/bootopts` | `disable=df0,cfa` : le pilote de disquette direct (DMA 8237 aux ports 00h–0Fh) et le pilote CompactFlash restent désactivés. Les disques passent par le BIOS (`fd0`, `hda`). Ces pilotes restent compilés parce que, sans `CONFIG_BLK_DEV_FD`, `directfd.c` ne compile pas dans ELKS 0.9.2. |

`solution02.patch` contient les mêmes modifications sous forme de différences par rapport
à ELKS v0.9.2.

### Caractères perdus au terminal (EOI du 8259)

Le BIOS reçoit l'UART par logiciel : l'IRQ4 signale le bit de départ, puis les bits sont
échantillonnés par des boucles calibrées. L'IRQ4 doit être servie en moins d'un demi-bit
environ (~50 µs à 9600 bauds). ELKS n'envoyait l'EOI au 8259 qu'à la fin de chaque
traitement d'interruption. Pour l'horloge (IRQ0, 100 Hz), ce traitement dure environ
230 µs, scrutation du clavier par INT 16h comprise. Pendant ce temps, le 8259 retient les
IRQ moins prioritaires (IRQ1 clavier, IRQ4 UART). Comme il travaille sur les fronts, le
bit de départ était perdu et le BIOS commençait la lecture de la trame sur un front
suivant. L'octet était alors lu décalé de plusieurs bits (`b` → `ECh`), ou jeté quand il
ressemblait à un premier octet UTF-8. C'est ainsi que `root` devenait `rot`. Le BIOS
envoie déjà l'EOI de sa propre IRQ0 dès l'entrée pour cette raison ; la modification
d'ELKS fait la même chose.

Mesure au simulateur, sur 400 octets à phase aléatoire : sans la modification, seulement
41 IRQ4 servies, la plupart en retard (jusqu'à 862 µs). Avec la modification, 399 IRQ4
servies, dont 18 en retard.

### Limites restantes

- **Environ 2 à 3 % des caractères tapés sont encore perdus ou faux** (simulateur, frappe
  irrégulière à 100–300 ms d'écart, terminal UART ou clavier PS/2). Les causes :
  - le début de l'entrée d'interruption d'ELKS (changement de pile avec les interruptions
    masquées, ~120 µs à chaque tic de 10 ms) ;
  - l'UART logiciel du BIOS, qui ne peut pas recevoir pendant qu'il émet (écho, et
    réaffichages de l'éditeur de ligne du shell au-delà de 80 colonnes).

  Un vrai UART (MC6850, 8250…) supprimerait cette limite.
- **Couper les animations des DEL** (menu principal, touche 7) avant de démarrer ELKS.
  ELKS appelle l'horloge du BIOS un tic sur cinq, et un pas d'animation masque les
  interruptions assez longtemps pour perdre un caractère.
- **Pilotes Ethernet retirés** (`# CONFIG_ETH is not set`). La carte ne décode que les
  lignes d'adresse A0-A7 : les sondages ISA d'ELKS tombaient sur ses propres puces : NE2000
  en 300h = LCD (il y écrivait 21h, *function set* en mode 4 bits : LCD brouillé), WD8003
  en 240h = 8253, 3C509 en 330h = U12. Ne pas les remettre.
- Les séquences ANSI qu'ELKS envoie au terminal (effacement, déplacements du curseur) sont
  interprétées par le BIOS 2.8 au lieu de s'afficher au LCD.
- La date est fausse (1979) : ELKS lit l'horloge aux ports 70h/71h, absents de la carte.
  La régler avec `date`.
- L'image de 360 Ko contient les 36 programmes de la liste `APPS_360K` d'ELKS (`sh`, `ls`,
  `cat`, `cp`, `mv`, `rm`, `mkdir`, `more`, `edit`, `grep`, `ps`, `mount`, `fdisk`, `mkfs`,
  `tetris`…).

## Utilisation

1. Copier l'image (`PC-DOS/ELKS-0.9.2/fd360-minix-s02.img`, hors de git, ou
   `sortie/elks-solution02-fd360.img` après une construction) sur la carte SD.
2. Menu principal : **7** (animations des DEL OFF), puis **1) DOS**, choisir l'image,
   Entrée.
3. Après ~50 s (lecture de 360 Ko par la carte SD) : `login:` → `root`, sans mot de passe.

## Image de disque dur (tous les programmes, compilateur C)

`PC-DOS/ELKS-0.9.2/hd32-minix-s02.img` (hors de git ; `sortie/elks-solution02-hd32.img`
après une construction) : 32 Mo, table de partitions (63 secteurs × 16 têtes), une
partition MINIX (type 80h), ELKS installé avec **tous les programmes** d'`elkscmd`
(environ 200 dans `/bin` : `vi`, `edit`, `emacs` (kilomacs), `kilo`, `sed`, `diff`,
`find`, `tar`, `gzip`, `bc`, `basic`, `lua`, `screen`, `ps`, `top`, `meminfo`, `uptime`,
jeux…) et les applications externes qui se construisent : le **compilateur C natif C86**
(`/usr/bin` : `cpp`, `c86`, `as`, `ld`, `ar`, `make`, `objdump`, `disasm86` ; en-têtes dans
`/usr/include`, `/usr/lib/libc86.a`, exemples dans `/usr/src`), le compilateur dcc
(`/usr/dcc`), Lua, Doom, Moria, Digger, visionneuses d'images… Il n'existe pas de
compilateur C++ pour ELKS. Les programmes graphiques (Nano-X, GEM, paint) demandent une
carte VGA et ne tournent pas sur le montage.

1. Copier l'image sur la carte SD (d'un seul tenant : le BIOS refuse une image
   fragmentée). Le BIOS la monte en C: (premier `.IMG` de plus de 1,44 Mo).
2. Menu principal : **7** (animations des DEL OFF), **1) DOS**, choisir la ligne de C:,
   Entrée.
3. `login:` → `root`. Depuis une partition MINIX sur C:, le BIOS 2.8 retire le disque B:
   en RAM et donne 507 Ko à ELKS (506K vus par le noyau, ~346 Ko libres) : avec les 379 Ko
   annoncés sinon, `cpp` et `c86` échouent (*not enough memory*).

Compiler un programme sur le montage :

```
cpp -0 -I/usr/include -I/usr/include/c86 hello.c -o hello.i
c86 -O -bas86 -separate=yes -lang=c99 -stackcheck=no hello.i hello.as
as -0 -j hello.as -o hello.o
ld -0 -i -L/usr/lib -o hello hello.o -lc86
./hello
```

`/usr/src/Makefile` (exemples) reprend les mêmes étapes pour `make`.

## Réseau (Wi-Fi par SLIP)

Le module Wi-Fi de J13 est un routeur SLIP avec NAT (esp_slip_router, voir le README de
Solution-02). ELKS y accède par **`/dev/ttyS1`** : pilote
`elks/arch/i86/drivers/char/serial-s02.c` (+ `serial-s02-asm.S`), choisi à la place du pilote
8250 quand `CONFIG_HW_SOLUTION02` est actif. Il passe par le BIOS 3.1 (INT 14h, DX = 1, AH =
08h/09h : blocs), qui partage le bus SPI avec la carte SD ; la réception est scrutée à chaque
tic d'horloge (`serial_bh`, 64 octets au plus), la vitesse est fixée par le module (115200).
`ttyS0` n'existe pas. Au démarrage : `ttyS1 Wi-Fi module via BIOS INT 14h (ATmega U17 channel 2)`.

```
net start slip                 # ktcp -m 512 sur /dev/ttyS1, 192.168.240.2, passerelle .1 ; telnetd
ping -c 3 192.168.240.1        # le module
ping -c 3 8.8.8.8              # Internet, a travers le NAT
ping google.com                # DNS par OpenDNS (208.67.222.222, en TCP)
```

- Réglages de l'image : `/etc/net.cfg` (`link=slip`, `device=/dev/ttyS1`, `baud=115200`,
  `mtu="-m 512"` : segments TCP de 472 octets au plus, dans le tampon de 1 Ko de l'ATmega,
  `netstart="telnetd"`), `/bin/net` (passe la MTU à ktcp en SLIP), `/bootopts`
  (`LOCALIP=192.168.240.2`, `GATEWAY=192.168.240.1`, `NETMASK=255.255.255.0`, `buf=24`).
- **Mémoire** : `buf=24` (tampons de disque 64 → 24 Ko) et pas de `ftpd` : avec 64 tampons et
  ftpd, une session telnet ne laissait plus de bloc assez grand pour lancer `ls`.
- **Telnet depuis le PC** : ELKS est derrière le NAT du module. Une redirection dans le module
  (console `telnet 192.168.240.1 7777` depuis ELKS : `portmap add TCP 23 192.168.240.2 23`,
  `save`), puis `telnet <adresse Wi-Fi du module>` depuis le PC. Donner un mot de passe à root
  (`passwd`) : sans lui, tout le réseau Wi-Fi a une session root.
- Débit : le 8088 lit le module à ~6 Ko/s au plus, sans contrôle de flux : le ping, telnet et
  les petits transferts vont bien ; les gros transferts subiront des retransmissions TCP.
- Simulateur : `tests/elks_reseau.rs` (module simulé en SLIP qui répond aux pings, session
  telnet locale).

## Construction

Depuis Windows, avec Docker Desktop démarré :

```
powershell -ExecutionPolicy Bypass -File construire.ps1
```

`construire.sh` tourne dans un conteneur Ubuntu 24.04. Il installe les outils (`xxd` est
nécessaire : sans lui, `bootblocks/mbr_autogen.c` reste vide et `makeboot.c` ne compile
pas), construit une seule fois la chaîne croisée ia16-elf-gcc 6.3.0 (~20 min, gardée dans
le volume Docker `elks-s02-cache`), puis le noyau, les programmes et l'image :
`sortie/elks-solution02-fd360.img` et `sortie/elks-solution02-noyau.bin`. Le `make`
complet finit par une erreur sur l'image pleine (trop de fichiers pour 360 Ko) ; le
script s'y attend et construit ensuite l'image réduite (`make fd360-minix`).

Image de disque dur :

```
powershell -ExecutionPolicy Bypass -File construire-hd.ps1
```

`construire-hd.sh` lance `construire.sh`, puis télécharge OpenWatcom v2 (instantané
Linux, gardé dans le volume), clone et construit les applications externes par
`buildext.sh` (C86, dcc, Lua, Doom… ; un projet en échec manque seulement à l'image, voir
`sortie/externes.log`) et construit `make hd32mbr-minix` (`CONFIG_APPS_HD` : tous les
programmes) : `sortie/elks-solution02-hd32.img`. Fichiers absents : `sortie/absents-hd.log`.
