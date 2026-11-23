/*
 * Solution-02 - ATmega328P (U17) : deux UART pour le 8088, esclave SPI.
 *   canal 1 = terminal (J5, UART logiciel PB0/PB1, RTS/CTS sur J8), IRQ vers IR4 ;
 *   canal 2 = module Grove - UART WiFi V2 (J13, USART materiel PD0/PD1, 115200 bauds).
 * Protocole (independant du materiel : teste sur le PC, voir test/test_protocole.c).
 *
 * Transaction : SS (U12 PC0) a 0, un octet de commande, des octets de donnees, SS a 1.
 * SPI mode 0, poids fort en premier. L'octet que le 8088 recoit pendant l'octet n est
 * celui que l'ATmega a prepare a la fin de l'octet n-1 (au moins 10 us entre deux octets).
 *
 * Pendant l'octet de commande, le 8088 recoit toujours P_SIGNATURE (A5h) : sans ATmega,
 * il lit FFh (tirage R20 sur MISO).
 *
 * Commande = canal (bit 4 : 0 = terminal, 1 = Wi-Fi) + operation (bits 0-3). Les commandes
 * du canal 1 sont celles de la version 2 : un BIOS 2.7 / 2.8 fonctionne tel quel.
 *   00h IDENT    -> 'S', '2', P_VERSION, vitesse du canal 1, vitesse du canal 2 (version 3),
 *                   puis 00h
 *   01h ETAT     -> nb recus (poids faible, poids fort), place libre en emission (poids
 *                   faible, poids fort), drapeaux (P_ETAT_*, remis a 0 par cette lecture)
 *   02h LIRE     -> n = min(recus, 255), puis n octets recus. Un octet ne quitte le tampon
 *                   qu'une fois entierement transmis : SS a 1 plus tot = rien de perdu.
 *   03h ECRIRE   -> f = min(place libre, 255) pendant le 1er octet suivant (ignore), puis
 *                   chaque octet envoye par le 8088 va dans le tampon d'emission. Au-dela de
 *                   la place libre : perdu, P_ETAT_TX_PLEIN.
 *   04h VITESSE  -> octet suivant = P_V_* ; appliquee quand l'emission en cours est finie.
 *   05h VIDER    -> octet suivant = A5h (confirmation) : tampons vides, drapeaux a 0.
 *   11h-15h      -> ETAT, LIRE, ECRIRE, VITESSE, VIDER du canal 2 (Wi-Fi). Pas de RTS/CTS
 *                   sur ce canal : ETAT2 les rend toujours actifs.
 *   autre        -> ignoree (00h).
 *
 * IRQ (PD2 -> IR4 du 8259, front montant) : 1 quand un octet recu du TERMINAL attend et
 * qu'aucune transaction n'est en cours. Elle tombe au debut de chaque transaction et remonte
 * a la fin s'il reste des octets. Le canal 2 se lit par scrutation (ETAT2 / LIRE2).
 * RTS (PD6, actif a 0, canal 1) : retire a P_RX_HAUT octets en attente, rendu a P_RX_BAS.
 */
#ifndef PROTOCOLE_H
#define PROTOCOLE_H

#include <stdint.h>

#define P_VERSION       3
#define P_SIGNATURE     0xA5

#define P_IDENT         0x00
#define P_ETAT          0x01
#define P_LIRE          0x02
#define P_ECRIRE        0x03
#define P_VITESSE       0x04
#define P_VIDER         0x05
#define P_CANAL2        0x10            /* + P_ETAT ... P_VIDER : canal 2 (Wi-Fi) */

/* drapeaux d'ETAT */
#define P_ETAT_RX_PLEIN 0x01    /* octet recu perdu : tampon de reception plein */
#define P_ETAT_UART_ERR 0x02    /* erreur de trame ou octet ecrase dans l'UART */
#define P_ETAT_TX_PLEIN 0x04    /* octet a emettre perdu : tampon d'emission plein */
#define P_ETAT_CTS      0x40    /* CTS actif : le terminal accepte des octets */
#define P_ETAT_RTS      0x80    /* RTS actif : l'ATmega accepte des octets */

/* vitesses (VITESSE) */
#define P_V_9600        0
#define P_V_19200       1
#define P_V_38400       2
#define P_V_57600       3
#define P_V_115200      4
#define P_V_4800        5
#define P_V_2400        6
#define P_V_NB          7
#define P_V_AUCUNE      0xFF

#define P_V1_DEFAUT     P_V_57600       /* terminal, a la mise sous tension */
#define P_V2_DEFAUT     P_V_115200      /* module Wi-Fi (micrologiciel AT) */

/* tampons (puissances de 2 ; 2 Ko de RAM en tout) */
#define P_RX_TAILLE     512             /* canal 1 */
#define P_TX_TAILLE     64
#define P_RX_HAUT       384
#define P_RX_BAS        128
#define P2_RX_TAILLE    1024            /* canal 2 : sans controle de flux, le plus grand */
#define P2_TX_TAILLE    128

/* sorties lues par le code du materiel */
extern volatile uint8_t p_irq;          /* niveau de la ligne IRQ */
extern volatile uint8_t p_rts;          /* 1 = RTS actif (broche a 0) */
extern volatile uint8_t p_cts;          /* entree : 1 = CTS actif (fourni par le materiel) */
extern volatile uint8_t p_vitesse;      /* canal 1 : vitesse demandee, P_V_AUCUNE sinon */
extern volatile uint8_t p_vit_courante; /* canal 1 : vitesse en service, tenue par le materiel */
extern volatile uint8_t p2_vitesse;     /* canal 2 : idem */
extern volatile uint8_t p2_vit_courante;

void p_init(void);

/* SPI : appelees depuis les interruptions */
void p_ss_debut(void);                  /* SS passe a 0 */
uint8_t p_ss_fin(void);                 /* SS passe a 1 ; rend l'octet a precharger */
uint8_t p_spi(uint8_t recu);            /* octet echange ; rend l'octet suivant a emettre */

/* UART : canal 1 (terminal) */
void p_uart_recu(uint8_t octet, uint8_t erreur);
int16_t p_uart_a_emettre(void);         /* octet suivant a emettre, -1 si rien */
uint16_t p_rx_nb(void);
uint16_t p_tx_nb(void);

/* UART : canal 2 (Wi-Fi) */
void p2_uart_recu(uint8_t octet, uint8_t erreur);
int16_t p2_uart_a_emettre(void);
uint16_t p2_rx_nb(void);
uint16_t p2_tx_nb(void);

#endif
