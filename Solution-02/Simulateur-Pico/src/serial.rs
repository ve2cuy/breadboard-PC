//! Clavier PS/2 (J4, sur PB0 = KBD_CLK / PB1 = KBD_DATA de U12) et UART logiciel
//! (J5 : TX = PA7, RX = PB2 de U12, 9600 8N1). Les trames partent a leur heure, en temps
//! reel du 8088, que le BIOS les ecoute ou non (comme les vrais peripheriques).

use crate::CLK_HZ;
use std::collections::VecDeque;

/// Demi-periode de l'horloge PS/2 : 50 us (horloge a 10 kHz, bas de la plage 10-16,7 kHz de la
/// norme, courant pour les claviers USB a repli PS/2). Le BIOS tolere une latence d'IRQ1 d'une
/// periode : a 12,5 kHz, un INT 16h en cours au debut d'une trame suffisait a la perdre.
pub const PS2_HALF: u64 = (50.0 * CLK_HZ / 1e6) as u64;
/// Ecart entre deux octets d'une meme touche (F0 xx, E0 xx) : ~1 ms comme un vrai clavier.
pub const PS2_GAP: u64 = (1000.0 * CLK_HZ / 1e6) as u64;

#[derive(Clone)]
struct Ps2Frame {
    start: u64,
    bits: [u8; 11],
    read: bool,
}

#[derive(Clone)]
pub struct Ps2Kbd {
    queue: VecDeque<u8>,
    frame: Option<Ps2Frame>,
    ready_at: u64,
    pub frames: u64,
    pub lost: u64,
    pub sent: VecDeque<u8>,
}

impl Ps2Kbd {
    pub fn new() -> Self {
        Ps2Kbd { queue: VecDeque::new(), frame: None, ready_at: 0, frames: 0, lost: 0, sent: VecDeque::new() }
    }

    pub fn push(&mut self, bytes: &[u8], now: u64) {
        if self.queue.is_empty() && self.frame.is_none() && self.ready_at < now {
            self.ready_at = now;
        }
        self.queue.extend(bytes.iter().copied());
    }

    pub fn pending(&self) -> usize {
        self.queue.len() + self.frame.is_some() as usize
    }

    pub fn clear(&mut self) {
        self.queue.clear();
        self.frame = None;
    }

    fn advance(&mut self, now: u64) {
        loop {
            if let Some(f) = &self.frame {
                let end = f.start + 22 * PS2_HALF;
                if now < end {
                    return;
                }
                self.frames += 1;
                if !f.read {
                    self.lost += 1;
                }
                self.ready_at = end + PS2_GAP;
                self.frame = None;
            }
            if self.queue.is_empty() || now < self.ready_at {
                return;
            }
            let b = self.queue.pop_front().unwrap();
            let mut bits = [0u8; 11];
            let mut ones = 0;
            for i in 0..8 {
                bits[1 + i] = (b >> i) & 1;
                ones += bits[1 + i];
            }
            bits[9] = if ones % 2 == 0 { 1 } else { 0 };
            bits[10] = 1;
            self.sent.push_back(b);
            if self.sent.len() > 64 {
                self.sent.pop_front();
            }
            self.frame = Some(Ps2Frame { start: self.ready_at, bits, read: false });
        }
    }

    /// (horloge, donnees) a l'instant `now`.
    pub fn lines(&mut self, now: u64) -> (bool, bool) {
        self.advance(now);
        match &self.frame {
            None => (true, true),
            Some(f) => {
                let e = now - f.start;
                let i = (e / (2 * PS2_HALF)) as usize;
                let ph = e % (2 * PS2_HALF);
                (ph < PS2_HALF, f.bits[i.min(10)] != 0)
            }
        }
    }

    /// Le BIOS lit PB pendant une trame : elle n'est pas perdue.
    pub fn mark_read(&mut self) {
        if let Some(f) = &mut self.frame {
            f.read = true;
        }
    }

    /// Prochain instant ou les lignes peuvent changer.
    pub fn next_change(&self, now: u64) -> u64 {
        match &self.frame {
            Some(f) => {
                let e = now.saturating_sub(f.start);
                f.start + (e / PS2_HALF + 1) * PS2_HALF
            }
            None => {
                if self.queue.is_empty() {
                    u64::MAX
                } else {
                    self.ready_at.max(now + 1)
                }
            }
        }
    }
}

impl Default for Ps2Kbd {
    fn default() -> Self {
        Self::new()
    }
}

/// Instant de debut du bit k d'une trame serie a 9600 bauds (cycles, depuis le debut).
#[inline]
pub fn bit_t(k: u64, baud: u64) -> u64 {
    // CLK = 16 MHz / 3
    k * 16_000_000 / (3 * baud)
}

#[derive(Clone)]
pub struct UartRx {
    queue: VecDeque<u8>,
    cur: Option<(u64, u16)>, // (debut, bits 0-9)
    ready_at: u64,
    pub baud: u64,
    /// Ecart supplementaire entre deux octets (cycles).
    pub gap: u64,
    /// Controle de flux : pas de nouvelle trame tant que `hold` (RTS de l'ATmega retire).
    hold: bool,
    /// Trames finies (fin, octet), gardees si `garde` (ATmega : remise octet par octet).
    pub garde: bool,
    pub faites: Vec<(u64, u8)>,
}

