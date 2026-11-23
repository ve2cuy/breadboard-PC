//! BIOS 3.2 sur la carte avec l'ATmega328P U17 (schema du 2026-11-23) : terminal par
//! l'ATmega (esclave SPI du 8088), carte SD sur le meme bus.
//! cargo test --release --test bios_atmega -- --nocapture

use s02sim::{Sim, CLK_HZ};

fn rom() -> Vec<u8> {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios.bin");
    std::fs::read(p).expect("ROM")
}

fn image(nom: &str) -> Option<Vec<u8>> {
    std::fs::read(format!("{}/../../PC-DOS/{}", env!("CARGO_MANIFEST_DIR"), nom)).ok()
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

fn texte_uart(s: &mut Sim) -> String {
    String::from_utf8_lossy(&s.uart_take()).into_owned()
}

/// Texte du terminal sans les sequences ESC [ ... (et sans CR).
fn net(t: &str) -> String {
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

/// Frappe au terminal, un octet a la fois, ecarts pseudo-aleatoires de 100 a 300 ms.
fn taper(s: &mut Sim, t: &[u8], alea: &mut u64) {
    for &c in t {
        s.uart_send(&[c]);
        *alea = alea.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        secs(s, 0.1 + ((*alea >> 33) % 2000) as f64 * 1e-4);
    }
}

fn carte_avec_atmega() -> Sim {
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    s
}

#[test]
fn menu_et_info_par_le_terminal() {
    let mut s = carte_avec_atmega();
    secs(&mut s, 6.0);
    show(&s, "menu");
    let tx = texte_uart(&mut s);
    println!("UART ({} octets) : {}", tx.len(), &tx[..tx.len().min(300)]);
    assert!(tx.contains("Solution-02 BIOS 3.2"), "banniere du BIOS 3.2 absente du terminal");
    assert!(tx.contains("6) BASIC"), "menu absent du terminal");
    s.uart_send(b"4");
    secs(&mut s, 1.0);
    show(&s, "Info (touche 4 au terminal)");
    let l = s.lcd_lines();
    assert!(l[0].contains("BIOS 3.2"), "Info : version");
    assert_eq!(l[2], "AVR04 L0040 P00 FC0 ", "Info : diagnostic de l'ATmega (version 4, 64 octets libres)");
    println!("ATmega : {}", s.atmega_state());
    assert!(s.atmega_state().contains("\"trop_tot\":0"));
}

#[test]
fn dos_de_la_rom_et_collage_rapide() {
    let mut s = carte_avec_atmega();
    secs(&mut s, 6.0);
    texte_uart(&mut s);
    s.atmega_journal();
    s.uart_send(b"1"); // Load DOS au terminal : sans carte, la ROM
    secs(&mut s, 4.0);
    show(&s, "apres 1");
    let j = s.atmega_journal();
    let l: Vec<&str> = j.lines().collect();
    println!("journal ({} transactions) : {:?} ... {:?}", l.len(), &l[..l.len().min(40)], &l[l.len().saturating_sub(10)..]);
    println!("ATmega : {}", s.atmega_state());
    s.uart_send(b"\r");
    secs(&mut s, 2.0);
    s.uart_send(b"\r");
    secs(&mut s, 2.0);
    show(&s, "invite");
    println!("terminal : {:?}", net(&texte_uart(&mut s)));
    let mut alea = 7;
    taper(&mut s, b"dir\r", &mut alea);
    secs(&mut s, 6.0);
    let tx = texte_uart(&mut s);
    println!("dir : {}", net(&tx));
    assert!(tx.contains("COMMAND"), "DIR n'a pas liste COMMAND.COM");
    // 100 caracteres colles d'un trait (9600 bauds, sans pause) : l'UART logiciel en perdait
    let mut ligne = b"echo ".to_vec();
    for i in 0..100u32 {
        ligne.push(b"abcdefghijklmnopqrstuvwxyz0123456789"[(i % 36) as usize]);
    }
    s.uart_send(&ligne);
    s.uart_send(b"\r");
    secs(&mut s, 6.0);
    let tx = net(&texte_uart(&mut s));
    let attendu = String::from_utf8_lossy(&ligne[5..]).into_owned();
    println!("collage : {:?}", tx);
    println!("ATmega : {} ; {}", s.atmega_state(), s.stats());
    assert!(tx.contains(&format!("{}\n{}", String::from_utf8_lossy(&ligne), attendu)),
            "collage rapide : ligne tapee ou resultat d'ECHO incomplet");
}

#[test]
fn cpm86_sur_c_avec_atmega() {
    let Some(c) = image("CPM86_C.IMG") else {
        println!("image absente : essai saute");
        return;
    };
    let mut s = carte_avec_atmega();
    s.sd_add_file("CPM86_C.IMG", &c);
    s.sd_insert_built();
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x16);
    secs(&mut s, 8.0);
    for _ in 0..2 {
        etendue(&mut s, 0x72);
        secs(&mut s, 0.5);
    }
    texte_uart(&mut s);
    appuyer(&mut s, 0x5A);
    secs(&mut s, 40.0);
    show(&s, "demarrage de C:");
    let tx = texte_uart(&mut s);
    let mut alea = 11;
    taper(&mut s, b"dir\r", &mut alea);
    secs(&mut s, 10.0);
    taper(&mut s, b"stat\r", &mut alea);
    secs(&mut s, 15.0);
    let t = net(&texte_uart(&mut s));
    println!("texte : {}", t);
    println!("ATmega : {}", s.atmega_state());
    assert!(tx.contains("Version 1.1"), "CP/M-86 1.1 n'a pas demarre depuis C:");
    assert!(t.contains("HDMAINT  CMD") && t.contains("HELP     HLP"), "DIR de C: incomplet");
    assert!(t.contains("C: RW, Free Space:"), "STAT de C: absent");
}

/// ELKS (PC-DOS/ELKS-0.9.2/fd360-minix-s02.img, hors de git) : avec l'UART logiciel, 2-3 %
/// des frappes se perdaient. Avec l'ATmega : frappe irreguliere et lignes collees, sans perte.
#[test]
fn elks_sans_perte() {
    let Some(img) = image("ELKS-0.9.2/fd360-minix-s02.img") else {
        println!("image absente : essai saute");
        return;
    };
    let mut s = carte_avec_atmega();
    s.sd_add_file("ELKS.IMG", &img);
    s.sd_insert_built();
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x16);
    secs(&mut s, 8.0);
    etendue(&mut s, 0x72);
    secs(&mut s, 0.5);
    appuyer(&mut s, 0x5A);
    secs(&mut s, 70.0);
    let tx = texte_uart(&mut s);
    println!("demarrage : ...{}", &tx[tx.len().saturating_sub(80)..]);
    assert!(tx.contains("login:"), "ELKS n'a pas demarre");
    let mut alea = 12345;
    taper(&mut s, b"root\r", &mut alea);
    secs(&mut s, 15.0);
    texte_uart(&mut s);
    let lignes: [&[u8]; 4] = [
        b"echo un deux trois quatre cinq six sept huit neuf dix",
        b"echo onze douze treize quatorze quinze seize dix-sept",
        b"echo the quick brown fox jumps over the lazy dog 0123456789",
        b"echo un deux trois quatre cinq six sept huit neuf dix",
    ];
    let mut fautes = 0;
    for (i, l) in lignes.iter().enumerate() {
        if i % 2 == 0 {
            taper(&mut s, l, &mut alea);
            taper(&mut s, b"\r", &mut alea);
        } else {
            s.uart_send(l); // collee d'un trait
            s.uart_send(b"\r");
            secs(&mut s, 3.0);
        }
        secs(&mut s, 8.0);
        let t = net(&texte_uart(&mut s));
        let mot = String::from_utf8_lossy(&l[5..]).into_owned();
        let ok = t.contains(&format!("{}\n", String::from_utf8_lossy(l))) && t.contains(&format!("\n{}\n", mot));
        println!("{} {:?}", if ok { "OK  " } else { "FAUX" }, t);
        if !ok {
            fautes += 1;
        }
    }
    println!("ATmega : {}", s.atmega_state());
    assert_eq!(fautes, 0, "caracteres perdus ou faux sous ELKS");
}

