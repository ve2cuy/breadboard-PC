//! ATmega328P (U17, schema du 2026-11-21) : UART du montage (J5) et esclave SPI du 8088 sur le
//! bus de la carte SD (SCK = U12 PC5, MOSI = U12 PC6, MISO -> U12 PB4, SS <- U12 PC0), IRQ
//! (PD2) -> IR4 du 8259, RTS/CTS sur J8.
//!
//! `Proto` reprend a l'identique arduino/atmega_uart/src/protocole.c (memes essais, plus bas).
//! `Avr` ajoute ce que fait main.c : esclave SPI au niveau des broches (mode 0, poids fort en
//! premier ; l'octet suivant est charge dans SPDR par l'interruption, ~3 us apres la fin d'un
//! octet : un 8088 trop rapide recoit le registre a decalage, compte dans `trop_tot`), USART
//! (decodeur de la ligne du terminal, generateur des trames emises), CTS et vitesse.

use crate::serial::{bit_t, UartRx};

pub const VERSION: u8 = 2;
pub const SIGNATURE: u8 = 0xA5;

pub const IDENT: u8 = 0x00;
pub const ETAT: u8 = 0x01;
pub const LIRE: u8 = 0x02;
pub const ECRIRE: u8 = 0x03;
pub const VITESSE: u8 = 0x04;
pub const VIDER: u8 = 0x05;

pub const ETAT_RX_PLEIN: u8 = 0x01;
pub const ETAT_UART_ERR: u8 = 0x02;
pub const ETAT_TX_PLEIN: u8 = 0x04;
pub const ETAT_CTS: u8 = 0x40;
pub const ETAT_RTS: u8 = 0x80;

pub const V_NB: u8 = 7;
pub const V_AUCUNE: u8 = 0xFF;
/// Vitesses de VITESSE (0 = 9600 au demarrage).
pub const VITESSES: [u64; 7] = [9600, 19200, 38400, 57600, 115200, 4800, 2400];

pub const RX_TAILLE: usize = 1024;
pub const TX_TAILLE: usize = 512;
pub const RX_HAUT: usize = 768;
pub const RX_BAS: usize = 256;

/// Latence de l'interruption SPI de l'ATmega (entree + prologue + ecriture de SPDR) : ~3 us.
pub const LATENCE_SPI: u64 = 16;

#[derive(Clone, Copy, PartialEq)]
enum E {
    Cmd,
    Ident,
    Etat,
    Lire,
    EcrireF,
    Ecrire,
    Vitesse,
    Vider,
    Ignore,
}

/// Protocole et tampons (protocole.c).
#[derive(Clone)]
pub struct Proto {
    pub irq: bool,
    pub rts: bool,
    pub cts: bool,
    pub vitesse: u8,
    /// Vitesse en service (code de VITESSES), rendue par IDENT depuis la version 2.
    pub vit_courante: u8,
    rx: Vec<u8>,
    tx: Vec<u8>,
    rx_tete: usize,
    rx_nb: usize,
    tx_tete: usize,
    tx_nb: usize,
    drapeaux: u8,
    etat: E,
    k: u8,
    n_lire: u8,
    lus: u8,
    donnee_chargee: bool,
    en_transaction: bool,
    instantane: [u8; 5],
}

impl Default for Proto {
    fn default() -> Self {
        Self::new()
    }
}

impl Proto {
    pub fn new() -> Self {
        let mut p = Proto {
            irq: false,
            rts: true,
            cts: true,
            vitesse: V_AUCUNE,
            vit_courante: 0,
            rx: vec![0; RX_TAILLE],
            tx: vec![0; TX_TAILLE],
            rx_tete: 0,
            rx_nb: 0,
            tx_tete: 0,
            tx_nb: 0,
            drapeaux: 0,
            etat: E::Cmd,
            k: 0,
            n_lire: 0,
            lus: 0,
            donnee_chargee: false,
            en_transaction: false,
            instantane: [0; 5],
        };
        p.vider();
        p
    }

