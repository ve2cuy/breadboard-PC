// ============================================================
// irq_test.ino
// Test de branchement Arduino -> 8259 (IR1 "clavier", IR4 "UART") -
// meme esprit que le bouton-poussoir cable DIRECTEMENT sur IR0 (voir
// Solution-01/Directives.md, Solution-01/solution-01.asm:
// irq0_test_handler/irq1_test_handler/irq4_test_handler).
//
// Objectif: valider que l'Arduino peut reellement declencher une
// interruption materielle sur le 8088 via le 8259, AVANT d'implementer
// le vrai protocole de donnees (port 8255 dedie, pas encore cable) qui
// permettra de transmettre un scan code clavier ou un octet UART.
//
// Cablage attendu (CONFIRME sur le materiel reel - boutons en
// PULL-DOWN externe vers GND: repos = BAS, appui = HAUT sur la broche
// - PAS le pull-up interne de l'Arduino, qui se battrait avec le
// pull-down externe et bloquerait la broche a un niveau errone):
//   PIN_IR1_OUT  -> IR1 du 8259 (test "clavier")
//   PIN_IR4_OUT  -> IR4 du 8259 (test "UART")
//   PIN_BTN_KBD  -> bouton-poussoir avec pull-down externe vers GND
//                   (repos=BAS, appui=HAUT) - declenche une impulsion
//                   sur IR1
//   PIN_BTN_UART -> bouton-poussoir avec pull-down externe vers GND
//                   (repos=BAS, appui=HAUT) - declenche une impulsion
//                   sur IR4
//
// Polarite IRn CONFIRMEE sur le materiel reel: le 8259A (mode
// declenchement par front, voir solution-01.asm/init_8259) reconnait
// bien une transition BAS->HAUT sur IRn comme une requete
// d'interruption - IRn est donc normalement BAS au repos (IDLE_LEVEL)
// et pulse BRIEVEMENT HAUT (PULSE_LEVEL) pour declencher.
//
// PAS d'anti-rebond cote 8088 volontairement (voir irqN_test_handler)
// - plusieurs interruptions par impulsion restent attendues/normales.
// L'anti-rebond logiciel ci-dessous (DEBOUNCE_MS) est seulement pour
// eviter qu'un appui prolonge du bouton ne declenche des dizaines
// d'impulsions Arduino inutiles - il n'empeche PAS les rebonds
// electriques bruts de la ligne IRn elle-meme.
// ============================================================

const uint8_t PIN_IR1_OUT  = 8;   // vers IR1 du 8259 (test clavier)
const uint8_t PIN_IR4_OUT  = 9;   // vers IR4 du 8259 (test UART)
const uint8_t PIN_BTN_KBD  = 2;   // bouton "clavier" (pull-down externe, repos=BAS)
const uint8_t PIN_BTN_UART = 3;   // bouton "UART" (pull-down externe, repos=BAS)

const uint8_t IDLE_LEVEL   = LOW;
const uint8_t PULSE_LEVEL  = HIGH;

const unsigned long PULSE_MS    = 20;   // duree de l'impulsion IRn
const unsigned long DEBOUNCE_MS = 200;  // anti-rebond logiciel (voir note ci-dessus)

unsigned long lastKbdMs  = 0;
unsigned long lastUartMs = 0;

void pulse(uint8_t pin, const char *label) {
  digitalWrite(pin, PULSE_LEVEL);
  Serial.print(F("Impulsion IR sur pin "));
  Serial.print(pin);
  Serial.print(F(" ("));
  Serial.print(label);
  Serial.println(F(")"));
  delay(PULSE_MS);
  digitalWrite(pin, IDLE_LEVEL);
}

void setup() {
  pinMode(PIN_IR1_OUT, OUTPUT);
  pinMode(PIN_IR4_OUT, OUTPUT);
  digitalWrite(PIN_IR1_OUT, IDLE_LEVEL);
  digitalWrite(PIN_IR4_OUT, IDLE_LEVEL);

  // INPUT (pas INPUT_PULLUP): le pull-down est deja externe (voir
  // en-tete) - activer AUSSI le pull-up interne se battrait avec lui
  // et bloquerait la broche a un niveau indetermine/errone.
  pinMode(PIN_BTN_KBD, INPUT);
  pinMode(PIN_BTN_UART, INPUT);

  Serial.begin(9600);
  Serial.println(F("Test de branchement Arduino -> 8259 (IR1/IR4)"));
  Serial.println(F("Bouton clavier (D2) -> IR1, bouton UART (D3) -> IR4"));
}

void loop() {
  unsigned long now = millis();

  // Pull-down externe: repos=BAS, appui=HAUT (voir en-tete) - donc
  // "== HIGH" detecte l'appui, pas "== LOW".
  if (digitalRead(PIN_BTN_KBD) == HIGH && (now - lastKbdMs) > DEBOUNCE_MS) {
    lastKbdMs = now;
    pulse(PIN_IR1_OUT, "clavier, IR1");
  }

  if (digitalRead(PIN_BTN_UART) == HIGH && (now - lastUartMs) > DEBOUNCE_MS) {
    lastUartMs = now;
    pulse(PIN_IR4_OUT, "UART, IR4");
  }
}
