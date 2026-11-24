//! Coeur du micrologiciel du Raspberry Pi Pico W de Solution-02.
//!
//! Le Pico est un peripherique d'E/S du 8088 sur O5 du 74LS138 (ports 50h-5Fh, A0-A2 :
//! 8 registres, repetes en 58h-5Fh), derriere deux SN74LVC245 (U18 donnees, U19 adresses et
//! commandes). Ce module ne touche a aucun materiel : il recoit les acces du bus
//! ([`Coeur::lire_port`], [`Coeur::ecrire_port`]), execute les commandes avec une carte SD
//! fournie par l'appelant ([`Carte`]) et relaie le reseau du 8088 (SLIP) vers un hote
//! ([`hote`]) qui ouvre les vraies connexions (Wi-Fi du Pico, ou simulateur).
//!
//! Le meme code tourne dans le micrologiciel (pico/micrologiciel) et dans le simulateur
//! (Simulateur-Pico) : ce que le simulateur montre est ce que le Pico fait.
//!
//! # Registres (port = 50h + n)
//!
//! | n | Lecture | Ecriture |
//! |---|---|---|
//! | 0 | octet suivant de la file de lecture (FFh si vide) | octet dans la file d'ecriture |
//! | 1 | ETAT (bits `E_*`) | COMMANDE (`C_*`) |
//! | 2-5 | PARAMETRES 0-3 (LBA en petit-boutiste, nombre...) | idem |
//! | 6 | signature `SIGNATURE` (50h) | masque d'interruption (bit 0 : donnees reseau) |
//! | 7 | octets dans la file de lecture (255 au plus) | (sans effet) |
//!
//! Un registre ETAT a 0FFh signifie : pas de Pico (bus en l'air). Le bit 7 d'ETAT vaut
//! toujours 0.

#![no_std]
extern crate alloc;

#[cfg(feature = "pio")]
pub mod bus_pio;
pub mod hote;
pub mod reseau;
pub mod slip;

use alloc::collections::VecDeque;
use alloc::vec::Vec;

pub use hote::{DeHote, VersHote};
pub use reseau::{Limites, Reseau};

/// Version du protocole des registres.
pub const VERSION: u8 = 1;
/// Lue au registre 6.
pub const SIGNATURE: u8 = 0x50;
/// Reponse a IDENT : 7 lettres puis la version.
pub const IDENT: &[u8; 7] = b"S02PICO";

// registres
pub const R_DONNEE: u8 = 0;
pub const R_ETAT: u8 = 1;
pub const R_PARAM: u8 = 2;
pub const R_SIGNATURE: u8 = 6;
pub const R_NOMBRE: u8 = 7;

// bits d'ETAT
pub const E_DONNEE: u8 = 0x01;
pub const E_OCCUPE: u8 = 0x02;
pub const E_ERREUR: u8 = 0x04;
pub const E_RESEAU: u8 = 0x08;
pub const E_CARTE: u8 = 0x10;
pub const E_WIFI: u8 = 0x20;
pub const E_IRQ: u8 = 0x40;

// commandes
pub const C_VIDER: u8 = 0x00;
pub const C_IDENT: u8 = 0x01;
pub const C_SD_INIT: u8 = 0x10;
pub const C_SD_LIRE: u8 = 0x11;
pub const C_SD_ECRIRE: u8 = 0x12;
pub const C_NET_LIRE: u8 = 0x20;
pub const C_NET_ECRIRE: u8 = 0x21;
pub const C_NET_ETAT: u8 = 0x22;
pub const C_WIFI_SSID: u8 = 0x30;
pub const C_WIFI_MDP: u8 = 0x31;
pub const C_WIFI_CONNECTER: u8 = 0x32;

/// Taille maximale de la file d'ecriture (octets du 8088 en attente d'une commande).
pub const ECRITURE_MAX: usize = 4096;
pub const SECTEUR: usize = 512;

/// Carte SD vue par le coeur (SPI0 du Pico, ou carte du simulateur).
pub trait Carte {
    /// Initialise la carte : nombre de secteurs de 512 octets, ou None (pas de carte).
    fn init(&mut self) -> Option<u32>;
    fn lire(&mut self, lba: u32, d: &mut [u8; SECTEUR]) -> bool;
    fn ecrire(&mut self, lba: u32, d: &[u8; SECTEUR]) -> bool;
}

