//! Pico W (A1) sur les ports 50h-57h, derriere U18/U19, avec le BIOS 3.3 :
//! - detection (IDENT) et infos systeme ;
//! - carte SD du Pico (J14) : demarrage du DOS depuis C:, vitesse des secteurs ;
//! - reseau : S02PKT et mTCP (PING, DNS, HTGET) puis ELKS (ktcp, ping, urlget) par le Pico,
//!   l'Internet etant celui du simulateur (src/internet.rs).
//! Images : PC-DOS/DOSNET_C.IMG (bios/tests/gen_dosnet.py), elks/sortie/elks-solution02-hd32.img.
//! cargo test --release --test pico -- --nocapture

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

/// Envoie une commande au terminal et attend jusqu'a `t` secondes (fin des que `fin` apparait).
fn commande(s: &mut Sim, c: &str, t: f64, fin: &str) -> String {
    s.uart_send(c.as_bytes());
    s.uart_send(b"\r");
    let mut r = String::new();
    let mut e = 0.0;
    while e < t {
        secs(s, 0.5);
        e += 0.5;
        r.push_str(&texte(s));
        if !fin.is_empty() && r.contains(fin) {
            secs(s, 0.5);
            r.push_str(&texte(s));
            break;
        }
    }
    println!("> {}\n{}", c, r);
    r
}

fn carte_pico(img_nom: &str, img: &[u8]) -> Sim {
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s.set_pico(true);
    s.sd_add_file(img_nom, img);
    s.sd_insert_built();
    s.set_sd_pico(true);
    s
}

/// Menu 1) DOS, deux fleches vers le bas (C:), Entree.
fn demarrer_c(s: &mut Sim, t: f64) -> String {
    secs(s, 6.0);
    appuyer(s, 0x16);
    secs(s, 6.0);
    for _ in 0..2 {
        etendue(s, 0x72);
        secs(s, 0.5);
    }
    texte(s);
    appuyer(s, 0x5A);
    secs(s, t);
    let t = texte(s);
    println!("{}", t);
    t
}

#[test]
fn bios_detecte_le_pico() {
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s.set_pico(true);
    secs(&mut s, 3.0);
    let v = s.peek(0x7F000 + 0x8A4, 4);
    assert_eq!(v[0], 1, "V_PICO : BIOS 3.3 sans Pico detecte");
    assert_eq!(v[2], s02pico_coeur::VERSION, "V_PICO_VER");
    // sans Pico : rien de change
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    secs(&mut s, 3.0);
    assert_eq!(s.peek(0x7F000 + 0x8A4, 1)[0], 0);
}

#[test]
fn info_systeme_montre_le_pico() {
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s.set_pico(true);
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x25); // 4) Info
    secs(&mut s, 2.0);
    let l = s.lcd_lines();
    println!("{:?}", l);
    assert!(l.iter().any(|x| x.contains("Pico v01")), "{:?}", l);
}

#[test]
fn dos_depuis_la_carte_du_pico_et_reseau() {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/DOSNET_C.IMG");
    let Ok(img) = std::fs::read(p) else {
        println!("image absente ({}) : essai saute", p);
        return;
    };
    let mut s = carte_pico("DOSNET_C.IMG", &img);
    let t0 = s.cycles();
    let t = demarrer_c(&mut s, 25.0);
    assert!(t.contains("Installe sur INT 60h"), "S02PKT ne s'est pas installe : {:?}", t);
    let st = s.pico_state();
    println!("Pico : {}", st);
    let v: serde_json::Value = serde_json::from_str(&st).unwrap();
    assert!(v["sd_lus"].as_u64().unwrap() > 50, "le DOS n'a pas ete lu par le Pico");
    println!("demarrage : {:.1} s", (s.cycles() - t0) / CLK_HZ);

    let r = commande(&mut s, "PING 192.168.240.1", 20.0, "Replies received");
    assert!(r.contains("Replies received: 4"), "pas de reponse du Pico : {:?}", r);
    let r = commande(&mut s, "PING 8.8.8.8", 20.0, "Replies received");
    assert!(r.contains("received from 8.8.8.8"), "pas de reponse de l'Internet : {:?}", r);
    // DNS (zone s02 de l'Internet simule) et HTTP par le relais TCP du Pico
    let r = commande(&mut s, "HTGET http://www.s02/", 30.0, "</html>");
    assert!(r.contains("Bienvenue sur www.s02"), "HTGET www.s02 : {:?}", r);
    // page d'etat servie par le Pico lui-meme
    let r = commande(&mut s, "HTGET http://192.168.240.1/", 30.0, "</html>");
    assert!(r.contains("Pico W de Solution-02"), "page du Pico : {:?}", r);
    // 64 Ko : debit et integrite (ecrits sur C: par le DOS, a travers le Pico)
    let t1 = s.cycles();
    let r = commande(&mut s, "HTGET -o GROS.BIN http://www.s02/gros.bin", 120.0, "C:\\");
    let dt = (s.cycles() - t1) / CLK_HZ;
    println!("gros.bin : {:.1} s, {:.1} Ko/s", dt, 64.0 / dt);
    assert!(!r.to_ascii_lowercase().contains("error"), "HTGET gros.bin : {:?}", r);
    let r = commande(&mut s, "DIR GROS.BIN", 10.0, "C:\\");
    assert!(r.contains("65,536") || r.contains("65 536") || r.contains("65536"), "taille de GROS.BIN : {:?}", r);
    let v: serde_json::Value = serde_json::from_str(&s.pico_state()).unwrap();
    println!("Pico : {}", v);
    assert_eq!(v["perdus"].as_u64().unwrap(), 0, "paquets perdus dans le Pico");
    assert!(v["sd_ecrits"].as_u64().unwrap() > 100, "GROS.BIN pas ecrit par le Pico");
}

