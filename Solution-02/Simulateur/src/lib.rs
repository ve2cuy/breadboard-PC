//! Simulateur de Solution-02 : ordinateur 8088 sur platine d'essai (VE2CUY).
//! Le meme code sert aux essais natifs (cargo test) et au fureteur (WebAssembly).

pub mod avr;
pub mod cpu;
pub mod disasm;
pub mod lcd;
pub mod machine;
pub mod pic;
pub mod pit;
pub mod ppi;
pub mod sd;
pub mod serial;
pub mod signals;

/// Horloge du 8088 : quartz de 16 MHz / 3 (82C84).
pub const CLK_HZ: f64 = 16_000_000.0 / 3.0;

use machine::Machine;
use std::rc::Rc;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

/// Interface du simulateur (exportee vers JavaScript).
#[cfg_attr(target_arch = "wasm32", wasm_bindgen)]
pub struct Sim {
    m: Machine,
    snap: Option<Machine>,
    pending_files: Vec<(String, Rc<Vec<u8>>)>,
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg_attr(target_arch = "wasm32", wasm_bindgen)]
impl Sim {
    #[cfg_attr(target_arch = "wasm32", wasm_bindgen(constructor))]
    pub fn new(rom: &[u8]) -> Sim {
        Sim { m: Machine::new(rom.to_vec()), snap: None, pending_files: Vec::new() }
    }

    pub fn clk_hz() -> f64 {
        CLK_HZ
    }

    // ------------------------------------------------------------ alimentation, reset
    pub fn power(&mut self, on: bool) {
        if on {
            self.m.power_on()
        } else {
            self.m.power_off()
        }
    }
    pub fn powered(&self) -> bool {
        self.m.powered
    }
    pub fn reset_button(&mut self, down: bool) {
        self.m.press_reset(down)
    }
    pub fn in_reset(&self) -> bool {
        self.m.in_reset()
    }
    pub fn set_rom(&mut self, rom: &[u8]) {
        self.m.set_rom(rom.to_vec())
    }

    // ------------------------------------------------------------ execution
    /// Execute `cycles` cycles. Rend 0 (fini), 1 (point d'arret), 3 (hors tension).
    pub fn run(&mut self, cycles: f64) -> u32 {
        let r = self.m.run(cycles.max(0.0) as u64) as u32;
        let now = self.m.cpu.cycles;
        self.m.b.tx.advance(now);
        r
    }
    pub fn step(&mut self) {
        self.m.step();
        let now = self.m.cpu.cycles;
        self.m.b.tx.advance(now);
    }
    pub fn cycles(&self) -> f64 {
        self.m.cpu.cycles as f64
    }
    pub fn instructions(&self) -> f64 {
        self.m.cpu.instructions as f64
    }
    pub fn set_breakpoints(&mut self, bps: Vec<u32>) {
        self.m.breakpoints = bps;
    }

    // ------------------------------------------------------------ registres, memoire
    /// AX CX DX BX SP BP SI DI ES CS SS DS IP FLAGS HALT
    pub fn regs(&self) -> Vec<u16> {
        let c = &self.m.cpu;
        let mut v = c.r.to_vec();
        v.extend_from_slice(&c.s);
        v.push(c.ip);
        v.push(c.flags);
        v.push(c.halted as u16);
        v
    }
    pub fn set_reg(&mut self, i: u32, v: u16) {
        let c = &mut self.m.cpu;
        match i {
            0..=7 => c.r[i as usize] = v,
            8..=11 => c.s[i as usize - 8] = v,
            12 => c.ip = v,
            13 => c.flags = (v & 0x0FD5) | 0xF002,
            _ => {}
        }
    }
    pub fn peek(&self, addr: u32, len: u32) -> Vec<u8> {
        (0..len).map(|k| self.m.b.peek(addr.wrapping_add(k) & 0xFFFFF)).collect()
    }
    pub fn poke(&mut self, addr: u32, v: u8) {
        self.m.b.poke(addr, v)
    }
    /// Lignes "adresse lineaire|CS:IP|octets|texte".
    pub fn disasm(&self, cs: u16, ip: u16, count: u32) -> String {
        let b = &self.m.b;
        let f = |a: u32| b.peek(a);
        let mut out = String::new();
        let mut ip = ip;
        for _ in 0..count {
            let (t, n) = disasm::disasm(&f, cs, ip);
            let lin = cpu::Cpu::phys(cs, ip);
            let bytes: Vec<String> =
                (0..n).map(|k| format!("{:02X}", b.peek(cpu::Cpu::phys(cs, ip.wrapping_add(k))))).collect();
            out.push_str(&format!("{}|{:04X}:{:04X}|{}|{}\n", lin, cs, ip, bytes.join(" "), t));
            ip = ip.wrapping_add(n);
        }
        out
    }
    /// Longueur de l'instruction en CS:IP (pour le pas a pas "par-dessus").
    pub fn insn_len(&self, cs: u16, ip: u16) -> u32 {
        let b = &self.m.b;
        let f = |a: u32| b.peek(a);
        disasm::disasm(&f, cs, ip).1 as u32
    }
    pub fn trace(&self) -> Vec<u32> {
        self.m.trace_history()
    }

