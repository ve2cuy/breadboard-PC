//! Carte SD (J9) sur le SPI bit par bit de U12 : PC4 = CS, PC5 = SCK, PC6 = MOSI, PB3 = MISO
//! (mode 0 : la carte lit MOSI au front montant de SCK et change MISO au front descendant).
//! Carte SDHC : CMD0, 8, 9, 12, 13, 16, 17, 24, 55, 58, ACMD41.
//! Contenu creux : secteurs ecrits + fichiers d'un seul tenant (images .IMG), en FAT32.

use std::collections::{HashMap, VecDeque};
use std::rc::Rc;

pub const SECT: usize = 512;

#[derive(Clone)]
pub struct SdFile {
    pub name: String,
    pub lba: u32,
    pub size: u32,
    pub data: Rc<Vec<u8>>,
}

#[derive(Clone)]
pub struct Disk {
    pub nsec: u32,
    map: HashMap<u32, Rc<Vec<u8>>>,
    pub files: Vec<SdFile>,
    pub dirty: HashMap<u32, bool>,
}

impl Disk {
    pub fn empty(nsec: u32) -> Self {
        Disk { nsec, map: HashMap::new(), files: Vec::new(), dirty: HashMap::new() }
    }

    /// Image brute d'une carte entiere.
    pub fn from_raw(data: Vec<u8>) -> Self {
        let nsec = (data.len() / SECT) as u32;
        let mut d = Disk::empty(nsec.max(1));
        let rc = Rc::new(data);
        d.files.push(SdFile { name: String::from("<carte>"), lba: 0, size: rc.len() as u32, data: rc });
        d
    }

    pub fn read(&self, lba: u32) -> Vec<u8> {
        if let Some(s) = self.map.get(&lba) {
            return s.as_ref().clone();
        }
        for f in &self.files {
            let n = (f.size as usize).div_ceil(SECT) as u32;
            if lba >= f.lba && lba < f.lba + n {
                let off = (lba - f.lba) as usize * SECT;
                let mut v = vec![0u8; SECT];
                let end = (off + SECT).min(f.data.len());
                v[..end - off].copy_from_slice(&f.data[off..end]);
                return v;
            }
        }
        vec![0u8; SECT]
    }

    pub fn write(&mut self, lba: u32, d: &[u8]) {
        self.map.insert(lba, Rc::new(d.to_vec()));
        self.dirty.insert(lba, true);
    }

    fn put(&mut self, lba: u32, d: Vec<u8>) {
        self.map.insert(lba, Rc::new(d));
    }

    /// Contenu actuel d'un fichier (avec les secteurs reecrits par le 8088).
    pub fn file_bytes(&self, i: usize) -> Vec<u8> {
        let f = &self.files[i];
        let n = (f.size as usize).div_ceil(SECT);
        let mut out = Vec::with_capacity(n * SECT);
        for k in 0..n as u32 {
            out.extend_from_slice(&self.read(f.lba + k));
        }
        out.truncate(f.size as usize);
        out
    }

    /// Le fichier i a-t-il ete modifie ?
    pub fn file_dirty(&self, i: usize) -> bool {
        let f = &self.files[i];
        let n = (f.size as usize).div_ceil(SECT) as u32;
        self.dirty.keys().any(|&l| l >= f.lba && l < f.lba + n)
    }
}

fn name83(name: &str) -> [u8; 11] {
    let up = name.to_ascii_uppercase();
    let (base, ext) = match up.rfind('.') {
        Some(p) => (&up[..p], &up[p + 1..]),
        None => (&up[..], ""),
    };
    let mut out = [b' '; 11];
    for (i, c) in base.bytes().filter(|c| c.is_ascii_graphic() && *c != b'.').take(8).enumerate() {
        out[i] = c;
    }
    for (i, c) in ext.bytes().filter(|c| c.is_ascii_graphic()).take(3).enumerate() {
        out[8 + i] = c;
    }
    out
}

