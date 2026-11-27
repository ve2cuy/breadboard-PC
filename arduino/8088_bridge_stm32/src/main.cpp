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
//     00h PING (reponse B1h, 3, capacites)   01h LIRE l'heure (reponse: 8 octets)
//     02h + 7 octets REGLER l'heure (annee 2 octets, mois, jour, h, min, s).
//     03h VERSION du firmware (PAS le "3" de PING ci-dessus, qui est le numero
//     de VERSION DU PROTOCOLE - sans rapport) -> 2 octets (majeure, mineure).
//     Necessite TAG1 (PB5) relie a PC1 du 8255 (tire a 0 par 10 kohm).
//     10h-19h = DISQUE: fichiers FAT (racine, noms 8.3) sur la flash SPI (W25Q64, 8 Mo) de la carte
//     (PA4 = CS, SPI1 PA5/PA6/PA7): statut, formater, ouvrir, lire, ecrire, fermer,
//     repertoire (debut / suivant), supprimer, espace libre. Voir lib/bridge.asm.
//     2Ch + 1 octet (action) = HORLOGE du 8088 (PA3, PWM materiel, voir clockExec ci-dessous):
//     0 lire, 1 +0,1 MHz, 2 -0,1 MHz, 3 +1 MHz, 4 -1 MHz, 5 -> 4,77 MHz, 6 -> 8 MHz
//     -> reponse 4 octets = Hz resultant.
//     Horloge de 1 Hz a 10 MHz (pont 2.0) par raccourcis traites ICI, sans le 8088 (a 1 Hz il
//     n'executerait plus son menu): Ctrl+Alt+PgUp / PgDn au clavier PS/2, Ctrl-] puis + / - au
//     terminal = valeur suivante / precedente de la suite 1-2-5 (1, 2, 5, 10 Hz ... 1, 2, 5,
//     10 MHz); Ctrl+Alt+Debut / Ctrl-] 0 = 4,77 MHz; Ctrl+Alt+Fin / Ctrl-] 1 = 1 Hz; Ctrl-] ? =
//     afficher. La frequence obtenue est ecrite au terminal ("[Pont] Horloge 8088: ...").
//     2Eh = LIRE les reglages du BIOS (pont 2.2) -> 16 octets; 2Fh + 16 octets = les ECRIRE (gardes dans
//     la flash interne du STM32, voir cfgSave) -> etat (0 = ok, 4 = erreur d'ecriture). Voir "REGLAGES".
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
//   PB2 -> RESET du 8088 (broche 21, actif HAUT; 4,7 kohm (R1) vers la masse sur le montage, bouton vers +5 V):
//   poussee HAUT pour un reset (demarrage du pont, Ctrl-Alt-Suppr au PS/2, Ctrl-\ au terminal), sinon
//   ENTREE (ne gene pas le bouton, jamais forcee BAS). PB2 = BOOT1: au repos la ligne est BASSE (4,7 kohm),
//   le mode DFU (BOOT0 = 1, BOOT1 = 0) reste donc utilisable.   PA0 = bouton K1 de la carte
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
#define BURST_WAIT_US 500UL   // rafale des reponses: attente maximale de la lecture d'un octet par le 8088
// Pause apres chaque retour chariot (CR) venant du PC: le 8088 traite la ligne saisie
// (tokenisation, insertion dans le programme) avant de recevoir la suivante. 0 = aucune.
#define LINE_DELAY_MS 15UL
// Apres une commande du 8088 au pont (disque, horloge...), le 8088 est occupe: ses instructions
// (OPEN, PRINT#, WRITE#, CLOSE...) durent des dizaines de ms et il ne vide pas son tampon de
// reception (256 octets). On suspend l'envoi des octets UART (collage) jusqu'a ce delai apres la
// derniere commande, sinon un collage de plusieurs lignes deborde ce tampon.
#define CMD_HOLD_MS   250UL
#define TX_STALL_MS 100UL    // port USB sans lecteur: on jette l'octet apres ce delai
#define HEARTBEAT   0        // 1 = LED (PC13, active a l'etat bas) clignote a 1 Hz (si DISK_LED 0)
// Pont 2.0: LED de la carte (PC13) = acces au disque, comme le temoin d'un PC: allumee pendant les
// lectures et ecritures de A: (image de disquette, 29h/2Ah), de C: (secteurs, 21h-24h), des fichiers
// du BASIC (11h-19h) et du lecteur USB, puis DISK_LED_MS de plus (visible meme pour un seul secteur).
#define DISK_LED    1
#define DISK_LED_MS 40UL
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
// Version du FIRMWARE du pont (PAS le numero de version du protocole - "3" -
// deja renvoye par PING, sans rapport) - interrogee par le 8088 (commande 03h,
// "4) Information" du sous-menu Configuration, Solution-01/solution-01.asm) et
// affichee telle quelle a l'utilisateur. A incrementer manuellement lors de
// changements notables a ce fichier.
#define FW_VERSION_MAJOR 2
#define FW_VERSION_MINOR 2
#define FW_XSTR(x) #x
#define FW_STR(x)  FW_XSTR(x)                // FW_STR(FW_VERSION_MINOR) -> "9"
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
// reponse 4 octets = la frequence REELLEMENT GENEREE en Hz (poids faible d'abord,
// meme convention que fs_free/fs_dir_next - voir Solution-01/lib/bridge.asm) -
// PAS la frequence demandee (voir actualClockHz ci-dessous, et Directives.md: rapporte
// sur le materiel reel, mesure a l'oscilloscope - un ecart pouvant depasser 4% a ete
// observe entre la frequence demandee et la frequence reellement generee, l'arrondi
// du prescaler/de l'ARR du minuteur devenant significatif loin de 4,77 MHz - PLUS le
// double arrondi entier de HardwareTimer::setOverflow(), voir
// framework-arduinoststm32/.../HardwareTimer.cpp):
//   0 = ne rien changer (sert de LIRE), 1 = +0,1 MHz, 2 = -0,1 MHz, 3 = +1 MHz,
//   4 = -1 MHz, 5 = aller a 4,77 MHz, 6 = aller a 8 MHz, 7 = 7,2 MHz (1.4),
//   8 = 2,35 MHz (1.7).
// ============================================================================
#define CLOCK_MIN_HZ           1UL                 // pont 2.0 (etait 1 MHz): raccourcis du clavier et du terminal
#define CLOCK_MENU_MIN_HZ 1000000UL                 // plancher des actions 1-4 (menu Clock speed du 8088)
#define CLOCK_MAX_HZ    10000000UL
#define CLOCK_DEFAULT_HZ 4770000UL
#define CLOCK_STEP_SMALL  100000UL                 // 0,1 MHz
#define CLOCK_STEP_BIG   1000000UL                 // 1 MHz
static HardwareTimer clockTimer(TIM2);
static uint32_t clockHz = CLOCK_DEFAULT_HZ;        // frequence DEMANDEE (ce que le 8088 a
                                                    // demande pour la derniere fois)
static uint32_t actualClockHz = CLOCK_DEFAULT_HZ;  // frequence REELLEMENT generee, lue
                                                    // dans les registres ARR/PSC du minuteur
                                                    // APRES setPWM() (getOverflow(HERTZ_FORMAT)
                                                    // relit LL_TIM_GetAutoReload/GetPrescaler -
                                                    // les MEMES valeurs que setOverflow() vient
                                                    // d'ecrire, donc reflete fidelement ce que
                                                    // le materiel produit vraiment) - c'est
                                                    // CETTE valeur qui est renvoyee au 8088,
                                                    // PAS clockHz

static void clockApply() {                         // (re)configure le PWM sur la frequence courante
  clockTimer.setPWM(4, PIN_CLK8088, clockHz, 33);
  actualClockHz = clockTimer.getOverflow(HERTZ_FORMAT);
}

// clockSetup: PREMIERE chose faite dans setup() - demarre l'horloge du 8088 a 4,77 MHz
// avant tout le reste (SPI/USB/RTC peuvent prendre plusieurs dizaines de ms).
static void clockSetup() {
  clockApply();
}

