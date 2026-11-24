//! Raspberry Pi Pico W (A1) sur la carte : U18/U19 (SN74LVC245), O5 du 74LS138 (ports
//! 50h-5Fh), READY (Q1, RDY1 du 82C84), IRQ3 par le cavalier J16, microSD J14.
//!
//! Le comportement vient du coeur du vrai micrologiciel (s02pico-coeur) ; ce module n'ajoute
//! que le temps :
//! - chaque lecture du 8088 au Pico passe par l'automate PIO, qui tient RDY1 a 0 (GP26 -> Q1)
//!   jusqu'a ce que le coeur 1 du RP2040 ait pose l'octet : `attentes` etats d'attente
//!   (3 par defaut : ~0,56 µs ; essai au cycle pres de pico/coeur/tests/pio_bus.rs : 1,7 a 6,4
//!   selon la latence du coeur 1) ;
//! - les commandes durent ce qu'elles durent sur le Pico (lecture d'un secteur de la carte
//!   en SPI a 12,5 MHz : ~0,4 ms...), pendant lesquelles ETAT montre OCCUPE.

use s02pico_coeur::{Carte, Coeur};

use crate::internet::Internet;
use crate::sd::SdCard;
use crate::CLK_HZ;

/// La carte de J14 vue par le coeur.
pub struct CarteSim<'a>(pub &'a mut SdCard);

impl Carte for CarteSim<'_> {
    fn init(&mut self) -> Option<u32> {
        self.0.disk.as_ref().map(|d| d.nsec)
    }
    fn lire(&mut self, lba: u32, d: &mut [u8; 512]) -> bool {
        match &self.0.disk {
            Some(k) if lba < k.nsec => {
                d.copy_from_slice(&k.read(lba));
                self.0.reads += 1;
                self.0.last_lba = lba;
                self.0.last_cmd = 17;
                true
            }
            _ => false,
        }
    }
    fn ecrire(&mut self, lba: u32, d: &[u8; 512]) -> bool {
        match self.0.disk.as_mut() {
            Some(k) if lba < k.nsec => {
                k.write(lba, d);
                self.0.writes += 1;
                self.0.last_lba = lba;
                self.0.last_cmd = 24;
                true
            }
            _ => false,
        }
    }
}

#[derive(Clone)]
pub struct PicoCfg {
    /// Etats d'attente par lecture (READY).
    pub attentes: u32,
    /// Cavalier J16 : GP22 -> IRQ3.
    pub j16: bool,
}

impl Default for PicoCfg {
    fn default() -> Self {
        PicoCfg { attentes: 3, j16: true }
    }
}

pub struct PicoW {
    pub coeur: Coeur,
    pub internet: Internet,
    pub cfg: PicoCfg,
    /// Instant (cycles du 8088) ou la commande en attente sera faite.
    pret_a: Option<u64>,
    dernier_poll_ms: u64,
    /// Etats d'attente inseres (total).
    pub attentes_total: u64,
    pub lectures: u64,
    pub ecritures: u64,
}

/// Copie d'etat (instantanes du simulateur) : la pile TCP de smoltcp ne se copie pas ; la
/// copie repart comme un Pico qui redemarre (memes reglages, connexions perdues).
impl Clone for PicoW {
    fn clone(&self) -> Self {
        let mut n = PicoW::new(self.cfg.clone());
        n.internet.js = self.internet.js;
        n
    }
}

pub fn ms(cycles: u64) -> u64 {
    (cycles as f64 * 1000.0 / CLK_HZ) as u64
}

fn cycles(s: f64) -> u64 {
    (s * CLK_HZ) as u64
}

impl PicoW {
    pub fn new(cfg: PicoCfg) -> Self {
        let mut coeur = Coeur::new();
        coeur.reseau.version = concat!("simule ", env!("CARGO_PKG_VERSION"));
        PicoW {
            coeur,
            internet: Internet::new(),
            cfg,
            pret_a: None,
            dernier_poll_ms: 0,
            attentes_total: 0,
            lectures: 0,
            ecritures: 0,
        }
    }

    /// Duree d'une commande sur le vrai Pico (secondes).
    fn duree(cmd: u8) -> f64 {
        use s02pico_coeur::*;
        match cmd {
            C_SD_INIT => 0.020,
            C_SD_LIRE => 0.000_40,
            C_SD_ECRIRE => 0.001_2,
            C_NET_ECRIRE | C_NET_LIRE => 0.000_015,
            _ => 0.000_005,
        }
    }

    /// RESET du 8088 (GP14).
    pub fn reset(&mut self) {
        self.coeur.reinitialiser();
        self.pret_a = None;
    }

    /// Lecture du 8088 (port 50h + reg) : valeur et etats d'attente.
    pub fn lire(&mut self, reg: u8, now: u64, carte: &mut SdCard) -> (u8, u32) {
        self.avancer(now, carte);
        self.lectures += 1;
        let v = self.coeur.lire_port(reg);
        self.attentes_total += self.cfg.attentes as u64;
        (v, self.cfg.attentes)
    }

    pub fn ecrire(&mut self, reg: u8, v: u8, now: u64, carte: &mut SdCard) {
        self.avancer(now, carte);
        self.ecritures += 1;
        self.coeur.ecrire_port(reg, v);
        if let Some(c) = self.coeur.commande_en_attente() {
            if self.pret_a.is_none() {
                self.pret_a = Some(now + cycles(Self::duree(c)).max(1));
            }
        }
    }

    /// Fait avancer le Pico jusqu'a `now` : commande due, reseau, Internet simule.
    pub fn avancer(&mut self, now: u64, carte: &mut SdCard) {
        if let Some(t) = self.pret_a {
            if now >= t {
                self.pret_a = None;
                let mut k = CarteSim(carte);
                self.coeur.executer(&mut k, ms(now));
            }
        }
        let t_ms = ms(now);
        let mut bouge = false;
        for m in self.internet.dues(t_ms) {
            self.coeur.reseau.recevoir(m);
            bouge = true;
        }
        if bouge || t_ms >= self.dernier_poll_ms + 10 {
            self.dernier_poll_ms = t_ms;
            self.coeur.poll(t_ms);
        }
        while let Some(m) = self.coeur.reseau.sortants.pop_front() {
            self.internet.depuis_pico(m, t_ms);
            bouge = true;
        }
        if bouge {
            // reponses immediates (delai nul) de l'Internet simule
            for m in self.internet.dues(t_ms) {
                self.coeur.reseau.recevoir(m);
            }
        }
    }

    /// Prochain instant (cycles) ou le Pico doit etre servi.
    pub fn prochain(&self, now: u64) -> u64 {
        let mut t = u64::MAX;
        if let Some(p) = self.pret_a {
            t = t.min(p);
        }
        if let Some(m) = self.internet.prochain() {
            t = t.min(cycles(m as f64 / 1000.0) + 1);
        }
        if self.coeur.reseau.connexions() > 0 {
            t = t.min(now + cycles(0.010));
        }
        t
    }

    /// GP22 : interruption (donnees reseau pour le 8088).
    pub fn irq(&self) -> bool {
        self.coeur.irq()
    }

    /// GP26 : le PIO tient RDY1 a 0 pendant une lecture.
    pub fn occupe(&self) -> bool {
        self.pret_a.is_some()
    }
}