/// Menu 8) : sous-menu des vitesses de l'UART (57600 a la mise sous tension). Echap : rien ne
/// change ; 2) 19200 au terminal (annonce a l'ancienne vitesse, le terminal suit), Info lisible a
/// 19200 ; RESET : la vitesse est gardee (IDENT) ; 5) 115200 bauds.
#[test]
fn vitesse_uart_menu_8() {
    let mut s = carte_avec_atmega();
    secs(&mut s, 6.0);
    texte_uart(&mut s);
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)57600 9)WiFi");
    s.uart_send(b"8");
    secs(&mut s, 1.0);
    show(&s, "sous-menu des vitesses");
    let l = s.lcd_lines();
    assert_eq!(l[0], "Vitesse UART: 57600 ");
    assert_eq!(l[1], "1) 9600     2) 19200");
    assert_eq!(l[3], "5) 115200 Echap=menu");
    assert!(net(&texte_uart(&mut s)).contains("3) 38400    4) 57600"), "sous-menu au terminal");
    s.uart_send(b"\x1b"); // Echap : retour, vitesse inchangee
    secs(&mut s, 1.0);
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)57600 9)WiFi");
    assert!(s.atmega_state().contains("\"baud\":57600"));
    texte_uart(&mut s);
    s.uart_send(b"8");
    secs(&mut s, 1.0);
    s.uart_send(b"2");
    secs(&mut s, 1.0);
    let t = texte_uart(&mut s);
    println!("touche 8 : {:?}", net(&t));
    assert!(t.contains("UART : 19200 bauds"), "annonce de la vitesse");
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)19200 9)WiFi");
    assert!(s.atmega_state().contains("\"baud\":19200"));
    s.uart_send(b"4");
    secs(&mut s, 1.0);
    let t = net(&texte_uart(&mut s));
    assert!(t.contains("SOLUTION-02 BIOS 3.2"), "Info lisible a 19200 bauds : {:?}", t);
    s.uart_send(b"x");
    secs(&mut s, 0.5);
    // RESET : l'ATmega garde sa vitesse, le BIOS la relit (IDENT, version 2)
    s.reset_button(true);
    secs(&mut s, 0.1);
    s.reset_button(false);
    texte_uart(&mut s);
    secs(&mut s, 6.0);
    let t = texte_uart(&mut s);
    show(&s, "apres RESET");
    assert!(t.contains("Solution-02 BIOS 3.2"), "banniere a 19200 apres RESET");
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)19200 9)WiFi");
    s.uart_send(b"8");
    secs(&mut s, 1.0);
    assert_eq!(s.lcd_lines()[0], "Vitesse UART: 19200 ");
    s.uart_send(b"5");
    secs(&mut s, 1.0);
    show(&s, "115200");
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)115k2 9)WiFi");
    texte_uart(&mut s);
    s.uart_send(b"4");
    secs(&mut s, 1.0);
    let t = net(&texte_uart(&mut s));
    println!("ATmega : {}", s.atmega_state());
    println!("a 115200 : {:?} ; LCD {:?} ; journal {}", t, s.lcd_lines(), s.take_log());
    assert!(t.contains("SOLUTION-02 BIOS 3.2"), "Info lisible a 115200 bauds : {:?}", t);
    assert!(s.atmega_state().contains("\"baud\":115200"));
}

