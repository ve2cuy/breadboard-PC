//! Afficheur LCD 20x4 (HD44780 / ST7066U, ROM A00), en ecriture seule (R/W a la masse) :
//! E = NOR(WR#, O0), RS = A0. Port 00h = commande, 01h = donnee.
//! Le modele verifie les delais d'execution (le drapeau occupe n'est pas lisible ici).

use crate::CLK_HZ;

const fn us(n: u64) -> u64 {
    (n * CLK_HZ as u64) / 1_000_000
}

#[derive(Clone)]
pub struct Lcd {
    pub ddram: [u8; 0x80],
    pub cgram: [u8; 64],
    pub ac: u8,
    pub cg_mode: bool,
    pub increment: bool,
    pub shift_display: bool,
    pub display_on: bool,
    pub cursor_on: bool,
    pub blink_on: bool,
    pub two_lines: bool,
    pub eight_bits: bool,
    pub font_5x10: bool,
    /// Decalage de l'affichage (commandes 18h/1Ch, ou entree avec S = 1).
    pub shift: i32,
    /// Au moins un "function set" recu (sinon : 1 ligne, ecran de mise sous tension).
    pub initialized: bool,
    busy_until: u64,
    power_on: u64,
    pub writes: u64,
    pub violations: u64,
    pub log: Vec<String>,
    /// Compteur incremente a chaque changement visible (pour le rafraichissement).
    pub version: u64,
}

impl Lcd {
    pub fn new(now: u64) -> Self {
        Lcd {
            ddram: [0x20; 0x80],
            cgram: [0; 64],
            ac: 0,
            cg_mode: false,
            increment: true,
            shift_display: false,
            display_on: false,
            cursor_on: false,
            blink_on: false,
            two_lines: false,
            eight_bits: true,
            font_5x10: false,
            shift: 0,
            initialized: false,
            busy_until: now + us(40_000),
            power_on: now,
            writes: 0,
            violations: 0,
            log: Vec::new(),
            version: 1,
        }
    }

    fn check_busy(&mut self, now: u64, what: &str) {
        if now < self.busy_until {
            self.violations += 1;
            if self.log.len() < 20 {
                let early = (self.busy_until - now) as f64 * 1e6 / CLK_HZ;
                let since = (now - self.power_on) as f64 / CLK_HZ;
                self.log.push(format!(
                    "LCD : {} {:.1} us trop tot (t = {:.3} s)",
                    what, early, since
                ));
            }
        }
    }

    pub fn write(&mut self, rs: bool, v: u8, now: u64) {
        self.writes += 1;
        self.version += 1;
        let mut exec = us(37);
        if !rs {
            self.check_busy(now, &format!("commande {:02X}h", v));
            if v == 0x01 {
                self.ddram = [0x20; 0x80];
                self.ac = 0;
                self.cg_mode = false;
                self.increment = true;
                self.shift = 0;
                exec = us(1520);
            } else if v & 0xFE == 0x02 {
                self.ac = 0;
                self.cg_mode = false;
                self.shift = 0;
                exec = us(1520);
            } else if v & 0x80 != 0 {
                self.ac = v & 0x7F;
                self.cg_mode = false;
            } else if v & 0x40 != 0 {
                self.ac = v & 0x3F;
                self.cg_mode = true;
            } else if v & 0x20 != 0 {
                if !self.initialized {
                    exec = us(4100);
                }
                self.initialized = true;
                self.eight_bits = v & 0x10 != 0;
                self.two_lines = v & 0x08 != 0;
                self.font_5x10 = v & 0x04 != 0;
                if !self.eight_bits && self.log.len() < 20 {
                    self.log.push(format!("LCD : function set {:02X}h = mode 4 bits (bus de 8 bits cable)", v));
                }
            } else if v & 0x10 != 0 {
                let right = v & 0x04 != 0;
                if v & 0x08 != 0 {
                    self.shift += if right { 1 } else { -1 };
                } else {
                    self.move_ac(right);
                }
            } else if v & 0x08 != 0 {
                self.display_on = v & 0x04 != 0;
                self.cursor_on = v & 0x02 != 0;
                self.blink_on = v & 0x01 != 0;
            } else if v & 0x04 != 0 {
                self.increment = v & 0x02 != 0;
                self.shift_display = v & 0x01 != 0;
            }
        } else {
            self.check_busy(now, &format!("donnee {:02X}h", v));
            if self.cg_mode {
                self.cgram[(self.ac & 0x3F) as usize] = v & 0x1F;
                self.ac = if self.increment { (self.ac + 1) & 0x3F } else { self.ac.wrapping_sub(1) & 0x3F };
            } else {
                self.ddram[self.ac as usize & 0x7F] = v;
                let inc = self.increment;
                self.move_ac(inc);
                if self.shift_display {
                    self.shift += if inc { -1 } else { 1 };
                }
            }
            exec = us(41);
        }
        self.busy_until = now + exec;
    }

    fn move_ac(&mut self, inc: bool) {
        if self.cg_mode {
            self.ac = if inc { (self.ac + 1) & 0x3F } else { self.ac.wrapping_sub(1) & 0x3F };
            return;
        }
        if self.two_lines {
            self.ac = if inc {
                match self.ac {
                    0x27 => 0x40,
                    0x67 => 0x00,
                    a => a + 1,
                }
            } else {
                match self.ac {
                    0x00 => 0x67,
                    0x40 => 0x27,
                    a => a - 1,
                }
            };
        } else {
            self.ac = if inc {
                if self.ac >= 0x4F { 0 } else { self.ac + 1 }
            } else if self.ac == 0 {
                0x4F
            } else {
                self.ac - 1
            };
        }
    }

    /// Codes de caractere visibles : 4 lignes x 20 (ordre physique), ou None si eteint.
    pub fn visible(&self) -> [u8; 80] {
        let mut out = [0x20u8; 80];
        let starts = [0x00i32, 0x40, 0x14, 0x54];
        for (row, &st) in starts.iter().enumerate() {
            for col in 0..20 {
                let base = if st >= 0x40 { 0x40 } else { 0 };
                let off = ((st - base) + col as i32 - self.shift).rem_euclid(40);
                out[row * 20 + col] = self.ddram[(base + off) as usize];
            }
        }
        out
    }

    /// Position du curseur (ligne, colonne) si visible.
    pub fn cursor_pos(&self) -> Option<(usize, usize)> {
        if self.cg_mode {
            return None;
        }
        let a = self.ac as i32;
        let starts = [0x00i32, 0x40, 0x14, 0x54];
        for (row, &st) in starts.iter().enumerate() {
            let base = if st >= 0x40 { 0x40 } else { 0 };
            if (a >= 0x40) != (base == 0x40) {
                continue;
            }
            let col = (a - st + self.shift).rem_euclid(40);
            if col < 20 {
                return Some((row, col as usize));
            }
        }
        None
    }
}
