//! Processeur Intel 8088 (mode minimum), jeu d'instructions complet du 8086/8088,
//! y compris les alias et instructions non documentees (POP CS, SALC, 60h-6Fh, C0h/C1h/C8h/C9h).
//!
//! Durees : table d'Intel (8086) + 4 cycles par transfert de mot (bus de 8 bits), bornee
//! en bas par le debit du bus : 4 cycles par octet lu ou ecrit (instruction et donnees).
//! C'est ce qui fait tomber la boucle de l'UART logiciel du BIOS a ~553 cycles par bit
//! (555,6 attendus a 9600 bauds et 5,333 MHz), comme sur le montage.

pub const CF: u16 = 0x0001;
pub const PF: u16 = 0x0004;
pub const AF: u16 = 0x0010;
pub const ZF: u16 = 0x0040;
pub const SF: u16 = 0x0080;
pub const TF: u16 = 0x0100;
pub const IF: u16 = 0x0200;
pub const DF: u16 = 0x0400;
pub const OF: u16 = 0x0800;

pub const AX: usize = 0;
pub const CX: usize = 1;
pub const DX: usize = 2;
pub const BX: usize = 3;
pub const SP: usize = 4;
pub const BP: usize = 5;
pub const SI: usize = 6;
pub const DI: usize = 7;

pub const ES: usize = 0;
pub const CS: usize = 1;
pub const SS: usize = 2;
pub const DS: usize = 3;

/// Bus du systeme vu par le processeur.
pub trait Bus {
    fn read8(&mut self, addr: u32) -> u8;
    fn write8(&mut self, addr: u32, v: u8);
    fn io_read8(&mut self, port: u16) -> u8;
    fn io_write8(&mut self, port: u16, v: u8);
    /// Cycle INTA : rend le numero de vecteur donne par le 8259.
    fn inta(&mut self) -> u8;
    /// Lecture d'un octet d'instruction (meme chose que read8 ; separe pour l'analyse).
    fn fetch8(&mut self, addr: u32) -> u8 {
        self.read8(addr)
    }
}

#[derive(Clone)]
pub struct Cpu {
    pub r: [u16; 8],
    pub s: [u16; 4],
    pub ip: u16,
    pub flags: u16,
    pub halted: bool,
    /// Interruptions masquees pour l'instruction suivante (apres STI, MOV SS, POP SS).
    pub inhibit: bool,
    pub cycles: u64,
    pub instructions: u64,
    // etat de l'instruction en cours
    start_ip: u16,
    seg_ovr: Option<usize>,
    rep: u8,
    t: u32,
    bus_bytes: u32,
    // ModR/M decode
    modrm: u8,
    ea_seg: usize,
    ea_off: u16,
    ea_is_reg: bool,
    /// Vecteur d'interruption logicielle ou d'exception a servir apres l'instruction.
    pending_int: Option<u8>,
    /// Dernier vecteur servi (pour le debogueur).
    pub last_int: Option<u8>,
}

impl Default for Cpu {
    fn default() -> Self {
        Self::new()
    }
}

#[inline]
fn parity(v: u8) -> bool {
    v.count_ones() & 1 == 0
}

impl Cpu {
    pub fn new() -> Self {
        let mut c = Cpu {
            r: [0; 8],
            s: [0; 4],
            ip: 0,
            flags: 0xF002,
            halted: false,
            inhibit: false,
            cycles: 0,
            instructions: 0,
            start_ip: 0,
            seg_ovr: None,
            rep: 0,
            t: 0,
            bus_bytes: 0,
            modrm: 0,
            ea_seg: DS,
            ea_off: 0,
            ea_is_reg: false,
            pending_int: None,
            last_int: None,
        };
        c.reset();
        c
    }

    /// RESET du 8088 : CS = FFFFh, IP = 0, drapeaux a 0, file vide.
    pub fn reset(&mut self) {
        self.s = [0, 0xFFFF, 0, 0];
        self.ip = 0;
        self.flags = 0xF002;
        self.halted = false;
        self.inhibit = false;
        self.pending_int = None;
    }

    #[inline]
    pub fn phys(seg: u16, off: u16) -> u32 {
        (((seg as u32) << 4) + off as u32) & 0xFFFFF
    }

    #[inline]
    pub fn get_flag(&self, f: u16) -> bool {
        self.flags & f != 0
    }
    #[inline]
    fn set_flag(&mut self, f: u16, v: bool) {
        if v {
            self.flags |= f
        } else {
            self.flags &= !f
        }
    }

    // ---------------------------------------------------------------- acces memoire
    #[inline]
    fn rd8<B: Bus>(&mut self, b: &mut B, seg: usize, off: u16) -> u8 {
        self.bus_bytes += 1;
        b.read8(Self::phys(self.s[seg], off))
    }
    #[inline]
    fn rd16<B: Bus>(&mut self, b: &mut B, seg: usize, off: u16) -> u16 {
        self.t += 4;
        let lo = self.rd8(b, seg, off) as u16;
        let hi = self.rd8(b, seg, off.wrapping_add(1)) as u16;
        lo | (hi << 8)
    }
    #[inline]
    fn wr8<B: Bus>(&mut self, b: &mut B, seg: usize, off: u16, v: u8) {
        self.bus_bytes += 1;
        b.write8(Self::phys(self.s[seg], off), v)
    }
    #[inline]
    fn wr16<B: Bus>(&mut self, b: &mut B, seg: usize, off: u16, v: u16) {
        self.t += 4;
        self.wr8(b, seg, off, v as u8);
        self.wr8(b, seg, off.wrapping_add(1), (v >> 8) as u8);
    }
    #[inline]
    fn fetch8<B: Bus>(&mut self, b: &mut B) -> u8 {
        let v = b.fetch8(Self::phys(self.s[CS], self.ip));
        self.ip = self.ip.wrapping_add(1);
        self.bus_bytes += 1;
        v
    }
    #[inline]
    fn fetch16<B: Bus>(&mut self, b: &mut B) -> u16 {
        let lo = self.fetch8(b) as u16;
        let hi = self.fetch8(b) as u16;
        lo | (hi << 8)
    }
    fn push<B: Bus>(&mut self, b: &mut B, v: u16) {
        self.r[SP] = self.r[SP].wrapping_sub(2);
        let sp = self.r[SP];
        self.wr16(b, SS, sp, v);
    }
    fn pop<B: Bus>(&mut self, b: &mut B) -> u16 {
        let sp = self.r[SP];
        let v = self.rd16(b, SS, sp);
        self.r[SP] = sp.wrapping_add(2);
        v
    }

