//! L'Internet vu par le Pico W simule.
//!
//! Le coeur du micrologiciel (s02pico-coeur) termine les connexions du 8088 et demande a son
//! hote d'ouvrir les vraies (messages [`VersHote`]). Ici, l'hote est :
//! - un Internet integre, toujours present (essais natifs, page sans relais) :
//!   - echos ICMP vers toute adresse : reponse apres ~20 ms (un fureteur ne peut pas pinguer) ;
//!   - DNS (UDP 53, tout serveur) : zone `s02` (www.s02, pico.s02) ;
//!   - serveur web de 10.83.0.80 (www.s02) : pages d'essai, fichier de 64 Ko ;
//! - le JavaScript de la page (`js = true`) pour le reste : DNS par DNS-over-HTTPS, TCP par
//!   le relais WebSocket (outils/relais.py) ou, sans relais, HTTP par fetch().
//!
//! Sans JavaScript, une connexion vers une autre adresse est refusee (RST) et un nom
//! inconnu rend NXDOMAIN.

use std::collections::{HashMap, VecDeque};

use s02pico_coeur::{DeHote, VersHote};

/// Serveur web integre (www.s02).
pub const IP_WWW: [u8; 4] = [10, 83, 0, 80];
/// Adresse du Pico sur le reseau Wi-Fi simule.
pub const IP_WIFI: [u8; 4] = [192, 168, 1, 77];
/// Delai d'un aller-retour vers l'Internet simule (ms).
pub const RTT_MS: u64 = 20;

/// Ou renvoyer la reponse a une requete DNS.
#[derive(Clone, Copy)]
enum RetourDns {
    Udp { ip: [u8; 4], port: u16, dport: u16 },
    /// DNS sur TCP (le resolveur d'ELKS) : reponse precedee de sa longueur.
    Tcp { id: u16 },
}

/// Ce que la page doit faire pour le Pico.
pub enum PourJs {
    Hote(VersHote),
    /// Requete DNS a resoudre par DNS-over-HTTPS ; reponse par `Internet::doh_reponse(cle)`.
    Doh { cle: u32, requete: Vec<u8> },
}

struct ConnWww {
    requete: Vec<u8>,
    servie: bool,
}

#[derive(Clone, Default, Debug)]
pub struct StatsInternet {
    pub pings: u32,
    pub dns: u32,
    pub tcp: u32,
    pub tcp_js: u32,
    pub octets_recus: u64,
    pub octets_envoyes: u64,
}

pub struct Internet {
    /// La page relaie ce que l'Internet integre ne sait pas faire.
    pub js: bool,
    /// Reponses programmees : (instant en ms, message).
    attente: Vec<(u64, DeHote)>,
    /// Messages pour le JavaScript.
    pub pour_js: VecDeque<PourJs>,
    /// Requetes DNS confiees a la page (DoH).
    doh: HashMap<u32, (RetourDns, Vec<u8>)>,
    doh_cle: u32,
    /// Connexions DNS sur TCP : octets recus.
    dns_tcp: HashMap<u16, Vec<u8>>,
    www: HashMap<u16, ConnWww>,
    /// Connexions confiees au JavaScript.
    js_ids: HashMap<u16, ()>,
    pub journal: VecDeque<String>,
    pub stats: StatsInternet,
    wifi_annonce: bool,
}

impl Default for Internet {
    fn default() -> Self {
        Self::new()
    }
}

fn ip_txt(ip: [u8; 4]) -> String {
    format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3])
}

/// Nom de la question d'une requete DNS (et la fin de la question).
fn dns_question(q: &[u8]) -> Option<(String, usize)> {
    if q.len() < 12 {
        return None;
    }
    let mut i = 12;
    let mut nom = String::new();
    loop {
        let n = *q.get(i)? as usize;
        if n == 0 {
            i += 1;
            break;
        }
        if n & 0xC0 != 0 {
            return None;
        }
        if !nom.is_empty() {
            nom.push('.');
        }
        nom.push_str(&String::from_utf8_lossy(q.get(i + 1..i + 1 + n)?));
        i += 1 + n;
    }
    if i + 4 > q.len() {
        return None;
    }
    Some((nom.to_ascii_lowercase(), i + 4))
}

