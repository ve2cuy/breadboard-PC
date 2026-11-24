//! Mesure du SPI logiciel du BIOS (8088 <-> ATmega U17) : un petit programme place en 7000:0000
//! ecrit 200 octets au module Wi-Fi (INT 14h DX=1 AH=09h), le module simule (commandes AT) les
//! renvoie en echo, puis le programme les relit (AH=08h). Cycles par octet de chaque appel.
//! Lecture de secteurs de la carte SD : INT 13h sur C: (image de 20 Mo), 16 secteurs.
//! cargo test --release --test spi_mesure -- --nocapture

use s02picosim::{Sim, CLK_HZ};
use std::process::Command;

const PROGRAMME: &str = r#"
cpu 8086
org 0
debut:  push    cs
        pop     ds
        push    cs
        pop     es
        mov     bx, tampon
        mov     cx, 200
        mov     dx, 1
        mov     ah, 09h
        int     14h                     ; 200 octets vers le module
        mov     [ecrits], cx
p1:     nop                             ; (point d'arret 1)
        mov     cx, 30000               ; l'echo revient a 115200 bauds (~20 ms)
.att:   loop    .att
p2:     nop                             ; (point d'arret 2)
        mov     bx, tampon2
        mov     cx, 255
        mov     dx, 1
        mov     ah, 08h
        int     14h                     ; relit l'echo
        mov     [lus], cx
p3:     nop                             ; (point d'arret 3)
        mov     ax, 0201h               ; INT 13h : lit 1 secteur de C: (cylindre 0, tete 1,
        mov     cx, 0001h               ; secteur 1 : debut de la partition)
        mov     dx, 0180h
        mov     bx, tampon3
        int     13h
        mov     ax, 0210h               ; puis 16 secteurs (cylindre 0, tete 1, secteur 2)
        mov     cx, 0002h
        mov     dx, 0180h
        mov     bx, tampon3
p4:     int     13h
p5:     nop
.fin:   jmp     .fin
ecrits: dw      0
lus:    dw      0
tampon: times 200 db 'a'
tampon2: times 256 db 0
tampon3:
"#;

fn programme() -> Option<Vec<u8>> {
    let dir = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    let asm = dir.join("spi_mesure.asm");
    let bin = dir.join("spi_mesure.bin");
    let lst = dir.join("spi_mesure.lst");
    std::fs::write(&asm, PROGRAMME).ok()?;
    let ok = Command::new("nasm").args(["-f", "bin", "-l"]).arg(&lst).arg(&asm).arg("-o").arg(&bin)
        .status().map(|s| s.success()).unwrap_or(false);
    if !ok {
        return None;
    }
    std::fs::read(&bin).ok()
}

fn rom() -> Vec<u8> {
    let p = std::env::var("S02_ROM").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/www/roms/solution-02-bios.bin").to_string()
    });
    std::fs::read(p).expect("ROM")
}

/// Adresse (decalage) d'une etiquette dans le listage nasm.
fn etiquette(nom: &str) -> u32 {
    let dir = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    let l = std::fs::read_to_string(dir.join("spi_mesure.lst")).unwrap();
    let mut prec = 0u32;
    for ligne in l.lines() {
        let champs: Vec<&str> = ligne.split_whitespace().collect();
        if champs.len() >= 3 {
            if let Ok(a) = u32::from_str_radix(champs[1], 16) {
                prec = a;
            }
        }
        if ligne.contains(&format!("{}:", nom)) {
            // l'instruction suit l'etiquette (ou est sur la meme ligne)
            if champs.len() >= 3 && u32::from_str_radix(champs[1], 16).is_ok() {
                return u32::from_str_radix(champs[1], 16).unwrap();
            }
            return prec;
        }
    }
    panic!("etiquette {}", nom)
}

#[test]
fn spi_cycles_par_octet() {
    let Some(p) = programme() else {
        println!("nasm absent : essai saute");
        return;
    };
    let mut s = Sim::new(&rom());
    s.set_atmega(true);
    if let Ok(img) = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../../PC-DOS/DOSNET_C.IMG")) {
        s.sd_add_file("DOSNET_C.IMG", &img);
        s.sd_insert_built();
    }
    s.run(6.0 * CLK_HZ);                    // menu du BIOS
    s.wifi_slip(false);
    for (i, b) in p.iter().enumerate() {
        s.poke(0x70000 + i as u32, *b);
    }
    s.set_reg(9, 0x7000);                   // CS
    s.set_reg(12, 0);                       // IP
    let base = 0x70000u32;
    let mut temps = Vec::new();
    for nom in ["p1", "p2", "p3", "p4", "p5"] {
        let t0 = s.cycles();
        s.set_breakpoints(vec![base + etiquette(nom)]);
        let r = s.run(30.0 * CLK_HZ);
        assert_eq!(r, 1, "point d'arret {} non atteint", nom);
        temps.push(s.cycles() - t0);
        s.set_breakpoints(vec![]);
        s.step();
    }
    let ecrits = u16::from_le_bytes([s.peek(base + etiquette("ecrits"), 2)[0], s.peek(base + etiquette("ecrits"), 2)[1]]);
    let lus = u16::from_le_bytes([s.peek(base + etiquette("lus"), 2)[0], s.peek(base + etiquette("lus"), 2)[1]]);
    let us = |c: f64| c / CLK_HZ * 1e6;
    println!("ecriture : {} octets en {:.0} cycles = {:.1} us/octet", ecrits, temps[0], us(temps[0]) / ecrits.max(1) as f64);
    println!("lecture  : {} octets en {:.0} cycles = {:.1} us/octet", lus, temps[2], us(temps[2]) / lus.max(1) as f64);
    println!("INT 13h 16 secteurs : {:.0} cycles = {:.1} ms, {:.1} us/octet", temps[4], us(temps[4]) / 1000.0,
             us(temps[4]) / (16.0 * 512.0));
    assert_eq!(ecrits, 200);
    assert!(lus >= 200, "echo du module : {} octets", lus);
    let t2 = s.peek(base + etiquette("tampon2"), lus as u32);
    assert!(t2[lus as usize - 200..].iter().all(|&b| b == b'a'), "echo altere : {:?}",
            String::from_utf8_lossy(&t2));
    println!("ATmega : {}", s.atmega_state());
    assert!(s.atmega_state().contains("\"trop_tot\":0"), "octet SPI pris avant d'etre pret");
}