    // ---------------------------------------------------------------- registres
    #[inline]
    pub fn get_r8(&self, i: usize) -> u8 {
        if i < 4 {
            self.r[i] as u8
        } else {
            (self.r[i - 4] >> 8) as u8
        }
    }
    #[inline]
    pub fn set_r8(&mut self, i: usize, v: u8) {
        if i < 4 {
            self.r[i] = (self.r[i] & 0xFF00) | v as u16
        } else {
            self.r[i - 4] = (self.r[i - 4] & 0x00FF) | ((v as u16) << 8)
        }
    }

    // ---------------------------------------------------------------- ModR/M
    fn decode_modrm<B: Bus>(&mut self, b: &mut B) {
        let m = self.fetch8(b);
        self.modrm = m;
        let md = m >> 6;
        let rm = m & 7;
        if md == 3 {
            self.ea_is_reg = true;
            return;
        }
        self.ea_is_reg = false;
        let (base, mut seg, ea_t): (u16, usize, u32) = match rm {
            0 => (self.r[BX].wrapping_add(self.r[SI]), DS, 7),
            1 => (self.r[BX].wrapping_add(self.r[DI]), DS, 8),
            2 => (self.r[BP].wrapping_add(self.r[SI]), SS, 8),
            3 => (self.r[BP].wrapping_add(self.r[DI]), SS, 7),
            4 => (self.r[SI], DS, 5),
            5 => (self.r[DI], DS, 5),
            6 => {
                if md == 0 {
                    (0, DS, 6)
                } else {
                    (self.r[BP], SS, 5)
                }
            }
            _ => (self.r[BX], DS, 5),
        };
        let mut off = base;
        let mut t = ea_t;
        match md {
            0 => {
                if rm == 6 {
                    off = self.fetch16(b);
                }
            }
            1 => {
                let d = self.fetch8(b) as i8 as i16 as u16;
                off = off.wrapping_add(d);
                t += 4;
            }
            _ => {
                let d = self.fetch16(b);
                off = off.wrapping_add(d);
                t += 4;
            }
        }
        if let Some(o) = self.seg_ovr {
            seg = o;
            t += 2;
        }
        self.t += t;
        self.ea_seg = seg;
        self.ea_off = off;
    }
    #[inline]
    fn reg_field(&self) -> usize {
        ((self.modrm >> 3) & 7) as usize
    }
    #[inline]
    fn rm_field(&self) -> usize {
        (self.modrm & 7) as usize
    }
    fn rm8<B: Bus>(&mut self, b: &mut B) -> u8 {
        if self.ea_is_reg {
            self.get_r8(self.rm_field())
        } else {
            let (s, o) = (self.ea_seg, self.ea_off);
            self.rd8(b, s, o)
        }
    }
    fn rm16<B: Bus>(&mut self, b: &mut B) -> u16 {
        if self.ea_is_reg {
            self.r[self.rm_field()]
        } else {
            let (s, o) = (self.ea_seg, self.ea_off);
            self.rd16(b, s, o)
        }
    }
    fn set_rm8<B: Bus>(&mut self, b: &mut B, v: u8) {
        if self.ea_is_reg {
            let i = self.rm_field();
            self.set_r8(i, v)
        } else {
            let (s, o) = (self.ea_seg, self.ea_off);
            self.wr8(b, s, o, v)
        }
    }
    fn set_rm16<B: Bus>(&mut self, b: &mut B, v: u16) {
        if self.ea_is_reg {
            let i = self.rm_field();
            self.r[i] = v
        } else {
            let (s, o) = (self.ea_seg, self.ea_off);
            self.wr16(b, s, o, v)
        }
    }

    // ---------------------------------------------------------------- drapeaux
    fn szp8(&mut self, v: u8) {
        self.set_flag(ZF, v == 0);
        self.set_flag(SF, v & 0x80 != 0);
        self.set_flag(PF, parity(v));
    }
    fn szp16(&mut self, v: u16) {
        self.set_flag(ZF, v == 0);
        self.set_flag(SF, v & 0x8000 != 0);
        self.set_flag(PF, parity(v as u8));
    }

    /// Operation arithmetique/logique 0-7 (ADD OR ADC SBB AND SUB XOR CMP), taille 8 ou 16.
    fn alu(&mut self, op: u8, a: u16, bv: u16, w: bool) -> u16 {
        let mask: u32 = if w { 0xFFFF } else { 0xFF };
        let sign: u32 = if w { 0x8000 } else { 0x80 };
        let (a32, b32) = (a as u32 & mask, bv as u32 & mask);
        let cin = if self.get_flag(CF) { 1 } else { 0 };
        let res: u32;
        match op {
            0 | 2 => {
                let c = if op == 2 { cin } else { 0 };
                let r = a32 + b32 + c;
                res = r & mask;
                self.set_flag(CF, r > mask);
                self.set_flag(AF, ((a32 ^ b32 ^ r) & 0x10) != 0);
                self.set_flag(OF, ((r ^ a32) & (r ^ b32) & sign) != 0);
            }
            3 | 5 | 7 => {
                let c = if op == 3 { cin } else { 0 };
                let r = a32.wrapping_sub(b32).wrapping_sub(c);
                res = r & mask;
                self.set_flag(CF, b32 + c > a32);
                self.set_flag(AF, ((a32 ^ b32 ^ r) & 0x10) != 0);
                self.set_flag(OF, ((a32 ^ b32) & (a32 ^ r) & sign) != 0);
            }
            _ => {
                res = match op {
                    1 => a32 | b32,
                    4 => a32 & b32,
                    _ => a32 ^ b32,
                };
                self.set_flag(CF, false);
                self.set_flag(OF, false);
                self.set_flag(AF, false);
            }
        }
        if w {
            self.szp16(res as u16)
        } else {
            self.szp8(res as u8)
        }
        res as u16
    }

