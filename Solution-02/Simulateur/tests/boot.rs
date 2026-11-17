//! Essais natifs : le BIOS de Solution-02 demarre dans le simulateur comme sur le montage.
//! cargo test --release -- --nocapture

use s02sim::{Sim, CLK_HZ};

fn rom() -> Vec<u8> {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios.bin");
    std::fs::read(p).or_else(|_| std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../bios/build/solution-02-bios.bin"))).expect("ROM")
}

fn secs(s: &mut Sim, t: f64) {
    s.run(t * CLK_HZ);
}

fn show(s: &Sim, titre: &str) {
    println!("--- {} (t = {:.2} s)", titre, s.cycles() / CLK_HZ);
    for l in s.lcd_lines() {
        println!("|{}|", l);
    }
}

/// Frappe d'une touche (jeu 2) : appui, 400 ms, relachement. Limite du BIOS (aussi sur le
/// montage) : une trame qui arrive pendant un envoi a l'UART (interruptions masquees ~1 ms par
/// caractere) est perdue ; un relachement perdu fait ignorer la touche suivante. On relache donc
/// apres l'echo de la touche.
fn appuyer(s: &mut Sim, code: u8) {
    s.kbd(&[code]);
    secs(s, 0.4);
    s.kbd(&[0xF0, code]);
}

fn texte_uart(s: &mut Sim) -> String {
    String::from_utf8_lossy(&s.uart_take()).into_owned()
}

#[test]
fn demarrage_et_menu() {
    let mut s = Sim::new(&rom());
    secs(&mut s, 0.5);
    show(&s, "ecran d'ouverture");
    secs(&mut s, 6.0);
    show(&s, "menu");
    let tx = texte_uart(&mut s);
    println!("UART ({} octets) :\n{}", tx.len(), tx);
    println!("{}", s.stats());
    let log = s.take_log();
    println!("journal : {}", log);
    let lignes = s.lcd_lines().join("\n");
    assert!(lignes.contains("6) BASIC"), "menu absent du LCD");
    assert!(tx.contains("6) BASIC"), "menu absent de l'UART");
}

#[test]
fn melodie_du_menu_au_piezo() {
    let mut s = Sim::new(&rom());
    s.audio_enable(true);
    let mut crete = 0f32;
    let mut n = 0usize;
    for _ in 0..80 {
        secs(&mut s, 0.1);
        let a = s.audio(48000.0);
        n += a.len();
        for v in a {
            crete = crete.max(v.abs());
        }
    }
    println!("{} echantillons, crete {:.3}, {}", n, crete, s.stats());
    assert!(n > 370_000, "trop peu d'echantillons");
    assert!(crete > 0.1, "aucun son : la melodie du menu n'est pas sortie");
}

#[test]
fn led_show_et_info() {
    let mut s = Sim::new(&rom());
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x26); // 3) LED Show
    secs(&mut s, 3.0);
    show(&s, "LED Show");
    let sig = s.signals();
    let names: Vec<String> = Sim::signal_names().split('\n').map(String::from).collect();
    let actives = (0..24).filter(|i| sig[names.iter().position(|n| n == "PA0").unwrap() + i] & 4 != 0).count();
    println!("DEL actives : {}", actives);
    assert!(actives > 0, "aucune DEL ne bouge");
    appuyer(&mut s, 0x76); // Echap
    secs(&mut s, 1.5);
    println!("UART apres Echap : {:?}\n{}", texte_uart(&mut s), s.stats());
    show(&s, "apres Echap");
    appuyer(&mut s, 0x25); // 4) Info
    secs(&mut s, 2.0);
    show(&s, "Info");
    println!("UART apres 4 : {}\n{}", texte_uart(&mut s), s.stats());
    let l = s.lcd_lines().join("\n");
    assert!(l.contains("8259+8253 OK"), "Info : 8259/8253 non detectes");
    // sans 8259 : repli par scrutation
    s.set_fault("no_pic", 1);
    s.reset_button(true);
    secs(&mut s, 0.01);
    s.reset_button(false);
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x25);
    secs(&mut s, 2.0);
    show(&s, "Info sans 8259");
    assert!(s.lcd_lines().join("\n").contains("8259 absent"), "repli sans 8259 non detecte");
}

/// Panne reelle du 2026-11-13 : D0-D7 inverses vers U7. Le mot 80h arrive comme 01h (commande
/// BSR) : les ports restent en entree (etat du RESET), aucune DEL ne s'allume.
#[test]
fn panne_bus_inverse_vers_u7() {
    let mut s = Sim::new(&rom());
    s.set_fault("u7_data_rev", 1);
    s.power(false);
    s.power(true);
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x26); // 3) LED Show
    secs(&mut s, 2.0);
    let sig = s.signals();
    let names: Vec<String> = Sim::signal_names().split('\n').map(String::from).collect();
    let pa0 = names.iter().position(|n| n == "PA0").unwrap();
    let flottantes = (0..24).filter(|i| sig[pa0 + i] & 3 == 2).count();
    println!("broches de U7 flottantes : {}/24", flottantes);
    assert_eq!(flottantes, 24, "U7 ne devrait pas sortir de donnees");
    assert!(s.chip_info("U7").contains("9Bh") || s.chip_info("U7").contains("entrée"), "{}", s.chip_info("U7"));
}

