//! La carte Solution-02 : bus du 8088, decodage (U5, U8, U9), memoires, peripheriques,
//! lignes d'interruption (U14 -> U13), son (U15, U16, BZ1) et pannes simulees.

use crate::cpu::{Bus, Cpu, IF};
use crate::lcd::Lcd;
use crate::pic::Pic;
use crate::pit::Pit;
use crate::ppi::Ppi;
use crate::sd::SdCard;
use crate::serial::{Ps2Kbd, UartRx, UartTx};
use crate::signals::{self as s, Signals};
use crate::CLK_HZ;

/// Pannes et variantes de montage que l'on peut simuler.
#[derive(Clone, Default)]
pub struct Faults {
    /// Lignes d'adresse A0-A18 coupees vers la RAM (lues a 0).
    pub ram_line_cut: u32,
    /// Cellule de RAM defectueuse : (adresse, bits colles a 0).
    pub ram_bad: Option<(u32, u8)>,
    pub no_pic: bool,
    pub no_pit: bool,
    pub no_lcd: bool,
    pub no_rom: bool,
    /// D0-D7 inverses vers U7 (erreur de cablage du 2026-11-13).
    pub u7_data_rev: bool,
    /// D+ et D- inverses sur J4 (erreur du schema du 2026-11-14).
    pub kbd_swap: bool,
    /// R4 (tirage de RX) absente : RX flottant lu a 0 quand le terminal est debranche.
    pub no_r4: bool,
}

#[derive(Clone, Copy, Default)]
pub struct IoRec {
    pub t: u64,
    pub port: u16,
    pub val: u8,
    pub write: bool,
}

#[derive(Clone)]
pub struct Board {
    pub ram: Vec<u8>,
    pub rom: Vec<u8>,
    pub lcd: Lcd,
    pub u7: Ppi,
    pub u12: Ppi,
    pub pic: Pic,
    pub pit: Pit,
    pub kbd: Ps2Kbd,
    pub rx: UartRx,
    pub tx: UartTx,
    pub sd: SdCard,
    pub sig: Signals,
    pub faults: Faults,
    /// Terminal (adaptateur serie) branche sur J5.
    pub term_connected: bool,
    pub now: u64,
    acc: u64,
    pub next_ev: u64,
    kbd_lines: (bool, bool),
    rx_line: bool,
    out0: bool,
    out2: bool,
    pub gate2: bool,
    pub spk_en: bool,
    pub spk: bool,
    /// Son : changements de SPK (cycle, niveau) depuis le dernier prelevement.
    pub audio_on: bool,
    audio_ev: Vec<(u64, bool)>,
    audio_t: u64,
    audio_level: bool,
    audio_x1: f32,
    audio_y1: f32,
    audio_frac: f64,
    pub io_log: Vec<IoRec>,
    io_pos: usize,
    pub io_reads: u64,
    pub io_writes: u64,
    pub mem_reads: u64,
    pub mem_writes: u64,
    pub rom_write_attempts: u64,
    pub log: Vec<String>,
    /// Acces a la carte SD : voyants (D1, D2) vus allumes recemment.
    pub reset_line: bool,
    /// Adresse et donnee du dernier cycle (pour l'affichage).
    pub last_addr: u32,
    pub last_data: u8,
}

const IO_LOG: usize = 4096;