// clockStep125: valeur suivante (up) ou precedente de la suite 1-2-5 (1, 2, 5, 10 Hz ... 5, 10 MHz)
// a partir de f, bornee a [CLOCK_MIN_HZ, CLOCK_MAX_HZ]. 4,77 MHz -> 5 MHz ou 2 MHz.
static uint32_t clockStep125(uint32_t f, bool up) {
  static const uint8_t m[3] = { 1, 2, 5 };
  uint32_t best = up ? CLOCK_MAX_HZ : CLOCK_MIN_HZ;
  for (uint32_t d = 1; d <= CLOCK_MAX_HZ; d *= 10)
    for (uint8_t i = 0; i < 3; i++) {
      uint32_t v = d * m[i];
      if (v > CLOCK_MAX_HZ) break;
      if (up && v > f && v < best) best = v;
      if (!up && v < f && v > best) best = v;
    }
  return best;
}

// clockChange: applique l'action (codes de la commande 2Ch, plus 9 = suivante et 10 = precedente de
// la suite 1-2-5, 11 = 1 Hz). Les actions 1-4 (menu Clock speed du 8088) restent bornees a
// [CLOCK_MENU_MIN_HZ, CLOCK_MAX_HZ], comme avant le pont 2.0.
static void clockChange(uint8_t action) {
  uint32_t f = clockHz;
  switch (action) {
    case 1: f = clockHz + CLOCK_STEP_SMALL; break;   // +0,1 MHz
    case 2: f = (clockHz > CLOCK_STEP_SMALL) ? clockHz - CLOCK_STEP_SMALL : 0; break;   // -0,1 MHz
    case 3: f = clockHz + CLOCK_STEP_BIG; break;     // +1 MHz
    case 4: f = (clockHz > CLOCK_STEP_BIG) ? clockHz - CLOCK_STEP_BIG : 0; break;       // -1 MHz
    case 5: f = CLOCK_DEFAULT_HZ; break;              // 4,77 MHz
    case 6: f = 8000000UL; break;                     // 8 MHz
    case 7: f = 7200000UL; break;                     // 7,2 MHz demandes (le diviseur entier du timer donne la valeur la plus proche)
    case 8: f = 2340000UL; break;                     // "2,35 MHz" (1.7): 96 MHz / 41 = 2,341 MHz, le plus proche (2 350 000 donnerait 96/40 = 2,40: division tronquee)
    case 9: f = clockStep125(clockHz, true); break;   // suite 1-2-5 (pont 2.0)
    case 10: f = clockStep125(clockHz, false); break;
    case 11: f = CLOCK_MIN_HZ; break;                 // 1 Hz
    default: return;                                  // 0 (ou inconnu) = lire seulement
  }
  if (action <= 4) {
    if (f < CLOCK_MENU_MIN_HZ) f = CLOCK_MENU_MIN_HZ;
  } else if (f < CLOCK_MIN_HZ) f = CLOCK_MIN_HZ;
  if (f > CLOCK_MAX_HZ) f = CLOCK_MAX_HZ;
  clockHz = f;
  // Le minuteur precharge ARR et PSC (TIM_AUTORELOAD_PRELOAD_ENABLE de HardwareTimer): la nouvelle
  // frequence part a la fin de la periode en cours (au plus 1 s a 1 Hz), sans impulsion tronquee.
  clockApply();
}

static void clockExec(uint8_t action) {
  if (action >= 1 && action <= 11) clockChange(action);
  // actualClockHz (REELLEMENT genere), PAS clockHz (seulement DEMANDE) - voir la
  // remarque en tete de section
  replyByte((uint8_t)actualClockHz); replyByte((uint8_t)(actualClockHz >> 8));
  replyByte((uint8_t)(actualClockHz >> 16)); replyByte((uint8_t)(actualClockHz >> 24));
}

// Raccourcis de l'horloge (pont 2.0): demandes du clavier PS/2 (kbdTrack, dans l'interruption) et du
// terminal (Ctrl-]), executees par loop(). clockReport ecrit la frequence obtenue au terminal.
static volatile uint8_t clockRequest = 0;  // code d'action de clockChange, 0 = rien
static void clockReport() {
  char t[48];
  unsigned long f = actualClockHz;
  if (f >= 1000000UL)
    snprintf(t, sizeof(t), "\r\n[Pont] Horloge 8088: %lu.%03lu MHz\r\n", f / 1000000UL, (f / 1000UL) % 1000UL);
  else if (f >= 1000UL)
    snprintf(t, sizeof(t), "\r\n[Pont] Horloge 8088: %lu.%03lu kHz\r\n", f / 1000UL, f % 1000UL);
  else
    snprintf(t, sizeof(t), "\r\n[Pont] Horloge 8088: %lu Hz\r\n", f);
  UsbSerial.print(t);
}

// ============================================================================
// REGLAGES DU BIOS (pont 2.2): 16 octets gardes dans la flash INTERNE du STM32 - le F411 n'a pas
// d'EEPROM: le secteur 7 (0x08060000, 128 Ko, que le programme n'atteint pas) en tient lieu. Chaque
// enregistrement (32 octets: magique "CFG1", les 16 octets, controle, 8 octets a FFh) s'ajoute apres le
// dernier; le secteur n'est efface (~1 s, le processeur attend) que plein, soit tous les ~4000
// enregistrements. Le magique s'ecrit en DERNIER: un enregistrement interrompu n'est jamais pris.
// Octets: 0 version (1); 1 drapeaux (CFG_F_NO_*: 0 = tout actif); 2 demarrage (0 menu, 1 GW-BASIC, 2 DOS 2.1 de la ROM,
// 3 disque C:); 3 duree de l'ecran d'accueil (1-5 s, 5 par defaut); 4-7 horloge du 8088 au demarrage du pont (Hz);
// 8-15 reserves (0). Le pont applique lui-meme l'horloge (setup) et le temoin du disque; le reste est
// lu par le 8088 (commande 2Eh, Solution-01/lib/setup.asm).
// ============================================================================
#define CFG_ADDR        0x08060000UL
#define CFG_SECTOR      7
#define CFG_BYTES       0x20000UL
#define CFG_REC         32
#define CFG_MAGIC       0x31474643UL       // "CFG1"
#define CFG_F_NO_LCD_BASIC 0x01            // PAS de console au LCD dans le BASIC (drapeaux a 0 = defauts,
#define CFG_F_NO_LCD_DOS   0x02            //   comme une RAM effacee du cote du 8088)
#define CFG_F_NO_RAMB      0x04            // pas de disque B: en RAM (DOS de la ROM)
#define CFG_F_NO_DISKLED   0x08            // pas de temoin d'acces au disque (LED PC13)
static uint8_t cfg[16];

