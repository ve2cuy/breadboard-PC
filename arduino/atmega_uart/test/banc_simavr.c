/*
 * Banc d'essai du micrologiciel complet (firmware.elf) sous simavr, au cycle pres :
 *  - le terminal envoie des trames sur PB0 (ICP1) a la vitesse choisie (duree de bit exacte,
 *    comme un PC) et respecte RTS (PD6) ;
 *  - l'emission du terminal (OC1A) est relevee a chaque entree dans l'interruption COMPA :
 *    OCR1A (instant de la comparaison, en tops) et COM1A1:0 (niveau pose a cet instant), ce
 *    qui fixe la ligne sur le vrai AVR ; les trames sont decodees en tops, au top pres ;
 *  - le module Wi-Fi envoie des octets a 115200 bauds sur l'USART et recoit ses emissions ;
 *  - le 8088 (maitre SPI) lit les deux canaux et renvoie chaque octet sur son canal (echo),
 *    avec les delais du 8088 autour de SS et un ecart choisi entre deux octets.
 * Reussite : chaque cote recoit exactement ce qu'il a envoye, sans erreur de trame, bits de
 * la bonne duree, aucune comparaison manquee, aucun octet SPI recharge en retard.
 *
 * Ecarts de simavr 1.6 compenses ici :
 *  - une interruption dont le drapeau est deja leve quand on la demasque (PCIE0, SPIE) n'est
 *    pas declenchee : on la declenche (le materiel le fait : requete = drapeau ET validation) ;
 *  - la broche OC1A change des l'ecriture de TCCR1A : on ne l'utilise pas (voir plus haut).
 *
 *   make banc   (WSL ; simavr extrait sans sudo, voir le Makefile)
 *   banc <firmware.elf> <code vitesse terminal> <octets> <us entre octets SPI>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sim_avr.h"
#include "sim_elf.h"
#include "sim_irq.h"
#include "sim_cycle_timers.h"
#include "sim_interrupts.h"
#include "sim_regbit.h"
#include "avr_ioport.h"
#include "avr_spi.h"
#include "avr_uart.h"

#define F 16000000.0
static avr_t *avr;
static const double vit[] = { 9600, 19200, 38400, 57600, 115200, 4800, 2400 };
static const int tops_bit[] = { 1667, 833, 417, 278, 139, 417, 833 };    /* main.c */

static int n_octets;
static uint8_t *term_env, *term_rec, *wifi_env, *wifi_rec;
static int term_nrec, wifi_nrec;

/* ---------------------------------------------------------------- terminal -> ATmega */
static double bt_term;                  /* duree d'un bit du terminal (cycles, exacte) */
static int term_i, term_bit;
static double term_t;
static avr_irq_t *pin_rx, *pin_cts, *pin_ss;
static int rts_actif = 1;

static long n_fronts_term, n_capt;
static int niv_term = 1;
static avr_cycle_count_t term_envoi(avr_t *a, avr_cycle_count_t when, void *p)
{
    (void)a; (void)p;
    if (term_bit == 0) {                /* debut d'une trame : seulement si RTS */
        if (term_i >= n_octets)
            return 0;
        if (!rts_actif) {
            term_t = (double)when + 50;
            return (avr_cycle_count_t)term_t;
        }
    }
    uint8_t o = term_env[term_i];
    int niv = term_bit == 0 ? 0 : term_bit <= 8 ? (o >> (term_bit - 1)) & 1 : 1;
    if (niv != niv_term)
        n_fronts_term++;
    niv_term = niv;
    avr_raise_irq(pin_rx, niv);
    term_t += bt_term;
    if (++term_bit == 10) {
        term_bit = 0;
        term_i++;
    }
    return (avr_cycle_count_t)(term_t + 0.5);
}

static void capt_isr(struct avr_irq_t *irq, uint32_t v, void *p)
{
    (void)irq; (void)p;
    if (v)
        n_capt++;
}

static void rts_change(struct avr_irq_t *irq, uint32_t v, void *p)
{
    (void)irq; (void)p;
    rts_actif = !v;
}

/* ---------------------------------------------------------------- ATmega -> terminal */
static int bt_tops;                     /* bit attendu, en tops de la minuterie 1 */
static int tx_bit = -1;                 /* -1 : repos ; 0 : depart ; 1-8 : donnees ; 9 : arret */
static uint16_t tx_ocr;                 /* comparaison precedente */
static avr_cycle_count_t tx_quand;      /* entree precedente dans COMPA */
static uint8_t tx_octet;
static int err_trame, err_cadence, err_manquee;
static long pire_gigue;                 /* ecart entre entrees successives et duree du bit */