impl Board {
    pub fn new(rom: Vec<u8>, seed: u64) -> Self {
        let mut ram = vec![0u8; 0x80000];
        // la RAM statique demarre avec un contenu quelconque
        let mut x = seed | 1;
        for b in ram.iter_mut() {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            *b = x as u8;
        }
        let mut rom = rom;
        rom.resize(0x40000, 0xFF);
        let mut b = Board {
            ram,
            rom,
            lcd: Lcd::new(0),
            u7: Ppi::new("U7 (8255)"),
            u12: Ppi::new("U12 (8255)"),
            pic: Pic::new(),
            pit: Pit::new(),
            kbd: Ps2Kbd::new(),
            rx: UartRx::new(),
            tx: UartTx::new(),
            sd: SdCard::new(),
            sig: Signals::new(),
            faults: Faults::default(),
            term_connected: true,
            now: 0,
            acc: 0,
            next_ev: 0,
            kbd_lines: (true, true),
            rx_line: true,
            out0: true,
            out2: true,
            gate2: false,
            spk_en: false,
            spk: false,
            audio_on: false,
            audio_ev: Vec::new(),
            audio_t: 0,
            audio_level: false,
            audio_x1: 0.0,
            audio_y1: 0.0,
            audio_frac: 0.0,
            io_log: vec![IoRec::default(); IO_LOG],
            io_pos: 0,
            io_reads: 0,
            io_writes: 0,
            mem_reads: 0,
            mem_writes: 0,
            rom_write_attempts: 0,
            log: Vec::new(),
            reset_line: true,
            last_addr: 0,
            last_data: 0,
        };
        b.init_signals();
        b
    }

    fn init_signals(&mut self) {
        let t = 0;
        for i in [s::RD, s::WR, s::INTA, s::ALE] {
            self.sig.set(i, i != s::ALE, t);
        }
        for i in 0..8 {
            self.sig.set(s::O0 + i, true, t);
        }
        self.sig.set(s::LCD_E, false, t);
        self.sig.set(s::WR_61, false, t);
        self.sig.set(s::CLK_61, true, t);
        self.sig.set(s::KBD_CLK, true, t);
        self.sig.set(s::KBD_DATA, true, t);
        self.sig.set(s::UART_RX, true, t);
        self.sig.set(s::SD_MISO, true, t);
        self.sig.set(s::SD_CS, true, t);
        self.sig.set(s::IRQ1, false, t);
        self.sig.set(s::IRQ4, false, t);
        self.sig.set(s::NSPK_EN, true, t);
        self.sig.set(s::NRES, true, t);
        self.sig.set(s::DTR, true, t);
        self.sig.set(s::DEN, true, t);
        self.sig.set(s::HLDA, false, t);
        for i in 0..24 {
            self.sig.set_z(s::U7_PA0 + i, t);
            self.sig.set_z(s::U12_PA0 + i, t);
        }
        for i in 0..4 {
            self.sig.set_z(s::U3_Q0 + i, t);
        }
    }

    /// Debut d'une instruction a l'instant `now`.
    #[inline]
    pub fn begin(&mut self, now: u64) {
        self.now = now;
        self.acc = 0;
    }

    #[inline]
    fn tq(&self, sub: u64) -> u64 {
        (self.now + 4 * self.acc) * 4 + sub
    }

    pub fn pclk(t: u64) -> u64 {
        t / 2
    }

    fn rec_io(&mut self, port: u16, val: u8, write: bool) {
        let t = self.now + 4 * self.acc;
        self.io_log[self.io_pos] = IoRec { t, port, val, write };
        self.io_pos = (self.io_pos + 1) % IO_LOG;
    }

    /// Journal des derniers acces d'E/S, du plus ancien au plus recent.
    pub fn io_history(&self) -> Vec<IoRec> {
        let mut v = Vec::with_capacity(IO_LOG);
        for k in 0..IO_LOG {
            let r = self.io_log[(self.io_pos + k) % IO_LOG];
            if r.t != 0 || r.port != 0 {
                v.push(r);
            }
        }
        v
    }