static uint32_t cfgHz() { uint32_t f; memcpy(&f, cfg + 4, 4); return f; }
static void cfgDefaults() {
  memset(cfg, 0, sizeof(cfg));
  cfg[0] = 1;
  cfg[3] = 5;                              // ecran d'accueil: 5 s ("Appuyer sur ESC pour lancer le BIOS")
  uint32_t f = CLOCK_DEFAULT_HZ;
  memcpy(cfg + 4, &f, 4);
}
static void cfgCheck() {                   // valeur hors bornes: celle par defaut
  if (cfg[0] != 1) { cfgDefaults(); return; }
  if (cfg[2] > 3) cfg[2] = 0;
  if (cfg[3] < 1 || cfg[3] > 5) cfg[3] = 5;
  uint32_t f = cfgHz();
  if (f < CLOCK_MENU_MIN_HZ || f > CLOCK_MAX_HZ) { f = CLOCK_DEFAULT_HZ; memcpy(cfg + 4, &f, 4); }
  memset(cfg + 8, 0, 8);
}
static uint32_t cfgSum(const uint32_t *d) { return 0xA5A5A5A5UL ^ d[0] ^ d[1] ^ d[2] ^ d[3]; }
static void cfgLoad() {                    // le dernier enregistrement valide du secteur, sinon les defauts
  cfgDefaults();
  for (uint32_t a = CFG_ADDR; a < CFG_ADDR + CFG_BYTES; a += CFG_REC) {
    const volatile uint32_t *r = (const volatile uint32_t *)a;
    if (r[0] != CFG_MAGIC) continue;
    uint32_t d[4] = { r[1], r[2], r[3], r[4] };
    if (r[5] == cfgSum(d)) memcpy(cfg, d, 16);
  }
  cfgCheck();
}
static bool cfgBlank(uint32_t a) {
  const volatile uint32_t *r = (const volatile uint32_t *)a;
  for (int i = 0; i < CFG_REC / 4; i++) if (r[i] != 0xFFFFFFFFUL) return false;
  return true;
}
static bool cfgSave() {
  cfgCheck();
  uint32_t a = CFG_ADDR;                   // apres le dernier emplacement utilise
  for (uint32_t p = CFG_ADDR; p < CFG_ADDR + CFG_BYTES; p += CFG_REC)
    if (!cfgBlank(p)) a = p + CFG_REC;
  uint32_t d[4];
  memcpy(d, cfg, 16);
  bool ok = true;
  HAL_FLASH_Unlock();
  __HAL_FLASH_CLEAR_FLAG(FLASH_FLAG_EOP | FLASH_FLAG_OPERR | FLASH_FLAG_WRPERR | FLASH_FLAG_PGAERR |
                         FLASH_FLAG_PGPERR | FLASH_FLAG_PGSERR);
  if (a + CFG_REC > CFG_ADDR + CFG_BYTES) {          // plein: on efface le secteur
    FLASH_EraseInitTypeDef e = {};
    uint32_t bad = 0;
    e.TypeErase = FLASH_TYPEERASE_SECTORS;
    e.Sector = CFG_SECTOR;
    e.NbSectors = 1;
    e.VoltageRange = FLASH_VOLTAGE_RANGE_3;
    ok = HAL_FLASHEx_Erase(&e, &bad) == HAL_OK;
    a = CFG_ADDR;
  }
  for (int i = 0; ok && i < 4; i++)
    ok = HAL_FLASH_Program(FLASH_TYPEPROGRAM_WORD, a + 4 + 4 * i, d[i]) == HAL_OK;
  if (ok) ok = HAL_FLASH_Program(FLASH_TYPEPROGRAM_WORD, a + 20, cfgSum(d)) == HAL_OK;
  if (ok) ok = HAL_FLASH_Program(FLASH_TYPEPROGRAM_WORD, a, CFG_MAGIC) == HAL_OK;
  HAL_FLASH_Lock();
  __HAL_FLASH_DATA_CACHE_DISABLE();         // le cache de donnees de la flash garde les anciennes valeurs
  __HAL_FLASH_DATA_CACHE_RESET();
  __HAL_FLASH_DATA_CACHE_ENABLE();
  const volatile uint32_t *r = (const volatile uint32_t *)a;
  return ok && r[0] == CFG_MAGIC && r[1] == d[0] && r[2] == d[1] && r[3] == d[2] && r[4] == d[3];
}
static void cfgExec(uint8_t op, const uint8_t *in) {   // in = les 16 octets de 2Fh
  if (op == 0x2E) {
    for (int i = 0; i < 16; i++) replyByte(cfg[i]);
  } else {
    memcpy(cfg, in, 16);
    replyByte(cfgSave() ? 0 : 4);
  }
}