/// Compteurs (affichage, essais).
#[derive(Clone, Default, Debug)]
pub struct Stats {
    pub commandes: u32,
    pub lectures_bus: u64,
    pub ecritures_bus: u64,
    pub sd_lus: u32,
    pub sd_ecrits: u32,
    pub sd_erreurs: u32,
    pub lectures_vides: u32,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Commande {
    Rien,
    Attente(u8),
}

/// Le peripherique tel que le 8088 le voit.
pub struct Coeur {
    lecture: VecDeque<u8>,
    ecriture: Vec<u8>,
    param: [u8; 4],
    cmd: Commande,
    erreur: bool,
    carte_ok: bool,
    pub secteurs: u32,
    masque_irq: u8,
    ssid: Vec<u8>,
    mdp: Vec<u8>,
    pub reseau: Reseau,
    pub stats: Stats,
}

impl Default for Coeur {
    fn default() -> Self {
        Self::new()
    }
}

impl Coeur {
    pub fn new() -> Self {
        Self::avec(Limites::default())
    }

    pub fn avec(limites: Limites) -> Self {
        Coeur {
            lecture: VecDeque::new(),
            ecriture: Vec::new(),
            param: [0; 4],
            cmd: Commande::Rien,
            erreur: false,
            carte_ok: false,
            secteurs: 0,
            masque_irq: 0,
            ssid: Vec::new(),
            mdp: Vec::new(),
            reseau: Reseau::avec(limites),
            stats: Stats::default(),
        }
    }

    /// RESET du 8088 (lu par GP14) : files videes, commande abandonnee, interruption masquee.
    /// Le reseau et la carte restent tels quels (connexions Wi-Fi gardees).
    pub fn reinitialiser(&mut self) {
        self.lecture.clear();
        self.ecriture.clear();
        self.param = [0; 4];
        self.cmd = Commande::Rien;
        self.erreur = false;
        self.masque_irq = 0;
    }

    pub fn etat(&self) -> u8 {
        let mut e = 0;
        if !self.lecture.is_empty() {
            e |= E_DONNEE;
        }
        if self.occupe() {
            e |= E_OCCUPE;
        }
        if self.erreur {
            e |= E_ERREUR;
        }
        if self.reseau.a_lire() > 0 {
            e |= E_RESEAU;
        }
        if self.carte_ok {
            e |= E_CARTE;
        }
        if self.reseau.wifi.connecte {
            e |= E_WIFI;
        }
        if self.irq() {
            e |= E_IRQ;
        }
        e
    }

    /// Ligne d'interruption (GP22 -> IRQ3 par J16) : donnees reseau pour le 8088.
    pub fn irq(&self) -> bool {
        self.masque_irq & 1 != 0 && self.reseau.a_lire() > 0
    }

    /// Une commande attend d'etre executee ([`Coeur::executer`]).
    pub fn occupe(&self) -> bool {
        self.cmd != Commande::Rien
    }

    pub fn commande_en_attente(&self) -> Option<u8> {
        match self.cmd {
            Commande::Attente(c) => Some(c),
            Commande::Rien => None,
        }
    }

    /// Octets dans la file de lecture.
    pub fn a_lire(&self) -> usize {
        self.lecture.len()
    }

    /// Lecture du 8088 au port 50h + reg (reg = A0-A2).
    pub fn lire_port(&mut self, reg: u8) -> u8 {
        self.stats.lectures_bus += 1;
        match reg & 7 {
            R_DONNEE => match self.lecture.pop_front() {
                Some(v) => v,
                None => {
                    self.stats.lectures_vides += 1;
                    0xFF
                }
            },
            R_ETAT => self.etat(),
            2..=5 => self.param[(reg & 7) as usize - 2],
            R_SIGNATURE => SIGNATURE,
            _ => self.lecture.len().min(255) as u8,
        }
    }