    // ---------------------------------------------------------------- signaux du bus
    /// Un cycle de bus : adresse verrouillee, donnee, strobes et selections.
    fn bus_cycle(&mut self, addr: u32, data: u8, io: bool, write: bool) {
        let t0 = self.tq(0);
        self.acc += 1;
        let probing = self.sig.any_probe;
        // adresses (A0-A19) et donnees (D0-D7) : bits 0-27 du premier mot
        let newv = (addr as u64 & 0xFFFFF) | ((data as u64) << 20);
        let old = self.sig.cur[0] & 0x0FFF_FFFF;
        let ch = old ^ newv;
        if ch != 0 {
            self.sig.tog[0] |= ch;
            self.sig.cur[0] = (self.sig.cur[0] & !0x0FFF_FFFF) | newv;
            if probing && self.sig.probe[0] & ch != 0 {
                let mut m = self.sig.probe[0] & ch;
                while m != 0 {
                    let i = m.trailing_zeros() as usize;
                    m &= m - 1;
                    let tt = if i >= s::D0 { t0 + if write { 4 } else { 9 } } else { t0 };
                    if self.sig.events.len() < self.sig.max_events {
                        self.sig.events.push((tt, i as u8, ((newv >> i) & 1) as u8));
                    }
                }
            }
        }
        self.sig.set(s::IOM, io, t0);
        self.sig.pulse(s::ALE, true, t0, t0 + 3);
        // A16-A19/S3-S6 multiplexees cote 8088 (etat pendant T2-T4)
        self.sig.tog[s::S3 >> 6] |= 0xF << (s::S3 & 63);
        let strobe = if write { s::WR } else { s::RD };
        self.sig.pulse(strobe, false, t0 + 4, t0 + 12);
        if !write {
            self.sig.pulse(s::DTR, false, t0, t0 + 14);
        }
        self.sig.pulse(s::DEN, false, t0 + 2, t0 + 14);
        // U5 : NAND(A19, A19) = /A19 ; NAND(IO/M, IO/M) = M ; CE ROM/RAM
        let a19 = addr & 0x80000 != 0;
        let mem = !io;
        self.sig.set(s::NA19, !a19, t0 + 1);
        self.sig.set(s::MEM, mem, t0 + 1);
        self.sig.set(s::ROM_CE, !(a19 && mem), t0 + 1);
        self.sig.set(s::RAM_CE, !(!a19 && mem), t0 + 1);
        // 74LS138 : E1# = E2# = A7, E3 = IO/M ; entrees A4-A6
        let sel = if io && addr & 0x80 == 0 { Some(((addr >> 4) & 7) as usize) } else { None };
        for k in 0..8 {
            self.sig.set(s::O0 + k, sel != Some(k), t0 + 1);
        }
        if write {
            match sel {
                Some(0) => self.sig.pulse(s::LCD_E, true, t0 + 4, t0 + 12),
                Some(6) => {
                    self.sig.pulse(s::WR_61, true, t0 + 4, t0 + 12);
                    self.sig.pulse(s::CLK_61, false, t0 + 4, t0 + 12);
                }
                _ => {}
            }
        }
        self.last_addr = addr;
        self.last_data = data;
    }

    // ---------------------------------------------------------------- memoire
    fn ram_index(&self, addr: u32) -> usize {
        (addr & 0x7FFFF & !self.faults.ram_line_cut) as usize
    }

    pub fn peek(&self, addr: u32) -> u8 {
        let addr = addr & 0xFFFFF;
        if addr & 0x80000 != 0 {
            if self.faults.no_rom {
                0xFF
            } else {
                self.rom[(addr & 0x3FFFF) as usize]
            }
        } else {
            let i = self.ram_index(addr);
            let mut v = self.ram[i];
            if let Some((a, m)) = self.faults.ram_bad {
                if a as usize == i {
                    v &= !m;
                }
            }
            v
        }
    }

    pub fn poke(&mut self, addr: u32, v: u8) {
        let addr = addr & 0xFFFFF;
        if addr & 0x80000 == 0 {
            let i = self.ram_index(addr);
            self.ram[i] = v;
        }
    }

    // ---------------------------------------------------------------- E/S
    fn u12_ext(&mut self) -> [u8; 3] {
        // entrees de U12 : PB0 = KBD_CLK, PB1 = KBD_DATA, PB2 = UART_RX, PB3 = SD_MISO ;
        // broches libres : CMOS en l'air, lues a 1 ici
        let (clk, data) = self.kbd_lines;
        let miso = self.sd.miso();
        let pb = 0xF0 | (miso as u8) << 3 | (self.rx_line as u8) << 2 | (data as u8) << 1 | clk as u8;
        [0xFF, pb, 0xFF]
    }