fn dir_entry(n83: &[u8; 11], attr: u8, cluster: u32, size: u32) -> [u8; 32] {
    let mut e = [0u8; 32];
    e[..11].copy_from_slice(n83);
    e[11] = attr;
    e[20..22].copy_from_slice(&((cluster >> 16) as u16).to_le_bytes());
    e[22..24].copy_from_slice(&0x6000u16.to_le_bytes()); // 12:00
    e[24..26].copy_from_slice(&0x5B71u16.to_le_bytes()); // 2025-11-17
    e[26..28].copy_from_slice(&(cluster as u16).to_le_bytes());
    e[28..32].copy_from_slice(&size.to_le_bytes());
    e
}

/// Carte SDHC formatee en FAT32 (MBR + 1 partition, amas de 32 Ko), fichiers d'un seul
/// tenant a la racine, comme une carte fraichement formatee sous Windows.
pub fn build_fat32(files: &[(String, Rc<Vec<u8>>)]) -> Disk {
    const SPC: u32 = 64;
    const PART: u32 = 2048;
    const RES: u32 = 32;
    let need: u64 = files.iter().map(|(_, d)| (d.len() as u64).div_ceil(SPC as u64 * 512) * SPC as u64).sum();
    // au moins 4 Go (65525 amas au minimum pour du FAT32)
    let mut total: u32 = 8 * 1024 * 1024;
    while (total as u64) < need + 300_000 {
        total *= 2;
    }
    let part_size = total - PART;
    let mut fatsz = 1u32;
    let clusters = loop {
        let c = (part_size - RES - 2 * fatsz) / SPC;
        if (c + 2) * 4 <= fatsz * 512 {
            break c;
        }
        fatsz += 1;
    };
    let _ = clusters;
    let mut d = Disk::empty(total);
    let mut mbr = vec![0u8; SECT];
    mbr[0x1BE] = 0x00;
    mbr[0x1BE + 4] = 0x0C;
    mbr[0x1BE + 1..0x1BE + 4].copy_from_slice(&[0xFE, 0xFF, 0xFF]);
    mbr[0x1BE + 5..0x1BE + 8].copy_from_slice(&[0xFE, 0xFF, 0xFF]);
    mbr[0x1BE + 8..0x1BE + 12].copy_from_slice(&PART.to_le_bytes());
    mbr[0x1BE + 12..0x1BE + 16].copy_from_slice(&part_size.to_le_bytes());
    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    d.put(0, mbr);
    let mut bpb = vec![0u8; SECT];
    bpb[0..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
    bpb[3..11].copy_from_slice(b"MSWIN4.1");
    bpb[11..13].copy_from_slice(&512u16.to_le_bytes());
    bpb[13] = SPC as u8;
    bpb[14..16].copy_from_slice(&(RES as u16).to_le_bytes());
    bpb[16] = 2;
    bpb[21] = 0xF8;
    bpb[24..26].copy_from_slice(&63u16.to_le_bytes());
    bpb[26..28].copy_from_slice(&255u16.to_le_bytes());
    bpb[28..32].copy_from_slice(&PART.to_le_bytes());
    bpb[32..36].copy_from_slice(&part_size.to_le_bytes());
    bpb[36..40].copy_from_slice(&fatsz.to_le_bytes());
    bpb[44..48].copy_from_slice(&2u32.to_le_bytes());
    bpb[48..50].copy_from_slice(&1u16.to_le_bytes());
    bpb[50..52].copy_from_slice(&6u16.to_le_bytes());
    bpb[0x40] = 0x80;
    bpb[0x42] = 0x29;
    bpb[0x43..0x47].copy_from_slice(&0x5302_2026u32.to_le_bytes());
    bpb[0x47..0x52].copy_from_slice(b"SOLUTION02 ");
    bpb[0x52..0x5A].copy_from_slice(b"FAT32   ");
    bpb[510] = 0x55;
    bpb[511] = 0xAA;
    d.put(PART, bpb);
    // FSInfo
    let mut fsi = vec![0u8; SECT];
    fsi[0..4].copy_from_slice(&0x4161_5252u32.to_le_bytes());
    fsi[484..488].copy_from_slice(&0x6141_7272u32.to_le_bytes());
    fsi[488..492].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
    fsi[492..496].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
    fsi[510] = 0x55;
    fsi[511] = 0xAA;
    d.put(PART + 1, fsi);

    let fat_lba = PART + RES;
    let data_lba = fat_lba + 2 * fatsz;
    let mut fat: Vec<(u32, u32)> = vec![(0, 0x0FFF_FFF8), (1, 0x0FFF_FFFF), (2, 0x0FFF_FFFF)];
    let mut entries: Vec<[u8; 32]> = vec![dir_entry(b"SOLUTION02 ", 0x08, 0, 0)];
    let mut next = 3u32;
    for (name, data) in files {
        let n = ((data.len() as u64).div_ceil(SPC as u64 * 512)).max(1) as u32;
        let first = next;
        for c in first..first + n {
            fat.push((c, if c + 1 < first + n { c + 1 } else { 0x0FFF_FFFF }));
        }
        next += n;
        let lba = data_lba + (first - 2) * SPC;
        entries.push(dir_entry(&name83(name), 0x20, first, data.len() as u32));
        d.files.push(SdFile { name: name.clone(), lba, size: data.len() as u32, data: data.clone() });
    }
    // racine (amas 2)
    let mut root = vec![0u8; (SPC as usize) * SECT];
    for (i, e) in entries.iter().enumerate().take(SPC as usize * 16) {
        root[i * 32..i * 32 + 32].copy_from_slice(e);
    }
    for j in 0..SPC {
        let s = &root[j as usize * SECT..(j as usize + 1) * SECT];
        if s.iter().any(|&b| b != 0) {
            d.put(data_lba + j, s.to_vec());
        }
    }
    // deux copies de la FAT
    let mut secs: HashMap<u32, Vec<u8>> = HashMap::new();
    for copy in 0..2 {
        for &(c, v) in &fat {
            let lba = fat_lba + copy * fatsz + c * 4 / 512;
            let s = secs.entry(lba).or_insert_with(|| vec![0u8; SECT]);
            let o = (c * 4 % 512) as usize;
            s[o..o + 4].copy_from_slice(&v.to_le_bytes());
        }
    }
    for (lba, s) in secs {
        d.put(lba, s);
    }
    d
}

#[derive(Clone)]
enum WriteState {
    None,
    Token(u32),
    Data(u32, Vec<u8>),
}

#[derive(Clone)]
pub struct SdCard {
    pub disk: Option<Disk>,
    cs: bool,
    sck: bool,
    k: u8,
    inp: u8,
    cur: u8,
    out: VecDeque<u8>,
    cmd: Vec<u8>,
    idle: bool,
    app: bool,
    acmd41_tries: u32,
    wr: WriteState,
    pub reads: u64,
    pub writes: u64,
    pub last_lba: u32,
    pub last_cmd: u8,
    pub log: Vec<String>,
}

impl SdCard {
    pub fn new() -> Self {
        SdCard {
            disk: None,
            cs: true,
            sck: false,
            k: 8,
            inp: 0,
            cur: 0xFF,
            out: VecDeque::new(),
            cmd: Vec::new(),
            idle: true,
            app: false,
            acmd41_tries: 0,
            wr: WriteState::None,
            reads: 0,
            writes: 0,
            last_lba: 0,
            last_cmd: 0,
            log: Vec::new(),
        }
    }

    pub fn insert(&mut self, d: Disk) {
        *self = SdCard { disk: Some(d), ..SdCard::new() };
    }
    pub fn eject(&mut self) -> Option<Disk> {
        let d = self.disk.take();
        *self = SdCard::new();
        d
    }
    pub fn present(&self) -> bool {
        self.disk.is_some()
    }

    /// Niveaux de PC4 (CS), PC5 (SCK), PC6 (MOSI).
    pub fn port_c(&mut self, v: u8) {
        let cs = v & 0x10 != 0;
        let sck = v & 0x20 != 0;
        let mosi = (v >> 6) & 1;
        if cs != self.cs {
            self.k = 8;
        }
        if !cs && sck && !self.sck && self.present() {
            if self.k == 8 {
                self.k = 0;
                self.cur = self.out.pop_front().unwrap_or(0xFF);
            }
            self.inp = (self.inp << 1) | mosi;
            self.k += 1;
            if self.k == 8 {
                let b = self.inp;
                self.byte(b);
            }
        }
        self.cs = cs;
        self.sck = sck;
    }

    pub fn miso(&self) -> bool {
        if self.cs || !self.present() {
            return true; // tirage R9
        }
        let i: i32 = if self.sck { self.k as i32 - 1 } else { self.k as i32 };
        if (0..8).contains(&i) {
            (self.cur >> (7 - i)) & 1 != 0
        } else {
            true
        }
    }

    fn byte(&mut self, b: u8) {
        match std::mem::replace(&mut self.wr, WriteState::None) {
            WriteState::Token(lba) => {
                self.wr = if b == 0xFE { WriteState::Data(lba, Vec::with_capacity(514)) } else { WriteState::Token(lba) };
                return;
            }
            WriteState::Data(lba, mut d) => {
                d.push(b);
                if d.len() == 514 {
                    if let Some(disk) = &mut self.disk {
                        disk.write(lba, &d[..512]);
                    }
                    self.writes += 1;
                    self.last_lba = lba;
                    self.out = VecDeque::from(vec![0x05, 0x00, 0x00, 0x00]);
                } else {
                    self.wr = WriteState::Data(lba, d);
                }
                return;
            }
            WriteState::None => {}
        }
        if self.cmd.is_empty() && (b & 0xC0) != 0x40 {
            return;
        }
        self.cmd.push(b);
        if self.cmd.len() < 6 {
            return;
        }
        let c = self.cmd[0] & 0x3F;
        let arg = u32::from_be_bytes([self.cmd[1], self.cmd[2], self.cmd[3], self.cmd[4]]);
        self.cmd.clear();
        self.last_cmd = c;
        let r1: u8 = if self.idle { 0x01 } else { 0x00 };
        let app = self.app;
        self.app = false;
        let nsec = self.disk.as_ref().map(|d| d.nsec).unwrap_or(0);
        let rep: Vec<u8> = match c {
            0 => {
                self.idle = true;
                self.acmd41_tries = 0;
                vec![0x01]
            }
            8 => vec![r1, 0x00, 0x00, 0x01, arg as u8],
            55 => {
                self.app = true;
                vec![r1]
            }
            41 if app => {
                self.acmd41_tries += 1;
                if self.acmd41_tries >= 3 {
                    self.idle = false;
                }
                vec![if self.idle { 0x01 } else { 0x00 }]
            }
            58 => vec![r1, 0xC0, 0xFF, 0x80, 0x00],
            9 => {
                let csize = nsec / 1024 - 1;
                let mut csd = [0u8; 16];
                csd[0] = 0x40;
                csd[7] = ((csize >> 16) & 0x3F) as u8;
                csd[8] = (csize >> 8) as u8;
                csd[9] = csize as u8;
                let mut v = vec![0x00, 0xFF, 0xFE];
                v.extend_from_slice(&csd);
                v.extend_from_slice(&[0xFF, 0xFF]);
                v
            }
            12 => vec![0xFF, r1],
            13 => vec![r1, 0x00],
            16 => vec![r1],
            17 => {
                if arg >= nsec {
                    vec![0x20]
                } else {
                    self.reads += 1;
                    self.last_lba = arg;
                    let mut v = vec![0x00, 0xFF, 0xFF, 0xFE];
                    v.extend_from_slice(&self.disk.as_ref().unwrap().read(arg));
                    v.extend_from_slice(&[0xFF, 0xFF]);
                    v
                }
            }
            24 => {
                if arg >= nsec {
                    vec![0x20]
                } else {
                    self.wr = WriteState::Token(arg);
                    vec![0x00]
                }
            }
            _ => {
                if self.log.len() < 10 {
                    self.log.push(format!("SD : commande CMD{} non geree", c));
                }
                vec![r1 | 0x04]
            }
        };
        self.out.clear();
        self.out.push_back(0xFF);
        self.out.extend(rep);
    }
}

impl Default for SdCard {
    fn default() -> Self {
        Self::new()
    }
}
