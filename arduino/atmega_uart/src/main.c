/*
 * Solution-02 - ATmega328P (U17), quartz 16 MHz : deux UART pour le 8088, esclave SPI sur le
 * bus de la carte SD. Protocole : protocole.h. Schema du 2026-11-23.
 *
 *   PB0 ICP1 <- J5-2 (terminal RX, R4)     PD0 RXD <- J13-1 (TX du module Wi-Fi, 3,3 V)
 *   PB1 OC1A -> J5-1 (terminal TX)         PD1 TXD -> J13-2 (RX du module, adapte a bord)
 *   PB2 SS   <- U12 PC0 (R21 au +5 V)      PD2 IRQ -> IR4 du 8259 (front montant)
 *   PB3 MOSI <- U12 PC6 (SD_MOSI)          PD6 RTS -> J8-1 (terminal, actif a 0)
 *   PB4 MISO -> U12 PB4 (R20 au +5 V)      PD7 CTS <- J8-2 (terminal, actif a 0, R22)
 *   PB5 SCK  <- U12 PC5 (SD_SCK)
 * En esclave, MISO n'est pilote que tant que SS = 0 : la carte SD garde le bus le reste du
 * temps. Ne jamais passer en maitre SPI.
 *
 * Canal 1 (terminal) = UART logiciel sur la minuterie 1, jusqu'a 115200 bauds :
 *  - reception : la capture d'entree (ICP1) date chaque front de la ligne au cycle pres (le
 *    materiel fige l'instant ; l'interruption ne fait que le ranger et inverser le front
 *    attendu). La boucle principale decode les trames a partir de ces dates : chaque bit vaut
 *    le niveau de la ligne au milieu du bit. Aucune contrainte de latence sur le decodage ;
 *    l'interruption doit seulement passer avant le front suivant (1 bit = 139 cycles a 115200).
 *  - emission : la comparaison A (OC1A) pose chaque bit au cycle pres ; l'interruption prepare
 *    le bit suivant (meme delai d'un bit).
 * Canal 2 (Wi-Fi) = USART materiel, scrute par la boucle principale (2 octets de FIFO).
 *
 * Interruptions : minuterie 1 (CAPT, COMPA) courtes et bloquantes ; SPI et PCINT (SS)
 * masquent SPI et PCINT puis rendent les interruptions, pour ne jamais retarder la minuterie
 * de plus que leur prologue. La boucle principale masque SPI et PCINT (pas tout) pendant ses
 * appels au protocole.
 *
 * Fusibles (fusibles.txt) : lfuse FFh (quartz), hfuse D9h, efuse FDh.
 */
#include <avr/interrupt.h>
#include <avr/io.h>
#include <avr/pgmspace.h>
#include "protocole.h"
#include "uart_logiciel.h"

#define SS      (1 << PB2)
#define MISO    (1 << PB4)
#define TXL     (1 << PB1)
#define RXL     (1 << PB0)
#define IRQ     (1 << PD2)
#define RTS     (1 << PD6)
#define CTS     (1 << PD7)

/* UBRR0 avec U2X0 (F_CPU / 8 / vitesse - 1), dans l'ordre de P_V_* */
static const uint16_t ubrr[P_V_NB] PROGMEM = { 207, 103, 51, 34, 16, 416, 832 };
/* UART logiciel : duree d'un bit en tops de la minuterie 1, et diviseur (1 ou 8) */
static const uint16_t bit_tops[P_V_NB] PROGMEM = { 1667, 833, 417, 278, 139, 417, 833 };
static const uint8_t bit_div8[P_V_NB] PROGMEM = { 0, 0, 0, 0, 0, 1, 1 };

/* masquage des interruptions SPI et PCINT (le protocole), la minuterie reste libre. Les deux
 * ecritures sont faites d'un bloc : sinon PCINT, survenant entre les deux, reactiverait SPI en
 * sortant (PROTO_ON) au milieu d'une section protegee (octet perdu, vu au banc simavr). */
#define PROTO_OFF()     do { uint8_t s_ = SREG; cli(); SPCR = (1 << SPE); PCICR = 0; SREG = s_; } while (0)
#define PROTO_ON()      do { PCICR = (1 << PCIE0); SPCR = (1 << SPE) | (1 << SPIE); } while (0)

static uint8_t emis2;                   /* au moins un octet emis au module */

static inline void sorties(void)
{
    if (p_irq)
        PORTD |= IRQ;
    else
        PORTD &= ~IRQ;
    if (p_rts)
        PORTD &= ~RTS;
    else
        PORTD |= RTS;
}

/* minuterie 1 : interruptions CAPT et COMPA en assembleur (uart_isr.S) */

/* ------------------------------------------------------------- SPI (8088) */

