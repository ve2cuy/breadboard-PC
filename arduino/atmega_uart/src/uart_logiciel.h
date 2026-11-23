/*
 * Solution-02 - ATmega328P (U17) : UART logiciel du terminal (canal 1) sur la minuterie 1.
 * Interruptions en assembleur (uart_isr.S), decodage et remplissage en C (main.c).
 * Ce fichier est lu par le C et par l'assembleur : #define seulement hors de __ASSEMBLER__.
 *
 * Registres reserves (platformio.ini : -ffixed-r2 ... -ffixed-r10, le compilateur n'y touche
 * jamais) : a 115200 bauds, CAPT et COMPA doivent tenir ensemble dans un bit (139 cycles) ;
 * leur etat en registres leur evite empilements et acces a la memoire.
 *   r2:r3  bt        duree d'un bit (tops), copie pour COMPA
 *   r4     fr_tete   file des fronts : ecrit par CAPT
 *   r5     tx_n      bits restant a poser dans la trame (COMPA ; la boucle principale, sous cli)
 *   r6     tx_sh     bits de donnees restants, poids faible d'abord (idem)
 *   r7     -         SREG pendant CAPT / COMPA (elles ne s'imbriquent jamais)
 *   r8:r9  -         travail de CAPT / COMPA
 *   r10    fr_queue  file des fronts : ecrit par la boucle principale
 */
#ifndef UART_LOGICIEL_H
#define UART_LOGICIEL_H

#define FR_N    32      /* fronts de la ligne RX en attente de decodage (puissance de 2) */
#define EM_N    2       /* octets prets a emettre (puissance de 2 ; CTS respecte a 1 octet pres) */
#define TX_BITS 9       /* tx_n au debut d'une trame : 8 donnees + l'arret */

/* TCCR1A : la comparaison A met OC1A a 1 / a 0 (mode normal ; OC1B deconnecte : PB2 = SS) */
#define OC1A_UN         0xC0
#define OC1A_ZERO       0x80

#ifndef __ASSEMBLER__
#include <stdint.h>

/* registres reserves, lus et ecrits par asm volatile (jamais gardes en cache par le C) */
#define REG_LIT(r)      ({ uint8_t v_; __asm__ volatile ("mov %0, " r : "=r" (v_)); v_; })
#define REG_ECRIT(r, v) __asm__ volatile ("mov " r ", %0" :: "r" ((uint8_t)(v)))
#define FR_TETE()       REG_LIT("r4")
#define FR_QUEUE()      REG_LIT("r10")
#define FR_QUEUE_ECRIT(v) REG_ECRIT("r10", v)

/* fronts : date (tops de la minuterie 1, bit 0 force) | niveau de la ligne apres le front */
extern volatile uint16_t fr[FR_N];
extern volatile uint8_t fr_perdu;

/* emission : file d'octets (boucle principale -> interruption), etat de la ligne */
extern volatile uint8_t em[EM_N];
extern volatile uint8_t em_tete, em_queue;
extern volatile uint8_t tx_actif;
extern volatile uint16_t tx_fin;        /* fin du bit d'arret de la derniere trame */
#endif

#endif
