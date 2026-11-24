//! ELKS 0.9.2 sur disque dur (C:) : image de 32 Mo, systeme de fichiers MINIX, tous les
//! programmes et le compilateur C natif C86 (elks/construire-hd.sh). Carte avec l'ATmega U17.
//! cargo test --release --test elks_hd -- --nocapture

use s02picosim::{Sim, CLK_HZ};

fn rom() -> Vec<u8> {
    // S02_ROM : autre ROM a essayer (sinon celle de l'interface)
    let p = std::env::var("S02_ROM").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios.bin").to_string()
    });
    std::fs::read(p).expect("ROM")
}

fn secs(s: &mut Sim, t: f64) {
    s.run(t * CLK_HZ);
}

fn show(s: &Sim, titre: &str) {
    println!("--- {}", titre);
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

/// Une commande au terminal (collee d'un trait : l'ATmega ne perd rien), puis attente.
fn commande(s: &mut Sim, c: &str, t: f64) -> String {
    s.uart_send(c.as_bytes());
    s.uart_send(b"\r");
    secs(s, t);
    let r = texte(s);
    println!("$ {}\n{}", c, r);
    r
}

#[test]
fn elks_disque_dur_et_c86() {
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/ELKS-0.9.2/hd32-minix-s02.img");
    let Ok(img) = std::fs::read(p) else {
        println!("image absente : essai saute");
        return;
    };
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
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
    show(&s, "demarrage depuis C:");
    let t = texte(&mut s);
    println!("{}", t);
    assert!(t.contains("login:"), "ELKS n'a pas demarre depuis C:");
    // BIOS 2.8 et suivants : partition MINIX sur C: -> pas de disque B: en RAM, 507 Ko annonces
    assert!(t.contains("506K ram"), "memoire vue par ELKS (507 Ko attendus)");
    commande(&mut s, "root", 15.0);
    let r = commande(&mut s, "df", 10.0);
    assert!(r.contains("/"), "df");
    let r = commande(&mut s, "ls /usr/bin", 10.0);
    for p in ["c86", "cpp", "as", "ld", "make"] {
        assert!(r.contains(p), "{} absent de /usr/bin", p);
    }
    commande(&mut s, "ls /bin | wc -l", 10.0);
    commande(&mut s, "ls /bin", 15.0);
    commande(&mut s, "ls / /usr /usr/lib /root /lib", 15.0);
    commande(&mut s, "ls /usr/include", 5.0);
    let r = commande(&mut s, "top", 6.0);
    assert!(r.contains("PID") && r.contains("COMMAND"), "top");
    s.uart_send(&[3]); // Ctrl-C
    secs(&mut s, 3.0);
    let r = commande(&mut s, "echo fin de top", 3.0);
    assert!(r.contains("fin de top"), "top ne s'arrete pas par Ctrl-C");
    // hello.c, compile sur le 8088 par C86
    s.uart_send(b"cat > hello.c\r");
    secs(&mut s, 3.0);
    s.uart_send(b"#include <stdio.h>\rint main(void) { printf(\"Bonjour %d\\n\", 6 * 7); return 0; }\r");
    secs(&mut s, 3.0);
    s.uart_send(&[4]); // Ctrl-D
    secs(&mut s, 3.0);
    commande(&mut s, "cat hello.c", 5.0);
    commande(&mut s, "cpp -0 -I/usr/include -I/usr/include/c86 hello.c -o hello.i", 120.0);
    commande(&mut s, "c86 -O -bas86 -separate=yes -lang=c99 -stackcheck=no hello.i hello.as", 240.0);
    commande(&mut s, "as -0 -j hello.as -o hello.o", 120.0);
    commande(&mut s, "ld -0 -i -L/usr/lib -o hello hello.o -lc86", 120.0);
    let r = commande(&mut s, "./hello", 20.0);
    show(&s, "apres ./hello");
    assert!(r.contains("Bonjour 42"), "hello.c compile par C86 : {:?}", r);
}
