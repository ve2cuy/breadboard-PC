//! Essais du coeur : le 8088 est joue par un acces aux ports (comme le BIOS 3.3) et, pour
//! TCP, par une seconde pile smoltcp (192.168.240.2) qui parle SLIP a travers les commandes
//! NET_ECRIRE / NET_LIRE. L'hote est joue par l'essai.

use std::collections::VecDeque;

use s02pico_coeur::*;
use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, Ipv4Address};

struct CarteRam {
    d: Vec<u8>,
}

impl Carte for CarteRam {
    fn init(&mut self) -> Option<u32> {
        Some((self.d.len() / 512) as u32)
    }
    fn lire(&mut self, lba: u32, d: &mut [u8; 512]) -> bool {
        let i = lba as usize * 512;
        if i + 512 > self.d.len() {
            return false;
        }
        d.copy_from_slice(&self.d[i..i + 512]);
        true
    }
    fn ecrire(&mut self, lba: u32, d: &[u8; 512]) -> bool {
        let i = lba as usize * 512;
        if i + 512 > self.d.len() {
            return false;
        }
        self.d[i..i + 512].copy_from_slice(d);
        true
    }
}

fn commande(c: &mut Coeur, carte: &mut CarteRam, cmd: u8, now: u64) {
    c.ecrire_port(R_ETAT, cmd);
    assert!(c.etat() & E_OCCUPE != 0);
    c.executer(carte, now);
    assert!(c.etat() & E_OCCUPE == 0);
}

fn lire_tout(c: &mut Coeur) -> Vec<u8> {
    let mut v = Vec::new();
    while c.etat() & E_DONNEE != 0 {
        v.push(c.lire_port(R_DONNEE));
    }
    v
}

#[test]
fn ident_signature_et_registres() {
    let mut c = Coeur::new();
    let mut k = CarteRam { d: vec![0; 512 * 8] };
    assert_eq!(c.lire_port(R_SIGNATURE), SIGNATURE);
    assert_eq!(c.etat() & 0x80, 0);
    commande(&mut c, &mut k, C_IDENT, 0);
    assert_eq!(c.lire_port(R_NOMBRE), 8);
    assert_eq!(lire_tout(&mut c), b"S02PICO\x01");
    assert_eq!(c.lire_port(R_DONNEE), 0xFF);
    for i in 0..4 {
        c.ecrire_port(R_PARAM + i, 0x10 + i);
    }
    assert_eq!(c.lire_port(R_PARAM + 3), 0x13);
    c.ecrire_port(R_ETAT, 0x7E);
    c.executer(&mut k, 0);
    assert!(c.etat() & E_ERREUR != 0);
    c.ecrire_port(R_ETAT, C_VIDER);
    assert_eq!(c.etat() & (E_ERREUR | E_OCCUPE | E_DONNEE), 0);
}

#[test]
fn carte_sd_lire_ecrire() {
    let mut c = Coeur::new();
    let mut k = CarteRam { d: (0..512 * 64).map(|i| (i * 7 + i / 512) as u8).collect() };
    commande(&mut c, &mut k, C_SD_INIT, 0);
    assert!(c.etat() & E_CARTE != 0);
    assert_eq!(lire_tout(&mut c), vec![1, 64, 0, 0, 0]);
    for (i, b) in 5u32.to_le_bytes().iter().enumerate() {
        c.ecrire_port(R_PARAM + i as u8, *b);
    }
    commande(&mut c, &mut k, C_SD_LIRE, 0);
    let s = lire_tout(&mut c);
    assert_eq!(s, k.d[5 * 512..6 * 512]);
    for i in 0..512 {
        c.ecrire_port(R_DONNEE, (i % 251) as u8);
    }
    c.ecrire_port(R_PARAM, 9);
    commande(&mut c, &mut k, C_SD_ECRIRE, 0);
    assert_eq!(c.etat() & E_ERREUR, 0);
    assert!((0..512).all(|i| k.d[9 * 512 + i] == (i % 251) as u8));
    // hors de la carte : erreur
    c.ecrire_port(R_PARAM + 3, 0x7F);
    commande(&mut c, &mut k, C_SD_LIRE, 0);
    assert!(c.etat() & E_ERREUR != 0);
    assert_eq!(c.stats.sd_lus, 1);
    assert_eq!(c.stats.sd_ecrits, 1);
}

