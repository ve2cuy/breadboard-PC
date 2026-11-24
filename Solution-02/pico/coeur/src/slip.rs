//! SLIP (RFC 1055) : les paquets IP du 8088 passent par le flux d'octets du port 50h, comme
//! avec le module Grove (les pilotes S02PKT et ttyS1 d'ELKS restent les memes).

use alloc::collections::VecDeque;
use alloc::vec::Vec;

pub const END: u8 = 0xC0;
pub const ESC: u8 = 0xDB;
pub const ESC_END: u8 = 0xDC;
pub const ESC_ESC: u8 = 0xDD;

/// Paquet le plus long accepte (au-dela : paquet abandonne).
pub const MAX: usize = 2048;

/// Code un paquet : END, octets echappes, END.
pub fn coder(p: &[u8], sortie: &mut VecDeque<u8>) {
    sortie.push_back(END);
    for &b in p {
        match b {
            END => sortie.extend([ESC, ESC_END]),
            ESC => sortie.extend([ESC, ESC_ESC]),
            _ => sortie.push_back(b),
        }
    }
    sortie.push_back(END);
}

#[derive(Default)]
pub struct Decodeur {
    trame: Vec<u8>,
    esc: bool,
    trop_long: bool,
}

impl Decodeur {
    pub fn new() -> Self {
        Self::default()
    }

    /// Un octet ; rend un paquet complet a la fin d'une trame non vide.
    pub fn octet(&mut self, b: u8) -> Option<Vec<u8>> {
        if self.esc {
            self.esc = false;
            let v = match b {
                ESC_END => END,
                ESC_ESC => ESC,
                x => x,
            };
            self.pousser(v);
            return None;
        }
        match b {
            ESC => self.esc = true,
            END => {
                let trop = core::mem::replace(&mut self.trop_long, false);
                if !self.trame.is_empty() && !trop {
                    return Some(core::mem::take(&mut self.trame));
                }
                self.trame.clear();
            }
            _ => self.pousser(b),
        }
        None
    }

    fn pousser(&mut self, b: u8) {
        if self.trame.len() < MAX {
            self.trame.push(b);
        } else {
            self.trop_long = true;
        }
    }
}
