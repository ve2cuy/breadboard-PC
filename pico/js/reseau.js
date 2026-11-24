// Pont reseau du Pico W simule : ce que l'Internet integre du simulateur (src/internet.rs :
// pings, zone s02, www.s02, page du Pico) ne sait pas faire, la page le fait :
//  - DNS des vrais noms : DNS-over-HTTPS (Cloudflare) ;
//  - TCP : relais WebSocket vers TCP (outils/relais.py, sur l'ordinateur) : vrai TCP/IP ;
//  - sans relais, HTTP (port 80) par fetch() du navigateur (sites qui le permettent) ;
//  - NTP (UDP 123) : heure de l'ordinateur.
// Le coeur du micrologiciel termine les connexions TCP du 8088 : ici on ne voit que des flux.

const DOH = 'https://cloudflare-dns.com/dns-query?dns=';

function b64dec(s) {
  const b = atob(s);
  const u = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
  return u;
}

function b64url(u) {
  let s = '';
  for (const x of u) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const enc = new TextEncoder();
const dec = new TextDecoder('latin1');

export class PontReseau {
  constructor(sim, hooks) {
    this.sim = sim;
    this.log = hooks.log || (() => {});
    this.onEtat = hooks.onEtat || (() => {});
    this.doh = true;
    this.fetch = true;
    this.url = 'ws://127.0.0.1:8765';
    this.relaisOk = false;
    this.conns = new Map();
    this.stats = { doh: 0, relais: 0, fetch: 0, octets: 0 };
    this.enCours = 0;          // requetes DoH et fetch en vol
  }

  /** Une operation reseau reelle est en cours : la page ramene la simulation au temps reel
   *  (sinon, en vitesse Max, les delais du 8088 expirent avant la reponse de l'Internet). */
  occupe() {
    return this.enCours > 0 || this.conns.size > 0;
  }

  /** Verifie le relais : il repond "S02RELAIS" a ?test=1. */
  connecter(url) {
    this.url = url.replace(/\/+$/, '');
    this.relaisOk = false;
    this.onEtat('essai');
    let ws;
    try { ws = new WebSocket(this.url + '/?test=1'); } catch (e) { this.onEtat('erreur'); return; }
    const fin = setTimeout(() => { try { ws.close(); } catch (e) { /* deja ferme */ } this.onEtat('erreur'); }, 3000);
    ws.onmessage = (e) => {
      if (typeof e.data === 'string' && e.data.startsWith('S02RELAIS')) {
        clearTimeout(fin);
        this.relaisOk = true;
        this.onEtat('ok', e.data);
        ws.close();
      }
    };
    ws.onerror = () => { clearTimeout(fin); this.onEtat('erreur'); };
  }

  deconnecter() {
    this.relaisOk = false;
    this.onEtat('aucun');
  }

  /** A chaque image : messages du Pico pour la page. */
  pump() {
    const t = this.sim.net_take();
    if (t === '[]') return;
    for (const m of JSON.parse(t)) {
      try { this.message(m); } catch (e) { this.log('w', 'Réseau : ' + e.message); }
    }
  }

  message(m) {
    switch (m.t) {
      case 'doh': this.dns(m.cle, b64dec(m.data)); break;
      case 'tcp_ouvrir': this.ouvrir(m.id, m.ip, m.port); break;
      case 'tcp_envoyer': { const c = this.conns.get(m.id); if (c) c.envoyer(b64dec(m.data)); break; }
      case 'tcp_fermer': { const c = this.conns.get(m.id); if (c) c.fermer(); this.conns.delete(m.id); break; }
      case 'udp': this.udp(m); break;
    }
  }

  dns(cle, q) {
    if (!this.doh) { this.sim.net_doh(cle, new Uint8Array(0)); return; }
    this.stats.doh++;
    this.enCours++;
    fetch(DOH + b64url(q), { headers: { accept: 'application/dns-message' } })
      .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error('HTTP ' + r.status))))
      .then((b) => this.sim.net_doh(cle, new Uint8Array(b)))
      .catch((e) => { this.log('w', 'DNS-over-HTTPS : ' + e.message); this.sim.net_doh(cle, new Uint8Array(0)); })
      .finally(() => { this.enCours--; });
  }

  ouvrir(id, ip, port) {
    if (this.relaisOk) {
      this.stats.relais++;
      this.conns.set(id, new ConnRelais(this, id, ip, port));
    } else if (this.fetch && port === 80) {
      this.stats.fetch++;
      this.conns.set(id, new ConnFetch(this, id, ip));
    } else {
      this.log('w', `TCP ${ip}:${port} : refusée (pas de relais ; python outils/relais.py)`);
      this.sim.net_tcp_echec(id);
    }
  }

  udp(m) {
    const d = b64dec(m.data);
    const ip = new Uint8Array(m.ip.split('.').map(Number));
    if (m.port === 123 && d.length >= 48) {
      // NTP : reponse du serveur avec l'heure de l'ordinateur
      const r = new Uint8Array(48);
      const dv = new DataView(r.buffer);
      r[0] = 0x24; r[1] = 2; r[2] = d[2]; r[3] = 0xEC;
      const ms = Date.now();
      const s = Math.floor(ms / 1000) + 2208988800;
      const f = Math.floor(((ms % 1000) / 1000) * 4294967296);
      r.set(d.subarray(40, 48), 24);
      for (const o of [16, 32, 40]) { dv.setUint32(o, s >>> 0); dv.setUint32(o + 4, f >>> 0); }
      this.sim.net_udp(ip, 123, m.sport, r);
    }
  }
}

