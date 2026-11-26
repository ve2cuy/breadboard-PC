//! ELKS sans Pico W (montage d'avant le Pico : ATmega U17 + module Wi-Fi en SLIP sur le canal 2).
//! Symptome du 2026-11-26 sur la carte (BIOS 3.4) : sous ELKS, le module Wi-Fi est sollicite sans
//! arret, puis le montage redemarre. L'essai compte les octets echanges avec le module pendant
//! que le systeme est au repos et guette un redemarrage (banniere du BIOS au terminal).
//! cargo test --release --test elks_sans_pico -- --nocapture

use s02picosim::{Sim, CLK_HZ};

fn rom() -> Vec<u8> {
    let p = std::env::var("S02_ROM").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios-en.bin").to_string()
    });
    std::fs::read(p).expect("ROM")
}

fn secs(s: &mut Sim, t: f64) {
    s.run(t * CLK_HZ);
}

fn appuyer(s: &mut Sim, code: u8) {
    s.kbd(&[code]);
    secs(s, 0.4);
    s.kbd(&[0xF0, code]);
}

fn etendue(s: &mut Sim, code: u8) {
    s.kbd(&[0xE0, code]);
    secs(s, 0.4);
    s.kbd(&[0xE0, 0xF0, code]);
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

fn commande(s: &mut Sim, c: &str, t: f64) -> String {
    s.uart_send(c.as_bytes());
    s.uart_send(b"\r");
    secs(s, t);
    let r = texte(s);
    println!("$ {}\n{}", c, r);
    r
}

/// (octets recus du module par l'ATmega, octets emis vers le module)
fn module(s: &Sim) -> (u64, u64) {
    let j = s.atmega_state();
    let v = |k: &str| -> u64 {
        let i = j.find(&format!("\"{}\":", k)).unwrap() + k.len() + 3;
        j[i..].split(|c: char| !c.is_ascii_digit()).next().unwrap().parse().unwrap()
    };
    (v("recus2"), v("emis2"))
}

fn elks(s: &mut Sim) {
    let p = std::env::var("S02_ELKS_HD").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/../elks/sortie/elks-solution02-hd32.img").to_string()
    });
    let img = std::fs::read(&p).expect("image ELKS");
    s.set_atmega(true);
    s.wifi_slip(true);
    s.sd_add_file("ELKSHD.IMG", &img);
    s.sd_insert_built();
    secs(s, 6.0);
    appuyer(s, 0x16); // 1) DOS
    secs(s, 8.0);
    for _ in 0..2 {
        etendue(s, 0x72); // fleche bas : C:
        secs(s, 0.5);
    }
    texte(s);
    appuyer(s, 0x5A); // Entree
    secs(s, 90.0);
    let t = texte(s);
    println!("{}", t);
    assert!(t.contains("login:"), "ELKS n'a pas demarre depuis C:");
    commande(s, "root", 15.0);
}

#[test]
fn elks_repos_sans_pico() {
    let mut s = Sim::new(&rom());
    assert!(!s.pico());
    elks(&mut s);
    let (r0, e0) = module(&s);
    println!("module apres le demarrage : recus {} emis {}", r0, e0);
    commande(&mut s, "net start slip", 20.0);
    let (r1, e1) = module(&s);
    println!("module apres net start : recus {} emis {}", r1, e1);
    for i in 0..12 {
        secs(&mut s, 10.0);
        let (r, e) = module(&s);
        let t = texte(&mut s);
        println!("t+{:3} s : module recus {} emis {} ; terminal {:?}", (i + 1) * 10, r, e, t);
        println!("  LCD {:?}", s.lcd_lines());
        assert!(!t.contains("BIOS"), "redemarrage du BIOS");
        assert_eq!((r, e), (r1, e1), "le module est sollicite au repos");
    }
    let r = commande(&mut s, "ping -c 2 192.168.240.1", 12.0);
    assert!(r.contains("from 192.168.240.1"), "reseau : {:?}", r);
}

#[test]
fn elks_trafic_sans_pico() {
    let mut s = Sim::new(&rom());
    elks(&mut s);
    commande(&mut s, "net start slip", 20.0);
    let r = commande(&mut s, "ping -c 150 -i 1 8.8.8.8", 200.0);
    println!("{}", s.atmega_state());
    assert!(r.contains("150 packets transmitted"), "ping : {:?}", r);
    let r = commande(&mut s, "ls /bin", 20.0);
    assert!(r.contains("ktcp"), "ELKS ne repond plus : {:?}", r);
}
