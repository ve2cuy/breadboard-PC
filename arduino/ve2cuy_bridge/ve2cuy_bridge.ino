// ============================================================================
// ve2cuy_bridge.ino  -  Pont Arduino UNO <-> 8088 (8255 en MODE 2)
//
// L'Arduino remplace toute la logique "peripherique" du PC/XT breadboard:
//   - clavier PS/2  : decode la trame (CLK/DATA), verifie parite/stop, envoie
//                     le scan code brut (Set 2) au 8088;
//   - UART          : Serial materiel (USB) <-> 8088, vitesse independante de
//                     l'horloge du 8088;
//   - LCD 20x4 I2C  : possede le bus I2C materiel (A4/A5) et le protocole
//                     PCF8574/HD44780 (init 4 bits, quartets, delais).
//
// Le 8088 ne voit qu'UN bus de 8 bits: le Port A du 8255 en MODE 2, avec la
// poignee de main materielle du 8255 (voir Directives.md, hardware.inc):
//
//   8088 -> Arduino : le 8088 pose le CANAL sur le Port B (PB0/PB1) puis ecrit
//       le Port A; OBF# (PC7) passe a 0. On lit le canal, on abaisse ACK#
//       (PC6): le 8255 pilote alors le bus, on lit l'octet, on relache ACK#.
//       canal 0 = octet UART a emettre, 1 = commande LCD, 2 = donnee LCD.
//   Arduino -> 8088 : on pose l'etiquette (PC0: 0 = scan code, 1 = octet UART
//       recu), on pose l'octet sur le bus et on pulse STB# (PC4); INTR du 8255
//       (cable sur IR1 du 8259) interrompt le 8088.
//
// CABLAGE (18 broches, aucun circuit integre supplementaire)
//   D2  <- CLK  clavier PS/2 (interruption INT0)
//   D3  <- DATA clavier PS/2
//   D4  -> ACK#  8255 PC6        (repos: HAUT)   + pull-up 10k vers +5V conseille
//   D5  -> STB#  8255 PC4        (repos: HAUT)   + pull-up 10k vers +5V conseille
//   D6  <- OBF#  8255 PC7
//   D7  -> TAG   8255 PC0
//   D8  <- CH0   8255 PB0
//   D9  <- CH1   8255 PB1
//   D10 D11 D12 D13 A3 A2 A1 A0  <->  8255 PA0 PA1 PA2 PA3 PA4 PA5 PA6 PA7
//   (soit D10-D13 = PA0-PA3, A3=PA4, A2=PA5, A1=PA6, A0=PA7 - voir BUS[])
//   A4 (SDA), A5 (SCL) -> module LCD I2C (PCF8574, adresse 0x27 ou 0x3F)
//   INTR du 8255 (PC3) -> IR1 du 8259 (plus aucune sortie IR sur l'Arduino)
//   D0/D1 : reserves a l'USB (UART vers le PC) - ne rien y brancher.
//   Masse commune Arduino / breadboard 8088.
//
// Aucun controle de flux 8088<-Arduino cote IBF (pas de broche libre): un
// espace minimal de GAP_US entre deux octets envoyes laisse au 8088 le temps
// de lire le Port A dans son interruption.
// ============================================================================
#include <Wire.h>

// ---- reglages -------------------------------------------------------------
#define UART_BAUD   57600UL   // 8N1, valide sur le materiel (ancien UART logiciel: 9600)
#define LCD_ADDR    0x27     // 0x3F pour un PCF8574A
#define GAP_US      1000UL   // espace mini entre deux octets Arduino -> 8088
// Le clavier envoie 0F0h puis le code de la touche COUP SUR COUP. Toute impulsion
// sur STB#/ACK#/bus pendant qu'une trame PS/2 arrive perturbe CLK/DATA (lignes
// tirees par les seuls pull-ups internes, voisines de D4/D5): trame rejetee
// ({S76}{G} dans la trace) - et le 8088, ayant lu 0F0h, avale la touche suivante.
// On n'agit donc sur le bus 8255 que si CLK est silencieux depuis:
#define KBD_QUIET_US 3000UL  // avant d'ENVOYER un octet clavier (fin de la rafale)
#define BUS_QUIET_US 400UL   // avant tout autre acces au bus (trame en cours)
// Filtrage du bruit sur CLK/DATA (lignes a haute impedance, voisines de D1/TX,
// de l'I2C et de STB#/ACK#): un vrai front descendant de CLK reste bas >= 30 us,
// un parasite de diaphonie quelques us seulement.
#define PS2_GLITCH_US    10UL  // CLK doit etre encore basse apres ce delai
#define PS2_FRAME_GAP_US 250UL // sans front valide depuis: nouvelle trame (la
                               // periode CLK max est 100 us) - realigne apres
                               // une trame abimee au lieu de decaler les suivantes