/* Corps des interruptions SPI et PCINT. Leur entree (uart_isr.S) masque SPI et PCINT et rend
 * aussitot les interruptions, avant meme de sauver les registres : la minuterie n'attend que
 * ~15 cycles. Elles se masquent l'une l'autre : jamais en meme temps. */

/* octet echange avec le 8088 : l'octet suivant est prepare tout de suite */
void spi_corps(void)
{
    SPDR = p_spi(SPDR);
    sorties();
}

/* SS change (PCINT2 = PB2) */
void ss_corps(void)
{
    if (SPSR & (1 << SPIF))             /* dernier octet pas encore traite (SPI masque par */
        (void)p_spi(SPDR);              /* la boucle principale) : avant la fin de transaction */
    SPDR = p_ss_fin();                  /* toujours : si SS est deja redescendu (impulsion */
    if (!(PINB & SS))                   /* haute plus courte que la latence), la fin de la */
        p_ss_debut();                   /* transaction precedente n'est pas perdue */
    sorties();
}

/* ------------------------------------------------------------- canal 1 */


static uint16_t bt;                     /* duree d'un bit (tops) ; copie en r2:r3 */

static void vitesse1(uint8_t v)
{
    bt = pgm_read_word(&bit_tops[v]);
    REG_ECRIT("r2", bt);                /* copie pour COMPA (r2:r3) */
    REG_ECRIT("r3", bt >> 8);
    TCCR1B = (TCCR1B & ~((1 << CS12) | (1 << CS11) | (1 << CS10)))
           | (pgm_read_byte(&bit_div8[v]) ? (1 << CS11) : (1 << CS10));
}

/* decodage des trames recues (boucle principale). Etat garde entre deux appels ; copie
 * locale pendant le decodage (a 115200 bauds, chaque cycle compte). */
static uint8_t rx_actif, rx_n, rx_sh, rx_niv;
static uint16_t rx_mil;                 /* milieu du bit rx_n */

static void canal2_rx(void);

static void rx_octet(uint8_t octet, uint8_t arret)
{
    PROTO_OFF();
    p_uart_recu(octet, !arret);         /* arret a 0 : erreur de trame */
    sorties();
    PROTO_ON();
}

static void canal1_rx(void)
{
    uint8_t q, actif = rx_actif, n = rx_n, sh = rx_sh, niv = rx_niv;
    uint16_t mil = rx_mil, b = bt, t;
    uint8_t fin = 0;

    for (;;) {
        q = FR_QUEUE();
        if (q != FR_TETE()) {           /* front suivant */
            t = fr[q];
            FR_QUEUE_ECRIT((q + 1) & (FR_N - 1));
        } else if (actif) {             /* plus de front : la ligne n'a pas bouge jusqu'ici */
            cli();
            t = TCNT1;
            fin = (FR_QUEUE() != FR_TETE()) || (TIFR1 & (1 << ICF1));
            sei();
            if (fin) {                  /* un front vient d'arriver : le traiter d'abord */
                fin = 0;
                continue;
            }
            fin = 1;
        } else {
            break;
        }
        if (actif) {                    /* bits dont le milieu est passe avant t */
            while ((int16_t)(t - mil) >= 0) {
                if (n <= 8) {
                    sh >>= 1;
                    if (niv)
                        sh |= 0x80;
                    n++;
                    mil += b;
                } else {                /* milieu du bit d'arret : trame finie */
                    rx_octet(sh, niv);
                    actif = 0;
                    break;
                }
            }
        }
        if (fin)
            break;
        niv = t & 1;
        if (!actif && !niv) {           /* front descendant hors trame : bit de depart */
            actif = 1;
            n = 1;
            mil = t + b + (b >> 1);
        }
        if (UCSR0A & (1 << RXC0))       /* (FIFO de l'USART : 2 octets seulement) */
            canal2_rx();
    }
    rx_actif = actif;
    rx_n = n;
    rx_sh = sh;
    rx_niv = niv;
    rx_mil = mil;

    if (!actif && FR_QUEUE() == FR_TETE()) {    /* repos : front attendu coherent avec la ligne */
        cli();
        if (!(TIFR1 & (1 << ICF1)) && FR_QUEUE() == FR_TETE()
            && (TCCR1B & (1 << ICES1)) && (PINB & RXL)) {
            TCCR1B &= ~(1 << ICES1);    /* front montant attendu, ligne deja a 1 : resynchronise */
            TIFR1 = (1 << ICF1);
        }
        sei();
    }
}