    fn inc_dec(&mut self, v: u16, dec: bool, w: bool) -> u16 {
        let cf = self.get_flag(CF);
        let r = self.alu(if dec { 5 } else { 0 }, v, 1, w);
        self.set_flag(CF, cf);
        r
    }

    /// Decalages et rotations (groupe 2) : op 0-7, compte, taille.
    fn shift(&mut self, op: u8, v: u16, count: u8, w: bool) -> u16 {
        if count == 0 {
            return v;
        }
        let bits: u32 = if w { 16 } else { 8 };
        let mask: u32 = if w { 0xFFFF } else { 0xFF };
        let msb: u32 = 1 << (bits - 1);
        let mut x = v as u32 & mask;
        let mut cf = self.get_flag(CF);
        for _ in 0..count {
            match op {
                0 => {
                    // ROL
                    cf = x & msb != 0;
                    x = ((x << 1) | cf as u32) & mask;
                }
                1 => {
                    // ROR
                    cf = x & 1 != 0;
                    x = (x >> 1) | if cf { msb } else { 0 };
                }
                2 => {
                    // RCL
                    let nc = x & msb != 0;
                    x = ((x << 1) | cf as u32) & mask;
                    cf = nc;
                }
                3 => {
                    // RCR
                    let nc = x & 1 != 0;
                    x = (x >> 1) | if cf { msb } else { 0 };
                    cf = nc;
                }
                4 => {
                    // SHL/SAL
                    cf = x & msb != 0;
                    x = (x << 1) & mask;
                }
                6 => {
                    // SETMO / SETMOC (non documentees) : operande a 1 partout
                    cf = false;
                    x = mask;
                }
                5 => {
                    // SHR
                    cf = x & 1 != 0;
                    x >>= 1;
                }
                _ => {
                    // SAR
                    cf = x & 1 != 0;
                    x = (x >> 1) | (x & msb);
                }
            }
        }
        self.set_flag(CF, cf);
        let top = x & msb != 0;
        match op {
            0 | 2 | 4 => self.set_flag(OF, top != cf),
            6 => self.set_flag(OF, false),
            1 | 3 => {
                let next = x & (msb >> 1) != 0;
                self.set_flag(OF, top != next)
            }
            5 => {
                // SHR : OF = bit de poids fort de l'operande d'origine (compte de 1)
                let orig = if count == 1 { v as u32 & msb != 0 } else { false };
                self.set_flag(OF, orig)
            }
            _ => self.set_flag(OF, false),
        }
        if op >= 4 {
            if w {
                self.szp16(x as u16)
            } else {
                self.szp8(x as u8)
            }
            self.set_flag(AF, false);
        }
        x as u16
    }

    fn cond(&self, c: u8) -> bool {
        let f = |x| self.get_flag(x);
        let r = match c >> 1 {
            0 => f(OF),
            1 => f(CF),
            2 => f(ZF),
            3 => f(CF) || f(ZF),
            4 => f(SF),
            5 => f(PF),
            6 => f(SF) != f(OF),
            _ => f(ZF) || (f(SF) != f(OF)),
        };
        if c & 1 != 0 {
            !r
        } else {
            r
        }
    }

    // ---------------------------------------------------------------- interruptions
    /// Entree dans une interruption (logicielle, exception ou materielle).
    pub fn interrupt<B: Bus>(&mut self, b: &mut B, v: u8) {
        let f = self.flags | 0xF002;
        self.push(b, f);
        self.flags &= !(IF | TF);
        let cs = self.s[CS];
        self.push(b, cs);
        let ip = self.ip;
        self.push(b, ip);
        let a = (v as u32) * 4;
        self.bus_bytes += 4;
        let lo = b.read8(a) as u16 | (b.read8(a + 1) as u16) << 8;
        let hi = b.read8(a + 2) as u16 | (b.read8(a + 3) as u16) << 8;
        self.ip = lo;
        self.s[CS] = hi;
        self.halted = false;
        self.last_int = Some(v);
    }

    /// Interruption materielle (INTR) : cycles INTA puis entree. Rend les cycles consommes.
    pub fn hw_interrupt<B: Bus>(&mut self, b: &mut B) -> u32 {
        self.t = 0;
        self.bus_bytes = 0;
        let v = b.inta();
        self.interrupt(b, v);
        self.inhibit = false;
        let c = 61u32.max(4 * self.bus_bytes);
        self.cycles += c as u64;
        c
    }

    /// Adresse lineaire de la prochaine instruction.
    pub fn pc(&self) -> u32 {
        Self::phys(self.s[CS], self.ip)
    }

    // ---------------------------------------------------------------- execution
    /// Execute une instruction (ou une iteration d'une instruction de chaine repetee).
    /// Rend le nombre de cycles d'horloge consommes.
    pub fn step<B: Bus>(&mut self, b: &mut B) -> u32 {
        if self.halted {
            self.cycles += 4;
            return 4;
        }
        self.t = 0;
        self.bus_bytes = 0;
        self.seg_ovr = None;
        self.rep = 0;
        self.start_ip = self.ip;
        let trap = self.get_flag(TF);
        self.inhibit = false;
        let mut op;
        loop {
            op = self.fetch8(b);
            match op {
                0x26 => self.seg_ovr = Some(ES),
                0x2E => self.seg_ovr = Some(CS),
                0x36 => self.seg_ovr = Some(SS),
                0x3E => self.seg_ovr = Some(DS),
                0xF0 | 0xF1 => {}
                0xF2 => self.rep = 1,
                0xF3 => self.rep = 2,
                _ => break,
            }
            self.t += 2;
        }
        self.exec(b, op);
        if let Some(v) = self.pending_int.take() {
            self.interrupt(b, v);
        }
        if trap && !self.inhibit {
            // pas a pas (TF) : INT 1 apres l'instruction
            self.interrupt(b, 1);
        }
        let c = self.t.max(4 * self.bus_bytes).max(2);
        self.cycles += c as u64;
        self.instructions += 1;
        c
    }

