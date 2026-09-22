# Pont STM32 (WeAct Black Pill V3.1, STM32F411) ↔ 8088

Portage de `../ve2cuy_bridge/ve2cuy_bridge.ino` (Arduino UNO) sur une
**Black Pill V3.1** (STM32F411CEU6, 100 MHz, USB natif). **Même protocole** côté
8088 : le firmware de `Solution-01` n'est pas modifié (étape 1 du portage).

> ✅ **Validé sur le matériel** (étape 1) : téléversement DFU, LED, LCD I2C, clavier
> PS/2, terminal USB et toutes les fonctions du menu du 8088 (dont le BASIC) avec
> `BUS_HIGH_NIBBLE_REVERSED 1`. Le câblage et les niveaux 3,3 V / 5 V restent à
> vérifier pour tout nouveau montage — voir « Vérifications ».

## Câblage

| Signal | Black Pill | 8255 / autre | Remarques |
|---|---|---|---|
| Bus `D0`-`D3` | **PB12, PB13, PB14, PB15** | `PA0`-`PA3` (mode 2) | bidirectionnel, sans pull |
| Bus `D4`-`D7` | **PB6, PB7, PB8, PB9** | `PA4`-`PA7` | idem (deux quartets, ordre direct D0 = PA0) |
| `ACK#` | **PB0** | `PC6` | sortie **drain ouvert** + 10 kΩ vers +5 V |
| `STB#` | **PB1** | `PC4` | sortie **drain ouvert** + 10 kΩ vers +5 V |
| `OBF#` | **PA8** | `PC7` | entrée |
| Canal bit 0 / bit 1 | **PA9 / PA10** | `PB0` / `PB1` (Port B) | entrées |
| `TAG` | **PB4** | `PC0` | sortie : `0` = scan code, `1` = octet UART |
| `IBF` (facultatif) | **PA15** | `PC5` | voir `USE_IBF` ; non câblé = « libre » (pull-down interne) |
| `TAG1` (**réponses**) | **PB5** | `PC1` (broche 15 du 8255A) | **sortie seulement** (PB5 n'est pas tolérante 5 V). **À câbler** pour l'horloge RTC, avec une **résistance de 10 kΩ vers la masse** sur `PC1` : `1` = l'octet envoyé est une réponse à une commande |
| **Horloge du 8088** | **PA3** | broche `CLK` (19) du 8088 | **PWM matériel** (`TIM2` canal 4), duty cycle fixe 1/3, 1-10 MHz (défaut 4,77 MHz) — remplace le fil depuis l'Arduino UNO R4 de `projets/Clock-8088/`. `PA3` servait à `TAG2`/`PC2` (jamais câblée) : **si votre montage câble `TAG2`, cette broche est prise et ne convient plus** |
| PS/2 `CLK` | **PA1** | connecteur clavier | interruption EXTI1 ; pull-up 4,7-10 kΩ vers +5 V conseillé |
| PS/2 `DATA` | **PA2** | connecteur clavier | idem |
| LCD I2C `SCL` / `SDA` | **PB10 / PB3** | module PCF8574 | I2C2 (AF4 / AF9) ; pull-ups 5 V du module ; adresse `0x27` (`LCD_ADDR`) |
| PC (terminal) | **USB-C** | — | port série virtuel (`Serial`), débit sans objet |
| Masse | **GND** | masse du 8088 | **commune** |

Broches **à ne pas utiliser** : `PA11`/`PA12` (USB), `PA13`/`PA14` (SWD), `PC13`
(LED, clignote à 1 Hz = le pont tourne), `PC14`/`PC15` (quartz RTC), `PA4`-`PA7`
(flash SPI de la carte, si soudée), `PB2` (**BOOT1** : ne rien y brancher, son
niveau au reset décide du mode de démarrage), `PA0` (bouton K1). Aucune broche
libre ne reste sur le brochage utile (21 signaux, dont les 2 facultatifs).

**Quartet haut inversé (constaté sur le montage)** : avec les broches ci-dessus, le
terminal recevait `0x20` (espace) en `0x40` (`@`) et `p` (`0x70`) en `0xE0` : les
broches `PA4`-`PA7` du 8255 arrivent dans l'ordre inverse (`D4↔D7`, `D5↔D6`), comme
sur l'UNO (`A0`-`A3` ↔ `PA7`-`PA4`). `BUS_HIGH_NIBBLE_REVERSED 1` (par défaut)
corrige cela **en logiciel**, en lecture comme en écriture ; mettre `0` si le bus
est recâblé dans l'ordre (`D0`…`D7` ↔ `PA0`…`PA7`).

## Vérifications avant de brancher

1. **Tolérance 5 V** — vérifiée dans la fiche technique
   (`medias/stm32f411.pdf`, DS10314 Rev 8, tableau 8, boîtier UFQFPN48) :
   toutes les broches utilisées ici sont **FT** (5 V) **sauf `PA0` et `PB5`**
   (`TC` : 3,3 V seulement). `PB5` a donc été réservée à une **sortie** (`TAG1`) ;
   `PA0` n'est pas utilisée. `PC13`-`PC15` sont alimentées par l'interrupteur de
   l'alimentation RTC : courant de sortie limité (la LED seule sur `PC13`).
2. **Niveaux de sortie 3,3 V** : corrects pour les entrées TTL du 8255 et du 8259
   (VIH ≈ 2 V). Problème possible avec de la logique **74HC** alimentée en 5 V
   (VIH ≈ 3,5 V) sur une ligne pilotée par le pont : à vérifier. `ACK#`/`STB#`
   sont en drain ouvert : leur niveau haut est un vrai 5 V grâce aux pull-ups.
3. **Pull-ups 10 kΩ vers +5 V** sur `ACK#` et `STB#` (recommandés ; le pull-up
   interne à 3,3 V sert de secours). Ils gardent ces lignes hautes pendant un
   reset ou une reprogrammation du STM32.
4. **`PB2` (BOOT1)** : ne pas l'utiliser. Si un signal du 8255 (par exemple
   `OBF#`, haut au repos) y était relié, le mode DFU (`BOOT0` + `NRST`) démarrerait
   en SRAM au lieu du chargeur système.
