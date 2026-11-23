/*
 * Essais du protocole de l'ATmega (src/protocole.c) sur le PC : le 8088 maitre est simule
 * octet par octet (ce qui sort sur MISO pendant l'octet n = ce que l'ATmega a prepare a la
 * fin de l'octet n-1, ou a la fin de la transaction precedente pour l'octet de commande).
 *
 *   make test   (gcc de WSL)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/protocole.h"

static int echecs, essais;
static uint8_t prepare = P_SIGNATURE;  /* octet charge dans SPDR */

#define VERIFIE(c, ...) do { essais++; if (!(c)) { echecs++; printf("ECHEC %s:%d : ", __FILE__, __LINE__); \
    printf(__VA_ARGS__); printf("\n"); } } while (0)

/* une transaction : SS a 0, n octets envoyes (mosi), recus (miso), SS a 1 */
static void transaction(const uint8_t *mosi, uint8_t *miso, int n)
{
    p_ss_debut();
    VERIFIE(p_irq == 0, "IRQ doit tomber au debut d'une transaction");
    for (int i = 0; i < n; i++) {
        miso[i] = prepare;
        prepare = p_spi(mosi[i]);
    }
    prepare = p_ss_fin();
}

static void recevoir(const char *s)
{
    while (*s)
        p_uart_recu((uint8_t)*s++, 0);
}

/* ETAT : rend nb recus, place libre, drapeaux */
static void etat(uint16_t *rx, uint16_t *libre, uint8_t *dr)
{
    uint8_t o[6] = { P_ETAT }, r[6];
    transaction(o, r, 6);
    VERIFIE(r[0] == P_SIGNATURE, "signature %02X", r[0]);
    *rx = r[1] | r[2] << 8;
    *libre = r[3] | r[4] << 8;
    *dr = r[5];
}

/* LIRE : lit n, puis au plus max octets ; rend le nombre lu */
static int lire(uint8_t *dst, int max, int *n_annonce)
{
    uint8_t o[260] = { P_LIRE }, r[260];
    p_ss_debut();
    r[0] = prepare;
    prepare = p_spi(o[0]);
    r[1] = prepare;
    prepare = p_spi(0);
    int n = r[1], lu = 0;
    *n_annonce = n;
    for (int i = 0; i < n && i < max; i++) {
        dst[lu++] = prepare;
        prepare = p_spi(0);
    }
    prepare = p_ss_fin();
    return lu;
}

static void ecrire(const char *s, uint8_t *libre)
{
    uint8_t o[600] = { P_ECRIRE, 0 }, r[600];
    int n = (int)strlen(s);
    memcpy(o + 2, s, n);
    transaction(o, r, n + 2);
    *libre = r[1];
}

static void raz(void)
{
    p_init();
    prepare = P_SIGNATURE;
}

