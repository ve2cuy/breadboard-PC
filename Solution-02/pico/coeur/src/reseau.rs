//! Reseau du 8088 a travers le Pico, a la maniere de slirp :
//!
//! - le 8088 envoie des paquets IPv4 en SLIP (192.168.240.2, passerelle 192.168.240.1 =
//!   le Pico, comme avec le module Grove) ;
//! - echos ICMP et datagrammes UDP : relayes tels quels a l'hote ([`VersHote::Ping`],
//!   [`VersHote::Udp`]), reponses reconstruites en paquets IPv4 ;
//! - TCP : terminees dans le Pico par smoltcp (accepte toute adresse de destination) ;
//!   l'hote ne voit que des flux ([`VersHote::TcpOuvrir`]...) qu'il relie aux vraies
//!   connexions du Wi-Fi ;
//! - 192.168.240.1 port 80 : page d'etat servie par le Pico lui-meme (sans Internet).
//!
//! Pas de NAT a faire, et l'Internet n'a pas a connaitre 192.168.240.0/24.

use alloc::collections::VecDeque;
use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, IpListenEndpoint, Ipv4Address};

use crate::hote::{DeHote, VersHote};
use crate::slip;

/// Adresse du Pico (passerelle) et du 8088 sur le lien SLIP.
pub const IP_PICO: [u8; 4] = [192, 168, 240, 1];
pub const IP_8088: [u8; 4] = [192, 168, 240, 2];
/// Octets SLIP en attente pour le 8088 au plus (au-dela : paquets abandonnes).
pub const VERS_8088_MAX: usize = 32 * 1024;
/// Octets recus de l'hote en attente d'entrer dans une connexion TCP (controle de flux :
/// l'hote ne lit plus la connexion distante tant que [`Reseau::tcp_place`] est nulle).
pub const TCP_ATTENTE_MAX: usize = 16 * 1024;
/// Memoire du relais : le simulateur prend les valeurs par defaut, le Pico (264 Ko de RAM)
/// des valeurs plus petites.
#[derive(Clone, Copy, Debug)]
pub struct Limites {
    /// Tampons de smoltcp par connexion (reception et emission).
    pub tcp_tampon: usize,
    pub connexions: usize,
    /// Octets SLIP en attente pour le 8088.
    pub vers_8088: usize,
}

impl Default for Limites {
    fn default() -> Self {
        Limites { tcp_tampon: 8 * 1024, connexions: 16, vers_8088: VERS_8088_MAX }
    }
}

#[derive(Clone, Default, Debug)]
pub struct Wifi {
    pub connecte: bool,
    pub ip: [u8; 4],
    pub rssi: i8,
}

#[derive(Clone, Default, Debug)]
pub struct StatsReseau {
    pub paquets_8088: u32,
    pub paquets_vers_8088: u32,
    pub perdus: u32,
    pub pings: u32,
    pub udp: u32,
    pub tcp_ouvertes: u32,
    pub octets_tcp_vers_hote: u64,
    pub octets_tcp_vers_8088: u64,
}

/// Lien IP brut (Medium::Ip) entre smoltcp et le flux SLIP.
struct Lien {
    entrants: VecDeque<Vec<u8>>,
    sortants: VecDeque<Vec<u8>>,
}

struct Rx(Vec<u8>);
struct Tx<'a>(&'a mut VecDeque<Vec<u8>>);

impl RxToken for Rx {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.0)
    }
}

impl<'a> TxToken for Tx<'a> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut b = vec![0u8; len];
        let r = f(&mut b);
        self.0.push_back(b);
        r
    }
}

impl Device for Lien {
    type RxToken<'a> = Rx where Self: 'a;
    type TxToken<'a> = Tx<'a> where Self: 'a;

    fn receive(&mut self, _t: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let p = self.entrants.pop_front()?;
        Some((Rx(p), Tx(&mut self.sortants)))
    }

    fn transmit(&mut self, _t: Instant) -> Option<Self::TxToken<'_>> {
        Some(Tx(&mut self.sortants))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut c = DeviceCapabilities::default();
        c.medium = Medium::Ip;
        c.max_transmission_unit = 1500;
        c
    }
}