// ------------------------------------------------------------------ le 8088 en SLIP
fn net_ecrire(c: &mut Coeur, k: &mut CarteRam, d: &[u8], now: u64) {
    for &b in d {
        c.ecrire_port(R_DONNEE, b);
    }
    commande(c, k, C_NET_ECRIRE, now);
}

fn net_lire(c: &mut Coeur, k: &mut CarteRam) -> Vec<u8> {
    let mut v = Vec::new();
    while c.etat() & E_RESEAU != 0 {
        c.ecrire_port(R_PARAM, 0);
        commande(c, k, C_NET_LIRE, 0);
        let n = c.lire_port(R_DONNEE) as usize;
        assert!(n > 0);
        for _ in 0..n {
            v.push(c.lire_port(R_DONNEE));
        }
    }
    v
}

fn decoder(d: &[u8]) -> Vec<Vec<u8>> {
    let mut dec = slip::Decodeur::new();
    d.iter().filter_map(|&b| dec.octet(b)).collect()
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

fn echo(dst: [u8; 4], seq: u16) -> Vec<u8> {
    let mut icmp = vec![8, 0, 0, 0, 0x12, 0x34, (seq >> 8) as u8, seq as u8];
    icmp.extend(b"abcdefgh");
    let s = somme(&icmp);
    icmp[2..4].copy_from_slice(&s.to_be_bytes());
    let mut p = vec![0x45, 0, 0, (20 + icmp.len()) as u8, 0, 1, 0, 0, 64, 1, 0, 0, 192, 168, 240, 2];
    p.extend(dst);
    let s = somme(&p);
    p[10..12].copy_from_slice(&s.to_be_bytes());
    p.extend(icmp);
    p
}

#[test]
fn ping_relaye_et_ping_du_pico() {
    let mut c = Coeur::new();
    let mut k = CarteRam { d: vec![] };
    let mut s = VecDeque::new();
    slip::coder(&echo([8, 8, 8, 8], 1), &mut s);
    slip::coder(&echo(reseau::IP_PICO, 2), &mut s);
    net_ecrire(&mut c, &mut k, &s.into_iter().collect::<Vec<_>>(), 10);
    // 192.168.240.1 : reponse immediate du Pico
    let r = decoder(&net_lire(&mut c, &mut k));
    assert_eq!(r.len(), 1);
    assert_eq!(&r[0][12..16], &reseau::IP_PICO);
    assert_eq!(r[0][20], 0);
    assert_eq!(somme(&r[0][..20]), 0);
    assert_eq!(somme(&r[0][20..]), 0);
    // 8.8.8.8 : relaye a l'hote
    let m = c.reseau.sortants.pop_front().unwrap();
    let VersHote::Ping { ip, ident, seq, data } = m else { panic!("{:?}", m) };
    assert_eq!((ip, ident, seq, &data[..]), ([8, 8, 8, 8], 0x1234, 1, &b"abcdefgh"[..]));
    c.reseau.recevoir(DeHote::PingReponse { ip, ident, seq, data });
    let r = decoder(&net_lire(&mut c, &mut k));
    assert_eq!(r.len(), 1);
    assert_eq!(&r[0][12..16], &[8, 8, 8, 8]);
    assert_eq!(&r[0][16..20], &reseau::IP_8088);
    assert_eq!(somme(&r[0][20..]), 0);
}

#[test]
fn udp_dns_relaye() {
    let mut c = Coeur::new();
    let mut k = CarteRam { d: vec![] };
    let q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x03www\x00\x00\x01\x00\x01";
    let mut u = vec![0x04, 0x00, 0, 53, 0, (8 + q.len()) as u8, 0, 0];
    u.extend(q);
    let mut p = vec![0x45, 0, 0, (20 + u.len()) as u8, 0, 1, 0, 0, 64, 17, 0, 0, 192, 168, 240, 2, 8, 8, 8, 8];
    let s = somme(&p);
    p[10..12].copy_from_slice(&s.to_be_bytes());
    p.extend(u);
    let mut sl = VecDeque::new();
    slip::coder(&p, &mut sl);
    net_ecrire(&mut c, &mut k, &sl.into_iter().collect::<Vec<_>>(), 0);
    let VersHote::Udp { sport, ip, port, data } = c.reseau.sortants.pop_front().unwrap() else { panic!() };
    assert_eq!((sport, ip, port, &data[..]), (1024, [8, 8, 8, 8], 53, &q[..]));
    c.reseau.recevoir(DeHote::Udp { ip, port, dport: sport, data: b"reponse".to_vec() });
    let r = decoder(&net_lire(&mut c, &mut k));
    assert_eq!(r.len(), 1);
    assert_eq!(r[0][9], 17);
    assert_eq!(&r[0][28..], b"reponse");
    // somme UDP avec le pseudo-en-tete
    let mut ph = r[0][12..20].to_vec();
    ph.extend([0, 17, 0, 15]);
    ph.extend(&r[0][20..]);
    assert_eq!(somme(&ph), 0);
}

// ------------------------------------------------------------------ TCP : pile du 8088
struct Lien8088 {
    rx: VecDeque<Vec<u8>>,
    tx: VecDeque<Vec<u8>>,
}
struct Rx(Vec<u8>);
struct Tx<'a>(&'a mut VecDeque<Vec<u8>>);
impl RxToken for Rx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}
impl<'a> TxToken for Tx<'a> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut b = vec![0; len];
        let r = f(&mut b);
        self.0.push_back(b);
        r
    }
}
impl Device for Lien8088 {
    type RxToken<'a> = Rx where Self: 'a;
    type TxToken<'a> = Tx<'a> where Self: 'a;
    fn receive(&mut self, _t: Instant) -> Option<(Rx, Tx<'_>)> {
        let p = self.rx.pop_front()?;
        Some((Rx(p), Tx(&mut self.tx)))
    }
    fn transmit(&mut self, _t: Instant) -> Option<Tx<'_>> {
        Some(Tx(&mut self.tx))
    }
    fn capabilities(&self) -> DeviceCapabilities {
        let mut c = DeviceCapabilities::default();
        c.medium = Medium::Ip;
        c.max_transmission_unit = 576;
        c
    }
}

