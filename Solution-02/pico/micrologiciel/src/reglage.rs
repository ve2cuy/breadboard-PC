//! Reglage du Wi-Fi : garde dans le dernier secteur de la flash (4 Ko), change par la console
//! (UART1, J15 : 115200 bauds, 3,3 V) ou par le 8088 (commandes 30h-32h du coeur).
//!
//! Console : `ssid NOM`, `mdp MOT_DE_PASSE`, `connecter` (garde en flash et joint le reseau),
//! `etat` (Wi-Fi, adresses, compteurs du coeur), `aide`.

use core::cell::RefCell;
use core::fmt::Write as _;

use cyw43::JoinOptions;
use embassy_net::Stack;
use embassy_rp::flash::{Blocking, Flash};
use embassy_rp::peripherals::FLASH;
use embassy_rp::uart::BufferedUart;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::blocking_mutex::Mutex;
use embassy_sync::signal::Signal;
use embassy_time::Timer;
use embedded_io_async::{Read, Write};
use heapless::{String, Vec};
use s02pico_coeur::DeHote;

use crate::liaison::VERS_COEUR;

const TAILLE_FLASH: usize = 2 * 1024 * 1024;
const DECALAGE: u32 = (TAILLE_FLASH - 4096) as u32;
const MAGIQUE: &[u8; 4] = b"S02W";

struct Reglage {
    ssid: Vec<u8, 32>,
    mdp: Vec<u8, 64>,
}

static REGLAGE: Mutex<CriticalSectionRawMutex, RefCell<Reglage>> =
    Mutex::new(RefCell::new(Reglage { ssid: Vec::new(), mdp: Vec::new() }));
static FLASH_: Mutex<CriticalSectionRawMutex, RefCell<Option<Flash<'static, FLASH, Blocking, TAILLE_FLASH>>>> =
    Mutex::new(RefCell::new(None));
static REJOINDRE: Signal<CriticalSectionRawMutex, ()> = Signal::new();

/// Lit le reglage garde ; joint le reseau s'il y en a un.
pub fn init(mut f: Flash<'static, FLASH, Blocking, TAILLE_FLASH>) {
    let mut b = [0u8; 4 + 2 + 32 + 64];
    let _ = f.blocking_read(DECALAGE, &mut b);
    if &b[..4] == MAGIQUE {
        let n1 = (b[4] as usize).min(32);
        let n2 = (b[5] as usize).min(64);
        REGLAGE.lock(|r| {
            let mut r = r.borrow_mut();
            r.ssid = Vec::from_slice(&b[6..6 + n1]).unwrap_or_default();
            r.mdp = Vec::from_slice(&b[38..38 + n2]).unwrap_or_default();
        });
        if n1 > 0 {
            REJOINDRE.signal(());
        }
    }
    FLASH_.lock(|x| *x.borrow_mut() = Some(f));
}

/// Nouveau reglage (garde en flash si `garder`), puis connexion.
pub fn changer(ssid: &[u8], mdp: &[u8], garder: bool) {
    REGLAGE.lock(|r| {
        let mut r = r.borrow_mut();
        r.ssid = Vec::from_slice(&ssid[..ssid.len().min(32)]).unwrap_or_default();
        r.mdp = Vec::from_slice(&mdp[..mdp.len().min(64)]).unwrap_or_default();
    });
    if garder {
        let mut b = [0xFFu8; 256];
        b[..4].copy_from_slice(MAGIQUE);
        REGLAGE.lock(|r| {
            let r = r.borrow();
            b[4] = r.ssid.len() as u8;
            b[5] = r.mdp.len() as u8;
            b[6..6 + r.ssid.len()].copy_from_slice(&r.ssid);
            b[38..38 + r.mdp.len()].copy_from_slice(&r.mdp);
        });
        // le coeur 1 est mis en pause par embassy-rp pendant l'ecriture (le 8088 attend : READY)
        FLASH_.lock(|x| {
            if let Some(f) = x.borrow_mut().as_mut() {
                let _ = f.blocking_erase(DECALAGE, DECALAGE + 4096);
                let _ = f.blocking_write(DECALAGE, &b);
            }
        });
    }
    REJOINDRE.signal(());
}