static void compa(struct avr_irq_t *irq, uint32_t v, void *p)
{
    (void)irq; (void)p;
    if (!v)
        return;
    uint16_t ocr = avr->data[0x88] | avr->data[0x89] << 8;
    int niv = (avr->data[0x80] >> 6) == 3;          /* COM1A1:0 = 11 : 1 ; 10 : 0 */
    int pre = (avr->data[0x81] & 7) == 2 ? 8 : 1;   /* CS12:0 */
    if (tx_bit >= 0) {                  /* dans une trame : un bit exactement apres */
        uint16_t d = ocr - tx_ocr;
        /* apres l'arret : trame suivante collee (d = 1 bit) ou apres un repos (d > 1 bit) */
        if (tx_bit == 9 ? d < bt_tops : d != bt_tops) {
            err_cadence++;
            if (getenv("BANC_CADENCE"))
                printf("  cadence : bit %d, OCR %04X -> %04X (d=%u), %llu cycles apres, octet %02X niv %d\n",
                       tx_bit, tx_ocr, ocr, d, (unsigned long long)(avr->cycle - tx_quand), tx_octet, niv);
        }
        long g = (long)(avr->cycle - tx_quand) - (long)d * pre;
        if (tx_bit == 9 && d != bt_tops)
            ;                           /* (repos : pas de comparaison attendue) */
        else if (g > 20000) {
            err_manquee++;
            if (getenv("BANC_MANQUEE"))
                printf("  manquee : bit %d, OCR %04X -> %04X, entree %llu cycles apres la precedente (%llu)\n",
                       tx_bit, tx_ocr, ocr, (unsigned long long)(avr->cycle - tx_quand),
                       (unsigned long long)avr->cycle);
        }              /* OCR1A ecrit trop tard : un tour de minuterie */
        else if (labs(g) > pire_gigue)
            pire_gigue = labs(g);
    }
    if (tx_bit < 0 || tx_bit == 9) {    /* repos, ou arret pose : seul un depart peut venir */
        if (niv) {
            tx_bit = -1;
        } else {
            tx_bit = 0;
            tx_octet = 0;
        }
    } else {
        tx_bit++;
        if (tx_bit <= 8) {
            tx_octet |= niv << (tx_bit - 1);
        } else {                        /* bit d'arret */
            if (!niv)
                err_trame++;
            if (term_nrec < n_octets)
                term_rec[term_nrec] = tx_octet;
            term_nrec++;
        }
    }
    tx_ocr = ocr;
    tx_quand = avr->cycle;
}

/* ---------------------------------------------------------------- module Wi-Fi */
static avr_irq_t *uart_in;
static int wifi_i;

static avr_cycle_count_t wifi_envoi(avr_t *a, avr_cycle_count_t when, void *p)
{
    (void)a; (void)p;
    if (wifi_i >= n_octets)
        return 0;
    avr_raise_irq(uart_in, wifi_env[wifi_i++]);
    return when + (avr_cycle_count_t)(10 * F / 115200);
}

static void wifi_recu(struct avr_irq_t *irq, uint32_t v, void *p)
{
    (void)irq; (void)p;
    if (wifi_nrec < n_octets)
        wifi_rec[wifi_nrec] = (uint8_t)v;
    wifi_nrec++;
}

/* ---------------------------------------------------------------- 8088 (SPI) */
/* simavr, en esclave : a l'injection d'un octet, SPI_IRQ_OUTPUT rend le contenu de SPDR
 * (l'octet que le maitre recoit). */
static avr_irq_t *spi_in;
static int capture, capte;
static int ecrit_depuis;                /* SPDR ecrit par le micrologiciel depuis l'octet precedent */
static int en_retard, octets_spi;

static void spdr_sortie(struct avr_irq_t *irq, uint32_t v, void *p)
{
    (void)irq; (void)p;
    if (capture)
        capte = (uint8_t)v;
}

