; Solution-02 - ATmega328P (U17) : interruptions de l'UART logiciel du terminal (minuterie 1).
; En assembleur pour etre courtes : a 115200 bauds un bit dure 139 cycles, et chacune doit
; passer avant l'evenement suivant (front ou bit). Voir uart_logiciel.h et main.c.
;
;   CAPT  : front sur RX (PB0 = ICP1) : date figee par le materiel (ICR1) ; on inverse le front
;           attendu, puis on range date|niveau dans fr[] pour la boucle principale.
;   COMPA : debut d'un bit sur TX (PB1 = OC1A) : le materiel vient de poser le niveau choisi ;
;           on choisit celui du bit suivant (COM1A1:0) et sa date (OCR1A += bt).
;   SPI, PCINT0 : entrees des interruptions du 8088 (corps en C, main.c) : SPI et PCINT
;           masques puis interruptions rendues (sei) AVANT de sauver les registres.
;
; CAPT et COMPA gardent leur etat dans des registres reserves (uart_logiciel.h) et n'utilisent
; pas r1 (pas forcement nul dans une interruption). Elles ne s'imbriquent jamais (I = 0) :
; r7 (SREG) et r8:r9 leur servent a toutes deux sans sauvegarde.

#include <avr/io.h>
#include "uart_logiciel.h"

        .section .bss
        .global fr, fr_perdu, em, em_tete, em_queue, tx_actif, tx_fin
fr:         .skip   2 * FR_N
fr_perdu:   .skip   1
em:         .skip   EM_N
em_tete:    .skip   1
em_queue:   .skip   1
tx_actif:   .skip   1
tx_fin:     .skip   2

        .section .text

; ------------------------------------------------------------------ TIMER1_CAPT
; ~45 cycles. Le front inverse est arme ~15 cycles apres l'entree.
        .global TIMER1_CAPT_vect
TIMER1_CAPT_vect:
        in      r7, _SFR_IO_ADDR(SREG)
        push    r30
        push    r31
        lds     r8, _SFR_MEM_ADDR(ICR1L)        ; (poids faible d'abord)
        lds     r9, _SFR_MEM_ADDR(ICR1H)
        lds     r30, _SFR_MEM_ADDR(TCCR1B)
        ldi     r31, (1 << ICES1)
        eor     r31, r30
        sts     _SFR_MEM_ADDR(TCCR1B), r31      ; front inverse ensuite
        ldi     r31, (1 << ICF1)
        out     _SFR_IO_ADDR(TIFR1), r31        ; (changer de front peut lever ICF1)
        bst     r30, ICES1                      ; front montant : ligne a 1
        bld     r8, 0                           ; date | niveau
        mov     r30, r4                         ; fr[fr_tete] (r4)
        lsl     r30
        ldi     r31, 0
        subi    r30, lo8(-(fr))
        sbci    r31, hi8(-(fr))
        st      Z+, r8
        st      Z, r9
        mov     r30, r4
        inc     r30
        andi    r30, FR_N - 1
        cp      r30, r10                        ; fr_queue (r10) : file pleine ?
        breq    1f
        mov     r4, r30
2:      pop     r31
        pop     r30
        out     _SFR_IO_ADDR(SREG), r7
        reti
1:      ldi     r30, 1                          ; front perdu
        sts     fr_perdu, r30
        rjmp    2b

; ------------------------------------------------------------------ TIMER1_COMPA
; ~35 cycles par bit (r5 = tx_n, r6 = tx_sh, r2:r3 = bt).
        .global TIMER1_COMPA_vect
TIMER1_COMPA_vect:
        in      r7, _SFR_IO_ADDR(SREG)
        push    r30
        tst     r5
        breq    .Larret                         ; le bit d'arret commence
        dec     r5
        ldi     r30, OC1A_UN                    ; tx_n devenu 0 : bit d'arret (a 1)
        breq    .Lpose
        sbrs    r6, 0
        ldi     r30, OC1A_ZERO
        lsr     r6
.Lpose: sts     _SFR_MEM_ADDR(TCCR1A), r30
.Lavance:                                       ; OCR1A += bt
        lds     r8, _SFR_MEM_ADDR(OCR1AL)
        lds     r9, _SFR_MEM_ADDR(OCR1AH)
        add     r8, r2
        adc     r9, r3
        sts     _SFR_MEM_ADDR(OCR1AH), r9       ; (poids fort d'abord)
        sts     _SFR_MEM_ADDR(OCR1AL), r8
.Lfin:  pop     r30
        out     _SFR_IO_ADDR(SREG), r7
        reti

.Larret:                                        ; octet suivant deja pret : trame collee
        push    r31
        lds     r30, em_queue
        lds     r31, em_tete
        cp      r30, r31
        breq    .Lrepos
        mov     r8, r30
        ldi     r31, 0
        subi    r30, lo8(-(em))
        sbci    r31, hi8(-(em))
        ld      r6, Z                           ; tx_sh
        mov     r30, r8
        inc     r30
        andi    r30, EM_N - 1
        sts     em_queue, r30
        ldi     r30, TX_BITS
        mov     r5, r30                         ; tx_n
        ldi     r30, OC1A_ZERO                  ; bit de depart, apres l'arret
        sts     _SFR_MEM_ADDR(TCCR1A), r30
        pop     r31
        rjmp    .Lavance

.Lrepos:                                        ; rien a emettre : tx_fin = fin de l'arret
        lds     r8, _SFR_MEM_ADDR(OCR1AL)
        lds     r9, _SFR_MEM_ADDR(OCR1AH)
        add     r8, r2
        adc     r9, r3
        sts     tx_fin, r8
        sts     tx_fin + 1, r9
        lds     r30, _SFR_MEM_ADDR(TIMSK1)
        andi    r30, ~(1 << OCIE1A)
        sts     _SFR_MEM_ADDR(TIMSK1), r30
        ldi     r30, 0
        sts     tx_actif, r30
        pop     r31
        rjmp    .Lfin

; ------------------------------------------------------------------ SPI_STC, PCINT0
; Entree commune : masquer SPI (SPCR = SPE) et PCINT (PCICR = 0), sei, puis sauver les
; registres que le C peut detruire, r1 = 0, appeler le corps ; sortie : cli, demasquer, reti.
.macro ENTREE_8088 corps
        push    r24
        in      r24, _SFR_IO_ADDR(SREG)
        push    r24
        ldi     r24, (1 << SPE)
        out     _SFR_IO_ADDR(SPCR), r24
        ldi     r24, 0
        sts     _SFR_MEM_ADDR(PCICR), r24
        sei
        push    r0
        push    r1
        clr     r1
        push    r18
        push    r19
        push    r20
        push    r21
        push    r22
        push    r23
        push    r25
        push    r26
        push    r27
        push    r30
        push    r31
        call    \corps
        pop     r31
        pop     r30
        pop     r27
        pop     r26
        pop     r25
        pop     r23
        pop     r22
        pop     r21
        pop     r20
        pop     r19
        pop     r18
        pop     r1
        pop     r0
        cli
        ldi     r24, (1 << PCIE0)
        sts     _SFR_MEM_ADDR(PCICR), r24
        ldi     r24, (1 << SPE) | (1 << SPIE)
        out     _SFR_IO_ADDR(SPCR), r24
        pop     r24
        out     _SFR_IO_ADDR(SREG), r24
        pop     r24
        reti
.endm

        .global SPI_STC_vect
SPI_STC_vect:
        ENTREE_8088 spi_corps

        .global PCINT0_vect
PCINT0_vect:
        ENTREE_8088 ss_corps
