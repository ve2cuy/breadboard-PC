//! MS-DOS 6.22 en reseau : pilote de paquets S02PKT (Solution-02/dos, SLIP vers le module Wi-Fi
//! par le BIOS 3.1) et mTCP. Le module simule repond aux pings (lui-meme et toute autre adresse,
//! comme a travers son NAT).
//! Image : PC-DOS/DOSNET_C.IMG (bios/tests/gen_dosnet.py, hors de git).
//! cargo test --release --test dos_reseau -- --nocapture

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

fn commande(s: &mut Sim, c: &str, t: f64) -> String {
    s.uart_send(c.as_bytes());
    s.uart_send(b"\r");
    secs(s, t);
    let r = texte(s);
    println!("> {}\n{}", c, r);
    r
}

#[test]
fn dos_mtcp_ping_par_slip() {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/DOSNET_C.IMG");
    let Ok(img) = std::fs::read(p) else {
        println!("image absente ({}) : essai saute", p);
        return;
    };
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s.wifi_slip(true);
    s.sd_add_file("DOSNET_C.IMG", &img);
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
    secs(&mut s, 40.0);
    let t = texte(&mut s);
    println!("{}", t);
    assert!(t.contains("Installe sur INT 60h"), "S02PKT ne s'est pas installe : {:?}", t);
    let r = commande(&mut s, "PING 192.168.240.1", 30.0);
    println!("paquets recus par le module : {}", s.wifi_paquets());
    assert!(s.wifi_paquets() >= 1, "aucun paquet SLIP n'est arrive au module");
    assert!(r.contains("Replies received: 4"), "pas de reponse du module : {:?}", r);
    let r = commande(&mut s, "PING 8.8.8.8", 30.0);
    assert!(r.contains("received from 8.8.8.8"), "pas de reponse a travers le NAT : {:?}", r);
}