struct Connexion {
    id: u16,
    h: SocketHandle,
    /// cle : port source du 8088, adresse et port de destination
    sport: u16,
    ip: [u8; 4],
    port: u16,
    /// servie par le Pico (page d'etat) au lieu de l'hote
    locale: bool,
    requete: Vec<u8>,
    /// octets de l'hote a faire entrer dans la connexion
    attente: VecDeque<u8>,
    fin_distante: bool,
    fermee_vers_hote: bool,
    etablie: bool,
    nee: u64,
}

pub struct Reseau {
    decodeur: slip::Decodeur,
    vers_8088: VecDeque<u8>,
    /// Messages pour l'hote (a vider par le micrologiciel ou le simulateur).
    pub sortants: VecDeque<VersHote>,
    lien: Lien,
    iface: Interface,
    sockets: SocketSet<'static>,
    conns: Vec<Connexion>,
    prochain_id: u16,
    /// Adresse du 8088 (apprise de ses paquets).
    pub ip_8088: [u8; 4],
    pub wifi: Wifi,
    pub stats: StatsReseau,
    pub version: &'static str,
    now: u64,
    limites: Limites,
}

impl Default for Reseau {
    fn default() -> Self {
        Self::new()
    }
}

fn somme(d: &[u8], init: u32) -> u16 {
    let mut s = init;
    for c in d.chunks(2) {
        s += (c[0] as u32) << 8 | *c.get(1).unwrap_or(&0) as u32;
    }
    while s >> 16 != 0 {
        s = (s & 0xFFFF) + (s >> 16);
    }
    !(s as u16)
}

fn be16(d: &[u8], i: usize) -> u16 {
    u16::from_be_bytes([d[i], d[i + 1]])
}

fn ip4(d: &[u8], i: usize) -> [u8; 4] {
    [d[i], d[i + 1], d[i + 2], d[i + 3]]
}

/// En-tete IPv4 (20 octets) devant `charge`.
fn paquet_ip(src: [u8; 4], dst: [u8; 4], proto: u8, charge: &[u8], ident: u16) -> Vec<u8> {
    let total = 20 + charge.len();
    let mut p = Vec::with_capacity(total);
    p.extend([0x45, 0, (total >> 8) as u8, total as u8]);
    p.extend(ident.to_be_bytes());
    p.extend([0x40, 0, 64, proto, 0, 0]);
    p.extend(src);
    p.extend(dst);
    let c = somme(&p[..20], 0);
    p[10..12].copy_from_slice(&c.to_be_bytes());
    p.extend_from_slice(charge);
    p
}

impl Reseau {
    pub fn new() -> Self {
        Self::avec(Limites::default())
    }

    pub fn avec(limites: Limites) -> Self {
        let mut lien = Lien { entrants: VecDeque::new(), sortants: VecDeque::new() };
        let config = Config::new(HardwareAddress::Ip);
        let mut iface = Interface::new(config, &mut lien, Instant::from_millis(0));
        iface.update_ip_addrs(|a| {
            let p = IP_PICO;
            let _ = a.push(IpCidr::new(IpAddress::v4(p[0], p[1], p[2], p[3]), 24));
        });
        // toute destination passe par nous-memes : smoltcp accepte alors les paquets pour
        // n'importe quelle adresse (any_ip)
        let _ = iface
            .routes_mut()
            .add_default_ipv4_route(Ipv4Address::new(IP_PICO[0], IP_PICO[1], IP_PICO[2], IP_PICO[3]));
        iface.set_any_ip(true);
        Reseau {
            decodeur: slip::Decodeur::new(),
            vers_8088: VecDeque::new(),
            sortants: VecDeque::new(),
            lien,
            iface,
            sockets: SocketSet::new(Vec::new()),
            conns: Vec::new(),
            prochain_id: 1,
            ip_8088: IP_8088,
            wifi: Wifi::default(),
            stats: StatsReseau::default(),
            version: "",
            now: 0,
            limites,
        }
    }

