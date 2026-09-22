#include <Arduino.h>
// ============================================================================
// main.cpp (projet PlatformIO 8088_bridge_stm32)  -  Pont WeAct Black Pill V3.1 (STM32F411) <-> 8088
//                              (8255 en MODE 2)
//
// Portage de ve2cuy_bridge.ino (Arduino UNO) - MEME PROTOCOLE cote 8088: le
// firmware du 8088 (Solution-01) n'est pas modifie. Voir README.md (meme
// dossier) pour le cablage, les niveaux 3,3 V / 5 V et la mise en route.
//
// Roles (inchanges):
//   - clavier PS/2  : decode la trame (CLK/DATA), verifie parite/stop, envoie
//                     le scan code brut (Set 2) au 8088;
//   - UART          : port serie virtuel USB (USB natif, "Serial") <-> 8088;
//   - LCD 20x4 I2C  : possede le bus I2C et le protocole PCF8574/HD44780.
//
// 8088 -> pont : le 8088 pose le CANAL sur le Port B (PB0/PB1 du 8255) puis
//     ecrit le Port A; OBF# passe a 0. On lit le canal, on abaisse ACK#, on lit
//     l'octet, on relache ACK#. canal 0 = octet UART, 1 = commande LCD, 2 =
//     donnee LCD.
// pont -> 8088 : on pose l'etiquette TAG (PC0: 0 = scan code, 1 = octet UART
//     recu; PC1 = 1: REPONSE a une commande), l'octet sur le bus, et on pulse
//     STB#; INTR du 8255 (sur IR1 du 8259) interrompt le 8088.
// canal 3 = COMMANDES pour le pont (voir Solution-01/lib/bridge.asm):
//     00h PING (reponse B1h, 1, capacites)   01h LIRE l'heure (reponse: 8 octets)
//     02h + 7 octets REGLER l'heure (annee 2 octets, mois, jour, h, min, s).
//     Necessite TAG1 (PB5) relie a PC1 du 8255 (tire a 0 par 10 kohm).
//     10h-19h = DISQUE: fichiers FAT (racine, noms 8.3) sur la flash SPI (W25Q64, 8 Mo) de la carte
//     (PA4 = CS, SPI1 PA5/PA6/PA7): statut, formater, ouvrir, lire, ecrire, fermer,
//     repertoire (debut / suivant), supprimer, espace libre. Voir lib/bridge.asm.
//     2Ch + 1 octet (action) = HORLOGE du 8088 (PA3, PWM materiel, voir clockExec ci-dessous):
//     0 lire, 1 +0,1 MHz, 2 -0,1 MHz, 3 +1 MHz, 4 -1 MHz, 5 -> 4,77 MHz, 6 -> 8 MHz
//     -> reponse 4 octets = Hz resultant.
//
// CABLAGE (voir le tableau du README.md)
//   D0-D3 <-> PB12-PB15 et D4-D7 <-> PB6-PB9  <->  8255 PA0-PA7 (bus de donnees)
//   PB0 -> ACK# (PC6)   PB1 -> STB# (PC4)   PA8 <- OBF# (PC7)   PB4 -> TAG (PC0)
//   PA9 <- canal bit 0 (8255 PB0)   PA10 <- canal bit 1 (8255 PB1)
//   PA15 <- IBF (PC5, facultatif)   PB5 -> TAG1 (PC1)
//   PA3 -> CLK du 8088 (broche 19, PWM materiel TIM2 CH4 - remplace le fil depuis l'Arduino UNO
//   R4 de projets/Clock-8088/; PA3 servait a TAG2/PC2, jamais cablee sur ce montage - libre)
//   PA1 <- CLK PS/2   PA2 <- DATA PS/2   PB10 = SCL, PB3 = SDA (LCD I2C2)
//   PA11/PA12 = USB, PA13/PA14 = SWD, PC13 = LED, PA4-PA7 = flash SPI (reservees),
//   PB2 = BOOT1 (ne rien y brancher), PA0 = bouton K1 de la carte
// Selon la fiche technique du STM32F411 (DS10314 Rev 8, tableau 8), TOUTES ces
// broches sont tolerantes 5 V (FT) SAUF PA0 et PB5 (TC, 3,3 V): PB5 n'est donc
// utilisee qu'en SORTIE (TAG1). Ne jamais y relier une sortie 5 V.
// ============================================================================
#include <Wire.h>
#include <HardwareTimer.h>
#include <STM32RTC.h>
#include <SPI.h>
#include <SdFat.h>
#include <Adafruit_SPIFlash.h>
#ifdef USE_TINYUSB
// Environnement PlatformIO blackpill_f411ce_usbdrive: pile USB Adafruit TinyUSB (port serie CDC +
// lecteur de masse). Le nom Serial y est inutilisable (macros croisees de la bibliotheque): on
// passe par UsbSerial. Sans USE_TINYUSB: pile USB du coeur STM32 (CDC seul), UsbSerial = Serial.
#include <Adafruit_TinyUSB.h>
#define UsbSerial SerialTinyUSB
#else
#define UsbSerial Serial
#endif

// ---- reglages -------------------------------------------------------------
#define LCD_ADDR    0x27     // 0x3F pour un PCF8574A
// IBF (PC5 du 8255) cable sur PA15 ? 1 = oui: on n'envoie un octet que si le 8088 a lu le
// precedent (aucun octet ecrase); 0 = non cable. Non cable, PA15 est tiree a 0 (= libre).
#define USE_IBF     1
// Espace MINIMAL entre deux octets pont -> 8088, en plus de IBF. Le 8088 met ~ 0,5 ms
// par caractere saisi (echo compris): a plus de ~ 2000 caracteres/s il ne suit plus et
// son tampon de reception (256 octets) deborde pendant un long collage.
#define GAP_US      1000UL
// Espace minimal entre deux octets de REPONSE (horloge, disque, secteurs, image de disquette): avec IBF
// cable (USE_IBF 1), un octet ne part que quand le 8088 a lu le precedent (IBF = 0): l'espace de 1 ms n'est
// plus necessaire et les blocs de 32 octets des secteurs partent au rythme de l'interruption du 8088
// (~ 150-300 us par octet) au lieu de 1 ms. Sans IBF (USE_IBF 0), les reponses gardent GAP_US.
#define REPLY_GAP_US 20UL
// Pause apres chaque retour chariot (CR) venant du PC: le 8088 traite la ligne saisie
// (tokenisation, insertion dans le programme) avant de recevoir la suivante. 0 = aucune.
#define LINE_DELAY_MS 15UL
// Apres une commande du 8088 au pont (disque, horloge...), le 8088 est occupe: ses instructions
// (OPEN, PRINT#, WRITE#, CLOSE...) durent des dizaines de ms et il ne vide pas son tampon de
// reception (256 octets). On suspend l'envoi des octets UART (collage) jusqu'a ce delai apres la
// derniere commande, sinon un collage de plusieurs lignes deborde ce tampon.
#define CMD_HOLD_MS   250UL
#define TX_STALL_MS 100UL    // port USB sans lecteur: on jette l'octet apres ce delai
#define HEARTBEAT   1        // 1 = LED (PC13, active a l'etat bas) clignote a 1 Hz
// Horloge temps reel: 1 = quartz LSE 32,768 kHz de la carte (precis; la carte V3.1 le
// porte), 0 = oscillateur interne LSI (imprecis). Sans pile sur VBAT l'heure est
// perdue a la mise hors tension.
#define RTC_USE_LSE 1
// Diagnostic disque: 1 = chaque commande disque recue est signalee sur le port serie USB
// ([fs] op=.. flash=.. fs=..), melangee a la sortie du BASIC. A remettre a 0 ensuite.
#define DEBUG_FS 0
#ifdef USE_TINYUSB
#define USB_CAPS 0x1F        // RTC + disque + secteurs + lecteur USB + image de disquette (+ 2Bh somme de controle)
#else
#define USB_CAPS 0x17
#endif
#define CMD_TIMEOUT_MS 100UL // commande a arguments incomplete: abandonnee apres ce delai
// Le clavier envoie 0F0h puis le code de la touche COUP SUR COUP. Toute impulsion
// sur STB#/ACK#/bus pendant qu'une trame PS/2 arrive risque de la perturber: on
// n'agit donc sur le bus 8255 que si CLK est silencieux depuis:
#define KBD_QUIET_US 3000UL  // avant d'ENVOYER un octet clavier (fin de la rafale)
#define BUS_QUIET_US 400UL   // avant tout autre acces au bus (trame en cours)
// Filtrage du bruit sur CLK/DATA: un vrai front descendant de CLK reste bas >=
// 30 us, un parasite de diaphonie quelques us seulement.
#define PS2_GLITCH_US    10UL  // CLK doit etre encore basse apres ce delai
#define PS2_FRAME_GAP_US 250UL // sans front valide depuis: nouvelle trame
#define DEBUG_PS2   0        // 1 = trace PS/2 sur le terminal (Serial), voir dbg*()

