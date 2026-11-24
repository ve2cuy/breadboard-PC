// Onglet « Pico W · Réseau » : montage (Pico, lecteur de la carte, J16, READY), etat des
// registres 50h-57h, Wi-Fi, relais, journal du reseau.

import { t, getLang, onLang } from './i18n.js';
import { PontReseau } from './reseau.js';

const $ = (id) => document.getElementById(id);

function lire(k, d) { try { const v = localStorage.getItem('s02p.' + k); return v === null ? d : v; } catch (e) { return d; } }
function garder(k, v) { try { localStorage.setItem('s02p.' + k, v); } catch (e) { /* stockage indisponible */ } }

const BITS = ['DONNEE', 'OCCUPE', 'ERREUR', 'RESEAU', 'CARTE', 'WIFI', 'IRQ'];

const AIDE_EN = `The Pico W answers on ports <b>50h-57h</b> (O5 of the 74LS138, U18/U19). <b>BIOS 3.3</b> finds it at start-up:
the J14 SD card goes through it (≈ 20 times faster than the 8088's bit-banged SPI) and INT 14h DX=1 (the DOS <b>S02PKT</b> and
ELKS <b>ttyS1</b> drivers) becomes a SLIP link to the Pico, which relays TCP/IP to Wi-Fi.<br>
Try: <b>1) Load DOS</b>, pick <b>FDNET.IMG</b> (FreeDOS + mTCP), then <code>PING 8.8.8.8</code>, <code>HTGET http://www.s02/</code>,
<code>HTGET http://192.168.240.1/</code> (the Pico's status page); without the relay, sites that allow CORS: <code>HTGET http://api.ipify.org/</code> (public address),
<code>HTGET http://wttr.in/Montreal?format=3</code> (weather). With the relay (<code>python outils/relais.py</code>), the whole
Internet: <code>HTGET http://example.com/</code>, <code>TELNET</code>, <code>FTP</code>…`;

export class PanneauPico {
  constructor(S, log) {
    this.S = S;
    this.log = log;
    this.pont = new PontReseau(S.sim, {
      log: (k, m) => { log(k, m); this.journal(m); },
      onEtat: (e, txt) => this.etatRelais(e, txt),
    });
    this.dernier = { acces: 0, paquets: 0, sd: 0 };
    this.vu = { pico: 0, net: 0, sd: 0 };
  }

  /** Reglages gardes, puis le montage par defaut : ATmega, Pico, carte dans J14. */
  appliquer() {
    const sim = this.S.sim;
    const on = lire('pico', '1') === '1';
    sim.set_pico(on);
    sim.net_js(true);
    sim.set_sd_pico(on && lire('slot', 'j14') === 'j14');
    sim.set_pico_j16(lire('j16', '1') === '1');
    sim.set_pico_attentes(+lire('attente', '3'));
    this.pont.doh = lire('doh', '1') === '1';
    this.pont.fetch = lire('fetch', '1') === '1';
    $('picoOn').checked = on;
    $('picoSlot').value = lire('slot', 'j14');
    $('picoJ16').checked = lire('j16', '1') === '1';
    $('picoWait').value = lire('attente', '3');
    $('netDoh').checked = this.pont.doh;
    $('netFetch').checked = this.pont.fetch;
    $('netRelais').value = lire('relais', 'ws://127.0.0.1:8765');
    if (lire('relais_on', '0') === '1') this.pont.connecter($('netRelais').value);
  }

  construire() {
    const sim = this.S.sim;
    this.aideFr = $('picoAide').innerHTML;
    const aide = () => { $('picoAide').innerHTML = getLang() === 'en' ? AIDE_EN : this.aideFr; };
    aide();
    onLang(aide);
    $('picoOn').onchange = (e) => {
      const on = e.target.checked;
      garder('pico', on ? '1' : '0');
      sim.set_pico(on);
      sim.net_js(true);
      sim.set_sd_pico(on && $('picoSlot').value === 'j14');
      sim.set_pico_j16($('picoJ16').checked);
      sim.set_pico_attentes(+$('picoWait').value);
      this.log('i', on ? t('Pico W monté : le BIOS 3.3 le trouvera au prochain RESET.') : t('Pico W retiré : carte SD dans J9, réseau par le module de l\'ATmega.'));
      this.S.board.staticDirty = true;
    };
    $('picoSlot').onchange = (e) => {
      garder('slot', e.target.value);
      sim.set_sd_pico(e.target.value === 'j14');
      this.log('i', t('Carte SD dans {0} (prise en compte au prochain RESET ou 1) Load DOS).', e.target.value === 'j14' ? 'J14 (Pico)' : 'J9 (U12)'));
    };
    $('picoJ16').onchange = (e) => { garder('j16', e.target.checked ? '1' : '0'); sim.set_pico_j16(e.target.checked); };
    $('picoWait').onchange = (e) => { garder('attente', e.target.value); sim.set_pico_attentes(+e.target.value); };
    $('netDoh').onchange = (e) => { garder('doh', e.target.checked ? '1' : '0'); this.pont.doh = e.target.checked; };
    $('netFetch').onchange = (e) => { garder('fetch', e.target.checked ? '1' : '0'); this.pont.fetch = e.target.checked; };
    $('netRelaisBtn').onclick = () => {
      if (this.pont.relaisOk) { this.pont.deconnecter(); garder('relais_on', '0'); return; }
      garder('relais', $('netRelais').value);
      garder('relais_on', '1');
      this.pont.connecter($('netRelais').value);
    };
    $('netRelais').addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter') $('netRelaisBtn').click(); });
  }

