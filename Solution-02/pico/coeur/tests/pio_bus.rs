//! Essai au cycle pres de l'automate PIO du bus (src/bus_pio.rs) face au 8088 :
//! - un emulateur des automates PIO du RP2040 (le vrai programme assemble, decode mot par mot,
//!   125 MHz, synchroniseur d'entree de 2 cycles) ;
//! - le 8088 a 5,333 MHz (82C84 : horloge 1/3 haute, READY synchronise en deux etages,
//!   ASYNC# a 0), ses cycles d'E/S en 50h-5Fh avec les pires temps de la fiche technique ;
//! - Q1 (2N3904) et la resistance de tirage de RDY1, U18/U19 (SN74LVC245, ~7 ns), RN4 ;
//! - le coeur 1 du RP2040 (latence reglable entre le mot du PIO et la reponse).
//!
//! On verifie : octet lu correct a l'instant ou le 8088 l'echantillonne, octet ecrit capte,
//! pas de conflit sur D0-D7 (le Pico ne pilote que pendant ~RD = 0), et le nombre d'etats
//! d'attente selon la latence du coeur 1.
//!
//! cargo test --features pio --test pio_bus -- --nocapture

use s02pico_coeur::bus_pio::{self, BROCHE_RD, BROCHE_SEL, BROCHE_WR};
use std::collections::VecDeque;

const NS_PIO: f64 = 8.0; // 125 MHz
const T: f64 = 187.5; // un etat du 8088
const LVC: f64 = 7.0; // SN74LVC245
const Q1_ON: f64 = 60.0; // GP26 -> RDY1 bas
const Q1_OFF: f64 = 200.0; // GP26 -> RDY1 haut (stockage de Q1, tirage de 10k)

// ------------------------------------------------------------------ PIO
struct Pio {
    code: Vec<u16>,
    wrap_src: u8,
    wrap_tgt: u8,
    pc: u8,
    x: u32,
    y: u32,
    isr: u32,
    osr: u32,
    delai: u8,
    rx: VecDeque<u32>,
    tx: VecDeque<u32>,
    sorties: u32,
    dirs: u32,
    side: bool,
    /// Instruction en attente (wait, push/pull bloques) : side-set deja applique.
    commencee: bool,
}

impl Pio {
    fn new() -> Self {
        let p = bus_pio::programme();
        Pio {
            code: p.code.iter().copied().collect(),
            wrap_src: p.wrap.source,
            wrap_tgt: p.wrap.target,
            pc: 0,
            x: 0,
            y: 0,
            isr: 0,
            osr: 0,
            delai: 0,
            rx: VecDeque::new(),
            tx: VecDeque::new(),
            sorties: 0,
            dirs: 0,
            side: false,
            commencee: false,
        }
    }

    fn suivant(&mut self) {
        if self.pc == self.wrap_src {
            self.pc = self.wrap_tgt;
        } else {
            self.pc += 1;
        }
    }

