//! L'hote du coeur sur le vrai Pico : les messages [`VersHote`] deviennent des connexions
//! embassy-net (Wi-Fi du CYW43439), et leurs evenements reviennent au coeur ([`DeHote`]).
//!
//! - TCP : `CONNEXIONS` taches, chacune une connexion a la fois (`tcp_tache`) ;
//! - UDP (DNS...) : une socket, les reponses rendues au port source du 8088 ;
//! - ping : une socket ICMP (identifiant 5302h, celui du 8088 retabli dans la reponse).

use alloc::vec::Vec;

use embassy_futures::select::{select, Either};
use embassy_net::icmp::{IcmpEndpoint, IcmpSocket, PacketMetadata as IcmpMeta};
use embassy_net::tcp::TcpSocket;
use embassy_net::udp::{PacketMetadata, UdpSocket};
use embassy_net::{IpAddress, IpEndpoint, Ipv4Address, Stack};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::channel::Channel;
use embassy_time::{Duration, Timer};
use s02pico_coeur::DeHote;

/// Connexions TCP simultanees (comme `Limites::connexions` du coeur).
pub const CONNEXIONS: usize = 6;
const TAMPON_TCP: usize = 2048;

pub enum CmdTcp {
    Ouvrir { id: u16, ip: [u8; 4], port: u16 },
    Envoyer(Vec<u8>),
    Fermer,
}

type Canal<T, const N: usize> = Channel<CriticalSectionRawMutex, T, N>;

/// Evenements pour le coeur (la boucle principale les remet a `Reseau::recevoir`).
pub static VERS_COEUR: Canal<DeHote, 24> = Channel::new();
pub static TCP: [Canal<CmdTcp, 8>; CONNEXIONS] = [const { Channel::new() }; CONNEXIONS];
pub static UDP: Canal<(u16, [u8; 4], u16, Vec<u8>), 4> = Channel::new();
pub static PING: Canal<([u8; 4], u16, u16, Vec<u8>), 4> = Channel::new();

fn ip(a: [u8; 4]) -> IpAddress {
    IpAddress::Ipv4(Ipv4Address::new(a[0], a[1], a[2], a[3]))
}

fn octets(a: IpAddress) -> [u8; 4] {
    match a {
        IpAddress::Ipv4(v) => v.octets(),
        #[allow(unreachable_patterns)]
        _ => [0; 4],
    }
}

/// Une connexion TCP a la fois, pilotee par `TCP[n]`.
#[embassy_executor::task(pool_size = CONNEXIONS)]
pub async fn tcp_tache(stack: Stack<'static>, n: usize, rx: &'static mut [u8; TAMPON_TCP], tx: &'static mut [u8; TAMPON_TCP]) {
    loop {
        let (id, a, port) = match TCP[n].receive().await {
            CmdTcp::Ouvrir { id, ip, port } => (id, ip, port),
            _ => continue,
        };
        let mut s = TcpSocket::new(stack, &mut rx[..], &mut tx[..]);
        s.set_timeout(Some(Duration::from_secs(60)));
        if s.connect(IpEndpoint::new(ip(a), port)).await.is_err() {
            VERS_COEUR.send(DeHote::TcpEchec { id }).await;
            continue;
        }
        VERS_COEUR.send(DeHote::TcpOuvert { id }).await;
        let mut buf = [0u8; 512];
        let mut fin_distante = false;
        loop {
            // controle de flux : ne lire la connexion que si le coeur a de la place
            let place = crate::avec_coeur(|c| c.reseau.tcp_place(id));
            if fin_distante || place < buf.len() {
                match select(TCP[n].receive(), Timer::after_millis(5)).await {
                    Either::First(CmdTcp::Envoyer(d)) => {
                        if s.write(&d).await.is_err() {
                            break;
                        }
                    }
                    Either::First(CmdTcp::Fermer) => break,
                    _ => {}
                }
                continue;
            }
            match select(s.read(&mut buf), TCP[n].receive()).await {
                Either::First(Ok(0)) | Either::First(Err(_)) => {
                    fin_distante = true;
                    VERS_COEUR.send(DeHote::TcpFerme { id }).await;
                }
                Either::First(Ok(k)) => VERS_COEUR.send(DeHote::TcpRecu { id, data: buf[..k].to_vec() }).await,
                Either::Second(CmdTcp::Envoyer(d)) => {
                    let mut reste = &d[..];
                    while !reste.is_empty() {
                        match s.write(reste).await {
                            Ok(k) => reste = &reste[k..],
                            Err(_) => break,
                        }
                    }
                }
                Either::Second(CmdTcp::Fermer) => break,
                Either::Second(CmdTcp::Ouvrir { .. }) => {}
            }
        }
        s.close();
        let _ = s.flush().await;
        s.abort();
    }
}

