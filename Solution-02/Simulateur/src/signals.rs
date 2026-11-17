//! Signaux logiques de la carte (noms des nets du schema KiCad, sans le '/').
//! Chaque signal a un niveau courant et un indicateur d'activite (change depuis la
//! derniere lecture), et peut etre sonde par l'oscilloscope (changements horodates).

pub const NAMES: &[&str] = &[
    // 0-19 : adresses verrouillees (U2 : A0-A7, U1 : A8-A15, U3 : A16-A19)
    "A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10", "A11", "A12", "A13", "A14", "A15",
    "A16", "A17", "A18", "A19",
    // 20-27 : bus de donnees (AD0-AD7 du 8088)
    "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
    // 28-
    "ALE", "~{RD}", "~{WR}", "IO/~{M}", "~{INTA}", "INTR", "RESET", "~{RESET}", "CLK", "PCLK",
    // 38-
    "U4-CE", "U6-CE#", "U5-Pad3", "U5-Pad10",
    // 42-49 : sorties du 74LS138
    "U8-O0", "~{CS_8255}", "~{CS_8259}", "~{CS_8255_2}", "~{CS_8253}", "U8-O5", "~{CS_61}", "U8-O7",
    // 50-
    "U10-E", "WR_61", "CLK_61", "GATE2", "~{SPK_EN}", "OUT2", "~{OUT2}", "SPK", "SPK_BZ",
    // 59-
    "IRQ0", "IRQ1", "IRQ4",
    // 62-
    "KBD_CLK", "KBD_DATA", "UART_TX", "UART_RX", "SD_CS", "SD_SCK", "SD_MOSI", "SD_MISO", "VOY_DISQ", "VOY_HD",
    // 72-95 : U7 PA0-PA7, PB0-PB7, PC0-PC7
    "PA0", "PA1", "PA2", "PA3", "PA4", "PA5", "PA6", "PA7", "PB0", "PB1", "PB2", "PB3", "PB4", "PB5", "PB6",
    "PB7", "PC0", "PC1", "PC2", "PC3", "PC4", "PC5", "PC6", "PC7",
    // 96-99 : A16-A19/S3-S6 cote 8088
    "U1-A16/S3", "U1-A17/S4", "U1-A18/S5", "U1-A19/S6",
    // 100-
    "U11-~{RES}", "OUT1", "U1-DT/~{R}", "U1-DEN", "U1-~{SSO}", "U1-HLDA",
    // 106-129 : broches de U12 (y compris non connectees) PA0-PA7, PB0-PB7, PC0-PC7
    "U12-PA0", "U12-PA1", "U12-PA2", "U12-PA3", "U12-PA4", "U12-PA5", "U12-PA6", "U12-PA7", "U12-PB0",
    "U12-PB1", "U12-PB2", "U12-PB3", "U12-PB4", "U12-PB5", "U12-PB6", "U12-PB7", "U12-PC0", "U12-PC1",
    "U12-PC2", "U12-PC3", "U12-PC4", "U12-PC5", "U12-PC6", "U12-PC7",
    // 130-
    "U3-Q0", "U3-Q1", "U3-Q2", "U3-Q3", "U16-Q1", "U16-Q2n",
    // 136-140 : entrees libres du 8259 (J12, tirees a la masse par R13-R17)
    "IRQ2", "IRQ3", "IRQ5", "IRQ6", "IRQ7",
];

pub const A0: usize = 0;
pub const D0: usize = 20;
pub const ALE: usize = 28;
pub const RD: usize = 29;
pub const WR: usize = 30;
pub const IOM: usize = 31;
pub const INTA: usize = 32;
pub const INTR: usize = 33;
pub const RESET: usize = 34;
pub const NRESET: usize = 35;
pub const CLK: usize = 36;
pub const PCLK: usize = 37;
pub const ROM_CE: usize = 38;
pub const RAM_CE: usize = 39;
pub const NA19: usize = 40;
pub const MEM: usize = 41;
pub const O0: usize = 42;
pub const LCD_E: usize = 50;
pub const WR_61: usize = 51;
pub const CLK_61: usize = 52;
pub const GATE2: usize = 53;
pub const NSPK_EN: usize = 54;
pub const OUT2: usize = 55;
pub const NOUT2: usize = 56;
pub const SPK: usize = 57;
pub const SPK_BZ: usize = 58;
pub const IRQ0: usize = 59;
pub const IRQ1: usize = 60;
pub const IRQ4: usize = 61;
pub const KBD_CLK: usize = 62;
pub const KBD_DATA: usize = 63;
pub const UART_TX: usize = 64;
pub const UART_RX: usize = 65;
pub const SD_CS: usize = 66;
pub const SD_SCK: usize = 67;
pub const SD_MOSI: usize = 68;
pub const SD_MISO: usize = 69;
pub const VOY_DISQ: usize = 70;
pub const VOY_HD: usize = 71;
pub const U7_PA0: usize = 72;
pub const S3: usize = 96;
pub const NRES: usize = 100;
pub const OUT1: usize = 101;
pub const DTR: usize = 102;
pub const DEN: usize = 103;
pub const SSO: usize = 104;
pub const HLDA: usize = 105;
pub const U12_PA0: usize = 106;
pub const U3_Q0: usize = 130;
pub const U16_Q1: usize = 134;
pub const U16_Q2N: usize = 135;