    fn maj_irq(&mut self) {
        self.irq = self.rx_nb != 0 && !self.en_transaction;
    }

    fn vider(&mut self) {
        self.rx_tete = 0;
        self.rx_nb = 0;
        self.tx_tete = 0;
        self.tx_nb = 0;
        self.drapeaux = 0;
        self.rts = true;
        self.maj_irq();
    }

    pub fn rx_nb(&self) -> usize {
        self.rx_nb
    }
    pub fn tx_nb(&self) -> usize {
        self.tx_nb
    }

    pub fn ss_debut(&mut self) {
        self.en_transaction = true;
        self.etat = E::Cmd;
        self.donnee_chargee = false;
        self.maj_irq();
    }

    pub fn ss_fin(&mut self) -> u8 {
        self.en_transaction = false;
        self.etat = E::Cmd;
        self.donnee_chargee = false;
        self.maj_irq();
        SIGNATURE
    }

    fn charger_donnee(&mut self) -> u8 {
        if self.lus < self.n_lire && self.rx_nb != 0 {
            self.lus += 1;
            self.donnee_chargee = true;
            return self.rx[self.rx_tete];
        }
        0
    }

    pub fn spi(&mut self, recu: u8) -> u8 {
        if self.donnee_chargee {
            self.donnee_chargee = false;
            self.rx_tete = (self.rx_tete + 1) & (RX_TAILLE - 1);
            self.rx_nb -= 1;
            if self.rx_nb <= RX_BAS {
                self.rts = true;
            }
        }
        match self.etat {
            E::Cmd => {
                self.k = 0;
                match recu {
                    IDENT => {
                        self.etat = E::Ident;
                        b'S'
                    }
                    ETAT => {
                        let libre = TX_TAILLE - self.tx_nb;
                        self.instantane = [
                            self.rx_nb as u8,
                            (self.rx_nb >> 8) as u8,
                            libre as u8,
                            (libre >> 8) as u8,
                            self.drapeaux
                                | if self.cts { ETAT_CTS } else { 0 }
                                | if self.rts { ETAT_RTS } else { 0 },
                        ];
                        self.drapeaux = 0;
                        self.etat = E::Etat;
                        self.instantane[0]
                    }
                    LIRE => {
                        self.n_lire = self.rx_nb.min(255) as u8;
                        self.lus = 0;
                        self.etat = E::Lire;
                        self.n_lire
                    }
                    ECRIRE => {
                        self.etat = E::EcrireF;
                        (TX_TAILLE - self.tx_nb).min(255) as u8
                    }
                    VITESSE => {
                        self.etat = E::Vitesse;
                        0
                    }
                    VIDER => {
                        self.etat = E::Vider;
                        0
                    }
                    _ => {
                        self.etat = E::Ignore;
                        0
                    }
                }
            }
            E::Ident => {
                self.k += 1;
                match self.k {
                    1 => b'2',
                    2 => VERSION,
                    3 => self.vit_courante,
                    _ => 0,
                }
            }
            E::Etat => {
                self.k += 1;
                if self.k < 5 {
                    self.instantane[self.k as usize]
                } else {
                    0
                }
            }
            E::Lire => self.charger_donnee(),
            E::EcrireF => {
                self.etat = E::Ecrire;
                0
            }
            E::Ecrire => {
                if self.tx_nb < TX_TAILLE {
                    self.tx[(self.tx_tete + self.tx_nb) & (TX_TAILLE - 1)] = recu;
                    self.tx_nb += 1;
                } else {
                    self.drapeaux |= ETAT_TX_PLEIN;
                }
                0
            }
            E::Vitesse => {
                if recu < V_NB {
                    self.vitesse = recu;
                }
                self.etat = E::Ignore;
                0
            }
            E::Vider => {
                if recu == SIGNATURE {
                    self.vider();
                }
                self.etat = E::Ignore;
                0
            }
            E::Ignore => 0,
        }
    }