    fn seg_default(&self, d: usize) -> usize {
        self.seg_ovr.unwrap_or(d)
    }

    fn exec<B: Bus>(&mut self, b: &mut B, op: u8) {
        match op {
            // ---------------------------------------------------- ALU r/m, reg / imm
            0x00..=0x3F if op & 7 < 6 => {
                let alu_op = (op >> 3) & 7;
                let w = op & 1 != 0;
                match op & 7 {
                    0..=3 => {
                        self.decode_modrm(b);
                        let to_reg = op & 2 != 0;
                        let reg = self.reg_field();
                        let (a, bb) = if w {
                            let rm = self.rm16(b);
                            if to_reg {
                                (self.r[reg], rm)
                            } else {
                                (rm, self.r[reg])
                            }
                        } else {
                            let rm = self.rm8(b) as u16;
                            let rv = self.get_r8(reg) as u16;
                            if to_reg {
                                (rv, rm)
                            } else {
                                (rm, rv)
                            }
                        };
                        let r = self.alu(alu_op, a, bb, w);
                        if alu_op != 7 {
                            if to_reg {
                                if w {
                                    self.r[reg] = r
                                } else {
                                    self.set_r8(reg, r as u8)
                                }
                            } else if w {
                                self.set_rm16(b, r)
                            } else {
                                self.set_rm8(b, r as u8)
                            }
                        }
                        self.t += if self.ea_is_reg {
                            3
                        } else if to_reg || alu_op == 7 {
                            9
                        } else {
                            16
                        };
                    }
                    4 => {
                        let v = self.fetch8(b) as u16;
                        let a = self.r[AX] & 0xFF;
                        let r = self.alu(alu_op, a, v, false);
                        if alu_op != 7 {
                            self.set_r8(0, r as u8)
                        }
                        self.t += 4;
                    }
                    _ => {
                        let v = self.fetch16(b);
                        let a = self.r[AX];
                        let r = self.alu(alu_op, a, v, true);
                        if alu_op != 7 {
                            self.r[AX] = r
                        }
                        self.t += 4;
                    }
                }
            }
            0x06 | 0x0E | 0x16 | 0x1E => {
                let v = self.s[(op >> 3) as usize & 3];
                self.push(b, v);
                self.t += 10;
            }
            0x07 | 0x0F | 0x17 | 0x1F => {
                let v = self.pop(b);
                self.s[(op >> 3) as usize & 3] = v;
                if op == 0x17 {
                    self.inhibit = true;
                }
                self.t += 8;
            }
            0x27 => {
                // DAA
                let al = self.get_r8(0);
                let cf = self.get_flag(CF);
                let af0 = self.get_flag(AF);
                let mut v = al;
                let mut ncf = false;
                if (al & 0x0F) > 9 || self.get_flag(AF) {
                    let (r, c) = v.overflowing_add(6);
                    v = r;
                    ncf = cf || c;
                    self.set_flag(AF, true);
                } else {
                    self.set_flag(AF, false);
                }
                // 8088 : le seuil passe a 9Fh quand AF etait a 1 (releve sur un vrai 8088)
                let seuil = if af0 { 0x9F } else { 0x99 };
                if al > seuil || cf {
                    v = v.wrapping_add(0x60);
                    ncf = true;
                }
                self.set_flag(CF, ncf);
                self.set_r8(0, v);
                self.szp8(v);
                self.t += 4;
            }
            0x2F => {
                // DAS
                let al = self.get_r8(0);
                let cf = self.get_flag(CF);
                let af0 = self.get_flag(AF);
                let mut v = al;
                let mut ncf = false;
                if (al & 0x0F) > 9 || af0 {
                    // 8088 : l'emprunt de cette soustraction n'est pas reporte dans CF
                    v = v.wrapping_sub(6);
                    ncf = cf;
                    self.set_flag(AF, true);
                } else {
                    self.set_flag(AF, false);
                }
                let seuil = if af0 { 0x9F } else { 0x99 };
                if al > seuil || cf {
                    v = v.wrapping_sub(0x60);
                    ncf = true;
                }
                self.set_flag(CF, ncf);
                self.set_r8(0, v);
                self.szp8(v);
                self.t += 4;
            }
            0x37 | 0x3F => {
                // AAA / AAS
                let al = self.get_r8(0);
                if (al & 0x0F) > 9 || self.get_flag(AF) {
                    // AL et AH ajustes separement : pas de retenue de AL vers AH
                    let ah = self.get_r8(4);
                    if op == 0x37 {
                        self.set_r8(0, al.wrapping_add(6));
                        self.set_r8(4, ah.wrapping_add(1));
                    } else {
                        self.set_r8(0, al.wrapping_sub(6));
                        self.set_r8(4, ah.wrapping_sub(1));
                    }
                    self.set_flag(AF, true);
                    self.set_flag(CF, true);
                } else {
                    self.set_flag(AF, false);
                    self.set_flag(CF, false);
                }
                let v = self.get_r8(0) & 0x0F;
                self.set_r8(0, v);
                self.t += 8;
            }
            // ---------------------------------------------------- INC/DEC/PUSH/POP reg
            0x40..=0x47 => {
                let i = (op & 7) as usize;
                self.r[i] = self.inc_dec(self.r[i], false, true);
                self.t += 2;
            }
            0x48..=0x4F => {
                let i = (op & 7) as usize;
                self.r[i] = self.inc_dec(self.r[i], true, true);
                self.t += 2;
            }
            0x50..=0x57 => {
                let i = (op & 7) as usize;
                if i == SP {
                    // 8086 : PUSH SP empile la valeur deja decrementee
                    self.r[SP] = self.r[SP].wrapping_sub(2);
                    let sp = self.r[SP];
                    self.wr16(b, SS, sp, sp);
                } else {
                    let v = self.r[i];
                    self.push(b, v);
                }
                self.t += 11;
            }
            0x58..=0x5F => {
                let v = self.pop(b);
                self.r[(op & 7) as usize] = v;
                self.t += 8;
            }
            // ---------------------------------------------------- sauts conditionnels
            0x60..=0x7F => {
                let d = self.fetch8(b) as i8 as i16 as u16;
                if self.cond(op & 0x0F) {
                    self.ip = self.ip.wrapping_add(d);
                    self.t += 16;
                } else {
                    self.t += 4;
                }
            }
            // ---------------------------------------------------- groupe 1
            0x80..=0x83 => {
                self.decode_modrm(b);
                let w = op & 1 != 0;
                let alu_op = self.reg_field() as u8;
                let a = if w { self.rm16(b) } else { self.rm8(b) as u16 };
                let v = if op == 0x81 {
                    self.fetch16(b)
                } else if op == 0x83 {
                    self.fetch8(b) as i8 as i16 as u16
                } else {
                    self.fetch8(b) as u16
                };
                let r = self.alu(alu_op, a, v, w);
                if alu_op != 7 {
                    if w {
                        self.set_rm16(b, r)
                    } else {
                        self.set_rm8(b, r as u8)
                    }
                }
                self.t += if self.ea_is_reg {
                    4
                } else if alu_op == 7 {
                    10
                } else {
                    17
                };
            }
            0x84 | 0x85 => {
                self.decode_modrm(b);
                let reg = self.reg_field();
                if op & 1 != 0 {
                    let a = self.rm16(b);
                    self.alu(4, a, self.r[reg], true);
                } else {
                    let a = self.rm8(b) as u16;
                    self.alu(4, a, self.get_r8(reg) as u16, false);
                }
                self.t += if self.ea_is_reg { 3 } else { 9 };
            }
            0x86 | 0x87 => {
                self.decode_modrm(b);
                let reg = self.reg_field();
                if op & 1 != 0 {
                    let a = self.rm16(b);
                    let rv = self.r[reg];
                    self.set_rm16(b, rv);
                    self.r[reg] = a;
                } else {
                    let a = self.rm8(b);
                    let rv = self.get_r8(reg);
                    self.set_rm8(b, rv);
                    self.set_r8(reg, a);
                }
                self.t += if self.ea_is_reg { 4 } else { 17 };
            }
            0x88..=0x8B => {
                self.decode_modrm(b);
                let reg = self.reg_field();
                match op {
                    0x88 => {
                        let v = self.get_r8(reg);
                        self.set_rm8(b, v)
                    }
                    0x89 => {
                        let v = self.r[reg];
                        self.set_rm16(b, v)
                    }
                    0x8A => {
                        let v = self.rm8(b);
                        self.set_r8(reg, v)
                    }
                    _ => {
                        let v = self.rm16(b);
                        self.r[reg] = v
                    }
                }
                self.t += if self.ea_is_reg {
                    2
                } else if op >= 0x8A {
                    8
                } else {
                    9
                };
            }
            0x8C => {
                self.decode_modrm(b);
                let v = self.s[self.reg_field() & 3];
                self.set_rm16(b, v);
                self.t += if self.ea_is_reg { 2 } else { 9 };
            }
            0x8D => {
                self.decode_modrm(b);
                let reg = self.reg_field();
                if !self.ea_is_reg {
                    self.r[reg] = self.ea_off;
                }
                self.t += 2;
            }
            0x8E => {
                self.decode_modrm(b);
                let v = self.rm16(b);
                let sr = self.reg_field() & 3;
                self.s[sr] = v;
                if sr == SS {
                    self.inhibit = true;
                }
                self.t += if self.ea_is_reg { 2 } else { 8 };
            }
            0x8F => {
                self.decode_modrm(b);
                let v = self.pop(b);
                self.set_rm16(b, v);
                self.t += if self.ea_is_reg { 8 } else { 17 };
            }
            0x90..=0x97 => {
                let i = (op & 7) as usize;
                self.r.swap(AX, i);
                self.t += 3;
            }
            0x98 => {
                self.r[AX] = self.get_r8(0) as i8 as i16 as u16;
                self.t += 2;
            }
            0x99 => {
                self.r[DX] = if self.r[AX] & 0x8000 != 0 { 0xFFFF } else { 0 };
                self.t += 5;
            }
            0x9A => {
                let nip = self.fetch16(b);
                let ncs = self.fetch16(b);
                let cs = self.s[CS];
                self.push(b, cs);
                let ip = self.ip;
                self.push(b, ip);
                self.ip = nip;
                self.s[CS] = ncs;
                self.t += 28;
            }
            0x9B => self.t += 3,
            0x9C => {
                let f = self.flags | 0xF002;
                self.push(b, f);
                self.t += 10;
            }
            0x9D => {
                let v = self.pop(b);
                self.flags = (v & 0x0FD5) | 0xF002;
                self.t += 8;
            }
            0x9E => {
                let ah = self.get_r8(4) as u16;
                self.flags = (self.flags & 0xFF00) | (ah & 0xD5) | 2;
                self.t += 4;
            }
            0x9F => {
                let f = (self.flags & 0xD5) | 2;
                self.set_r8(4, f as u8);
                self.t += 4;
            }
            0xA0..=0xA3 => {
                let off = self.fetch16(b);
                let seg = self.seg_default(DS);
                match op {
                    0xA0 => {
                        let v = self.rd8(b, seg, off);
                        self.set_r8(0, v)
                    }
                    0xA1 => {
                        let v = self.rd16(b, seg, off);
                        self.r[AX] = v
                    }
                    0xA2 => {
                        let v = self.get_r8(0);
                        self.wr8(b, seg, off, v)
                    }
                    _ => {
                        let v = self.r[AX];
                        self.wr16(b, seg, off, v)
                    }
                }
                self.t += 10;
            }
            0xA4..=0xA7 | 0xAA..=0xAF => self.string_op(b, op),
            0xA8 => {
                let v = self.fetch8(b) as u16;
                let a = self.r[AX] & 0xFF;
                self.alu(4, a, v, false);
                self.t += 4;
            }
            0xA9 => {
                let v = self.fetch16(b);
                let a = self.r[AX];
                self.alu(4, a, v, true);
                self.t += 4;
            }
            0xB0..=0xB7 => {
                let v = self.fetch8(b);
                self.set_r8((op & 7) as usize, v);
                self.t += 4;
            }
            0xB8..=0xBF => {
                let v = self.fetch16(b);
                self.r[(op & 7) as usize] = v;
                self.t += 4;
            }
            0xC0 | 0xC2 => {
                let n = self.fetch16(b);
                self.ip = self.pop(b);
                self.r[SP] = self.r[SP].wrapping_add(n);
                self.t += 12;
            }
            0xC1 | 0xC3 => {
                self.ip = self.pop(b);
                self.t += 8;
            }
            0xC4 | 0xC5 => {
                self.decode_modrm(b);
                let reg = self.reg_field();
                let (s, o) = (self.ea_seg, self.ea_off);
                let off = self.rd16(b, s, o);
                let seg = self.rd16(b, s, o.wrapping_add(2));
                self.r[reg] = off;
                self.s[if op == 0xC4 { ES } else { DS }] = seg;
                self.t += 16;
            }
            0xC6 => {
                self.decode_modrm(b);
                let v = self.fetch8(b);
                self.set_rm8(b, v);
                self.t += if self.ea_is_reg { 4 } else { 10 };
            }
            0xC7 => {
                self.decode_modrm(b);
                let v = self.fetch16(b);
                self.set_rm16(b, v);
                self.t += if self.ea_is_reg { 4 } else { 10 };
            }
            0xC8 | 0xCA => {
                let n = self.fetch16(b);
                self.ip = self.pop(b);
                self.s[CS] = self.pop(b);
                self.r[SP] = self.r[SP].wrapping_add(n);
                self.t += 17;
            }
            0xC9 | 0xCB => {
                self.ip = self.pop(b);
                self.s[CS] = self.pop(b);
                self.t += 18;
            }
            0xCC => {
                self.pending_int = Some(3);
                self.t += 52;
            }
            0xCD => {
                let v = self.fetch8(b);
                self.pending_int = Some(v);
                self.t += 51;
            }
            0xCE => {
                if self.get_flag(OF) {
                    self.pending_int = Some(4);
                    self.t += 53;
                } else {
                    self.t += 4;
                }
            }
            0xCF => {
                self.ip = self.pop(b);
                self.s[CS] = self.pop(b);
                let f = self.pop(b);
                self.flags = (f & 0x0FD5) | 0xF002;
                self.t += 24;
            }
            0xD0..=0xD3 => {
                self.decode_modrm(b);
                let w = op & 1 != 0;
                let count = if op >= 0xD2 { self.get_r8(1) } else { 1 };
                let sop = self.reg_field() as u8;
                if w {
                    let v = self.rm16(b);
                    let r = self.shift(sop, v, count, true);
                    self.set_rm16(b, r);
                } else {
                    let v = self.rm8(b) as u16;
                    let r = self.shift(sop, v, count, false);
                    self.set_rm8(b, r as u8);
                }
                self.t += match (op >= 0xD2, self.ea_is_reg) {
                    (false, true) => 2,
                    (false, false) => 15,
                    (true, true) => 8 + 4 * count as u32,
                    (true, false) => 20 + 4 * count as u32,
                };
            }
            0xD4 => {
                let base = self.fetch8(b);
                if base == 0 {
                    // releve sur un 8088 : Z = P = 1, les autres drapeaux arithmetiques a 0
                    self.flags = (self.flags & !(CF | PF | AF | ZF | SF | OF)) | ZF | PF;
                    self.pending_int = Some(0);
                } else {
                    let al = self.get_r8(0);
                    self.set_r8(4, al / base);
                    self.set_r8(0, al % base);
                    let v = self.get_r8(0);
                    self.szp8(v);
                }
                self.t += 83;
            }
            0xD5 => {
                let base = self.fetch8(b);
                let al = self.get_r8(0);
                let ah = self.get_r8(4);
                let v = al.wrapping_add(ah.wrapping_mul(base));
                self.r[AX] = v as u16;
                self.szp8(v);
                self.t += 60;
            }
            0xD6 => {
                let v = if self.get_flag(CF) { 0xFF } else { 0 };
                self.set_r8(0, v);
                self.t += 3;
            }
            0xD7 => {
                let seg = self.seg_default(DS);
                let off = self.r[BX].wrapping_add(self.get_r8(0) as u16);
                let v = self.rd8(b, seg, off);
                self.set_r8(0, v);
                self.t += 11;
            }
            0xD8..=0xDF => {
                // ESC (coprocesseur absent) : lit l'operande, sans effet
                self.decode_modrm(b);
                self.t += if self.ea_is_reg { 2 } else { 8 };
            }
            0xE0..=0xE3 => {
                let d = self.fetch8(b) as i8 as i16 as u16;
                let jump = if op == 0xE3 {
                    self.r[CX] == 0
                } else {
                    self.r[CX] = self.r[CX].wrapping_sub(1);
                    let cx = self.r[CX] != 0;
                    match op {
                        0xE0 => cx && !self.get_flag(ZF),
                        0xE1 => cx && self.get_flag(ZF),
                        _ => cx,
                    }
                };
                if jump {
                    self.ip = self.ip.wrapping_add(d);
                }
                self.t += match (op, jump) {
                    (0xE2, true) => 17,
                    (0xE2, false) => 5,
                    (0xE1, true) => 18,
                    (0xE0, true) => 19,
                    (0xE3, true) => 18,
                    (0xE3, false) => 6,
                    (0xE1, false) => 6,
                    _ => 5,
                };
            }
            0xE4..=0xE7 | 0xEC..=0xEF => {
                let port = if op < 0xE8 {
                    self.t += 10;
                    self.fetch8(b) as u16
                } else {
                    self.t += 8;
                    self.r[DX]
                };
                let w = op & 1 != 0;
                if op & 2 == 0 {
                    // IN
                    self.bus_bytes += 1;
                    let lo = b.io_read8(port);
                    if w {
                        self.bus_bytes += 1;
                        self.t += 4;
                        let hi = b.io_read8(port.wrapping_add(1));
                        self.r[AX] = lo as u16 | (hi as u16) << 8;
                    } else {
                        self.set_r8(0, lo);
                    }
                } else {
                    self.bus_bytes += 1;
                    b.io_write8(port, self.r[AX] as u8);
                    if w {
                        self.bus_bytes += 1;
                        self.t += 4;
                        b.io_write8(port.wrapping_add(1), (self.r[AX] >> 8) as u8);
                    }
                }
            }
            0xE8 => {
                let d = self.fetch16(b);
                let ip = self.ip;
                self.push(b, ip);
                self.ip = self.ip.wrapping_add(d);
                self.t += 19;
            }
            0xE9 => {
                let d = self.fetch16(b);
                self.ip = self.ip.wrapping_add(d);
                self.t += 15;
            }
            0xEA => {
                let nip = self.fetch16(b);
                let ncs = self.fetch16(b);
                self.ip = nip;
                self.s[CS] = ncs;
                self.t += 15;
            }
            0xEB => {
                let d = self.fetch8(b) as i8 as i16 as u16;
                self.ip = self.ip.wrapping_add(d);
                self.t += 15;
            }
            0xF4 => {
                self.halted = true;
                self.t += 2;
            }
            0xF5 => {
                self.flags ^= CF;
                self.t += 2;
            }
            0xF6 | 0xF7 => self.group3(b, op & 1 != 0),
            0xF8 => {
                self.set_flag(CF, false);
                self.t += 2
            }
            0xF9 => {
                self.set_flag(CF, true);
                self.t += 2
            }
            0xFA => {
                self.set_flag(IF, false);
                self.t += 2
            }
            0xFB => {
                self.set_flag(IF, true);
                self.inhibit = true;
                self.t += 2
            }
            0xFC => {
                self.set_flag(DF, false);
                self.t += 2
            }
            0xFD => {
                self.set_flag(DF, true);
                self.t += 2
            }
            0xFE => {
                self.decode_modrm(b);
                match self.reg_field() {
                    0 | 1 => {
                        let v = self.rm8(b) as u16;
                        let r = self.inc_dec(v, self.reg_field() == 1, false);
                        self.set_rm8(b, r as u8);
                    }
                    _ => {}
                }
                self.t += if self.ea_is_reg { 3 } else { 15 };
            }
            0xFF => self.group5(b),
            _ => {
                // 0x00-0x3F avec op&7 = 6/7 deja traites ; ne devrait pas arriver
                self.t += 2;
            }
        }
    }

