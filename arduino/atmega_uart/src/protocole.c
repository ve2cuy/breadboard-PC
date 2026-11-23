/*
 * Solution-02 - ATmega328P (U17) : protocole SPI et tampons des deux UART (voir protocole.h).
 * Aucun registre de l'AVR ici. Ces fonctions sont appelees par les interruptions SPI et
 * PCINT, et par la boucle principale ; le code du materiel garantit qu'elles ne s'executent
 * jamais en meme temps (main.c : interruptions SPI et PCINT masquees pendant les appels de la
 * boucle principale ; elles se masquent l'une l'autre).
 */
#include "protocole.h"

volatile uint8_t p_irq;
volatile uint8_t p_rts;
volatile uint8_t p_cts;
volatile uint8_t p_vitesse;
volatile uint8_t p_vit_courante;
volatile uint8_t p2_vitesse;
volatile uint8_t p2_vit_courante;
volatile uint8_t p_pont;

typedef struct {
    uint8_t *rx, *tx;
    uint16_t rx_masque, tx_masque;      /* taille - 1 */
    uint16_t rx_tete, rx_nb, tx_tete, tx_nb;
    uint8_t drapeaux;
} canal_t;

static uint8_t rx1[P_RX_TAILLE], tx1[P_TX_TAILLE];
static uint8_t rx2[P2_RX_TAILLE], tx2[P2_TX_TAILLE];
static canal_t can[2] = {
    { rx1, tx1, P_RX_TAILLE - 1, P_TX_TAILLE - 1, 0, 0, 0, 0, 0 },
    { rx2, tx2, P2_RX_TAILLE - 1, P2_TX_TAILLE - 1, 0, 0, 0, 0, 0 },
};

enum { E_CMD, E_IDENT, E_ETAT, E_LIRE, E_ECRIRE_F, E_ECRIRE, E_VITESSE, E_VIDER, E_PONT, E_IGNORE };
static uint8_t etat, k, n_lire, lus, donnee_chargee, en_transaction;
static canal_t *c;                      /* canal de la transaction en cours */
static uint8_t instantane[5];

static void maj_irq(void)
{
    p_irq = (can[0].rx_nb != 0 && !en_transaction);
}

static void vider(canal_t *x)
{
    x->rx_tete = x->rx_nb = x->tx_tete = x->tx_nb = 0;
    x->drapeaux = 0;
    if (x == &can[0])
        p_rts = 1;
    maj_irq();
}

void p_init(void)
{
    vider(&can[0]);
    vider(&can[1]);
    p_cts = 1;
    p_vitesse = p2_vitesse = P_V_AUCUNE;
    p_vit_courante = P_V1_DEFAUT;
    p_pont = 0;
    p2_vit_courante = P_V2_DEFAUT;
    etat = E_CMD;
    c = &can[0];
    en_transaction = 0;
    donnee_chargee = 0;
    maj_irq();
}

uint16_t p_rx_nb(void) { return can[0].rx_nb; }
uint16_t p_tx_nb(void) { return can[0].tx_nb; }
uint16_t p2_rx_nb(void) { return can[1].rx_nb; }
uint16_t p2_tx_nb(void) { return can[1].tx_nb; }

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
    if (lus < n_lire && c->rx_nb) {
        lus++;
        donnee_chargee = 1;
        return c->rx[c->rx_tete];
    }
    return 0;
}

