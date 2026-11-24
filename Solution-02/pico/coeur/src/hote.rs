//! Messages entre le coeur et l'hote qui ouvre les vraies connexions : la pile Wi-Fi du Pico
//! (embassy-net) dans le micrologiciel, ou l'Internet du simulateur (DNS par DoH, relais
//! WebSocket, pages integrees). Le coeur termine les connexions TCP du 8088 (comme slirp) :
//! l'hote ne voit que des flux d'octets, des datagrammes UDP et des echos ICMP.

use alloc::vec::Vec;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VersHote {
    /// Le 8088 ouvre une connexion TCP vers ip:port (le coeur a deja repondu SYN-ACK).
    TcpOuvrir { id: u16, ip: [u8; 4], port: u16 },
    /// Octets du 8088 pour la connexion.
    TcpEnvoyer { id: u16, data: Vec<u8> },
    /// Le 8088 a ferme (FIN) ou abandonne la connexion.
    TcpFermer { id: u16 },
    /// Datagramme UDP du 8088 (port source sport) vers ip:port (DNS : port 53).
    Udp { sport: u16, ip: [u8; 4], port: u16, data: Vec<u8> },
    /// Echo ICMP (ping) vers ip.
    Ping { ip: [u8; 4], ident: u16, seq: u16, data: Vec<u8> },
    /// Joindre un reseau Wi-Fi (commande 32h).
    Wifi { ssid: Vec<u8>, mdp: Vec<u8> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeHote {
    /// La connexion distante est etablie.
    TcpOuvert { id: u16 },
    /// Octets recus de la connexion distante.
    TcpRecu { id: u16, data: Vec<u8> },
    /// Fin du flux distant (FIN).
    TcpFerme { id: u16 },
    /// Connexion refusee ou coupee : RST vers le 8088.
    TcpEchec { id: u16 },
    /// Datagramme UDP de ip:port vers le port dport du 8088.
    Udp { ip: [u8; 4], port: u16, dport: u16, data: Vec<u8> },
    /// Reponse a un echo.
    PingReponse { ip: [u8; 4], ident: u16, seq: u16, data: Vec<u8> },
    /// Etat du Wi-Fi : connecte, adresse du Pico sur le reseau local, puissance (dBm).
    Wifi { connecte: bool, ip: [u8; 4], rssi: i8 },
}