    /// Un cycle de l'automate ; `e` = broches vues (apres le synchroniseur).
    fn cycle(&mut self, e: u32) {
        if self.delai > 0 {
            self.delai -= 1;
            return;
        }
        let i = self.code[self.pc as usize];
        let ds = (i >> 8) & 0x1F;
        // .side_set 1 opt : bit 12 = valide, bit 11 = valeur, bits 10-8 = delai
        if !self.commencee && ds & 0x10 != 0 {
            self.side = ds & 0x08 != 0;
        }
        let delai = (ds & 7) as u8;
        let op = i >> 13;
        let a = ((i >> 5) & 7) as u8;
        let b = (i & 0x1F) as u32;
        let n = if b == 0 { 32 } else { b };
        let masque = |n: u32| if n == 32 { u32::MAX } else { (1u32 << n) - 1 };
        let mut fini = true;
        let mut saut = None;
        match op {
            0 => {
                let c = match a {
                    0 => true,
                    1 => self.x == 0,
                    2 => {
                        let c = self.x != 0;
                        self.x = self.x.wrapping_sub(1);
                        c
                    }
                    3 => self.y == 0,
                    4 => {
                        let c = self.y != 0;
                        self.y = self.y.wrapping_sub(1);
                        c
                    }
                    5 => self.x != self.y,
                    6 => e >> BROCHE_RD & 1 != 0, // JMP_PIN = ~RD
                    _ => panic!("jmp !osre"),
                };
                if c {
                    saut = Some(b as u8);
                }
            }
            1 => {
                let pol = (i >> 7) & 1 != 0;
                let src = (i >> 5) & 3;
                assert_eq!(src, 0, "wait : seulement gpio");
                fini = (e >> b & 1 != 0) == pol;
            }
            2 => {
                let v = match a {
                    0 => e,
                    1 => self.x,
                    2 => self.y,
                    3 => 0,
                    6 => self.isr,
                    7 => self.osr,
                    _ => panic!(),
                };
                self.isr = if n == 32 { v } else { (self.isr << n) | (v & masque(n)) };
            }
            3 => {
                let v = self.osr & masque(n);
                self.osr = if n == 32 { 0 } else { self.osr >> n };
                match a {
                    0 => self.sorties = (self.sorties & !0xFF) | (v & 0xFF), // OUT_BASE GP0, 8 broches
                    1 => self.x = v,
                    2 => self.y = v,
                    3 => {}
                    4 => self.dirs = (self.dirs & !0xFF) | (v & 0xFF),
                    _ => panic!("out {}", a),
                }
            }
            4 => {
                let pull = (i >> 7) & 1 != 0;
                let bloque = (i >> 5) & 1 != 0;
                if pull {
                    match self.tx.pop_front() {
                        Some(v) => self.osr = v,
                        None if bloque => fini = false,
                        None => self.osr = self.x,
                    }
                } else if self.rx.len() >= 4 {
                    fini = !bloque;
                } else {
                    self.rx.push_back(self.isr);
                    self.isr = 0;
                }
            }
            5 => {
                let src = i & 7;
                let opn = (i >> 3) & 3;
                let mut v = match src {
                    0 => e,
                    1 => self.x,
                    2 => self.y,
                    3 => 0,
                    6 => self.isr,
                    7 => self.osr,
                    _ => panic!("mov source {}", src),
                };
                if opn == 1 {
                    v = !v;
                } else if opn == 2 {
                    v = v.reverse_bits();
                }
                match a {
                    1 => self.x = v,
                    2 => self.y = v,
                    6 => self.isr = v,
                    7 => self.osr = v,
                    _ => panic!("mov destination {} (le RP2040 n'a pas mov pindirs)", a),
                }
            }
            7 => match a {
                1 => self.x = b,
                2 => self.y = b,
                _ => panic!("set {}", a),
            },
            _ => panic!("instruction {:04X}", i),
        }
        if fini {
            self.commencee = false;
            match saut {
                Some(p) => self.pc = p,
                None => self.suivant(),
            }
            self.delai = delai;
        } else {
            self.commencee = true;
        }
    }
}

// ------------------------------------------------------------------ banc
#[derive(Clone, Copy, PartialEq, Debug)]
enum Etat {
    Repos,
    T1,
    T2,
    T3,
    Tw,
    T4,
}

struct Cycle {
    ecriture: bool,
    reg: u8,
    donnee: u8,
}

struct Resultat {
    lus: Vec<(u8, u8)>,
    ecrits: Vec<(u8, u8)>,
    attentes: Vec<u32>,
    conflit_ns: f64,
}