int main(void)
{
    uint8_t r[16], buf[1100];
    uint16_t rx, libre;
    uint8_t dr;
    int n, lu;

    /* 1. signature et IDENT */
    raz();
    {
        uint8_t o[7] = { P_IDENT, 0, 0, 0, 0, 0, 0 };
        transaction(o, r, 7);
        VERIFIE(r[0] == 0xA5 && r[1] == 'S' && r[2] == '2' && r[3] == 4 && r[4] == P_V_57600
                && r[5] == P_V_115200 && r[6] == 0,
                "IDENT : %02X %02X %02X %02X %02X %02X %02X", r[0], r[1], r[2], r[3], r[4], r[5], r[6]);
        p_vit_courante = P_V_115200;    /* vitesses en service rendues par IDENT (version 3) */
        p2_vit_courante = P_V_9600;
        transaction(o, r, 7);
        VERIFIE(r[4] == P_V_115200 && r[5] == P_V_9600, "IDENT : vitesses courantes %02X %02X", r[4], r[5]);
    }

    /* 2. reception, IRQ, ETAT, LIRE */
    raz();
    VERIFIE(p_irq == 0, "IRQ au repos");
    recevoir("abc");
    VERIFIE(p_irq == 1, "IRQ apres reception");
    etat(&rx, &libre, &dr);
    VERIFIE(rx == 3 && libre == P_TX_TAILLE, "ETAT rx=%u libre=%u", rx, libre);
    VERIFIE(dr == (P_ETAT_CTS | P_ETAT_RTS), "drapeaux %02X", dr);
    VERIFIE(p_irq == 1, "IRQ remonte apres ETAT (octets en attente)");
    lu = lire(buf, 255, &n);
    VERIFIE(n == 3 && lu == 3 && !memcmp(buf, "abc", 3), "LIRE n=%d lu=%d", n, lu);
    VERIFIE(p_rx_nb() == 0 && p_irq == 0, "tampon vide, IRQ a 0");

    /* 3. lecture partielle : rien de perdu, rien en double */
    raz();
    recevoir("ABCDE");
    lu = lire(buf, 2, &n);
    VERIFIE(n == 5 && lu == 2 && !memcmp(buf, "AB", 2), "partielle 1");
    VERIFIE(p_rx_nb() == 3 && p_irq == 1, "reste 3, IRQ remonte (nb=%u)", p_rx_nb());
    lu = lire(buf, 255, &n);
    VERIFIE(n == 3 && lu == 3 && !memcmp(buf, "CDE", 3), "partielle 2 : %.*s", lu, buf);

    /* 4. octet recu pendant une transaction : IRQ seulement a la fin */
    raz();
    p_ss_debut();
    prepare = p_spi(P_ETAT);
    recevoir("x");
    VERIFIE(p_irq == 0, "pas d'IRQ pendant la transaction");
    prepare = p_ss_fin();
    VERIFIE(p_irq == 1, "IRQ a la fin de la transaction");

    /* 5. ECRIRE puis emission */
    raz();
    {
        uint8_t f;
        ecrire("hello", &f);
        VERIFIE(f == (P_TX_TAILLE > 255 ? 255 : P_TX_TAILLE), "place annoncee %u", f);
        char e[8] = { 0 };
        for (int i = 0; i < 5; i++)
            e[i] = (char)p_uart_a_emettre();
        VERIFIE(!strcmp(e, "hello") && p_uart_a_emettre() == -1, "emis '%s'", e);
    }

    /* 6. tampon d'emission plein */
    raz();
    {
        uint8_t f;
        static char gros[P_TX_TAILLE + 11];
        memset(gros, 'z', sizeof gros - 1);
        gros[sizeof gros - 1] = 0;
        ecrire(gros, &f);
        VERIFIE(p_tx_nb() == P_TX_TAILLE, "tx plein %u", p_tx_nb());
        etat(&rx, &libre, &dr);
        VERIFIE(libre == 0 && (dr & P_ETAT_TX_PLEIN), "TX_PLEIN libre=%u dr=%02X", libre, dr);
        etat(&rx, &libre, &dr);
        VERIFIE(!(dr & P_ETAT_TX_PLEIN), "drapeau remis a 0 par ETAT");
    }

    /* 7. reception : RTS, debordement */
    raz();
    for (int i = 0; i < P_RX_HAUT - 1; i++)
        p_uart_recu((uint8_t)i, 0);
    VERIFIE(p_rts == 1, "RTS encore actif a %d", P_RX_HAUT - 1);
    p_uart_recu(0, 0);
    VERIFIE(p_rts == 0, "RTS retire a %d", P_RX_HAUT);
    for (int i = 0; i < P_RX_TAILLE - P_RX_HAUT + 3; i++)
        p_uart_recu(0, 0);
    VERIFIE(p_rx_nb() == P_RX_TAILLE, "tampon plein");
    etat(&rx, &libre, &dr);
    VERIFIE(rx == P_RX_TAILLE && (dr & P_ETAT_RX_PLEIN) && !(dr & P_ETAT_RTS), "RX_PLEIN dr=%02X", dr);
    while (p_rx_nb() - 255 > P_RX_BAS + 1) {
        lire(buf, 255, &n);
        VERIFIE(p_rts == 0, "RTS toujours retire (%u)", p_rx_nb());
    }
    lire(buf, (int)p_rx_nb() - (P_RX_BAS + 1), &n);
    VERIFIE(p_rx_nb() == P_RX_BAS + 1 && p_rts == 0, "RTS retire a %d (%u)", P_RX_BAS + 1, p_rx_nb());
    lire(buf, 1, &n);
    VERIFIE(p_rx_nb() == P_RX_BAS && p_rts == 1, "RTS rendu a %d (%u)", P_RX_BAS, p_rx_nb());

    /* 8. ordre des octets sur un tour complet du tampon circulaire */
    raz();
    {
        int envoye = 0, attendu = 0, bon = 1;
        for (int tour = 0; tour < 20; tour++) {
            for (int i = 0; i < 300; i++)
                p_uart_recu((uint8_t)(envoye++ * 7), 0);
            while (p_rx_nb()) {
                lu = lire(buf, 100, &n);
                for (int i = 0; i < lu; i++)
                    bon &= (buf[i] == (uint8_t)(attendu++ * 7));
            }
        }
        VERIFIE(bon && envoye == attendu, "ordre circulaire %d/%d", attendu, envoye);
    }

    /* 9. VIDER : seulement avec la confirmation A5h */
    raz();
    recevoir("abc");
    {
        uint8_t o[2] = { P_VIDER, 0x00 };
        transaction(o, r, 2);
        VERIFIE(p_rx_nb() == 3, "VIDER sans confirmation : rien");
        o[1] = P_SIGNATURE;
        transaction(o, r, 2);
        VERIFIE(p_rx_nb() == 0 && p_irq == 0, "VIDER confirme");
    }

    /* 10. VITESSE */
    raz();
    {
        uint8_t o[2] = { P_VITESSE, P_V_115200 };
        transaction(o, r, 2);
        VERIFIE(p_vitesse == P_V_115200, "vitesse demandee %u", p_vitesse);
        p_vitesse = P_V_AUCUNE;
        o[1] = 99;
        transaction(o, r, 2);
        VERIFIE(p_vitesse == P_V_AUCUNE, "vitesse invalide ignoree");
    }

    /* 11. SS a 0 puis a 1 sans horloge (mot de mode du 8255) ; commande inconnue */
    raz();
    recevoir("q");
    transaction(NULL, r, 0);
    VERIFIE(p_rx_nb() == 1 && p_irq == 1, "SS sans octet : rien ne change");
    {
        uint8_t o[4] = { 0x7E, 1, 2, 3 };
        transaction(o, r, 4);
        VERIFIE(r[0] == 0xA5 && r[1] == 0 && r[2] == 0 && r[3] == 0 && p_rx_nb() == 1, "commande inconnue");
    }

    /* 12. erreur de l'USART */
    raz();
    p_uart_recu('e', 1);
    etat(&rx, &libre, &dr);
    VERIFIE(rx == 1 && (dr & P_ETAT_UART_ERR), "UART_ERR dr=%02X", dr);

    /* 13. canal 2 (Wi-Fi) : independant du canal 1, pas d'IRQ ni de RTS */
    raz();
    p2_uart_recu('O', 0);
    p2_uart_recu('K', 0);
    VERIFIE(p_irq == 0 && p_rx_nb() == 0 && p2_rx_nb() == 2, "canal 2 : pas d'IRQ, rien au canal 1");
    {
        uint8_t o[6] = { P_CANAL2 | P_ETAT }, q[8];
        transaction(o, q, 6);
        VERIFIE(q[1] == 2 && q[2] == 0 && (q[3] | q[4] << 8) == P2_TX_TAILLE
                && q[5] == (P_ETAT_CTS | P_ETAT_RTS), "ETAT2 %02X %02X %02X %02X %02X", q[1], q[2], q[3], q[4], q[5]);
        recevoir("t");
        uint8_t l[5] = { P_CANAL2 | P_LIRE, 0, 0, 0, 0 };
        transaction(l, q, 5);
        VERIFIE(q[1] == 2 && q[2] == 'O' && q[3] == 'K' && q[4] == 0, "LIRE2 %02X '%c%c'", q[1], q[2], q[3]);
        VERIFIE(p2_rx_nb() == 0 && p_rx_nb() == 1 && p_irq == 1, "LIRE2 laisse le canal 1");
        uint8_t e[6] = { P_CANAL2 | P_ECRIRE, 0, 'A', 'T', 13, 10 };
        transaction(e, q, 6);
        VERIFIE(q[1] == (P2_TX_TAILLE > 255 ? 255 : P2_TX_TAILLE), "ECRIRE2 place %u", q[1]);
        VERIFIE(p2_tx_nb() == 4 && p_tx_nb() == 0, "ECRIRE2 : 4 octets au canal 2");
        char t[5] = { 0 };
        for (int i = 0; i < 4; i++)
            t[i] = (char)p2_uart_a_emettre();
        VERIFIE(!strcmp(t, "AT\r\n") && p2_uart_a_emettre() == -1, "emis au module");
        uint8_t v[2] = { P_CANAL2 | P_VITESSE, P_V_9600 };
        transaction(v, q, 2);
        VERIFIE(p2_vitesse == P_V_9600 && p_vitesse == P_V_AUCUNE, "VITESSE2");
        for (int i = 0; i < P2_RX_TAILLE + 2; i++)
            p2_uart_recu((uint8_t)i, 0);
        VERIFIE(p2_rx_nb() == P2_RX_TAILLE && p_rts == 1, "canal 2 plein, RTS du canal 1 intact");
        transaction(o, q, 6);
        VERIFIE((q[1] | q[2] << 8) == P2_RX_TAILLE && (q[5] & P_ETAT_RX_PLEIN), "RX_PLEIN au canal 2");
        uint8_t z[2] = { P_CANAL2 | P_VIDER, P_SIGNATURE };
        transaction(z, q, 2);
        VERIFIE(p2_rx_nb() == 0 && p_rx_nb() == 1, "VIDER2 laisse le canal 1");
        uint8_t i6[2] = { 0x16, 0 };
        transaction(i6, q, 2);
        VERIFIE(q[1] == 0, "16h inconnue");
    }

    /* 14. PONT (version 4) : seulement avec A5h ; les octets passent d'un canal a l'autre */
    raz();
    {
        uint8_t o[2] = { P_PONT, 0x00 }, q[4];
        transaction(o, q, 2);
        VERIFIE(p_pont == 0, "PONT sans confirmation : rien");
        o[1] = P_SIGNATURE;
        transaction(o, q, 2);
        VERIFIE(p_pont == 1, "PONT active");
        VERIFIE(p_pont_vers_module('x') == 1 && p2_tx_nb() == 1 && p2_uart_a_emettre() == 'x',
                "pont : terminal -> module");
        VERIFIE(p_pont_vers_terminal('y') == 1 && p_tx_nb() == 1 && p_uart_a_emettre() == 'y',
                "pont : module -> terminal");
        for (int i = 0; i < P2_TX_TAILLE; i++)
            p_pont_vers_module((uint8_t)i);
        VERIFIE(p_pont_vers_module(0) == 0, "pont : tampon du module plein");
        uint8_t e[6] = { P_CANAL2 | P_ETAT }, f[6];
        transaction(e, f, 6);
        VERIFIE(f[5] & P_ETAT_TX_PLEIN, "pont : perte signalee (%02X)", f[5]);
        o[1] = 0;
        transaction(o, q, 2);
        VERIFIE(p_pont == 0, "PONT termine");
    }

    printf("%d essais, %d echecs\n", essais, echecs);
    return echecs != 0;
}
