/*
 * Solution-02 - ATmega32-16PU, etape 1 : clignotement.
 *
 * Valide l'ATmega32 avant le micrologiciel (UART + carte SD + lien parallele avec le 8088) :
 * alimentation, RESET (tirage 10k), quartz 16 MHz (fusibles lfuse BFh, hfuse CFh : JTAG
 * coupe, CKOPT programme pour le quartz a 16 MHz, demarrage en 0000h).
 *
 * DEL sur PB0 (broche 1 du DIP-40) : PB0 -> resistance 330 ohms -> anode, cathode -> masse.
 *
 * Rythme : 5 eclairs rapides au demarrage (RESET vu), puis 1 s allumee / 1 s eteinte.
 * Verification du quartz : 10 cycles complets = 20 s au chronometre. Sur l'oscillateur RC
 * interne (1 MHz d'origine), tout irait 16 fois plus lentement ; sans oscillateur, rien ne bouge.
 */
#include <avr/io.h>
#include <util/delay.h>

#define DEL (1 << PB0)

int main(void)
{
    DDRB |= DEL;

    for (uint8_t i = 0; i < 5; i++) {   /* demarrage : 5 eclairs de 100 ms */
        PORTB |= DEL;
        _delay_ms(100);
        PORTB &= ~DEL;
        _delay_ms(100);
    }
    _delay_ms(1000);

    for (;;) {                           /* 1 s allumee, 1 s eteinte */
        PORTB |= DEL;
        _delay_ms(1000);
        PORTB &= ~DEL;
        _delay_ms(1000);
    }
}