    pub fn uart_recu(&mut self, octet: u8, erreur: bool) {
        if erreur {
            self.drapeaux |= ETAT_UART_ERR;
        }
        if self.rx_nb < RX_TAILLE {
            self.rx[(self.rx_tete + self.rx_nb) & (RX_TAILLE - 1)] = octet;
            self.rx_nb += 1;
            if self.rx_nb >= RX_HAUT {
                self.rts = false;
            }
        } else {
            self.drapeaux |= ETAT_RX_PLEIN;
        }
        self.maj_irq();
    }

    pub fn uart_a_emettre(&mut self) -> Option<u8> {
        if self.tx_nb == 0 {
            return None;
        }
        let b = self.tx[self.tx_tete];
        self.tx_tete = (self.tx_tete + 1) & (TX_TAILLE - 1);
        self.tx_nb -= 1;
        Some(b)
    }
}

/// L'ATmega vu de la carte.
#[derive(Clone)]
pub struct Avr {
    pub p: Proto,
    ss: bool,
    sck: bool,
    k: u8,
    inp: u8,
    cur: u8,
    /// Octet que l'interruption SPI ecrit dans SPDR, et a quel instant (cycles du 8088).
    pend: Option<(u64, u8)>,
    pub baud: u64,
    /// USART : decodeur de la ligne RX (terminal -> ATmega) et trames emises (ATmega -> terminal).
    gen: UartRx,
    /// Trames emises vers le terminal : (fin de la trame, octet, vitesse).
    vers_terminal: std::collections::VecDeque<(u64, u8, u64)>,
    fin_tx: u64,
    /// Statistiques.
    pub octets_spi: u64,
    pub trop_tot: u64,
    pub recus: u64,
    pub emis: u64,
    /// Journal de mise au point : (instant, commande, octets de la transaction).
    pub journal: Vec<(u64, u8, u32)>,
    octet_tr: u32,
}

impl Default for Avr {
    fn default() -> Self {
        Self::new()
    }
}

impl Avr {
    pub fn new() -> Self {
        Avr {
            p: Proto::new(),
            ss: true,
            sck: false,
            k: 8,
            inp: 0,
            cur: SIGNATURE,
            pend: Some((0, SIGNATURE)),
            baud: 9600,
            gen: UartRx::new(),
            vers_terminal: std::collections::VecDeque::new(),
            fin_tx: 0,
            octets_spi: 0,
            trop_tot: 0,
            recus: 0,
            emis: 0,
            journal: Vec::new(),
            octet_tr: 0,
        }
    }

    /// Broches de U12 vues par l'ATmega : bit 0 = SS (PC0), bit 5 = SCK (PC5), bit 6 = MOSI (PC6).
    pub fn port_c(&mut self, v: u8, t: u64) {
        let ss = v & 0x01 != 0;
        let sck = v & 0x20 != 0;
        let mosi = (v >> 6) & 1;
        if ss != self.ss {
            self.ss = ss;
            self.k = 8;
            if ss {
                if self.octet_tr > 0 && self.journal.len() < 4096 {
                    if let Some(d) = self.journal.last_mut() {
                        d.2 = self.octet_tr;
                    }
                }
                let o = self.p.ss_fin();
                self.pend = Some((t + LATENCE_SPI, o));
            } else {
                self.p.ss_debut();
                self.octet_tr = 0;
            }
        }
        if !ss && sck && !self.sck {
            if self.k == 8 {
                // premier front d'un octet : SPDR recharge a temps ?
                match self.pend.take() {
                    Some((tr, o)) if t >= tr => self.cur = o,
                    other => {
                        // l'ATmega n'a pas encore ecrit SPDR : le registre a decalage contient
                        // l'octet recu ; l'ecriture tardive tombera en collision (WCOL)
                        self.cur = self.inp;
                        if other.is_some() {
                            self.trop_tot += 1;
                        }
                    }
                }
                self.k = 0;
                self.inp = 0;
            }
            self.inp = (self.inp << 1) | mosi;
            self.k += 1;
            if self.k == 8 {
                if self.octet_tr == 0 && self.journal.len() < 4096 {
                    self.journal.push((t, self.inp, 0));
                }
                self.octet_tr += 1;
                let o = self.p.spi(self.inp);
                self.pend = Some((t + LATENCE_SPI, o));
                self.octets_spi += 1;
                self.service(t);
            }
        }
        self.sck = sck;
    }

