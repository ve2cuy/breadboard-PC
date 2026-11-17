//! 8259A (U13), ports 20h-21h, maitre unique, mode 8086.
//! Mode front (choisi par le BIOS) : une demande est memorisee au front montant de IR mais
//! n'est valable que si IR est encore haute ; INT, une fois levee, reste haute jusqu'a INTA ;
//! si plus aucune demande n'est valable a INTA, le 8259 donne le vecteur de IR7 (parasite).

#[derive(Clone)]
pub struct Pic {
    pub init: bool,
    step: u8,
    need_icw4: bool,
    single: bool,
    pub level: bool,
    pub aeoi: bool,
    pub base: u8,
    pub imr: u8,
    pub isr: u8,
    /// Fronts memorises (IRR en mode front).
    pub edge: u8,
    /// Niveaux actuels des entrees IR0-IR7.
    pub ir: u8,
    pub int_out: bool,
    read_isr: bool,
    poll: bool,
    pub served: [u64; 8],
    pub spurious: u64,
    pub log: Vec<String>,
}

impl Pic {
    pub fn new() -> Self {
        Pic {
            init: false,
            step: 0,
            need_icw4: false,
            single: true,
            level: false,
            aeoi: false,
            base: 0,
            imr: 0xFF,
            isr: 0,
            edge: 0,
            ir: 0,
            int_out: false,
            read_isr: false,
            poll: false,
            served: [0; 8],
            spurious: 0,
            log: Vec::new(),
        }
    }

    pub fn irr(&self) -> u8 {
        if self.level {
            self.ir
        } else {
            self.edge & self.ir
        }
    }

    pub fn write(&mut self, a0: bool, v: u8) {
        if !a0 {
            if v & 0x10 != 0 {
                // ICW1
                self.step = 1;
                self.need_icw4 = v & 1 != 0;
                self.single = v & 2 != 0;
                self.level = v & 8 != 0;
                self.init = false;
                self.imr = 0;
                self.isr = 0;
                self.edge = 0;
                self.int_out = false;
                self.read_isr = false;
                self.aeoi = false;
            } else if v & 0x08 != 0 {
                // OCW3
                if v & 0x04 != 0 {
                    self.poll = true;
                }
                if v & 0x02 != 0 {
                    self.read_isr = v & 1 != 0;
                }
            } else {
                // OCW2
                match v & 0xE0 {
                    0x20 | 0xA0 => {
                        if self.isr != 0 {
                            self.isr &= self.isr - 1; // la plus prioritaire servie
                        }
                    }
                    0x60 | 0xE0 => self.isr &= !(1 << (v & 7)),
                    _ => {}
                }
                self.update();
            }
        } else {
            match self.step {
                1 => {
                    self.base = v & 0xF8;
                    self.step = if !self.single {
                        2
                    } else if self.need_icw4 {
                        3
                    } else {
                        0
                    };
                    if self.step == 0 {
                        self.init = true;
                    }
                }
                2 => {
                    self.step = if self.need_icw4 { 3 } else { 0 };
                    if self.step == 0 {
                        self.init = true;
                    }
                }
                3 => {
                    self.aeoi = v & 2 != 0;
                    if v & 1 == 0 && self.log.len() < 10 {
                        self.log.push(format!("8259 : ICW4 {:02X}h = mode 8080 (8086 attendu)", v));
                    }
                    self.step = 0;
                    self.init = true;
                }
                _ => {
                    self.imr = v;
                    self.update();
                }
            }
        }
    }

    pub fn read(&mut self, a0: bool) -> u8 {
        if self.poll {
            self.poll = false;
            return match self.request() {
                Some(irq) => {
                    self.isr |= 1 << irq;
                    self.edge &= !(1 << irq);
                    self.update();
                    0x80 | irq
                }
                None => 0,
            };
        }
        if a0 {
            self.imr
        } else if self.read_isr {
            self.isr
        } else {
            self.irr()
        }
    }

    /// Nouveaux niveaux des entrees IR (bit n = IRn).
    pub fn set_inputs(&mut self, lv: u8) {
        self.edge |= lv & !self.ir;
        self.ir = lv;
        self.update();
    }

    fn request(&self) -> Option<u8> {
        if !self.init {
            return None;
        }
        let req = self.irr() & !self.imr;
        if req == 0 {
            return None;
        }
        let irq = req.trailing_zeros() as u8;
        if self.isr != 0 && (self.isr.trailing_zeros() as u8) <= irq {
            return None;
        }
        Some(irq)
    }

    fn update(&mut self) {
        if self.request().is_some() {
            self.int_out = true;
        }
    }

    /// Cycle INTA du 8088 : rend le vecteur.
    pub fn inta(&mut self) -> u8 {
        self.int_out = false;
        let v = match self.request() {
            None => {
                self.spurious += 1;
                self.base + 7
            }
            Some(irq) => {
                if !self.aeoi {
                    self.isr |= 1 << irq;
                }
                self.edge &= !(1 << irq);
                self.served[irq as usize] += 1;
                self.base + irq
            }
        };
        self.update();
        v
    }
}

impl Default for Pic {
    fn default() -> Self {
        Self::new()
    }
}
