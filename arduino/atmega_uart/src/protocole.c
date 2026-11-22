/*
 * Solution-02 - ATmega328P (U17) : protocole SPI et tampons de l'UART (voir protocole.h).
 * Aucun registre de l'AVR ici : tout est appele depuis les interruptions (jamais imbriquees
 * sur l'AVR), donc sans protection supplementaire.
 */
#include "protocole.h"

volatile uint8_t p_irq;
volatile uint8_t p_rts;
volatile uint8_t p_cts;
volatile uint8_t p_vitesse;
volatile uint8_t p_vit_courante;

static uint8_t rx[P_RX_TAILLE];
static uint8_t tx[P_TX_TAILLE];
static uint16_t rx_tete, rx_nb, tx_tete, tx_nb;
static uint8_t drapeaux;

enum { E_CMD, E_IDENT, E_ETAT, E_LIRE, E_ECRIRE_F, E_ECRIRE, E_VITESSE, E_VIDER, E_IGNORE };
static uint8_t etat, k, n_lire, lus, donnee_chargee, en_transaction;
static uint8_t instantane[5];

static void maj_irq(void)
{
    p_irq = (rx_nb != 0 && !en_transaction);
}

static void vider(void)
{
    rx_tete = rx_nb = tx_tete = tx_nb = 0;
    drapeaux = 0;
    p_rts = 1;
    maj_irq();
}

void p_init(void)
{
    vider();
    p_cts = 1;
    p_vitesse = P_V_AUCUNE;
    p_vit_courante = P_V_9600;
    etat = E_CMD;
    en_transaction = 0;
    donnee_chargee = 0;
    maj_irq();
}

uint16_t p_rx_nb(void) { return rx_nb; }
uint16_t p_tx_nb(void) { return tx_nb; }

static uint8_t min255(uint16_t v) { return v > 255 ? 255 : (uint8_t)v; }

/* ------------------------------------------------------------------ SPI */
void p_ss_debut(void)
{
    en_transaction = 1;
    etat = E_CMD;
    donnee_chargee = 0;
    maj_irq();
}

uint8_t p_ss_fin(void)
{
    en_transaction = 0;
    etat = E_CMD;
    donnee_chargee = 0;         /* octet prepare mais pas transmis : il reste dans le tampon */
    maj_irq();
    return P_SIGNATURE;
}

static uint8_t charger_donnee(void)
{
    if (lus < n_lire && rx_nb) {
        lus++;
        donnee_chargee = 1;
        return rx[rx_tete];
    }
    return 0;
}

uint8_t p_spi(uint8_t recu)
{
    if (donnee_chargee) {       /* l'octet prepare vient d'etre transmis : il quitte le tampon */
        donnee_chargee = 0;
        rx_tete = (rx_tete + 1) & (P_RX_TAILLE - 1);
        rx_nb--;
        if (rx_nb <= P_RX_BAS)
            p_rts = 1;
    }
    switch (etat) {
    case E_CMD:
        k = 0;
        switch (recu) {
        case P_IDENT:
            etat = E_IDENT;
            return 'S';
        case P_ETAT:
            instantane[0] = (uint8_t)rx_nb;
            instantane[1] = (uint8_t)(rx_nb >> 8);
            instantane[2] = (uint8_t)(P_TX_TAILLE - tx_nb);
            instantane[3] = (uint8_t)((P_TX_TAILLE - tx_nb) >> 8);
            instantane[4] = drapeaux | (p_cts ? P_ETAT_CTS : 0) | (p_rts ? P_ETAT_RTS : 0);
            drapeaux = 0;
            etat = E_ETAT;
            return instantane[0];
        case P_LIRE:
            n_lire = min255(rx_nb);
            lus = 0;
            etat = E_LIRE;
            return n_lire;
        case P_ECRIRE:
            etat = E_ECRIRE_F;
            return min255(P_TX_TAILLE - tx_nb);
        case P_VITESSE:
            etat = E_VITESSE;
            return 0;
        case P_VIDER:
            etat = E_VIDER;
            return 0;
        default:
            etat = E_IGNORE;
            return 0;
        }
    case E_IDENT:
        k++;
        return k == 1 ? '2' : k == 2 ? P_VERSION : k == 3 ? p_vit_courante : 0;
    case E_ETAT:
        k++;
        return k < 5 ? instantane[k] : 0;
    case E_LIRE:
        return charger_donnee();
    case E_ECRIRE_F:            /* octet de remplissage pendant lequel la place libre est partie */
        etat = E_ECRIRE;
        return 0;
    case E_ECRIRE:
        if (tx_nb < P_TX_TAILLE) {
            tx[(tx_tete + tx_nb) & (P_TX_TAILLE - 1)] = recu;
            tx_nb++;
        } else {
            drapeaux |= P_ETAT_TX_PLEIN;
        }
        return 0;
    case E_VITESSE:
        if (recu < P_V_NB)
            p_vitesse = recu;
        etat = E_IGNORE;
        return 0;
    case E_VIDER:
        if (recu == P_SIGNATURE)
            vider();
        etat = E_IGNORE;
        return 0;
    default:
        return 0;
    }
}

/* ------------------------------------------------------------------ UART */
void p_uart_recu(uint8_t octet, uint8_t erreur)
{
    if (erreur)
        drapeaux |= P_ETAT_UART_ERR;
    if (rx_nb < P_RX_TAILLE) {
        rx[(rx_tete + rx_nb) & (P_RX_TAILLE - 1)] = octet;
        rx_nb++;
        if (rx_nb >= P_RX_HAUT)
            p_rts = 0;
    } else {
        drapeaux |= P_ETAT_RX_PLEIN;
    }
    maj_irq();
}

int16_t p_uart_a_emettre(void)
{
    uint8_t b;
    if (!tx_nb)
        return -1;
    b = tx[tx_tete];
    tx_tete = (tx_tete + 1) & (P_TX_TAILLE - 1);
    tx_nb--;
    return b;
}