    /// MISO (PB4 de U12) : R20 au +5 V quand l'ATmega n'est pas selectionne.
    pub fn miso(&self, t: u64) -> bool {
        if self.ss {
            return true;
        }
        let i: i32 = if self.sck { self.k as i32 - 1 } else { self.k as i32 };
        if (0..8).contains(&i) {
            return (self.cur >> (7 - i)) & 1 != 0;
        }
        // entre deux octets : bit 7 de SPDR une fois recharge, sinon du registre a decalage
        match self.pend {
            Some((tr, o)) if t >= tr => o & 0x80 != 0,
            _ => self.inp & 0x80 != 0,
        }
    }

    pub fn irq(&self) -> bool {
        self.p.irq
    }

    /// RTS actif : le terminal peut envoyer.
    pub fn rts(&self) -> bool {
        self.p.rts
    }

    /// Octet recu du terminal, remis a la fin exacte de sa trame (erreur : vitesses differentes).
    /// Les trames sont remises octet par octet plutot que par leurs fronts : a 115200 bauds, un
    /// bit ne dure que 46 cycles du 8088, moins qu'une longue instruction (MUL, DIV).
    pub fn recu(&mut self, t: u64, octet: u8, erreur: bool) {
        self.service(t);
        self.p.uart_recu(octet, erreur);
        self.recus += 1;
    }

    /// Ce que font la boucle principale et les interruptions de l'USART jusqu'a l'instant t.
    pub fn service(&mut self, t: u64) {
        // emission : un octet a la fois, seulement si le terminal accepte (CTS)
        self.gen.line(t);
        if self.gen.pending() == 0 {
            if self.p.vitesse != V_AUCUNE && self.p.tx_nb() == 0 {
                self.baud = VITESSES[self.p.vitesse as usize];
                self.p.vit_courante = self.p.vitesse;
                self.gen.baud = self.baud;
                self.p.vitesse = V_AUCUNE;
            }
            if self.p.cts {
                if let Some(b) = self.p.uart_a_emettre() {
                    let debut = t.max(self.fin_tx);
                    self.gen.push(&[b], t);
                    self.fin_tx = debut + bit_t(10, self.baud);
                    self.vers_terminal.push_back((self.fin_tx, b, self.baud));
                    self.emis += 1;
                }
            }
        }
    }

    /// Octets emis dont la trame est finie a l'instant t : (octet, vitesse) pour le terminal.
    pub fn pour_terminal(&mut self, t: u64) -> Vec<(u8, u64)> {
        let mut v = Vec::new();
        while let Some(&(f, b, baud)) = self.vers_terminal.front() {
            if f > t {
                break;
            }
            self.vers_terminal.pop_front();
            v.push((b, baud));
        }
        v
    }

    /// Ligne TX (ATmega -> terminal).
    pub fn tx_line(&mut self, t: u64) -> bool {
        self.gen.line(t)
    }

    /// Prochain instant ou il se passe quelque chose sans action du 8088.
    pub fn next_change(&self, t: u64) -> u64 {
        let mut n = self.gen.next_change(t);
        if self.gen.pending() == 0 && self.p.tx_nb() != 0 && self.p.cts {
            n = n.min(t + 1);
        }
        if let Some(&(f, _, _)) = self.vers_terminal.front() {
            n = n.min(f.max(t + 1));
        }
        n
    }
}

#[cfg(test)]
mod essais {
    //! Memes essais que arduino/atmega_uart/test/test_protocole.c.
    use super::*;

    struct Maitre {
        p: Proto,
        prepare: u8,
    }