    /// Ecriture du 8088 au port 50h + reg.
    pub fn ecrire_port(&mut self, reg: u8, v: u8) {
        self.stats.ecritures_bus += 1;
        match reg & 7 {
            R_DONNEE => {
                if self.ecriture.len() < ECRITURE_MAX {
                    self.ecriture.push(v);
                } else {
                    self.erreur = true;
                }
            }
            R_ETAT => {
                self.stats.commandes += 1;
                if v == C_VIDER {
                    // immediate : sert aussi a sortir d'un etat inconnu
                    self.lecture.clear();
                    self.ecriture.clear();
                    self.erreur = false;
                    self.cmd = Commande::Rien;
                } else {
                    self.cmd = Commande::Attente(v);
                }
            }
            2..=5 => self.param[(reg & 7) as usize - 2] = v,
            R_SIGNATURE => self.masque_irq = v,
            _ => {}
        }
    }

    fn lba(&self) -> u32 {
        u32::from_le_bytes(self.param)
    }

    /// Execute la commande en attente (boucle principale du Pico ; le simulateur l'appelle
    /// apres la duree de la commande). `now_ms` sert au reseau.
    pub fn executer(&mut self, carte: &mut dyn Carte, now_ms: u64) {
        let c = match self.cmd {
            Commande::Attente(c) => c,
            Commande::Rien => return,
        };
        self.cmd = Commande::Rien;
        self.erreur = false;
        match c {
            C_IDENT => {
                self.lecture.clear();
                self.lecture.extend(IDENT.iter().copied());
                self.lecture.push_back(VERSION);
            }
            C_SD_INIT => {
                self.lecture.clear();
                match carte.init() {
                    Some(n) => {
                        self.carte_ok = true;
                        self.secteurs = n;
                        self.lecture.push_back(1);
                        self.lecture.extend(n.to_le_bytes());
                    }
                    None => {
                        self.carte_ok = false;
                        self.secteurs = 0;
                        self.erreur = true;
                        self.lecture.push_back(0);
                        self.lecture.extend([0u8; 4]);
                    }
                }
            }
            C_SD_LIRE => {
                self.lecture.clear();
                let mut d = [0u8; SECTEUR];
                if self.carte_ok && carte.lire(self.lba(), &mut d) {
                    self.stats.sd_lus += 1;
                    self.lecture.extend(d);
                } else {
                    self.stats.sd_erreurs += 1;
                    self.erreur = true;
                }
            }
            C_SD_ECRIRE => {
                if self.ecriture.len() < SECTEUR || !self.carte_ok {
                    self.erreur = true;
                    self.stats.sd_erreurs += 1;
                } else {
                    let mut d = [0u8; SECTEUR];
                    d.copy_from_slice(&self.ecriture[..SECTEUR]);
                    self.ecriture.drain(..SECTEUR);
                    if carte.ecrire(self.lba(), &d) {
                        self.stats.sd_ecrits += 1;
                    } else {
                        self.stats.sd_erreurs += 1;
                        self.erreur = true;
                    }
                }
            }
            C_NET_LIRE => {
                self.lecture.clear();
                let max = if self.param[0] == 0 { 255 } else { self.param[0] as usize };
                let n = self.reseau.a_lire().min(max);
                self.lecture.push_back(n as u8);
                for _ in 0..n {
                    if let Some(b) = self.reseau.prendre() {
                        self.lecture.push_back(b);
                    }
                }
            }
            C_NET_ECRIRE => {
                let d = core::mem::take(&mut self.ecriture);
                self.reseau.depuis_8088(&d, now_ms);
            }
            C_NET_ETAT => {
                self.lecture.clear();
                let n = self.reseau.a_lire().min(0xFFFF) as u16;
                self.lecture.extend(n.to_le_bytes());
                let w = &self.reseau.wifi;
                self.lecture.push_back(w.connecte as u8);
                self.lecture.extend(w.ip);
                self.lecture.push_back(w.rssi as u8);
            }
            C_WIFI_SSID => self.ssid = core::mem::take(&mut self.ecriture),
            C_WIFI_MDP => self.mdp = core::mem::take(&mut self.ecriture),
            C_WIFI_CONNECTER => {
                self.reseau.sortants.push_back(VersHote::Wifi {
                    ssid: self.ssid.clone(),
                    mdp: self.mdp.clone(),
                });
            }
            _ => self.erreur = true,
        }
    }

    /// Tache de fond : pile TCP du cote du 8088, minuteries (a appeler souvent).
    pub fn poll(&mut self, now_ms: u64) {
        self.reseau.poll(now_ms);
    }
}