static uint64_t profil[32768];          /* cycles passes a chaque adresse (BANC_PROFIL) */
static int profiler;
static uint16_t trace_pc[4096];
static uint64_t trace_cy[4096];
static unsigned trace_i;
static uint16_t a_fr_perdu;
static int perdu_vu;
static elf_firmware_t *fw;
static const char *fonction(uint32_t a)
{
    const char *n = "?";
    uint32_t meilleur = 0;
    for (uint32_t i = 0; i < fw->symbolcount; i++) {
        uint32_t s0 = fw->symbol[i]->addr;
        if (s0 < 0x800000 && s0 <= a && s0 >= meilleur && fw->symbol[i]->symbol[0] != '_') {
            meilleur = s0;
            n = fw->symbol[i]->symbol;
        }
        if (s0 < 0x800000 && s0 <= a && s0 >= meilleur && !strncmp(fw->symbol[i]->symbol, "__vector", 8)) {
            meilleur = s0;
            n = fw->symbol[i]->symbol;
        }
    }
    return n;
}

/* TIFR1 : sur l'AVR, ecrire 1 dans un drapeau n'efface QUE ce drapeau. simavr 1.6
 * (avr_timer_write_pending) efface tous les drapeaux leves quel que soit l'octet ecrit :
 * CAPT effacait une comparaison A en attente (et la boucle principale, un front capte). */
static avr_int_vector_t *vec_t1[8];     /* bit de TIFR1 -> vecteur */
static void tifr1_ecrit(struct avr_t *a, avr_io_addr_t addr, uint8_t v, void *param)
{
    (void)a; (void)addr; (void)param;
    for (int b = 0; b < 8; b++)
        if ((v & (1 << b)) && vec_t1[b])
            avr_clear_interrupt(avr, vec_t1[b]);
}

static void interruptions_en_niveau(void)
{
    for (int i = 0; i < avr->interrupts.vector_count; i++) {
        avr_int_vector_t *v = avr->interrupts.vector[i];
        if (v && v->raised.reg && !v->pending && avr_regbit_get(avr, v->raised)
            && avr_regbit_get(avr, v->enable))
            avr_raise_interrupt(avr, v);
    }
    /* (simavr ne relance le service qu'a un changement de I : I deja a 1, on le relance) */
    if (avr->sreg[S_I] && avr->interrupt_state == 0 && avr_has_pending_interrupts(avr))
        avr->interrupt_state = 1;
}

static void attendre(double us)
{
    avr_cycle_count_t fin = avr->cycle + (avr_cycle_count_t)(us * 16);
    while (avr->cycle < fin) {
        interruptions_en_niveau();
        /* instruction OUT 0x2E (SPDR), Rr : 1011 1AAr rrrr AAAA */
        uint16_t op = avr->flash[avr->pc] | avr->flash[avr->pc + 1] << 8;
        if ((op & 0xFE0F) == 0xBC0E)
            ecrit_depuis = 1;
        avr_cycle_count_t c0 = avr->cycle;
        avr_flashaddr_t pc0 = avr->pc;
        int st = avr_run(avr);
        if (profiler && pc0 < 32768)
            profil[pc0] += avr->cycle - c0;
        trace_pc[trace_i & 4095] = pc0;
        trace_cy[trace_i & 4095] = c0;
        trace_i++;
        static int vus;
        int retard = getenv("BANC_RETARD") && tx_bit >= 0 && tx_bit < 9
                     && avr->cycle - tx_quand > (avr_cycle_count_t)bt_tops + 200 && vus < 2;
        if (retard) {
            vus++;
            printf("COMPA en retard a %llu (derniere entree %llu, SREG I=%d, etat %d, en cours %d) :\n",
                   (unsigned long long)avr->cycle, (unsigned long long)tx_quand, avr->sreg[S_I],
                   avr->interrupt_state, avr->interrupts.running_ptr);
            const char *prec = "";
            uint64_t debut = 0;
            for (unsigned k = trace_i - 600; k != trace_i; k++) {
                const char *n = fonction(trace_pc[k & 4095]);
                if (strcmp(n, prec)) {
                    if (*prec)
                        printf("  %llu-%llu %s\n", (unsigned long long)debut,
                               (unsigned long long)trace_cy[k & 4095], prec);
                    prec = n;
                    debut = trace_cy[k & 4095];
                }
            }
            printf("  ... %s (PC %04X)\n", prec, (unsigned)avr->pc);
        }
        if (a_fr_perdu && avr->data[a_fr_perdu] && !perdu_vu) {
            perdu_vu = 1;
            printf("fr_perdu a %llu ; fonctions des 4096 dernieres instructions :\n", (unsigned long long)avr->cycle);
            const char *prec = "";
            uint64_t debut = 0;
            for (unsigned k = trace_i - 4096; k != trace_i; k++) {
                const char *n = fonction(trace_pc[k & 4095]);
                if (strcmp(n, prec)) {
                    if (*prec)
                        printf("  %llu-%llu %s\n", (unsigned long long)debut, (unsigned long long)trace_cy[k & 4095], prec);
                    prec = n;
                    debut = trace_cy[k & 4095];
                }
            }
        }
        if (st == cpu_Done || st == cpu_Crashed) {
            printf("ATmega arrete (%d)\n", st);
            exit(2);
        }
    }
}