/// Datagrammes UDP du 8088 (DNS surtout) ; reponse remise au dernier port source qui a
/// ecrit a cette adresse.
#[embassy_executor::task]
pub async fn udp_tache(stack: Stack<'static>) {
    static mut RX_META: [PacketMetadata; 4] = [PacketMetadata::EMPTY; 4];
    static mut TX_META: [PacketMetadata; 4] = [PacketMetadata::EMPTY; 4];
    static mut RX: [u8; 2048] = [0; 2048];
    static mut TX: [u8; 2048] = [0; 2048];
    #[allow(static_mut_refs)]
    let mut s = unsafe { UdpSocket::new(stack, &mut RX_META, &mut RX, &mut TX_META, &mut TX) };
    let _ = s.bind(49153);
    let mut table: heapless::Vec<([u8; 4], u16, u16), 8> = heapless::Vec::new();
    let mut buf = [0u8; 1500];
    loop {
        match select(UDP.receive(), s.recv_from(&mut buf)).await {
            Either::First((sport, a, port, d)) => {
                table.retain(|e| !(e.0 == a && e.1 == port));
                if table.is_full() {
                    table.remove(0);
                }
                let _ = table.push((a, port, sport));
                let _ = s.send_to(&d, IpEndpoint::new(ip(a), port)).await;
            }
            Either::Second(Ok((k, meta))) => {
                let a = octets(meta.endpoint.addr);
                let port = meta.endpoint.port;
                if let Some(e) = table.iter().find(|e| e.0 == a && e.1 == port) {
                    VERS_COEUR.send(DeHote::Udp { ip: a, port, dport: e.2, data: buf[..k].to_vec() }).await;
                }
            }
            Either::Second(Err(_)) => {}
        }
    }
}

fn somme(d: &[u8]) -> u16 {
    let mut s: u32 = 0;
    for c in d.chunks(2) {
        s += (c[0] as u32) << 8 | *c.get(1).unwrap_or(&0) as u32;
    }
    while s >> 16 != 0 {
        s = (s & 0xFFFF) + (s >> 16);
    }
    !(s as u16)
}

const IDENT_PICO: u16 = 0x5302;

/// Echos ICMP du 8088 vers l'Internet.
#[embassy_executor::task]
pub async fn ping_tache(stack: Stack<'static>) {
    static mut RX_META: [IcmpMeta; 4] = [IcmpMeta::EMPTY; 4];
    static mut TX_META: [IcmpMeta; 4] = [IcmpMeta::EMPTY; 4];
    static mut RX: [u8; 1024] = [0; 1024];
    static mut TX: [u8; 1024] = [0; 1024];
    #[allow(static_mut_refs)]
    let mut s = unsafe { IcmpSocket::new(stack, &mut RX_META, &mut RX, &mut TX_META, &mut TX) };
    let _ = s.bind(IcmpEndpoint::Ident(IDENT_PICO));
    // (adresse, numero) -> identifiant du 8088
    let mut table: heapless::Vec<([u8; 4], u16, u16), 8> = heapless::Vec::new();
    let mut buf = [0u8; 1024];
    loop {
        match select(PING.receive(), s.recv_from(&mut buf)).await {
            Either::First((a, ident, seq, d)) => {
                if table.is_full() {
                    table.remove(0);
                }
                let _ = table.push((a, seq, ident));
                let mut p = Vec::with_capacity(8 + d.len());
                p.extend([8, 0, 0, 0]);
                p.extend(IDENT_PICO.to_be_bytes());
                p.extend(seq.to_be_bytes());
                p.extend(&d);
                let c = somme(&p);
                p[2..4].copy_from_slice(&c.to_be_bytes());
                let _ = s.send_to(&p, ip(a)).await;
            }
            Either::Second(Ok((k, de))) => {
                if k >= 8 && buf[0] == 0 {
                    let a = octets(de);
                    let seq = u16::from_be_bytes([buf[6], buf[7]]);
                    if let Some(i) = table.iter().position(|e| e.0 == a && e.1 == seq) {
                        let ident = table.remove(i).2;
                        VERS_COEUR
                            .send(DeHote::PingReponse { ip: a, ident, seq, data: buf[8..k].to_vec() })
                            .await;
                    }
                }
            }
            Either::Second(Err(_)) => {}
        }
    }
}