    fn group3<B: Bus>(&mut self, b: &mut B, w: bool) {
        self.decode_modrm(b);
        let sub = self.reg_field();
        let mem = !self.ea_is_reg;
        match sub {
            0 | 1 => {
                let a = if w { self.rm16(b) } else { self.rm8(b) as u16 };
                let v = if w { self.fetch16(b) } else { self.fetch8(b) as u16 };
                self.alu(4, a, v, w);
                self.t += if mem { 11 } else { 5 };
            }
            2 => {
                if w {
                    let v = !self.rm16(b);
                    self.set_rm16(b, v)
                } else {
                    let v = !self.rm8(b);
                    self.set_rm8(b, v)
                }
                self.t += if mem { 16 } else { 3 };
            }
            3 => {
                if w {
                    let v = self.rm16(b);
                    let r = self.alu(5, 0, v, true);
                    self.set_rm16(b, r);
                } else {
                    let v = self.rm8(b) as u16;
                    let r = self.alu(5, 0, v, false);
                    self.set_rm8(b, r as u8);
                }
                self.t += if mem { 16 } else { 3 };
            }
            4 | 5 => {
                // MUL / IMUL
                let signed = sub == 5;
                if w {
                    let v = self.rm16(b);
                    let a = self.r[AX];
                    let (res, ext) = if signed {
                        let p = (a as i16 as i32) * (v as i16 as i32);
                        (p as u32, p != (p as i16 as i32))
                    } else {
                        let p = a as u32 * v as u32;
                        (p, p >> 16 != 0)
                    };
                    self.r[AX] = res as u16;
                    self.r[DX] = (res >> 16) as u16;
                    self.set_flag(CF, ext);
                    self.set_flag(OF, ext);
                    self.t += if signed { 141 } else { 128 };
                } else {
                    let v = self.rm8(b);
                    let a = self.get_r8(0);
                    let (res, ext) = if signed {
                        let p = (a as i8 as i16) * (v as i8 as i16);
                        (p as u16, p != (p as i8 as i16))
                    } else {
                        let p = a as u16 * v as u16;
                        (p, p >> 8 != 0)
                    };
                    self.r[AX] = res;
                    self.set_flag(CF, ext);
                    self.set_flag(OF, ext);
                    self.t += if signed { 89 } else { 74 };
                }
                // drapeaux non definis : le 8088 laisse Z selon le resultat (approximation)
                let hi = if w { self.r[DX] } else { self.r[AX] >> 8 };
                self.set_flag(ZF, hi == 0);
                if mem {
                    self.t += 6;
                }
            }
            _ => {
                // DIV / IDIV
                let signed = sub == 7;
                let mut err = false;
                if w {
                    let d = self.rm16(b);
                    let n = ((self.r[DX] as u32) << 16) | self.r[AX] as u32;
                    if d == 0 {
                        err = true;
                    } else if signed {
                        let n = n as i32;
                        let dd = d as i16 as i32;
                        let mut q = n.wrapping_div(dd);
                        let r = n.wrapping_rem(dd);
                        if !(-32767..=32767).contains(&q) || (n == i32::MIN && dd == -1) {
                            err = true;
                        } else {
                            if self.rep != 0 {
                                q = -q;
                            }
                            self.r[AX] = q as u16;
                            self.r[DX] = r as u16;
                        }
                    } else {
                        let q = n / d as u32;
                        if q > 0xFFFF {
                            err = true;
                        } else {
                            self.r[AX] = q as u16;
                            self.r[DX] = (n % d as u32) as u16;
                        }
                    }
                    self.t += if signed { 174 } else { 153 };
                } else {
                    let d = self.rm8(b);
                    let n = self.r[AX];
                    if d == 0 {
                        err = true;
                    } else if signed {
                        let n = n as i16;
                        let dd = d as i8 as i16;
                        let mut q = n.wrapping_div(dd);
                        let r = n.wrapping_rem(dd);
                        if !(-127..=127).contains(&q) || (n == i16::MIN && dd == -1) {
                            err = true;
                        } else {
                            // 8088 : un prefixe REP inverse le signe du quotient (microcode)
                            if self.rep != 0 {
                                q = -q;
                            }
                            self.r[AX] = (q as u8 as u16) | ((r as u8 as u16) << 8);
                        }
                    } else {
                        let q = n / d as u16;
                        if q > 0xFF {
                            err = true;
                        } else {
                            self.r[AX] = q | ((n % d as u16) << 8);
                        }
                    }
                    self.t += if signed { 107 } else { 85 };
                }
                if mem {
                    self.t += 6;
                }
                if err {
                    self.pending_int = Some(0);
                }
            }
        }
    }