static double us_octet;

static uint8_t octet(uint8_t o)
{
    attendre(us_octet);
    if (!ecrit_depuis)                  /* SPDR pas recharge depuis l'octet precedent */
        en_retard++;
    ecrit_depuis = 0;
    capture = 1;
    capte = -1;
    avr_raise_irq(spi_in, o);
    capture = 0;
    octets_spi++;
    return (uint8_t)capte;
}

/* SS : comme le 8088 (avr_fin, avr_debut) : >= 10 us apres le dernier octet, SS haut au
 * moins 15 us, premier octet us_octet apres la descente */
static void ss(int v)
{
    attendre(v ? 10 : 15);
    avr_raise_irq(pin_ss, v);
    if (!v)
        ecrit_depuis = 1;               /* (SPDR = A5h, prepare a la fin de la precedente) */
}

static int signatures_fausses;

static int lire(uint8_t cmd, uint8_t *dst, int max)
{
    ss(0);
    if (octet(cmd) != 0xA5)
        signatures_fausses++;
    int n = octet(0);
    if (n > max)
        n = max;
    for (int i = 0; i < n; i++)
        dst[i] = octet(0);
    ss(1);
    return n;
}

static int ecrire(uint8_t cmd, const uint8_t *src, int n)
{
    ss(0);
    if (octet(cmd) != 0xA5)
        signatures_fausses++;
    int libre = octet(0);
    if (n > libre)
        n = libre;
    for (int i = 0; i < n; i++)
        octet(src[i]);
    ss(1);
    return n;
}

static uint8_t etat_r[6];
static uint8_t etat(uint8_t cmd)
{
    ss(0);
    for (int i = 0; i < 6; i++)
        etat_r[i] = octet(i ? 0 : cmd);
    ss(1);
    return etat_r[5];
}