    /// Octets SLIP en attente pour le 8088.
    pub fn a_lire(&self) -> usize {
        self.vers_8088.len()
    }

    pub fn prendre(&mut self) -> Option<u8> {
        self.vers_8088.pop_front()
    }

    /// Connexions TCP ouvertes.
    pub fn connexions(&self) -> usize {
        self.conns.len()
    }

    /// Place pour des octets de l'hote dans la connexion `id` (0 : ne plus lire la
    /// connexion distante pour le moment).
    pub fn tcp_place(&self, id: u16) -> usize {
        self.conns
            .iter()
            .find(|c| c.id == id)
            .map(|c| TCP_ATTENTE_MAX.saturating_sub(c.attente.len()))
            .unwrap_or(0)
    }

    fn vers_8088_paquet(&mut self, p: &[u8]) {
        if self.vers_8088.len() + 2 * p.len() + 2 > self.limites.vers_8088 {
            self.stats.perdus += 1;
            return;
        }
        self.stats.paquets_vers_8088 += 1;
        slip::coder(p, &mut self.vers_8088);
    }

    /// Octets SLIP ecrits par le 8088 (commande NET_ECRIRE).
    pub fn depuis_8088(&mut self, d: &[u8], now_ms: u64) {
        for &b in d {
            if let Some(p) = self.decodeur.octet(b) {
                self.paquet_8088(p, now_ms);
            }
        }
        self.poll(now_ms);
    }

    fn paquet_8088(&mut self, p: Vec<u8>, now_ms: u64) {
        if p.len() < 20 || p[0] >> 4 != 4 {
            return;
        }
        let lh = (p[0] & 15) as usize * 4;
        let total = (be16(&p, 2) as usize).min(p.len());
        if lh < 20 || total < lh {
            return;
        }
        self.stats.paquets_8088 += 1;
        let src = ip4(&p, 12);
        let dst = ip4(&p, 16);
        self.ip_8088 = src;
        let proto = p[9];
        let charge = &p[lh..total];
        match proto {
            1 => {
                // ICMP : seuls les echos sont relayes
                if charge.len() < 8 || charge[0] != 8 {
                    return;
                }
                self.stats.pings += 1;
                let ident = be16(charge, 4);
                let seq = be16(charge, 6);
                let data = charge[8..].to_vec();
                if dst == IP_PICO {
                    self.reponse_ping(dst, ident, seq, &data);
                } else {
                    self.sortants.push_back(VersHote::Ping { ip: dst, ident, seq, data });
                }
            }
            17 => {
                if charge.len() < 8 {
                    return;
                }
                self.stats.udp += 1;
                let sport = be16(charge, 0);
                let port = be16(charge, 2);
                let n = (be16(charge, 4) as usize).clamp(8, charge.len());
                self.sortants.push_back(VersHote::Udp {
                    sport,
                    ip: dst,
                    port,
                    data: charge[8..n].to_vec(),
                });
            }
            6 => {
                if charge.len() < 20 {
                    return;
                }
                let sport = be16(charge, 0);
                let dport = be16(charge, 2);
                let drap = charge[13];
                let syn = drap & 0x02 != 0 && drap & 0x10 == 0;
                if syn && !self.conns.iter().any(|c| c.sport == sport && c.ip == dst && c.port == dport) {
                    self.nouvelle_connexion(sport, dst, dport, now_ms);
                }
                self.lien.entrants.push_back(p[..total].to_vec());
            }
            _ => {}
        }
    }