// ---- broches --------------------------------------------------------------
// Les signaux sont lus et ecrits par registres (BSRR/IDR) pour garder les temps
// de l'instantane (voir takeFrom8088).
#define ACK_BIT   0                  // GPIOB, sortie drain ouvert (10 kohm vers +5 V)
#define STB_BIT   1                  // GPIOB, sortie drain ouvert (10 kohm vers +5 V)
#define TAG_BIT   4                  // GPIOB, sortie
#define TAG1_BIT  5                  // GPIOB, sortie SEULEMENT (PB5 n'est pas tolerante 5 V)
#define OBF_BIT   8                  // GPIOA, entree
#define CH0_BIT   9                  // GPIOA, entrees (canal = Port B du 8255)
#define CH1_BIT   10
#define IBF_BIT   15                 // GPIOA, entree (facultatif)
#define PS2_CLK_BIT  1               // GPIOA, interruption EXTI1
#define PS2_DATA_BIT 2               // GPIOA
const uint32_t PIN_ACK = PB0, PIN_STB = PB1, PIN_TAG = PB4;
const uint32_t PIN_OBF = PA8, PIN_CH0 = PA9, PIN_CH1 = PA10, PIN_IBF = PA15;
const uint32_t PIN_TAG1 = PB5;                         // PC1 (etiquette etendue, futur)
const uint32_t PIN_PS2_CLK = PA1, PIN_PS2_DATA = PA2;
const uint32_t PIN_SCL = PB10, PIN_SDA = PB3;          // I2C2 (AF4 / AF9)
const uint32_t PIN_CLK8088 = PA3;                      // TIM2 CH4: horloge du 8088 (broche CLK, 19) -
                                                         // remplace le fil depuis l'Arduino UNO R4 (projets/Clock-8088)
                                                         // - PA3 servait a TAG2/PC2, jamais cablee sur ce montage

// Bus de donnees sur GPIOB, en deux quartets: D0-D3 = PB12-PB15, D4-D7 = PB6-PB9
#define BUS_ODR_MASK   ((0xFUL << 12) | (0xFUL << 6))
#define BUS_MODER_MASK 0xFF0FF000UL  // 2 bits par broche: PB12-15 (bits 24-31) et PB6-9 (bits 12-19)
#define BUS_MODER_OUT  0x55055000UL  // 01 = sortie
// Sur le montage, les broches PA4-PA7 du 8255 arrivent dans l'ORDRE INVERSE
// (constate: espace 0x20 recu 0x40, 'p' 0x70 recu 0xE0): le quartet haut est
// inverse (D4<->D7, D5<->D6), comme sur l'UNO. 1 = corrige en logiciel, 0 = bus
// cable dans l'ordre (D0-D7 <-> PA0-PA7).
#define BUS_HIGH_NIBBLE_REVERSED 1

// ---- canaux 8088 -> pont (Port B du 8255) ---------------------------------
const uint8_t CH_UART     = 0;
const uint8_t CH_LCD_CMD  = 1;
const uint8_t CH_LCD_DATA = 2;
const uint8_t CH_CMD      = 3;         // commandes pour le pont (horloge...)

// ============================================================================
// Acces rapide aux broches (registres GPIO)
// ============================================================================
static inline void ackLow()  { GPIOB->BSRR = (1UL << (ACK_BIT + 16)); }
static inline void ackHigh() { GPIOB->BSRR = (1UL << ACK_BIT); }
static inline void stbLow()  { GPIOB->BSRR = (1UL << (STB_BIT + 16)); }
static inline void stbHigh() { GPIOB->BSRR = (1UL << STB_BIT); }
static inline bool obfHigh() { return (GPIOA->IDR >> OBF_BIT) & 1; }   // 1 = rien en attente
static inline void tagWrite(uint8_t t) {   // t = 0: scan code, 1: octet UART, 2: reponse
  GPIOB->BSRR = (t & 1) ? (1UL << TAG_BIT) : (1UL << (TAG_BIT + 16));
  GPIOB->BSRR = (t & 2) ? (1UL << TAG1_BIT) : (1UL << (TAG1_BIT + 16));
}

// ============================================================================
// Bus Port A du 8255 = PB12-PB15 (D0-D3) + PB6-PB9 (D4-D7) (MODER/BSRR/IDR)
// ============================================================================
static inline void busRelease() {          // haute impedance, sans pull
  GPIOB->MODER &= ~BUS_MODER_MASK;         // 00 = entree
}

// Inverse l'ordre des 4 bits du quartet haut (involution: sert a la lecture et a l'ecriture)
static inline uint8_t fixHighNibble(uint8_t v) {
#if BUS_HIGH_NIBBLE_REVERSED
  uint8_t h = (uint8_t)(v >> 4);
  h = (uint8_t)(((h & 1) << 3) | ((h & 2) << 1) | ((h & 4) >> 1) | ((h & 8) >> 3));
  return (uint8_t)((v & 0x0F) | (h << 4));
#else
  return v;
#endif
}

static inline uint8_t busFromIdr(uint32_t idr) {
  return fixHighNibble((uint8_t)(((idr >> 12) & 0x0F) | ((idr >> 2) & 0xF0)));
}

static inline void busDrive(uint8_t v) {   // niveau AVANT de passer en sortie
  v = fixHighNibble(v);
  uint32_t set = ((uint32_t)(v & 0x0F) << 12) | ((uint32_t)(v & 0xF0) << 2);
  GPIOB->BSRR = ((BUS_ODR_MASK & ~set) << 16) | set;
  GPIOB->MODER = (GPIOB->MODER & ~BUS_MODER_MASK) | BUS_MODER_OUT;
}