    fn u12_changed(&mut self) {
        let t = self.tq(12);
        let ext = self.u12_ext();
        let pins = self.u12.pins(ext);
        let mask = self.u12.out_mask();
        for p in 0..3 {
            for bit in 0..8 {
                let i = s::U12_PA0 + p * 8 + bit;
                if mask[p] >> bit & 1 != 0 {
                    self.sig.set(i, pins[p] >> bit & 1 != 0, t);
                } else if p == 1 && bit < 4 {
                    self.sig.set(i, pins[p] >> bit & 1 != 0, t);
                } else {
                    self.sig.set_z(i, t);
                }
            }
        }
        // TX (PA7) : sortie flottante apres RESET = repos (tirage du terminal)
        let tx = if mask[0] & 0x80 != 0 { pins[0] & 0x80 != 0 } else { true };
        if mask[0] & 0x80 != 0 {
            self.sig.set(s::UART_TX, tx, t);
        } else {
            self.sig.set_z(s::UART_TX, t);
        }
        if self.tx.level() != tx {
            self.tx.edge(self.now + 4 * self.acc, tx);
        }
        // voyants D1 (PA0), D2 (PA1)
        if mask[0] & 1 != 0 {
            self.sig.set(s::VOY_DISQ, pins[0] & 1 != 0, t);
            self.sig.set(s::VOY_HD, pins[0] & 2 != 0, t);
        } else {
            self.sig.set_z(s::VOY_DISQ, t);
            self.sig.set_z(s::VOY_HD, t);
        }
        // carte SD : CS, SCK, MOSI (PC4-PC6), CS tire a 1 par R10 si PC en entree
        let pcv = if mask[2] & 0xF0 != 0 { pins[2] } else { 0x10 };
        self.sig.set(s::SD_CS, pcv & 0x10 != 0, t);
        if mask[2] & 0xF0 != 0 {
            self.sig.set(s::SD_SCK, pcv & 0x20 != 0, t);
            self.sig.set(s::SD_MOSI, pcv & 0x40 != 0, t);
        } else {
            self.sig.set_z(s::SD_SCK, t);
            self.sig.set_z(s::SD_MOSI, t);
        }
        self.sd.port_c(pcv);
        let miso = self.sd.miso();
        self.sig.set(s::SD_MISO, miso, t);
        self.sig.set(s::U12_PA0 + 11, miso, t);
    }

    fn u7_changed(&mut self) {
        let t = self.tq(12);
        let pins = self.u7.pins([0xFF; 3]);
        let mask = self.u7.out_mask();
        for p in 0..3 {
            for bit in 0..8 {
                let i = s::U7_PA0 + p * 8 + bit;
                if mask[p] >> bit & 1 != 0 {
                    self.sig.set(i, pins[p] >> bit & 1 != 0, t);
                } else {
                    self.sig.set_z(i, t);
                }
            }
        }
    }

    fn port61(&mut self, v: u8) {
        let t = self.tq(12);
        let g = v & 1 != 0;
        let en = v & 2 != 0;
        self.sig.set(s::GATE2, g, t);
        self.sig.set(s::U16_Q1, g, t);
        self.sig.set(s::NSPK_EN, !en, t);
        if g != self.gate2 {
            let tp = Self::pclk(self.now + 4 * self.acc);
            if !self.faults.no_pit {
                self.pit.set_gate(2, g, tp);
            }
        }
        self.gate2 = g;
        self.spk_en = en;
        self.next_ev = 0;
    }

    pub fn reset_peripherals(&mut self) {
        let t = self.tq(0);
        self.u7.reset();
        self.u12.reset();
        self.u7_changed();
        self.u12_changed();
        // ~CLR de U16 = ~RESET : GATE2 = 0, SPK_EN = 0
        self.gate2 = false;
        self.spk_en = false;
        self.pit.set_gate(2, false, Self::pclk(self.now));
        self.sig.set(s::GATE2, false, t);
        self.sig.set(s::U16_Q1, false, t);
        self.sig.set(s::NSPK_EN, true, t);
        self.next_ev = 0;
    }