    // ------------------------------------------------------------ LCD
    /// 80 codes visibles, 64 octets de CGRAM, puis : allume, curseur, clignotement,
    /// initialise, 2 lignes, ligne du curseur (255 = aucun), colonne, version (4 octets).
    pub fn lcd(&self) -> Vec<u8> {
        let l = &self.m.b.lcd;
        let mut v = l.visible().to_vec();
        v.extend_from_slice(&l.cgram);
        v.push(l.display_on as u8);
        v.push(l.cursor_on as u8);
        v.push(l.blink_on as u8);
        v.push(l.initialized as u8);
        v.push(l.two_lines as u8);
        let (r, c) = l.cursor_pos().map(|(r, c)| (r as u8, c as u8)).unwrap_or((255, 0));
        v.push(r);
        v.push(c);
        v.extend_from_slice(&(l.version as u32).to_le_bytes());
        v.push(self.m.b.faults.no_lcd as u8);
        v
    }

    // ------------------------------------------------------------ signaux, sonde
    pub fn signal_names() -> String {
        signals::NAMES.join("\n")
    }
    pub fn signals(&mut self) -> Vec<u8> {
        self.m.mark_clocks();
        self.m.b.sig.snapshot()
    }
    pub fn set_probes(&mut self, ids: Vec<u8>) {
        let sig = &mut self.m.b.sig;
        sig.probe = [0; 3];
        for i in &ids {
            let i = *i as usize;
            if i < signals::N {
                sig.probe[i >> 6] |= 1 << (i & 63);
            }
        }
        sig.any_probe = !ids.is_empty();
        sig.events.clear();
        self.m.b.next_ev = 0;
    }
    /// Changements sondes : triplets (instant bas, instant haut, signal << 8 | niveau),
    /// instant en quarts de cycle d'horloge.
    pub fn take_events(&mut self) -> Vec<u32> {
        let ev = std::mem::take(&mut self.m.b.sig.events);
        let mut v = Vec::with_capacity(ev.len() * 3);
        for (t, i, l) in ev {
            v.push(t as u32);
            v.push((t >> 32) as u32);
            v.push((i as u32) << 8 | l as u32);
        }
        v
    }

