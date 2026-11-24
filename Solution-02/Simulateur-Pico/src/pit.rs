//! Minuterie NEC D8253C-2 (U15), ports 40h-43h ; CLK0-2 = PCLK (CLK du 8088 / 2 = 2,667 MHz).
//! Modele analytique : la valeur du compteur et la sortie OUT sont calculees a partir de
//! l'instant du chargement, ce qui permet de connaitre exactement le prochain front de OUT.
//! Modes 0 a 5 (1 et 5 traites comme 0 et 4 : GATE0/1 sont a +5 V).

#[derive(Clone, Default)]
pub struct Counter {
    pub mode: u8,
    pub rw: u8,
    pub bcd: bool,
    /// Diviseur charge (0 -> 65536).
    pub n: u32,
    pub loaded: bool,
    /// Instant (en periodes de PCLK) ou le comptage a commence.
    pub start: u64,
    pub gate: bool,
    lsb_next: bool,
    lsb_tmp: u8,
    latch: Option<u16>,
    read_msb: bool,
    /// Sortie avant le premier chargement.
    pub out_idle: bool,
}

impl Counter {
    fn new() -> Self {
        Counter { gate: true, out_idle: true, n: 0x10000, ..Default::default() }
    }

    fn running(&self) -> bool {
        self.loaded && (self.gate || !matches!(self.mode, 2 | 3))
    }

    /// (valeur du compteur, niveau de OUT) a l'instant t (periodes de PCLK).
    pub fn state(&self, t: u64) -> (u16, bool) {
        if !self.loaded {
            return (0, self.out_idle);
        }
        let n = self.n as u64;
        if !self.running() {
            return (self.n as u16, true);
        }
        let e = t.saturating_sub(self.start);
        match self.mode {
            2 => {
                let ph = e % n;
                // OUT bas pendant la derniere periode (compte = 1)
                ((n - ph) as u16, ph != n - 1)
            }
            3 => {
                let ph = e % n;
                let high = (n + 1) / 2;
                if ph < high {
                    ((n - 2 * ph).max(2) as u16 & 0xFFFE, true)
                } else {
                    ((n - 2 * (ph - high)).max(2) as u16 & 0xFFFE, false)
                }
            }
            4 => {
                let v = (n as i64 - e as i64).rem_euclid(65536) as u16;
                (v, e != n)
            }
            _ => {
                // mode 0 : OUT bas jusqu'au compte final, puis haut
                let v = (n as i64 - e as i64).rem_euclid(65536) as u16;
                (v, e >= n)
            }
        }
    }

    /// Prochain changement de OUT strictement apres t (periodes de PCLK).
    pub fn next_edge(&self, t: u64) -> Option<u64> {
        if !self.running() {
            return None;
        }
        let n = self.n as u64;
        let e = t.saturating_sub(self.start);
        let base = self.start;
        match self.mode {
            2 => {
                let k = e / n;
                let ph = e % n;
                if ph < n - 1 {
                    Some(base + k * n + n - 1)
                } else {
                    Some(base + (k + 1) * n)
                }
            }
            3 => {
                let k = e / n;
                let ph = e % n;
                let high = (n + 1) / 2;
                if ph < high {
                    Some(base + k * n + high)
                } else {
                    Some(base + (k + 1) * n)
                }
            }
            4 => {
                if e < n {
                    Some(base + n)
                } else if e == n {
                    Some(base + n + 1)
                } else {
                    None
                }
            }
            _ => {
                if e < n {
                    Some(base + n)
                } else {
                    None
                }
            }
        }
    }
}

#[derive(Clone)]
pub struct Pit {
    pub c: [Counter; 3],
    pub log: Vec<String>,
}

impl Pit {
    pub fn new() -> Self {
        Pit { c: [Counter::new(), Counter::new(), Counter::new()], log: Vec::new() }
    }

    /// Ecriture ; t = instant en periodes de PCLK.
    pub fn write(&mut self, a: u8, v: u8, t: u64) {
        let a = a & 3;
        if a == 3 {
            let sc = (v >> 6) as usize;
            if sc == 3 {
                if self.log.len() < 10 {
                    self.log.push(format!("8253 : commande {:02X}h (relecture : 8254 seulement)", v));
                }
                return;
            }
            let rw = (v >> 4) & 3;
            let c = &mut self.c[sc];
            if rw == 0 {
                // verrouillage
                if c.latch.is_none() {
                    c.latch = Some(c.state(t).0);
                    c.read_msb = false;
                }
                return;
            }
            c.rw = rw;
            c.mode = match (v >> 1) & 7 {
                6 => 2,
                7 => 3,
                m => m,
            };
            c.bcd = v & 1 != 0;
            c.lsb_next = true;
            c.loaded = false;
            c.latch = None;
            c.read_msb = false;
            c.out_idle = c.mode != 0;
            return;
        }
        let c = &mut self.c[a as usize];
        let val: Option<u32> = match c.rw {
            1 => Some(v as u32),
            2 => Some((v as u32) << 8),
            _ => {
                if c.lsb_next {
                    c.lsb_tmp = v;
                    c.lsb_next = false;
                    if c.mode == 0 {
                        // mode 0 : l'ecriture du premier octet arrete le comptage
                        c.out_idle = false;
                        c.loaded = false;
                    }
                    None
                } else {
                    c.lsb_next = true;
                    Some(c.lsb_tmp as u32 | (v as u32) << 8)
                }
            }
        };
        if let Some(mut n) = val {
            if c.bcd {
                let d = |x: u32| (x & 0xF) + 10 * ((x >> 4) & 0xF) + 100 * ((x >> 8) & 0xF) + 1000 * ((x >> 12) & 0xF);
                n = d(n);
                if n == 0 {
                    n = 10000;
                }
            } else if n == 0 {
                n = 0x10000;
            }
            // en modes 2 et 3, un nouveau diviseur prend effet au prochain cycle ; ici tout de suite
            c.n = n.max(if c.mode == 3 { 2 } else { 1 });
            c.loaded = true;
            c.start = t + 1;
        }
    }

    pub fn read(&mut self, a: u8, t: u64) -> u8 {
        let a = a & 3;
        if a == 3 {
            return 0xFF;
        }
        let c = &mut self.c[a as usize];
        let v = match c.latch {
            Some(l) => l,
            None => c.state(t).0,
        };
        let out = match c.rw {
            1 => {
                c.latch = None;
                v as u8
            }
            2 => {
                c.latch = None;
                (v >> 8) as u8
            }
            _ => {
                if c.read_msb {
                    c.read_msb = false;
                    c.latch = None;
                    (v >> 8) as u8
                } else {
                    c.read_msb = true;
                    v as u8
                }
            }
        };
        out
    }

    pub fn set_gate(&mut self, i: usize, g: bool, t: u64) {
        let c = &mut self.c[i];
        if g && !c.gate && matches!(c.mode, 1 | 2 | 3 | 5) && c.loaded {
            c.start = t + 1; // front montant de GATE : rechargement
        }
        c.gate = g;
    }

    pub fn out(&self, i: usize, t: u64) -> bool {
        self.c[i].state(t).1
    }
}

impl Default for Pit {
    fn default() -> Self {
        Self::new()
    }
}