/// Rejoue `cycles` avec un ecart de `ecart` etats entre deux cycles et une latence du
/// coeur 1 de `latence` ns. Le coeur 1 rend, pour la k-ieme lecture du registre r : A0h + r + k.
fn banc(cycles: &[Cycle], ecart: u32, latence: f64) -> Resultat {
    let mut pio = Pio::new();
    let mut res = Resultat { lus: vec![], ecrits: vec![], attentes: vec![], conflit_ns: 0.0 };
    let mut etat = Etat::Repos;
    let mut prochain_etat = Etat::Repos;
    let mut repos_reste = 4u32;
    let mut k = 0usize;
    let mut attentes = 0u32;
    // fronts des signaux du cycle en cours
    let mut sel_bas = f64::INFINITY;
    let mut sel_haut = f64::INFINITY;
    let mut strobe_bas = f64::INFINITY;
    let mut strobe_haut = f64::INFINITY;
    let mut echantillon_a = f64::INFINITY; // lecture : le 8088 prend D0-D7
    // 82C84 : 1er etage (front montant), sortie READY (front descendant)
    let mut s1 = true;
    let mut ready = true;
    // Q1 : dernier changement de GP26
    let mut gp26 = (-1e9f64, false);
    // coeur 1
    let mut c1: VecDeque<(f64, u32)> = VecDeque::new();
    let mut lus_k = 0u8;
    // synchroniseur d'entree du PIO (2 cycles)
    let mut hist: VecDeque<u32> = VecDeque::from(vec![0xFFFF_FFFF; 2]);

    let pas = 0.5;
    let mut t = 0.0f64;
    let mut prochain_pio = 0.0f64;
    let mut front_desc = 0.0f64; // debut de l'etat suivant
    let mut front_mont = 125.0f64;
    let limite = (cycles.len() as f64 + 4.0) * (ecart as f64 + 40.0) * T;
    loop {
        assert!(t < limite, "le 8088 est reste bloque (etat {:?}, cycle {})", etat, k);
        let c = &cycles[k.min(cycles.len() - 1)];
        // ---- signaux a l'instant t (cote Pico, apres U19)
        let sel = !(t >= sel_bas && t < sel_haut);
        let strobe = !(t >= strobe_bas && t < strobe_haut);
        let rd = c.ecriture || strobe;
        let wr = !c.ecriture || strobe;
        let pico_pilote = pio.dirs & 0xFF == 0xFF;
        let d8088 = if c.ecriture {
            // donnees valides au pire 110 ns apres le debut de T2, tenues 88 ns apres ~WR
            if t >= strobe_bas - 10.0 - LVC + 110.0 + LVC && t < strobe_haut + 88.0 {
                c.donnee as u32
            } else {
                (t as u32 * 7) & 0xFF
            }
        } else {
            0xEE
        };
        let d = if pico_pilote { pio.sorties & 0xFF } else { d8088 };
        if pico_pilote && rd {
            res.conflit_ns += pas;
        }
        if t >= echantillon_a {
            echantillon_a = f64::INFINITY;
            res.lus.push((c.reg, d as u8));
        }
        let entrees = d
            | (c.reg as u32) << 8
            | (sel as u32) << BROCHE_SEL
            | (rd as u32) << BROCHE_RD
            | (wr as u32) << BROCHE_WR
            | 0xFFFF_C000;
        // ---- PIO
        if t >= prochain_pio {
            prochain_pio += NS_PIO;
            hist.push_back(entrees);
            let vu = hist.pop_front().unwrap();
            let avant = pio.side;
            pio.cycle(vu);
            if pio.side != avant {
                gp26 = (t, pio.side);
            }
            while let Some(m) = pio.rx.pop_front() {
                c1.push_back((t + latence, m));
            }
        }
        // ---- coeur 1
        if let Some(&(tc, m)) = c1.front() {
            if t >= tc {
                c1.pop_front();
                let (ecr, reg, v) = bus_pio::decoder(m);
                if ecr {
                    res.ecrits.push((reg, v));
                } else {
                    let r = 0xA0u8.wrapping_add(reg).wrapping_add(lus_k);
                    lus_k = lus_k.wrapping_add(1);
                    pio.tx.push_back(r as u32 | 0xFF00);
                }
            }
        }
        // ---- Q1 : RDY1
        let rdy1 = if gp26.1 { t < gp26.0 + Q1_ON } else { t >= gp26.0 + Q1_OFF };
        // ---- horloge du 8088
        if t >= front_mont {
            front_mont = f64::INFINITY;
            if matches!(etat, Etat::T3 | Etat::Tw) {
                // le 8088 regarde READY : etat d'attente ou T4
                if ready {
                    prochain_etat = Etat::T4;
                    if !c.ecriture {
                        echantillon_a = front_desc - 30.0;
                    }
                } else {
                    prochain_etat = Etat::Tw;
                    attentes += 1;
                }
            }
            s1 = rdy1;
        }
        if t >= front_desc {
            ready = s1;
            let debut = front_desc;
            front_desc += T;
            front_mont = debut + 125.0;
            etat = match etat {
                Etat::Repos => {
                    if repos_reste > 0 {
                        repos_reste -= 1;
                        Etat::Repos
                    } else if k < cycles.len() {
                        sel_bas = debut + 70.0 + LVC;
                        sel_haut = f64::INFINITY;
                        strobe_bas = f64::INFINITY;
                        strobe_haut = f64::INFINITY;
                        attentes = 0;
                        Etat::T1
                    } else {
                        break;
                    }
                }
                Etat::T1 => {
                    strobe_bas = debut + 10.0 + LVC;
                    Etat::T2
                }
                Etat::T2 => Etat::T3,
                Etat::T3 | Etat::Tw => {
                    if prochain_etat == Etat::T4 {
                        strobe_haut = debut + 10.0 + LVC;
                        res.attentes.push(attentes);
                        Etat::T4
                    } else {
                        Etat::Tw
                    }
                }
                Etat::T4 => {
                    sel_haut = debut + 100.0 + LVC;
                    repos_reste = ecart;
                    k += 1;
                    Etat::Repos
                }
            };
        }
        t += pas;
    }
    res
}

