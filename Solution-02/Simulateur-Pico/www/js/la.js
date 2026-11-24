// Analyseur logique 32 voies : capture declenchee (pre/post), zoom et deplacement, decodeurs
// UART (9600 8N1), PS/2, SPI (carte SD) et bus du 8088 (cycles memoire et E/S).

import { t } from './i18n.js';

const CLK = 16e6 / 3;
const TQ = 1 / (CLK * 4);                         // seconde par unite de temps (quart de cycle)
export const LA_COLORS = ['#8a8f96', '#a0622d', '#e0453d', '#f08a24', '#f2d22e', '#4ec95a', '#3f8cff', '#b06bff'];
const CTRL = { 0: 'NUL', 7: 'BEL', 8: 'BS', 9: 'TAB', 10: 'LF', 12: 'FF', 13: 'CR', 27: 'ESC', 127: 'DEL' };
/** Texte d'un octet : caractere imprimable, nom de controle ou hexadecimal. */
export function ascii(b) {
  if (b >= 0x20 && b < 0x7F) return b === 0x20 ? '␠' : String.fromCharCode(b);
  return CTRL[b] || hx(b, 2) + 'h';
}

/**
 * Types de decodeurs : libelle, parametres (pour le formulaire), configuration par defaut
 * devinee d'apres les noms des voies, et fonction de decodage (this = analyseur ; push(t0, t1,
 * texte, couleur, texte complet)).
 */