/// Joint le reseau regle, annonce l'adresse au coeur, recommence en cas d'echec.
#[embassy_executor::task]
pub async fn wifi_tache(mut control: cyw43::Control<'static>, stack: Stack<'static>) {
    loop {
        REJOINDRE.wait().await;
        let (ssid, mdp) = REGLAGE.lock(|r| {
            let r = r.borrow();
            (r.ssid.clone(), r.mdp.clone())
        });
        let nom = core::str::from_utf8(&ssid).unwrap_or("");
        loop {
            let opt = if mdp.is_empty() { JoinOptions::new_open() } else { JoinOptions::new(&mdp) };
            if control.join(nom, opt).await.is_ok() {
                break;
            }
            VERS_COEUR.send(DeHote::Wifi { connecte: false, ip: [0; 4], rssi: 0 }).await;
            Timer::after_secs(5).await;
            if REJOINDRE.signaled() {
                break;
            }
        }
        stack.wait_config_up().await;
        let ip = stack.config_v4().map(|c| c.address.address().octets()).unwrap_or([0; 4]);
        let rssi = control.get_rssi().await.clamp(-127, 0) as i8;
        VERS_COEUR.send(DeHote::Wifi { connecte: true, ip, rssi }).await;
    }
}

/// Console de reglage sur UART1 (J15).
#[embassy_executor::task]
pub async fn console_tache(mut u: BufferedUart, stack: Stack<'static>) {
    let _ = u.write_all(b"\r\nPico W de Solution-02 - console (aide)\r\n> ").await;
    let mut ligne: Vec<u8, 100> = Vec::new();
    let mut ssid: Vec<u8, 32> = Vec::new();
    let mut mdp: Vec<u8, 64> = Vec::new();
    loop {
        let mut b = [0u8; 1];
        if u.read(&mut b).await.is_err() {
            continue;
        }
        match b[0] {
            b'\r' | b'\n' => {
                let _ = u.write_all(b"\r\n").await;
                let l = core::str::from_utf8(&ligne).unwrap_or("").trim();
                let mut rep: String<256> = String::new();
                if let Some(x) = l.strip_prefix("ssid ") {
                    ssid = Vec::from_slice(&x.as_bytes()[..x.len().min(32)]).unwrap_or_default();
                    let _ = write!(rep, "ssid : {}", x);
                } else if let Some(x) = l.strip_prefix("mdp ") {
                    mdp = Vec::from_slice(&x.as_bytes()[..x.len().min(64)]).unwrap_or_default();
                    let _ = write!(rep, "mot de passe regle ({} caracteres)", x.len());
                } else if l == "connecter" {
                    changer(&ssid, &mdp, true);
                    let _ = write!(rep, "garde en flash ; connexion...");
                } else if l == "etat" {
                    let ip = stack.config_v4().map(|c| c.address.address().octets()).unwrap_or([0; 4]);
                    let (sd, pq, tcp) = crate::avec_coeur(|c| {
                        (c.stats.sd_lus, c.reseau.stats.paquets_8088, c.reseau.connexions())
                    });
                    let _ = write!(
                        rep,
                        "Wi-Fi {} {}.{}.{}.{} ; secteurs lus {} ; paquets du 8088 {} ; connexions TCP {}",
                        if stack.is_config_up() { "connecte" } else { "deconnecte" },
                        ip[0], ip[1], ip[2], ip[3], sd, pq, tcp
                    );
                } else if !l.is_empty() {
                    let _ = write!(rep, "commandes : ssid NOM, mdp MOT, connecter, etat");
                }
                ligne.clear();
                if !rep.is_empty() {
                    let _ = u.write_all(rep.as_bytes()).await;
                    let _ = u.write_all(b"\r\n").await;
                }
                let _ = u.write_all(b"> ").await;
            }
            8 | 127 => {
                if ligne.pop().is_some() {
                    let _ = u.write_all(b"\x08 \x08").await;
                }
            }
            c if c >= 32 => {
                if ligne.push(c).is_ok() {
                    let _ = u.write_all(&[c]).await;
                }
            }
            _ => {}
        }
    }
}