#define DEBUG_PS2   0        // 1 = trace PS/2 sur le terminal (Serial), voir dbg*()

// ---- broches --------------------------------------------------------------
const uint8_t PIN_PS2_CLK  = 2;   // = PD2 (INT0) - ps2Isr lit PIND directement: garder CLK/DATA sur PD0-PD7
const uint8_t PIN_PS2_DATA = 3;
const uint8_t PIN_ACK      = 4;
const uint8_t PIN_STB      = 5;
const uint8_t PIN_OBF      = 6;
const uint8_t PIN_TAG      = 7;
const uint8_t PIN_CH0      = 8;
const uint8_t PIN_CH1      = 9;
// Ordre selon le CABLAGE REEL constate sur le montage: A0..A3 sont relies a
// PA7..PA4 (ordre inverse - les broches du 8255 sont numerotees 4,3,2,1 puis
// 40,39,38,37 pour PA0..PA7). Si vous recablez A3->PA7 ... A0->PA4, remettez
// {10, 11, 12, 13, A0, A1, A2, A3}.
const uint8_t BUS[8]       = {10, 11, 12, 13, A3, A2, A1, A0};

// ---- canaux 8088 -> Arduino (Port B) --------------------------------------
const uint8_t CH_UART     = 0;
const uint8_t CH_LCD_CMD  = 1;
const uint8_t CH_LCD_DATA = 2;

// ============================================================================
// Bus Port A
// ============================================================================
static void busRelease() {                 // haute impedance, sans pull-up
  for (uint8_t i = 0; i < 8; i++) {
    pinMode(BUS[i], INPUT);
    digitalWrite(BUS[i], LOW);
  }
}

static uint8_t busRead() {
  uint8_t v = 0;
  for (uint8_t i = 0; i < 8; i++)
    if (digitalRead(BUS[i])) v |= (uint8_t)(1 << i);
  return v;
}

// Arduino -> 8088: octet + etiquette, puis impulsion STB#.
static void sendTo8088(uint8_t tag, uint8_t v) {
  digitalWrite(PIN_TAG, tag);
  for (uint8_t i = 0; i < 8; i++) {
    digitalWrite(BUS[i], (v >> i) & 1);    // niveau AVANT de passer en sortie
    pinMode(BUS[i], OUTPUT);
  }
  delayMicroseconds(2);
  digitalWrite(PIN_STB, LOW);
  delayMicroseconds(2);
  digitalWrite(PIN_STB, HIGH);             // front montant: le 8255 verrouille
  delayMicroseconds(2);
  busRelease();
}

// Echantillonnage INSTANTANE des 3 ports (3 lectures de registre, < 1 us),
// puis decodage a loisir. Indispensable: le 8255 remet OBF# a 1 des que ACK#
// DESCEND (pas quand il remonte), donc le 8088 peut ecrire l'octet suivant
// ~15 us plus tard, pendant qu'on lit encore le bus. Lire les 8 broches une a
// une avec digitalRead (~30 us) melangeait deux octets.
static inline uint32_t snapPorts() {       // PINB | PINC<<8 | PIND<<16
  return (uint32_t)PINB | ((uint32_t)PINC << 8) | ((uint32_t)PIND << 16);
}
static uint8_t snapBit(uint32_t s, uint8_t pin) {
  volatile uint8_t *reg = portInputRegister(digitalPinToPort(pin));
  uint8_t r = (reg == &PINB) ? (uint8_t)s
            : (reg == &PINC) ? (uint8_t)(s >> 8) : (uint8_t)(s >> 16);
  return (r & digitalPinToBitMask(pin)) ? 1 : 0;
}