// Temoin d'acces au disque (DISK_LED): diskLed() a chaque acces, diskLedPoll() l'eteint ensuite.
static volatile uint32_t diskLedUntil = 0;
static volatile bool diskLedLit = false;
static inline void diskLed() {
#if DISK_LED
  if (cfg[1] & CFG_F_NO_DISKLED) return;  // pont 2.2: temoin coupe dans les reglages du BIOS
  GPIOC->BSRR = (1UL << (13 + 16));       // PC13 a 0: LED allumee
  diskLedLit = true;
  diskLedUntil = millis() + DISK_LED_MS;
#endif
}
static inline void diskLedPoll() {
#if DISK_LED
  if (diskLedLit && (int32_t)(millis() - diskLedUntil) >= 0) {
    GPIOC->BSRR = (1UL << 13);            // PC13 a 1: LED eteinte
    diskLedLit = false;
  }
#endif
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
static bool imgReadOnly = false;          // image en lecture seule (attribut R du fichier): ecritures refusees
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

// Secteur de demarrage du disque C: pour DOS (pont 2.0). SdFat 2.3 (FatFormatter::initPbs) ecrit
// un nom OEM de 8 ESPACES: DOS 6 y cherche une version ("MSDOS5.0", "IBM  3.3"...), juge sans elle
// le secteur de demarrage invalide et calcule sa propre disposition du volume (vu sur le materiel,
// INT 21h AH=32h: grappes de 8 secteurs, FAT12 de 6 secteurs, racine au secteur 13 au lieu de 65):
// DIR C: lisait la FAT comme repertoire. Les mesures sur le materiel (2026-11-26) l'ont montre:
// nom OEM "MSDOS5.0" = DIR C: correct. fsFixBoot, apres FORMAT et a chaque montage (en place, sans
// toucher aux fichiers): nom OEM "MSDOS5.0" s'il est vide; nombre total de secteurs dans le champ
// 16 bits s'il tient (comme FORMAT de DOS; SdFat le met dans le champ 32 bits); geometrie
// 255 tetes x 63 secteurs, celle du BIOS du 8088 (INT 13h AH=08h), dans le BPB (SdFat 2.3 y laisse
// 0) et le MBR (SdFat l'ecrit en 2 x 32). Rien sans MBR (secteur 0 = secteur de demarrage,
// "superfloppy" d'un formatage par Windows: DOS ne peut pas s'en servir comme disque dur).
static void chs255x63(uint8_t *chs, uint32_t lba) {
  uint32_t c = lba / (255UL * 63UL), r = lba % (255UL * 63UL);
  uint8_t h = (uint8_t)(r / 63), s = (uint8_t)(r % 63 + 1);
  if (c > 1023) { c = 1023; h = 254; s = 63; }
  chs[0] = h;
  chs[1] = (uint8_t)(((c >> 2) & 0xC0) | s);
  chs[2] = (uint8_t)c;
}
static uint32_t le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void fsFixBoot() {
  static uint8_t sec[512];
  if (!flashOk || !flash.readBlocks(0, sec, 1)) return;
  if (sec[510] != 0x55 || sec[511] != 0xAA) return;
  if ((sec[0] == 0xEB || sec[0] == 0xE9) && sec[11] == 0x00 && sec[12] == 0x02) return;  // superfloppy
  uint8_t *p = sec + 446;                  // premiere entree de la table des partitions
  uint8_t t = p[4];
  uint32_t start = le32(p + 8), n = le32(p + 12);
  if ((p[0] != 0x00 && p[0] != 0x80) || !(t == 0x01 || t == 0x04 || t == 0x06 || t == 0x0B ||
      t == 0x0C || t == 0x0E) || start == 0 || n == 0 || start + n > flash.size() / 512) return;
  uint8_t b[3], e[3];
  chs255x63(b, start);
  chs255x63(e, start + n - 1);
  if (memcmp(p + 1, b, 3) != 0 || memcmp(p + 5, e, 3) != 0) {
    memcpy(p + 1, b, 3);
    memcpy(p + 5, e, 3);
    flash.writeBlocks(0, sec, 1);
  }
  if (flash.readBlocks(start, sec, 1) && sec[510] == 0x55 && sec[511] == 0xAA &&
      sec[11] == 0x00 && sec[12] == 0x02) {
    bool w = false;
    if (memcmp(sec + 3, "        ", 8) == 0) { memcpy(sec + 3, "MSDOS5.0", 8); w = true; }   // nom OEM
    uint32_t t32 = le32(sec + 32);
    if (sec[19] == 0 && sec[20] == 0 && t32 > 0 && t32 < 65536) {       // total: champ 16 bits (13h)
      sec[19] = (uint8_t)t32; sec[20] = (uint8_t)(t32 >> 8);
      memset(sec + 32, 0, 4);
      w = true;
    }
    if (sec[24] != 63 || sec[25] != 0 || sec[26] != 255 || sec[27] != 0) {
      sec[24] = 63; sec[25] = 0;           // secteurs par piste (BPB, 18h)
      sec[26] = 255; sec[27] = 0;          // tetes (BPB, 1Ah)
      w = true;
    }
    if (w) flash.writeBlocks(start, sec, 1);
  }
  flash.syncBlocks();
}

// Formate la flash en FAT16 (DETRUIT tout). Vrai si le volume est ensuite monte.
static bool fsFormat() {
  static uint8_t secBuf[512];
  fsCloseAll();
  imgClose();
  FatFormatter formatter;
  bool ok = formatter.format(&flash, secBuf, nullptr);
  flash.syncBlocks();
  if (ok) fsFixBoot();                     // secteur de demarrage lisible par DOS (nom OEM...)
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

// Puce de flash (pont 2.0). Adafruit SPIFlash ne connait qu'une courte liste de puces (W25Qxx de
// Winbond, GD25Q, S25FL...); les Black Pill recents portent souvent une autre marque (Puya P25Q,
// XTX XT25F, Zbit ZB25VQ, Boya BY25Q...): flash.begin() echouait alors et tout le disque repondait
// "pas pret", meme apres un formatage. Puce inconnue: identifiant JEDEC lu ici (commande 9Fh) et,
// si la capacite est plausible (64 Ko a 16 Mo), description generique en SPI simple (lecture rapide
// 0Bh, programmation 02h, effacement 20h: communs a toutes ces puces). Les bits de protection des
// blocs (BP, registre d'etat 1) sont remis a 0 s'ils sont poses (sinon les ecritures echouent).
static uint8_t flashJedec[3] = { 0, 0, 0 };
static bool flashGeneric = false;          // puce hors de la liste de la bibliotheque
static SPIFlash_Device_t flashGenericDev;

static void flashUnprotect() {
  uint8_t st = 0;
  flashTransport.readCommand(0x05, &st, 1);          // registre d'etat 1
  if ((st & 0x3C) == 0) return;                      // BP0-BP3: aucune protection
  uint8_t zero = 0;
  flashTransport.runCommand(0x06);                   // ecriture permise
  flashTransport.writeCommand(0x01, &zero, 1);       // BP = 0
  for (uint32_t t0 = millis(); millis() - t0 < 100; ) {
    flashTransport.readCommand(0x05, &st, 1);
    if (!(st & 0x01)) break;                         // fin d'ecriture
  }
}

static void fsMount() {
  flashTransport.begin();
  flashTransport.readCommand(0x9F, flashJedec, 3);
  flashOk = flash.begin();
  if (!flashOk && flashJedec[0] != 0x00 && flashJedec[0] != 0xFF &&
      flashJedec[2] >= 0x10 && flashJedec[2] <= 0x18) {
    memset(&flashGenericDev, 0, sizeof(flashGenericDev));
    flashGenericDev.total_size = 1UL << flashJedec[2];
    flashGenericDev.start_up_time_us = 5000;
    flashGenericDev.manufacturer_id = flashJedec[0];
    flashGenericDev.memory_type = flashJedec[1];
    flashGenericDev.capacity = flashJedec[2];
    flashGenericDev.max_clock_speed_mhz = 33;        // prudent: SPI simple
    flashGenericDev.supports_fast_read = true;
    flashGenericDev.single_status_byte = true;       // pas de 35h (registre 2) suppose
    flashOk = flash.begin(&flashGenericDev, 1);
    flashGeneric = flashOk;
  }
  if (flashOk) flashUnprotect();
  fsFixBoot();                             // disque formate par SdFat 2.3: repare en place pour DOS
  fsOk = flashOk && fatfs.begin(&flash);
  if (flashOk && !fsOk && flashLooksBlank()) fsFormat();
}

// Etat de la flash en texte (LCD au demarrage, Ctrl-] ? au terminal): "Flash EF4017 8 Mo",
// "Flash 856017 8 Mo*" (* = description generique), "Flash ? 000000" (puce absente ou muette).
static void flashText(char *t, size_t n) {
  if (flashOk)
    snprintf(t, n, "Flash %02X%02X%02X %lu %s%s", flashJedec[0], flashJedec[1], flashJedec[2],
             (unsigned long)(flash.size() >= 1048576UL ? flash.size() >> 20 : flash.size() >> 10),
             flash.size() >= 1048576UL ? "Mo" : "Ko", flashGeneric ? "*" : "");
  else
    snprintf(t, n, "Flash ? %02X%02X%02X", flashJedec[0], flashJedec[1], flashJedec[2]);
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
        // Nom LONG s'il tient en 8.3 (12 caracteres: "hello.asm" garde sa casse), sinon le nom
        // COURT (ex. "pcdos2_1_bug.img" -> "PCDOS2~1.IMG", que le 8088 peut ouvrir tel quel).
        // Avant: getName() dans un tampon de 16 octets ECHOUAIT pour un nom long de 16+
        // caracteres -> longueur 0 = "plus d'entree" pour le 8088: la liste s'arretait LA et
        // tous les fichiers suivants disparaissaient (FILES, List files, Boot disk image).
        char name[64];
        size_t n = f.getName(name, sizeof name);
        if (n == 0 || n > 12) n = f.getSFN(name, 13);
        uint32_t sz = f.fileSize();
        f.close();
        if (n == 0 || n > 12) continue;    // aucun nom utilisable: entree sautee, pas fin de liste
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
        imgReadOnly = false;
        if (!imgFile) {                    // fichier en lecture seule (attribut R): l'ouvrir quand meme, en lecture
          imgFile = fatfs.open(name, O_RDONLY);
          imgReadOnly = (bool)imgFile;
        }
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
    if (imgReadOnly) { replyStatus(FSE_IO); return; }   // image en lecture seule: ecriture refusee
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
  diskLed();
  return flash.readBlocks(lba, (uint8_t *)buf, size / 512) ? (int32_t)size : -1;
}
static int32_t mscWrite(uint32_t lba, uint8_t *buf, uint32_t size) {
  diskLed();
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

static void conStart();                    // console au LCD (commande 2Dh, pont 2.1), plus bas

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
    case 0x2F: return 17;                  // reglages du BIOS (pont 2.2)
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
  if (!usbActive && ((op >= 0x11 && op <= 0x19) || (op >= 0x21 && op <= 0x24) || op == 0x29 || op == 0x2A))
    diskLed();                             // temoin d'acces: A: (29h/2Ah), C: (21h-24h), fichiers (11h-19h)
  if (op == 0x00) { replyByte(0xB1); replyByte(3); replyByte(USB_CAPS); }        // PING: v3, RTC + disque + secteurs
  else if (op == 0x01) replyTime();
  else if (op == 0x02) applyTime(cmdBuf + 1);
  else if (op == 0x03) { replyByte(FW_VERSION_MAJOR); replyByte(FW_VERSION_MINOR); }  // version du firmware
  else if (op == 0x25 || op == 0x26) usbExec(op);
  else if (usbActive && op >= 0x10 && op <= 0x2B) diskBusy(op);
  else if (op >= 0x10 && op <= 0x19) fsExec(cmdBuf);
  else if (op >= 0x20 && op <= 0x24) secExec(cmdBuf);
  else if (op >= 0x27 && op <= 0x2A) imgExec(cmdBuf);
  else if (op == 0x2B) secSum();
  else if (op == 0x2C) clockExec(cmdBuf[1]);
  else if (op == 0x2D) { conStart(); cmdLen = 0; return; }   // console au LCD: sans reponse ni collage
  else if (op == 0x2E || op == 0x2F) cfgExec(op, cmdBuf + 1);   // reglages du BIOS (pont 2.2)
  // Le 8088 est occupe avec sa commande: pas de collage pour l'instant - SEULEMENT pour les commandes
  // longues (disque, fichiers, USB: op >= 10h, sauf 2Ch). Les commandes courtes (ping, heure, version,
  // horloge) n'en ont pas besoin: l'ecran Information lit l'heure toutes les ~170 ms a 7,38 MHz (moins
  // de CMD_HOLD_MS) - le terminal etait alors muet en permanence (Echap sans effet, PS/2 normal).
  if (op >= 0x10 && op != 0x2C && op != 0x2E) uartHoldUntil = millis() + CMD_HOLD_MS;
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

// Ecrit s a partir de la DDRAM addr (00h = ligne 1, 40h = ligne 2)
static void lcdPrintAt(uint8_t addr, const char *s) {
  lcdSend((uint8_t)(0x80 | addr), 0);      // Set DDRAM Address
  while (*s) lcdSend((uint8_t)*s++, LCD_RS);
}

// Message de demarrage du pont: visible tant que le 8088 n'a rien affiche (sans 8088, il reste;
// avec le 8088, i2c_lcd_init du BIOS l'efface). Lignes 1-2 et 16 caracteres au plus: lisible sur
// un 16x2 comme sur un 20x4 (le HD44780 ne permet pas de savoir lequel est branche).
// ~16 ms a 100 kHz, avant la liberation du RESET du 8088.
static void lcdBanner() {
  lcdPrintAt(0x00, "Pont STM32 v" FW_STR(FW_VERSION_MAJOR) "." FW_STR(FW_VERSION_MINOR));
  lcdPrintAt(0x40, "En attente 8088");
  char t[24];                              // ligne 3 du 20x4 (adresse 14h: hors de l'ecran d'un 16x2)
  flashText(t, sizeof(t));
  lcdPrintAt(0x14, t);
  if (!fsOk) lcdPrintAt(0x54, flashOk ? "Disque non formate" : "Disque absent");
}

// ============================================================================
// CONSOLE AU LCD (pont 2.1, commande 2Dh). Le pont tient en permanence l'ecran 80x25 du terminal: chaque
// octet que le 8088 envoie a l'UART passe par conPut (caracteres, CR, LF, BS, TAB, sequences ESC [ ... du
// BIOS: position, effacements; UTF-8 de la page 437 -> caracteres du LCD). Apres 2Dh (le BIOS l'envoie a
// l'amorcage d'un DOS et a la liste des images), le LCD montre une fenetre de 20x4 de cet ecran, comme
// Solution-02: elle suit le curseur a la verticale; a l'arret de l'affichage (CON_IDLE_MS), elle se place
// par pas de 10 colonnes pour montrer le curseur (gauche = (colonne/10 - 1) x 10). Maj + fleches au
// clavier PS/2 la deplacent (haut/bas: 1 ligne, gauche/droite: 10 colonnes) et ne vont pas au 8088; elle
// reste ou on l'a mise jusqu'au prochain affichage. Curseur souligne du LCD a la position du curseur.
// Dessin par difference (seules les cases changees sont ecrites), quelques cases par tour de boucle,
// presque rien tant que le 8088 affiche (le debit de l'UART n'est pas ralenti): le LCD rattrape a l'arret.
// Fin: premier octet LCD du 8088 (menu) ou RESET du 8088.
// ============================================================================
#define CON_W 80
#define CON_H 25
#define CON_IDLE_MS    150UL               // sans affichage depuis: suivi horizontal, dessin a pleine vitesse
#define CON_BUSY_MS     50UL               // pendant l'affichage: un peu de dessin toutes les CON_BUSY_MS
static uint8_t conScr[CON_H][CON_W];       // caracteres DEJA traduits pour le LCD (ROM A00 + CGRAM)
static uint8_t conR = 0, conC = 0, conSaveR = 0, conSaveC = 0;
static bool conWrap = false;               // 80e colonne ecrite: retour a la ligne au caractere suivant
static uint8_t conEsc = 0;                 // 0 texte, 1 ESC recu, 2 dans ESC [
static uint8_t conPar[4], conNPar = 0;
static uint8_t conU8n = 0;                 // octets UTF-8 de continuation attendus
static uint16_t conU8 = 0;
static volatile bool lcdCon = false;       // le LCD montre la console (lu par l'ISR du clavier)
static uint8_t conVR = 0, conVC = 0;       // coin haut gauche de la fenetre
static bool conOut = false, conFollowH = false;
static uint32_t conLastOut = 0, conRenderT = 0;
static uint16_t lcdShadow[4][20];          // ce que montre le LCD (100h = inconnu)
static uint8_t lcdAddr = 0xFF;             // compteur d'adresse DDRAM du LCD (FFh = inconnu)
static bool lcdCursor = false;
static volatile uint8_t navQ[8];
static volatile uint8_t navHead = 0, navTail = 0;

// CGRAM 0-7: e aigu, e grave, e circonflexe, a grave, barre oblique inverse (5Ch = yen dans la ROM A00),
// c cedille, u grave, o circonflexe (les memes que Solution-02).
static const uint8_t conGlyphs[64] = {
  0x02,0x04,0x0E,0x11,0x1F,0x10,0x0E,0x00,  0x08,0x04,0x0E,0x11,0x1F,0x10,0x0E,0x00,
  0x04,0x0A,0x0E,0x11,0x1F,0x10,0x0E,0x00,  0x08,0x04,0x0E,0x01,0x0F,0x11,0x0F,0x00,
  0x00,0x10,0x08,0x04,0x02,0x01,0x00,0x00,  0x00,0x0E,0x10,0x10,0x11,0x0E,0x04,0x0C,
  0x08,0x04,0x11,0x11,0x11,0x13,0x0D,0x00,  0x04,0x0A,0x0E,0x11,0x11,0x11,0x0E,0x00 };

// Point de code Unicode -> caractere du LCD
static uint8_t conMap(uint16_t u) {
  if (u >= 0x20 && u < 0x7F) return u == '\\' ? 4 : (uint8_t)u;
  switch (u) {
    case 0xE9: return 0;  case 0xE8: return 1;  case 0xEA: return 2;  case 0xE0: return 3;
    case 0xE7: return 5;  case 0xF9: return 6;  case 0xF4: return 7;
    case 0xA0: return ' '; case 0xB0: return 0xDF; case 0xB5: case 0x3BC: return 0xE4;
    case 0xB7: case 0x2219: return 0xA5; case 0xB1: return '+'; case 0xF7: return 0xFD;
    case 0xDF: case 0x3B2: return 0xE2; case 0x3B1: return 0xE0; case 0x3B5: return 0xE3;
    case 0x3C0: return 0xF7; case 0x3A3: return 0xF6; case 0x3C3: return 0xE5; case 0x3A9: return 0xF4;
    case 0x398: return 0xF2; case 0x221A: return 0xE8; case 0x221E: return 0xF3;
    case 0x2265: return '>'; case 0x2264: return '<'; case 0x2248: return '~'; case 0xAB: return '<';
    case 0xBB: return '>'; case 0xA2: return 'c'; case 0xA3: return 'L'; case 0xA5: return 'Y';
  }
  if (u >= 0xC0 && u <= 0xFF) {            // lettres accentuees: sans accent
    static const char base[] = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYPsaaaaaaaceeeeiiiidnooooo/ouuuuypy";
    return (uint8_t)base[u - 0xC0];
  }
  if (u >= 0x2500 && u <= 0x257F) {        // cadres
    if (u == 0x2550) return '=';
    if (u == 0x2551) return '|';
    if (u <= 0x250B) return (u & 2) ? '|' : '-';
    if (u >= 0x254C && u <= 0x254F) return (u & 2) ? '|' : '-';
    return '+';
  }
  if ((u >= 0x2580 && u <= 0x259F) || u == 0x25A0) return 0xFF;   // blocs
  return '?';
}

static void conClear(uint8_t r0, uint8_t c0, uint8_t r1, uint8_t c1) {   // de (r0,c0) a (r1,c1) inclus
  for (uint8_t r = r0; r <= r1; r++)
    for (uint8_t c = (r == r0 ? c0 : 0); c <= (r == r1 ? c1 : CON_W - 1); c++) conScr[r][c] = ' ';
}
static void conLF() {
  if (conR < CON_H - 1) { conR++; return; }
  memmove(conScr[0], conScr[1], (CON_H - 1) * CON_W);
  memset(conScr[CON_H - 1], ' ', CON_W);
}
static void conChar(uint8_t v) {
  if (conWrap) { conWrap = false; conC = 0; conLF(); }
  conScr[conR][conC] = v;
  if (conC == CON_W - 1) conWrap = true; else conC++;
}
static void conCsi(uint8_t f) {
  uint8_t a = conNPar ? conPar[0] : 0, b = conNPar > 1 ? conPar[1] : 0, n = a ? a : 1;
  conWrap = false;
  switch (f) {
    case 'H': case 'f':
      conR = (uint8_t)((a ? a - 1 : 0) < CON_H ? (a ? a - 1 : 0) : CON_H - 1);
      conC = (uint8_t)((b ? b - 1 : 0) < CON_W ? (b ? b - 1 : 0) : CON_W - 1);
      break;
    case 'J':
      if (a == 2 || a == 3) conClear(0, 0, CON_H - 1, CON_W - 1);
      else if (a == 1) conClear(0, 0, conR, conC);
      else conClear(conR, conC, CON_H - 1, CON_W - 1);
      break;
    case 'K':
      if (a == 2) conClear(conR, 0, conR, CON_W - 1);
      else if (a == 1) conClear(conR, 0, conR, conC);
      else conClear(conR, conC, conR, CON_W - 1);
      break;
    case 'A': conR = conR >= n ? conR - n : 0; break;
    case 'B': conR = conR + n < CON_H ? conR + n : CON_H - 1; break;
    case 'C': conC = conC + n < CON_W ? conC + n : CON_W - 1; break;
    case 'D': conC = conC >= n ? conC - n : 0; break;
    case 's': conSaveR = conR; conSaveC = conC; break;
    case 'u': conR = conSaveR; conC = conSaveC; break;
  }
}
// Un octet du 8088 vers le terminal
static void conPut(uint8_t v) {
  conOut = true;
  if (conEsc == 1) {
    if (v == '[') { conEsc = 2; conNPar = 0; conPar[0] = 0; return; }
    conEsc = 0;
    if (v == '7') { conSaveR = conR; conSaveC = conC; }
    else if (v == '8') { conR = conSaveR; conC = conSaveC; conWrap = false; }
    return;
  }
  if (conEsc == 2) {
    if (v >= '0' && v <= '9') {
      if (!conNPar) conNPar = 1;
      uint16_t x = (uint16_t)(conPar[conNPar - 1] * 10 + (v - '0'));
      conPar[conNPar - 1] = (uint8_t)(x > 255 ? 255 : x);
    } else if (v == ';') {
      if (!conNPar) conNPar = 1;
      if (conNPar < 4) conPar[conNPar++] = 0;
    } else if (v >= 0x40 && v <= 0x7E) { conEsc = 0; conCsi(v); }
    else if (v < 0x20 || v > 0x3F) conEsc = 0;       // ('?' et autres octets de parametre: ignores)
    return;
  }
  if (conU8n) {
    if ((v & 0xC0) == 0x80) {
      conU8 = (uint16_t)((conU8 << 6) | (v & 0x3F));
      if (--conU8n == 0) conChar(conMap(conU8));
      return;
    }
    conU8n = 0;
    conChar('?');
  }
  if (v >= 0x20 && v < 0x7F) { conChar(conMap(v)); return; }
  switch (v) {
    case 0x1B: conEsc = 1; return;
    case 0x0D: conC = 0; conWrap = false; return;
    case 0x0A: conWrap = false; conLF(); return;
    case 0x08: if (conWrap) conWrap = false; else if (conC) conC--; return;
    case 0x09: conWrap = false; conC = (uint8_t)((conC | 7) + 1 < CON_W ? (conC | 7) + 1 : CON_W - 1); return;
  }
  if (v >= 0xC2 && v <= 0xDF) { conU8n = 1; conU8 = v & 0x1F; return; }
  if (v >= 0xE0 && v <= 0xEF) { conU8n = 2; conU8 = v & 0x0F; return; }
  if (v >= 0x80) conChar('?');             // (autres octets de commande: ignores)
}

static inline uint8_t conCurCol() { return conWrap ? CON_W - 1 : conC; }

// Commande 2Dh: le LCD passe a la console (CGRAM chargee, fenetre sur le curseur, tout redessine)
static void conStart() {
  lcdCon = true;
  lcdSend(0x0C, 0);                        // curseur cache le temps du dessin
  lcdCursor = false;
  lcdSend(0x40, 0);                        // CGRAM 0
  for (uint8_t i = 0; i < 64; i++) lcdSend(conGlyphs[i], LCD_RS);
  lcdAddr = 0xFF;
  for (uint8_t r = 0; r < 4; r++) for (uint8_t c = 0; c < 20; c++) lcdShadow[r][c] = 0x100;
  conVR = conR > 3 ? conR - 3 : 0;
  int vc = (conCurCol() / 10 - 1) * 10;
  conVC = (uint8_t)(vc < 0 ? 0 : vc > CON_W - 20 ? CON_W - 20 : vc);
  conOut = false; conFollowH = false;
  conLastOut = millis();
}

// Deplacements demandes par Maj + fleches (ISR du clavier) -> fenetre
static void conNav() {
  while (navHead != navTail) {
    uint8_t d = navQ[navTail];
    navTail = (uint8_t)((navTail + 1) & 7);
    if (d == 1 && conVR > 0) conVR--;
    else if (d == 2 && conVR < CON_H - 4) conVR++;
    else if (d == 3) conVC = conVC >= 10 ? conVC - 10 : 0;
    else if (d == 4) conVC = conVC + 10 <= CON_W - 20 ? conVC + 10 : CON_W - 20;
    conFollowH = false;                    // la fenetre reste ou on l'a mise jusqu'au prochain affichage
  }
}

// Un tour de dessin: au plus `budget` cases changees, puis le curseur
static void conRender(uint8_t budget) {
  for (uint8_t r = 0; r < 4; r++) {
    for (uint8_t c = 0; c < 20; c++) {
      uint8_t v = conScr[conVR + r][conVC + c];
      if (lcdShadow[r][c] == v) continue;
      if (!budget) return;
      budget--;
      if (lcdCursor) { lcdSend(0x0C, 0); lcdCursor = false; }
      uint8_t a = (uint8_t)((r & 1 ? 0x40 : 0x00) + (r & 2 ? 0x14 : 0x00) + c);
      if (lcdAddr != a) lcdSend((uint8_t)(0x80 | a), 0);
      lcdSend(v, LCD_RS);
      lcdShadow[r][c] = v;
      lcdAddr = (uint8_t)(a + 1);
    }
  }
  uint8_t cc = conCurCol();
  bool vis = conR >= conVR && conR < conVR + 4 && cc >= conVC && cc < conVC + 20;
  if (vis) {
    uint8_t r = conR - conVR;
    uint8_t a = (uint8_t)((r & 1 ? 0x40 : 0x00) + (r & 2 ? 0x14 : 0x00) + (cc - conVC));
    if (lcdAddr != a) { lcdSend((uint8_t)(0x80 | a), 0); lcdAddr = a; }
    if (!lcdCursor) { lcdSend(0x0E, 0); lcdCursor = true; }
  } else if (lcdCursor) { lcdSend(0x0C, 0); lcdCursor = false; }
}

// Appelee a chaque tour de loop()
static void conPoll() {
  if (!lcdCon) { navHead = navTail; return; }
  uint32_t now = millis();
  if (conOut) {                            // affichage depuis le dernier tour: la fenetre suit le curseur
    conOut = false;
    conLastOut = now;
    conFollowH = true;
    if (conR < conVR) conVR = conR;
    else if (conR > conVR + 3) conVR = conR - 3;
  }
  conNav();
  bool idle = (uint32_t)(now - conLastOut) >= CON_IDLE_MS;
  if (idle && conFollowH) {
    conFollowH = false;
    int vc = (conCurCol() / 10 - 1) * 10;
    conVC = (uint8_t)(vc < 0 ? 0 : vc > CON_W - 20 ? CON_W - 20 : vc);
  }
  if (idle) conRender(6);
  else if ((uint32_t)(now - conRenderT) >= CON_BUSY_MS) { conRenderT = now; conRender(2); }
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

static void kbdTrack(uint8_t sc);          // Ctrl-Alt-Suppr (voir RESET du 8088, plus bas)

static inline void ps2Push(uint8_t v) {    // octet pour le 8088 (dans l'ISR)
  uint8_t nh = (uint8_t)((ps2Head + 1) & 31);
  if (nh != ps2Tail) { ps2Buf[ps2Head] = v; ps2Head = nh; dbg(v); }
  else dbg(0x400);
}

// Console au LCD (pont 2.1): Maj (12h, 59h; pas les Maj factices E0 12h / E0 59h que le clavier envoie autour
// des fleches) + fleche (75h haut, 72h bas, 6Bh gauche, 74h droite, avec ou sans E0: pave numerique) = navigation
// de la fenetre, retiree du flux du 8088 avec ses prefixes. Pendant la console, un prefixe E0/F0 attend donc
// l'octet suivant avant de partir (quelques ms). Hors console: tout part tel quel.
static volatile uint8_t navPfx[2], navPfxN = 0;
static volatile uint8_t navMods = 0;       // bit 0: F0 recu, bit 1: E0 recu, bit 2: Maj gauche, bit 3: Maj droite
static void ps2Accept(uint8_t sc) {
  bool brk = navMods & 1, ext = navMods & 2;
  bool pfx = (sc == 0xF0 || sc == 0xE0);
  if (sc == 0xF0) navMods |= 1;
  else if (sc == 0xE0) navMods |= 2;
  else {
    navMods &= (uint8_t)~3;
    uint8_t bit = ext ? 0 : (sc == 0x12) ? 4 : (sc == 0x59) ? 8 : 0;
    if (bit) { if (brk) navMods &= (uint8_t)~bit; else navMods |= bit; }
  }
  if (lcdCon) {
    if (pfx && navPfxN < 2) { navPfx[navPfxN++] = sc; return; }
    if (!pfx && (navMods & 12)) {
      uint8_t d = sc == 0x75 ? 1 : sc == 0x72 ? 2 : sc == 0x6B ? 3 : sc == 0x74 ? 4 : 0;
      if (d) {
        navPfxN = 0;
        uint8_t nh = (uint8_t)((navHead + 1) & 7);
        if (!brk && nh != navTail) { navQ[navHead] = d; navHead = nh; }
        return;
      }
    }
  }
  for (uint8_t i = 0; i < navPfxN; i++) ps2Push(navPfx[i]);
  navPfxN = 0;
  ps2Push(sc);
}

// Test du clavier sur le LCD (pont 1.9): tant que le 8088 n'a rien envoye au LCD (lcdBridge), le pont y
// affiche lui-meme chaque octet PS/2 recu (kbdTestPoll, ligne 2). Copie des octets prise dans l'ISR: sans
// 8088, ps2Buf n'est jamais vide (IBF reste a 1) et finit plein. Bits 8-9: erreur de parite / de stop.
static volatile bool     lcdBridge = true; // faux des le premier octet LCD du 8088 (jusqu'au reset du pont)
static volatile uint16_t kbdEvt[16];
static volatile uint8_t  kbdEvtHead = 0, kbdEvtTail = 0;
static inline void kbdEvtPush(uint16_t e) {
  if (!lcdBridge) return;
  uint8_t nh = (uint8_t)((kbdEvtHead + 1) & 15);
  if (nh != kbdEvtTail) { kbdEvt[kbdEvtHead] = e; kbdEvtHead = nh; }
}

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
      ps2Accept(ps2Shift);                 // vers le 8088, sauf Maj + fleche pendant la console au LCD
      kbdTrack(ps2Shift);                  // Ctrl-Alt-Suppr -> reset du 8088 (meme s'il est fige)
      kbdEvtPush(ps2Shift);
    } else if (!ps2ParOk) { dbg(0x100 | ps2Shift); kbdEvtPush(0x100 | ps2Shift); }
    else { dbg(0x200 | ps2Shift); kbdEvtPush(0x200 | ps2Shift); }
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

// Caractere (position US) d'un code de jeu 2 sans prefixe, ou 0
static char kbdChar(uint8_t sc) {
  static const uint8_t code[] = { 0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,
                                  0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A,
                                  0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46 };
  static const char txt[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  for (uint8_t i = 0; i < sizeof(code); i++) if (code[i] == sc) return txt[i];
  return 0;
}

// Un evenement du test du clavier -> ligne 2 du LCD (16 caracteres: 16x2 comme 20x4). Un par tour de
// boucle (~8 ms d'I2C), seulement tant que le LCD appartient au pont.
//   "Clavier OK (AA)"   auto-test (BAT) reussi a la mise sous tension du clavier ("Clavier err (FC)")
//   "Appui   1C A"      touche enfoncee (code de jeu 2, caractere en position US)
//   "Relache E0 75"     touche relachee (F0), touche etendue (E0)
//   "Pause (E1)"        Pause: les 7 octets suivants de la sequence sont ignores
//   "Err parite 1C"     trame recue avec une erreur ("Err stop 1C"): cablage, tirages, parasites
static void kbdTestPoll() {
  static uint8_t pre = 0;                  // bit 0: F0 recu, bit 1: E0 recu
  static uint8_t skip = 0;                 // octets restants de la sequence Pause
  if (!lcdBridge || kbdEvtHead == kbdEvtTail) return;
  uint16_t e = kbdEvt[kbdEvtTail];
  kbdEvtTail = (uint8_t)((kbdEvtTail + 1) & 15);
  uint8_t sc = (uint8_t)e;
  char line[17];
  if (e & 0x300) {
    snprintf(line, sizeof(line), "Err %s %02X", (e & 0x100) ? "parite" : "stop", sc);
    pre = 0; skip = 0;
  } else if (skip) { skip--; return; }
  else if (sc == 0xE0) { pre |= 2; return; }
  else if (sc == 0xF0) { pre |= 1; return; }
  else if (sc == 0xE1) { snprintf(line, sizeof(line), "Pause (E1)"); skip = 7; pre = 0; }
  else if (pre == 0 && (sc == 0xAA || sc == 0xFC)) {
    snprintf(line, sizeof(line), sc == 0xAA ? "Clavier OK (AA)" : "Clavier err (FC)");
  } else {
    char c = (pre & 2) ? 0 : kbdChar(sc);
    snprintf(line, sizeof(line), "%s %s%02X %c", (pre & 1) ? "Relache" : "Appui  ",
             (pre & 2) ? "E0 " : "", sc, c ? c : ' ');
    pre = 0;
  }
  uint8_t n = (uint8_t)strlen(line);
  while (n < 16) line[n++] = ' ';          // efface la fin de la ligne precedente
  line[16] = 0;
  lcdPrintAt(0x40, line);
}

// ============================================================================
// RESET materiel du 8088 (PB2 -> broche 21, RESET actif HAUT)
// Le montage tire RESET a la masse (4,7 kohm, R1) et son bouton le porte a +5 V: PB2 (tolerante 5 V) n'est
// donc JAMAIS forcee BAS - soit sortie HAUTE (reset en cours), soit ENTREE sans pull (le bouton marche).
// Demandes: demarrage du pont (setup: le 8088 reste en reset, horloge deja en marche, jusqu'a ce que le
// pont soit pret), Ctrl-Alt-Suppr au clavier PS/2 (kbdTrack, dans ps2Isr: detecte meme si le 8088 est
// fige et ne lit plus rien), Ctrl-\ au terminal (1Ch: n'est plus transmis au 8088 - son ISR faisait un
// redemarrage LOGICIEL, sans effet quand le 8088 est fige).
// ============================================================================
#define RESET8088_BIT      2               // GPIOB
#define RESET8088_PULSE_MS 10UL            // >> 4 cycles d'horloge exiges par le 8088
#define RESET_UART_KEY     0x1C            // Ctrl-\ (terminal)
#define STUCK_MS           500UL           // IBF = 1 depuis ce delai: le 8088 ne lit plus (fige)
static volatile bool resetRequest = false;

static void reset8088Hold() {              // sortie HAUTE (ODR avant MODER: aucune impulsion basse)
  __HAL_RCC_GPIOB_CLK_ENABLE();
  GPIOB->BSRR = (1UL << RESET8088_BIT);
  GPIOB->OTYPER &= ~(1UL << RESET8088_BIT);
  GPIOB->PUPDR &= ~(3UL << (RESET8088_BIT * 2));
  GPIOB->MODER = (GPIOB->MODER & ~(3UL << (RESET8088_BIT * 2))) | (1UL << (RESET8088_BIT * 2));
}
static void reset8088Release() {           // entree sans pull: les 4,7 kohm (R1) ramenent RESET a 0
  GPIOB->MODER &= ~(3UL << (RESET8088_BIT * 2));
}

// Clavier PS/2 (jeu 2): Ctrl (14h, E0 14h) + Alt (11h, E0 11h) enfonces + Suppr (71h, E0 71h) -> reset.
// Appelee par ps2Isr pour CHAQUE octet recu (rapide, aucun delai).
static volatile uint8_t kbdMods = 0;       // bit 0: F0 recu, bit 1: E0 recu, bit 2: Ctrl, bit 3: Alt
static void kbdTrack(uint8_t sc) {
  if (sc == 0xF0) { kbdMods |= 1; return; }
  if (sc == 0xE0) { kbdMods |= 2; return; }
  bool brk = kbdMods & 1;
  kbdMods &= (uint8_t)~3;
  uint8_t bit = (sc == 0x14) ? 4 : (sc == 0x11) ? 8 : 0;
  if (bit) { if (brk) kbdMods &= (uint8_t)~bit; else kbdMods |= bit; return; }
  if (!brk && sc == 0x71 && (kbdMods & 12) == 12) resetRequest = true;
  // Horloge (pont 2.0): Ctrl+Alt+PgUp (7Dh) / PgDn (7Ah) / Debut (6Ch) / Fin (69h), avec ou sans E0
  // (pave numerique, Verr num eteint). Les touches partent aussi au 8088, comme Ctrl-Alt-Suppr.
  if (!brk && (kbdMods & 12) == 12) {
    if (sc == 0x7D) clockRequest = 9;
    else if (sc == 0x7A) clockRequest = 10;
    else if (sc == 0x6C) clockRequest = 5;
    else if (sc == 0x69) clockRequest = 11;
  }
}

// Impulsion de reset: l'ancienne session est oubliee (octets en attente dans les deux sens, commande
// partielle), puis RESET est relache - le 8088 repart au vecteur de reset (menu, RAM effacee).
static void reset8088Pulse() {
  reset8088Hold();
  noInterrupts();
  ps2Head = ps2Tail = 0;
  interrupts();
  qHead = qTail = 0;
  rqHead = rqTail = 0;
  cmdLen = 0;
  uartHoldUntil = 0;
  lcdCon = false;                          // le menu du 8088 reprend le LCD
  navPfxN = 0;
  // Le 8088 exige un RESET d'au moins 4 cycles d'horloge: 10 ms, ou 5 cycles si l'horloge est plus
  // lente (pont 2.0: 5 s a 1 Hz). L'USB reste servi pendant l'attente.
  uint32_t ms = RESET8088_PULSE_MS;
  if (actualClockHz > 0 && 5000UL / actualClockHz + 1 > ms) ms = 5000UL / actualClockHz + 1;
  uint32_t t0 = millis();
  while (millis() - t0 < ms) yield();
  reset8088Release();
  resetRequest = false;
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
  reset8088Hold();                         // le 8088 reste en RESET jusqu'a ce que le pont soit pret (fin de setup)
  cfgLoad();                               // pont 2.2: reglages du BIOS (flash interne, lecture directe: rapide)
  clockHz = cfgHz();                       // horloge au demarrage choisie dans le BIOS (4,77 MHz par defaut)
  clockSetup();                            // TOUT DE SUITE: le 8088 a besoin d'une horloge (aussi pendant son
                                            // reset) - avant tout ce qui suit (SPI/USB/RTC, lent)
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

#if HEARTBEAT || DISK_LED
  pinMode(PC13, OUTPUT);
  digitalWrite(PC13, HIGH);                // LED eteinte (active a l'etat bas)
#endif


  Wire.setSDA(PIN_SDA);
  Wire.setSCL(PIN_SCL);
  Wire.begin();
  Wire.setClock(100000);
  lcdInit();
  memset(conScr, ' ', sizeof(conScr));   // ecran du terminal vide (console au LCD)
  lcdBanner();                             // "Pont STM32 v1.9 / En attente 8088"

  pinMode(PIN_PS2_CLK, INPUT_PULLUP);      // + pull-ups externes 4,7-10 kohm vers +5 V conseilles
  pinMode(PIN_PS2_DATA, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_PS2_CLK), ps2Isr, FALLING);

  delay(RESET8088_PULSE_MS);               // pont pret: le 8088 demarre (horloge stable depuis clockSetup)
  reset8088Release();
}

// Terminal (port USB) -> 8088, pont 2.0: Ctrl-\ (reset) et Ctrl-] suivi d'une touche (horloge) sont
// traites ici et ne partent pas au 8088. termTake lit l'octet suivant destine au 8088 (-1: aucun).
// Quand le 8088 ne lit plus (fige, ou horloge tres lente), loop() vide quand meme le port USB pour y
// trouver ces raccourcis; les autres octets attendent alors dans termPend (64 octets, puis perdus).
static uint8_t termPend[64];
static uint8_t termPendHead = 0, termPendTail = 0;
static bool termCtlPrefix = false;
static bool termControl(uint8_t c) {      // vrai si l'octet est un raccourci du pont (consomme)
  if (termCtlPrefix) {
    termCtlPrefix = false;
    if (c == '+' || c == '=') clockRequest = 9;
    else if (c == '-' || c == '_') clockRequest = 10;
    else if (c == '0') clockRequest = 5;
    else if (c == '1') clockRequest = 11;
    else if (c == '?') {
      char t[24];
      clockReport();
      flashText(t, sizeof(t));
      UsbSerial.print("[Pont] "); UsbSerial.print(t);
      UsbSerial.print(fsOk ? ", disque monte\r\n" : (flashOk ? ", disque non formate\r\n" : ", disque absent\r\n"));
    }
    return true;                           // autre touche apres Ctrl-]: ignoree
  }
  if (c == 0x1D) { termCtlPrefix = true; return true; }      // Ctrl-]
  if (c == RESET_UART_KEY) { resetRequest = true; return true; }
  return false;
}
static void termDrain() {                 // 8088 qui ne lit plus: raccourcis seulement
  while (UsbSerial.available() > 0) {
    uint8_t c = (uint8_t)UsbSerial.read();
    if (termControl(c)) continue;
    uint8_t nh = (uint8_t)((termPendHead + 1) & 63);
    if (nh != termPendTail) { termPend[termPendHead] = c; termPendHead = nh; }
  }
}
static int termTake() {
  if (termPendHead != termPendTail) {
    uint8_t c = termPend[termPendTail];
    termPendTail = (uint8_t)((termPendTail + 1) & 63);
    return c;
  }
  while (UsbSerial.available() > 0) {
    uint8_t c = (uint8_t)UsbSerial.read();
    if (!termControl(c)) return c;
  }
  return -1;
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

  // Reset du 8088 demande (Ctrl-Alt-Suppr, Ctrl-\). Si le 8088 ne lit plus rien, le terminal n'est plus
  // lu plus bas - on y cherche Ctrl-\ ici (les autres octets sont perdus: le 8088 ne les aurait jamais lus).
  // "Fige" = IBF = 1 (dernier octet envoye non lu) ET plus rien envoye depuis STUCK_MS. Premiere version
  // (1.2 initiale): IBF = 1 observe a CHAQUE debut de boucle pendant STUCK_MS - FAUX pendant un collage:
  // un tour de boucle (echo vers l'USB et le LCD I2C) peut durer plus que GAP_US, l'octet suivant partait
  // alors en fin de tour et le debut du tour suivant revoyait IBF = 1 - le 8088 semblait fige et le reste
  // du collage etait jete ("60 PI = 3.14159265" -> "60").
#if USE_IBF
  if (((GPIOA->IDR >> IBF_BIT) & 1) && (uint32_t)(micros() - lastTx) > STUCK_MS * 1000UL)
    termDrain();
#endif
  if (resetRequest) reset8088Pulse();
  if (clockRequest) {                      // raccourci de l'horloge (clavier PS/2 ou terminal)
    noInterrupts();
    uint8_t a = clockRequest;
    clockRequest = 0;
    interrupts();
    clockChange(a);
    clockReport();
  }

#if HEARTBEAT && !DISK_LED
  { static uint32_t t = 0;
    if (millis() - t >= 500) { t = millis(); digitalToggle(PC13); } }
#endif
  diskLedPoll();                           // temoin d'acces au disque (DISK_LED)

  // 1. 8088 -> file
  if (!qFull() && ps2Quiet(BUS_QUIET_US)) {
    uint8_t chan, val;
    if (takeFrom8088(chan, val)) {
      if (chan == CH_UART) conPut(val);    // ecran 80x25 du terminal (console au LCD)
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
      if (it.chan == CH_LCD_CMD || it.chan == CH_LCD_DATA) {
        lcdBridge = false;                 // le 8088 prend le LCD: fin du test du clavier
        if (lcdCon) { lcdCon = false; lcdAddr = 0xFF; }   // ... et de la console au LCD
      }
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
  kbdTestPoll();                           // test du clavier sur le LCD (tant que le 8088 ne l'a pas pris)
  conPoll();                               // console au LCD (commande 2Dh)

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
    // RAFALE (pont 1.6): les octets suivants de la reponse (bloc de 32 octets d'un secteur, par exemple)
    // partent des que le 8088 a lu le precedent (IBF = 0), sans repasser par la boucle principale
    // (USB, LCD, clavier: un octet par tour, ~150-300 us). Retour a la boucle si le 8088 tarde plus de
    // BURST_WAIT_US (il fait autre chose) ou si une trame PS/2 commence.
    {
      uint32_t t0 = micros();
      while (rqHead != rqTail) {
        if ((GPIOA->IDR >> IBF_BIT) & 1) {               // octet precedent pas encore lu
          if ((uint32_t)(micros() - t0) > BURST_WAIT_US) break;
          continue;
        }
        if ((uint32_t)(micros() - lastTx) < REPLY_GAP_US) continue;
        if (!ps2Quiet(BUS_QUIET_US)) break;
        v = rq[rqTail];
        rqTail = (uint8_t)((rqTail + 1) & 63);
        sendTo8088(2, v);
        markSent();
        t0 = micros();
      }
    }
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
    } else if ((termPendHead != termPendTail || UsbSerial.available() > 0) && ps2Quiet(BUS_QUIET_US) &&
               (int32_t)(millis() - uartHoldUntil) >= 0) {
      int c = termTake();                  // Ctrl-\ (reset) et Ctrl-] (horloge) traites par termControl
      if (c >= 0) {
        sendTo8088(1, (uint8_t)c);
        markSent();
        if (c == 13) uartHoldUntil = millis() + LINE_DELAY_MS;   // le 8088 traite la ligne
      }
    }
  }
}