uint8_t p_spi(uint8_t recu)
{
    if (donnee_chargee) {       /* l'octet prepare vient d'etre transmis : il quitte le tampon */
        donnee_chargee = 0;
        c->rx_tete = (c->rx_tete + 1) & c->rx_masque;
        c->rx_nb--;
        if (c == &can[0]) {
            if (c->rx_nb <= P_RX_BAS)
                p_rts = 1;
            maj_irq();
        }
    }
    switch (etat) {
    case E_CMD:
        k = 0;
        if (recu == P_IDENT) {
            etat = E_IDENT;
            return 'S';
        }
        if (recu == P_PONT) {
            etat = E_PONT;
            return 0;
        }
        if ((recu & ~P_CANAL2) < P_ETAT || (recu & ~P_CANAL2) > P_VIDER) {
            etat = E_IGNORE;
            return 0;
        }
        c = &can[(recu & P_CANAL2) ? 1 : 0];
        switch (recu & ~P_CANAL2) {
        case P_ETAT: {
            uint16_t libre = c->tx_masque + 1 - c->tx_nb;
            instantane[0] = (uint8_t)c->rx_nb;
            instantane[1] = (uint8_t)(c->rx_nb >> 8);
            instantane[2] = (uint8_t)libre;
            instantane[3] = (uint8_t)(libre >> 8);
            if (c == &can[0])
                instantane[4] = c->drapeaux | (p_cts ? P_ETAT_CTS : 0) | (p_rts ? P_ETAT_RTS : 0);
            else
                instantane[4] = c->drapeaux | P_ETAT_CTS | P_ETAT_RTS;
            c->drapeaux = 0;
            etat = E_ETAT;
            return instantane[0];
        }
        case P_LIRE:
            n_lire = min255(c->rx_nb);
            lus = 0;
            etat = E_LIRE;
            return n_lire;
        case P_ECRIRE:
            etat = E_ECRIRE_F;
            return min255(c->tx_masque + 1 - c->tx_nb);
        case P_VITESSE:
            etat = E_VITESSE;
            return 0;
        default:                /* P_VIDER */
            etat = E_VIDER;
            return 0;
        }
    case E_IDENT:
        k++;
        return k == 1 ? '2' : k == 2 ? P_VERSION : k == 3 ? p_vit_courante
             : k == 4 ? p2_vit_courante : 0;
    case E_ETAT:
        k++;
        return k < 5 ? instantane[k] : 0;
    case E_LIRE:
        return charger_donnee();
    case E_ECRIRE_F:            /* octet de remplissage pendant lequel la place libre est partie */
        etat = E_ECRIRE;
        return 0;
    case E_ECRIRE:
        if (c->tx_nb <= c->tx_masque) {
            c->tx[(c->tx_tete + c->tx_nb) & c->tx_masque] = recu;
            c->tx_nb++;
        } else {
            c->drapeaux |= P_ETAT_TX_PLEIN;
        }
        return 0;
    case E_VITESSE:
        if (recu < P_V_NB) {
            if (c == &can[0])
                p_vitesse = recu;
            else
                p2_vitesse = recu;
        }
        etat = E_IGNORE;
        return 0;
    case E_VIDER:
        if (recu == P_SIGNATURE)
            vider(c);
        etat = E_IGNORE;
        return 0;
    case E_PONT:
        p_pont = (recu == P_SIGNATURE);
        etat = E_IGNORE;
        return 0;
    default:
        return 0;
    }
}

/* ------------------------------------------------------------------ UART */
static void recu(canal_t *x, uint8_t octet, uint8_t erreur)
{
    if (erreur)
        x->drapeaux |= P_ETAT_UART_ERR;
    if (x->rx_nb <= x->rx_masque) {
        x->rx[(x->rx_tete + x->rx_nb) & x->rx_masque] = octet;
        x->rx_nb++;
    } else {
        x->drapeaux |= P_ETAT_RX_PLEIN;
    }
}

static int16_t a_emettre(canal_t *x)
{
    uint8_t b;
    if (!x->tx_nb)
        return -1;
    b = x->tx[x->tx_tete];
    x->tx_tete = (x->tx_tete + 1) & x->tx_masque;
    x->tx_nb--;
    return b;
}

void p_uart_recu(uint8_t octet, uint8_t erreur)
{
    recu(&can[0], octet, erreur);
    if (can[0].rx_nb >= P_RX_HAUT)
        p_rts = 0;
    maj_irq();
}

void p2_uart_recu(uint8_t octet, uint8_t erreur)
{
    recu(&can[1], octet, erreur);
}

int16_t p_uart_a_emettre(void) { return a_emettre(&can[0]); }
int16_t p2_uart_a_emettre(void) { return a_emettre(&can[1]); }

/* pont : l'octet va directement dans le tampon d'emission de l'autre canal */
static uint8_t a_emettre_ajoute(canal_t *x, uint8_t octet)
{
    if (x->tx_nb > x->tx_masque) {
        x->drapeaux |= P_ETAT_TX_PLEIN;
        return 0;
    }
    x->tx[(x->tx_tete + x->tx_nb) & x->tx_masque] = octet;
    x->tx_nb++;
    return 1;
}

uint8_t p_pont_vers_module(uint8_t octet) { return a_emettre_ajoute(&can[1], octet); }
uint8_t p_pont_vers_terminal(uint8_t octet) { return a_emettre_ajoute(&can[0], octet); }