fn cycles_melanges() -> Vec<Cycle> {
    let mut v = Vec::new();
    for i in 0..40u32 {
        let reg = (i * 3 % 8) as u8;
        v.push(Cycle { ecriture: i % 3 == 1, reg, donnee: (i * 37 + 11) as u8 });
    }
    v
}

fn verifier(c: &[Cycle], r: &Resultat) {
    let lectures: Vec<u8> = c.iter().filter(|x| !x.ecriture).map(|x| x.reg).collect();
    let ecritures: Vec<(u8, u8)> = c.iter().filter(|x| x.ecriture).map(|x| (x.reg, x.donnee)).collect();
    assert_eq!(r.ecrits, ecritures, "ecritures captees par le PIO");
    assert_eq!(r.lus.len(), lectures.len());
    for (k, ((reg, v), attendu_reg)) in r.lus.iter().zip(lectures.iter()).enumerate() {
        assert_eq!(reg, attendu_reg);
        let attendu = 0xA0u8.wrapping_add(*reg).wrapping_add(k as u8);
        assert_eq!(*v, attendu, "lecture {} du registre {} : {:02X} au lieu de {:02X}", k, reg, v, attendu);
    }
    // a la remontee de ~RD, U18 se retourne vers le Pico qui pilote encore D0-D7 quelques
    // cycles (synchroniseur + 2 instructions) : courant limite par RN4 (100 ohms)
    let par_lecture = r.conflit_ns / lectures.len().max(1) as f64;
    assert!(par_lecture <= 50.0, "conflit sur D0-D7 : {:.0} ns par lecture", par_lecture);
}

#[test]
fn programme_tient_dans_le_pio() {
    let p = bus_pio::programme();
    println!("{} instructions, wrap {}..{}", p.code.len(), p.wrap.target, p.wrap.source);
    assert!(p.code.len() <= 32);
}

#[test]
fn lectures_et_ecritures_au_cycle_pres() {
    let c = cycles_melanges();
    for &latence in &[100.0, 300.0, 600.0, 1500.0] {
        for &ecart in &[1u32, 3, 8] {
            let r = banc(&c, ecart, latence);
            verifier(&c, &r);
            let moy = r.attentes.iter().sum::<u32>() as f64 / r.attentes.len() as f64;
            println!(
                "coeur 1 a {:>6.0} ns, ecart {} etats : {} cycles, attentes {:.2} en moyenne (max {}), conflit {:.0} ns par lecture",
                latence,
                ecart,
                r.attentes.len(),
                moy,
                r.attentes.iter().max().unwrap(),
                r.conflit_ns / c.iter().filter(|x| !x.ecriture).count() as f64
            );
        }
    }
}

#[test]
fn etats_d_attente_selon_la_latence() {
    let c: Vec<Cycle> = (0..20).map(|i| Cycle { ecriture: false, reg: 0, donnee: i }).collect();
    let rapide = banc(&c, 2, 100.0);
    let lent = banc(&c, 2, 1500.0);
    verifier(&c, &rapide);
    verifier(&c, &lent);
    let m = |r: &Resultat| *r.attentes.iter().max().unwrap();
    assert!(m(&rapide) >= 1, "RDY1 tombe trop tard : aucun etat d'attente");
    assert!(m(&lent) > m(&rapide) + 4, "READY ne retient pas le 8088 : {} / {}", m(&rapide), m(&lent));
}