// pont -> 8088: octet + etiquette, puis impulsion STB#.
#if DEBUG_FS
static uint8_t dbgIbfAfter = 0;
#endif
static void sendTo8088(uint8_t tag, uint8_t v) {
  tagWrite(tag);
  busDrive(v);
  delayMicroseconds(2);
  stbLow();
  delayMicroseconds(2);
  stbHigh();                               // front montant: le 8255 verrouille
  delayMicroseconds(2);
#if DEBUG_FS
  dbgIbfAfter = (uint8_t)((GPIOA->IDR >> IBF_BIT) & 1);   // IBF doit valoir 1 (octet non lu)
#endif
  busRelease();
}

// 8088 -> pont: si OBF# est bas, lit canal + octet. ACK# bas = le 8255 pilote
// le bus (les broches sont des entrees a ce moment-la). INSTANTANE indispensable:
// le 8255 remet OBF# a 1 des que ACK# DESCEND, donc le 8088 peut ecrire l'octet
// suivant ~15 us plus tard, pendant qu'on lit encore le bus. Ici les deux ports
// sont lus en quelques cycles (< 100 ns).
static bool takeFrom8088(uint8_t &chan, uint8_t &val) {
  if (obfHigh()) return false;             // rien en attente
  ackLow();
  delayMicroseconds(2);                    // tAOD du 8255 < 200 ns
  uint32_t b = GPIOB->IDR;
  uint32_t a = GPIOA->IDR;
  ackHigh();
  val  = busFromIdr(b);
  chan = (uint8_t)(((a >> CH0_BIT) & 1) | (((a >> CH1_BIT) & 1) << 1));
  return true;
}

// ============================================================================
// File 8088 -> peripheriques (256 entrees, 255 utiles)
// ============================================================================
struct Item { uint8_t chan; uint8_t val; };
static Item   q[256];
static uint8_t qHead = 0, qTail = 0;
static inline bool qEmpty() { return qHead == qTail; }
static inline bool qFull()  { return (uint8_t)(qHead + 1) == qTail; }

// ============================================================================
// Horloge temps reel et commandes du canal 3
// ============================================================================
static STM32RTC &rtc = STM32RTC::getInstance();

static uint8_t rq[64];                     // reponses en attente d'envoi au 8088
static uint8_t rqHead = 0, rqTail = 0;
static void replyByte(uint8_t v) {
  uint8_t nh = (uint8_t)((rqHead + 1) & 63);
  if (nh != rqTail) { rq[rqHead] = v; rqHead = nh; }
}

// Lecture COHERENTE par registres: SSR d'abord (verrouille les registres image), puis
// TR et DR (deverrouille). Centiemes = (PREDIV_S - SSR) / (PREDIV_S + 1) * 100.
static void replyTime() {
  uint32_t ss = RTC->SSR;
  uint32_t tr = RTC->TR;
  uint32_t dr = RTC->DR;
  uint32_t prediv = RTC->PRER & 0x7FFFUL;
  uint8_t hh = (uint8_t)(((tr >> 20) & 3) * 10 + ((tr >> 16) & 15));
  uint8_t mm = (uint8_t)(((tr >> 12) & 7) * 10 + ((tr >> 8) & 15));
  uint8_t sc = (uint8_t)(((tr >> 4) & 7) * 10 + (tr & 15));
  uint16_t year = (uint16_t)(2000 + ((dr >> 20) & 15) * 10 + ((dr >> 16) & 15));
  uint8_t mo = (uint8_t)(((dr >> 12) & 1) * 10 + ((dr >> 8) & 15));
  uint8_t dd = (uint8_t)(((dr >> 4) & 3) * 10 + (dr & 15));
  uint32_t cs = (ss <= prediv) ? ((prediv - ss) * 100UL) / (prediv + 1UL) : 0;
  if (cs > 99) cs = 99;
  replyByte((uint8_t)year); replyByte((uint8_t)(year >> 8));
  replyByte(mo); replyByte(dd); replyByte(hh); replyByte(mm); replyByte(sc);
  replyByte((uint8_t)cs);
}

static void applyTime(const uint8_t *a) {  // annee (2 octets), mois, jour, h, min, s
  uint16_t year = (uint16_t)(a[0] | (a[1] << 8));
  if (year < 2000 || year > 2099 || a[2] < 1 || a[2] > 12 || a[3] < 1 || a[3] > 31 ||
      a[4] > 23 || a[5] > 59 || a[6] > 59) return;               // valeurs invalides: ignore
  rtc.setDate(a[3], a[2], (uint8_t)(year - 2000));
  rtc.setTime(a[4], a[5], a[6]);
}

// ============================================================================
// Horloge du 8088 (PA3 = TIM2 CH4, PWM materiel, duty cycle fixe 1/3 - voir
// projets/Clock-8088/src/main.cpp, meme principe mais sur l'Arduino UNO R4 separe
// d'origine: ici, l'horloge est generee par CE MEME pont, plus besoin de 2e carte).
// clockSetup() DOIT etre appelee EN PREMIER dans setup() (avant SPI/USB/RTC, qui
// prennent du temps): le 8088 a besoin d'une horloge stable des sa mise sous tension.
// Valeur courante en Hz (pas de table fixe - reglage continu par pas de 100 kHz ou
// 1 MHz), bornee a [1, 10] MHz, 4,77 MHz par defaut au demarrage de ce pont (vitesse
// du PC IBM d'origine). Commande 2Ch (1 octet d'argument, le CODE D'ACTION, numerote
// comme les options du sous-menu Clock speed - voir Solution-01/solution-01.asm) ->
// reponse 4 octets = la frequence resultante en Hz (poids faible d'abord, meme
// convention que fs_free/fs_dir_next - voir Solution-01/lib/bridge.asm):
//   0 = ne rien changer (sert de LIRE), 1 = +0,1 MHz, 2 = -0,1 MHz, 3 = +1 MHz,
//   4 = -1 MHz, 5 = aller a 4,77 MHz, 6 = aller a 8 MHz.
// ============================================================================
#define CLOCK_MIN_HZ     1000000UL
#define CLOCK_MAX_HZ    10000000UL
#define CLOCK_DEFAULT_HZ 4770000UL
#define CLOCK_STEP_SMALL  100000UL                 // 0,1 MHz
#define CLOCK_STEP_BIG   1000000UL                 // 1 MHz
static HardwareTimer clockTimer(TIM2);
static uint32_t clockHz = CLOCK_DEFAULT_HZ;

static void clockApply() {                         // (re)configure le PWM sur la frequence courante
  clockTimer.setPWM(4, PIN_CLK8088, clockHz, 33);
}

// clockSetup: PREMIERE chose faite dans setup() - demarre l'horloge du 8088 a 4,77 MHz
// avant tout le reste (SPI/USB/RTC peuvent prendre plusieurs dizaines de ms).
static void clockSetup() {
  clockApply();
}

static void clockExec(uint8_t action) {
  switch (action) {
    case 1:                                          // +0,1 MHz
      clockHz = (clockHz + CLOCK_STEP_SMALL > CLOCK_MAX_HZ) ? CLOCK_MAX_HZ : clockHz + CLOCK_STEP_SMALL;
      break;
    case 2:                                          // -0,1 MHz
      clockHz = (clockHz < CLOCK_MIN_HZ + CLOCK_STEP_SMALL) ? CLOCK_MIN_HZ : clockHz - CLOCK_STEP_SMALL;
      break;
    case 3:                                          // +1 MHz
      clockHz = (clockHz + CLOCK_STEP_BIG > CLOCK_MAX_HZ) ? CLOCK_MAX_HZ : clockHz + CLOCK_STEP_BIG;
      break;
    case 4:                                          // -1 MHz
      clockHz = (clockHz < CLOCK_MIN_HZ + CLOCK_STEP_BIG) ? CLOCK_MIN_HZ : clockHz - CLOCK_STEP_BIG;
      break;
    case 5: clockHz = CLOCK_DEFAULT_HZ; break;        // 4,77 MHz
    case 6: clockHz = 8000000UL; break;               // 8 MHz
    default: break;                                   // 0 (ou inconnu) = lire seulement
  }
  if (action >= 1 && action <= 6) clockApply();
  replyByte((uint8_t)clockHz); replyByte((uint8_t)(clockHz >> 8));
  replyByte((uint8_t)(clockHz >> 16)); replyByte((uint8_t)(clockHz >> 24));
}