/// Reponse DNS a une question de type A : adresse ou NXDOMAIN.
pub fn dns_reponse(q: &[u8], ip: Option<[u8; 4]>) -> Option<Vec<u8>> {
    let (_, fin) = dns_question(q)?;
    let qtype = u16::from_be_bytes([q[fin - 4], q[fin - 3]]);
    let mut r = q[..fin].to_vec();
    r[2] = 0x81 | (q[2] & 0x01); // reponse, RD recopie, AA
    r[2] = (r[2] & !0x78) | 0x04;
    let rcode = if ip.is_some() { 0 } else { 3 };
    r[3] = 0x80 | rcode; // RA
    r[4] = 0;
    r[5] = 1;
    r[6] = 0;
    r[7] = if ip.is_some() && qtype == 1 { 1 } else { 0 };
    r[8..12].copy_from_slice(&[0, 0, 0, 0]);
    if let (Some(ip), 1) = (ip, qtype) {
        r.extend([0xC0, 12, 0, 1, 0, 1, 0, 0, 0x0E, 0x10, 0, 4]);
        r.extend(ip);
    }
    Some(r)
}

/// Noms connus de l'Internet integre.
fn zone(nom: &str) -> Option<[u8; 4]> {
    match nom {
        "www.s02" | "s02" | "web.s02" => Some(IP_WWW),
        "pico.s02" => Some(s02pico_coeur::reseau::IP_PICO),
        "solution02.s02" => Some(s02pico_coeur::reseau::IP_8088),
        _ => None,
    }
}

fn page(chemin: &str) -> (u16, String, Vec<u8>) {
    let chemin = chemin.split('?').next().unwrap_or("/");
    match chemin {
        "/" | "/index.html" => (
            200,
            "text/html".into(),
            concat!(
                "<html><head><title>www.s02</title></head><body>\r\n",
                "<h1>Bienvenue sur www.s02 / Welcome to www.s02</h1>\r\n",
                "<p>Serveur web de l'Internet simule de Solution-02 : la requete a traverse ",
                "le pilote de paquets du 8088, le BIOS 3.3, les ports 50h-57h, U18/U19 et le Pico W.</p>\r\n",
                "<p>Simulated Internet web server of Solution-02: this request went through the ",
                "8088 packet driver, BIOS 3.3, ports 50h-57h, U18/U19 and the Pico W.</p>\r\n",
                "<p><a href=\"/gros.bin\">gros.bin</a> : 64 Ko pour mesurer le debit.</p>\r\n",
                "</body></html>\r\n"
            )
            .as_bytes()
            .to_vec(),
        ),
        "/gros.bin" => (
            200,
            "application/octet-stream".into(),
            (0..65536u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 24) as u8).collect(),
        ),
        "/texte.txt" => (200, "text/plain".into(), b"Solution-02 + Pico W : OK\r\n".to_vec()),
        _ => (404, "text/html".into(), b"<html><body><h1>404</h1></body></html>\r\n".to_vec()),
    }
}

/// Contenu de /gros.bin (essais).
pub fn gros_bin() -> Vec<u8> {
    page("/gros.bin").2
}

impl Internet {
    pub fn new() -> Self {
        Internet {
            js: false,
            attente: Vec::new(),
            pour_js: VecDeque::new(),
            www: HashMap::new(),
            js_ids: HashMap::new(),
            doh: HashMap::new(),
            doh_cle: 1,
            dns_tcp: HashMap::new(),
            journal: VecDeque::new(),
            stats: StatsInternet::default(),
            wifi_annonce: false,
        }
    }

    pub fn noter(&mut self, s: String) {
        if self.journal.len() >= 200 {
            self.journal.pop_front();
        }
        self.journal.push_back(s);
    }

    fn plus_tard(&mut self, now: u64, delai: u64, m: DeHote) {
        self.attente.push((now + delai, m));
    }

    /// Prochain instant (ms) ou une reponse est due.
    pub fn prochain(&self) -> Option<u64> {
        self.attente.iter().map(|a| a.0).min()
    }