    // ---------------------------------------------------------------- lignes et temps
    /// Met a jour les lignes des peripheriques a l'instant `now` (clavier, RX, minuterie).
    pub fn update(&mut self, now: u64) {
        let tq = now * 4;
        // minuterie : fronts de OUT0 et OUT2 a leur instant exact
        let mut next = u64::MAX;
        if !self.faults.no_pit {
            let tp = Self::pclk(now);
            loop {
                let o0 = self.pit.out(0, tp);
                if o0 == self.out0 {
                    break;
                }
                self.out0 = o0;
                self.sig.set(s::IRQ0, o0, tq);
                break;
            }
            if let Some(e) = self.pit.c[0].next_edge(tp) {
                next = next.min(e * 2);
            }
            let o1 = self.pit.out(1, tp);
            self.sig.set(s::OUT1, o1, tq);
            // OUT2 : seulement si le son peut sortir ou si l'on regarde
            let watch2 = self.spk_en || self.sig.probed(s::OUT2) || self.sig.probed(s::NOUT2);
            let o2 = self.pit.out(2, tp);
            if o2 != self.out2 {
                // instant exact du front (pour le son)
                self.out2 = o2;
                self.sig.set(s::OUT2, o2, tq);
                self.sig.set(s::NOUT2, !o2, tq);
            }
            if watch2 {
                if let Some(e) = self.pit.c[2].next_edge(tp) {
                    next = next.min(e * 2);
                }
            }
        }
        let spk = self.out2 && self.spk_en;
        if spk != self.spk {
            self.spk = spk;
            self.sig.set(s::SPK, spk, tq);
            self.sig.set(s::SPK_BZ, spk, tq);
            if self.audio_on {
                self.audio_ev.push((now, spk));
            }
        }
        // clavier PS/2
        let (mut clk, mut data) = self.kbd.lines(now);
        if self.faults.kbd_swap {
            std::mem::swap(&mut clk, &mut data);
        }
        if (clk, data) != self.kbd_lines {
            self.kbd_lines = (clk, data);
            self.sig.set(s::KBD_CLK, clk, tq);
            self.sig.set(s::KBD_DATA, data, tq);
            self.sig.set(s::U12_PA0 + 8, clk, tq);
            self.sig.set(s::U12_PA0 + 9, data, tq);
            self.sig.set(s::IRQ1, !clk, tq);
        }
        next = next.min(self.kbd.next_change(now));
        // UART RX (terminal) ; sans terminal : tirage R4, ou 0 si R4 est absente
        let rx = if self.term_connected { self.rx.line(now) } else { !self.faults.no_r4 };
        if rx != self.rx_line {
            self.rx_line = rx;
            self.sig.set(s::UART_RX, rx, tq);
            self.sig.set(s::U12_PA0 + 10, rx, tq);
            self.sig.set(s::IRQ4, !rx, tq);
        }
        if self.term_connected {
            next = next.min(self.rx.next_change(now));
        }
        // 8259 : IR0 = OUT0, IR1 = KBD_CLK inversee, IR4 = RX inversee (U14, 74LS14)
        if !self.faults.no_pic {
            let lv = (self.out0 as u8) | ((!clk as u8) << 1) | ((!rx as u8) << 4);
            if lv != self.pic.ir {
                self.pic.set_inputs(lv);
            }
            let int = self.pic.int_out;
            self.sig.set(s::INTR, int, tq);
        } else {
            self.sig.set_z(s::INTR, tq);
        }
        self.next_ev = next.max(now + 1);
    }

    pub fn int_pending(&self) -> bool {
        !self.faults.no_pic && self.pic.int_out
    }

