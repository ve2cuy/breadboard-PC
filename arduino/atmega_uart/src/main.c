/*
 * Solution-02 - ATmega328P (U17), etape 1 : clignotement.
 *
 * Valide l'ATmega sur la plaquette : alimentation, RESET (tirage 10k), quartz 16 MHz
 * (fusibles lfuse FFh, hfuse D9h, efuse FDh).
 *
 * DEL sur PB5 (broche 19 du DIP-28, comme la broche 13 d'un Arduino) :
 *   PB5 -> resistance 330 ohms -> anode de la DEL, cathode -> masse.
 *
 * Rythme : 5 eclairs rapides au demarrage (RESET vu), puis 1 s allumee / 1 s eteinte.
 * Verification du quartz : 10 cycles complets = 20 s au chronometre. Avec le RC interne
 * a 8 MHz par erreur, tout irait 2 fois plus lentement ; sans oscillateur, rien ne bouge.
 */
#include <avr/io.h>
#include <util/delay.h>

#define DEL (1 << PB5)

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