/// ELKS (image sans Ethernet : ses sondes en 300h/330h/240h tombaient sur le LCD, U12 et la
/// 8253) : les sequences ANSI envoyees au terminal (clear, edition de ligne) sont interpretees par
/// le BIOS 3.2 au lieu d'apparaitre au LCD ; aucune commande parasite au LCD.
#[test]
fn elks_lcd_sans_sequences() {
    let Some(img) = image("ELKS-0.9.2/fd360-minix-s02.img") else {
        println!("image absente : essai saute");
        return;
    };
    let mut s = carte_avec_atmega();
    s.sd_add_file("ELKS.IMG", &img);
    s.sd_insert_built();
    secs(&mut s, 6.0);
    appuyer(&mut s, 0x16);
    secs(&mut s, 8.0);
    etendue(&mut s, 0x72);
    secs(&mut s, 0.5);
    appuyer(&mut s, 0x5A);
    secs(&mut s, 70.0);
    let mut alea = 99;
    taper(&mut s, b"root\r", &mut alea);
    secs(&mut s, 15.0);
    let sequence = |l: &str| {
        l.contains('\x1b') || l.as_bytes().windows(3).any(|w| w[0] == b'[' && w[1].is_ascii_digit())
    };
    let mut journal = s.take_log();
    taper(&mut s, b"ls /bin\r", &mut alea);
    secs(&mut s, 8.0);
    show(&s, "apres ls /bin");
    let longue = b"echo un deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze quinze seize";
    s.uart_send(longue); // collee d'un trait : depasse 80 colonnes, le shell reaffiche la ligne
    secs(&mut s, 4.0);
    show(&s, "longue ligne (plus de 80 colonnes)");
    for l in s.lcd_lines() {
        assert!(!sequence(&l), "sequence ANSI au LCD : {:?}", l);
    }
    s.uart_send(b"\r");
    secs(&mut s, 6.0);
    show(&s, "apres la longue ligne");
    for l in s.lcd_lines() {
        assert!(!sequence(&l), "sequence ANSI au LCD : {:?}", l);
    }
    journal.push_str(&s.take_log());
    let lcd: Vec<&str> = journal.lines().filter(|l| l.starts_with("LCD")).collect();
    println!("alertes du LCD : {:?}", lcd);
    assert!(lcd.is_empty(), "commandes parasites au LCD : {:?}", lcd);
}