// ============================================================================
// Disque: systeme de fichiers FAT sur la flash SPI (W25Q64, 8 Mo) de la carte.
// Le STM32F411 n'a pas de QUADSPI: la flash s'utilise en SPI simple (SPI1: PA4 = CS,
// PA5 = SCK, PA6 = MISO, PA7 = MOSI). Fichiers a la racine, noms 8.3.
// ============================================================================
static Adafruit_FlashTransport_SPI flashTransport(PA4, SPI);
static Adafruit_SPIFlash flash(&flashTransport);
static FatVolume fatfs;
static bool flashOk = false, fsOk = false;
static bool usbActive = false;            // USB ON: le PC a le disque (le 8088 recoit "disque non pret")
static bool fsStale = false;              // secteurs ecrits en direct: remonter le volume avant tout acces fichier
static File32 curFile, dirRoot;
static File32 imgFile;                    // image de disquette montee (commandes 27h-2Ah), independante de curFile
static bool imgOpen = false;
static uint32_t imgSize = 0;
static bool fileOpen = false, dirOpen = false;
static uint8_t curMode = 0;

enum { FSE_OK = 0, FSE_NOTREADY = 1, FSE_NOTFOUND = 2, FSE_EXISTS = 3, FSE_IO = 4,
       FSE_BADNAME = 5, FSE_OPEN = 6, FSE_NOTOPEN = 7, FSE_FULL = 8, FSE_NOSUPPORT = 9 };

// Ferme l'image de disquette (avant tout ce qui touche au volume: formatage, secteurs, USB, remontage)
static void imgClose() {
  if (imgOpen) { imgFile.close(); imgOpen = false; }
}

static void fsCloseAll() {
  if (fileOpen) { curFile.close(); fileOpen = false; flash.syncBlocks(); }
  if (dirOpen)  { dirRoot.close(); dirOpen = false; }
}

// Formate la flash en FAT16 (DETRUIT tout). Vrai si le volume est ensuite monte.
static bool fsFormat() {
  static uint8_t secBuf[512];
  fsCloseAll();
  imgClose();
  FatFormatter formatter;
  bool ok = formatter.format(&flash, secBuf, nullptr);
  flash.syncBlocks();
  fsOk = ok && fatfs.begin(&flash);
  return fsOk;
}

// Vrai si le premier secteur de la flash est entierement efface (0xFF) ou nul: flash
// neuve, formatage automatique sans risque (un disque deja utilise n'est JAMAIS
// formate sans la commande FORMAT).
static bool flashLooksBlank() {
  static uint8_t sec[512];
  if (!flash.readBlocks(0, sec, 1)) return false;
  uint8_t a = 0xFF, b = 0x00;
  for (int i = 0; i < 512; i++) { a &= sec[i]; b |= sec[i]; }
  return a == 0xFF || b == 0x00;
}

static void fsMount() {
  flashOk = flash.begin();
  fsOk = flashOk && fatfs.begin(&flash);
  if (flashOk && !fsOk && flashLooksBlank()) fsFormat();
}

// Nom 8.3 (majuscules, chiffres, . _ - $ ~) : 1-8 caracteres, point facultatif, 0-3 d'extension
static bool nameOk(const char *n) {
  int base = 0, ext = -1;
  for (const char *p = n; *p; p++) {
    char c = *p;
    if (c == '.') { if (ext >= 0 || base == 0) return false; ext = 0; continue; }
    if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '$' || c == '~'))
      return false;
    if (ext >= 0) { if (++ext > 3) return false; } else if (++base > 8) return false;
  }
  return base > 0 && ext != 0;
}

static void replyStatus(uint8_t st) { replyByte(st); }

// Execute une commande disque complete (opcode + arguments dans cmdBuf).
static void fsExec(const uint8_t *c) {
  uint8_t op = c[0];
  if (op == 0x11) { replyStatus(flashOk ? (fsFormat() ? FSE_OK : FSE_IO) : FSE_NOTREADY); return; }
  if (fsStale) { fsStale = false; fsCloseAll(); imgClose(); fsOk = flashOk && fatfs.begin(&flash); }
  if (!fsOk) {                             // pas de flash ou pas de systeme de fichiers
    if (op == 0x13 || op == 0x17) replyByte(0xFF);
    else if (op == 0x19) { for (int i = 0; i < 4; i++) replyByte(0xFF); }
    else replyStatus(FSE_NOTREADY);
    return;
  }
  switch (op) {
    case 0x10: replyStatus(FSE_OK); break;
    case 0x12: {                           // OUVRIR: mode, longueur du nom, nom
      uint8_t mode = c[1], n = c[2];
      char name[16];
      if (n < 1 || n > 12) { replyStatus(FSE_BADNAME); break; }
      for (uint8_t i = 0; i < n; i++) name[i] = (char)c[3 + i];
      name[n] = 0;
      if (!nameOk(name)) { replyStatus(FSE_BADNAME); break; }
      fsCloseAll();                        // un seul fichier ouvert: OUVRIR ferme le precedent
      oflag_t fl = (mode == 0) ? O_RDONLY : (mode == 1) ? (O_WRONLY | O_CREAT | O_TRUNC)
                                                         : (O_WRONLY | O_CREAT | O_APPEND);
      curFile = fatfs.open(name, fl);
      if (!curFile) { replyStatus(mode == 0 ? FSE_NOTFOUND : FSE_IO); break; }
      fileOpen = true; curMode = mode;
      replyStatus(FSE_OK);
      break;
    }
    case 0x13: {                           // LIRE n octets
      uint8_t n = c[1] > 32 ? 32 : c[1];
      uint8_t buf[32];
      if (!fileOpen || curMode != 0) { replyByte(0xFF); break; }
      int r = curFile.read(buf, n);
      if (r < 0) { replyByte(0xFF); break; }
      replyByte((uint8_t)r);
      for (int i = 0; i < r; i++) replyByte(buf[i]);
      break;
    }
    case 0x14: {                           // ECRIRE n octets
      uint8_t n = c[1];
      if (!fileOpen || curMode == 0) { replyStatus(FSE_NOTOPEN); break; }
      replyStatus(curFile.write(c + 2, n) == n ? FSE_OK : FSE_FULL);
      break;
    }
    case 0x15:                             // FERMER
      if (!fileOpen) { replyStatus(FSE_NOTOPEN); break; }
      curFile.close(); fileOpen = false;
      flash.syncBlocks();                  // vide le cache d'ecriture vers la flash
      replyStatus(FSE_OK);
      break;
    case 0x16:                             // REPERTOIRE: debut
      if (dirOpen) dirRoot.close();
      dirOpen = dirRoot.open("/");
      replyStatus(dirOpen ? FSE_OK : FSE_IO);
      break;
    case 0x17: {                           // entree suivante
      if (!dirOpen) { replyByte(0xFF); break; }
      File32 f;
      while (f.openNext(&dirRoot, O_RDONLY)) {
        if (f.isDir() || f.isHidden()) { f.close(); continue; }
        char name[16];
        f.getName(name, sizeof name);
        uint32_t sz = f.fileSize();
        f.close();
        uint8_t len = (uint8_t)strlen(name);
        replyByte(len);
        for (uint8_t i = 0; i < len; i++) replyByte((uint8_t)name[i]);
        for (int i = 0; i < 4; i++) replyByte((uint8_t)(sz >> (8 * i)));
        return;
      }
      replyByte(0);                        // plus d'entree
      break;
    }
    case 0x18: {                           // SUPPRIMER
      uint8_t n = c[1];
      char name[16];
      if (n < 1 || n > 12) { replyStatus(FSE_BADNAME); break; }
      for (uint8_t i = 0; i < n; i++) name[i] = (char)c[2 + i];
      name[n] = 0;
      if (!nameOk(name)) { replyStatus(FSE_BADNAME); break; }
      if (fileOpen) { curFile.close(); fileOpen = false; }
      bool ok = fatfs.remove(name);
      flash.syncBlocks();
      replyStatus(ok ? FSE_OK : FSE_NOTFOUND);
      break;
    }
    case 0x19: {                           // ESPACE LIBRE (octets)
      uint64_t free = (uint64_t)fatfs.freeClusterCount() * fatfs.bytesPerCluster();
      if (free > 0xFFFFFFFFULL) free = 0xFFFFFFFFULL;
      for (int i = 0; i < 4; i++) replyByte((uint8_t)(free >> (8 * i)));
      break;
    }
    default: break;
  }
}

