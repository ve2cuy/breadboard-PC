//! ATmega328P (U17, schema du 2026-11-23) : deux UART pour le 8088 et esclave SPI sur le bus
//! de la carte SD (SCK = U12 PC5, MOSI = U12 PC6, MISO -> U12 PB4, SS <- U12 PC0), IRQ (PD2) ->
//! IR4 du 8259. Canal 1 = terminal (J5, UART logiciel PB0/PB1, RTS/CTS sur J8) ; canal 2 = module
//! Grove - UART WiFi V2 (J13, USART materiel, 115200 bauds, micrologiciel AT).
//!
//! `Proto` reprend a l'identique arduino/atmega_uart/src/protocole.c (protocole version 3, memes
//! essais, plus bas). `Avr` ajoute ce que fait main.c : esclave SPI au niveau des broches (mode 0,
//! poids fort en premier ; l'octet suivant est charge dans SPDR par l'interruption, ~3 us apres
//! la fin d'un octet : un 8088 trop rapide recoit le registre a decalage, compte dans
//! `trop_tot`), UART du terminal (decodeur de la ligne, generateur des trames emises), CTS et
//! vitesse ; et `Wifi`, un module AT simplifie au bout du canal 2.

use crate::serial::{bit_t, UartRx};

pub const VERSION: u8 = 4;
pub const SIGNATURE: u8 = 0xA5;

pub const IDENT: u8 = 0x00;
pub const ETAT: u8 = 0x01;
pub const LIRE: u8 = 0x02;
pub const ECRIRE: u8 = 0x03;
pub const VITESSE: u8 = 0x04;
pub const VIDER: u8 = 0x05;
/// Pont terminal <-> module (version 4) : octet suivant A5h = pont, autre = fin.
pub const PONT: u8 = 0x06;
/// + ETAT ... VIDER : canal 2 (Wi-Fi).
pub const CANAL2: u8 = 0x10;

pub const ETAT_RX_PLEIN: u8 = 0x01;
pub const ETAT_UART_ERR: u8 = 0x02;
pub const ETAT_TX_PLEIN: u8 = 0x04;
pub const ETAT_CTS: u8 = 0x40;
pub const ETAT_RTS: u8 = 0x80;

pub const V_NB: u8 = 7;
pub const V_AUCUNE: u8 = 0xFF;
/// Vitesses de VITESSE.
pub const VITESSES: [u64; 7] = [9600, 19200, 38400, 57600, 115200, 4800, 2400];
/// Vitesses a la mise sous tension : terminal 57600, module Wi-Fi 115200.
pub const V1_DEFAUT: u8 = 3;
pub const V2_DEFAUT: u8 = 4;

pub const RX_TAILLE: usize = 512;
pub const TX_TAILLE: usize = 64;
pub const RX_HAUT: usize = 384;
pub const RX_BAS: usize = 128;
pub const RX2_TAILLE: usize = 1024;
pub const TX2_TAILLE: usize = 128;

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
    Pont,
    Ignore,
}

/// Tampons d'un canal.
#[derive(Clone)]
struct Canal {
    rx: Vec<u8>,
    tx: Vec<u8>,
    rx_tete: usize,
    rx_nb: usize,
    tx_tete: usize,
    tx_nb: usize,
    drapeaux: u8,
}

impl Canal {
    fn new(rx: usize, tx: usize) -> Self {
        Canal { rx: vec![0; rx], tx: vec![0; tx], rx_tete: 0, rx_nb: 0, tx_tete: 0, tx_nb: 0, drapeaux: 0 }
    }
    fn vider(&mut self) {
        self.rx_tete = 0;
        self.rx_nb = 0;
        self.tx_tete = 0;
        self.tx_nb = 0;
        self.drapeaux = 0;
    }
    fn recu(&mut self, octet: u8, erreur: bool) {
        if erreur {
            self.drapeaux |= ETAT_UART_ERR;
        }
        let n = self.rx.len();
        if self.rx_nb < n {
            self.rx[(self.rx_tete + self.rx_nb) & (n - 1)] = octet;
            self.rx_nb += 1;
        } else {
            self.drapeaux |= ETAT_RX_PLEIN;
        }
    }
    #[cfg(test)]
    fn a_emettre_rx(&mut self) -> Option<u8> {
        if self.rx_nb == 0 {
            return None;
        }
        let b = self.rx[self.rx_tete];
        self.rx_tete = (self.rx_tete + 1) & (self.rx.len() - 1);
        self.rx_nb -= 1;
        Some(b)
    }
    fn a_emettre(&mut self) -> Option<u8> {
        if self.tx_nb == 0 {
            return None;
        }
        let b = self.tx[self.tx_tete];
        self.tx_tete = (self.tx_tete + 1) & (self.tx.len() - 1);
        self.tx_nb -= 1;
        Some(b)
    }
}