    /// Reponses dues a l'instant `now` (ms).
    pub fn dues(&mut self, now: u64) -> Vec<DeHote> {
        if !self.wifi_annonce {
            self.wifi_annonce = true;
            self.attente.push((now, DeHote::Wifi { connecte: true, ip: IP_WIFI, rssi: -52 }));
        }
        let mut out = Vec::new();
        let mut i = 0;
        // dans l'ordre de leur echeance
        self.attente.sort_by_key(|a| a.0);
        while i < self.attente.len() {
            if self.attente[i].0 <= now {
                out.push(self.attente.remove(i).1);
            } else {
                i += 1;
            }
        }
        out
    }

    fn rendre_dns(&mut self, ret: RetourDns, r: Vec<u8>, now: u64, delai: u64) {
        match ret {
            RetourDns::Udp { ip, port, dport } => self.plus_tard(now, delai, DeHote::Udp { ip, port, dport, data: r }),
            RetourDns::Tcp { id } => {
                let mut d = (r.len() as u16).to_be_bytes().to_vec();
                d.extend(r);
                self.plus_tard(now, delai, DeHote::TcpRecu { id, data: d });
            }
        }
    }

    /// Requete DNS (UDP ou TCP) : zone s02, sinon DoH par la page, sinon NXDOMAIN.
    fn dns(&mut self, q: Vec<u8>, ret: RetourDns, now: u64) {
        self.stats.dns += 1;
        let nom = dns_question(&q).map(|n| n.0).unwrap_or_default();
        match zone(&nom) {
            Some(a) => {
                self.noter(format!("DNS {} -> {}", nom, ip_txt(a)));
                if let Some(r) = dns_reponse(&q, Some(a)) {
                    self.rendre_dns(ret, r, now, 2);
                }
            }
            None if self.js => {
                self.noter(format!("DNS {} (DNS-over-HTTPS)", nom));
                let cle = self.doh_cle;
                self.doh_cle = self.doh_cle.wrapping_add(1).max(1);
                self.doh.insert(cle, (ret, q.clone()));
                self.pour_js.push_back(PourJs::Doh { cle, requete: q });
            }
            None => {
                self.noter(format!("DNS {} : inconnu", nom));
                if let Some(r) = dns_reponse(&q, None) {
                    self.rendre_dns(ret, r, now, RTT_MS);
                }
            }
        }
    }

    /// Reponse DoH de la page (vide : echec, NXDOMAIN rendu).
    pub fn doh_reponse(&mut self, cle: u32, r: Vec<u8>, now: u64) {
        if let Some((ret, q)) = self.doh.remove(&cle) {
            let r = if r.len() >= 12 { r } else { dns_reponse(&q, None).unwrap_or_default() };
            self.rendre_dns(ret, r, now, 0);
        }
    }

