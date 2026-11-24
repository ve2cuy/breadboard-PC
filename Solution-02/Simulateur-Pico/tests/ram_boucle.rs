//! Menu 2) Test memoire, 3) Loop : le nombre de passes au LCD et au terminal.
//! cargo test --release --test ram_boucle -- --nocapture

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

#[test]
fn passes_au_lcd_et_au_terminal() {
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    secs(&mut s, 6.0);
    texte(&mut s);
    s.uart_send(b"2");
    secs(&mut s, 1.0);
    println!("sous-menu : {:?}", s.lcd_lines());
    s.uart_send(b"3");
    let mut t = String::new();
    let mut vus = Vec::new();
    for k in 0..24 {
        secs(&mut s, 5.0);
        t.push_str(&texte(&mut s));
        let l = s.lcd_lines();
        println!("t = {:>3} s : {:?}", (k + 1) * 5, l);
        vus.push(l[1].clone());
    }
    println!("{}", &t[t.len().saturating_sub(1500)..]);
    let fr = t.contains("passe");
    let (p1, p2) = if fr { ("Passe 1 en cours    ", "Passe 2 en cours    ") } else { ("Pass 1 running      ", "Pass 2 running      ") };
    assert!(vus.iter().any(|l| l == p1), "LCD : pas de {:?}", p1);
    assert!(vus.iter().any(|l| l == p2), "LCD : pas de {:?}", p2);
    assert!(t.contains(if fr { "passe 2 " } else { "pass 2 " }), "terminal : pas de passe 2");
    assert!(t.contains(if fr { "Boucle: 1 passe(s)" } else { "Loop: 1 pass(es)" }), "terminal : pas de bilan");
    // Echap : arret apres la passe, retour au sous-menu (le numero ne reste pas au LCD)
    s.uart_send(b"");
    secs(&mut s, 60.0);
    let t = texte(&mut s);
    assert!(t.contains(if fr { "arrete (Echap)" } else { "stopped (Esc)" }), "pas d'arret : {:?}", t);
    let l = s.lcd_lines();
    println!("apres Echap : {:?}", l);
    assert!(l[1].starts_with("1) Trace"), "LCD : {:?}", l);
}