    fn group5<B: Bus>(&mut self, b: &mut B) {
        self.decode_modrm(b);
        let sub = self.reg_field();
        let mem = !self.ea_is_reg;
        match sub {
            0 | 1 => {
                let v = self.rm16(b);
                let r = self.inc_dec(v, sub == 1, true);
                self.set_rm16(b, r);
                self.t += if mem { 15 } else { 2 };
            }
            2 => {
                let v = self.rm16(b);
                let ip = self.ip;
                self.push(b, ip);
                self.ip = v;
                self.t += if mem { 21 } else { 16 };
            }
            3 => {
                let (s, o) = (self.ea_seg, self.ea_off);
                let nip = self.rd16(b, s, o);
                let ncs = self.rd16(b, s, o.wrapping_add(2));
                let cs = self.s[CS];
                self.push(b, cs);
                let ip = self.ip;
                self.push(b, ip);
                self.ip = nip;
                self.s[CS] = ncs;
                self.t += 37;
            }
            4 => {
                self.ip = self.rm16(b);
                self.t += if mem { 18 } else { 11 };
            }
            5 => {
                let (s, o) = (self.ea_seg, self.ea_off);
                let nip = self.rd16(b, s, o);
                let ncs = self.rd16(b, s, o.wrapping_add(2));
                self.ip = nip;
                self.s[CS] = ncs;
                self.t += 24;
            }
            _ => {
                let v = self.rm16(b);
                if self.ea_is_reg && self.rm_field() == SP {
                    self.r[SP] = self.r[SP].wrapping_sub(2);
                    let sp = self.r[SP];
                    self.wr16(b, SS, sp, sp);
                } else {
                    self.push(b, v);
                }
                self.t += if mem { 16 } else { 11 };
            }
        }
    }