/// Le 8088 ouvre une connexion vers ip:port, envoie `requete`, rend tout ce qu'il recoit.
/// `hote` repond aux messages du coeur.
fn session_tcp(ip: [u8; 4], port: u16, requete: &[u8], mut hote: impl FnMut(VersHote, &mut Coeur)) -> Vec<u8> {
    let mut c = Coeur::new();
    let mut k = CarteRam { d: vec![] };
    let mut lien = Lien8088 { rx: VecDeque::new(), tx: VecDeque::new() };
    let mut iface = Interface::new(Config::new(HardwareAddress::Ip), &mut lien, Instant::from_millis(0));
    iface.update_ip_addrs(|a| {
        a.push(IpCidr::new(IpAddress::v4(192, 168, 240, 2), 24)).unwrap();
    });
    iface.routes_mut().add_default_ipv4_route(Ipv4Address::new(192, 168, 240, 1)).unwrap();
    let mut socks = SocketSet::new(vec![]);
    let s = tcp::Socket::new(tcp::SocketBuffer::new(vec![0; 2048]), tcp::SocketBuffer::new(vec![0; 2048]));
    let h = socks.add(s);
    socks
        .get_mut::<tcp::Socket>(h)
        .connect(iface.context(), (IpAddress::v4(ip[0], ip[1], ip[2], ip[3]), port), 40000)
        .unwrap();
    let mut recu = Vec::new();
    let mut envoye = false;
    for ms in 0..3000u64 {
        let t = Instant::from_millis(ms as i64);
        iface.poll(t, &mut lien, &mut socks);
        let s = socks.get_mut::<tcp::Socket>(h);
        if s.may_send() && !envoye {
            s.send_slice(requete).unwrap();
            envoye = true;
        }
        while s.can_recv() {
            let mut b = [0u8; 256];
            let n = s.recv_slice(&mut b).unwrap();
            recu.extend_from_slice(&b[..n]);
        }
        if envoye && !s.may_recv() && s.state() != tcp::State::Closed {
            s.close();
        }
        if envoye && s.state() == tcp::State::Closed {
            break;
        }
        // 8088 -> Pico
        let mut sl = VecDeque::new();
        while let Some(p) = lien.tx.pop_front() {
            slip::coder(&p, &mut sl);
        }
        if !sl.is_empty() {
            net_ecrire(&mut c, &mut k, &sl.into_iter().collect::<Vec<_>>(), ms);
        }
        c.poll(ms);
        while let Some(m) = c.reseau.sortants.pop_front() {
            hote(m, &mut c);
        }
        // Pico -> 8088
        for p in decoder(&net_lire(&mut c, &mut k)) {
            lien.rx.push_back(p);
        }
    }
    assert_eq!(c.reseau.connexions(), 0, "connexion restee ouverte dans le Pico");
    recu
}