    /// Echantillons du piezo (BZ1) de `audio_t` a `now`, a `rate` Hz.
    pub fn audio_take(&mut self, now: u64, rate: f64) -> Vec<f32> {
        let cps = CLK_HZ / rate;
        let mut out = Vec::new();
        if now <= self.audio_t {
            return out;
        }
        let mut ev = std::mem::take(&mut self.audio_ev);
        ev.retain(|e| e.0 >= self.audio_t);
        let mut ei = 0;
        let mut t = self.audio_t as f64 + self.audio_frac;
        let end = now as f64;
        while t + cps <= end {
            let t1 = t + cps;
            // moyenne du niveau sur [t, t1)
            let mut acc = 0.0;
            let mut cur_t = t;
            while ei < ev.len() && (ev[ei].0 as f64) < t1 {
                let et = (ev[ei].0 as f64).max(cur_t);
                if self.audio_level {
                    acc += et - cur_t;
                }
                cur_t = et;
                self.audio_level = ev[ei].1;
                ei += 1;
            }
            if self.audio_level {
                acc += t1 - cur_t;
            }
            let x = (acc / cps) as f32;
            // filtre passe-haut (le piezo ne rend pas le continu)
            let y = x - self.audio_x1 + 0.995 * self.audio_y1;
            self.audio_x1 = x;
            self.audio_y1 = y;
            out.push(y * 0.35);
            t = t1;
        }
        // evenements restants (apres t)
        self.audio_ev = ev.split_off(ei);
        self.audio_t = t.floor() as u64;
        self.audio_frac = t - self.audio_t as f64;
        out
    }

    pub fn audio_reset(&mut self, now: u64) {
        self.audio_ev.clear();
        self.audio_t = now;
        self.audio_frac = 0.0;
        self.audio_level = self.spk;
    }
}

impl Bus for Board {
    fn read8(&mut self, addr: u32) -> u8 {
        let v = self.peek(addr);
        self.mem_reads += 1;
        self.bus_cycle(addr, v, false, false);
        v
    }

    fn write8(&mut self, addr: u32, v: u8) {
        self.mem_writes += 1;
        let addr = addr & 0xFFFFF;
        if addr & 0x80000 != 0 {
            // WE# de la ROM a +5 V : ecriture sans effet
            self.rom_write_attempts += 1;
        } else {
            let i = self.ram_index(addr);
            self.ram[i] = v;
        }
        self.bus_cycle(addr, v, false, true);
    }

    fn io_read8(&mut self, port: u16) -> u8 {
        self.io_reads += 1;
        let p = port as u8;
        let now = self.now + 4 * self.acc;
        let v = if p & 0x80 != 0 {
            0xFF
        } else {
            match p >> 4 {
                1 => {
                    let v = self.u7.read(p, [0xFF; 3]);
                    if self.faults.u7_data_rev {
                        v.reverse_bits()
                    } else {
                        v
                    }
                }
                2 => {
                    if self.faults.no_pic {
                        0xFF
                    } else {
                        self.pic.read(p & 1 != 0)
                    }
                }
                3 => {
                    if p & 3 == 1 {
                        self.update(now);
                        self.kbd.mark_read();
                    }
                    let ext = self.u12_ext();
                    self.u12.read(p, ext)
                }
                4 => {
                    if self.faults.no_pit {
                        0xFF
                    } else {
                        self.pit.read(p, Self::pclk(now))
                    }
                }
                _ => 0xFF, // LCD en ecriture seule, port 61h en ecriture seule, O5/O7 libres
            }
        };
        self.rec_io(port, v, false);
        self.bus_cycle(port as u32, v, true, false);
        v
    }

    fn io_write8(&mut self, port: u16, v: u8) {
        self.io_writes += 1;
        let p = port as u8;
        let now = self.now + 4 * self.acc;
        self.rec_io(port, v, true);
        self.bus_cycle(port as u32, v, true, true);
        if p & 0x80 != 0 {
            return;
        }
        match p >> 4 {
            0 => {
                if !self.faults.no_lcd {
                    self.lcd.write(p & 1 != 0, v, now);
                }
            }
            1 => {
                let v = if self.faults.u7_data_rev { v.reverse_bits() } else { v };
                self.u7.write(p, v);
                self.u7_changed();
            }
            2 => {
                if !self.faults.no_pic {
                    self.pic.write(p & 1 != 0, v);
                    self.next_ev = 0;
                }
            }
            3 => {
                self.update(now);
                self.u12.write(p, v);
                self.u12_changed();
            }
            4 => {
                if !self.faults.no_pit {
                    self.pit.write(p, v, Self::pclk(now));
                    self.next_ev = 0;
                }
            }
            6 => self.port61(v),
            _ => {}
        }
    }

