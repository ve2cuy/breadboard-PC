# Les deux environnements PlatformIO du pont

Un **environnement** PlatformIO est une recette de compilation nommée, déclarée par une section
`[env:nom]` dans [platformio.ini](platformio.ini). Un même projet, avec le même code source, peut
avoir plusieurs recettes. Chacune produit son propre firmware, dans son propre dossier
`.pio/build/<nom>/`.

## Les deux recettes de ce projet

| | `blackpill_f411ce_usbdrive` (par défaut) | `blackpill_f411ce` (secours) |
|---|---|---|
| Ligne dans le .ini | 35 | 20 |
| Drapeaux de compilation | `-D USE_TINYUSB` | `-D PIO_FRAMEWORK_ARDUINO_ENABLE_CDC`, `-D USBCON`, `-D HAL_PCD_MODULE_ENABLED` |
| Bibliothèques | RTC, SPIFlash, SdFat, plus **Adafruit TinyUSB** | les mêmes, sans TinyUSB |
| Pile USB | TinyUSB | celle du cœur STM32 |
| Ce que voit le PC | un port série et le lecteur « 8088 Disk » | un port série |
| `USB ON` dans le BASIC | fonctionne | `Device unavailable` |

Ce qui change vraiment est le **drapeau `-D`**. Il équivaut à écrire `#define USE_TINYUSB` tout en
haut du fichier avant de compiler. Le fichier `main.cpp` est le même dans les deux cas, mais le
préprocesseur en garde ou en jette des morceaux selon ce drapeau.

La ligne `default_envs = blackpill_f411ce_usbdrive` (ligne 11) dit ce que fait `platformio run` sans
précision. Pour l'autre : `platformio run -e blackpill_f411ce`. Dans VS Code, le choix se fait dans
la barre d'état en bas.

Commandes complètes (téléverser, DFU : BOOT0 + NRST) :

```
platformio run -t upload                                        (défaut : port série + lecteur USB)
platformio run -e blackpill_f411ce -t upload                    (secours : port série seul)
```

## Où le voir dans main.cpp

Cherche `USE_TINYUSB` (Ctrl+F) : six blocs `#ifdef` ou `#ifndef`. Le code entre
`#ifdef USE_TINYUSB` et `#else` ou `#endif` n'existe que dans la version `usbdrive`.

- **[Ligne 48-56](src/main.cpp#L48) :** le choix du port série. Avec TinyUSB, `UsbSerial` devient
  `SerialTinyUSB` ; sans, il devient `Serial`. C'est pour ça que tout le fichier écrit
  `UsbSerial.print(...)` (29 fois) au lieu de `Serial.print(...)`.
- **[Ligne 84](src/main.cpp#L84) :** la valeur annoncée par le PING (`USB_CAPS`), qui vaut `0x0F`
  avec TinyUSB et `0x07` sans.
- **[Ligne 466](src/main.cpp#L466) :** les fonctions du lecteur de masse (`mscRead`, `mscWrite`,
  `usbMscBegin`).
- **[Ligne 485](src/main.cpp#L485) :** dans `usbExec`, avec TinyUSB, `USB ON` réussit ; sans, il
  répond « non géré » et le BASIC affiche `Device unavailable`.
- **[Ligne 744](src/main.cpp#L744), [766](src/main.cpp#L766) :** dans `setup()`, le démarrage de
  TinyUSB (`TinyUSBDevice.begin(0)`) et l'ordre d'initialisation du disque.
- **[Ligne 800](src/main.cpp#L800) :** dans `loop()`, l'appel à `yield()` qui fait tourner la pile
  USB.

(Les numéros de ligne sont ceux du moment de l'écriture ; ils dérivent si `main.cpp` change.)

VS Code grise le code inactif selon l'environnement choisi.

## Pourquoi deux recettes plutôt qu'une

La pile USB de TinyUSB est récente. Elle a d'abord été essayée dans un environnement séparé, en
gardant la recette d'origine intacte. `usbdrive` a ensuite été validé sur le matériel (`USB ON`,
copie d'un fichier depuis le PC, `USB OFF`, `FILES`) et il est devenu l'environnement par défaut
(ligne 11 du .ini). La recette d'origine reste comme secours : si la pile TinyUSB pose un problème,
`platformio run -e blackpill_f411ce -t upload` redonne le firmware éprouvé (terminal seul).

Voir aussi la section « Lecteur USB » du [README.md](README.md).
