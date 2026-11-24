//! Automate PIO du bus du 8088 (RP2040, PIO1 SM0), commun au micrologiciel et a l'essai au
//! cycle pres (tests/pio_bus.rs).
//!
//! Broches (apres U18/U19, en 3,3 V) :
//! - GP0-GP7 : D0-D7 (U18, par RN4 ; U18 tourne vers le bus quand ~RD = 0) ;
//! - GP8-GP10 : A0-A2, GP11 : ~SEL (O5 du 74LS138, ports 50h-5Fh), GP12 : ~RD, GP13 : ~WR,
//!   GP14 : RESET (U19) ;
//! - GP26 : 1 = Q1 conduit, RDY1 du 82C84 a 0 : le 8088 ajoute des etats d'attente.
//!
//! Deroulement :
//! 1. ~SEL tombe (T1 + ~60 ns) : GP26 = 1 tout de suite, le 8088 attendra (RDY1 doit tomber
//!    avant la fin de T2 ; il tombe ~150 ns apres le debut de T1).
//! 2. On attend ~RD ou ~WR (T2).
//! 3. Lecture : A0-A2 vers le coeur 1 (mot : broches << 1, bit 0 = 0) ; il rend l'octet (| FF00h,
//!    pour les directions) ; octet pose, D0-D7 en sortie, puis GP26 = 0 : le 8088 finit son
//!    cycle et lit l'octet. A la remontee de ~RD, D0-D7 repassent en entree.
//! 4. Ecriture : GP26 = 0 tout de suite ; a la remontee de ~WR (donnees encore valides au moins
//!    88 ns, TWHDX du 8088), D0-D7 et A0-A2 vers le coeur 1 (bit 0 = 1).
//!
//! (`mov pindirs` n'existe que sur le RP2350 : les directions passent par `out pindirs`.)
//!
//! Configuration : IN_BASE = OUT_BASE = GP0 (8 broches en sortie), SIDESET_BASE = GP26
//! (1 bit, optionnel), JMP_PIN = GP12 (~RD), ISR decale a gauche, OSR a droite, sans
//! auto-push ni auto-pull.

pub const BROCHE_SEL: u8 = 11;
pub const BROCHE_RD: u8 = 12;
pub const BROCHE_WR: u8 = 13;
pub const BROCHE_RESET: u8 = 14;
pub const BROCHE_IRQ: u8 = 22;
pub const BROCHE_RDY: u8 = 26;

/// Programme assemble (au plus 32 instructions).
pub fn programme() -> pio::Program<32> {
    pio::pio_asm!(
        ".side_set 1 opt",
        ".wrap_target",
        "debut:",
        "    wait 1 gpio 11      side 0", // ~SEL haut : cycle precedent fini, RDY1 libre
        "    wait 0 gpio 11      side 1", // ~SEL bas (T1) : RDY1 a 0
        "quel:",
        "    jmp pin pas_lecture",        // ~RD haut : pas (encore) une lecture
        "    in pins, 11",                // lecture : D0-D7 (sans objet), A0-A2
        "    in null, 1",                 // bit 0 = 0 : lecture
        "    push block",
        "    pull block",                 // octet du coeur 1 | FF00h
        "    out pins, 8",                // octet sur D0-D7
        "    out pindirs, 8",             // D0-D7 en sortie (FFh)
        "    nop                 side 0 [3]", // RDY1 libre : le 8088 lit en fin de T3
        "    wait 1 gpio 12",             // ~RD remonte (T4)
        "    mov osr, null",
        "    out pindirs, 8",             // D0-D7 en entree
        "    jmp debut",
        "pas_lecture:",
        "    mov osr, pins",
        "    out null, 13",               // D0-D7, A0-A2, ~SEL, ~RD
        "    out x, 1",                   // x = ~WR
        "    jmp x-- quel",               // ~WR haut : ni lecture ni ecriture encore
        "    nop                 side 0", // ecriture : RDY1 libre tout de suite
        "    wait 1 gpio 13",             // ~WR remonte (T4) : donnees valides ~88 ns encore
        "    in pins, 11",                // D0-D7, A0-A2
        "    set x, 1",
        "    in x, 1",                    // bit 0 = 1 : ecriture
        "    push block",
        ".wrap",
    )
    .program
}

/// Mot recu du PIO : (ecriture, registre A0-A2, donnee).
pub fn decoder(mot: u32) -> (bool, u8, u8) {
    let broches = mot >> 1;
    (mot & 1 != 0, ((broches >> 8) & 7) as u8, broches as u8)
}