5. **Alimentation** : soit l'USB-C seul, soit le +5 V du montage sur la broche
   `5V` — **jamais les deux** sans diode d'isolement. Masse commune obligatoire.
6. `PB3`/`PB4`/`PA15` sont des broches JTAG au reset : le croquis les
   reconfigure (I2C2, sortie, entrée). Avec un ST-Link, utiliser **SWD** seulement.

## Compilation et téléversement (PlatformIO)

Le projet est un projet **PlatformIO** (`platformio.ini`, croquis dans
`src/main.cpp`, cœur STM32duino via `platform = ststm32`) :

```powershell
cd breadboard\arduino\8088_bridge_stm32
C:\Users\alin_\.platformio\penv\Scripts\platformio.exe run                # compile
C:\Users\alin_\.platformio\penv\Scripts\platformio.exe run -t upload      # téléverse
```

Les `build_flags` (`PIO_FRAMEWORK_ARDUINO_ENABLE_CDC`, `USBCON`,
`HAL_PCD_MODULE_ENABLED`) font de `Serial` le **port USB** : ne pas les retirer.
Téléversement : **DFU** (confirmé sur le matériel ; tenir `BOOT0`, appuyer sur `NRST`, relâcher, puis
`upload_protocol = dfu`) ou **SWD** avec un ST-Link (`upload_protocol = stlink`).

Ouvrir le port série (COM du PC, n'importe quel débit) **ne réinitialise pas**
la carte, contrairement à l'UNO. Terminal : ANSI, 24×80 au moins, **écho local
désactivé**, Entrée = `CR`.

## Horloge temps réelle (RTC) et commandes du canal 3

> ✅ **Validé sur le matériel** : `TIME$` et `DATE$` (lecture et réglage) depuis le BASIC.

Étape 1 de l'évolution : le pont possède la **RTC** du STM32 (quartz LSE
32,768 kHz de la carte, bibliothèque `STM32duino RTC` 1.8.0 — la 2.x exige un cœur
plus récent que celui de PlatformIO). Le 8088 la lit et la règle par des
**commandes sur le canal 3** ; les réponses reviennent avec l'étiquette
`TAG1`/`PC1` = 1 (voir `Solution-01/lib/bridge.asm`) :

| Octets envoyés (canal 3) | Effet / réponse |
|---|---|
| `00h` | PING : réponse `B1h`, version `3`, capacités `17h` (bit 0 RTC, bit 1 disque, bit 2 secteurs, bit 4 image de disquette ; `1Fh` avec le lecteur USB, bit 3) |
| `01h` | LIRE : 8 octets = année (bas, haut), mois, jour, heures, minutes, secondes, centièmes |
| `02h` + 7 octets | RÉGLER : année (2 octets, 2000-2099), mois, jour, heures, minutes, secondes ; valeurs invalides ignorées |