export const DECODERS = {
  bus8088: {
    label: 'Bus 8088', params: [],
    def: () => ({}),
    run(c, push) {
      const rd = this.chOf('~{RD}'), wr = this.chOf('~{WR}'), iom = this.chOf('IO/~{M}');
      const A = Array.from({ length: 20 }, (_, i) => this.chOf('A' + i));
      const Dd = Array.from({ length: 8 }, (_, i) => this.chOf('D' + i));
      if (!(rd || wr) || !Dd.some((x) => x)) return;
      for (const [ch, w] of [[rd, false], [wr, true]]) {
        if (!ch) continue;
        for (const tt of this.edges(ch, true)) {
          const s = tt - 2;
          let a = 0, d = 0;
          A.forEach((x, i) => { if (x && this.lv(x, s)) a |= 1 << i; });
          Dd.forEach((x, i) => { if (x && this.lv(x, s)) d |= 1 << i; });
          const io = iom ? this.lv(iom, s) : 0;
          const txt = `${io ? 'IO' : 'M'}${w ? 'W' : 'R'} ${io ? hx(a & 0xFFFF, 4) : hx(a, 5)}${w ? '←' : '→'}${hx(d, 2)}`;
          push(tt - 12, tt, txt, io ? (w ? '#ffb000' : '#3fd8ff') : (w ? '#ff7a6b' : '#5cff7a'));
        }
      }
    },
  },
  ascii: {
    label: 'ASCII (bus parallèle)',
    params: [{ k: 'src', label: 'Bits D0-D7', kind: 'sel', opts: [['names', 'voies D0..D7'], ['suite', '8 voies à partir de « Bit 0 »']] },
      { k: 'd0', label: 'Bit 0', kind: 'ch' },
      { k: 'strobe', label: 'Échantillon', kind: 'chopt' }, { k: 'edge', label: 'Front', kind: 'sel', opts: [['r', '↑'], ['f', '↓'], ['a', '↕']] },
      { k: 'strobe2', label: 'Échantillon 2', kind: 'chopt' }],
    def(la) {
      return { src: la.idx(/^D0$/) >= 0 ? 'names' : 'suite', d0: Math.max(0, la.idx(/^D0$/)),
        strobe: la.idx(/^~\{RD\}$/) >= 0 ? la.idx(/^~\{RD\}$/) : la.idx(/^U10-E$/), edge: la.idx(/^~\{RD\}$/) >= 0 ? 'r' : 'f', strobe2: la.idx(/^~\{WR\}$/) };
    },
    run(c, push) {
      const bits = c.src === 'names' ? Array.from({ length: 8 }, (_, i) => this.chOf('D' + i)) : Array.from({ length: 8 }, (_, i) => this.cd(c.d0 + i));
      if (!bits.some((x) => x)) return;
      const val = (tt) => { let b = 0; bits.forEach((x, i) => { if (x && this.lv(x, tt)) b |= 1 << i; }); return b; };
      const times = [];
      for (const s of [c.strobe, c.strobe2]) {
        const sc = this.cd(s);
        if (!sc) continue;
        if (c.edge === 'a') { times.push(...this.edges(sc, true), ...this.edges(sc, false)); } else times.push(...this.edges(sc, c.edge === 'r'));
      }
      if (!times.length && this.cd(c.strobe) === null && this.cd(c.strobe2) === null) {
        // sans signal d'echantillonnage : a chaque changement des donnees (stables 8 quarts de cycle)
        const all = [];
        bits.forEach((x) => { if (x) all.push(...x.t); });
        all.sort((a, b) => a - b);
        for (let i = 0; i < all.length; i++) if (i === all.length - 1 || all[i + 1] - all[i] > 8) times.push(all[i] + 4);
      }
      times.sort((a, b) => a - b);
      for (const tt of times) {
        const b = val(tt - 2);
        push(tt - 10, tt + 2, ascii(b), b >= 0x20 && b < 0x7F ? '#f2d22e' : '#a0a0a0', `${ascii(b)}  ${hx(b, 2)}h`);
      }
    },
  },
  uart: {
    label: 'UART',
    params: [{ k: 'ch', label: 'Voie', kind: 'ch' },
      { k: 'baud', label: 'Bauds', kind: 'sel', opts: [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200].map((b) => [b, String(b)]) },
      { k: 'bits', label: 'Bits', kind: 'sel', opts: [[5, '5'], [6, '6'], [7, '7'], [8, '8']] },
      { k: 'parity', label: 'Parité', kind: 'sel', opts: [['N', 'N'], ['E', 'E'], ['O', 'O']] },
      { k: 'stop', label: 'Arrêt', kind: 'sel', opts: [[1, '1'], [2, '2']] },
      { k: 'inv', label: 'Inversé', kind: 'sel', opts: [[0, 'non'], [1, 'oui']] },
      { k: 'fmt', label: 'Affichage', kind: 'sel', opts: [['ascii', 'ASCII'], ['hex', 'hex']] }],
    def(la) { const i = la.idx(/UART_TX/); return { ch: i >= 0 ? i : Math.max(0, la.idx(/UART|RX|TX/)), baud: 9600, bits: 8, parity: 'N', stop: 1, inv: 0, fmt: 'ascii' }; },
    run(c, push) {
      const ch = this.cd(c.ch);
      if (!ch) return;
      const bit = (CLK * 4) / c.baud, inv = +c.inv;
      const L = (tt) => this.lv(ch, tt) ^ inv;
      const nb = +c.bits, par = c.parity !== 'N' ? 1 : 0, len = 1 + nb + par + +c.stop;
      let k = 0;
      while (k < ch.t.length) {
        const ts = ch.t[k];
        const prev = (k > 0 ? ch.v[k - 1] : ch.base) ^ inv, cur = ch.v[k] ^ inv;
        if (!(prev === 1 && cur === 0)) { k++; continue; }
        let b = 0, ones = 0;
        for (let j = 0; j < nb; j++) if (L(ts + bit * (1.5 + j))) { b |= 1 << j; ones++; }
        let ok = true;
        if (par) { const p = L(ts + bit * (1.5 + nb)); ones += p; ok = c.parity === 'E' ? ones % 2 === 0 : ones % 2 === 1; }
        const stopOk = L(ts + bit * (len - 0.5)) === 1;
        const txt = c.fmt === 'hex' ? hx(b, 2) : ascii(b);
        push(ts, ts + bit * len, txt, ok && stopOk ? '#4ec95a' : '#e0453d', `${ascii(b)}  ${hx(b, 2)}h${ok ? '' : ' ' + t('(parité)')}${stopOk ? '' : ' ' + t('(trame)')}`);
        while (k < ch.t.length && ch.t[k] < ts + bit * (len - 0.4)) k++;
      }
    },
  },
  spi: {
    label: 'SPI',
    params: [{ k: 'clk', label: 'SCK', kind: 'ch' }, { k: 'mosi', label: 'MOSI', kind: 'chopt' }, { k: 'miso', label: 'MISO', kind: 'chopt' },
      { k: 'cs', label: 'CS#', kind: 'chopt' }, { k: 'mode', label: 'Mode', kind: 'sel', opts: [[0, '0 (CPOL 0, CPHA 0)'], [1, '1'], [2, '2'], [3, '3']] },
      { k: 'order', label: 'Ordre', kind: 'sel', opts: [['msb', 'MSB d’abord'], ['lsb', 'LSB d’abord']] }],
    def(la) { return { clk: Math.max(0, la.idx(/SCK|CLK/)), mosi: la.idx(/MOSI/), miso: la.idx(/MISO/), cs: la.idx(/_CS$|CS#|~\{CS/), mode: 0, order: 'msb' }; },
    run(c, push) {
      const sck = this.cd(c.clk);
      if (!sck) return;
      const mosi = this.cd(c.mosi), miso = this.cd(c.miso), cs = this.cd(c.cs);
      const rising = (+c.mode === 0 || +c.mode === 3);
      let n = 0, bo = 0, bi = 0, ts = 0;
      let lastCs = cs ? this.lv(cs, this.data.t0) : 0;
      for (const tt of this.edges(sck, rising)) {
        if (cs) {
          const l = this.lv(cs, tt);
          if (l) { n = 0; lastCs = l; continue; }
          if (lastCs) n = 0;
          lastCs = l;
        }
        if (!n) ts = tt;
        const o = mosi ? this.lv(mosi, tt) : 0, i = miso ? this.lv(miso, tt) : 1;
        if (c.order === 'lsb') { bo |= o << n; bi |= i << n; } else { bo = (bo << 1) | o; bi = (bi << 1) | i; }
        if (++n === 8) {
          const txt = (mosi ? hx(bo & 0xFF, 2) : '') + (mosi && miso ? '/' : '') + (miso ? hx(bi & 0xFF, 2) : '');
          push(ts - 4, tt + 4, txt, '#3f8cff', (mosi ? 'MOSI ' + hx(bo & 0xFF, 2) + '  ' : '') + (miso ? 'MISO ' + hx(bi & 0xFF, 2) : ''));
          n = 0; bo = bi = 0;
        }
      }
    },
  },
  i2c: {
    label: 'I²C',
    params: [{ k: 'scl', label: 'SCL', kind: 'ch' }, { k: 'sda', label: 'SDA', kind: 'ch' }],
    def(la) { return { scl: Math.max(0, la.idx(/SCL/)), sda: Math.max(0, la.idx(/SDA/)) }; },
    run(c, push) {
      const scl = this.cd(c.scl), sda = this.cd(c.sda);
      if (!scl || !sda || c.scl === c.sda) return;
      const ev = [];
      scl.t.forEach((tt, i) => ev.push([tt, 0, i]));
      sda.t.forEach((tt, i) => ev.push([tt, 1, i]));
      ev.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
      let busy = false, bits = [], nByte = 0, tByte = 0;
      for (const [tt, w, i] of ev) {
        if (w === 1) {
          const prev = i > 0 ? sda.v[i - 1] : sda.base, cur = sda.v[i];
          if (this.lv(scl, tt) !== 1 || prev === cur) continue;
          if (cur === 0) { push(tt - 20, tt + 20, busy ? 'Sr' : 'S', '#b06bff', busy ? t('START répété') : 'START'); busy = true; bits = []; nByte = 0; }
          else { push(tt - 20, tt + 20, 'P', '#b06bff', 'STOP'); busy = false; bits = []; }
          continue;
        }
        const prev = i > 0 ? scl.v[i - 1] : scl.base;
        if (!busy || !(prev === 0 && scl.v[i] === 1)) continue;
        if (!bits.length) tByte = tt;
        bits.push(this.lv(sda, tt + 1));
        if (bits.length === 9) {
          let b = 0;
          for (let j = 0; j < 8; j++) b = (b << 1) | bits[j];
          const ack = bits[8] === 0 ? 'A' : 'N';
          if (nByte === 0) push(tByte, tt, `${hx(b >> 1, 2)} ${b & 1 ? 'R' : 'W'} ${ack}`, '#f08a24', `${t('Adresse')} ${hx(b >> 1, 2)}h ${b & 1 ? t('lecture') : t('écriture')} ${ack === 'A' ? 'ACK' : 'NACK'}`);
          else push(tByte, tt, `${hx(b, 2)} ${ack}`, '#4ec95a', `${hx(b, 2)}h ${ack === 'A' ? 'ACK' : 'NACK'}`);
          nByte++; bits = [];
        }
      }
    },
  },
  ps2: {
    label: 'PS/2',
    params: [{ k: 'clk', label: 'CLK', kind: 'ch' }, { k: 'data', label: 'DATA', kind: 'ch' }],
    def(la) { return { clk: Math.max(0, la.idx(/KBD_CLK|PB0/)), data: Math.max(0, la.idx(/KBD_DATA|PB1/)) }; },
    run(c, push) {
      const kc = this.cd(c.clk), kd = this.cd(c.data);
      if (!kc || !kd) return;
      let bits = [], ts = 0;
      for (const tt of this.edges(kc, false)) {
        if (bits.length && tt - ts > CLK * 4 * 0.002) bits = [];
        if (!bits.length) ts = tt;
        bits.push(this.lv(kd, tt));
        if (bits.length === 11) {
          let b = 0;
          for (let j = 0; j < 8; j++) b |= bits[1 + j] << j;
          const ok = bits[0] === 0 && bits[10] === 1;
          push(ts - 200, tt + 200, hx(b, 2), ok ? '#f2d22e' : '#e0453d');
          bits = [];
        }
      }
    },
  },
};

export const LA_DEPTHS = [[20e-6, '20 µs'], [100e-6, '100 µs'], [500e-6, '500 µs'], [1e-3, '1 ms'], [2e-3, '2 ms'], [5e-3, '5 ms'],
  [10e-3, '10 ms'], [20e-3, '20 ms'], [50e-3, '50 ms'], [100e-3, '100 ms'], [200e-3, '200 ms'], [500e-3, '500 ms'], [1, '1 s'], [2, '2 s']];
const MAX_EVENTS = 4_000_000;

function fmt(s) {
  const a = Math.abs(s);
  if (a >= 1) return s.toFixed(3) + ' s';
  if (a >= 1e-3) return (s * 1e3).toFixed(a >= 0.1 ? 1 : 3) + ' ms';
  if (a >= 1e-6) return (s * 1e6).toFixed(a >= 1e-4 ? 1 : 2) + ' µs';
  return (s * 1e9).toFixed(0) + ' ns';
}
const hx = (v, n) => v.toString(16).toUpperCase().padStart(n, '0');

export class LogicAnalyzer {
  constructor(canvas, hooks) {
    this.cv = canvas;
    this.g = canvas.getContext('2d');
    this.hooks = hooks;            // { setProbes(), signalNow(i), names, onState(), onResults() }
    this.ch = new Array(32).fill(null);
    this.depth = 5;                // 5 ms
    this.pos = 0.1;
    this.trig = { ch: -1, edge: 'r' };
    this.state = 'idle';           // idle | wait | run | done
    this.continu = false;
    this.data = null;              // capture terminee : { t0, t1, T, ch: [{t:[],v:[],base}] }
    this.view = { t0: 0, span: 1 };
    this.results = [];
    this.decs = [];                // decodeurs : { id, type, on, cfg }
    this.decId = 0;
    this.hover = null;
    this.layout = [];
    this.bind();
  }

  // ------------------------------------------------------------------ voies
  ids() { return this.ch.filter((c) => c).map((c) => c.sig); }
  set(i, sig) {
    if (sig === null || sig === undefined) this.ch[i] = null;
    else this.ch[i] = { sig, name: this.hooks.names[sig] };
    this.hooks.setProbes();
  }
  add(sig) {
    if (this.ch.some((c) => c && c.sig === sig)) return this.ch.findIndex((c) => c && c.sig === sig);
    const i = this.ch.findIndex((c) => !c);
    if (i < 0) return -1;
    this.set(i, sig);
    return i;
  }
  clear() { this.ch.fill(null); this.trig.ch = -1; this.hooks.setProbes(); }
  preset(names) {
    this.ch.fill(null);
    names.slice(0, 32).forEach((n, i) => { const s = this.hooks.names.indexOf(n); if (s >= 0) this.ch[i] = { sig: s, name: n }; });
    this.hooks.setProbes();
  }

  // ------------------------------------------------------------------ capture
  get spanQ() { return LA_DEPTHS[this.depth][0] / TQ; }
  start(continu) {
    this.continu = !!continu;
    this.cap = { armT: this.hooks.now(), T: null, n: 0, ch: this.ch.map((c) => c && { sig: c.sig, t: [], v: [], base: this.hooks.signalNow(c.sig) }) };
    const pre = this.spanQ * this.pos;
    if (this.trig.ch < 0 || !this.ch[this.trig.ch]) { this.cap.T = this.cap.armT + pre; this.state = 'run'; }
    else this.state = 'wait';
    this.hooks.onState();
  }
  stop() {
    if (this.state === 'wait' || this.state === 'run') {
      if (this.cap && this.cap.T === null) { this.state = 'idle'; this.cap = null; }
      else this.finish(true);
    }
    this.continu = false;
    this.hooks.onState();
  }

  ingest(ev, now) {
    const cap = this.cap;
    if (!cap || (this.state !== 'wait' && this.state !== 'run')) return;
    const bySig = new Map();
    cap.ch.forEach((c) => { if (c) bySig.set(c.sig, c); });
    const pre = this.spanQ * this.pos, post = this.spanQ - pre;
    const tc = this.state === 'wait' ? cap.ch[this.trig.ch] : null;
    for (let k = 0; k + 2 < ev.length; k += 3) {
      const c = bySig.get(ev[k + 2] >> 8);
      if (!c) continue;
      const tt = ev[k] + ev[k + 1] * 4294967296, l = ev[k + 2] & 0xFF;
      const n = c.t.length;
      if (n && c.t[n - 1] > tt) {
        let j = n - 1;
        while (j >= 0 && c.t[j] > tt) j--;
        c.t.splice(j + 1, 0, tt); c.v.splice(j + 1, 0, l);
      } else { c.t.push(tt); c.v.push(l); }
      cap.n++;
      // declenchement : front de la voie choisie, avec assez d'avant-declenchement
      if (c === tc && cap.T === null && tt >= cap.armT + pre * 0.98) {
        const prev = c.v.length > 1 ? c.v[c.v.length - 2] : c.base;
        if (l !== prev && l !== 2 && (this.trig.edge === 'a' || (this.trig.edge === 'r' && l === 1) || (this.trig.edge === 'f' && l === 0))) {
          cap.T = tt; this.state = 'run'; this.hooks.onState();
        }
      }
    }
    // en attente : on ne garde que l'avant-declenchement
    if (this.state === 'wait') {
      const from = now - pre * 1.5;
      for (const c of cap.ch) {
        if (!c || c.t.length < 2000 || c.t[0] >= from) continue;
        let cut = 0;
        while (cut < c.t.length - 1 && c.t[cut] < from) cut++;
        c.base = c.v[cut - 1]; c.t.splice(0, cut); c.v.splice(0, cut); cap.n -= cut;
      }
    }
    if (this.state === 'run' && (now >= cap.T + post || cap.n > MAX_EVENTS)) this.finish(cap.n > MAX_EVENTS);
  }

  finish(cut) {
    const cap = this.cap;
    const pre = this.spanQ * this.pos;
    const t0 = cap.T - pre, t1 = cut ? Math.min(cap.T + this.spanQ - pre, this.hooks.now()) : cap.T + this.spanQ - pre;
    const ch = cap.ch.map((c) => {
      if (!c) return null;
      let a = 0;
      while (a < c.t.length && c.t[a] < t0) a++;
      const base = a > 0 ? c.v[a - 1] : c.base;
      let b = a;
      while (b < c.t.length && c.t[b] <= t1) b++;
      return { sig: c.sig, t: c.t.slice(a, b), v: c.v.slice(a, b), base };
    });
    this.data = { t0, t1, T: cap.T, ch, full: cap.n > MAX_EVENTS };
    this.view = { t0, span: t1 - t0 };
    this.cap = null;
    this.state = 'done';
    this.decodeAll();
    this.hooks.onState();
    if (this.continu) this.start(true);
  }

  // ------------------------------------------------------------------ decodeurs
  lv(c, tt) {
    if (!c) return 0;
    let lo = 0, hi = c.t.length - 1, r = -1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (c.t[m] <= tt) { r = m; lo = m + 1; } else hi = m - 1; }
    return (r < 0 ? c.base : c.v[r]) === 1 ? 1 : 0;
  }
  chOf(name) {
    if (!this.data) return null;
    const i = this.ch.findIndex((c) => c && c.name === name);
    return i >= 0 ? this.data.ch[i] : null;
  }
  edges(c, rising) {
    const out = [];
    if (!c) return out;
    for (let i = 0; i < c.t.length; i++) {
      const prev = i > 0 ? c.v[i - 1] : c.base;
      if (rising ? prev === 0 && c.v[i] === 1 : prev === 1 && c.v[i] === 0) out.push(c.t[i]);
    }
    return out;
  }

  /** Capture de la voie numero i (ou null). */
  cd(i) { return this.data && i !== undefined && i !== null && i >= 0 ? this.data.ch[i] || null : null; }
  /** Numero de la voie dont le nom correspond (ou -1). */
  idx(re) { return this.ch.findIndex((c) => c && re.test(c.name)); }

  addDecoder(type, cfg = {}) {
    const T = DECODERS[type];
    const d = { id: ++this.decId, type, on: true, cfg: { ...T.def(this), ...cfg } };
    this.decs.push(d);
    this.decodeAll();
    return d;
  }
  removeDecoder(id) { this.decs = this.decs.filter((d) => d.id !== id); this.decodeAll(); }
  decName(d) {
    const T = DECODERS[d.type];
    const c = d.cfg;
    const n = (i) => (i >= 0 && this.ch[i] ? short(this.ch[i].name) : '—');
    switch (d.type) {
      case 'uart': return `UART ${n(c.ch)}`;
      case 'spi': return `SPI ${n(c.mosi)}/${n(c.miso)}`;
      case 'i2c': return `I²C ${n(c.sda)}`;
      case 'ascii': return 'ASCII D0-D7';
      case 'ps2': return `PS/2 ${n(c.data)}`;
      default: return t(T.label);
    }
  }

  decodeAll() {
    const rows = [], res = [];
    if (this.data) {
      for (const d of this.decs) {
        if (!d.on) continue;
        const cells = [], name = this.decName(d);
        const push = (t0, t1, txt, col, full) => { cells.push({ t0, t1, txt, col }); res.push({ t: t0, dec: name, txt: full || txt }); };
        try { DECODERS[d.type].run.call(this, d.cfg, push); } catch (e) { console.error(e); }
        cells.sort((x, y) => x.t0 - y.t0);
        rows.push({ name, cells });
      }
    }
    res.sort((x, y) => x.t - y.t);
    this.rows = rows;
    this.results = res;
    this.hooks.onResults && this.hooks.onResults();
  }

  // ------------------------------------------------------------------ vue
  bind() {
    const cv = this.cv;
    const pt = (e) => { const r = cv.getBoundingClientRect(); const d = window.devicePixelRatio || 1; return [(e.clientX - r.left) * d, (e.clientY - r.top) * d]; };
    let drag = null;
    cv.addEventListener('wheel', (e) => {
      e.preventDefault();
      if (!this.data) return;
      const [x] = pt(e);
      const tt = this.pxT(x);
      const f = Math.exp(e.deltaY * 0.0018);
      const span = Math.max(8, Math.min(this.data.t1 - this.data.t0, this.view.span * f));
      this.view.t0 = tt - (tt - this.view.t0) * (span / this.view.span);
      this.view.span = span;
      this.clampView();
    }, { passive: false });
    cv.addEventListener('mousedown', (e) => {
      const [x, y] = pt(e);
      const lane = this.layout.find((l) => y >= l.y && y < l.y + l.h);
      if (x < this.L && lane && lane.ch !== undefined) { this.hooks.onLaneClick && this.hooks.onLaneClick(lane.ch, e); return; }
      drag = { x, t0: this.view.t0 };
    });
    window.addEventListener('mousemove', (e) => {
      const [x, y] = pt(e);
      if (drag && this.data) {
        this.view.t0 = drag.t0 - ((x - drag.x) / this.W) * this.view.span;
        this.clampView();
      }
      this.hover = e.target === cv ? [x, y] : null;
    });
    window.addEventListener('mouseup', () => { drag = null; });
    cv.addEventListener('dblclick', () => { if (this.data) this.view = { t0: this.data.t0, span: this.data.t1 - this.data.t0 }; });
  }
  clampView() {
    const D = this.data;
    this.view.t0 = Math.max(D.t0 - this.view.span * 0.05, Math.min(D.t1 - this.view.span * 0.95, this.view.t0));
  }
  pxT(x) { return this.view.t0 + ((x - this.L) / this.W) * this.view.span; }
  goTo(tt) { if (!this.data) return; this.view.span = Math.min(this.view.span, 4 * CLK * 0.002); this.view.t0 = tt - this.view.span * 0.3; this.clampView(); }

  draw() {
    const cv = this.cv, g = this.g;
    const d = window.devicePixelRatio || 1;
    // hauteur du canevas selon le nombre de voies et de lignes de decodage
    const nRows = ((this.data && this.rows) || []).filter((r) => r.cells.length).length + Math.max(1, this.ch.filter((c) => c).length);
    const needH = 26 + 8 + nRows * 22 + 20;
    if (Math.abs(cv.clientHeight - needH) > 2) cv.style.height = needH + 'px';
    const r = cv.getBoundingClientRect();
    if (cv.width !== Math.round(r.width * d) || cv.height !== Math.round(r.height * d)) { cv.width = Math.round(r.width * d); cv.height = Math.round(r.height * d); }
    const Wc = cv.width, Hc = cv.height;
    g.fillStyle = '#1f1f1f'; g.fillRect(0, 0, Wc, Hc);
    const L = this.L = 112 * d, RT = 26 * d;
    const W = this.W = Wc - L - 6 * d;
    const D = this.data;
    const v = this.view;
    // regle de temps
    g.fillStyle = '#252525'; g.fillRect(L, 0, W, RT);
    g.strokeStyle = '#7d7d7d'; g.fillStyle = '#c8c8c8'; g.font = `${10 * d}px "Segoe UI", Arial`; g.textAlign = 'center'; g.textBaseline = 'top';
    const ticks = 12;
    for (let i = 0; i <= ticks * 5; i++) {
      const x = L + (W * i) / (ticks * 5);
      g.beginPath(); g.moveTo(x + 0.5, RT - (i % 5 ? 4 : 9) * d); g.lineTo(x + 0.5, RT); g.stroke();
      if (i % 5 === 0 && D) {
        const tt = v.t0 + (v.span * i) / (ticks * 5) - D.T;
        g.fillText((tt >= 0 ? '+' : '') + fmt(tt * TQ), x, 2 * d);
      }
    }
    // voies et lignes de decodage
    const lanes = [];
    for (const row of (D && this.rows) || []) if (row.cells.length) lanes.push({ dec: row, h: 22 * d });
    this.ch.forEach((c, i) => { if (c) lanes.push({ ch: i, h: 22 * d }); });
    if (!this.ch.some((c) => c)) lanes.push({ empty: true, h: 40 * d });
    let y = RT + 4 * d;
    this.layout = [];
    g.textBaseline = 'middle';
    for (const ln of lanes) {
      ln.y = y;
      this.layout.push(ln);
      const mid = y + ln.h / 2;
      if (ln.empty) {
        g.fillStyle = '#9a9a9a'; g.font = `${12 * d}px "Segoe UI", Arial`; g.textAlign = 'left';
        g.fillText(t('Choisir des voies (préréglage ou clic sur une broche de la carte), puis Démarrer.'), L + 10 * d, mid);
      } else if (ln.dec) {
        g.fillStyle = '#3a3a3a'; rr(g, 6 * d, y + 3 * d, 18 * d, ln.h - 6 * d, 3 * d); g.fill();
        g.fillStyle = '#e6e6e6'; g.font = `bold ${10 * d}px Arial`; g.textAlign = 'center'; g.fillText('D', 15 * d, mid);
        g.textAlign = 'left'; g.font = `${11 * d}px "Segoe UI", Arial`; g.fillText(ln.dec.name, 28 * d, mid);
        this.drawCells(g, ln.dec.cells, L, W, mid, d);
      } else {
        const i = ln.ch, c = this.ch[i];
        const col = LA_COLORS[i % 8];
        g.fillStyle = col; rr(g, 6 * d, y + 3 * d, 22 * d, ln.h - 6 * d, 3 * d); g.fill();
        g.fillStyle = i % 8 === 4 || i % 8 === 5 ? '#000' : '#fff'; g.font = `bold ${10 * d}px Arial`; g.textAlign = 'center'; g.fillText(String(i), 17 * d, mid);
        g.fillStyle = '#e6e6e6'; g.textAlign = 'left'; g.font = `${11 * d}px "Segoe UI", Arial`;
        g.fillText(short(c.name), 32 * d, mid);
        // icone de declenchement
        const trig = this.trig.ch === i;
        g.fillStyle = trig ? '#ffb000' : '#5a5a5a'; g.font = `bold ${11 * d}px Arial`; g.textAlign = 'center';
        g.fillText(trig ? ({ r: '↑', f: '↓', a: '↕' }[this.trig.edge]) : '×', L - 10 * d, mid);
        g.strokeStyle = '#2c2c2c'; g.beginPath(); g.moveTo(L, y + ln.h - 0.5); g.lineTo(L + W, y + ln.h - 0.5); g.stroke();
        if (D && D.ch[i]) this.drawWave(g, D.ch[i], col, L, W, y + 5 * d, y + ln.h - 5 * d, d);
      }
      y += ln.h;
    }
    // repere de declenchement
    if (D) {
      const x = L + ((D.T - v.t0) / v.span) * W;
      if (x >= L && x <= L + W) {
        g.strokeStyle = 'rgba(255,176,0,0.7)'; g.setLineDash([4 * d, 3 * d]);
        g.beginPath(); g.moveTo(x, RT); g.lineTo(x, y); g.stroke(); g.setLineDash([]);
        g.fillStyle = '#ffb000'; g.beginPath(); g.moveTo(x - 5 * d, RT); g.lineTo(x + 5 * d, RT); g.lineTo(x, RT + 7 * d); g.fill();
      }
    }
    // curseur
    if (this.hover && D && this.hover[0] > L) {
      const x = this.hover[0];
      g.strokeStyle = 'rgba(255,255,255,0.35)'; g.beginPath(); g.moveTo(x + 0.5, RT); g.lineTo(x + 0.5, y); g.stroke();
      const tt = (this.pxT(x) - D.T) * TQ;
      g.fillStyle = 'rgba(0,0,0,0.75)'; rr(g, x + 6 * d, RT + 4 * d, 92 * d, 18 * d, 3 * d); g.fill();
      g.fillStyle = '#fff'; g.font = `${11 * d}px "Cascadia Mono", Consolas, monospace`; g.textAlign = 'left';
      g.fillText((tt >= 0 ? '+' : '') + fmt(tt), x + 11 * d, RT + 13 * d);
    }
    // etat
    g.textAlign = 'right'; g.font = `${11 * d}px "Segoe UI", Arial`; g.fillStyle = '#9a9a9a'; g.textBaseline = 'bottom';
    const stTxt = { idle: t('Arrêté'), wait: t('Attente du déclenchement…'), run: t('Capture…'), done: t('Capture terminée') }[this.state];
    g.fillText(stTxt + (D ? ` · ${fmt((D.t1 - D.t0) * TQ)} · ${t('résolution')} 47 ns${D.full ? ' · ' + t('mémoire pleine') : ''}` : ''), Wc - 8 * d, Hc - 4 * d);
  }

  drawWave(g, c, col, L, W, yHi, yLo, d) {
    const v = this.view;
    const end = v.t0 + v.span;
    const X = (tt) => L + ((tt - v.t0) / v.span) * W;
    // densite : trop de fronts par pixel -> bloc plein
    let lo = 0, hi = c.t.length;
    while (lo < hi) { const m = (lo + hi) >> 1; if (c.t[m] < v.t0) lo = m + 1; else hi = m; }
    let i = lo;
    let lvl = i > 0 ? c.v[i - 1] : c.base;
    g.strokeStyle = col; g.lineWidth = 1.2 * d;
    g.beginPath();
    let px = L;
    const yOf = (l) => (l === 1 ? yHi : l === 0 ? yLo : (yHi + yLo) / 2);
    g.moveTo(px, yOf(lvl));
    let blockFrom = -1;
    for (; i < c.t.length && c.t[i] <= end; i++) {
      const x = X(c.t[i]);
      if (x - px < 1.2) {
        if (blockFrom < 0) blockFrom = px;
        lvl = c.v[i];
        px = x;
        continue;
      }
      if (blockFrom >= 0) {
        g.stroke();
        g.fillStyle = col; g.fillRect(blockFrom, yHi, Math.max(1, px - blockFrom), yLo - yHi);
        g.beginPath(); g.moveTo(px, yOf(lvl));
        blockFrom = -1;
      }
      g.lineTo(x, yOf(lvl));
      lvl = c.v[i];
      g.lineTo(x, yOf(lvl));
      px = x;
    }
    if (blockFrom >= 0) { g.stroke(); g.fillStyle = col; g.fillRect(blockFrom, yHi, Math.max(1, px - blockFrom), yLo - yHi); g.beginPath(); g.moveTo(px, yOf(lvl)); }
    g.lineTo(L + W, yOf(lvl));
    g.stroke();
  }

  drawCells(g, cells, L, W, mid, d) {
    const v = this.view;
    const X = (tt) => L + ((tt - v.t0) / v.span) * W;
    const hh = 8 * d;
    let lastX = -1e9, dense = 0;
    g.font = `bold ${10 * d}px "Segoe UI", Arial`; g.textAlign = 'center';
    for (const c of cells) {
      if (c.t1 < v.t0 || c.t0 > v.t0 + v.span) continue;
      const x0 = X(c.t0), x1 = Math.max(x0 + 3 * d, X(c.t1));
      if (x0 < lastX + 1) { dense++; continue; }
      lastX = x1;
      const cut = Math.min(5 * d, (x1 - x0) / 3);
      g.fillStyle = c.col;
      g.beginPath(); g.moveTo(x0, mid); g.lineTo(x0 + cut, mid - hh); g.lineTo(x1 - cut, mid - hh); g.lineTo(x1, mid); g.lineTo(x1 - cut, mid + hh); g.lineTo(x0 + cut, mid + hh); g.closePath(); g.fill();
      if (x1 - x0 > g.measureText(c.txt).width + 8 * d) { g.fillStyle = '#111'; g.fillText(c.txt, (x0 + x1) / 2, mid + 0.5 * d); }
    }
    if (dense > 20) {
      g.fillStyle = 'rgba(200,200,200,0.7)'; g.font = `${10 * d}px "Segoe UI", Arial`; g.textAlign = 'center';
      g.fillText('— ' + t('Zoomer pour les détails') + ' —', L + W / 2, mid);
    }
  }
}

function short(s) { s = String(s).replace(/~\{([^}]*)\}/g, '/$1'); return s.length > 10 ? s.slice(0, 10) + '…' : s; }
function rr(g, x, y, w, h, r) {
  g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
}