    fn nouvelle_connexion(&mut self, sport: u16, ip: [u8; 4], port: u16, now_ms: u64) {
        if self.conns.len() >= self.limites.connexions {
            return; // smoltcp repondra RST
        }
        let mut s = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0; self.limites.tcp_tampon]),
            tcp::SocketBuffer::new(vec![0; self.limites.tcp_tampon]),
        );
        let ep = IpListenEndpoint {
            addr: Some(IpAddress::v4(ip[0], ip[1], ip[2], ip[3])),
            port,
        };
        if s.listen(ep).is_err() {
            return;
        }
        s.set_nagle_enabled(false);
        let h = self.sockets.add(s);
        let id = self.prochain_id;
        self.prochain_id = self.prochain_id.wrapping_add(1).max(1);
        let locale = ip == IP_PICO;
        if !locale {
            self.sortants.push_back(VersHote::TcpOuvrir { id, ip, port });
        }
        self.stats.tcp_ouvertes += 1;
        self.conns.push(Connexion {
            id,
            h,
            sport,
            ip,
            port,
            locale,
            requete: Vec::new(),
            attente: VecDeque::new(),
            fin_distante: false,
            fermee_vers_hote: false,
            etablie: false,
            nee: now_ms,
        });
    }

    fn reponse_ping(&mut self, src: [u8; 4], ident: u16, seq: u16, data: &[u8]) {
        let mut icmp = Vec::with_capacity(8 + data.len());
        icmp.extend([0, 0, 0, 0]);
        icmp.extend(ident.to_be_bytes());
        icmp.extend(seq.to_be_bytes());
        icmp.extend_from_slice(data);
        let c = somme(&icmp, 0);
        icmp[2..4].copy_from_slice(&c.to_be_bytes());
        let p = paquet_ip(src, self.ip_8088, 1, &icmp, seq);
        self.vers_8088_paquet(&p);
    }

    fn datagramme(&mut self, src: [u8; 4], sport: u16, dport: u16, data: &[u8]) {
        let n = 8 + data.len();
        let mut u = Vec::with_capacity(n);
        u.extend(sport.to_be_bytes());
        u.extend(dport.to_be_bytes());
        u.extend((n as u16).to_be_bytes());
        u.extend([0, 0]);
        u.extend_from_slice(data);
        // pseudo-en-tete
        let mut ph = Vec::with_capacity(12);
        ph.extend(src);
        ph.extend(self.ip_8088);
        ph.extend([0, 17]);
        ph.extend((n as u16).to_be_bytes());
        let mut s: u32 = 0;
        for c in ph.chunks(2) {
            s += (c[0] as u32) << 8 | c[1] as u32;
        }
        let mut c = somme(&u, s);
        if c == 0 {
            c = 0xFFFF;
        }
        u[6..8].copy_from_slice(&c.to_be_bytes());
        let p = paquet_ip(src, self.ip_8088, 17, &u, dport);
        self.vers_8088_paquet(&p);
    }

    /// Message de l'hote.
    pub fn recevoir(&mut self, m: DeHote) {
        match m {
            DeHote::TcpOuvert { id } => {
                let _ = id;
            }
            DeHote::TcpRecu { id, data } => {
                if let Some(c) = self.conns.iter_mut().find(|c| c.id == id) {
                    c.attente.extend(data);
                }
            }
            DeHote::TcpFerme { id } => {
                if let Some(c) = self.conns.iter_mut().find(|c| c.id == id) {
                    c.fin_distante = true;
                }
            }
            DeHote::TcpEchec { id } => {
                if let Some(c) = self.conns.iter_mut().find(|c| c.id == id) {
                    c.fermee_vers_hote = true;
                    self.sockets.get_mut::<tcp::Socket>(c.h).abort();
                }
            }
            DeHote::Udp { ip, port, dport, data } => self.datagramme(ip, port, dport, &data),
            DeHote::PingReponse { ip, ident, seq, data } => self.reponse_ping(ip, ident, seq, &data),
            DeHote::Wifi { connecte, ip, rssi } => self.wifi = Wifi { connecte, ip, rssi },
        }
        let now = self.now;
        self.poll(now);
    }

    fn page_etat(&self) -> Vec<u8> {
        let w = &self.wifi;
        let s = &self.stats;
        let corps = format!(
            concat!(
                "<html><head><title>Pico W de Solution-02</title></head><body>\r\n",
                "<h1>Pico W de Solution-02</h1>\r\n",
                "<p>Micrologiciel {}, protocole des registres {} (ports 50h-57h).</p>\r\n",
                "<p>Wi-Fi : {} - adresse {}.{}.{}.{} - {} dBm</p>\r\n",
                "<p>8088 : {}.{}.{}.{} ; paquets recus {}, envoyes {}, perdus {} ; ",
                "connexions TCP ouvertes {} ; pings {} ; UDP {}.</p>\r\n",
                "</body></html>\r\n"
            ),
            self.version,
            crate::VERSION,
            if w.connecte { "connecte" } else { "deconnecte" },
            w.ip[0], w.ip[1], w.ip[2], w.ip[3],
            w.rssi,
            self.ip_8088[0], self.ip_8088[1], self.ip_8088[2], self.ip_8088[3],
            s.paquets_8088,
            s.paquets_vers_8088,
            s.perdus,
            s.tcp_ouvertes,
            s.pings,
            s.udp
        );
        let mut r: String = format!(
            "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            corps.len()
        );
        r.push_str(&corps);
        r.into_bytes()
    }

    /// Fait avancer la pile TCP et les connexions.
    pub fn poll(&mut self, now_ms: u64) {
        self.now = now_ms;
        let t = Instant::from_millis(now_ms as i64);
        for _ in 0..4 {
            self.iface.poll(t, &mut self.lien, &mut self.sockets);
            let mut encore = false;
            let mut i = 0;
            while i < self.conns.len() {
                let page = if self.conns[i].locale { Some(self.page_etat()) } else { None };
                let c = &mut self.conns[i];
                let s = self.sockets.get_mut::<tcp::Socket>(c.h);
                if s.is_active() && s.state() != tcp::State::SynReceived && s.state() != tcp::State::Listen {
                    c.etablie = true;
                }
                // 8088 -> hote
                while s.can_recv() {
                    let mut tmp = [0u8; 512];
                    let n = s.recv_slice(&mut tmp).unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    if c.locale {
                        c.requete.extend_from_slice(&tmp[..n]);
                    } else {
                        self.stats.octets_tcp_vers_hote += n as u64;
                        self.sortants.push_back(VersHote::TcpEnvoyer { id: c.id, data: tmp[..n].to_vec() });
                    }
                }
                if c.locale && !c.fin_distante && c.requete.windows(4).any(|w| w == b"\r\n\r\n") {
                    c.attente.extend(page.unwrap_or_default());
                    c.fin_distante = true;
                }
                // hote -> 8088
                while !c.attente.is_empty() && s.can_send() {
                    let (a, _) = c.attente.as_slices();
                    let n = s.send_slice(a).unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    self.stats.octets_tcp_vers_8088 += n as u64;
                    c.attente.drain(..n);
                    encore = true;
                }
                if c.fin_distante && c.attente.is_empty() && s.may_send() {
                    s.close();
                    encore = true;
                }
                // fin cote 8088 (FIN recu, ou connexion abandonnee)
                if c.etablie && !s.may_recv() && !c.fermee_vers_hote {
                    c.fermee_vers_hote = true;
                    if !c.locale {
                        self.sortants.push_back(VersHote::TcpFermer { id: c.id });
                    }
                }
                let st = s.state();
                let morte = (c.etablie || c.fermee_vers_hote || now_ms.saturating_sub(c.nee) > 30_000)
                    && (st == tcp::State::Closed || st == tcp::State::TimeWait);
                // SYN jamais arrive (doublon) : socket en ecoute abandonne
                let orpheline = st == tcp::State::Listen && now_ms.saturating_sub(c.nee) > 5_000;
                if morte || orpheline {
                    if !c.fermee_vers_hote && !c.locale {
                        self.sortants.push_back(VersHote::TcpFermer { id: c.id });
                    }
                    let h = c.h;
                    self.sockets.remove(h);
                    self.conns.remove(i);
                    continue;
                }
                i += 1;
            }
            if !encore {
                break;
            }
        }
        while let Some(p) = self.lien.sortants.pop_front() {
            self.vers_8088_paquet(&p);
        }
    }
}