  etatRelais(e, txt) {
    const b = $('netRelaisEtat');
    const m = {
      essai: t('connexion…'), ok: t('relais connecté') + (txt ? ' (' + txt.replace('S02RELAIS ', 'v') + ')' : ''),
      erreur: t('relais introuvable : python outils/relais.py'), aucun: t('aucun relais'),
    }[e];
    b.textContent = m;
    b.classList.toggle('ok', e === 'ok');
    b.classList.toggle('err', e === 'erreur');
    $('netRelaisBtn').textContent = e === 'ok' ? t('Déconnecter') : t('Connecter');
    if (e === 'ok' || e === 'erreur') this.journal(m);
  }

  journal(m) {
    const el = $('picoLog');
    if (!el) return;
    const d = document.createElement('div');
    d.textContent = m;
    el.appendChild(d);
    while (el.childElementCount > 300) el.firstChild.remove();
    el.scrollTop = el.scrollHeight;
  }

  /** A chaque image : pont reseau et voyants. */
  image(now) {
    const sim = this.S.sim;
    this.pont.pump();
    const a = sim.pico_acces();
    if (a !== this.dernier.acces) { this.dernier.acces = a; this.vu.pico = now; }
    const sd = sim.sd_stats();
    const n = sd[0] + sd[1];
    if (n !== this.dernier.sd) { this.dernier.sd = n; this.vu.sd = now; }
  }

  voyants(now, on) {
    return {
      pico: on && now - this.vu.pico < 80,
      net: on && now - this.vu.net < 120,
      sd: on && now - this.vu.sd < 80,
      wifi: this.wifi,
    };
  }

  /** Deux fois par seconde : etat detaille. */
  rafraichir(visible) {
    const sim = this.S.sim;
    const j = sim.pico_journal();
    if (j) for (const l of j.split('\n')) this.journal(l);
    let st = null;
    try { st = JSON.parse(sim.pico_state()); } catch (e) { st = null; }
    this.wifi = !!(st && st.wifi);
    if (st && st.paquets_8088 + st.paquets_vers_8088 !== this.dernier.paquets) {
      this.dernier.paquets = st.paquets_8088 + st.paquets_vers_8088;
      this.vu.net = performance.now();
    }
    if (!visible) return;
    if (!st) {
      $('picoArtEtat').textContent = t('absent');
      $('picoRegs').textContent = t('Pico W absent du montage : le BIOS garde le SPI de U12 et le module Wi-Fi de l\'ATmega.');
      $('picoNet').textContent = '';
      return;
    }
    const bits = BITS.filter((_, i) => st.etat & (1 << i)).join(' ') || '—';
    $('picoArtEtat').textContent = st.wifi ? 'Wi-Fi ' + st.ip : t('Wi-Fi déconnecté');
    $('picoRegs').textContent = [
      t('ETAT (51h) : {0}h  {1}', st.etat.toString(16).toUpperCase().padStart(2, '0'), bits),
      t('Accès du 8088 : {0} lectures, {1} écritures', st.lectures, st.ecritures),
      t('READY : {0} états d\'attente ({1} par lecture)', st.attentes_total, st.attentes),
      t('Carte de J14 : {0} ; secteurs lus {1}, écrits {2}', st.sd_pico ? Math.round(st.secteurs / 2048) + ' ' + t('Mo') : t('vide (carte dans J9)'), st.sd_lus, st.sd_ecrits),
      t('Commandes : {0} ; GP22 (IRQ3) : {1} {2}', st.commandes, st.irq ? 1 : 0, st.j16 ? t('(J16 posé)') : t('(J16 retiré)')),
    ].join('\n');
    const r = this.pont.stats;
    $('picoNet').textContent = [
      t('8088 {0} ⇄ Pico 192.168.240.1 ⇄ Wi-Fi {1} ({2} dBm)', st.ip_8088, st.ip, st.rssi),
      t('Paquets : {0} du 8088, {1} vers le 8088, {2} perdus ; octets TCP : {3} reçus, {4} envoyés', st.paquets_8088, st.paquets_vers_8088, st.perdus, st.octets_vers_8088, st.octets_du_8088),
      t('TCP : {0} ouvertes ({1} en cours) ; pings {2} ; UDP {3}', st.tcp_ouvertes, st.tcp, st.pings, st.udp),
      t('Page : DNS-over-HTTPS {0}, relais {1}, fetch {2}', r.doh, r.relais, r.fetch),
    ].join('\n');
  }
}