/// Protocole et tampons (protocole.c).
#[derive(Clone)]
pub struct Proto {
    pub irq: bool,
    pub rts: bool,
    pub cts: bool,
    /// Canal 1 : vitesse demandee (V_AUCUNE sinon) et vitesse en service.
    pub vitesse: u8,
    pub vit_courante: u8,
    /// Canal 2 : idem.
    pub vitesse2: u8,
    pub vit_courante2: u8,
    /// Pont (PONT) : terminal <-> module sans le 8088.
    pub pont: bool,
    c: [Canal; 2],
    can: usize,
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
            vit_courante: V1_DEFAUT,
            vitesse2: V_AUCUNE,
            vit_courante2: V2_DEFAUT,
            pont: false,
            c: [Canal::new(RX_TAILLE, TX_TAILLE), Canal::new(RX2_TAILLE, TX2_TAILLE)],
            can: 0,
            etat: E::Cmd,
            k: 0,
            n_lire: 0,
            lus: 0,
            donnee_chargee: false,
            en_transaction: false,
            instantane: [0; 5],
        };
        p.vider(0);
        p.vider(1);
        p
    }

    fn maj_irq(&mut self) {
        self.irq = self.c[0].rx_nb != 0 && !self.en_transaction;
    }

    fn vider(&mut self, can: usize) {
        self.c[can].vider();
        if can == 0 {
            self.rts = true;
        }
        self.maj_irq();
    }

    pub fn rx_nb(&self) -> usize {
        self.c[0].rx_nb
    }
    pub fn tx_nb(&self) -> usize {
        self.c[0].tx_nb
    }
    pub fn rx2_nb(&self) -> usize {
        self.c[1].rx_nb
    }
    pub fn tx2_nb(&self) -> usize {
        self.c[1].tx_nb
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
        let c = &self.c[self.can];
        if self.lus < self.n_lire && c.rx_nb != 0 {
            self.lus += 1;
            self.donnee_chargee = true;
            return c.rx[c.rx_tete];
        }
        0
    }

    pub fn spi(&mut self, recu: u8) -> u8 {
        if self.donnee_chargee {
            self.donnee_chargee = false;
            let c = &mut self.c[self.can];
            c.rx_tete = (c.rx_tete + 1) & (c.rx.len() - 1);
            c.rx_nb -= 1;
            if self.can == 0 {
                if self.c[0].rx_nb <= RX_BAS {
                    self.rts = true;
                }
                self.maj_irq();
            }
        }
        match self.etat {
            E::Cmd => {
                self.k = 0;
                if recu == IDENT {
                    self.etat = E::Ident;
                    return b'S';
                }
                if recu == PONT {
                    self.etat = E::Pont;
                    return 0;
                }
                let op = recu & !CANAL2;
                if !(ETAT..=VIDER).contains(&op) {
                    self.etat = E::Ignore;
                    return 0;
                }
                self.can = if recu & CANAL2 != 0 { 1 } else { 0 };
                match op {
                    ETAT => {
                        let c = &self.c[self.can];
                        let libre = c.tx.len() - c.tx_nb;
                        let lignes = if self.can == 0 {
                            (if self.cts { ETAT_CTS } else { 0 }) | if self.rts { ETAT_RTS } else { 0 }
                        } else {
                            ETAT_CTS | ETAT_RTS
                        };
                        self.instantane = [
                            c.rx_nb as u8,
                            (c.rx_nb >> 8) as u8,
                            libre as u8,
                            (libre >> 8) as u8,
                            c.drapeaux | lignes,
                        ];
                        self.c[self.can].drapeaux = 0;
                        self.etat = E::Etat;
                        self.instantane[0]
                    }
                    LIRE => {
                        self.n_lire = self.c[self.can].rx_nb.min(255) as u8;
                        self.lus = 0;
                        self.etat = E::Lire;
                        self.n_lire
                    }
                    ECRIRE => {
                        self.etat = E::EcrireF;
                        let c = &self.c[self.can];
                        (c.tx.len() - c.tx_nb).min(255) as u8
                    }
                    VITESSE => {
                        self.etat = E::Vitesse;
                        0
                    }
                    _ => {
                        self.etat = E::Vider;
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
                    4 => self.vit_courante2,
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
                let c = &mut self.c[self.can];
                let n = c.tx.len();
                if c.tx_nb < n {
                    c.tx[(c.tx_tete + c.tx_nb) & (n - 1)] = recu;
                    c.tx_nb += 1;
                } else {
                    c.drapeaux |= ETAT_TX_PLEIN;
                }
                0
            }
            E::Vitesse => {
                if recu < V_NB {
                    if self.can == 0 {
                        self.vitesse = recu;
                    } else {
                        self.vitesse2 = recu;
                    }
                }
                self.etat = E::Ignore;
                0
            }
            E::Vider => {
                if recu == SIGNATURE {
                    self.vider(self.can);
                }
                self.etat = E::Ignore;
                0
            }
            E::Pont => {
                self.pont = recu == SIGNATURE;
                self.etat = E::Ignore;
                0
            }
            E::Ignore => 0,
        }
    }

    /// Pont : octet recu du terminal, a emettre au module (false : plus de place, perdu).
    pub fn pont_vers_module(&mut self, octet: u8) -> bool {
        Self::ajoute(&mut self.c[1], octet)
    }

    /// Pont : octet recu du module, a emettre au terminal.
    pub fn pont_vers_terminal(&mut self, octet: u8) -> bool {
        Self::ajoute(&mut self.c[0], octet)
    }

    fn ajoute(c: &mut Canal, octet: u8) -> bool {
        let n = c.tx.len();
        if c.tx_nb >= n {
            c.drapeaux |= ETAT_TX_PLEIN;
            return false;
        }
        c.tx[(c.tx_tete + c.tx_nb) & (n - 1)] = octet;
        c.tx_nb += 1;
        true
    }

    /// Canal 1 (terminal).
    pub fn uart_recu(&mut self, octet: u8, erreur: bool) {
        self.c[0].recu(octet, erreur);
        if self.c[0].rx_nb >= RX_HAUT {
            self.rts = false;
        }
        self.maj_irq();
    }

    pub fn uart_a_emettre(&mut self) -> Option<u8> {
        self.c[0].a_emettre()
    }

    /// Canal 2 (Wi-Fi).
    pub fn uart2_recu(&mut self, octet: u8, erreur: bool) {
        self.c[1].recu(octet, erreur);
    }

    pub fn uart2_a_emettre(&mut self) -> Option<u8> {
        self.c[1].a_emettre()
    }
}

/// Module Grove - UART WiFi V2 (ESP8285, micrologiciel AT) simplifie : echo (ATE1 par defaut),
/// une ligne par CR LF, quelques commandes. Sans reseau : CWJAP repond comme un point d'acces
/// trouve, CIPSTART refuse.
#[derive(Clone)]
pub struct Wifi {
    ligne: Vec<u8>,
    echo: bool,
    /// Micrologiciel esp_slip_router (au lieu des commandes AT) : SLIP a 115200, le module
    /// (192.168.240.1) repond aux pings, et ceux vers une autre adresse comme s'ils
    /// traversaient le NAT vers Internet.
    pub slip: bool,
    trame: Vec<u8>,
    dans_esc: bool,
    /// Paquets IP recus en SLIP (mise au point, essais).
    pub paquets: u32,
    /// Octets a rendre a l'ATmega.
    pub sortie: std::collections::VecDeque<u8>,
    /// Lignes recues (mise au point, essais).
    pub journal: Vec<String>,
}

impl Default for Wifi {
    fn default() -> Self {
        Self::new()
    }
}

impl Wifi {
    pub fn new() -> Self {
        let mut w = Wifi {
            ligne: Vec::new(),
            echo: true,
            slip: false,
            trame: Vec::new(),
            dans_esc: false,
            paquets: 0,
            sortie: Default::default(),
            journal: Vec::new(),
        };
        w.dire("\r\nready\r\n");
        w
    }

    fn dire(&mut self, s: &str) {
        self.sortie.extend(s.bytes());
    }

    /// Passe au micrologiciel SLIP (ou revient aux commandes AT).
    pub fn mode_slip(&mut self, on: bool) {
        self.slip = on;
        self.sortie.clear();
        self.trame.clear();
    }

    fn slip_octet(&mut self, b: u8) {
        const END: u8 = 0xC0;
        const ESC: u8 = 0xDB;
        if self.dans_esc {
            self.trame.push(match b {
                0xDC => END,
                0xDD => ESC,
                x => x,
            });
            self.dans_esc = false;
        } else if b == ESC {
            self.dans_esc = true;
        } else if b == END {
            if !self.trame.is_empty() {
                let p = std::mem::take(&mut self.trame);
                self.paquets += 1;
                if let Some(r) = Self::reponse_ip(&p) {
                    self.sortie.push_back(END);
                    for x in r {
                        match x {
                            END => self.sortie.extend([ESC, 0xDC]),
                            ESC => self.sortie.extend([ESC, 0xDD]),
                            _ => self.sortie.push_back(x),
                        }
                    }
                    self.sortie.push_back(END);
                }
            }
        } else if self.trame.len() < 2048 {
            self.trame.push(b);
        }
    }

    fn somme(d: &[u8]) -> u16 {
        let mut s: u32 = 0;
        for c in d.chunks(2) {
            s += (c[0] as u32) << 8 | *c.get(1).unwrap_or(&0) as u32;
        }
        while s >> 16 != 0 {
            s = (s & 0xFFFF) + (s >> 16);
        }
        !(s as u16)
    }

    /// Reponse a un echo ICMP (IPv4) : adresses echangees, type 0, sommes recalculees.
    fn reponse_ip(p: &[u8]) -> Option<Vec<u8>> {
        if p.len() < 28 || p[0] >> 4 != 4 || p[9] != 1 {
            return None;
        }
        let lh = (p[0] & 15) as usize * 4;
        let total = (u16::from_be_bytes([p[2], p[3]]) as usize).min(p.len());
        if total < lh + 8 || p[lh] != 8 {
            return None;
        }
        let mut r = p[..total].to_vec();
        r.copy_within(12..16, 16);
        r[12..16].copy_from_slice(&p[16..20]);
        r[8] = 64;
        r[10] = 0;
        r[11] = 0;
        let c = Self::somme(&r[..lh]);
        r[10..12].copy_from_slice(&c.to_be_bytes());
        r[lh] = 0;
        r[lh + 2] = 0;
        r[lh + 3] = 0;
        let c = Self::somme(&r[lh..total]);
        r[lh + 2..lh + 4].copy_from_slice(&c.to_be_bytes());
        Some(r)
    }

    /// Octet recu du ATmega (canal 2).
    pub fn recu(&mut self, b: u8) {
        if self.slip {
            self.slip_octet(b);
            return;
        }
        if self.echo {
            self.sortie.push_back(b);
        }
        if b == b'\n' {
            let l = String::from_utf8_lossy(&self.ligne).trim_end_matches('\r').to_string();
            self.ligne.clear();
            self.commande(&l);
        } else if self.ligne.len() < 256 {
            self.ligne.push(b);
        }
    }

    fn commande(&mut self, l: &str) {
        if self.journal.len() < 256 {
            self.journal.push(l.to_string());
        }
        let u = l.to_ascii_uppercase();
        if u.is_empty() {
            return;
        }
        let r: String = if u == "AT" {
            "\r\nOK\r\n".into()
        } else if u == "ATE0" {
            self.echo = false;
            "\r\nOK\r\n".into()
        } else if u == "ATE1" {
            self.echo = true;
            "\r\nOK\r\n".into()
        } else if u == "AT+RST" {
            "\r\nOK\r\n\r\nready\r\n".into()
        } else if u == "AT+GMR" {
            "AT version:0.40.0.0(simulateur)\r\nSDK version:1.1.0\r\n\r\nOK\r\n".into()
        } else if u.starts_with("AT+CWMODE") {
            "\r\nOK\r\n".into()
        } else if u.starts_with("AT+CWJAP") && u.contains('=') {
            "WIFI CONNECTED\r\nWIFI GOT IP\r\n\r\nOK\r\n".into()
        } else if u == "AT+CIFSR" {
            "+CIFSR:STAIP,\"192.168.1.50\"\r\n+CIFSR:STAMAC,\"18:fe:34:00:00:02\"\r\n\r\nOK\r\n".into()
        } else if u.starts_with("AT+CIPSTART") {
            "\r\nERROR\r\nCLOSED\r\n".into()
        } else {
            "\r\nERROR\r\n".into()
        };
        self.dire(&r);
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
    /// Canal 2 : USART materiel -> module Wi-Fi (115200 bauds au demarrage).
    pub baud2: u64,
    pub wifi: Wifi,
    /// Octets en route vers le module : (fin de la trame, octet, vitesse de l'ATmega).
    vers_wifi: std::collections::VecDeque<(u64, u8, u64)>,
    fin_tx2: u64,
    /// Fin de la prochaine trame du module vers l'ATmega.
    proch_rx2: u64,
    pub emis2: u64,
    pub recus2: u64,
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
            baud: VITESSES[V1_DEFAUT as usize],
            gen: {
                let mut g = UartRx::new();
                g.baud = VITESSES[V1_DEFAUT as usize];
                g
            },
            vers_terminal: std::collections::VecDeque::new(),
            fin_tx: 0,
            octets_spi: 0,
            trop_tot: 0,
            recus: 0,
            emis: 0,
            journal: Vec::new(),
            octet_tr: 0,
            baud2: VITESSES[V2_DEFAUT as usize],
            wifi: Wifi::new(),
            vers_wifi: std::collections::VecDeque::new(),
            fin_tx2: 0,
            proch_rx2: 0,
            emis2: 0,
            recus2: 0,
        }
    }

    /// Canal 2 jusqu'a l'instant t : USART <-> module (115200 bauds, sans controle de flux).
    /// A une autre vitesse que 115200, le module recoit et rend des octets faux.
    fn service2(&mut self, t: u64) {
        const MODULE: u64 = 115200;
        if self.p.vitesse2 != V_AUCUNE && self.p.tx2_nb() == 0 && self.fin_tx2 <= t {
            self.baud2 = VITESSES[self.p.vitesse2 as usize];
            self.p.vit_courante2 = self.p.vitesse2;
            self.p.vitesse2 = V_AUCUNE;
        }
        while self.fin_tx2 <= t {
            let Some(b) = self.p.uart2_a_emettre() else { break };
            self.fin_tx2 = self.fin_tx2.max(t) + bit_t(10, self.baud2);
            self.vers_wifi.push_back((self.fin_tx2, b, self.baud2));
            self.emis2 += 1;
        }
        while let Some(&(f, b, baud)) = self.vers_wifi.front() {
            if f > t {
                break;
            }
            self.vers_wifi.pop_front();
            self.wifi.recu(if baud == MODULE { b } else { b ^ 0x5A });
        }
        if self.wifi.sortie.is_empty() {
            self.proch_rx2 = self.proch_rx2.max(t);
        } else {
            if self.proch_rx2 == 0 {
                self.proch_rx2 = t + bit_t(10, MODULE);
            }
            while self.proch_rx2 <= t {
                let Some(b) = self.wifi.sortie.pop_front() else { break };
                let faux = self.baud2 != MODULE;
                let b = if faux { b ^ 0x5A } else { b };
                if self.p.pont {
                    self.p.pont_vers_terminal(b);
                } else {
                    self.p.uart2_recu(b, faux);
                }
                self.recus2 += 1;
                self.proch_rx2 += bit_t(10, MODULE);
            }
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
        if self.p.pont {
            self.p.pont_vers_module(octet);
        } else {
            self.p.uart_recu(octet, erreur);
        }
        self.recus += 1;
    }

    /// Ce que font la boucle principale et les interruptions de l'USART jusqu'a l'instant t.
    pub fn service(&mut self, t: u64) {
        self.service2(t);
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
        // canal 2 : prochaine trame vers le module, ou du module
        if let Some(&(f, _, _)) = self.vers_wifi.front() {
            n = n.min(f.max(t + 1));
        }
        if self.p.tx2_nb() != 0 {
            n = n.min(self.fin_tx2.max(t + 1));
        }
        if !self.wifi.sortie.is_empty() {
            n = n.min(self.proch_rx2.max(t + 1));
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
        assert_eq!(
            m.transaction(&[IDENT, 0, 0, 0, 0, 0, 0]),
            vec![0xA5, b'S', b'2', VERSION, V1_DEFAUT, V2_DEFAUT, 0]
        );
        m.p.vit_courante = 4;
        m.p.vit_courante2 = 0;
        let r = m.transaction(&[IDENT, 0, 0, 0, 0, 0]);
        assert_eq!((r[4], r[5]), (4, 0), "IDENT : vitesses courantes");
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
        assert_eq!(m.ecrire(b"hello") as usize, TX_TAILLE.min(255));
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

    /// Canal 2 (Wi-Fi) : independant du canal 1 (pas d'IRQ, pas de RTS), commandes 11h-15h.
    #[test]
    fn canal2() {
        let mut m = Maitre::new();
        m.p.uart2_recu(b'O', false);
        m.p.uart2_recu(b'K', false);
        assert!(!m.p.irq && m.p.rx_nb() == 0 && m.p.rx2_nb() == 2);
        let r = m.transaction(&[CANAL2 | ETAT, 0, 0, 0, 0, 0]);
        assert_eq!(&r[1..], &[2, 0, TX2_TAILLE as u8, 0, ETAT_CTS | ETAT_RTS]);
        m.recevoir(b"t");
        assert_eq!(m.transaction(&[CANAL2 | LIRE, 0, 0, 0, 0]), vec![0xA5, 2, b'O', b'K', 0]);
        assert!(m.p.rx2_nb() == 0 && m.p.rx_nb() == 1 && m.p.irq);
        m.transaction(&[CANAL2 | ECRIRE, 0, b'A', b'T', 13, 10]);
        assert_eq!(m.p.tx2_nb(), 4);
        assert_eq!(m.p.tx_nb(), 0);
        let e: Vec<u8> = std::iter::from_fn(|| m.p.uart2_a_emettre()).collect();
        assert_eq!(e, b"AT\r\n");
        m.transaction(&[CANAL2 | VITESSE, 0]);
        assert_eq!((m.p.vitesse2, m.p.vitesse), (0, V_AUCUNE));
        for i in 0..RX2_TAILLE + 2 {
            m.p.uart2_recu(i as u8, false);
        }
        assert!(m.p.rx2_nb() == RX2_TAILLE && m.p.rts);
        assert!(m.transaction(&[CANAL2 | ETAT, 0, 0, 0, 0, 0])[5] & ETAT_RX_PLEIN != 0);
        m.transaction(&[CANAL2 | VIDER, SIGNATURE]);
        assert!(m.p.rx2_nb() == 0 && m.p.rx_nb() == 1);
        assert_eq!(m.transaction(&[0x16, 0]), vec![0xA5, 0]);
    }

    /// PONT (version 4) : seulement avec A5h ; terminal -> module, module -> terminal.
    #[test]
    fn pont() {
        let mut m = Maitre::new();
        m.transaction(&[PONT, 0]);
        assert!(!m.p.pont);
        m.transaction(&[PONT, SIGNATURE]);
        assert!(m.p.pont);
        assert!(m.p.pont_vers_module(b'x') && m.p.uart2_a_emettre() == Some(b'x'));
        assert!(m.p.pont_vers_terminal(b'y') && m.p.uart_a_emettre() == Some(b'y'));
        m.transaction(&[PONT, 0]);
        assert!(!m.p.pont);
    }

    /// Module en SLIP : un ping (ICMP echo) recoit sa reponse, adresses echangees.
    #[test]
    fn module_slip_ping() {
        let mut w = Wifi::new();
        w.mode_slip(true);
        let mut p = vec![0x45, 0, 0, 28, 0x12, 0x34, 0, 0, 64, 1, 0, 0, 192, 168, 240, 2, 8, 8, 8, 8];
        let c = Wifi::somme(&p);
        p[10..12].copy_from_slice(&c.to_be_bytes());
        let mut icmp = vec![8, 0, 0, 0, 0xAB, 0xCD, 0, 1];
        let c = Wifi::somme(&icmp);
        icmp[2..4].copy_from_slice(&c.to_be_bytes());
        p.extend(icmp);
        w.recu(0xC0);
        for &b in &p {
            match b {
                0xC0 => [0xDB, 0xDC].iter().for_each(|&x| w.recu(x)),
                0xDB => [0xDB, 0xDD].iter().for_each(|&x| w.recu(x)),
                _ => w.recu(b),
            }
        }
        w.recu(0xC0);
        let brut: Vec<u8> = w.sortie.drain(..).collect();
        let mut r = vec![0xC0];             // (desechappement de la reponse)
        let mut i = 1;
        while i < brut.len() - 1 {
            if brut[i] == 0xDB {
                r.push(if brut[i + 1] == 0xDC { 0xC0 } else { 0xDB });
                i += 2;
            } else {
                r.push(brut[i]);
                i += 1;
            }
        }
        r.push(0xC0);
        assert_eq!((r[0], *r.last().unwrap()), (0xC0, 0xC0));
        let r = &r[1..r.len() - 1];
        assert_eq!(&r[12..16], &[8, 8, 8, 8]);
        assert_eq!(&r[16..20], &[192, 168, 240, 2]);
        assert_eq!(r[20], 0, "echo reply");
        assert_eq!(Wifi::somme(&r[..20]), 0);
        assert_eq!(Wifi::somme(&r[20..]), 0);
    }

    /// Module AT : echo, OK, ATE0, ERROR.
    #[test]
    fn module_wifi() {
        let mut w = Wifi::new();
        w.sortie.clear();
        for &b in b"AT\r\n" {
            w.recu(b);
        }
        let r: Vec<u8> = w.sortie.drain(..).collect();
        assert_eq!(r, b"AT\r\n\r\nOK\r\n");
        for &b in b"ATE0\r\nAT+XYZ\r\n" {
            w.recu(b);
        }
        let r: Vec<u8> = w.sortie.drain(..).collect();
        assert_eq!(String::from_utf8_lossy(&r), "ATE0\r\n\r\nOK\r\n\r\nERROR\r\n");
    }

    /// AT au bout du canal 2, a travers l'Avr : 115200 bauds, octets remis au rythme du module.
    #[test]
    fn avr_vers_module() {
        let mut a = Avr::new();
        a.wifi.sortie.clear();          // ("ready" du module)
        let mut m = Maitre { p: std::mem::take(&mut a.p), prepare: SIGNATURE };
        m.p.c[1].vider();
        m.transaction(&[CANAL2 | ECRIRE, 0, b'A', b'T', 13, 10]);
        a.p = m.p;
        let mut t = 2_000_000u64;
        for _ in 0..200 {
            t += 100;
            a.service(t);
        }
        assert_eq!(a.wifi.journal, vec!["AT".to_string()]);
        let mut v = Vec::new();
        while let Some(b) = a.p.c[1].a_emettre_rx() {
            v.push(b);
        }
        assert_eq!(String::from_utf8_lossy(&v), "AT\r\n\r\nOK\r\n");
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