// Acces direct aux secteurs de 512 octets (commandes 20h-24h), pour un futur DOS: passe par un
// tampon de 512 octets (secBuf), transfere par blocs de 32 octets. Ferme le fichier ouvert; apres
// une ecriture le volume FAT est remonte a la prochaine commande fichier (fsStale).
static uint8_t secBuf[512];
static uint32_t secLba(const uint8_t *c) {
  return (uint32_t)c[0] | ((uint32_t)c[1] << 8) | ((uint32_t)c[2] << 16) | ((uint32_t)c[3] << 24);
}
static void secExec(const uint8_t *c) {
  uint8_t op = c[0];
  uint32_t nsec = flashOk ? (uint32_t)(flash.size() / 512) : 0;
  if (op == 0x20) { for (int i = 0; i < 4; i++) replyByte((uint8_t)(nsec >> (8 * i))); return; }
  if (op == 0x22) {                        // OBTENIR le bloc i du tampon
    uint8_t i = c[1];
    for (int k = 0; k < 32; k++) replyByte(i < 16 ? secBuf[i * 32 + k] : 0);
    return;
  }
  if (!flashOk) { replyStatus(FSE_NOTREADY); return; }
  if (op == 0x23) {                        // DEPOSER le bloc i dans le tampon
    uint8_t i = c[1];
    if (i > 15) { replyStatus(FSE_IO); return; }
    memcpy(secBuf + i * 32, c + 2, 32);
    replyStatus(FSE_OK);
    return;
  }
  uint32_t lba = secLba(c + 1);            // 21h LIRE / 24h ECRIRE
  if (lba >= nsec) { replyStatus(FSE_IO); return; }
  fsCloseAll();
  if (op == 0x24) imgClose();              // ecriture directe: l'image montee ne serait plus coherente
  flash.syncBlocks();
  if (op == 0x21) {
    replyStatus(flash.readBlocks(lba, secBuf, 1) ? FSE_OK : FSE_IO);
  } else {
    bool ok = flash.writeBlocks(lba, secBuf, 1);
    flash.syncBlocks();
    fsStale = true;
    replyStatus(ok ? FSE_OK : FSE_IO);
  }
}

// 2Bh SOMME: somme (16 bits) des 512 octets de secBuf, envoyee apres un secteur lu (21h / 29h). Le 8088 la compare a
// celle des octets qu'il a recus et relit le secteur si elles different (octets perdus ou alteres en route).
static void secSum() {
  uint16_t sum = 0;
  for (int i = 0; i < 512; i++) sum += secBuf[i];
  replyByte((uint8_t)sum);
  replyByte((uint8_t)(sum >> 8));
}

// Image de disquette (commandes 27h-2Ah): un fichier de la racine (.IMG, le plus souvent) sert de DISQUETTE
// au 8088 (lecteur A: d'un DOS). 27h MONTER (nom) -> etat + taille (4 octets); 28h DEMONTER; 29h LIRE le
// secteur lba (dans secBuf, a relire par 22h); 2Ah ECRIRE le secteur lba (depuis secBuf, deposer par 23h).
// Les ecritures vont dans le fichier (synchronisees a chaque secteur). Un seul fichier monte a la fois.
static bool imgNameOk(const char *n, int len) {
  for (int i = 0; i < len; i++) {
    char c = n[i];
    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
          c == '$' || c == '~' || c == '.'))
      return false;
  }
  return len > 0;
}
static void imgExec(const uint8_t *c) {
  uint8_t op = c[0];
  if (op == 0x28) { imgClose(); replyStatus(FSE_OK); return; }
  if (op == 0x27) {
    imgClose();
    uint8_t st = FSE_OK;
    uint32_t sz = 0;
    uint8_t n = c[1];
    char name[16];
    if (fsStale) { fsStale = false; fsCloseAll(); fsOk = flashOk && fatfs.begin(&flash); }
    if (!fsOk) {
      st = FSE_NOTREADY;
    } else if (n < 1 || n > 12) {
      st = FSE_BADNAME;
    } else {
      for (uint8_t i = 0; i < n; i++) name[i] = (char)c[2 + i];
      name[n] = 0;
      if (!imgNameOk(name, n)) {
        st = FSE_BADNAME;
      } else {
        imgFile = fatfs.open(name, O_RDWR);
        if (!imgFile) { st = FSE_NOTFOUND; }
        else { imgOpen = true; imgSize = imgFile.fileSize(); sz = imgSize; }
      }
    }
    replyStatus(st);
    for (int i = 0; i < 4; i++) replyByte((uint8_t)(sz >> (8 * i)));
    return;
  }
  if (!imgOpen) { replyStatus(FSE_NOTOPEN); return; }
  uint32_t lba = secLba(c + 1);
  if (((uint64_t)lba + 1) * 512ULL > imgSize || !imgFile.seekSet(lba * 512UL)) { replyStatus(FSE_IO); return; }
  if (op == 0x29) {
    replyStatus(imgFile.read(secBuf, 512) == 512 ? FSE_OK : FSE_IO);
  } else {
    bool ok = imgFile.write(secBuf, 512) == 512 && imgFile.sync();
    flash.syncBlocks();
    replyStatus(ok ? FSE_OK : FSE_IO);
  }
}