impl UartRx {
    pub fn new() -> Self {
        UartRx { queue: VecDeque::new(), cur: None, ready_at: 0, baud: 9600, gap: 0, hold: false, garde: false, faites: Vec::new() }
    }
    /// Suspend (true) ou reprend (false) l'envoi de nouvelles trames a l'instant `now`
    /// (la trame en cours se termine).
    pub fn set_hold(&mut self, hold: bool, now: u64) {
        if self.hold && !hold && self.ready_at < now {
            self.ready_at = now;
        }
        self.hold = hold;
    }
    pub fn push(&mut self, bytes: &[u8], now: u64) {
        if self.queue.is_empty() && self.cur.is_none() && self.ready_at < now {
            self.ready_at = now;
        }
        self.queue.extend(bytes.iter().copied());
    }
    pub fn pending(&self) -> usize {
        self.queue.len() + self.cur.is_some() as usize
    }
    pub fn clear(&mut self) {
        self.queue.clear();
        self.cur = None;
    }
    fn advance(&mut self, now: u64) {
        loop {
            if let Some((s, bits)) = self.cur {
                let end = s + bit_t(10, self.baud);
                if now < end {
                    return;
                }
                if self.garde {
                    self.faites.push((end, (bits >> 1) as u8));
                }
                self.cur = None;
                self.ready_at = end + self.gap;
            }
            if self.queue.is_empty() || now < self.ready_at || self.hold {
                return;
            }
            let b = self.queue.pop_front().unwrap();
            self.cur = Some((self.ready_at, ((b as u16) << 1) | 0x200));
        }
    }
    /// Niveau de la ligne RX (repos = 1).
    pub fn line(&mut self, now: u64) -> bool {
        self.advance(now);
        match self.cur {
            None => true,
            Some((s, bits)) => {
                let e = now - s;
                let mut k = (e * 3 * self.baud / 16_000_000).min(9);
                while k < 9 && bit_t(k + 1, self.baud) <= e {
                    k += 1;
                }
                while k > 0 && bit_t(k, self.baud) > e {
                    k -= 1;
                }
                (bits >> k) & 1 != 0
            }
        }
    }
    pub fn next_change(&self, now: u64) -> u64 {
        match self.cur {
            Some((s, _)) => {
                let e = now.saturating_sub(s);
                let mut k = e * 3 * self.baud / 16_000_000;
                while bit_t(k, self.baud) <= e {
                    k += 1;
                }
                s + bit_t(k, self.baud)
            }
            None => {
                if self.queue.is_empty() || self.hold {
                    u64::MAX
                } else {
                    self.ready_at.max(now + 1)
                }
            }
        }
    }
}

impl Default for UartRx {
    fn default() -> Self {
        Self::new()
    }
}

/// Recepteur du terminal branche sur TX (PA7) : echantillonne au milieu de chaque bit.
#[derive(Clone)]
pub struct UartTx {
    level: bool,
    busy: bool,
    start: u64,
    k: u32,
    byte: u8,
    pub baud: u64,
    pub out: Vec<u8>,
    pub framing_errors: u64,
    pub bytes: u64,
    /// Duree du dernier bit de depart mesuree (cycles), pour l'affichage de la calibration.
    pub last_bit: u64,
    last_fall: u64,
}

impl UartTx {
    pub fn new() -> Self {
        UartTx {
            level: true,
            busy: false,
            start: 0,
            k: 0,
            byte: 0,
            baud: 9600,
            out: Vec::new(),
            framing_errors: 0,
            bytes: 0,
            last_bit: 0,
            last_fall: 0,
        }
    }

    pub fn advance(&mut self, t: u64) {
        while self.busy {
            // echantillon k : bits de donnees 0-7 au milieu des bits 1-8, arret au milieu du 9
            let s = self.start + (bit_t(2 * (self.k as u64 + 1) + 1, self.baud)) / 2;
            if s >= t {
                return;
            }
            if self.k < 8 {
                if self.level {
                    self.byte |= 1 << self.k;
                }
                self.k += 1;
            } else {
                if !self.level {
                    self.framing_errors += 1;
                }
                self.out.push(self.byte);
                self.bytes += 1;
                self.busy = false;
            }
        }
    }

    pub fn edge(&mut self, t: u64, level: bool) {
        self.advance(t);
        if level == self.level {
            return;
        }
        if !level {
            self.last_fall = t;
            if !self.busy {
                self.busy = true;
                self.start = t;
                self.k = 0;
                self.byte = 0;
            }
        } else if self.busy && self.k == 0 {
            self.last_bit = t - self.last_fall;
        }
        self.level = level;
    }

    pub fn level(&self) -> bool {
        self.level
    }

    /// Instant du prochain echantillon d'une trame en cours (None au repos).
    pub fn next_sample(&self) -> Option<u64> {
        if self.busy {
            Some(self.start + (bit_t(2 * (self.k as u64 + 1) + 1, self.baud)) / 2 + 1)
        } else {
            None
        }
    }
}

impl Default for UartTx {
    fn default() -> Self {
        Self::new()
    }
}