/// BASIC de la ROM (menu 6) : PRINT 2+3 tape au clavier PS/2 (Maj pour le +).
#[test]
fn basic_print() {
    let mut s = Sim::new(&rom());
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x36); // 6) BASIC
    secs(&mut s, 2.5);
    texte_uart(&mut s);
    taper(&mut s, "print 2");
    s.kbd(&[0x12]); // Maj gauche
    secs(&mut s, 0.05);
    appuyer(&mut s, 0x55); // = -> +
    s.kbd(&[0xF0, 0x12]);
    secs(&mut s, 0.1);
    taper(&mut s, "3
");
    secs(&mut s, 1.0);
    let tx = texte_uart(&mut s);
    println!("UART : {:?}", tx);
    assert!(tx.contains("print 2+3") && tx.contains(" 5"), "BASIC : PRINT 2+3 n'a pas donne 5");
}

fn image(nom: &str) -> Option<Vec<u8>> {
    std::fs::read(format!("{}/../../PC-DOS/{}", env!("CARGO_MANIFEST_DIR"), nom)).ok()
}

/// Touche etendue (E0 xx) : appui, 80 ms, relachement.
fn etendue(s: &mut Sim, code: u8) {
    s.kbd(&[0xE0, code]);
    secs(s, 0.4);
    s.kbd(&[0xE0, 0xF0, code]);
}

fn taper(s: &mut Sim, t: &str) {
    for c in t.chars() {
        let code = match c {
            'a'..='z' => [0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15, 0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A][(c as u8 - b'a') as usize],
            ' ' => 0x29,
            '0'..='9' => [0x45, 0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46][(c as u8 - b'0') as usize],
            ':' => 0x4C, // ';' sans Maj (approximation suffisante ici)
            '\n' => 0x5A,
            _ => 0x29,
        };
        appuyer(s, code);
        secs(s, 0.15);
    }
}

#[test]
fn carte_sd_dos622_sur_c() {
    let (Some(c), Some(a)) = (image("DOS622_C.IMG"), image("Dos33-d1.IMG")) else {
        println!("images absentes : essai saute");
        return;
    };
    let mut s = Sim::new(&rom());
    s.sd_add_file("DOS33.IMG", &a);
    s.sd_add_file("DOS622_C.IMG", &c);
    s.sd_insert_built();
    secs(&mut s, 6.0);
    texte_uart(&mut s);
    appuyer(&mut s, 0x16);
    secs(&mut s, 8.0);
    show(&s, "liste de la carte");
    println!("UART :\n{}", texte_uart(&mut s));
    // descendre jusqu'a la ligne C: puis Entree
    for _ in 0..4 {
        etendue(&mut s, 0x72);
        secs(&mut s, 0.5);
    }
    show(&s, "C: choisi ?");
    appuyer(&mut s, 0x5A);
    secs(&mut s, 40.0);
    show(&s, "demarrage de C:");
    let tx = texte_uart(&mut s);
    println!("UART :\n{}", tx);
    taper(&mut s, "ver\n");
    secs(&mut s, 3.0);
    let tx2 = texte_uart(&mut s);
    println!("UART :\n{}", tx2);
    println!("{}", s.stats());
    assert!(tx2.contains("6.2") || tx.contains("6.2") || tx2.contains("MS-DOS"), "MS-DOS 6.22 n'a pas repondu");
}

#[test]
fn dos_depuis_la_rom() {
    let mut s = Sim::new(&rom());
    secs(&mut s, 6.0);
    texte_uart(&mut s);
    // 1) Load DOS : sans carte, la ROM
    appuyer(&mut s, 0x16);
    secs(&mut s, 3.0);
    show(&s, "apres 1");
    let tx = texte_uart(&mut s);
    println!("UART :\n{}", tx);
    // date et heure : Entree, Entree
    for _ in 0..2 {
        appuyer(&mut s, 0x5A);
        secs(&mut s, 2.0);
    }
    show(&s, "invite");
    // dir
    for c in [0x23u8, 0x43, 0x2D] {
        appuyer(&mut s, c);
        secs(&mut s, 0.3);
    }
    appuyer(&mut s, 0x5A);
    secs(&mut s, 6.0);
    show(&s, "apres dir");
    let tx = texte_uart(&mut s);
    println!("UART :\n{}", tx);
    println!("{}", s.stats());
    assert!(tx.contains("COMMAND"), "DIR n'a pas liste COMMAND.COM");
}
