# ELKS (Minix) sur Solution-01

*[English version](README.md)*

[ELKS 0.9.2](https://github.com/ghaerr/elks) (un petit Linux pour 8086, système de fichiers MINIX),
construit pour le montage de Solution-01. Les sources d'ELKS sont celles de Solution-02
(`../../Solution-02/elks/src`) ; seuls la configuration (`solution01.config`) et quelques changements
sous `CONFIG_HW_SOLUTION01` diffèrent.

## Construction

Docker Desktop, puis depuis ce dossier :

```
powershell -ExecutionPolicy Bypass -File construire.ps1
```

La chaîne croisée ia16-elf-gcc est gardée dans le volume Docker `elks-s02-cache` (partagé avec
Solution-02). Résultat : `sortie/elks-solution01-fd360.img` (disquette de 360 Ko). La copier sur la
flash du pont (menu *USB Disk → ON*), puis l'amorcer par *USB Disk → 3) Boot disk image*. Se connecter
en `root`.

Il faut la ROM 2.0 et le pont 2.3 (tic d'horloge).

## Ce qui change par rapport à Solution-02

Solution-01 n'a pas de minuterie 8253 et son décodage des E/S est minimal : le 8255 qui parle au pont
répond à tout port où A7 = 1, le 8259 à tout port où A5 = 1. L'ELKS de Solution-02 atteignait les deux,
ce qui figeait le lien avec le pont (curseur bloqué en 0,0).

| Problème sur Solution-01 | Changement |
|---|---|
| Pas d'interruption de minuterie : ni ordonnancement, ni clavier (scruté à chaque tic) | Le pont 2.3 envoie un tic toutes les 54,9 ms (commande 30h) ; le BIOS de la ROM en fait l'INT 1Ch, comme le BIOS du PC depuis l'IRQ 0 ; ELKS utilise `CONFIG_TIMER_INT1C` |
| `outb_p`/`inb_p` marquent une pause en écrivant le port 80h = port de données du 8255 : des octets partaient au pont comme des commandes | `IO_DELAY_PORT` 4Fh (`include/arch/io.h`, `CONFIG_HW_SOLUTION01`) |
| Sondage des 8250 (3F8h-3FFh, 2F8h, 3E8h, 2E8h ; LCR 3FBh = mot de commande du 8255) | `CONFIG_CHAR_DEV_RS` désactivé |
| Arrêt des moteurs de disquette (3F2h), pilote direct de disquette (CMOS 70h, FDC) | `bioshd.c` protégé par `CONFIG_HW_SOLUTION01` ; `CONFIG_BLK_DEV_FD` désactivé |
| Sondage IDE/CF (1F0h-1F7h) | `CONFIG_IDE_PROBE`, `CONFIG_BLK_DEV_ATA_CF` désactivés |
| `clock -s` lit la CMOS (70h/71h = 8259) | `clock` passe par l'INT 1Ah du BIOS (la RTC du pont) |
| Haut-parleur (61h = 8259) | `CONFIG_AUDIO` désactivé |

Console : sans écran (INT 10h / INT 16h du BIOS), terminal ou clavier PS/2 ; la console du LCD du
pont la montre aussi.

Essayé au simulateur (`tests/rom_test.py`, image copiée en `PC-DOS/ELKS-0.9.2/fd360-minix-s01.img`) :
connexion, `ls`, `date`, et aucun accès au 8255 ni au 8259 hors du BIOS.