- **Câblage supplémentaire** : `PB5` (`TAG1`) → `PC1` du 8255 (broche 15 du 8255A), avec
  10 kΩ vers la masse sur `PC1`. Le 8088 ne lit `PC1` que **pendant une commande**
  (`BRIDGE_EXPECT_OFF`, mis par `rtc_get`) : non câblée, elle ne perturbe donc pas le
  clavier ni l'UART hors de ces ~ 10 ms, mais elle est indispensable pour un
  fonctionnement fiable de `TIMER`/`TIME$`/`DATE$` (un octet tapé pendant la lecture
  serait sinon pris pour une réponse, et le niveau d'une entrée flottante n'est pas
  garanti).
- **Pile** : sans pile CR2032 sur la broche `VB` (VBAT), l'heure est perdue à chaque
  mise hors tension (l'horloge repart d'une date par défaut) ; elle se règle depuis le
  BASIC : `TIME$="12:30:00"`, `DATE$="09-20-2026"`.
- **Centièmes** : lus dans `RTC->SSR` (registres lus dans l'ordre SSR, TR, DR : lecture
  cohérente), résolution ~ 4 ms.
- `RTC_USE_LSE` (croquis) : `1` = quartz de la carte ; **si la carte n'a pas de quartz
  LSE, l'initialisation peut bloquer** (la LED cesse de clignoter) : mettre `0` (LSI,
  imprécis).