static void montre(const char *titre, const uint8_t *a, int n)
{
    printf("%-11s:", titre);
    for (int i = 0; i < 12 && i < n; i++)
        printf(" %02X", a[i]);
    printf("\n");
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "banc <firmware.elf> <code vitesse> <octets> <us entre octets SPI>\n");
        return 2;
    }
    elf_firmware_t f;
    memset(&f, 0, sizeof f);
    if (elf_read_firmware(argv[1], &f)) {
        fprintf(stderr, "lecture de %s\n", argv[1]);
        return 2;
    }
    int code = atoi(argv[2]);
    n_octets = atoi(argv[3]);
    us_octet = atof(argv[4]);
    profiler = getenv("BANC_PROFIL") != NULL;
    fw = &f;
    for (uint32_t i = 0; i < f.symbolcount; i++)
        if (!strcmp(f.symbol[i]->symbol, "fr_perdu") && getenv("BANC_PERDU"))
            a_fr_perdu = f.symbol[i]->addr & 0xFFFF;
    avr = avr_make_mcu_by_name("atmega328p");
    avr_init(avr);
    f.frequency = (uint32_t)F;
    avr_load_firmware(avr, &f);
    avr->frequency = (uint32_t)F;

    for (int i = 0; i < avr->interrupts.vector_count; i++) {
        avr_int_vector_t *v = avr->interrupts.vector[i];
        if (v && v->raised.reg == 0x36)                     /* TIFR1 : ICF1, OCF1B, OCF1A, TOV1 */
            vec_t1[v->raised.bit] = v;
    }
    avr->io[AVR_DATA_TO_IO(0x36)].w.c = tifr1_ecrit;
    avr->io[AVR_DATA_TO_IO(0x36)].w.param = NULL;
    pin_rx = avr_io_getirq(avr, AVR_IOCTL_IOPORT_GETIRQ('B'), 0);
    pin_ss = avr_io_getirq(avr, AVR_IOCTL_IOPORT_GETIRQ('B'), 2);
    pin_cts = avr_io_getirq(avr, AVR_IOCTL_IOPORT_GETIRQ('D'), 7);
    avr_irq_register_notify(avr_io_getirq(avr, AVR_IOCTL_IOPORT_GETIRQ('D'), 6), rts_change, NULL);
    for (int i = 0; i < avr->interrupts.vector_count; i++)
        if (avr->interrupts.vector[i] && avr->interrupts.vector[i]->vector == 11)  /* TIMER1_COMPA */
            avr_irq_register_notify(avr->interrupts.vector[i]->irq + AVR_INT_IRQ_RUNNING, compa, NULL);
    for (int i = 0; i < avr->interrupts.vector_count; i++)
        if (avr->interrupts.vector[i] && avr->interrupts.vector[i]->vector == 10)  /* TIMER1_CAPT */
            avr_irq_register_notify(avr->interrupts.vector[i]->irq + AVR_INT_IRQ_RUNNING, capt_isr, NULL);
    spi_in = avr_io_getirq(avr, AVR_IOCTL_SPI_GETIRQ(0), SPI_IRQ_INPUT);
    avr_irq_register_notify(avr_io_getirq(avr, AVR_IOCTL_SPI_GETIRQ(0), SPI_IRQ_OUTPUT), spdr_sortie, NULL);
    uart_in = avr_io_getirq(avr, AVR_IOCTL_UART_GETIRQ('0'), UART_IRQ_INPUT);
    avr_irq_register_notify(avr_io_getirq(avr, AVR_IOCTL_UART_GETIRQ('0'), UART_IRQ_OUTPUT), wifi_recu, NULL);
    uint32_t fl = 0;
    avr_ioctl(avr, AVR_IOCTL_UART_GET_FLAGS('0'), &fl);
    fl &= ~AVR_UART_FLAG_STDIO;
    avr_ioctl(avr, AVR_IOCTL_UART_SET_FLAGS('0'), &fl);

    avr_raise_irq(pin_rx, 1);
    avr_raise_irq(pin_ss, 1);
    avr_raise_irq(pin_cts, 0);          /* CTS actif (R22) */

    term_env = malloc(n_octets); term_rec = calloc(n_octets, 1);
    wifi_env = malloc(n_octets); wifi_rec = calloc(n_octets, 1);
    srand(1234);
    for (int i = 0; i < n_octets; i++) {
        term_env[i] = (uint8_t)rand();
        wifi_env[i] = (uint8_t)rand();
    }

    attendre(2000);                     /* demarrage */
    uint8_t r[8];
    ss(0);
    for (int i = 0; i < 7; i++)
        r[i] = octet(0x00);
    ss(1);
    printf("IDENT : %02X %c%c v%d, vitesses %d et %d ; ", r[0], r[1], r[2], r[3], r[4], r[5]);
    if (r[0] != 0xA5 || r[1] != 'S' || r[2] != '2' || r[3] != 3 || r[4] != 3 || r[5] != 4) {
        printf("ECHEC\n");
        return 1;
    }
    if (code != r[4]) {                 /* VITESSE du canal 1 */
        ss(0); octet(0x04); octet((uint8_t)code); ss(1);
        attendre(200);
    }
    bt_term = F / vit[code];
    bt_tops = tops_bit[code];

    term_t = (double)avr->cycle + 1000;
    avr_cycle_timer_register(avr, (avr_cycle_count_t)term_t - avr->cycle, term_envoi, NULL);
    avr_cycle_timer_register(avr, 1500, wifi_envoi, NULL);

    static uint8_t a1[100000], a2[100000];
    int n1 = 0, n2 = 0, echo1 = 0, echo2 = 0;
    double duree = n_octets * 10 * (bt_term > F / 115200 ? bt_term : F / 115200);
    avr_cycle_count_t debut = avr->cycle;
    while ((term_nrec < n_octets || wifi_nrec < n_octets) && avr->cycle - debut < 3 * duree + 16e6) {
        n1 += lire(0x02, a1 + n1, 64);
        n2 += lire(0x12, a2 + n2, 64);
        if (echo1 < n1)
            echo1 += ecrire(0x03, a1 + echo1, n1 - echo1);
        if (echo2 < n2)
            echo2 += ecrire(0x13, a2 + echo2, n2 - echo2);
    }
    attendre(500);
    uint8_t dr1 = etat(0x01);
    int rx1 = etat_r[1] | etat_r[2] << 8, libre1 = etat_r[3] | etat_r[4] << 8;
    uint8_t dr2 = etat(0x11);
    int rx2 = etat_r[1] | etat_r[2] << 8, libre2 = etat_r[3] | etat_r[4] << 8;
    printf("fin : canal 1 lus %d, renvoyes %d, en attente %d, place %d ; canal 2 lus %d, renvoyes %d,"
           " en attente %d, place %d\n", n1, echo1, rx1, libre1, n2, echo2, rx2, libre2);

    int bon1 = term_nrec == n_octets && n1 == n_octets && !memcmp(term_rec, term_env, n_octets);
    int bon2 = wifi_nrec == n_octets && n2 == n_octets && !memcmp(wifi_rec, wifi_env, n_octets);
    uint32_t a_perdu = 0;
    for (uint32_t i = 0; i < f.symbolcount; i++)
        if (!strcmp(f.symbol[i]->symbol, "fr_perdu"))
            a_perdu = f.symbol[i]->addr & 0xFFFF;
    int perdu = a_perdu ? avr->data[a_perdu] : 0;
    printf("terminal %.0f bauds, SPI %.0f us/octet ; fronts envoyes %ld, entrees CAPT %ld\n", vit[code],
           us_octet, n_fronts_term, n_capt);
    printf("  terminal -> ATmega -> 8088 : %d/%d ; 8088 -> ATmega -> terminal : %d/%d %s ;\n"
           "  trames fausses %d, cadence fausse %d, comparaisons manquees %d (gigue max %ld cycles,"
           " bit = %d tops) ; fronts perdus %d ; drapeaux %02X\n", n1, n_octets, term_nrec, n_octets,
           bon1 ? "OK" : "FAUX", err_trame, err_cadence, err_manquee, pire_gigue, bt_tops, perdu, dr1);
    printf("  Wi-Fi 115200 : %d/%d lus, %d/%d revenus %s, drapeaux %02X ; SPI %d octets, %d en retard,"
           " %d signatures fausses ; %.1f ms simulees\n", n2, n_octets, wifi_nrec, n_octets,
           bon2 ? "OK" : "FAUX", dr2, octets_spi, en_retard, signatures_fausses,
           (avr->cycle - debut) / 16000.0);
    for (int i = 0; i < n_octets; i++)
        if (i >= term_nrec || term_rec[i] != term_env[i]) {
            printf("  terminal : 1er ecart a l'octet %d :", i);
            for (int k = i - 2; k < i + 4 && k < n_octets; k++)
                if (k >= 0)
                    printf(" %02X/%02X", term_env[k], k < term_nrec ? term_rec[k] : 0);
            printf("\n");
            break;
        }
    for (int i = 0; i < n_octets; i++)
        if (i >= wifi_nrec || wifi_rec[i] != wifi_env[i]) {
            printf("  Wi-Fi : 1er ecart a l'octet %d :", i);
            for (int k = i - 2; k < i + 4 && k < n_octets; k++)
                if (k >= 0)
                    printf(" %02X/%02X", wifi_env[k], k < wifi_nrec ? wifi_rec[k] : 0);
            printf("\n");
            break;
        }
    if (!bon1) {
        montre("  envoye", term_env, n_octets);
        montre("  lu 8088", a1, n1);
        montre("  revenu", term_rec, term_nrec);
    }
    if (profiler) {                     /* cycles par fonction (symboles du .elf) */
        uint64_t tot = 0;
        for (int a = 0; a < 32768; a++)
            tot += profil[a];
        for (uint32_t i = 0; i < f.symbolcount; i++) {
            uint32_t a0 = f.symbol[i]->addr;
            if (a0 >= 0x800000)
                continue;
            uint32_t a1s = 32768;
            for (uint32_t j = 0; j < f.symbolcount; j++)
                if (f.symbol[j]->addr > a0 && f.symbol[j]->addr < a1s)
                    a1s = f.symbol[j]->addr;
            uint64_t c = 0;
            for (uint32_t a = a0; a < a1s; a++)
                c += profil[a];
            if (c * 200 > tot)
                printf("    %-22s %5.1f %%\n", f.symbol[i]->symbol, 100.0 * c / tot);
        }
    }
    int ok = bon1 && bon2 && !err_trame && !err_cadence && !err_manquee && !perdu && !en_retard
          && !signatures_fausses && !(dr1 & 7) && !(dr2 & 7);
    printf("  %s\n", ok ? "REUSSI" : "ECHEC");
    return !ok;
}