static void canal1_tx(void)
{
    int16_t b;
    if (!tx_actif) {                    /* repos : tx_fin suit l'horloge (comparaisons sur 16 bits) */
        cli();
        if ((int16_t)(TCNT1 - tx_fin) > 0)
            tx_fin = TCNT1;
        sei();
    }
    p_cts = !(PIND & CTS);
    if (!p_cts || ((em_tete + 1) & (EM_N - 1)) == em_queue || !p_tx_nb())
        return;
    PROTO_OFF();
    b = p_uart_a_emettre();
    PROTO_ON();
    if (b < 0)
        return;
    em[em_tete] = (uint8_t)b;
    cli();
    em_tete = (em_tete + 1) & (EM_N - 1);
    if (!tx_actif) {                    /* ligne au repos : premiere trame */
        uint8_t q = em_queue;
        uint16_t t = TCNT1 + 40;
        if ((int16_t)(tx_fin - t) > 0)
            t = tx_fin;                 /* bit d'arret precedent entier */
        REG_ECRIT("r6", em[q]);         /* tx_sh */
        em_queue = (q + 1) & (EM_N - 1);
        REG_ECRIT("r5", TX_BITS);       /* tx_n */
        TCCR1A = OC1A_ZERO;
        OCR1A = t;
        TIFR1 = (1 << OCF1A);
        TIMSK1 |= (1 << OCIE1A);
        tx_actif = 1;
    }
    sei();
}

static void canal1_vitesse(void)
{
    if (p_vitesse == P_V_AUCUNE || tx_actif || em_tete != em_queue || rx_actif)
        return;
    PROTO_OFF();
    if (p_tx_nb() == 0) {
        cli();
        vitesse1(p_vitesse);
        tx_fin = TCNT1;
        sei();
        p_vit_courante = p_vitesse;
        p_vitesse = P_V_AUCUNE;
    }
    PROTO_ON();
}

/* ------------------------------------------------------------- canal 2 */

static void canal2_rx(void)
{
    uint8_t st = UCSR0A;
    if (st & (1 << RXC0)) {
        uint8_t b = UDR0;
        PROTO_OFF();
        p2_uart_recu(b, st & ((1 << FE0) | (1 << DOR0)));
        PROTO_ON();
    }
}

static void canal2(void)
{
    uint8_t st;
    canal2_rx();
    st = UCSR0A;
    if ((st & (1 << UDRE0)) && p2_tx_nb()) {   /* (lecture sans masque : indication) */
        int16_t b;
        PROTO_OFF();
        b = p2_uart_a_emettre();
        PROTO_ON();
        if (b >= 0) {
            UCSR0A = (1 << U2X0) | (1 << TXC0); /* TXC0 a 0 (s'efface en ecrivant 1) */
            UDR0 = (uint8_t)b;
            emis2 = 1;
        }
    }
    if (p2_vitesse != P_V_AUCUNE) {
        PROTO_OFF();
        if (p2_tx_nb() == 0 && (!emis2 || (UCSR0A & (1 << TXC0)))) {  /* dernier octet parti */
            UBRR0 = pgm_read_word(&ubrr[p2_vitesse]);
            p2_vit_courante = p2_vitesse;
            p2_vitesse = P_V_AUCUNE;
        }
        PROTO_ON();
    }
}

int main(void)
{
    /* broches libres (PC0-PC5, PD3-PD5) : entrees avec tirage */
    PORTB = RXL | TXL;
    PORTC = 0x3F;
    PORTD = (1 << PD3) | (1 << PD4) | (1 << PD5);
    DDRB = MISO;                        /* SS, MOSI, SCK, RX en entree */
    DDRD = IRQ | RTS;                   /* IRQ a 0, RTS actif (0) */

    p_init();

    /* minuterie 1 : mode normal, capture sur front descendant avec filtre, OC1A a 1 */
    TCCR1A = OC1A_UN;
    TCCR1B = (1 << ICNC1);
    vitesse1(p_vit_courante);
    TCCR1C = (1 << FOC1A);              /* force OC1A a 1 (repos) avant de piloter PB1 */
    DDRB = MISO | TXL;
    TIFR1 = 0xFF;
    TIMSK1 = (1 << ICIE1);
    tx_fin = TCNT1;

    /* USART : module Wi-Fi, 8N1, scrute */
    UCSR0A = (1 << U2X0);
    UBRR0 = pgm_read_word(&ubrr[p2_vit_courante]);
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);
    UCSR0B = (1 << RXEN0) | (1 << TXEN0);

    SPCR = (1 << SPE) | (1 << SPIE);    /* esclave, mode 0, poids fort en premier */
    SPDR = P_SIGNATURE;
    PCMSK0 = (1 << PCINT2);             /* SS */
    PCICR = (1 << PCIE0);
    sorties();
    sei();

    for (;;) {
        canal1_rx();
        canal2();
        canal1_tx();
        canal2();
        canal1_vitesse();
    }
}
