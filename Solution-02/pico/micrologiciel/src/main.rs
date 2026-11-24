//! Micrologiciel du Raspberry Pi Pico W de Solution-02 (A1 au schema du 2026-11-23).
//!
//! - Coeur 1 : bus du 8088. L'automate PIO1/SM0 (s02pico_coeur::bus_pio) suit ~SEL, ~RD, ~WR,
//!   tient READY (GP26 -> Q1 -> RDY1) et passe chaque acces au coeur 1, qui le joue sur le
//!   `Coeur` (registres 50h-57h) et rend l'octet lu.
//! - Coeur 0 (embassy) : commandes du `Coeur` (carte microSD de J14 sur SPI0), relais TCP/IP du
//!   8088 vers le Wi-Fi (liaison.rs), GP22 -> IRQ3 (J16), console sur UART1 (J15, 115200 bauds)
//!   pour regler le Wi-Fi.
//!
//! Le meme coeur tourne dans le simulateur (Simulateur-Pico) : voir pico/coeur.

#![no_std]
#![no_main]

extern crate alloc;

mod carte;
mod liaison;
mod reglage;

use core::cell::RefCell;
use core::ptr::addr_of_mut;

use alloc::vec::Vec;
use cyw43_pio::{PioSpi, DEFAULT_CLOCK_DIVIDER};
use embassy_executor::Spawner;
use embassy_net::{Config as NetConfig, StackResources};
use embassy_rp::gpio::{Input, Level, Output, Pull};
use embassy_rp::multicore::{spawn_core1, Stack};
use embassy_rp::peripherals::{DMA_CH0, PIO0, PIO1, UART1};
use embassy_rp::pio::{self, Direction, Pio, ShiftConfig, ShiftDirection};
use embassy_rp::spi::{self, Spi};
use embassy_rp::uart::{self, BufferedUart};
use embassy_rp::{bind_interrupts, dma};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::blocking_mutex::Mutex;
use embassy_time::{Instant, Timer};
use embedded_alloc::LlffHeap as Heap;
use panic_halt as _;
use s02pico_coeur::{bus_pio, Coeur, Limites, VersHote};
use static_cell::StaticCell;

use crate::carte::CarteSd;
use crate::liaison::{CmdTcp, CONNEXIONS};

#[global_allocator]
static HEAP: Heap = Heap::empty();

bind_interrupts!(struct Irqs {
    PIO0_IRQ_0 => pio::InterruptHandler<PIO0>;
    PIO1_IRQ_0 => pio::InterruptHandler<PIO1>;
    UART1_IRQ => uart::BufferedInterruptHandler<UART1>;
    DMA_IRQ_0 => dma::InterruptHandler<DMA_CH0>;
});

/// Le peripherique vu par le 8088 (partage entre les deux coeurs).
static COEUR: Mutex<CriticalSectionRawMutex, RefCell<Option<Coeur>>> = Mutex::new(RefCell::new(None));

pub fn avec_coeur<R>(f: impl FnOnce(&mut Coeur) -> R) -> R {
    COEUR.lock(|c| f(c.borrow_mut().as_mut().unwrap()))
}

static mut PILE_C1: Stack<4096> = Stack::new();

#[embassy_executor::task]
async fn cyw43_tache(r: cyw43::Runner<'static, cyw43::SpiBus<Output<'static>, PioSpi<'static, PIO0, 0>>>) -> ! {
    r.run().await
}