/// Sequences ANSI au LCD, depuis le BASIC de la ROM (PRINT CHR$(27);"[...") : ESC [ 2 J + ESC [ H
/// (effacement, curseur en haut), ESC [ n D + ESC [ K (fin de ligne effacee), ESC [ n C.
#[test]
fn ansi_au_lcd_depuis_le_basic() {
    let mut s = Sim::new(&rom());
    secs(&mut s, 6.0);
    s.uart_send(b"6");
    secs(&mut s, 3.0);
    let mut alea = 5;
    for _ in 0..3 {
        taper(&mut s, b"PRINT \"XXXXXXXXXXXXXXXXXX\"\r", &mut alea);
    }
    taper(&mut s, b"PRINT CHR$(27);\"[2J\";CHR$(27);\"[H\";\"HAUT\";\r", &mut alea);
    secs(&mut s, 2.0);
    show(&s, "ESC [ 2 J, ESC [ H");
    let l = s.lcd_lines();
    assert!(l[0].starts_with("HAUT"), "HAUT en haut a gauche : {:?}", l);
    assert!(!l.iter().any(|x| x.contains("XXXX")), "ecran efface : {:?}", l);
    taper(&mut s, b"PRINT \"ABCDEFGH\";CHR$(27);\"[4D\";CHR$(27);\"[K\";CHR$(27);\"[2C\";\"Z\"\r", &mut alea);
    secs(&mut s, 2.0);
    show(&s, "ESC [ 4 D, ESC [ K, ESC [ 2 C");
    let l = s.lcd_lines();
    assert!(l.iter().any(|x| x.starts_with("ABCD  Z")), "ABCD, fin effacee, Z deux colonnes plus loin : {:?}", l);
    for x in &l {
        assert!(!x.contains('[') && !x.contains('\x1b'), "sequence au LCD : {:?}", x);
    }
}

