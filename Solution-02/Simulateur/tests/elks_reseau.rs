//! ELKS en reseau : ttyS1 = module Wi-Fi (esp_slip_router) par le BIOS 3.1 (INT 14h DX=1, blocs)
//! et l'ATmega U17 (canal 2), ktcp en SLIP. Le module simule repond aux pings (le module lui-meme
//! et toute autre adresse, comme a travers son NAT).
//! Image : elks/sortie/elks-solution02-hd32.img (elks/construire-hd.ps1), ou S02_ELKS_HD.
//! cargo test --release --test elks_reseau -- --nocapture

use s02sim::{Sim, CLK_HZ};

fn rom() -> Vec<u8> {
    let p = std::env::var("S02_ROM").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios.bin").to_string()
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

#[test]
fn elks_ping_par_slip() {
    let p = std::env::var("S02_ELKS_HD").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/../elks/sortie/elks-solution02-hd32.img").to_string()
    });
    let Ok(img) = std::fs::read(&p) else {
        println!("image absente ({}) : essai saute", p);
        return;
    };
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s.wifi_slip(true);
    s.sd_add_file("ELKSHD.IMG", &img);
    s.sd_insert_built();
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x16); // 1) DOS
    secs(&mut s, 8.0);
    for _ in 0..2 {
        etendue(&mut s, 0x72); // fleche bas : C:
        secs(&mut s, 0.5);
    }
    texte(&mut s);
    appuyer(&mut s, 0x5A); // Entree
    secs(&mut s, 90.0);
    let t = texte(&mut s);
    println!("{}", t);
    assert!(t.contains("login:"), "ELKS n'a pas demarre depuis C:");
    assert!(t.contains("ttyS1 Wi-Fi module"), "pilote ttyS1 du module absent au demarrage");
    commande(&mut s, "root", 15.0);
    let r = commande(&mut s, "net start slip", 20.0);
    assert!(r.contains("ktcp"), "net start slip : {:?}", r);
    let r = commande(&mut s, "ping -c 3 192.168.240.1", 15.0);
    println!("paquets recus par le module : {}", s.wifi_paquets());
    assert!(s.wifi_paquets() >= 1, "aucun paquet SLIP n'est arrive au module");
    assert!(r.contains("from 192.168.240.1"), "pas de reponse du module : {:?}", r);
    let r = commande(&mut s, "ping -c 2 8.8.8.8", 12.0);
    assert!(r.contains("from 8.8.8.8"), "pas de reponse a travers le NAT : {:?}", r);
    // session telnet (ELKS vers lui-meme, comme depuis le PC a travers la redirection du module) :
    // telnetd, pseudo-terminal, login et un second shell doivent laisser de quoi lancer ls
    // (buf=24 dans /bootopts, pas de ftpd : 2026-11-23, 'ls: not enough memory' sur la carte)
    let r = commande(&mut s, "telnet 192.168.240.2", 20.0);
    assert!(r.contains("login:"), "telnet local : {:?}", r);
    commande(&mut s, "root", 20.0);
    let r = commande(&mut s, "ls /bin", 20.0);
    assert!(!r.contains("not enough memory") && r.contains("ktcp"), "ls dans la session telnet : {:?}", r);
    commande(&mut s, "meminfo", 15.0);
}