#[embassy_executor::task]
async fn reseau_tache(mut r: embassy_net::Runner<'static, cyw43::NetDriver<'static>>) -> ! {
    r.run().await
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    {
        const TAILLE: usize = 96 * 1024;
        static mut TAS: [u8; TAILLE] = [0; TAILLE];
        #[allow(static_mut_refs)]
        unsafe {
            HEAP.init(TAS.as_ptr() as usize, TAILLE)
        }
    }
    let mut coeur = Coeur::avec(Limites { tcp_tampon: 2048, connexions: CONNEXIONS, vers_8088: 8 * 1024 });
    coeur.reseau.version = concat!("Pico W ", env!("CARGO_PKG_VERSION"));
    COEUR.lock(|c| *c.borrow_mut() = Some(coeur));

    // ---------------------------------------------------------------- bus du 8088 (PIO1)
    let Pio { mut common, sm0: mut sm, .. } = Pio::new(p.PIO1, Irqs);
    let prog = common.load_program(&bus_pio::programme());
    let d = [
        common.make_pio_pin(p.PIN_0),
        common.make_pio_pin(p.PIN_1),
        common.make_pio_pin(p.PIN_2),
        common.make_pio_pin(p.PIN_3),
        common.make_pio_pin(p.PIN_4),
        common.make_pio_pin(p.PIN_5),
        common.make_pio_pin(p.PIN_6),
        common.make_pio_pin(p.PIN_7),
    ];
    let c = [
        common.make_pio_pin(p.PIN_8),
        common.make_pio_pin(p.PIN_9),
        common.make_pio_pin(p.PIN_10),
        common.make_pio_pin(p.PIN_11),
        common.make_pio_pin(p.PIN_12),
        common.make_pio_pin(p.PIN_13),
    ];
    let rdy = common.make_pio_pin(p.PIN_26);
    let mut cfg = pio::Config::default();
    cfg.use_program(&prog, &[&rdy]);
    cfg.set_in_pins(&[&d[0]]);
    cfg.set_out_pins(&[&d[0], &d[1], &d[2], &d[3], &d[4], &d[5], &d[6], &d[7]]);
    cfg.set_jmp_pin(&c[4]); // ~RD
    cfg.shift_in = ShiftConfig { threshold: 32, direction: ShiftDirection::Left, auto_fill: false };
    cfg.shift_out = ShiftConfig { threshold: 32, direction: ShiftDirection::Right, auto_fill: false };
    sm.set_config(&cfg);
    sm.set_pins(Level::Low, &[&rdy]);
    sm.set_pin_dirs(Direction::Out, &[&rdy]);
    sm.set_pin_dirs(Direction::In, &[&d[0], &d[1], &d[2], &d[3], &d[4], &d[5], &d[6], &d[7]]);
    sm.set_pin_dirs(Direction::In, &[&c[0], &c[1], &c[2], &c[3], &c[4], &c[5]]);
    sm.set_enable(true);
    core::mem::forget(d);
    core::mem::forget(c);
    core::mem::forget(rdy);

    // coeur 1 : chaque acces du 8088 joue sur le Coeur
    #[allow(static_mut_refs)]
    spawn_core1(p.CORE1, unsafe { &mut *addr_of_mut!(PILE_C1) }, move || -> ! {
        loop {
            if let Some(m) = sm.rx().try_pull() {
                let (ecriture, reg, v) = bus_pio::decoder(m);
                if ecriture {
                    avec_coeur(|c| c.ecrire_port(reg, v));
                } else {
                    let r = avec_coeur(|c| c.lire_port(reg));
                    while !sm.tx().try_push(r as u32 | 0xFF00) {}
                }
            }
        }
    });

    // ---------------------------------------------------------------- Wi-Fi (CYW43439)
    let pwr = Output::new(p.PIN_23, Level::Low);
    let cs = Output::new(p.PIN_25, Level::High);
    let mut pio0 = Pio::new(p.PIO0, Irqs);
    let spi_wifi = PioSpi::new(
        &mut pio0.common,
        pio0.sm0,
        DEFAULT_CLOCK_DIVIDER,
        pio0.irq0,
        cs,
        p.PIN_24,
        p.PIN_29,
        dma::Channel::new(p.DMA_CH0, Irqs),
    );
    static ETAT: StaticCell<cyw43::State> = StaticCell::new();
    let (net, mut control, runner) =
        cyw43::new(ETAT.init(cyw43::State::new()), pwr, spi_wifi, &cyw43_setup::FW, &cyw43_setup::NVRAM).await;
    spawner.spawn(cyw43_tache(runner).unwrap());
    control.init(cyw43_setup::CLM).await;
    control.set_power_management(cyw43::PowerManagementMode::PowerSave).await;

    static RESSOURCES: StaticCell<StackResources<12>> = StaticCell::new();
    let graine = Instant::now().as_ticks() ^ 0x5302_8088_5302_8088;
    let (stack, runner) =
        embassy_net::new(net, NetConfig::dhcpv4(Default::default()), RESSOURCES.init(StackResources::new()), graine);
    spawner.spawn(reseau_tache(runner).unwrap());
    for n in 0..CONNEXIONS {
        let rx = alloc::boxed::Box::leak(alloc::boxed::Box::new([0u8; 2048]));
        let tx = alloc::boxed::Box::leak(alloc::boxed::Box::new([0u8; 2048]));
        spawner.spawn(liaison::tcp_tache(stack, n, rx, tx).unwrap());
    }
    spawner.spawn(liaison::udp_tache(stack).unwrap());
    spawner.spawn(liaison::ping_tache(stack).unwrap());

    // ---------------------------------------------------------------- console (J15) et reglage
    let flash = embassy_rp::flash::Flash::<_, embassy_rp::flash::Blocking, { 2 * 1024 * 1024 }>::new_blocking(p.FLASH);
    reglage::init(flash);
    static TX_BUF: StaticCell<[u8; 256]> = StaticCell::new();
    static RX_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    let mut ucfg = uart::Config::default();
    ucfg.baudrate = 115_200;
    let console = BufferedUart::new(
        p.UART1,
        p.PIN_20,
        p.PIN_21,
        Irqs,
        TX_BUF.init([0; 256]),
        RX_BUF.init([0; 64]),
        ucfg,
    );
    spawner.spawn(reglage::console_tache(console, stack).unwrap());
    spawner.spawn(reglage::wifi_tache(control, stack).unwrap());

    // ---------------------------------------------------------------- carte SD (J14, SPI0)
    let mut scfg = spi::Config::default();
    scfg.frequency = 400_000;
    let spi_sd = Spi::new_blocking(p.SPI0, p.PIN_18, p.PIN_19, p.PIN_16, scfg);
    let mut carte = CarteSd::new(spi_sd, Output::new(p.PIN_17, Level::High));
    let mut irq = Output::new(p.PIN_22, Level::Low);
    let reset = Input::new(p.PIN_14, Pull::None);

    // ---------------------------------------------------------------- boucle principale
    let mut en_reset = false;
    // connexion du coeur -> tache TCP
    let mut cases: [Option<u16>; CONNEXIONS] = [None; CONNEXIONS];
    loop {
        // RESET du 8088 (U19 -> GP14) : files du coeur videes
        let r = reset.is_high();
        if r && !en_reset {
            avec_coeur(|c| c.reinitialiser());
        }
        en_reset = r;
        while let Ok(m) = liaison::VERS_COEUR.try_receive() {
            avec_coeur(|c| c.reseau.recevoir(m));
        }
        let now = Instant::now().as_millis();
        let (sortants, i) = avec_coeur(|c| {
            c.executer(&mut carte, now);
            c.poll(now);
            let v: Vec<VersHote> = c.reseau.sortants.drain(..).collect();
            (v, c.irq())
        });
        irq.set_level(if i { Level::High } else { Level::Low });
        for m in sortants {
            match m {
                VersHote::TcpOuvrir { id, ip, port } => {
                    if let Some(n) = cases.iter().position(|x| x.is_none()) {
                        cases[n] = Some(id);
                        liaison::TCP[n].send(CmdTcp::Ouvrir { id, ip, port }).await;
                    } else {
                        avec_coeur(|c| c.reseau.recevoir(s02pico_coeur::DeHote::TcpEchec { id }));
                    }
                }
                VersHote::TcpEnvoyer { id, data } => {
                    if let Some(n) = cases.iter().position(|x| *x == Some(id)) {
                        liaison::TCP[n].send(CmdTcp::Envoyer(data)).await;
                    }
                }
                VersHote::TcpFermer { id } => {
                    if let Some(n) = cases.iter().position(|x| *x == Some(id)) {
                        cases[n] = None;
                        liaison::TCP[n].send(CmdTcp::Fermer).await;
                    }
                }
                VersHote::Udp { sport, ip, port, data } => liaison::UDP.send((sport, ip, port, data)).await,
                VersHote::Ping { ip, ident, seq, data } => liaison::PING.send((ip, ident, seq, data)).await,
                VersHote::Wifi { ssid, mdp } => reglage::changer(&ssid, &mdp, true),
            }
        }
        Timer::after_micros(200).await;
    }
}