/** Connexion par le relais WebSocket (outils/relais.py). */
class ConnRelais {
  constructor(pont, id, ip, port) {
    this.pont = pont; this.id = id; this.file = []; this.ouverte = false; this.finie = false;
    const ws = new WebSocket(`${pont.url}/?ip=${ip}&port=${port}`);
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    ws.onmessage = (e) => {
      if (typeof e.data === 'string') {
        if (e.data === 'OK') {
          this.ouverte = true;
          pont.sim.net_tcp_ouvert(id);
          for (const d of this.file) ws.send(d);
          this.file = [];
        }
        return;
      }
      const u = new Uint8Array(e.data);
      pont.stats.octets += u.length;
      pont.sim.net_tcp_recu(id, u);
    };
    ws.onclose = () => {
      pont.conns.delete(id);
      if (this.finie) return;
      this.finie = true;
      if (this.ouverte) pont.sim.net_tcp_ferme(id); else pont.sim.net_tcp_echec(id);
    };
    ws.onerror = () => { /* onclose suit */ };
  }
  envoyer(d) { if (this.ouverte) this.ws.send(d); else this.file.push(d); }
  fermer() { this.finie = true; try { this.ws.close(); } catch (e) { /* deja ferme */ } }
}

/** HTTP par fetch() : la requete du 8088 est relue, la reponse refaite en HTTP/1.0. */
class ConnFetch {
  constructor(pont, id, ip) {
    this.pont = pont; this.id = id; this.ip = ip; this.req = ''; this.partie = false;
    pont.sim.net_tcp_ouvert(id);
  }
  envoyer(d) {
    if (this.partie) return;
    this.req += dec.decode(d);
    const fin = this.req.indexOf('\r\n\r\n');
    if (fin < 0) return;
    this.partie = true;
    const lignes = this.req.slice(0, fin).split('\r\n');
    const [methode, chemin] = lignes[0].split(' ');
    const hote = (lignes.find((l) => /^host:/i.test(l)) || '').replace(/^host:\s*/i, '') || this.ip;
    const url = 'https://' + hote + (chemin && chemin.startsWith('/') ? chemin : '/');
    this.pont.log('i', `HTTP ${methode} ${url} (fetch)`);
    this.pont.enCours++;
    fetch(url, { method: methode === 'HEAD' ? 'HEAD' : 'GET', redirect: 'follow' })
      .then(async (r) => {
        const corps = new Uint8Array(methode === 'HEAD' ? 0 : await r.arrayBuffer()).slice(0, 1 << 20);
        const type = r.headers.get('content-type') || 'application/octet-stream';
        const tete = `HTTP/1.0 ${r.status} ${r.statusText || 'OK'}\r\nContent-Type: ${type}\r\n` +
          `Content-Length: ${corps.length}\r\nConnection: close\r\n\r\n`;
        this.repondre(enc.encode(tete), corps);
      })
      .catch((e) => {
        const p = enc.encode(`<html><body><h1>502</h1><p>${url} : ${e.message}.</p>` +
          '<p>Le navigateur refuse les sites qui ne permettent pas les requetes d\'autres origines (CORS). ' +
          'Lancer le relais (python outils/relais.py) et le connecter dans l\'onglet Pico W.</p>' +
          '<p>The browser blocks sites without CORS: start the relay (python outils/relais.py) and connect it in the Pico W tab.</p></body></html>\r\n');
        const tete = enc.encode(`HTTP/1.0 502 Bad Gateway\r\nContent-Type: text/html\r\nContent-Length: ${p.length}\r\nConnection: close\r\n\r\n`);
        this.repondre(tete, p);
      })
      .finally(() => { this.pont.enCours--; });
  }
  repondre(tete, corps) {
    const s = this.pont.sim;
    s.net_tcp_recu(this.id, tete);
    for (let i = 0; i < corps.length; i += 8192) s.net_tcp_recu(this.id, corps.subarray(i, i + 8192));
    this.pont.stats.octets += tete.length + corps.length;
    s.net_tcp_ferme(this.id);
    this.pont.conns.delete(this.id);
  }
  fermer() { this.partie = true; }
}
