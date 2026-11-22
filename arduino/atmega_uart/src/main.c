/*
 * Solution-02 - ATmega328P (U17), quartz 16 MHz : UART du montage (J5), esclave SPI du 8088
 * sur le bus de la carte SD. Protocole : protocole.h. Schema du 2026-11-21.
 *
 *   PB2 SS   <- U12 PC0 (R21 au +5 V)      PD0 RXD <- J5-2 (R4 au +5 V)
 *   PB3 MOSI <- U12 PC6 (SD_MOSI)          PD1 TXD -> J5-1
 *   PB4 MISO -> U12 PB4 (R20 au +5 V)      PD2 IRQ -> IR4 du 8259 (front montant)
 *   PB5 SCK  <- U12 PC5 (SD_SCK)           PD6 RTS -> J8-1 (actif a 0)
 *                                          PD7 CTS <- J8-2 (actif a 0, R22 a la masse)
 * En esclave, MISO n'est pilote que tant que SS = 0 : la carte SD garde le bus le reste du
 * temps. Ne jamais passer en maitre SPI.
 *
 * Fusibles (fusibles.txt) : lfuse FFh (quartz), hfuse D9h, efuse FDh.
 */
#include <avr/interrupt.h>
#include <avr/io.h>
#include "protocole.h"

#define SS      (1 << PB2)
#define MISO    (1 << PB4)
#define IRQ     (1 << PD2)
#define RTS     (1 << PD6)
#define CTS     (1 << PD7)

/* UBRR0 avec U2X0 (F_CPU / 8 / vitesse - 1), dans l'ordre de P_V_* */
static const uint16_t ubrr[P_V_NB] = { 207, 103, 51, 34, 16, 416, 832 };

static volatile uint8_t emis;           /* au moins un octet emis depuis le demarrage */

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

/* octet echange avec le 8088 : l'octet suivant est prepare tout de suite */
ISR(SPI_STC_vect)
{
    SPDR = p_spi(SPDR);
    sorties();
}

/* SS change (PCINT2 = PB2) */
ISR(PCINT0_vect)
{
    if (PINB & SS)
        SPDR = p_ss_fin();
    else
        p_ss_debut();
    sorties();
}

ISR(USART_RX_vect)
{
    uint8_t st = UCSR0A;
    uint8_t b = UDR0;
    p_uart_recu(b, st & ((1 << FE0) | (1 << DOR0)));
    sorties();
}

ISR(USART_UDRE_vect)
{
    int16_t b;
    if (PIND & CTS) {                   /* le terminal ne peut plus recevoir : attente */
        UCSR0B &= ~(1 << UDRIE0);
        return;
    }
    b = p_uart_a_emettre();
    if (b < 0) {
        UCSR0B &= ~(1 << UDRIE0);
        return;
    }
    UCSR0A = (1 << U2X0) | (1 << TXC0); /* TXC0 a 0 (s'efface en ecrivant 1) */
    UDR0 = (uint8_t)b;
    emis = 1;
}

static void vitesse(uint8_t v)
{
    UBRR0 = ubrr[v];
}

int main(void)
{
    /* broches libres (PB0, PB1, PC0-PC5, PD3-PD5) : entrees avec tirage */
    PORTB = (1 << PB0) | (1 << PB1);
    PORTC = 0x3F;
    PORTD = (1 << PD3) | (1 << PD4) | (1 << PD5);
    DDRB = MISO;                        /* SS, MOSI, SCK en entree */
    DDRD = IRQ | RTS;                   /* IRQ a 0, RTS actif (0) */

    p_init();

    UCSR0A = (1 << U2X0);
    vitesse(P_V_9600);
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);     /* 8N1 */
    UCSR0B = (1 << RXCIE0) | (1 << RXEN0) | (1 << TXEN0);

    SPCR = (1 << SPE) | (1 << SPIE);    /* esclave, mode 0, poids fort en premier */
    SPDR = P_SIGNATURE;
    PCMSK0 = (1 << PCINT2);             /* SS */
    PCICR = (1 << PCIE0);
    sorties();
    sei();

    for (;;) {
        cli();
        p_cts = !(PIND & CTS);
        if (p_cts && p_tx_nb())         /* reprise de l'emission (ECRIRE, retour de CTS) */
            UCSR0B |= (1 << UDRIE0);
        if (p_vitesse != P_V_AUCUNE && !p_tx_nb() && !(UCSR0B & (1 << UDRIE0))
            && (!emis || (UCSR0A & (1 << TXC0)))) {     /* dernier octet parti */
            vitesse(p_vitesse);
            p_vit_courante = p_vitesse;
            p_vitesse = P_V_AUCUNE;
        }
        sei();
    }
}