    /// Instructions de chaine ; une iteration par appel si REP (IP ramene au debut).
    fn string_op<B: Bus>(&mut self, b: &mut B, op: u8) {
        let w = op & 1 != 0;
        let delta: u16 = match (w, self.get_flag(DF)) {
            (false, false) => 1,
            (false, true) => 0xFFFF,
            (true, false) => 2,
            (true, true) => 0xFFFE,
        };
        if self.rep != 0 {
            if self.r[CX] == 0 {
                self.t += 9;
                return;
            }
        }
        let src = self.seg_default(DS);
        let si = self.r[SI];
        let di = self.r[DI];
        let mut cmp_flag_stop = false;
        match op & 0xFE {
            0xA4 => {
                if w {
                    let v = self.rd16(b, src, si);
                    self.wr16(b, ES, di, v);
                } else {
                    let v = self.rd8(b, src, si);
                    self.wr8(b, ES, di, v);
                }
                self.r[SI] = si.wrapping_add(delta);
                self.r[DI] = di.wrapping_add(delta);
                self.t += if self.rep != 0 { 17 } else { 18 };
            }
            0xA6 => {
                if w {
                    let a = self.rd16(b, src, si);
                    let c = self.rd16(b, ES, di);
                    self.alu(7, a, c, true);
                } else {
                    let a = self.rd8(b, src, si) as u16;
                    let c = self.rd8(b, ES, di) as u16;
                    self.alu(7, a, c, false);
                }
                self.r[SI] = si.wrapping_add(delta);
                self.r[DI] = di.wrapping_add(delta);
                cmp_flag_stop = true;
                self.t += 22;
            }
            0xAA => {
                if w {
                    let v = self.r[AX];
                    self.wr16(b, ES, di, v);
                } else {
                    let v = self.get_r8(0);
                    self.wr8(b, ES, di, v);
                }
                self.r[DI] = di.wrapping_add(delta);
                self.t += if self.rep != 0 { 10 } else { 11 };
            }
            0xAC => {
                if w {
                    self.r[AX] = self.rd16(b, src, si);
                } else {
                    let v = self.rd8(b, src, si);
                    self.set_r8(0, v);
                }
                self.r[SI] = si.wrapping_add(delta);
                self.t += if self.rep != 0 { 13 } else { 12 };
            }
            _ => {
                // AE SCAS
                if w {
                    let c = self.rd16(b, ES, di);
                    let a = self.r[AX];
                    self.alu(7, a, c, true);
                } else {
                    let c = self.rd8(b, ES, di) as u16;
                    let a = self.r[AX] & 0xFF;
                    self.alu(7, a, c, false);
                }
                self.r[DI] = di.wrapping_add(delta);
                cmp_flag_stop = true;
                self.t += 15;
            }
        }
        if self.rep != 0 {
            self.r[CX] = self.r[CX].wrapping_sub(1);
            let mut done = self.r[CX] == 0;
            if cmp_flag_stop {
                let z = self.get_flag(ZF);
                if (self.rep == 2 && !z) || (self.rep == 1 && z) {
                    done = true;
                }
            }
            if !done {
                // iteration suivante : l'instruction (prefixes compris) est reprise ;
                // une interruption peut etre servie entre deux iterations, comme sur le 8088.
                self.ip = self.start_ip;
                // pas de recherche des octets de prefixe au tour suivant (deja dans la file)
                self.bus_bytes = self.bus_bytes.saturating_sub(1);
            }
        }
    }
}
