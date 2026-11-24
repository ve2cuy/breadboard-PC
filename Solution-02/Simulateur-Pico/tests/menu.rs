//! BIOS 3.4 : menu principal a un choix par ligne (pages au LCD, liste complete au terminal) et
//! choix de l'image du DOS par une touche (0-9, A-Z), sans fleches (clavier du iPad).
//! cargo test --release --test menu -- --nocapture

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

fn lignes(s: &Sim) -> Vec<String> {
    s.lcd_lines().iter().map(|l| l.trim_end().to_string()).collect()
}

#[test]
fn menu_un_choix_par_ligne_avec_atmega() {
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    secs(&mut s, 6.0);
    let t = texte(&mut s);
    println!("{}\n{:?}", t, lignes(&s));
    assert_eq!(lignes(&s), ["1) Lancer le DOS 1/3", "2) Test memoire", "3) Anim. des DEL", "4) Info systeme"]);
    for l in ["1) Lancer le DOS", "4) Info systeme", "5) Console: ON", "6) BASIC", "7) DEL auto: ON", "8) UART 57600", "9) Wi-Fi"] {
        assert!(t.contains(&format!("{}\n", l)), "terminal : {:?} absent de {:?}", l, t);
    }
    s.uart_send(b" ");
    secs(&mut s, 0.5);
    assert_eq!(lignes(&s), ["5) Console: ON   2/3", "6) BASIC", "7) DEL auto: ON", "8) UART 57600"]);
    s.uart_send(b" ");
    secs(&mut s, 0.5);
    assert_eq!(lignes(&s), ["9) Wi-Fi         3/3", "", "", ""]);
    // les touches marchent sur toutes les pages : 7) bascule, la page reste
    // 7) depuis la page 3 : le LCD montre la page du choix (on voit le changement)
    s.uart_send(b"7");
    secs(&mut s, 0.5);
    assert_eq!(lignes(&s)[0], "5) Console: ON   2/3");
    assert_eq!(lignes(&s)[2], "7) DEL auto: OFF");
    // fleche gauche (sequence ANSI du terminal) : page precedente
    s.uart_send(b"\x1b[D");
    secs(&mut s, 0.5);
    assert_eq!(lignes(&s)[0], "1) Lancer le DOS 1/3");
    // 4) Info depuis la page 1
    s.uart_send(b"4");
    secs(&mut s, 1.0);
    assert_eq!(lignes(&s)[0], "SOLUTION-02 BIOS 3.4");
}

#[test]
fn menu_sans_atmega_deux_pages() {
    let mut s = Sim::new(&rom());
    secs(&mut s, 6.0);
    assert_eq!(lignes(&s)[0], "1) Lancer le DOS 1/2");
    s.kbd(&[0x29]); // Espace au clavier PS/2
    secs(&mut s, 0.3);
    s.kbd(&[0xF0, 0x29]);
    secs(&mut s, 0.5);
    assert_eq!(lignes(&s), ["5) Console: ON   1/2".replace("1/2", "2/2"), "6) BASIC".into(), "7) DEL auto: ON".into(), "".into()]);
}

#[test]
fn image_choisie_par_une_touche() {
    let dos = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/Dos33-d1.IMG"));
    let pc21 = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/pcdos2_1.img"));
    let (Ok(dos), Ok(pc21)) = (dos, pc21) else {
        println!("images absentes : essai saute");
        return;
    };
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s.sd_add_file("PCDOS21.IMG", &pc21);
    s.sd_add_file("DOS33.IMG", &dos);
    s.sd_insert_built();
    secs(&mut s, 6.0);
    texte(&mut s);
    s.uart_send(b"1");
    secs(&mut s, 6.0);
    let t = texte(&mut s);
    println!("{}\n{:?}", t, lignes(&s));
    assert!(t.contains("0>ROM PC-DOS 2.1"), "liste au terminal : {:?}", t);
    assert!(t.contains("1 PCDOS21.IMG") && t.contains("2 DOS33.IMG"), "liste au terminal : {:?}", t);
    assert_eq!(lignes(&s)[0], "Touche ou Entree");
    s.uart_send(b"2"); // DOS 3.3, sans fleches
    let mut tout = String::new();
    for _ in 0..60 {
        secs(&mut s, 0.5);
        tout.push_str(&texte(&mut s));
        if tout.contains("A>") || tout.contains("Enter new date") {
            break;
        }
    }
    println!("{}", tout);
    assert!(tout.contains("Enter new date") || tout.contains("A>"), "DOS 3.3 n a pas demarre : {:?}", tout);
}
