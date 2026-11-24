//! Carte microSD de J14 sur SPI0 (GP16 MISO, GP17 CS, GP18 SCK, GP19 MOSI), mode SPI 0.
//! SD v1 (SDSC, adresse en octets), SD v2 SDSC et SDHC/SDXC (adresse en blocs).
//! Initialisation a 400 kHz, puis 12,5 MHz.

use embassy_rp::gpio::Output;
use embassy_rp::peripherals::SPI0;
use embassy_rp::spi::{Blocking, Spi};
use embassy_time::{Duration, Instant};
use s02pico_coeur::{Carte, SECTEUR};

pub struct CarteSd<'d> {
    spi: Spi<'d, SPI0, Blocking>,
    cs: Output<'d>,
    /// adresses en blocs (SDHC)
    blocs: bool,
}

impl<'d> CarteSd<'d> {
    pub fn new(spi: Spi<'d, SPI0, Blocking>, cs: Output<'d>) -> Self {
        CarteSd { spi, cs, blocs: false }
    }

    fn octet(&mut self, b: u8) -> u8 {
        let mut d = [b];
        let _ = self.spi.blocking_transfer_in_place(&mut d);
        d[0]
    }

    fn libere(&mut self) {
        self.cs.set_high();
        self.octet(0xFF);
    }

    /// Commande : R1 (FFh si pas de reponse).
    fn cmd(&mut self, n: u8, arg: u32, crc: u8) -> u8 {
        self.cs.set_low();
        self.octet(0xFF);
        self.octet(0x40 | n);
        for b in arg.to_be_bytes() {
            self.octet(b);
        }
        self.octet(crc);
        for _ in 0..10 {
            let r = self.octet(0xFF);
            if r & 0x80 == 0 {
                return r;
            }
        }
        0xFF
    }

    fn attente_jeton(&mut self) -> bool {
        let t = Instant::now();
        while t.elapsed() < Duration::from_millis(300) {
            match self.octet(0xFF) {
                0xFE => return true,
                0xFF => {}
                _ => return false,
            }
        }
        false
    }

    fn capacite(&mut self) -> Option<u32> {
        if self.cmd(9, 0, 0xFF) != 0 || !self.attente_jeton() {
            self.libere();
            return None;
        }
        let mut csd = [0xFFu8; 16];
        let _ = self.spi.blocking_transfer_in_place(&mut csd);
        self.octet(0xFF);
        self.octet(0xFF);
        self.libere();
        if csd[0] >> 6 == 1 {
            let c = ((csd[7] as u32 & 0x3F) << 16) | (csd[8] as u32) << 8 | csd[9] as u32;
            Some((c + 1) * 1024)
        } else {
            let c = ((csd[6] as u32 & 3) << 10) | (csd[7] as u32) << 2 | (csd[8] as u32) >> 6;
            let mult = ((csd[9] as u32 & 3) << 1) | (csd[10] as u32) >> 7;
            let bl = csd[5] as u32 & 0x0F;
            Some(((c + 1) << (mult + 2 + bl)) / 512)
        }
    }
}

impl Carte for CarteSd<'_> {
    fn init(&mut self) -> Option<u32> {
        self.spi.set_frequency(400_000);
        self.cs.set_high();
        for _ in 0..10 {
            self.octet(0xFF);
        }
        let mut ok = false;
        for _ in 0..10 {
            if self.cmd(0, 0, 0x95) == 1 {
                ok = true;
                break;
            }
            self.libere();
        }
        self.libere();
        if !ok {
            return None;
        }
        let v2 = self.cmd(8, 0x1AA, 0x87) == 1;
        if v2 {
            let mut r = [0xFFu8; 4];
            let _ = self.spi.blocking_transfer_in_place(&mut r);
            if r[2] & 0x0F != 1 || r[3] != 0xAA {
                self.libere();
                return None;
            }
        }
        self.libere();
        let t = Instant::now();
        loop {
            self.cmd(55, 0, 0xFF);
            self.libere();
            let r = self.cmd(41, if v2 { 0x4000_0000 } else { 0 }, 0xFF);
            self.libere();
            if r == 0 {
                break;
            }
            if t.elapsed() > Duration::from_secs(2) {
                return None;
            }
        }
        self.blocs = false;
        if v2 && self.cmd(58, 0, 0xFF) == 0 {
            let mut ocr = [0xFFu8; 4];
            let _ = self.spi.blocking_transfer_in_place(&mut ocr);
            self.blocs = ocr[0] & 0x40 != 0;
        }
        self.libere();
        if !self.blocs {
            self.cmd(16, 512, 0xFF);
            self.libere();
        }
        self.spi.set_frequency(12_500_000);
        self.capacite()
    }

    fn lire(&mut self, lba: u32, d: &mut [u8; SECTEUR]) -> bool {
        let a = if self.blocs { lba } else { lba.wrapping_mul(512) };
        if self.cmd(17, a, 0xFF) != 0 || !self.attente_jeton() {
            self.libere();
            return false;
        }
        d.fill(0xFF);
        let _ = self.spi.blocking_transfer_in_place(d);
        self.octet(0xFF);
        self.octet(0xFF);
        self.libere();
        true
    }

    fn ecrire(&mut self, lba: u32, d: &[u8; SECTEUR]) -> bool {
        let a = if self.blocs { lba } else { lba.wrapping_mul(512) };
        if self.cmd(24, a, 0xFF) != 0 {
            self.libere();
            return false;
        }
        self.octet(0xFF);
        self.octet(0xFE);
        let _ = self.spi.blocking_write(d);
        self.octet(0xFF);
        self.octet(0xFF);
        let r = self.octet(0xFF);
        if r & 0x1F != 0x05 {
            self.libere();
            return false;
        }
        let t = Instant::now();
        while self.octet(0xFF) == 0 {
            if t.elapsed() > Duration::from_millis(500) {
                self.libere();
                return false;
            }
        }
        self.libere();
        true
    }
}
