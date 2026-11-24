//! Frappe rapide au clavier PS/2 (2026-11-24 : sur la carte, des touches se perdaient des ~3
//! caracteres par seconde ; pas au terminal). Causes : ~30 us masques a chaque entree d'INT 16h,
//! et l'IRQ1 qui supposait l'entree dans le bit de depart (avec un clavier a 15 kHz, une latence
//! de plus d'une periode decalait la trame). BIOS 3.4 : STI des l'entree des services,
//! ps2_trame_it compte les phases basses de CLK (10 ou 11).
//! PC-DOS 2.1 de la ROM, console UART a ON : un texte tape a 3, 5 et 8 caracteres par seconde,
//! touches tenues 80 ms, horloge du clavier a 10 et 15 kHz : tout doit arriver. A 16,7 kHz,
//! il reste de rares pertes (latence de l'IRQ1 de ~110 us) : KHZ=16.7 pour l'essayer.
//! cargo test --release --test frappe -- --nocapture

use s02picosim::{Sim, CLK_HZ};

fn rom() -> Vec<u8> {
    let p = std::env::var("S02_ROM").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios.bin").to_string()
    });
    std::fs::read(p).expect("ROM")
}

fn secs(s: &mut Sim, t: f64) {
    s.run(t * CLK_HZ);
}

fn texte(s: &mut Sim) -> String {
    let t = String::from_utf8_lossy(&s.uart_take()).to_string();
    let mut n = String::new();
    let mut it = t.chars();
    while let Some(c) = it.next() {
        if c == '\x1b' {
            for d in it.by_ref() {
                if d.is_ascii_alphabetic() {
                    break;
                }
            }
        } else if c != '\r' {
            n.push(c);
        }
    }
    n
}

fn code(c: char) -> u8 {
    match c {
        'a'..='z' => [0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15,
                      0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A][(c as u8 - b'a') as usize],
        _ => 0x29,
    }
}

/// Tape `t` a `cps` caracteres par seconde, chaque touche tenue `tenue` s.
fn taper(s: &mut Sim, t: &str, cps: f64, tenue: f64) {
    for c in t.chars() {
        s.kbd(&[code(c)]);
        secs(s, tenue);
        s.kbd(&[0xF0, code(c)]);
        secs(s, 1.0 / cps - tenue);
    }
}

fn touche(s: &mut Sim, k: u8) {
    s.kbd(&[k]);
    secs(s, 0.1);
    s.kbd(&[0xF0, k]);
    secs(s, 0.3);
}

fn au_dos(atmega: bool, khz: f64) -> Sim {
    let mut s = Sim::new(&rom());
    s.kbd_khz(khz);
    s.set_atmega(atmega);
    secs(&mut s, 6.0);
    touche(&mut s, 0x16); // 1) DOS (sans carte : PC-DOS 2.1 de la ROM)
    secs(&mut s, 12.0);
    touche(&mut s, 0x5A); // date
    secs(&mut s, 1.0);
    touche(&mut s, 0x5A); // heure
    secs(&mut s, 2.0);
    let t = texte(&mut s);
    assert!(t.contains("A>"), "pas d'invite du DOS : {:?}", t);
    s
}

fn essai(atmega: bool) {
    let mot = "abcdefghijklmnopqrstuvwxyz";
    let mut echecs = Vec::new();
    let khz_v: Vec<f64> = match std::env::var("KHZ").ok().and_then(|v| v.parse().ok()) {
        Some(k) => vec![k],
        None => vec![10.0, 15.0],
    };
    for khz in khz_v {
        for cps in [3.0, 5.0, 8.0] {
            let mut s = au_dos(atmega, khz);
            let avant = s.kbd_stats();
            taper(&mut s, mot, cps, 0.08);
            secs(&mut s, 1.0);
            let t = texte(&mut s);
            let recu: String = t.lines().last().unwrap_or("").trim_start_matches("A>").to_string();
            let st = s.kbd_stats();
            println!(
                "clavier {:>4} kHz, {} car/s (ATmega {}) : {:?} ; trames perdues {}",
                khz, cps, atmega, recu, st[1] - avant[1]
            );
            if recu != mot || st[1] != avant[1] {
                echecs.push((khz, cps, recu));
            }
        }
    }
    assert!(echecs.is_empty(), "touches perdues : {:?}", echecs);
}

#[test]
fn frappe_rapide_avec_atmega() {
    essai(true);
}

#[test]
fn frappe_rapide_sans_atmega() {
    essai(false);
}

#[test]
#[ignore]
fn retards_de_l_irq1() {
    for atmega in [false, true] {
        let khz: f64 = std::env::var("KHZ").ok().and_then(|v| v.parse().ok()).unwrap_or(15.0);
        let mut s = au_dos(atmega, khz);
        s.kbd_retards();
        taper(&mut s, "abcdefghijklmnopqrstuvwxyz", 5.0, 0.08);
        secs(&mut s, 1.0);
        let mut r = s.kbd_retards();
        r.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = r.len();
        println!("ATmega {} : {} trames ; retard min {:.0} us, median {:.0}, 90 % {:.0}, max {:.0}",
                 atmega, n, r[0], r[n / 2], r[n * 9 / 10], r[n - 1]);
        let p = 1000.0 / khz;
        println!("  > {:.0} us : {:?}", p, r.iter().filter(|&&x| x > p).map(|x| x.round()).collect::<Vec<_>>());
    }
}

#[test]
#[ignore]
fn trace_des_trames() {
    let cps: f64 = std::env::var("CPS").ok().and_then(|v| v.parse().ok()).unwrap_or(5.0);
    let mut s = au_dos(true, 16.7);
    s.kbd_trace();
    texte(&mut s);
    taper(&mut s, "abcdefghijklmnopqrstuvwxyz", cps, 0.08);
    secs(&mut s, 1.0);
    println!("{:?}", texte(&mut s));
    for (b, r) in s.kbd_trace() {
        println!("{:02X} {:.0}", b, r);
    }
}