// Lecteur de masse USB (environnement blackpill_f411ce_usbdrive): la flash entiere (MBR + volume FAT)
// est offerte au PC. Un seul proprietaire a la fois: USB ON (25h) donne le disque au PC, le 8088
// recoit alors "disque non pret"; USB OFF (26h) le reprend (le PC doit avoir ejecte le lecteur).
#ifdef USE_TINYUSB
static Adafruit_USBD_MSC usbMsc;
static int32_t mscRead(uint32_t lba, void *buf, uint32_t size) {
  return flash.readBlocks(lba, (uint8_t *)buf, size / 512) ? (int32_t)size : -1;
}
static int32_t mscWrite(uint32_t lba, uint8_t *buf, uint32_t size) {
  return flash.writeBlocks(lba, buf, size / 512) ? (int32_t)size : -1;
}
static void mscFlush() { flash.syncBlocks(); }
static void usbMscBegin() {              // avant UsbSerial.begin()
  usbMsc.setID("VE2CUY", "8088 Disk", "1.0");
  usbMsc.setReadWriteCallback(mscRead, mscWrite, mscFlush);
  usbMsc.setCapacity(flashOk ? (uint32_t)(flash.size() / 512) : 0, 512);
  usbMsc.setUnitReady(false);            // "pas de disque" tant que USB ON n'est pas demande
  usbMsc.begin();
}
#endif

static void usbExec(uint8_t op) {
#ifdef USE_TINYUSB
  if (!flashOk) { replyStatus(FSE_NOTREADY); return; }
  if (op == 0x25) {
    if (!usbActive) { fsCloseAll(); imgClose(); flash.syncBlocks(); usbActive = true; usbMsc.setUnitReady(true); }
  } else if (usbActive) {
    usbMsc.setUnitReady(false);
    flash.syncBlocks();
    usbActive = false;
    fsStale = true;                      // le PC a pu modifier le volume: le remonter
  }
  replyStatus(FSE_OK);
#else
  (void)op;
  replyStatus(FSE_NOSUPPORT);
#endif
}

// USB ON: toute commande disque du 8088 recoit "disque non pret" (reponse de la bonne taille)
static void diskBusy(uint8_t op) {
  if (op == 0x13 || op == 0x17) replyByte(0xFF);
  else if (op == 0x19) { for (int i = 0; i < 4; i++) replyByte(0xFF); }
  else if (op == 0x20) { for (int i = 0; i < 4; i++) replyByte(0); }
  else if (op == 0x22) { for (int i = 0; i < 32; i++) replyByte(0); }
  else if (op == 0x27) { replyStatus(FSE_NOTREADY); for (int i = 0; i < 4; i++) replyByte(0); }
  else if (op == 0x2B) { replyByte(0); replyByte(0); }
  else replyStatus(FSE_NOTREADY);
}

// Automate des commandes du canal 3: un octet d'operation, puis ses arguments.
static uint32_t uartHoldUntil = 0;         // pas d'octet UART avant cette date (ms): LINE_DELAY_MS, CMD_HOLD_MS
static uint8_t cmdBuf[264], cmdLen = 0;
static uint32_t cmdT = 0;
static int cmdNeed() {                     // nombre total d'octets de la commande en cours
  switch (cmdBuf[0]) {
    case 0x02: return 8;
    case 0x13: return 2;
    case 0x21: case 0x24: case 0x29: case 0x2A: return 5;
    case 0x27: return cmdLen >= 2 ? 2 + cmdBuf[1] : 2;
    case 0x22: return 2;
    case 0x23: return 34;
    case 0x2C: return 2;
    case 0x12: return cmdLen >= 3 ? 3 + cmdBuf[2] : 3;
    case 0x14: return cmdLen >= 2 ? 2 + cmdBuf[1] : 2;
    case 0x18: return cmdLen >= 2 ? 2 + cmdBuf[1] : 2;
    default:   return 1;                   // 00h 01h 10h 11h 15h 16h 17h 19h 20h et inconnues
  }
}
static void cmdByte(uint8_t v) {
  uint32_t now = millis();
  if (cmdLen && (uint32_t)(now - cmdT) > CMD_TIMEOUT_MS) cmdLen = 0;   // commande abandonnee
  cmdT = now;
  cmdBuf[cmdLen++] = v;
  if (cmdLen < cmdNeed()) return;
  uint8_t op = cmdBuf[0];
#if DEBUG_FS
  static bool first = true;
  if (first) {
    first = false;
    UsbSerial.print("\r\n[fs] flash JEDEC=0x"); UsbSerial.print(flashOk ? flash.getJEDECID() : 0, HEX);
    UsbSerial.print(" taille="); UsbSerial.print(flashOk ? flash.size() : 0);
    UsbSerial.print(" flashOk="); UsbSerial.print(flashOk);
    UsbSerial.print(" fsOk="); UsbSerial.print(fsOk); UsbSerial.print("\r\n");
  }
  UsbSerial.print("[br] op=0x"); UsbSerial.print(op, HEX); UsbSerial.print(" n="); UsbSerial.print(cmdLen); UsbSerial.print("\r\n");
#endif
  if (op == 0x00) { replyByte(0xB1); replyByte(3); replyByte(USB_CAPS); }        // PING: v3, RTC + disque + secteurs
  else if (op == 0x01) replyTime();
  else if (op == 0x02) applyTime(cmdBuf + 1);
  else if (op == 0x25 || op == 0x26) usbExec(op);
  else if (usbActive && op >= 0x10 && op <= 0x2B) diskBusy(op);
  else if (op >= 0x10 && op <= 0x19) fsExec(cmdBuf);
  else if (op >= 0x20 && op <= 0x24) secExec(cmdBuf);
  else if (op >= 0x27 && op <= 0x2A) imgExec(cmdBuf);
  else if (op == 0x2B) secSum();
  else if (op == 0x2C) clockExec(cmdBuf[1]);
  uartHoldUntil = millis() + CMD_HOLD_MS;  // le 8088 est occupe avec sa commande: pas de collage pour l'instant
  cmdLen = 0;
}

// ============================================================================
// LCD HD44780 derriere un PCF8574 (P0=RS P1=RW P2=EN P3=BL P4-P7=D4-D7)
// ============================================================================
const uint8_t LCD_RS = 0x01, LCD_EN = 0x04, LCD_BL = 0x08;

static void lcdNibble(uint8_t n) {         // n = quartet deja aligne sur D4-D7
  Wire.beginTransmission(LCD_ADDR);
  Wire.write((uint8_t)(n | LCD_BL | LCD_EN));
  Wire.write((uint8_t)(n | LCD_BL));
  Wire.endTransmission();
}

static void lcdSend(uint8_t v, uint8_t rs) {
  uint8_t hi = (uint8_t)((v & 0xF0) | LCD_BL | rs);
  uint8_t lo = (uint8_t)(((uint8_t)(v << 4) & 0xF0) | LCD_BL | rs);
  Wire.beginTransmission(LCD_ADDR);        // une seule transaction: 4 octets
  Wire.write((uint8_t)(hi | LCD_EN));
  Wire.write(hi);
  Wire.write((uint8_t)(lo | LCD_EN));
  Wire.write(lo);
  Wire.endTransmission();
  if (!rs && v <= 0x03) delayMicroseconds(2000);   // Clear / Home: >= 1,52 ms
  else                  delayMicroseconds(50);     // autres: >= 37-43 us
}

// Initialisation "par instruction" du HD44780: ramene le controleur en mode
// 4 bits depuis N'IMPORTE QUEL etat (8 bits, quartet a moitie envoye...).
static void lcdResync() {
  lcdNibble(0x30); delay(5);
  lcdNibble(0x30); delayMicroseconds(200);
  lcdNibble(0x30); delayMicroseconds(200);
  lcdNibble(0x20); delayMicroseconds(200); // bascule en 4 bits
}

