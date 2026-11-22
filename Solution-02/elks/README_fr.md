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
- Le LCD se brouille au bout d'un moment : il reçoit une commande *function set 21h*
  (mode 4 bits). Pas encore étudié.
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