    impl Maitre {
        fn new() -> Self {
            Maitre { p: Proto::new(), prepare: SIGNATURE }
        }
        fn transaction(&mut self, mosi: &[u8]) -> Vec<u8> {
            self.p.ss_debut();
            assert!(!self.p.irq, "IRQ doit tomber au debut d'une transaction");
            let mut r = Vec::new();
            for &o in mosi {
                r.push(self.prepare);
                self.prepare = self.p.spi(o);
            }
            self.prepare = self.p.ss_fin();
            r
        }
        fn recevoir(&mut self, s: &[u8]) {
            for &b in s {
                self.p.uart_recu(b, false);
            }
        }
        fn etat(&mut self) -> (usize, usize, u8) {
            let r = self.transaction(&[ETAT, 0, 0, 0, 0, 0]);
            assert_eq!(r[0], SIGNATURE);
            (r[1] as usize | (r[2] as usize) << 8, r[3] as usize | (r[4] as usize) << 8, r[5])
        }
        fn lire(&mut self, max: usize) -> (usize, Vec<u8>) {
            self.p.ss_debut();
            self.prepare = self.p.spi(LIRE);
            let n = self.prepare as usize;
            self.prepare = self.p.spi(0);
            let mut v = Vec::new();
            for _ in 0..n.min(max) {
                v.push(self.prepare);
                self.prepare = self.p.spi(0);
            }
            self.prepare = self.p.ss_fin();
            (n, v)
        }
        fn ecrire(&mut self, s: &[u8]) -> u8 {
            let mut o = vec![ECRIRE, 0];
            o.extend_from_slice(s);
            self.transaction(&o)[1]
        }
    }

    #[test]
    fn ident() {
        let mut m = Maitre::new();
        assert_eq!(m.transaction(&[IDENT, 0, 0, 0, 0, 0]), vec![0xA5, b'S', b'2', VERSION, 0, 0]);
        m.p.vit_courante = 4;
        assert_eq!(m.transaction(&[IDENT, 0, 0, 0, 0])[4], 4, "IDENT : vitesse courante");
    }

    #[test]
    fn reception_irq_lire() {
        let mut m = Maitre::new();
        assert!(!m.p.irq);
        m.recevoir(b"abc");
        assert!(m.p.irq);
        assert_eq!(m.etat(), (3, TX_TAILLE, ETAT_CTS | ETAT_RTS));
        assert!(m.p.irq);
        assert_eq!(m.lire(255), (3, b"abc".to_vec()));
        assert_eq!(m.p.rx_nb(), 0);
        assert!(!m.p.irq);
    }

    #[test]
    fn lecture_partielle() {
        let mut m = Maitre::new();
        m.recevoir(b"ABCDE");
        assert_eq!(m.lire(2), (5, b"AB".to_vec()));
        assert_eq!(m.p.rx_nb(), 3);
        assert!(m.p.irq);
        assert_eq!(m.lire(255), (3, b"CDE".to_vec()));
    }

    #[test]
    fn irq_a_la_fin_de_la_transaction() {
        let mut m = Maitre::new();
        m.p.ss_debut();
        m.prepare = m.p.spi(ETAT);
        m.recevoir(b"x");
        assert!(!m.p.irq);
        m.prepare = m.p.ss_fin();
        assert!(m.p.irq);
    }

    #[test]
    fn ecrire_et_plein() {
        let mut m = Maitre::new();
        assert_eq!(m.ecrire(b"hello"), 255);
        let e: Vec<u8> = std::iter::from_fn(|| m.p.uart_a_emettre()).collect();
        assert_eq!(e, b"hello");
        let gros = vec![b'z'; TX_TAILLE + 10];
        m.ecrire(&gros);
        assert_eq!(m.p.tx_nb(), TX_TAILLE);
        let (_, libre, dr) = m.etat();
        assert_eq!(libre, 0);
        assert!(dr & ETAT_TX_PLEIN != 0);
        assert!(m.etat().2 & ETAT_TX_PLEIN == 0);
    }