    fn inta(&mut self) -> u8 {
        let t0 = self.tq(0);
        // deux cycles INTA (le 2e donne le vecteur)
        self.sig.pulse(s::INTA, false, t0 + 4, t0 + 12);
        self.sig.pulse(s::INTA, false, t0 + 20, t0 + 28);
        self.acc += 2;
        let v = if self.faults.no_pic { 0xFF } else { self.pic.inta() };
        self.sig.set(s::INTR, self.pic.int_out, t0 + 28);
        self.next_ev = 0;
        v
    }
}

/// Raison de l'arret d'une execution.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stop {
    Budget = 0,
    Breakpoint = 1,
    Off = 3,
}

#[derive(Clone)]
pub struct Machine {
    pub cpu: Cpu,
    pub b: Board,
    pub powered: bool,
    pub reset_held: bool,
    reset_until: u64,
    pub breakpoints: Vec<u32>,
    skip_bp: bool,
    pub trace: Vec<u32>,
    trace_pos: usize,
    pub rom_image: Vec<u8>,
    seed: u64,
}

const TRACE: usize = 256;

impl Machine {
    pub fn new(rom: Vec<u8>) -> Self {
        let mut m = Machine {
            cpu: Cpu::new(),
            b: Board::new(rom.clone(), 0x5EED_1234),
            powered: false,
            reset_held: false,
            reset_until: 0,
            breakpoints: Vec::new(),
            skip_bp: false,
            trace: vec![0; TRACE],
            trace_pos: 0,
            rom_image: rom,
            seed: 0x5EED_1234,
        };
        m.power_on();
        m
    }

    /// Mise sous tension : RAM quelconque, LCD non initialise, 8259/8253 non programmes,
    /// RESET tenu ~5 ms par R1/C1 sur RES# du 82C84.
    pub fn power_on(&mut self) {
        self.seed = self.seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let faults = self.b.faults.clone();
        let sd = std::mem::take(&mut self.b.sd);
        let term = self.b.term_connected;
        let audio = self.b.audio_on;
        let probe = self.b.sig.probe;
        let any = self.b.sig.any_probe;
        self.b = Board::new(self.rom_image.clone(), self.seed);
        self.b.faults = faults;
        self.b.sd = sd;
        // la carte est remise a zero comme a l'insertion (SPI au repos)
        if let Some(d) = self.b.sd.disk.take() {
            self.b.sd.insert(d);
        }
        self.b.term_connected = term;
        self.b.audio_on = audio;
        self.b.sig.probe = probe;
        self.b.sig.any_probe = any;
        let t = self.cpu.cycles;
        self.cpu = Cpu::new();
        self.cpu.cycles = t;
        self.b.now = t;
        self.b.lcd = Lcd::new(t);
        self.b.audio_reset(t);
        self.powered = true;
        self.reset_until = t + (0.005 * CLK_HZ) as u64;
        self.set_reset_signals(true);
        self.b.reset_peripherals();
    }

    pub fn power_off(&mut self) {
        self.powered = false;
    }

    fn set_reset_signals(&mut self, on: bool) {
        let tq = self.cpu.cycles * 4;
        self.b.sig.set(s::RESET, on, tq);
        self.b.sig.set(s::NRESET, !on, tq);
        self.b.reset_line = on;
    }

    /// Bouton RESET (SW1) appuye ou relache.
    pub fn press_reset(&mut self, down: bool) {
        if !self.powered {
            return;
        }
        let tq = self.cpu.cycles * 4;
        self.b.begin(self.cpu.cycles);
        self.b.sig.set(s::NRES, !down, tq);
        if down {
            self.reset_held = true;
            self.set_reset_signals(true);
            self.b.reset_peripherals();
        } else if self.reset_held {
            self.reset_held = false;
            // le 82C84 synchronise : RESET retombe quelques cycles plus tard
            self.reset_until = self.cpu.cycles + 50;
        }
    }

    fn release_reset(&mut self) {
        self.b.begin(self.cpu.cycles);
        self.cpu.reset();
        self.set_reset_signals(false);
        self.b.reset_peripherals();
        self.reset_until = 0;
    }