static void lcdInit() {
  delay(50);                               // >= 40 ms apres mise sous tension
  lcdResync();
  lcdSend(0x28, 0);                        // 4 bits, 2 lignes, 5x8
  lcdSend(0x0C, 0);                        // affichage on, curseur off
  lcdSend(0x06, 0);                        // entry mode: incremente
  lcdSend(0x01, 0);                        // clear
}

// ============================================================================
// Trace PS/2 (DEBUG_PS2=1): evenements ecrits dans un petit anneau, affiches
// par loop() sur le terminal, ENTRELACES avec la sortie du 8088:
//   {76}  octet decode et valide      {>76} octet envoye au 8088
//   {P76} erreur de parite            {S76} erreur de stop
//   {G}   start invalide (parasite)   {Rn}  resync avec n bits recus
//   {O}   anneau PS/2 plein (octet perdu)   {g} parasite CLK filtre
// ============================================================================
#if DEBUG_PS2
static volatile uint16_t dbgBuf[64];
static volatile uint8_t  dbgHead = 0, dbgTail = 0;
static inline void dbg(uint16_t v) {       // appelable depuis l'ISR
  uint8_t nh = (uint8_t)((dbgHead + 1) & 63);
  if (nh != dbgTail) { dbgBuf[dbgHead] = v; dbgHead = nh; }
}
static void dbgSent(uint8_t v) {           // appelable depuis loop()
  noInterrupts(); dbg(0x600 | v); interrupts();
}
static void dbgFlush() {
  while (dbgHead != dbgTail && UsbSerial.availableForWrite() >= 8) {
    uint16_t v = dbgBuf[dbgTail];
    dbgTail = (uint8_t)((dbgTail + 1) & 63);
    uint8_t k = (uint8_t)(v >> 8), b = (uint8_t)v;
    UsbSerial.print('{');
    switch (k) {
      case 0: break;
      case 1: UsbSerial.print('P'); break;
      case 2: UsbSerial.print('S'); break;
      case 3: UsbSerial.print('G'); break;
      case 4: UsbSerial.print('O'); break;
      case 5: UsbSerial.print('R'); UsbSerial.print(b); UsbSerial.print('}'); continue;
      case 6: UsbSerial.print('>'); break;
      case 7: UsbSerial.print('g'); UsbSerial.print('}'); continue;
    }
    if (k != 3 && k != 4) { if (b < 16) UsbSerial.print('0'); UsbSerial.print(b, HEX); }
    UsbSerial.print('}');
  }
}
#else
#define dbg(v)     ((void)0)
#define dbgSent(v) ((void)0)
#define dbgFlush() ((void)0)
#endif

// ============================================================================
// Clavier PS/2 (Set 2): 11 bits = start(0) + 8 donnees LSB + parite impaire
// + stop(1), echantillonnes sur chaque front descendant de CLK.
// ============================================================================
static volatile uint8_t  ps2Buf[32];
static volatile uint8_t  ps2Head = 0, ps2Tail = 0;
static volatile uint8_t  ps2Bit = 0, ps2Shift = 0, ps2Par = 0, ps2ParOk = 0;
static volatile uint32_t ps2Last = 0;   // dernier front VALIDE de CLK
static volatile uint32_t ps2Act  = 0;   // dernier front CLK, valide ou non (silence)

static inline bool ps2ClkHigh()  { return (GPIOA->IDR >> PS2_CLK_BIT) & 1; }
static inline bool ps2DataHigh() { return (GPIOA->IDR >> PS2_DATA_BIT) & 1; }

static void ps2Isr() {
  uint32_t now = micros();
  ps2Act = now;
  delayMicroseconds(PS2_GLITCH_US);
  if (ps2ClkHigh()) { dbg(0x700); return; }   // CLK repassee haute: parasite

  // DATA: vote majoritaire sur 3 lectures (encore stable a ce stade du cycle)
  uint8_t votes = 0;
  if (ps2DataHigh()) votes++;
  delayMicroseconds(2);
  if (ps2DataHigh()) votes++;
  delayMicroseconds(2);
  if (ps2DataHigh()) votes++;
  uint8_t b = (votes >= 2) ? 1 : 0;

  if ((uint32_t)(now - ps2Last) > PS2_FRAME_GAP_US) {   // nouvelle trame
    if (ps2Bit != 0) dbg(0x500 | ps2Bit);
    ps2Bit = 0;
  }
  ps2Last = now;

  if (ps2Bit == 0) {                       // bit de start: doit etre 0
    if (b) { dbg(0x300); return; }
    ps2Shift = 0; ps2Par = 0; ps2Bit = 1;
  } else if (ps2Bit <= 8) {                // 8 bits de donnees, LSB d'abord
    if (b) { ps2Shift |= (uint8_t)(1 << (ps2Bit - 1)); ps2Par ^= 1; }
    ps2Bit++;
  } else if (ps2Bit == 9) {                // parite impaire: donnees+parite = impair
    ps2ParOk = (b ^ ps2Par) & 1;
    ps2Bit++;
  } else {                                 // bit de stop: doit etre 1
    if (b && ps2ParOk) {
      uint8_t nh = (uint8_t)((ps2Head + 1) & 31);
      if (nh != ps2Tail) { ps2Buf[ps2Head] = ps2Shift; ps2Head = nh; dbg(ps2Shift); }
      else dbg(0x400);
    } else if (!ps2ParOk) dbg(0x100 | ps2Shift);
    else dbg(0x200 | ps2Shift);
    ps2Bit = 0;
  }
}

// Vrai si aucun front CLK n'a ete vu depuis au moins `us` microsecondes.
static bool ps2Quiet(uint32_t us) {
  noInterrupts();
  uint32_t last = ps2Act;
  interrupts();
  return (uint32_t)(micros() - last) >= us;
}

static bool ps2Pop(uint8_t &v) {
  if (ps2Head == ps2Tail) return false;
  v = ps2Buf[ps2Tail];
  ps2Tail = (uint8_t)((ps2Tail + 1) & 31);
  return true;
}

// ============================================================================
// Initialisation des broches
// ============================================================================
static void pullUp(GPIO_TypeDef *port, uint8_t bit) {   // PUPDR = 01
  port->PUPDR = (port->PUPDR & ~(3UL << (bit * 2))) | (1UL << (bit * 2));
}

static void initPins() {
  // ACK#/STB#: DRAIN OUVERT. Le niveau haut est fourni par les 10 kohm vers +5 V
  // (vrai niveau 5 V pour le 8255, et lignes tenues hautes pendant un reset du
  // STM32). Pull-up interne en secours (3,3 V, suffisant pour l'entree TTL du 8255).
  pinMode(PIN_ACK, OUTPUT_OPEN_DRAIN);  ackHigh();  pullUp(GPIOB, ACK_BIT);
  pinMode(PIN_STB, OUTPUT_OPEN_DRAIN);  stbHigh();  pullUp(GPIOB, STB_BIT);
  pinMode(PIN_TAG, OUTPUT);   digitalWrite(PIN_TAG, LOW);
  pinMode(PIN_TAG1, OUTPUT);  digitalWrite(PIN_TAG1, LOW);   // PC1 (inutilise pour l'instant)
  pinMode(PIN_OBF, INPUT_PULLUP);          // 8255 absent/hors tension = "rien"
  pinMode(PIN_CH0, INPUT);
  pinMode(PIN_CH1, INPUT);
  pinMode(PIN_IBF, INPUT_PULLDOWN);        // non cable = "libre"

  // Bus (PB6-PB9, PB12-PB15): entrees, sans pull, sorties push-pull rapides.
  // (L'horloge de GPIOB est deja activee par les pinMode() ci-dessus.)
  GPIOB->PUPDR   &= ~BUS_MODER_MASK;
  GPIOB->OTYPER  &= ~BUS_ODR_MASK;
  GPIOB->OSPEEDR |= 0xAA0AA000UL;          // 10 = grande vitesse
  busRelease();
}