    #[test]
    fn rts_et_debordement() {
        let mut m = Maitre::new();
        for i in 0..RX_HAUT - 1 {
            m.p.uart_recu(i as u8, false);
        }
        assert!(m.p.rts);
        m.p.uart_recu(0, false);
        assert!(!m.p.rts);
        for _ in 0..RX_TAILLE - RX_HAUT + 3 {
            m.p.uart_recu(0, false);
        }
        let (rx, _, dr) = m.etat();
        assert_eq!(rx, RX_TAILLE);
        assert!(dr & ETAT_RX_PLEIN != 0 && dr & ETAT_RTS == 0);
        while m.p.rx_nb() - 255 > RX_BAS + 1 {
            m.lire(255);
            assert!(!m.p.rts);
        }
        let reste = m.p.rx_nb() - (RX_BAS + 1);
        m.lire(reste);
        assert!(!m.p.rts);
        m.lire(1);
        assert_eq!(m.p.rx_nb(), RX_BAS);
        assert!(m.p.rts);
    }

    #[test]
    fn ordre_circulaire() {
        let mut m = Maitre::new();
        let (mut envoye, mut attendu) = (0u32, 0u32);
        for _ in 0..20 {
            for _ in 0..300 {
                m.p.uart_recu((envoye * 7) as u8, false);
                envoye += 1;
            }
            while m.p.rx_nb() != 0 {
                for b in m.lire(100).1 {
                    assert_eq!(b, (attendu * 7) as u8);
                    attendu += 1;
                }
            }
        }
        assert_eq!(envoye, attendu);
    }

    #[test]
    fn vider_vitesse_inconnue_erreur() {
        let mut m = Maitre::new();
        m.recevoir(b"abc");
        m.transaction(&[VIDER, 0]);
        assert_eq!(m.p.rx_nb(), 3);
        m.transaction(&[VIDER, SIGNATURE]);
        assert_eq!(m.p.rx_nb(), 0);
        assert!(!m.p.irq);
        m.transaction(&[VITESSE, 4]);
        assert_eq!(m.p.vitesse, 4);
        m.p.vitesse = V_AUCUNE;
        m.transaction(&[VITESSE, 99]);
        assert_eq!(m.p.vitesse, V_AUCUNE);
        m.recevoir(b"q");
        m.transaction(&[]);
        assert_eq!(m.p.rx_nb(), 1);
        assert_eq!(m.transaction(&[0x7E, 1, 2, 3]), vec![0xA5, 0, 0, 0]);
        m.p.uart_recu(b'e', true);
        assert!(m.etat().2 & ETAT_UART_ERR != 0);
    }

    /// Esclave SPI au niveau des broches : 8088 qui laisse assez de temps entre les octets,
    /// puis un 8088 trop rapide.
    #[test]
    fn spi_broches() {
        fn octet(a: &mut Avr, t: &mut u64, o: u8, demi: u64) -> u8 {
            let mut r = 0u8;
            for i in (0..8).rev() {
                let mosi = (o >> i) & 1;
                a.port_c(mosi << 6, *t); // SS = 0, SCK = 0, MOSI pose
                *t += demi;
                a.port_c(0x20 | mosi << 6, *t); // SCK = 1
                r = (r << 1) | a.miso(*t) as u8;
                *t += demi;
            }
            a.port_c(0, *t);
            r
        }
        let mut a = Avr::new();
        let mut t = 1000u64;
        a.port_c(0x01, t); // SS = 1
        t += 100;
        a.port_c(0x00, t); // SS = 0
        t += 20;
        let r: Vec<u8> = [IDENT, 0, 0, 0].iter().map(|&o| {
            let v = octet(&mut a, &mut t, o, 25);
            t += 60; // ~11 us entre deux octets
            v
        }).collect();
        a.port_c(0x01, t);
        assert_eq!(r, vec![0xA5, b'S', b'2', VERSION]);
        assert_eq!(a.trop_tot, 0);
        // 8088 trop rapide : octet suivant 1 cycle apres le precedent
        t += 100;
        a.port_c(0x00, t);
        t += 20;
        let _ = octet(&mut a, &mut t, IDENT, 2);
        let _ = octet(&mut a, &mut t, 0, 2);
        assert_eq!(a.trop_tot, 1);
    }
}