#[test]
fn secteurs_par_le_pico_plus_vite_que_le_spi() {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/DOSNET_C.IMG");
    let Ok(img) = std::fs::read(p) else {
        println!("image absente ({}) : essai saute", p);
        return;
    };
    let mut temps = Vec::new();
    for pico in [false, true] {
        let mut s = Sim::new(&rom());
        s.set_atmega(true);
        s.set_pico(pico);
        s.sd_add_file("DOSNET_C.IMG", &img);
        s.sd_insert_built();
        s.set_sd_pico(pico);
        let t0 = s.cycles();
        let t = demarrer_c(&mut s, 0.0);
        let _ = t;
        // jusqu'a l'invite du DOS
        let mut tout = String::new();
        let mut e = 0.0;
        while e < 90.0 && !tout.contains("Installe sur INT 60h") {
            secs(&mut s, 0.25);
            e += 0.25;
            tout.push_str(&texte(&mut s));
        }
        assert!(tout.contains("Installe sur INT 60h"), "pico={} : {:?}", pico, tout);
        temps.push((s.cycles() - t0) / CLK_HZ);
    }
    println!("demarrage du DOS jusqu'a S02PKT : SPI de U12 {:.1} s, Pico {:.1} s", temps[0], temps[1]);
    assert!(temps[1] < temps[0] * 0.8, "le Pico n'accelere pas : {:?}", temps);
}

#[test]
fn elks_par_le_pico() {
    let p = std::env::var("S02_ELKS_HD").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/../elks/sortie/elks-solution02-hd32.img").to_string()
    });
    let Ok(img) = std::fs::read(&p) else {
        println!("image absente ({}) : essai saute", p);
        return;
    };
    let mut s = carte_pico("ELKSHD.IMG", &img);
    let t = demarrer_c(&mut s, 60.0);
    assert!(t.contains("login:"), "ELKS n'a pas demarre depuis la carte du Pico");
    assert!(t.contains("ttyS1"), "pilote ttyS1 absent : {:?}", t);
    commande(&mut s, "root", 10.0, "#");
    let r = commande(&mut s, "net start slip", 20.0, "ktcp");
    assert!(r.contains("ktcp"), "net start slip : {:?}", r);
    let r = commande(&mut s, "ping -c 3 192.168.240.1", 15.0, "packets");
    assert!(r.contains("from 192.168.240.1"), "ping du Pico : {:?}", r);
    let r = commande(&mut s, "ping -c 2 8.8.8.8", 15.0, "packets");
    assert!(r.contains("from 8.8.8.8"), "ping de l'Internet : {:?}", r);
    let r = commande(&mut s, "urlget http://www.s02/texte.txt", 30.0, "OK");
    assert!(r.contains("Solution-02 + Pico W : OK"), "urlget : {:?}", r);
}

#[test]
fn freedos_mtcp_par_le_pico() {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/FDNET_C.IMG");
    let Ok(img) = std::fs::read(p) else {
        println!("image absente ({}) : essai saute", p);
        return;
    };
    let mut s = carte_pico("FDNET_C.IMG", &img);
    let t = demarrer_c(&mut s, 30.0);
    assert!(t.contains("Installe sur INT 60h"), "S02PKT sous FreeDOS : {:?}", t);
    assert!(t.contains("Pico W"), "lien du Pico non vu par S02PKT : {:?}", t);
    let r = commande(&mut s, "PING 8.8.8.8", 20.0, "Replies received");
    assert!(r.contains("received from 8.8.8.8"), "{:?}", r);
    let r = commande(&mut s, "HTGET http://www.s02/texte.txt", 30.0, "OK");
    assert!(r.contains("Solution-02 + Pico W : OK"), "{:?}", r);
}