// ============================================================================
void setup() {
  clockSetup();                            // EN PREMIER: le 8088 a besoin d'une horloge des la mise
                                            // sous tension - avant tout ce qui suit (SPI/USB/RTC, lent)
#ifdef USE_TINYUSB
  fsMount();                               // la flash d'abord: le lecteur de masse en a besoin
  // Ce coeur n'appelle pas TinyUSB_Device_Init(): sans begin(0) le port USB ne demarre jamais
  // (aucun peripherique visible du PC). begin() efface la configuration (CDC ajoute par lui-meme),
  // donc le lecteur de masse s'ajoute APRES; si le PC a deja enumere, on se re-enumere.
  if (!TinyUSBDevice.isInitialized()) TinyUSBDevice.begin(0);
  usbMscBegin();
  UsbSerial.begin(115200);
  if (TinyUSBDevice.mounted()) {
    TinyUSBDevice.detach();
    delay(10);
    TinyUSBDevice.attach();
  }
#else
  UsbSerial.begin(115200);                 // USB natif: le debit est ignore (pas de DTR-reset)
#endif

#if RTC_USE_LSE
  rtc.setClockSource(STM32RTC::LSE_CLOCK);
#endif
  rtc.begin();                             // conserve l'heure si la RTC tournait deja (pile VBAT)

#ifndef USE_TINYUSB
  fsMount();                               // flash SPI + systeme de fichiers FAT (formate si neuve)
#endif
  // UsbSerial.println("\n8088_bridge_stm32: " __DATE__ " " __TIME__);
  initPins();

#if HEARTBEAT
  pinMode(PC13, OUTPUT);
  digitalWrite(PC13, HIGH);                // LED eteinte (active a l'etat bas)
#endif


  Wire.setSDA(PIN_SDA);
  Wire.setSCL(PIN_SCL);
  Wire.begin();
  Wire.setClock(100000);
  lcdInit();

  pinMode(PIN_PS2_CLK, INPUT_PULLUP);      // + pull-ups externes 4,7-10 kohm vers +5 V conseilles
  pinMode(PIN_PS2_DATA, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_PS2_CLK), ps2Isr, FALLING);
}

// Vrai si le 8088 peut recevoir un octet du pont
static uint32_t lastTx = 0;                // date du dernier octet envoye (USE_IBF=0)
static bool canSend() {
#if USE_IBF
  if ((GPIOA->IDR >> IBF_BIT) & 1) return false;   // IBF = 1: le 8088 n'a pas encore lu l'octet precedent
#endif
  return (uint32_t)(micros() - lastTx) >= GAP_US;
}
static inline void markSent() { lastTx = micros(); }

void loop() {
#ifdef USE_TINYUSB
  yield();                                 // tud_task(): traite les evenements USB (CDC, lecteur de masse)
#endif
  dbgFlush();

#if HEARTBEAT
  { static uint32_t t = 0;
    if (millis() - t >= 500) { t = millis(); digitalToggle(PC13); } }
#endif

  // 1. 8088 -> file
  if (!qFull() && ps2Quiet(BUS_QUIET_US)) {
    uint8_t chan, val;
    if (takeFrom8088(chan, val)) {
      q[qHead].chan = chan; q[qHead].val = val;
      qHead++;
    }
  }

  // 2. file -> UART (USB) ou LCD (un element par tour)
  if (!qEmpty()) {
    Item &it = q[qTail];
    if (it.chan == CH_UART) {
      static uint32_t stallSince = 0;
      if (UsbSerial.availableForWrite() > 0) {
        UsbSerial.write(it.val); qTail++; stallSince = 0;
      } else if (stallSince == 0) {
        stallSince = millis() | 1;
      } else if (millis() - stallSince > TX_STALL_MS) {
        qTail++; stallSince = 0;           // personne ne lit le port USB: octet jete
      }
    } else {
      if (it.chan == CH_LCD_CMD) {
        if (it.val == 0x28) lcdResync();   // Function Set = debut de i2c_lcd_init
                                           // (8088): resynchronise un LCD deregle
        lcdSend(it.val, 0);
      }
      else if (it.chan == CH_LCD_DATA) lcdSend(it.val, LCD_RS);
      else if (it.chan == CH_CMD) cmdByte(it.val);
      qTail++;                             // canal inconnu: octet jete
    }
  }

  // 3. reponses / clavier / UART recu -> 8088
  uint8_t v;
#if DEBUG_FS
  { // diagnostic: une reponse en attente depuis plus de 100 ms = bloquee (IBF? PS/2?)
    static uint32_t since = 0; static bool said = false;
    if (rqHead == rqTail) { since = 0; said = false; }
    else if (since == 0) since = millis() | 1;
    else if (!said && millis() - since > 100) {
      said = true;
      UsbSerial.print("[rq] bloquee: IBF="); UsbSerial.print((GPIOA->IDR >> IBF_BIT) & 1);
      UsbSerial.print(" ps2Quiet="); UsbSerial.print(ps2Quiet(BUS_QUIET_US));
      UsbSerial.print(" n="); UsbSerial.print((uint8_t)((rqHead - rqTail) & 63)); UsbSerial.print("\r\n");
    }
  }
#endif
#if USE_IBF
  // Reponse a une commande: IBF seul suffit (voir REPLY_GAP_US)
  if (rqHead != rqTail && !((GPIOA->IDR >> IBF_BIT) & 1) && (uint32_t)(micros() - lastTx) >= REPLY_GAP_US &&
      ps2Quiet(BUS_QUIET_US)) {
    v = rq[rqTail];
    rqTail = (uint8_t)((rqTail + 1) & 63);
    sendTo8088(2, v);
    markSent();
  } else
#endif
  if (canSend()) {                         // IBF libre (si cable) et GAP_US ecoule
    if (rqHead != rqTail && ps2Quiet(BUS_QUIET_US)) {           // reponse a une commande (sans IBF)
      v = rq[rqTail];
      rqTail = (uint8_t)((rqTail + 1) & 63);
      sendTo8088(2, v);
#if DEBUG_FS
      UsbSerial.print("[tx] "); UsbSerial.print(v, HEX); UsbSerial.print(" ibf="); UsbSerial.print(dbgIbfAfter); UsbSerial.print("\r\n");
#endif
      markSent();
    } else if (ps2Head != ps2Tail && ps2Quiet(KBD_QUIET_US)) {
      ps2Pop(v);
      sendTo8088(0, v);
      dbgSent(v);
      markSent();
    } else if (UsbSerial.available() > 0 && ps2Quiet(BUS_QUIET_US) &&
               (int32_t)(millis() - uartHoldUntil) >= 0) {
      uint8_t c = (uint8_t)UsbSerial.read();
      sendTo8088(1, c);
      markSent();
      if (c == 13) uartHoldUntil = millis() + LINE_DELAY_MS;   // le 8088 traite la ligne
    }
  }
}