/// Menu 9) : le terminal parle au module Wi-Fi (canal 2 de l'ATmega, commandes AT a 115200
/// bauds) : "AT" Entree -> le module recoit "AT", sa reponse (echo et OK) revient au terminal et
/// au LCD ; Echap ramene au menu. Puis INT 14h DX = 1 depuis le BASIC n'est pas accessible :
/// on verifie seulement l'etat de l'ATmega (115200 bauds au canal 2).
#[test]
fn wifi_menu_9() {
    let mut s = carte_avec_atmega();
    secs(&mut s, 6.0);
    texte_uart(&mut s);
    s.uart_send(b"9");
    secs(&mut s, 1.0);
    show(&s, "menu 9");
    assert_eq!(s.lcd_lines()[0], "WIFI AT  Echap=menu ");
    let t = texte_uart(&mut s);
    assert!(t.contains("module AT (115200 bauds)"), "annonce au terminal : {:?}", t);
    s.uart_send(b"AT\r");
    secs(&mut s, 1.0);
    let t = texte_uart(&mut s);
    show(&s, "apres AT");
    println!("terminal : {:?} ; module : {:?}", t, s.wifi_journal());
    assert!(s.wifi_journal().lines().any(|l| l == "AT"), "le module a recu AT");
    assert!(t.contains("AT\r\n\r\nOK\r\n"), "reponse du module au terminal : {:?}", t);
    let l = s.lcd_lines();
    assert!(l[1].starts_with("AT") && l[2].starts_with("OK"), "LCD : {:?}", l);
    s.uart_send(b"AT+GMR\r");
    secs(&mut s, 1.0);
    let t = texte_uart(&mut s);
    assert!(t.contains("AT version:"), "AT+GMR : {:?}", t);
    s.uart_send(b"\x1b");
    secs(&mut s, 1.5);
    show(&s, "retour au menu");
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)57600 9)WiFi");
    assert!(s.atmega_state().contains("\"baud2\":115200"));
}

/// Menu 9), Ctrl+B : pont terminal <-> module (PONT, ATmega version 4). Le terminal passe a
/// 115200 bauds ; ce qu'il envoie va tel quel au module (sans le 8088) et la reponse revient ;
/// Echap au clavier PS/2 termine le pont et rend 57600 bauds.
#[test]
fn wifi_pont_ctrl_b() {
    let mut s = carte_avec_atmega();
    secs(&mut s, 6.0);
    s.uart_send(b"9");
    secs(&mut s, 1.0);
    texte_uart(&mut s);
    s.uart_send(b"\x02");
    secs(&mut s, 1.0);
    show(&s, "pont");
    let t = texte_uart(&mut s);
    assert!(t.contains("Pont terminal <-> module Wi-Fi a 115200"), "annonce : {:?}", t);
    assert_eq!(s.lcd_lines()[0], "PONT terminal-WiFi  ");
    assert!(s.atmega_state().contains("\"baud\":115200"), "{}", s.atmega_state());
    s.term_baud(115200);
    s.uart_send(b"AT+GMR\r\n");
    secs(&mut s, 0.5);
    let t = texte_uart(&mut s);
    println!("pont : {:?} ; module : {:?}", t, s.wifi_journal());
    assert!(s.wifi_journal().lines().any(|l| l == "AT+GMR"), "le module a recu AT+GMR");
    assert!(t.contains("AT version:"), "reponse du module au terminal : {:?}", t);
    appuyer(&mut s, 0x76); // Echap au clavier PS/2
    secs(&mut s, 1.0);
    s.term_baud(57600);
    secs(&mut s, 2.0);
    show(&s, "apres le pont");
    assert!(s.atmega_state().contains("\"baud\":57600"), "{}", s.atmega_state());
    assert_eq!(s.lcd_lines()[1], "2)RAM 8)57600 9)WiFi");
}
