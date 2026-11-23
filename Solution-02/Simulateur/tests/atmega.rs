//! ATmega328P (U17, schema du 2026-11-21) vu du 8088 : un petit programme (assemble par NASM)
//! parle a l'ATmega par U12 (SPI logiciel, SS = PC0, MISO = PB4) comme le fera le BIOS 2.7.
//! cargo test --release --test atmega -- --nocapture

use s02sim::{Sim, CLK_HZ};
use std::process::Command;

/// Programme d'essai (ROM de 256 Ko, F000:0000). Resultats en 0000:0600.
const PROGRAMME: &str = r#"
cpu 8086
PB      equ 31h
PC      equ 32h
CTL     equ 33h
REPOS   equ 51h                 ; PC0 = 1 (ATmega non selectionne), CS de la SD = 1, MOSI = 1
SEL     equ 50h                 ; PC0 = 0 : ATmega selectionne
MISO    equ 10h                 ; PB4

        times 0 db 0
debut:  cli
        xor     ax, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 7000h
        mov     ax, cs
        mov     ds, ax
        mov     al, 82h
        out     CTL, al
        mov     al, REPOS
        out     PC, al
%ifdef ARRET
        hlt
%endif
        ; 1) IDENT -> 0600h
        mov     si, cmd_ident
        mov     di, 0600h
        mov     cx, 5
        call    trans
        ; 2) ETAT jusqu'a 5 octets recus -> 0610h
        mov     dx, 2000
.att:   mov     si, cmd_etat
        mov     di, 0610h
        mov     cx, 6
        call    trans
        cmp     byte [es:0611h], 5
        jae     .lire
        dec     dx
        jnz     .att
        jmp     fin
        ; 3) LIRE -> 0620h = signature, 0621h = n, 0622h... = octets
.lire:  mov     di, 0620h
        mov     al, SEL
        out     PC, al
        mov     al, 02h
        call    spi
        stosb
        call    pause
        xor     al, al
        call    spi
        stosb
        mov     cl, al
        xor     ch, ch
        jcxz    .fl
.l:     call    pause
        xor     al, al
        call    spi
        stosb
        loop    .l
.fl:    mov     al, REPOS
        out     PC, al
        ; 4) ECRIRE "WORLD" -> 0640h
        mov     si, cmd_ecrire
        mov     di, 0640h
        mov     cx, 7
        call    trans
fin:    mov     byte [es:06FFh], 0AAh
        hlt

; trans : CX octets de DS:SI envoyes, recus en ES:DI (une transaction)
trans:  mov     al, SEL
        out     PC, al
.b:     call    pause
        lodsb
        call    spi
        stosb
        loop    .b
        mov     al, REPOS
        out     PC, al
        ret