// 8088 -> Arduino: si OBF# est bas, lit canal + octet. ACK# bas = le 8255
// pilote le bus; les broches sont des entrees a ce moment-la. Le canal (Port
// B) est stable depuis que le 8088 a ecrit le Port A - meme instantane.
static bool takeFrom8088(uint8_t &chan, uint8_t &val) {
  if (digitalRead(PIN_OBF)) return false;  // rien en attente
  digitalWrite(PIN_ACK, LOW);
  delayMicroseconds(2);                    // tAOD du 8255 < 200 ns
  uint32_t s = snapPorts();
  digitalWrite(PIN_ACK, HIGH);
  chan = (uint8_t)(snapBit(s, PIN_CH0) | (snapBit(s, PIN_CH1) << 1));
  val = 0;
  for (uint8_t i = 0; i < 8; i++) val |= (uint8_t)(snapBit(s, BUS[i]) << i);
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
// Si {76}{F0}{76} apparait a chaque appui sur Echap mais que le 8088 rate la
// touche, la perte est apres l'Arduino (8255/8088); si des {P..}/{S..}/{G}/{R..}
// apparaissent, c'est la reception PS/2 (parasites, tirage au +5V).
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
  while (dbgHead != dbgTail && Serial.availableForWrite() >= 8) {
    uint16_t v = dbgBuf[dbgTail];
    dbgTail = (uint8_t)((dbgTail + 1) & 63);
    uint8_t k = (uint8_t)(v >> 8), b = (uint8_t)v;
    Serial.print('{');
    switch (k) {
      case 0: break;
      case 1: Serial.print('P'); break;
      case 2: Serial.print('S'); break;
      case 3: Serial.print('G'); break;
      case 4: Serial.print('O'); break;
      case 5: Serial.print('R'); Serial.print(b); Serial.print('}'); continue;
      case 6: Serial.print('>'); break;
      case 7: Serial.print('g'); Serial.print('}'); continue;
    }
    if (k != 3 && k != 4) { if (b < 16) Serial.print('0'); Serial.print(b, HEX); }
    Serial.print('}');
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

static void ps2Isr() {
  uint32_t now = micros();
  ps2Act = now;
  delayMicroseconds(PS2_GLITCH_US);
  if (PIND & _BV(PIN_PS2_CLK)) { dbg(0x700); return; }   // CLK repassee haute: parasite

  // DATA: vote majoritaire sur 3 lectures (encore stable a ce stade du cycle)
  uint8_t votes = 0;
  if (PIND & _BV(PIN_PS2_DATA)) votes++;
  delayMicroseconds(2);
  if (PIND & _BV(PIN_PS2_DATA)) votes++;
  delayMicroseconds(2);
  if (PIND & _BV(PIN_PS2_DATA)) votes++;
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
void setup() {
  pinMode(PIN_ACK, OUTPUT);  digitalWrite(PIN_ACK, HIGH);
  pinMode(PIN_STB, OUTPUT);  digitalWrite(PIN_STB, HIGH);
  pinMode(PIN_TAG, OUTPUT);  digitalWrite(PIN_TAG, LOW);
  pinMode(PIN_OBF, INPUT_PULLUP);          // 8255 absent/hors tension = "rien"
  pinMode(PIN_CH0, INPUT);
  pinMode(PIN_CH1, INPUT);
  busRelease();

  Serial.begin(UART_BAUD);

  Wire.begin();
  Wire.setClock(100000);
#ifdef WIRE_HAS_TIMEOUT
  Wire.setWireTimeout(3000, true);         // un bus I2C bloque ne fige pas le pont
#endif
  lcdInit();

  pinMode(PIN_PS2_CLK, INPUT_PULLUP);
  pinMode(PIN_PS2_DATA, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_PS2_CLK), ps2Isr, FALLING);
}

void loop() {
  dbgFlush();

  // 1. 8088 -> file
  if (!qFull() && ps2Quiet(BUS_QUIET_US)) {
    uint8_t chan, val;
    if (takeFrom8088(chan, val)) {
      q[qHead].chan = chan; q[qHead].val = val;
      qHead++;
    }
  }

  // 2. file -> UART ou LCD (un element par tour)
  if (!qEmpty()) {
    Item &it = q[qTail];
    if (it.chan == CH_UART) {
      if (Serial.availableForWrite() > 0) { Serial.write(it.val); qTail++; }
    } else {
      if (it.chan == CH_LCD_CMD) {
        if (it.val == 0x28) lcdResync();   // Function Set = debut de i2c_lcd_init
                                           // (8088): resynchronise un LCD deregle
        lcdSend(it.val, 0);
      }
      else if (it.chan == CH_LCD_DATA) lcdSend(it.val, LCD_RS);
      qTail++;                             // canal inconnu: octet jete
    }
  }

  // 3. clavier / UART recu -> 8088 (espace minimal entre deux octets)
  static uint32_t lastTx = 0;
  if ((uint32_t)(micros() - lastTx) >= GAP_US) {
    uint8_t v;
    if (ps2Head != ps2Tail && ps2Quiet(KBD_QUIET_US)) {
      ps2Pop(v);
      sendTo8088(0, v);
      dbgSent(v);
      lastTx = micros();
    } else if (Serial.available() > 0 && ps2Quiet(BUS_QUIET_US)) {
      sendTo8088(1, (uint8_t)Serial.read());
      lastTx = micros();
    }
  }
}