    // ------------------------------------------------------------ clavier PS/2, UART
    pub fn kbd(&mut self, bytes: &[u8]) {
        let now = self.m.cpu.cycles;
        self.m.b.kbd.push(bytes, now);
        self.m.b.next_ev = 0;
    }
    pub fn kbd_pending(&self) -> u32 {
        self.m.b.kbd.pending() as u32
    }
    pub fn uart_send(&mut self, bytes: &[u8]) {
        let now = self.m.cpu.cycles;
        self.m.b.rx.push(bytes, now);
        self.m.b.next_ev = 0;
    }
    pub fn uart_pending(&self) -> u32 {
        self.m.b.rx.pending() as u32
    }
    /// Ecart supplementaire entre deux octets envoyes au 8088 (microsecondes).
    pub fn uart_gap_us(&mut self, us: f64) {
        self.m.b.rx.gap = (us * CLK_HZ / 1e6) as u64;
    }
    pub fn uart_take(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.m.b.tx.out)
    }
    pub fn term_connected(&mut self, on: bool) {
        self.m.b.term_connected = on;
        if !on {
            self.m.b.rx.clear();
        }
        self.m.b.next_ev = 0;
    }
    /// Vitesse du terminal (bauds) : doit suivre celle de l'UART (VITESSE de l'ATmega).
    pub fn term_baud(&mut self, baud: u32) {
        self.m.b.rx.baud = baud.max(300) as u64;
        self.m.b.tx.baud = baud.max(300) as u64;
        self.m.b.next_ev = 0;
    }
    /// Le terminal respecte RTS de l'ATmega (controle de flux materiel, J8).
    pub fn term_rtscts(&mut self, on: bool) {
        self.m.b.term_rtscts = on;
        self.m.b.next_ev = 0;
    }

    // ------------------------------------------------------------ ATmega328P (U17)
    /// Variante de la carte : ATmega328P U17 (schema du 2026-11-23 : terminal sur l'UART
    /// logiciel de l'ATmega, module Wi-Fi sur son USART, esclave SPI du 8088) ou UART logiciel du
    /// 8088 (schema d'avant, BIOS 2.6). Garde au fil des mises sous tension ; l'ATmega repart a
    /// neuf a chaque changement, et le terminal prend sa vitesse de mise sous tension (57600).
    pub fn set_atmega(&mut self, on: bool) {
        let b = &mut self.m.b;
        b.avr = if on { Some(avr::Avr::new()) } else { None };
        if on {
            let v = avr::VITESSES[avr::V1_DEFAUT as usize];
            b.rx.baud = v;
            b.tx.baud = v;
        }
        b.rx.set_hold(false, self.m.cpu.cycles);
        b.rx.garde = on;
        b.rx.faites.clear();
        b.next_ev = 0;
    }
    /// Journal des transactions recues par l'ATmega (mise au point) : "t:cmd:n" par ligne.
    pub fn atmega_journal(&mut self) -> String {
        match self.m.b.avr.as_mut() {
            None => String::new(),
            Some(a) => std::mem::take(&mut a.journal)
                .iter()
                .map(|(t, c, n)| format!("{:.4}:{:02X}:{}", *t as f64 / CLK_HZ, c, n))
                .collect::<Vec<_>>()
                .join("
"),
        }
    }
    /// Lignes de commande recues par le module Wi-Fi (canal 2 de l'ATmega), une par ligne.
    pub fn wifi_journal(&self) -> String {
        match &self.m.b.avr {
            None => String::new(),
            Some(a) => a.wifi.journal.join("\n"),
        }
    }
    pub fn atmega(&self) -> bool {
        self.m.b.avr.is_some()
    }
    /// Etat de l'ATmega (JSON) : octets en attente, IRQ, RTS, vitesse, compteurs.
    pub fn atmega_state(&self) -> String {
        match &self.m.b.avr {
            None => "null".into(),
            Some(a) => format!(
                concat!(
                    "{{\"rx_nb\":{},\"tx_nb\":{},\"irq\":{},\"rts\":{},\"baud\":{},",
                    "\"octets_spi\":{},\"trop_tot\":{},\"recus\":{},\"emis\":{},",
                    "\"baud2\":{},\"rx2_nb\":{},\"tx2_nb\":{},\"recus2\":{},\"emis2\":{}}}"
                ),
                a.p.rx_nb(),
                a.p.tx_nb(),
                a.irq(),
                a.rts(),
                a.baud,
                a.octets_spi,
                a.trop_tot,
                a.recus,
                a.emis,
                a.baud2,
                a.p.rx2_nb(),
                a.p.tx2_nb(),
                a.recus2,
                a.emis2
            ),
        }
    }

    // ------------------------------------------------------------ son
    pub fn audio_enable(&mut self, on: bool) {
        let now = self.m.cpu.cycles;
        self.m.b.audio_on = on;
        self.m.b.audio_reset(now);
        self.m.b.next_ev = 0;
    }
    pub fn audio(&mut self, rate: f64) -> Vec<f32> {
        let now = self.m.cpu.cycles;
        self.m.b.audio_take(now, rate)
    }

    // ------------------------------------------------------------ carte SD
    pub fn sd_clear_files(&mut self) {
        self.pending_files.clear();
    }
    pub fn sd_add_file(&mut self, name: &str, data: &[u8]) {
        self.pending_files.push((name.to_string(), Rc::new(data.to_vec())));
    }
    /// Formate une carte FAT32 avec les fichiers ajoutes et l'insere.
    pub fn sd_insert_built(&mut self) {
        let d = sd::build_fat32(&self.pending_files);
        self.pending_files.clear();
        self.m.b.sd.insert(d);
    }
    /// Insere une image brute de carte entiere.
    pub fn sd_insert_raw(&mut self, data: &[u8]) {
        self.m.b.sd.insert(sd::Disk::from_raw(data.to_vec()));
    }
    pub fn sd_eject(&mut self) {
        self.m.b.sd.eject();
    }
    pub fn sd_present(&self) -> bool {
        self.m.b.sd.present()
    }
    /// JSON : [{"name":..,"size":..,"lba":..,"dirty":..}, ...]
    pub fn sd_files(&self) -> String {
        let mut out = String::from("[");
        if let Some(d) = &self.m.b.sd.disk {
            for (i, f) in d.files.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&format!(
                    "{{\"name\":\"{}\",\"size\":{},\"lba\":{},\"dirty\":{}}}",
                    esc(&f.name),
                    f.size,
                    f.lba,
                    d.file_dirty(i)
                ));
            }
        }
        out.push(']');
        out
    }
    pub fn sd_file(&self, i: u32) -> Vec<u8> {
        match &self.m.b.sd.disk {
            Some(d) if (i as usize) < d.files.len() => d.file_bytes(i as usize),
            _ => Vec::new(),
        }
    }
    /// lectures, ecritures, dernier LBA, derniere commande
    pub fn sd_stats(&self) -> Vec<f64> {
        let c = &self.m.b.sd;
        vec![c.reads as f64, c.writes as f64, c.last_lba as f64, c.last_cmd as f64]
    }

    // ------------------------------------------------------------ pannes
    pub fn set_fault(&mut self, name: &str, v: u32) {
        let f = &mut self.m.b.faults;
        match name {
            "ram_line_cut" => f.ram_line_cut = v & 0x7FFFF,
            "ram_bad" => f.ram_bad = if v == 0xFFFF_FFFF { None } else { Some((v & 0x7FFFF, 0xFF)) },
            "no_pic" => f.no_pic = v != 0,
            "no_pit" => f.no_pit = v != 0,
            "no_lcd" => f.no_lcd = v != 0,
            "no_rom" => f.no_rom = v != 0,
            "u7_data_rev" => f.u7_data_rev = v != 0,
            "kbd_swap" => f.kbd_swap = v != 0,
            "no_r4" => f.no_r4 = v != 0,
            _ => {}
        }
        self.m.b.next_ev = 0;
    }

    // ------------------------------------------------------------ instantanes
    pub fn snapshot(&mut self) {
        self.snap = Some(self.m.clone());
    }
    pub fn restore(&mut self) -> bool {
        match &self.snap {
            Some(s) => {
                let t = self.m.cpu.cycles;
                self.m = s.clone();
                // le temps ne recule pas pour l'interface : on garde la position relative
                let _ = t;
                true
            }
            None => false,
        }
    }
    pub fn has_snapshot(&self) -> bool {
        self.snap.is_some()
    }

    // ------------------------------------------------------------ J12 : IRQ libres du 8259
    /// Demasque de force IRn (2, 3, 5, 6, 7) : comme un programme qui ecrirait l'IMR.
    pub fn irq_enable(&mut self, n: u8, on: bool) {
        if n < 8 && 0xEC & (1 << n) != 0 {
            let b = &mut self.m.b;
            if on {
                b.pic.force |= 1 << n;
            } else {
                b.pic.force &= !(1 << n);
            }
            b.next_ev = 0;
        }
    }
    /// Fin d'interruption simulee pour les entrees libres (le BIOS les pointe sur un IRET seul).
    pub fn irq_sim_eoi(&mut self, on: bool) {
        self.m.b.pic.sim_eoi = if on { 0xEC } else { 0 };
    }
    /// Front montant sur IRn (J12), tenu jusqu'a INTA ou `ms` millisecondes.
    pub fn irq_trigger(&mut self, n: u8, ms: f64) -> bool {
        let hold = (ms * 1e-3 * CLK_HZ) as u64;
        self.m.b.irq_trigger(n, hold.max(1))
    }
    /// Etat du 8259 : [IMR, forcage, ISR, IRR, niveaux IR, demandes J12, initialise].
    pub fn irq_state(&self) -> Vec<u8> {
        let p = &self.m.b.pic;
        vec![p.imr, p.force, p.isr, p.irr(), p.ir, self.m.b.ext_irq, p.init as u8]
    }
    /// Interruptions libres servies depuis la derniere lecture : triplets (cycle, IRn, vecteur).
    pub fn take_irq_events(&mut self) -> Vec<f64> {
        let mut out = Vec::new();
        for (t, n, v) in self.m.b.irq_events.drain(..) {
            out.extend_from_slice(&[t as f64, n as f64, v as f64]);
        }
        out
    }

    // ------------------------------------------------------------ diagnostic
    /// Messages des modeles (delais du LCD, modes inattendus...), vides apres lecture.
    pub fn take_log(&mut self) -> String {
        let b = &mut self.m.b;
        let mut v: Vec<String> = Vec::new();
        v.append(&mut b.lcd.log);
        v.append(&mut b.u7.log);
        v.append(&mut b.u12.log);
        v.append(&mut b.pic.log);
        v.append(&mut b.pit.log);
        v.append(&mut b.sd.log);
        v.append(&mut b.log);
        v.join("\n")
    }

    pub fn io_history(&self) -> String {
        let mut out = String::new();
        for r in self.m.b.io_history().iter().rev().take(if cfg!(target_arch = "wasm32") { 64 } else { 4096 }) {
            out.push_str(&format!(
                "{}|{}|{:04X}|{:02X}\n",
                r.t,
                if r.write { "OUT" } else { "IN" },
                r.port,
                r.val
            ));
        }
        out
    }

    /// Statistiques (JSON).
    pub fn stats(&self) -> String {
        let b = &self.m.b;
        let c = &self.m.cpu;
        format!(
            concat!(
                "{{\"cycles\":{},\"instr\":{},\"io_r\":{},\"io_w\":{},\"mem_r\":{},\"mem_w\":{},",
                "\"rom_w\":{},\"kbd_frames\":{},\"kbd_lost\":{},\"kbd_pending\":{},\"tx_bytes\":{},",
                "\"tx_err\":{},\"tx_bit\":{},\"rx_pending\":{},\"irq\":[{},{},{},{},{},{},{},{}],",
                "\"spurious\":{},\"lcd_w\":{},\"lcd_v\":{},\"sd_r\":{},\"sd_w\":{},\"halted\":{},",
                "\"last_int\":{},\"spk\":{},\"gate2\":{},\"spk_en\":{}}}"
            ),
            c.cycles,
            c.instructions,
            b.io_reads,
            b.io_writes,
            b.mem_reads,
            b.mem_writes,
            b.rom_write_attempts,
            b.kbd.frames,
            b.kbd.lost,
            b.kbd.pending(),
            b.tx.bytes,
            b.tx.framing_errors,
            b.tx.last_bit,
            b.rx.pending(),
            b.pic.served[0],
            b.pic.served[1],
            b.pic.served[2],
            b.pic.served[3],
            b.pic.served[4],
            b.pic.served[5],
            b.pic.served[6],
            b.pic.served[7],
            b.pic.spurious,
            b.lcd.writes,
            b.lcd.violations,
            b.sd.reads,
            b.sd.writes,
            c.halted,
            c.last_int.map(|v| v as i32).unwrap_or(-1),
            b.spk,
            b.gate2,
            b.spk_en
        )
    }

    /// Etat interne d'une puce pour l'inspecteur (texte multiligne).
    pub fn chip_info(&self, r: &str) -> String {
        let b = &self.m.b;
        let c = &self.m.cpu;
        let t = Board::now_pclk(self.m.cpu.cycles);
        match r {
            "U1" => format!(
                "AX={:04X} BX={:04X} CX={:04X} DX={:04X}\nSP={:04X} BP={:04X} SI={:04X} DI={:04X}\nCS={:04X} DS={:04X} ES={:04X} SS={:04X}\nIP={:04X} FLAGS={:04X}{}\nInstructions : {}\nCycles : {}",
                c.r[0], c.r[3], c.r[1], c.r[2], c.r[4], c.r[5], c.r[6], c.r[7], c.s[1], c.s[3], c.s[0], c.s[2],
                c.ip, c.flags, if c.halted { "  (HLT)" } else { "" }, c.instructions, c.cycles
            ),
            "U7" | "U12" => {
                let p = if r == "U7" { &b.u7 } else { &b.u12 };
                let m = p.out_mask();
                let dir = |mask: u8| if mask == 0xFF { "sortie" } else if mask == 0 { "entrée" } else { "mixte" };
                format!(
                    "Mot de mode : {:02X}h\nPA : {:02X}h ({})\nPB : {:02X}h ({})\nPC : {:02X}h (haut {}, bas {})\nÉcritures : {}",
                    p.ctrl, p.out[0], dir(m[0]), p.out[1], dir(m[1]), p.out[2],
                    if m[2] & 0xF0 != 0 { "sortie" } else { "entrée" },
                    if m[2] & 0x0F != 0 { "sortie" } else { "entrée" }, p.writes
                )
            }
            "U13" => {
                let p = &b.pic;
                if b.faults.no_pic {
                    return "8259 retiré du montage".into();
                }
                format!(
                    "Initialisé : {}\nBase des vecteurs : {:02X}h\nMode : {}{}\nIMR : {:08b}\nIRR : {:08b}\nISR : {:08b}\nEntrees IR : {:08b}\nINT : {}\nServies IR0-7 : {:?}\nIRQ7 parasites : {}",
                    p.init, p.base, if p.level { "niveau" } else { "front" }, if p.aeoi { ", EOI auto" } else { "" },
                    p.imr, p.irr(), p.isr, p.ir, p.int_out as u8, p.served, p.spurious
                )
            }
            "U15" => {
                if b.faults.no_pit {
                    return "8253 retirée du montage".into();
                }
                let mut s = String::new();
                for (i, k) in b.pit.c.iter().enumerate() {
                    let (v, o) = k.state(t);
                    s.push_str(&format!(
                        "Compteur {} : mode {}, diviseur {}{}, valeur {}, OUT {}, GATE {}\n",
                        i,
                        k.mode,
                        k.n,
                        if k.loaded { format!(" ({:.2} Hz)", CLK_HZ / 2.0 / k.n as f64) } else { " (non chargé)".into() },
                        v,
                        o as u8,
                        k.gate as u8
                    ));
                }
                s
            }
            "U10" => {
                let l = &b.lcd;
                format!(
                    "Initialisé : {}\nAffichage : {}  curseur : {}  clignotement : {}\nAC : {:02X}h ({})\nDecalage : {}\nÉcritures : {}\nDélais non respectés : {}",
                    l.initialized, l.display_on, l.cursor_on, l.blink_on, l.ac,
                    if l.cg_mode { "CGRAM" } else { "DDRAM" }, l.shift, l.writes, l.violations
                )
            }
            "J9" => {
                let c = &b.sd;
                format!(
                    "Carte : {}\nLectures : {}\nÉcritures : {}\nDernier secteur : {}\nDernière commande : CMD{}",
                    if c.present() { "insérée" } else { "absente" },
                    c.reads, c.writes, c.last_lba, c.last_cmd
                )
            }
            "J4" => format!(
                "Trames envoyées : {}\nTrames perdues (non lues par le BIOS) : {}\nEn attente : {}\nDerniers octets : {:02X?}",
                b.kbd.frames, b.kbd.lost, b.kbd.pending(), b.kbd.sent.iter().rev().take(12).collect::<Vec<_>>()
            ),
            "J5" => format!(
                "Terminal : {}\n9600 8N1\nOctets reçus du 8088 : {}\nErreurs de trame : {}\nBit de départ mesuré : {:.1} us\nOctets en attente vers le 8088 : {}",
                if b.term_connected { "branché" } else { "débranché" },
                b.tx.bytes, b.tx.framing_errors, b.tx.last_bit as f64 * 1e6 / CLK_HZ, b.rx.pending()
            ),
            "U16" => format!("Port 61h\nGATE2 (D0) : {}\nSPK_EN (D1) : {}\nSPK : {}", b.gate2 as u8, b.spk_en as u8, b.spk as u8),
            "U4" => format!("ROM 256 Ko (29C020) en 80000h-FFFFFh (vue deux fois : A18 non reliée)\nÉcritures tentées (sans effet) : {}{}", b.rom_write_attempts, if b.faults.no_rom { "\nPUCE RETIRÉE" } else { "" }),
            "U6" => format!("RAM 512 Ko (HM628512) en 00000h-7FFFFh\nLectures : {}\nÉcritures : {}", b.mem_reads, b.mem_writes),
            _ => String::new(),
        }
    }
}

use machine::Board;
impl Board {
    pub fn now_pclk(t: u64) -> u64 {
        t / 2
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl Sim {
    pub fn machine(&mut self) -> &mut Machine {
        &mut self.m
    }
    pub fn lcd_lines(&self) -> Vec<String> {
        let v = self.m.b.lcd.visible();
        (0..4).map(|r| v[r * 20..r * 20 + 20].iter().map(|&c| if (0x20..0x7F).contains(&c) { c as char } else { '?' }).collect()).collect()
    }
}