; pause : ~10 us entre deux octets (l'ATmega prepare le suivant)
pause:
%ifdef SANS_PAUSE
        ret
%endif
        push    cx
        mov     cx, 4
.p:     loop    .p
        pop     cx
        ret

; spi : envoie AL, rend l'octet recu (mode 0, poids fort en premier ; MISO = PB4)
spi:    push    bx
        push    cx
        mov     bl, al
        mov     cx, 8
.b:     mov     al, SEL
        shl     bl, 1
        jc      .un
        mov     al, SEL & ~40h
.un:    out     PC, al
        or      al, 20h
        out     PC, al
        in      al, PB
        and     al, MISO
        add     al, 0F0h
        rcl     bh, 1
        loop    .b
        mov     al, SEL
        out     PC, al
        mov     al, bh
        pop     cx
        pop     bx
        ret

cmd_ident:  db 00h, 0, 0, 0, 0
cmd_etat:   db 01h, 0, 0, 0, 0, 0
cmd_ecrire: db 03h, 0, 'WORLD'

        times 0FFF0h - ($ - $$) db 0FFh
        jmp     0F000h:debut
        times 10000h - ($ - $$) db 0FFh
"#;

/// ROM de 256 Ko : le programme dans le dernier bloc de 64 Ko (F000:0000).
fn rom(defs: &[&str]) -> Option<Vec<u8>> {
    let dir = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    let nom = format!("atmega{}", defs.join(""));
    let asm = dir.join(format!("{}.asm", nom));
    let bin = dir.join(format!("{}.bin", nom));
    std::fs::write(&asm, PROGRAMME).ok()?;
    let mut c = Command::new("nasm");
    c.arg("-f").arg("bin");
    for d in defs {
        c.arg(format!("-d{}", d));
    }
    let ok = c.arg(&asm).arg("-o").arg(&bin).status().map(|s| s.success()).unwrap_or(false);
    if !ok {
        return None;
    }
    let p = std::fs::read(&bin).ok()?;
    assert_eq!(p.len(), 0x10000);
    let mut r = vec![0xFFu8; 0x30000];
    r.extend_from_slice(&p);
    Some(r)
}

fn secs(s: &mut Sim, t: f64) {
    s.run(t * CLK_HZ);
}

#[test]
fn atmega_ident_etat_lire_ecrire() {
    let Some(r) = rom(&[]) else {
        println!("nasm absent : essai saute");
        return;
    };
    let mut s = Sim::new(&r);
    s.set_atmega(true);
    secs(&mut s, 0.02);
    let id = s.peek(0x600, 5);
    println!("IDENT : {:02X?}", id);
    assert_eq!(id, vec![0xA5, b'S', b'2', 4, 3], "IDENT");
    s.uart_send(b"hello");
    secs(&mut s, 0.03);
    let etat = s.peek(0x610, 6);
    let lu = s.peek(0x620, 7);
    println!("ETAT : {:02X?} ; LIRE : {:02X?}", etat, lu);
    assert_eq!(etat[0], 0xA5);
    assert_eq!(lu[0], 0xA5);
    assert_eq!(lu[1], 5, "LIRE : nombre annonce");
    assert_eq!(&lu[2..7], b"hello", "LIRE : octets");
    secs(&mut s, 0.02);
    let fin = s.peek(0x6FF, 1)[0];
    let tx = s.uart_take();
    println!("terminal : {:?} ; ATmega : {}", String::from_utf8_lossy(&tx), s.atmega_state());
    assert_eq!(fin, 0xAA, "programme termine");
    assert_eq!(s.peek(0x641, 1)[0], 64, "ECRIRE : place annoncee (64 octets en version 3)");
    assert_eq!(tx, b"WORLD", "emission vers le terminal");
    assert!(s.atmega_state().contains("\"trop_tot\":0"), "le 8088 laisse assez de temps a l'ATmega");
}

/// Sans pause entre les octets (cadence de spi_octet du BIOS) : l'ATmega suit-il ?
#[test]
fn atmega_sans_pause() {
    let Some(r) = rom(&["SANS_PAUSE"]) else {
        println!("nasm absent : essai saute");
        return;
    };
    let mut s = Sim::new(&r);
    s.set_atmega(true);
    secs(&mut s, 0.02);
    s.uart_send(b"hello");
    secs(&mut s, 0.05);
    println!("sans pause : IDENT {:02X?}, LIRE {:02X?}, {}", s.peek(0x600, 5), s.peek(0x620, 7), s.atmega_state());
    assert_eq!(s.peek(0x600, 5), vec![0xA5, b'S', b'2', 4, 3]);
    assert_eq!(&s.peek(0x622, 5)[..], b"hello");
    assert!(s.atmega_state().contains("\"trop_tot\":0"));
}

#[test]
fn atmega_irq4_et_rts() {
    let Some(r) = rom(&["ARRET"]) else {
        println!("nasm absent : essai saute");
        return;
    };
    let mut s = Sim::new(&r);
    s.set_atmega(true);
    secs(&mut s, 0.01);
    assert_eq!(s.irq_state()[4] & 0x10, 0, "IR4 au repos");
    s.uart_send(b"x");
    secs(&mut s, 0.005);
    assert_ne!(s.irq_state()[4] & 0x10, 0, "IR4 : un octet attend");
    // 8088 arrete : le tampon se remplit, RTS retire a 384, le terminal attend (rien de perdu)
    let gros = vec![b'z'; 1100];
    s.uart_send(&gros);
    secs(&mut s, 1.5);
    let st = s.atmega_state();
    println!("apres 1101 octets envoyes : {} ; en attente au terminal : {}", st, s.uart_pending());
    assert!(st.contains("\"rx_nb\":384") || st.contains("\"rx_nb\":385"), "RTS retire vers 384 : {}", st);
    assert!(st.contains("\"rts\":false"));
    assert!(s.uart_pending() > 300, "le terminal garde le reste");
    // variante sans ATmega : l'UART logiciel revient (IR4 = RX inverse)
    s.set_atmega(false);
    assert!(!s.atmega());
}