#[test]
fn tcp_relaye_vers_l_hote() {
    let mut ouvert = false;
    let mut req = Vec::new();
    let mut ferme = false;
    let rep = session_tcp([93, 184, 215, 14], 80, b"GET / HTTP/1.0\r\nHost: exemple\r\n\r\n", |m, c| match m {
        VersHote::TcpOuvrir { id, ip, port } => {
            assert_eq!((ip, port), ([93, 184, 215, 14], 80));
            ouvert = true;
            c.reseau.recevoir(DeHote::TcpOuvert { id });
        }
        VersHote::TcpEnvoyer { id, data } => {
            req.extend(data);
            if req.ends_with(b"\r\n\r\n") {
                let corps: Vec<u8> = (0..3000).map(|i| b'a' + (i % 26) as u8).collect();
                let mut r = format!("HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n", corps.len()).into_bytes();
                r.extend(corps);
                c.reseau.recevoir(DeHote::TcpRecu { id, data: r });
                c.reseau.recevoir(DeHote::TcpFerme { id });
            }
        }
        VersHote::TcpFermer { .. } => ferme = true,
        m => panic!("{:?}", m),
    });
    assert!(ouvert);
    assert_eq!(&req[..], b"GET / HTTP/1.0\r\nHost: exemple\r\n\r\n");
    let t = String::from_utf8_lossy(&rep);
    assert!(t.starts_with("HTTP/1.0 200 OK"), "{}", t);
    assert_eq!(rep.len(), t.find("\r\n\r\n").unwrap() + 4 + 3000);
    assert!(ferme);
}

#[test]
fn tcp_refusee_par_l_hote() {
    let rep = session_tcp([10, 9, 9, 9], 23, b"x", |m, c| {
        if let VersHote::TcpOuvrir { id, .. } = m {
            c.reseau.recevoir(DeHote::TcpEchec { id });
        }
    });
    assert!(rep.is_empty());
}

#[test]
fn page_d_etat_du_pico() {
    let rep = session_tcp(reseau::IP_PICO, 80, b"GET / HTTP/1.0\r\n\r\n", |m, _| panic!("hote sollicite : {:?}", m));
    let t = String::from_utf8_lossy(&rep);
    assert!(t.starts_with("HTTP/1.0 200 OK"), "{}", t);
    assert!(t.contains("Pico W de Solution-02"));
}