pub const IRQ2: usize = 136;
/// Signal de l'entree IRn du 8259 (n = 2, 3, 5, 6, 7) : IRQ2 + index dans [2, 3, 5, 6, 7].
pub const FREE_IRQS: [u8; 5] = [2, 3, 5, 6, 7];

pub const N: usize = 141;
const W: usize = N.div_ceil(64);

/// Signal flottant (haute impedance) : bit dans `z`.
#[derive(Clone)]
pub struct Signals {
    pub cur: [u64; W],
    pub tog: [u64; W],
    pub z: [u64; W],
    pub probe: [u64; W],
    pub any_probe: bool,
    /// Changements sondes : (instant en quarts de cycle, signal, niveau 0/1/2=Z).
    pub events: Vec<(u64, u8, u8)>,
    pub max_events: usize,
}

impl Signals {
    pub fn new() -> Self {
        Signals {
            cur: [0; W],
            tog: [0; W],
            z: [0; W],
            probe: [0; W],
            any_probe: false,
            events: Vec::new(),
            max_events: 400_000,
        }
    }

    #[inline]
    pub fn get(&self, i: usize) -> bool {
        self.cur[i >> 6] >> (i & 63) & 1 != 0
    }

    /// Change un signal a l'instant tq (quarts de cycle).
    #[inline]
    pub fn set(&mut self, i: usize, v: bool, tq: u64) {
        let (w, b) = (i >> 6, 1u64 << (i & 63));
        let old = self.cur[w] & b != 0;
        let wasz = self.z[w] & b != 0;
        if old == v && !wasz {
            return;
        }
        self.z[w] &= !b;
        if v {
            self.cur[w] |= b
        } else {
            self.cur[w] &= !b
        }
        self.tog[w] |= b;
        if self.probe[w] & b != 0 && self.events.len() < self.max_events {
            self.events.push((tq, i as u8, v as u8));
        }
    }

    #[inline]
    pub fn set_z(&mut self, i: usize, tq: u64) {
        let (w, b) = (i >> 6, 1u64 << (i & 63));
        if self.z[w] & b != 0 {
            return;
        }
        self.z[w] |= b;
        self.tog[w] |= b;
        if self.probe[w] & b != 0 && self.events.len() < self.max_events {
            self.events.push((tq, i as u8, 2));
        }
    }

    /// Impulsion breve (strobe) : le signal passe a `v` puis revient.
    #[inline]
    pub fn pulse(&mut self, i: usize, v: bool, t0: u64, t1: u64) {
        let (w, b) = (i >> 6, 1u64 << (i & 63));
        self.tog[w] |= b;
        if self.probe[w] & b != 0 && self.events.len() + 1 < self.max_events {
            self.events.push((t0, i as u8, v as u8));
            self.events.push((t1, i as u8, (!v) as u8));
        }
    }

    #[inline]
    pub fn probed(&self, i: usize) -> bool {
        self.probe[i >> 6] >> (i & 63) & 1 != 0
    }

    /// Etat pour l'affichage : 0 bas, 1 haut, 2 Z, +4 si actif depuis la derniere lecture.
    pub fn snapshot(&mut self) -> Vec<u8> {
        let mut v = Vec::with_capacity(N);
        for i in 0..N {
            let (w, b) = (i >> 6, 1u64 << (i & 63));
            let mut s = if self.z[w] & b != 0 { 2 } else if self.cur[w] & b != 0 { 1 } else { 0 };
            if self.tog[w] & b != 0 {
                s |= 4;
            }
            v.push(s);
        }
        self.tog = [0; W];
        v
    }

    pub fn index(name: &str) -> Option<usize> {
        NAMES.iter().position(|n| *n == name)
    }
}

impl Default for Signals {
    fn default() -> Self {
        Self::new()
    }
}
