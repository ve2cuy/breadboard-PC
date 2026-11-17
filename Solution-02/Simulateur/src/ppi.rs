//! 8255A / uPD71055C en mode 0 (le seul utilise par le BIOS) et commandes BSR.
//! Le mot de mode remet toutes les sorties a 0 ; RESET met les trois ports en entree.

#[derive(Clone)]
pub struct Ppi {
    pub ctrl: u8,
    /// Verrous de sortie A, B, C.
    pub out: [u8; 3],
    pub writes: u64,
    pub log: Vec<String>,
    pub name: &'static str,
}

impl Ppi {
    pub fn new(name: &'static str) -> Self {
        Ppi { ctrl: 0x9B, out: [0; 3], writes: 0, log: Vec::new(), name }
    }

    pub fn reset(&mut self) {
        self.ctrl = 0x9B; // mode 0, tout en entree
        self.out = [0; 3];
    }

    pub fn a_input(&self) -> bool {
        self.ctrl & 0x10 != 0
    }
    pub fn b_input(&self) -> bool {
        self.ctrl & 0x02 != 0
    }
    pub fn cu_input(&self) -> bool {
        self.ctrl & 0x08 != 0
    }
    pub fn cl_input(&self) -> bool {
        self.ctrl & 0x01 != 0
    }

    /// Masque des broches de sortie de chaque port.
    pub fn out_mask(&self) -> [u8; 3] {
        [
            if self.a_input() { 0 } else { 0xFF },
            if self.b_input() { 0 } else { 0xFF },
            (if self.cu_input() { 0 } else { 0xF0 }) | (if self.cl_input() { 0 } else { 0x0F }),
        ]
    }

    /// Niveau des broches cote circuit : sortie = verrou, entree = valeur externe.
    pub fn pins(&self, ext: [u8; 3]) -> [u8; 3] {
        let m = self.out_mask();
        [
            (self.out[0] & m[0]) | (ext[0] & !m[0]),
            (self.out[1] & m[1]) | (ext[1] & !m[1]),
            (self.out[2] & m[2]) | (ext[2] & !m[2]),
        ]
    }

    pub fn write(&mut self, a: u8, v: u8) {
        self.writes += 1;
        match a & 3 {
            3 => {
                if v & 0x80 != 0 {
                    if v & 0x64 != 0 && self.log.len() < 10 {
                        self.log.push(format!("{} : mot de mode {:02X}h (modes 1/2 non simules)", self.name, v));
                    }
                    self.ctrl = v;
                    self.out = [0; 3];
                } else {
                    let bit = (v >> 1) & 7;
                    if v & 1 != 0 {
                        self.out[2] |= 1 << bit
                    } else {
                        self.out[2] &= !(1 << bit)
                    }
                }
            }
            i => self.out[i as usize] = v,
        }
    }

    /// Lecture : ports en entree = valeur externe ; en sortie = verrou.
    pub fn read(&self, a: u8, ext: [u8; 3]) -> u8 {
        match a & 3 {
            3 => 0xFF, // le mot de controle n'est pas lisible sur le 8255A
            i => self.pins(ext)[i as usize],
        }
    }
}