- La réponse à `LIRE` met ~ 8 ms (un octet toutes les `GAP_US` = 1 ms tant que `IBF`
  n'est pas utilisé).

## Disque : FAT16 sur la flash SPI (commandes `10h`-`19h`)

Étape 3 : la flash **W25Q64 (8 Mo, JEDEC EF4017)** de la carte porte un volume **FAT16** (MBR +
partition, lisible plus tard par un DOS) ; le pont y expose des **fichiers à la
racine** (noms 8.3, un seul ouvert à la fois) au 8088. Le STM32F411 n'a pas de
QUADSPI : la flash est utilisée en **SPI simple** (SPI1 : `PA4` = CS, `PA5` = SCK,
`PA6` = MISO, `PA7` = MOSI — broches réservées, déjà internes à la carte). Bibliothèques
PlatformIO : `Adafruit SPIFlash` et `SdFat - Adafruit Fork`.

| Octets envoyés (canal 3) | Réponse |
|---|---|
| `10h` | état (0 = prêt, 1 = pas de disque / pas de système de fichiers) |
| `11h` | FORMATER (**détruit tout**, plusieurs secondes) → état |
| `12h`, mode (0 lecture, 1 écriture/création, 2 ajout), longueur, nom | OUVRIR (ferme le fichier précédent) → état |
| `13h`, n (1-32) | longueur lue (0 = fin de fichier, `FFh` = erreur), puis les octets |
| `14h`, n (1-32), n octets | ÉCRIRE → état |
| `15h` | FERMER → état (vide le cache vers la flash) |
| `16h` / `17h` | RÉPERTOIRE début → état / entrée suivante → longueur du nom (0 = fin), nom, taille (4 octets) |
| `18h`, longueur, nom | SUPPRIMER → état |
| `19h` | espace libre, 4 octets (octets) |
| `20h` | SECTEURS : nombre de secteurs de 512 octets, 4 octets (flash entière, 16384 pour 8 Mo) |
| `21h`, LBA (4 octets) | LIRE le secteur dans le tampon de 512 octets du pont → état |
| `22h`, i (0-15) | OBTENIR le bloc i (32 octets) du tampon → 32 octets |
| `23h`, i (0-15), 32 octets | DÉPOSER le bloc i dans le tampon → état |
| `24h`, LBA (4 octets) | ÉCRIRE le tampon dans le secteur → état |
| `27h`, longueur, nom | MONTER une image de disquette (un fichier de la racine, lecture/écriture) → état, puis sa taille (4 octets) |
| `28h` | DÉMONTER l'image → état |
| `29h`, LBA (4 octets) | LIRE le secteur LBA de l'image dans le tampon du pont → état (puis `22h`) |
| `2Ah`, LBA (4 octets) | ÉCRIRE le tampon (déposé par `23h`) dans le secteur LBA de l'image → état |
| `2Bh` | SOMME de contrôle : somme (16 bits) des 512 octets du tampon → 2 octets (poids faible d'abord). Le 8088 la demande après chaque secteur lu (`21h`/`29h`), la compare à celle des octets reçus et relit le secteur (3 essais) si elles diffèrent |
| `2Ch`, action | HORLOGE du 8088 : `0` lire (ne rien changer), `1` +1 MHz, `2` -1 MHz (1-10 MHz), `3` → 4,77 MHz (défaut), `4` → 8 MHz → 4 octets (fréquence résultante en Hz, poids faible d'abord) |
| `25h` | USB ON : le PC prend le disque (lecteur de masse) → état ; état 9 = pile USB sans lecteur de masse |
| `26h` | USB OFF : le pont reprend le disque (remonte le volume) → état |

États : 0 OK, 1 disque non prêt, 2 introuvable, 3 existe déjà, 4 erreur d'E/S, 5 nom
invalide, 6 déjà ouvert, 7 non ouvert, 8 disque plein.

**Accès par secteurs** (`20h`-`24h`, base d'un futur DOS) : la flash entière (MBR compris) est
vue comme un disque de secteurs de 512 octets, LBA 32 bits. Le transfert passe par un tampon de
512 octets du pont, par blocs de 32 octets (taille maximale d'une réponse pour le tampon de
64 octets du 8088). Chaque lecture/écriture de secteur ferme le fichier ouvert ; après une
écriture, le volume FAT est remonté (`fsStale`) à la prochaine commande fichier, pour que ses
caches ne soient pas périmés. Un LBA hors de la flash donne l'état 4.

- **Premier démarrage** : si la flash est **neuve** (premier secteur tout à `FFh` ou
  à zéro), elle est formatée automatiquement. Un disque déjà utilisé n'est **jamais**
  reformaté sans la commande `FORMAT "YES"` du BASIC.
- **Pont sans flash** (ou flash illisible) : les commandes répondent « disque non
  prêt » ; le 8088 affiche `Disk not Ready`.
- Chaque fermeture (`15h`) et chaque suppression appellent `flash.syncBlocks()` : les
  données sont réellement écrites dans la flash (le cache de la bibliothèque est vidé).
- Le tampon des réponses du 8088 fait 64 octets : blocs de lecture de 32 octets,
  donc ~ 3 Ko/s en lecture (`LOAD` d'un programme de 2 Ko : moins d'une seconde).
- **Accès depuis le PC** (lecteur USB) : voir la section « Lecteur USB » ci-dessous (environnement
  `blackpill_f411ce_usbdrive`).

## Lecteur USB : la flash vue du PC (environnement `blackpill_f411ce_usbdrive`)

Le même croquis se compile en deux versions (`platformio.ini`) :

| Environnement | Pile USB | Ce que voit le PC |
|---|---|---|
| `blackpill_f411ce_usbdrive` (**par défaut**) | **Adafruit TinyUSB** | un port série **et** un lecteur de masse « 8088 Disk » (la flash entière, MBR + volume FAT16). |
| `blackpill_f411ce` (secours) | celle du cœur STM32 | un port série (CDC) seulement. Sans `USB ON`. |

```
platformio run -t upload                          (défaut = usbdrive ; DFU: BOOT0 + NRST)
platformio run -e blackpill_f411ce -t upload      (secours : port série seul)
```

- **Partage PC / 8088 (jamais les deux à la fois)** : au démarrage le lecteur est présent mais
  **vide** (« pas de disque »). `USB ON` dans le BASIC (commande `25h`) le « insère » : le PC monte le
  volume, et toute commande disque du 8088 (`FILES`, `SAVE`, `DSKREAD`…) donne `Disk not Ready` tant
  que c'est actif. **Éjecter le lecteur sur le PC**, puis `USB OFF` (`26h`) : le pont reprend le
  disque et remonte le volume (il a pu être modifié par le PC). `USB ON` est refusé (`File already open`)
  si un fichier de données BASIC est ouvert.
- Capacité annoncée : `flash.size() / 512` secteurs (16384 pour la W25Q64). Les écritures du PC
  passent par `flash.writeBlocks` et `syncBlocks` (vidage du cache vers la flash).
- **Avec cette pile, `Serial` n'existe pas** : le croquis passe par `UsbSerial` (= `SerialTinyUSB`) ;
  le nom `Serial` est réservé au port matériel de la carte (utilisé par SdFat pour ses messages). Le
  numéro de **port COM peut changer** (autre périphérique USB pour Windows, autres VID/PID).
- La commande `26h`/`25h` d'un pont **sans** cette pile (environnement de secours) répond « non
  géré » (état 9) : le BASIC affiche `Device unavailable`. Le PING annonce le bit 3 (`0Fh`) seulement
  avec la pile TinyUSB.
- **Validé sur le matériel** : port série, lecteur « 8088 Disk », `USB ON`, copie d'un fichier depuis
  le PC, `USB OFF`, `FILES`. La pile TinyUSB pour STM32F4 est récente : en cas de problème (le port
  série n'apparaît plus, etc.), retéléverser l'environnement de secours `blackpill_f411ce`.

## Réglages (début du croquis)

| Constante | Défaut | Rôle |
|---|---|---|
| `LCD_ADDR` | `0x27` | adresse I2C du PCF8574 (`0x3F` pour un PCF8574A) |
| `BUS_HIGH_NIBBLE_REVERSED` | `1` | corrige l'inversion du quartet haut du bus (voir ci-dessus) |
| `USE_IBF` | `1` | `PC5` (`IBF`) câblée sur `PA15` : le pont n'envoie un octet que si le 8088 a lu le précédent (aucun octet écrasé) ; les réponses de l'horloge partent dès que `IBF` retombe (~ 2 ms au lieu de 8). `0` = non câblée |
| `LINE_DELAY_MS` | 15 | pause après chaque `CR` venant du PC : le 8088 traite la ligne saisie (tokenisation, insertion) avant la suivante ; évite de perdre des caractères lors d'un **collage** de code BASIC |
| `GAP_US` | 1000 | espace minimal entre deux octets pont → 8088 (en plus de `IBF` : le 8088 ne traite pas plus de ~ 2000 caractères/s en saisie) |
| `TX_STALL_MS` | 100 | si personne ne lit le port USB, l'octet est jeté au bout de ce délai (le 8088 n'est jamais bloqué) |
| `HEARTBEAT` | 1 | LED `PC13` à 1 Hz |
| `RTC_USE_LSE` | 1 | horloge RTC sur le quartz LSE de la carte (`0` = LSI interne) |
| `CMD_TIMEOUT_MS` | 100 | une commande `02h` incomplète est abandonnée après ce délai |
| `KBD_QUIET_US` / `BUS_QUIET_US` | 3000 / 400 | silence `CLK` avant d'agir sur le bus (inchangé) |
| `DEBUG_PS2` | 0 | `1` = trace PS/2 sur le port USB (`{76}` octet décodé, `{>76}` envoyé au 8088…) |

## Mise en route conseillée

1. **Sans le montage 8088** : téléverser, ouvrir le port USB, vérifier que la LED
   `PC13` clignote et que le LCD I2C s'initialise.
2. **PS/2 seul** : `DEBUG_PS2=1`, appuyer sur des touches : `{76}` etc. doivent
   apparaître sans `{P..}`/`{S..}`/`{G}`.
3. **Avec le 8088** (ROM du projet) : le menu doit s'afficher sur le terminal et
   le LCD ; un test simple : option `4) BASIC`, `PRINT 2+3`, `HELP`.
4. Collage d'un programme BASIC dans le terminal : `IBF` (`USE_IBF 1`) évite d'écraser
   un octet, `LINE_DELAY_MS` laisse au 8088 le temps de traiter chaque ligne. Si des
   caractères se perdent encore, augmenter `LINE_DELAY_MS` (ou `GAP_US`).

## Différences avec la version UNO

| | UNO | Black Pill |
|---|---|---|
| Accès au bus | `PINB`/`PINC`/`PIND`, lecture instantanée des 3 ports | `GPIOB->IDR` + `GPIOA->IDR` (instantané), `BSRR` pour l'écriture ; bus en deux quartets sur `GPIOB` (`busFromIdr`/`busDrive`) |
| `ACK#`/`STB#` | sorties push-pull | **drain ouvert** (+10 kΩ vers 5 V) |
| Liaison PC | `Serial` matériel 57600 bauds (reset au DTR) | port série **USB** natif (pas de reset, débit sans objet) |
| I2C | `A4`/`A5` | `PB3`/`PB10` (I2C2, `Wire.setSDA/SCL`) |
| `IBF` | non câblé (pas de broche libre) | **PA15** (facultatif) |

## Suite prévue (pas encore faite)

- Capture PS/2 par timer matériel (seulement si des touches se perdent).
