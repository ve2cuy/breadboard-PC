//! Validation du processeur avec la suite publique SingleStepTests/8088 (v1) :
//! https://github.com/SingleStepTests/8088 — environ 10 000 cas par opcode, releves sur un vrai 8088.
//!
//!   SST_DIR=chemin/vers/v1  cargo test --release --test sst -- --nocapture
//!
//! Le dossier contient les fichiers xx.json.gz (ou xx.y.json.gz) et metadata.json (masques des
//! drapeaux non definis). Sans SST_DIR, l'essai est saute. Les durees (cycles) ne sont pas comparees.

use flate2::read::GzDecoder;
use s02sim::cpu::{Bus, Cpu};
use serde_json::Value;
use std::collections::HashMap;
use std::io::Read;

struct Mem(HashMap<u32, u8>);
impl Bus for Mem {
    fn read8(&mut self, a: u32) -> u8 {
        *self.0.get(&a).unwrap_or(&0)
    }
    fn write8(&mut self, a: u32, v: u8) {
        self.0.insert(a, v);
    }
    fn io_read8(&mut self, _: u16) -> u8 {
        0xFF
    }
    fn io_write8(&mut self, _: u16, _: u8) {}
    fn inta(&mut self) -> u8 {
        0
    }
}

/// L'etat final est-il l'entree dans INT 0 (CS et IP charges depuis la table des vecteurs) ?
fn fin_is_exception(fin: &Value) -> bool {
    fin["regs"].get("cs").is_some() && fin["regs"].get("sp").is_some()
}

const NAMES: [&str; 8] = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"];
const SEGS: [&str; 4] = ["es", "cs", "ss", "ds"];

fn mask_for(meta: &Value, file: &str) -> u16 {
    let stem = file.trim_end_matches(".json.gz");
    let mut parts = stem.split('.');
    let op = parts.next().unwrap().to_uppercase();
    let o = &meta["opcodes"][&op];
    let m = match parts.next() {
        Some(r) => &o["reg"][r]["flags-mask"],
        None => &o["flags-mask"],
    };
    m.as_u64().unwrap_or(0xFFFF) as u16
}

#[test]
fn single_step_tests() {
    let Ok(dir) = std::env::var("SST_DIR") else {
        println!("SST_DIR absent : essai saute");
        return;
    };
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(format!("{}/meta.json", dir)).or_else(|_| std::fs::read_to_string(format!("{}/metadata.json", dir))).unwrap()).unwrap();
    let mut files: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .filter(|n| n.ends_with(".json.gz"))
        .collect();
    files.sort();
    let (mut total, mut bad_files) = (0usize, 0usize);
    for f in &files {
        let mut s = String::new();
        GzDecoder::new(std::fs::File::open(format!("{}/{}", dir, f)).unwrap()).read_to_string(&mut s).unwrap();
        let tests: Value = serde_json::from_str(&s).unwrap();
        let fmask = mask_for(&meta, f);
        let mut fails = 0;
        let mut first: Option<String> = None;
        let n = tests.as_array().unwrap().len();
        for t in tests.as_array().unwrap() {
            let ini = &t["initial"];
            let mut cpu = Cpu::new();
            for (i, r) in NAMES.iter().enumerate() {
                cpu.r[i] = ini["regs"][r].as_u64().unwrap() as u16;
            }
            for (i, r) in SEGS.iter().enumerate() {
                cpu.s[i] = ini["regs"][r].as_u64().unwrap() as u16;
            }
            cpu.ip = ini["regs"]["ip"].as_u64().unwrap() as u16;
            cpu.flags = ini["regs"]["flags"].as_u64().unwrap() as u16;
            let mut mem = Mem(HashMap::new());
            for e in ini["ram"].as_array().unwrap() {
                mem.0.insert(e[0].as_u64().unwrap() as u32, e[1].as_u64().unwrap() as u8);
            }
            let start = (cpu.s[1], cpu.ip);
            // une instruction ; une chaine prefixee REP est rejouee jusqu'au bout
            let bytes: Vec<u8> = t["bytes"].as_array().unwrap().iter().map(|b| b.as_u64().unwrap() as u8).collect();
            let opi = bytes.iter().position(|b| !matches!(b, 0x26 | 0x2E | 0x36 | 0x3E | 0xF0 | 0xF1 | 0xF2 | 0xF3)).unwrap_or(0);
            let rep_str = bytes[..opi].iter().any(|&b| b == 0xF2 || b == 0xF3) && matches!(bytes[opi], 0xA4..=0xA7 | 0xAA..=0xAF);
            let mut k = 0;
            loop {
                cpu.step(&mut mem);
                k += 1;
                if !rep_str || (cpu.s[1], cpu.ip) != start || k > 70000 {
                    break;
                }
            }
            // exception de division : les drapeaux empiles par INT 0 sont ceux, non definis,
            // que laisse le microcode de division (non modelises) -> mot ignore
            let div_exc = matches!(bytes[opi], 0xF6 | 0xF7) && fin_is_exception(&t["final"]);
            let flags_word = Cpu::phys(cpu.s[2], cpu.r[4].wrapping_add(4));
            let fin = &t["final"];
            let mut err = Vec::new();
            for (i, r) in NAMES.iter().enumerate() {
                if let Some(v) = fin["regs"][r].as_u64() {
                    if cpu.r[i] != v as u16 {
                        err.push(format!("{}={:04X} (attendu {:04X})", r, cpu.r[i], v));
                    }
                }
            }
            for (i, r) in SEGS.iter().enumerate() {
                if let Some(v) = fin["regs"][r].as_u64() {
                    if cpu.s[i] != v as u16 {
                        err.push(format!("{}={:04X} (attendu {:04X})", r, cpu.s[i], v));
                    }
                }
            }
            if let Some(v) = fin["regs"]["ip"].as_u64() {
                if cpu.ip != v as u16 {
                    err.push(format!("ip={:04X} (attendu {:04X})", cpu.ip, v));
                }
            }
            let fexp = fin["regs"]["flags"].as_u64().map(|v| v as u16).unwrap_or(ini["regs"]["flags"].as_u64().unwrap() as u16);
            if (cpu.flags ^ fexp) & fmask & 0x0FD5 != 0 {
                err.push(format!("flags={:04X} (attendu {:04X}, masque {:04X})", cpu.flags, fexp, fmask));
            }
            for e in fin["ram"].as_array().unwrap() {
                let a = e[0].as_u64().unwrap() as u32;
                let v = e[1].as_u64().unwrap() as u8;
                let got = *mem.0.get(&a).unwrap_or(&0);
                if div_exc && (a == flags_word || a == (flags_word + 1) & 0xFFFFF) {
                    continue;
                }
                if got != v {
                    err.push(format!("[{:05X}]={:02X} (attendu {:02X})", a, got, v));
                }
            }
            if !err.is_empty() {
                fails += 1;
                if first.is_none() {
                    first = Some(format!("{} : {}", t["name"].as_str().unwrap_or("?"), err.join(", ")));
                }
            }
        }
        total += n;
        if fails > 0 {
            bad_files += 1;
            println!("{:12} {:5}/{} ECHECS  ex. {}", f, fails, n, first.unwrap());
        } else {
            println!("{:12} {} OK", f, n);
        }
    }
    println!("{} fichiers, {} cas, {} fichier(s) avec echecs", files.len(), total, bad_files);
    assert_eq!(bad_files, 0);
}