    /// Message du Pico.
    pub fn depuis_pico(&mut self, m: VersHote, now: u64) {
        match m {
            VersHote::Ping { ip, ident, seq, data } => {
                self.stats.pings += 1;
                self.plus_tard(now, RTT_MS, DeHote::PingReponse { ip, ident, seq, data });
            }
            VersHote::Udp { sport, ip, port, data } => {
                if port == 53 {
                    self.dns(data, RetourDns::Udp { ip, port, dport: sport }, now);
                } else if self.js {
                    self.pour_js.push_back(PourJs::Hote(VersHote::Udp { sport, ip, port, data }));
                }
            }
            VersHote::TcpOuvrir { id, ip, port } => {
                self.stats.tcp += 1;
                if port == 53 {
                    self.noter(format!("TCP {} : DNS sur TCP vers {}", id, ip_txt(ip)));
                    self.dns_tcp.insert(id, Vec::new());
                    self.plus_tard(now, RTT_MS / 2, DeHote::TcpOuvert { id });
                } else if ip == IP_WWW && port == 80 {
                    self.noter(format!("TCP {} : www.s02:80 (integre)", id));
                    self.www.insert(id, ConnWww { requete: Vec::new(), servie: false });
                    self.plus_tard(now, RTT_MS / 2, DeHote::TcpOuvert { id });
                } else if self.js {
                    self.noter(format!("TCP {} : {}:{} (page : relais ou fetch)", id, ip_txt(ip), port));
                    self.stats.tcp_js += 1;
                    self.js_ids.insert(id, ());
                    self.pour_js.push_back(PourJs::Hote(VersHote::TcpOuvrir { id, ip, port }));
                } else {
                    self.noter(format!("TCP {} : {}:{} refusee (pas de relais)", id, ip_txt(ip), port));
                    self.plus_tard(now, RTT_MS, DeHote::TcpEchec { id });
                }
            }
            VersHote::TcpEnvoyer { id, data } => {
                self.stats.octets_envoyes += data.len() as u64;
                if let Some(b) = self.dns_tcp.get_mut(&id) {
                    b.extend(&data);
                    let mut qs = Vec::new();
                    while b.len() >= 2 {
                        let n = u16::from_be_bytes([b[0], b[1]]) as usize;
                        if b.len() < 2 + n {
                            break;
                        }
                        qs.push(b[2..2 + n].to_vec());
                        b.drain(..2 + n);
                    }
                    for q in qs {
                        self.dns(q, RetourDns::Tcp { id }, now);
                    }
                } else if let Some(c) = self.www.get_mut(&id) {
                    c.requete.extend(&data);
                    if !c.servie {
                        if let Some(fin) = c.requete.windows(4).position(|w| w == b"\r\n\r\n") {
                            c.servie = true;
                            let tete = String::from_utf8_lossy(&c.requete[..fin]).to_string();
                            let ligne = tete.lines().next().unwrap_or("").to_string();
                            let mut mots = ligne.split_whitespace();
                            let methode = mots.next().unwrap_or("").to_string();
                            let chemin = mots.next().unwrap_or("/").to_string();
                            let (code, type_, corps) = page(&chemin);
                            let mut r = format!(
                                "HTTP/1.0 {} {}\r\nServer: www.s02 (Solution-02)\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                code,
                                if code == 200 { "OK" } else { "Not Found" },
                                type_,
                                corps.len()
                            )
                            .into_bytes();
                            if methode != "HEAD" {
                                r.extend(corps);
                            }
                            self.noter(format!("HTTP {} {} -> {} ({} o)", methode, chemin, code, r.len()));
                            self.stats.octets_recus += r.len() as u64;
                            // par morceaux de 4 Ko, comme un vrai serveur
                            for (k, m) in r.chunks(4096).enumerate() {
                                self.plus_tard(now, RTT_MS / 2 + k as u64, DeHote::TcpRecu { id, data: m.to_vec() });
                            }
                            let n = r.len().div_ceil(4096) as u64;
                            self.plus_tard(now, RTT_MS / 2 + n, DeHote::TcpFerme { id });
                        }
                    }
                } else if self.js_ids.contains_key(&id) {
                    self.pour_js.push_back(PourJs::Hote(VersHote::TcpEnvoyer { id, data }));
                }
            }
            VersHote::TcpFermer { id } => {
                self.www.remove(&id);
                if self.dns_tcp.remove(&id).is_some() {
                    self.plus_tard(now, 1, DeHote::TcpFerme { id });
                }
                if self.js_ids.remove(&id).is_some() {
                    self.pour_js.push_back(PourJs::Hote(VersHote::TcpFermer { id }));
                }
            }
            VersHote::Wifi { ssid, .. } => {
                self.noter(format!("Wi-Fi : {}", String::from_utf8_lossy(&ssid)));
                self.plus_tard(now, 500, DeHote::Wifi { connecte: true, ip: IP_WIFI, rssi: -52 });
            }
        }
    }

    /// Message du JavaScript (relais, DoH, fetch) : remis tout de suite.
    pub fn depuis_js(&mut self, m: DeHote, now: u64) {
        if let DeHote::TcpRecu { data, .. } = &m {
            self.stats.octets_recus += data.len() as u64;
        }
        if let DeHote::TcpFerme { id } | DeHote::TcpEchec { id } = &m {
            self.js_ids.remove(id);
        }
        self.attente.push((now, m));
    }
}