    pub fn in_reset(&self) -> bool {
        self.reset_held || self.reset_until != 0
    }

    pub fn now(&self) -> u64 {
        self.cpu.cycles
    }

    /// Execute pendant `cycles` cycles d'horloge du 8088 (ou jusqu'a un point d'arret).
    pub fn run(&mut self, cycles: u64) -> Stop {
        if !self.powered {
            return Stop::Off;
        }
        let end = self.cpu.cycles + cycles;
        while self.cpu.cycles < end {
            let now = self.cpu.cycles;
            if self.reset_held {
                self.b.begin(end);
                self.b.update(end);
                self.cpu.cycles = end;
                continue;
            }
            if self.reset_until != 0 {
                if now >= self.reset_until {
                    self.release_reset();
                } else {
                    let t = end.min(self.reset_until);
                    self.b.begin(t);
                    self.b.update(t);
                    self.cpu.cycles = t;
                    continue;
                }
            }
            if self.step_inner(true) {
                return Stop::Breakpoint;
            }
            if self.cpu.halted && !(self.b.int_pending() && self.cpu.flags & IF != 0) {
                let t = end.min(self.b.next_ev).max(self.cpu.cycles + 1);
                self.cpu.cycles = t;
            }
        }
        Stop::Budget
    }

    /// Une instruction (ou une interruption materielle). Rend true si point d'arret.
    fn step_inner(&mut self, check_bp: bool) -> bool {
        let now = self.cpu.cycles;
        self.b.begin(now);
        if now >= self.b.next_ev {
            self.b.update(now);
        }
        if self.b.int_pending() && self.cpu.flags & IF != 0 && !self.cpu.inhibit {
            self.cpu.hw_interrupt(&mut self.b);
            self.cpu.inhibit = false;
            return false;
        }
        if self.cpu.halted {
            self.cpu.cycles += 1;
            return false;
        }
        let pc = self.cpu.pc();
        if check_bp && !self.breakpoints.is_empty() {
            if self.skip_bp {
                self.skip_bp = false;
            } else if self.breakpoints.contains(&pc) {
                self.skip_bp = true;
                return true;
            }
        }
        self.trace[self.trace_pos] = pc;
        self.trace_pos = (self.trace_pos + 1) % TRACE;
        let b = &mut self.b;
        b.begin(now);
        self.cpu.step(b);
        false
    }

    /// Pas a pas : une instruction (les interruptions en attente sont servies d'abord).
    pub fn step(&mut self) {
        if !self.powered || self.in_reset() {
            return;
        }
        self.skip_bp = false;
        loop {
            let ip = (self.cpu.s[1], self.cpu.ip);
            self.step_inner(false);
            if (self.cpu.s[1], self.cpu.ip) != ip || !self.cpu.halted {
                break;
            }
            if self.cpu.halted {
                // HLT : avance jusqu'au prochain evenement
                let t = self.b.next_ev.max(self.cpu.cycles + 1);
                if t == u64::MAX {
                    break;
                }
                self.cpu.cycles = t;
            }
        }
        self.skip_bp = true;
    }

    pub fn resume(&mut self) {
        self.skip_bp = true;
    }

    /// Dernieres adresses executees (de la plus ancienne a la plus recente).
    pub fn trace_history(&self) -> Vec<u32> {
        (0..TRACE).map(|k| self.trace[(self.trace_pos + k) % TRACE]).filter(|&a| a != 0).collect()
    }

    pub fn set_rom(&mut self, rom: Vec<u8>) {
        let mut r = rom;
        r.resize(0x40000, 0xFF);
        self.rom_image = r.clone();
        self.b.rom = r;
    }

    /// Lignes et signaux d'horloge (pour l'affichage : toujours actifs sous tension).
    pub fn mark_clocks(&mut self) {
        if self.powered {
            let tq = self.cpu.cycles * 4;
            self.b.sig.tog[s::CLK >> 6] |= 1 << (s::CLK & 63);
            self.b.sig.tog[s::PCLK >> 6] |= 1 << (s::PCLK & 63);
            let _ = tq;
        }
    }
}
