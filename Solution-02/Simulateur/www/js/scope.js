// Oscilloscope numerique 4 voies (DSO de table) : sondes sur les nets de la carte, traces
// d'allure analogique 0-5 V, declenchement sur front, curseurs, mesures, decodage UART et PS/2.

import { t } from './i18n.js';

const CLK = 16e6 / 3;               // horloge du 8088
const TQ = 1 / (CLK * 4);           // un quart de cycle (unite des instants), en secondes
const BASES = [
  [250e-9, '250ns'], [500e-9, '500ns'], [1e-6, '1.00µs'], [2e-6, '2.00µs'], [5e-6, '5.00µs'], [10e-6, '10.0µs'],
  [20e-6, '20.0µs'], [50e-6, '50.0µs'], [100e-6, '100µs'], [200e-6, '200µs'], [500e-6, '500µs'], [1e-3, '1.00ms'],
  [2e-3, '2.00ms'], [5e-3, '5.00ms'], [10e-3, '10.0ms'], [20e-3, '20.0ms'], [50e-3, '50.0ms'], [100e-3, '100ms'],
  [200e-3, '200ms'], [500e-3, '500ms'],
];
export const DSO_COLORS = ['#f5e04a', '#3fd8ff', '#ff5ccd', '#4d8dff'];
const SYNTH = { CLK: { per: 4, high: 4 / 3, label: '5.333 MHz' }, PCLK: { per: 8, high: 4, label: '2.667 MHz' }, OSC: { per: 4 / 3, high: 2 / 3, label: '16 MHz' } };
const MAXEV = 150000;

export function fmtTime(s) {
  const a = Math.abs(s);
  if (a >= 1) return s.toFixed(3) + ' s';
  if (a >= 1e-3) return (s * 1e3).toFixed(3) + ' ms';
  if (a >= 1e-6) return (s * 1e6).toFixed(2) + ' µs';
  return (s * 1e9).toFixed(0) + ' ns';
}
export function fmtFreq(f) {
  if (!isFinite(f) || f <= 0) return '—';
  if (f >= 1e6) return (f / 1e6).toFixed(3) + ' MHz';
  if (f >= 1e3) return (f / 1e3).toFixed(3) + ' kHz';
  return f.toFixed(2) + ' Hz';
}
function rnd(x) { const s = Math.sin(x * 12.9898) * 43758.5453; return s - Math.floor(s); }

export class Scope {
  constructor(canvas, hooks) {
    this.cv = canvas;
    this.g = canvas.getContext('2d');
    this.hooks = hooks;          // { setProbes(), signalNow(i), onTb(i) }
    this.ch = [null, null, null, null];
    this.sel = 0;                // voie choisie (bouton 1-4) pour la prochaine sonde
    this.tb = 8;                 // 100 µs/div
    this.trig = { ch: 0, edge: 'r' };
    this.mode = 'auto';
    this.running = true;
    this.pos = 0.5;
    this.t0 = 0;
    this.now = 0;
    this.status = 'AUTO';
    this.cursor = null;
    this.mA = null; this.mB = null;
    this.showCursor = true;
    this.showMeas = true;
    this.armT = 0;
    this.bind();
  }

  get span() { return (BASES[this.tb][0] * 10) / TQ; }
  static bases() { return BASES.map((b) => b[1]); }
  setTb(i) { this.tb = Math.max(0, Math.min(BASES.length - 1, i)); }

  bind() {
    const cv = this.cv;
    const x = (e) => (e.clientX - cv.getBoundingClientRect().left) * (window.devicePixelRatio || 1);
    let down = false;
    cv.addEventListener('mousemove', (e) => { this.cursor = x(e); if (down) this.mB = this.pxToT(this.cursor); });
    cv.addEventListener('mouseleave', () => { this.cursor = null; });
    cv.addEventListener('mousedown', (e) => { down = true; this.mA = this.pxToT(x(e)); this.mB = null; });
    window.addEventListener('mouseup', () => { down = false; });
    cv.addEventListener('dblclick', () => { this.mA = this.mB = null; });
    cv.addEventListener('wheel', (e) => {
      e.preventDefault();
      this.setTb(this.tb + (e.deltaY > 0 ? 1 : -1));
      this.hooks.onTb && this.hooks.onTb(this.tb);
    }, { passive: false });
  }

  // ------------------------------------------------------------------ voies
  ids() { return this.ch.filter((c) => c && c.sig !== null).map((c) => c.sig); }
  same(c, def) { return c && ((def.sig !== null && c.sig === def.sig) || (def.synth && c.synth === def.synth)); }
  /** Pose la sonde sur la voie choisie (ou la premiere libre). Rend le numero de voie. */
  add(def, slot) {
    const dup = this.ch.findIndex((c) => this.same(c, def));
    if (dup >= 0) return dup;
    let i = slot ?? (this.ch[this.sel] ? this.ch.findIndex((c) => !c) : this.sel);
    if (i < 0) i = this.sel;
    this.ch[i] = { ...def, color: DSO_COLORS[i], t: [], v: [], base: def.sig !== null ? this.hooks.signalNow(def.sig) : 0, baseT: this.now };
    this.sel = (i + 1) % 4;
    if (!this.ch[this.trig.ch]) this.trig.ch = i;
    this.hooks.setProbes();
    return i;
  }
  find(def) { return this.ch.findIndex((c) => this.same(c, def)); }
  remove(i) { this.ch[i] = null; if (this.trig.ch === i) this.trig.ch = Math.max(0, this.ch.findIndex((c) => c)); this.hooks.setProbes(); }
  clear() { this.ch = [null, null, null, null]; this.hooks.setProbes(); }
  resetData() {
    for (const c of this.ch) {
      if (!c || c.sig === null) continue;
      c.base = this.hooks.signalNow(c.sig); c.baseT = this.now; c.t = []; c.v = [];
    }
  }

  /** Evenements du simulateur : triplets (t_bas, t_haut, signal<<8|niveau). now en quarts de cycle. */
  ingest(ev, now) {
    this.now = now;
    if (!this.running) return;
    const bySig = new Map();
    for (const c of this.ch) if (c && c.sig !== null) bySig.set(c.sig, c);
    if (!bySig.size) return;
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
    }
    const keepFrom = now - Math.max(this.span * 3, CLK);
    for (const c of this.ch) {
      if (!c || c.synth) continue;
      if (c.t.length > MAXEV || (c.t.length > 1000 && c.t[0] < keepFrom)) {
        let cut = c.t.length > MAXEV ? c.t.length - MAXEV / 2 : 0;
        while (cut < c.t.length - 1 && c.t[cut] < keepFrom) cut++;
        if (cut > 0) { c.base = c.v[cut - 1]; c.baseT = c.t[cut - 1]; c.t.splice(0, cut); c.v.splice(0, cut); }
      }
    }
  }

  levelAt(c, tt) {
    if (c.synth) { const s = SYNTH[c.synth]; return (tt % s.per) < s.high ? 1 : 0; }
    let lo = 0, hi = c.t.length - 1, r = -1;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (c.t[m] <= tt) { r = m; lo = m + 1; } else hi = m - 1; }
    return r < 0 ? c.base : c.v[r];
  }
  idxAfter(c, tt) {
    let lo = 0, hi = c.t.length;
    while (lo < hi) { const m = (lo + hi) >> 1; if (c.t[m] < tt) lo = m + 1; else hi = m; }
    return lo;
  }

  findTrigger(before, after = -Infinity) {
    const c = this.ch[this.trig.ch];
    if (!c || c.synth) return null;
    for (let i = c.t.length - 1; i >= 0; i--) {
      const tt = c.t[i];
      if (tt > before) continue;
      if (tt < after) return null;
      const prev = i > 0 ? c.v[i - 1] : c.base;
      const v = c.v[i];
      if (v === prev || v === 2) continue;
      if (this.trig.edge === 'a' || (this.trig.edge === 'r' && v === 1) || (this.trig.edge === 'f' && v === 0)) return tt;
    }
    return null;
  }

  arm() { this.running = true; this.armT = this.now; }

  update() {
    if (!this.running) { this.status = 'STOP'; return; }
    const span = this.span;
    const latest = this.now - span * (1 - this.pos);
    if (!this.ch.some((c) => c)) { this.status = 'AUTO'; this.t0 = this.now - span; return; }
    const T = this.findTrigger(latest, this.mode === 'single' ? this.armT : this.now - span * 50);
    if (T !== null) {
      this.t0 = T - span * this.pos;
      this.status = "T'D";
      if (this.mode === 'single') { this.running = false; this.status = 'STOP'; }
    } else if (this.mode === 'auto') {
      this.t0 = this.now - span;
      this.status = 'AUTO';
    } else this.status = 'WAIT';
  }

  /** Base de temps automatique : 2 a 3 periodes du signal de declenchement a l'ecran. */
  autoset() {
    const c = this.ch[this.trig.ch];
    if (!c || c.t.length < 4) return;
    const n = c.t.length;
    let per = 0, k = 0;
    for (let i = n - 1; i > 0 && k < 20; i--) if (c.v[i] === 1 && c.v[i - 1] !== 1) {
      for (let j = i - 1; j > 0; j--) if (c.v[j] === 1 && c.v[j - 1] !== 1) { per += c.t[i] - c.t[j]; k++; break; }
    }
    if (!k) return;
    const target = (per / k) * TQ * 3 / 10;
    let best = 0;
    for (let i = 0; i < BASES.length; i++) if (BASES[i][0] <= target) best = i;
    this.setTb(best);
    this.mode = 'auto';
    this.running = true;
  }

  pxToT(px) { return this.t0 + ((px - this.gx) / this.gw) * this.span; }

  // ------------------------------------------------------------------ dessin
  draw() {
    const cv = this.cv, g = this.g;
    const dpr = window.devicePixelRatio || 1;
    const r = cv.getBoundingClientRect();
    if (cv.width !== Math.round(r.width * dpr) || cv.height !== Math.round(r.height * dpr)) {
      cv.width = Math.round(r.width * dpr); cv.height = Math.round(r.height * dpr);
    }
    const W = cv.width, H = cv.height, d = dpr;
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    // ---- barre du haut
    const TB = 24 * d;
    g.fillStyle = '#101418'; g.fillRect(0, 0, W, TB);
    g.font = `bold italic ${13 * d}px "Segoe UI", Arial, sans-serif`; g.textBaseline = 'middle'; g.textAlign = 'left';
    g.fillStyle = '#f2c230'; g.fillText('S02', 8 * d, TB / 2);
    g.fillStyle = '#d6dbe0'; g.fillText('LAB', 34 * d, TB / 2);
    let x = 68 * d;
    const pill = (label, txt, col, w) => {
      g.fillStyle = '#1d242b'; rr(g, x, 3 * d, w * d, TB - 6 * d, 4 * d); g.fill();
      g.fillStyle = col; g.beginPath(); g.arc(x + 9 * d, TB / 2, 7 * d, 0, 7); g.fill();
      g.fillStyle = '#111'; g.font = `bold ${10 * d}px "Segoe UI", Arial`; g.textAlign = 'center'; g.fillText(label, x + 9 * d, TB / 2 + 0.5 * d);
      g.fillStyle = '#e6eaee'; g.font = `${11 * d}px "Cascadia Mono", Consolas, monospace`; g.textAlign = 'left'; g.fillText(txt, x + 20 * d, TB / 2 + 0.5 * d);
      x += (w + 5) * d;
    };
    const st = this.status;
    const stc = st === 'STOP' ? '#ff4d4d' : st === 'WAIT' ? '#ffb000' : '#3ee07a';
    g.fillStyle = '#1d242b'; rr(g, x, 3 * d, 48 * d, TB - 6 * d, 4 * d); g.fill();
    g.fillStyle = stc; g.font = `bold ${11 * d}px "Segoe UI", Arial`; g.textAlign = 'center'; g.fillText(st, x + 24 * d, TB / 2 + 0.5 * d);
    x += 53 * d;
    pill('H', BASES[this.tb][1] + '/', '#f08a24', 86);
    const tc = this.ch[this.trig.ch];
    pill('T', (tc ? (this.trig.ch + 1) + ' ' : '— ') + ({ r: '↑', f: '↓', a: '↕' }[this.trig.edge]) + ' 1.40V', '#f08a24', 92);
    if (W - x > 120 * d) pill('D', fmtTime((this.t0 + this.span * this.pos) * TQ), '#f08a24', 96);
    // ---- zone des traces
    const BB = 30 * d;                     // boites des voies en bas
    const gx = this.gx = 4 * d, gy = TB + 4 * d, gw = this.gw = W - 8 * d, gh = H - TB - BB - 8 * d;
    g.fillStyle = '#05080a'; g.fillRect(gx, gy, gw, gh);
    g.strokeStyle = 'rgba(160,160,160,0.22)'; g.lineWidth = 1;
    g.setLineDash([1 * d, 4 * d]);
    for (let i = 1; i < 10; i++) { const xx = Math.round(gx + (gw * i) / 10) + 0.5; g.beginPath(); g.moveTo(xx, gy); g.lineTo(xx, gy + gh); g.stroke(); }
    for (let i = 1; i < 8; i++) { const yy = Math.round(gy + (gh * i) / 8) + 0.5; g.beginPath(); g.moveTo(gx, yy); g.lineTo(gx + gw, yy); g.stroke(); }
    g.setLineDash([]);
    g.strokeStyle = 'rgba(200,200,200,0.45)';
    const cx = gx + gw / 2, cy = gy + gh / 2;
    g.beginPath(); g.moveTo(gx, cy + 0.5); g.lineTo(gx + gw, cy + 0.5); g.moveTo(cx + 0.5, gy); g.lineTo(cx + 0.5, gy + gh); g.stroke();
    for (let i = 0; i <= 50; i++) { const xx = gx + (gw * i) / 50; g.beginPath(); g.moveTo(xx, cy - 3 * d); g.lineTo(xx, cy + 3 * d); g.stroke(); }
    for (let i = 0; i <= 40; i++) { const yy = gy + (gh * i) / 40; g.beginPath(); g.moveTo(cx - 3 * d, yy); g.lineTo(cx + 3 * d, yy); g.stroke(); }
    g.strokeStyle = 'rgba(200,200,200,0.5)'; g.strokeRect(gx + 0.5, gy + 0.5, gw - 1, gh - 1);
    // repere du declenchement (position horizontale)
    const tx = gx + gw * this.pos;
    g.fillStyle = '#f08a24';
    g.beginPath(); g.moveTo(tx - 7 * d, gy); g.lineTo(tx + 7 * d, gy); g.lineTo(tx + 7 * d, gy + 8 * d); g.lineTo(tx, gy + 14 * d); g.lineTo(tx - 7 * d, gy + 8 * d); g.fill();
    g.fillStyle = '#111'; g.font = `bold ${9 * d}px Arial`; g.textAlign = 'center'; g.fillText('T', tx, gy + 6 * d);
    // traces
    const act = this.ch.map((c, i) => (c ? i : -1)).filter((i) => i >= 0);
    const n = Math.max(1, act.length);
    const laneDiv = 8 / n;
    let vdiv = 5 / (laneDiv * 0.62);
    vdiv = [0.5, 1, 2, 5, 10].find((v) => v >= vdiv) || 10;
    this.vdiv = vdiv;
    const divH = gh / 8;
    const span = this.span, t0 = this.t0;
    act.forEach((ci, k) => {
      const c = this.ch[ci];
      const base = gy + (k + 0.82) * laneDiv * divH;     // 0 V
      const h5 = (5 / vdiv) * divH;                      // hauteur de 5 V
      // repere de voie (masse) a gauche
      g.fillStyle = c.color;
      g.beginPath(); g.moveTo(gx, base - 7 * d); g.lineTo(gx + 14 * d, base - 7 * d); g.lineTo(gx + 20 * d, base); g.lineTo(gx + 14 * d, base + 7 * d); g.lineTo(gx, base + 7 * d); g.fill();
      g.fillStyle = '#000'; g.font = `bold ${10 * d}px Arial`; g.textAlign = 'center'; g.fillText(String(ci + 1), gx + 8 * d, base + 0.5 * d);
      this.drawTrace(g, c, gx, gw, base, h5, t0, span, d);
      this.decode(g, c, gx, gw, base - h5 * 0.5, t0, span, d);
    });
    if (!act.length) {
      g.fillStyle = 'rgba(220,220,220,0.5)'; g.font = `${13 * d}px "Segoe UI", Arial`; g.textAlign = 'center';
      g.fillText(t('Cliquer sur une broche de la carte pour y poser la sonde (voie choisie : {0})', this.sel + 1), cx, cy - 20 * d);
    }
    // curseurs
    const meas = [];
    const tpx = (tt) => gx + ((tt - t0) / span) * gw;
    if (this.mA !== null) {
      g.strokeStyle = '#9b7bff'; g.setLineDash([5 * d, 4 * d]);
      for (const tt of [this.mA, this.mB]) { if (tt === null) continue; const xx = tpx(tt); g.beginPath(); g.moveTo(xx, gy); g.lineTo(xx, gy + gh); g.stroke(); }
      g.setLineDash([]);
      if (this.mB !== null) {
        const dt = Math.abs(this.mB - this.mA) * TQ;
        meas.push(['ΔX', fmtTime(dt)], ['1/ΔX', fmtFreq(1 / dt)]);
        g.fillStyle = 'rgba(20,16,40,0.85)'; rr(g, gx + 8 * d, gy + 8 * d, 150 * d, 34 * d, 4 * d); g.fill();
        g.fillStyle = '#c7b6ff'; g.font = `${11 * d}px "Cascadia Mono", Consolas, monospace`; g.textAlign = 'left';
        g.fillText('ΔX = ' + fmtTime(dt), gx + 16 * d, gy + 19 * d);
        g.fillText('1/ΔX = ' + fmtFreq(1 / dt), gx + 16 * d, gy + 33 * d);
      }
    }
    if (this.cursor !== null && this.cursor > gx) {
      g.strokeStyle = 'rgba(255,255,255,0.3)';
      g.beginPath(); g.moveTo(this.cursor + 0.5, gy); g.lineTo(this.cursor + 0.5, gy + gh); g.stroke();
    }
    // ---- boites des voies en bas
    const by = H - BB;
    g.fillStyle = '#101418'; g.fillRect(0, by, W, BB);
    const bw = Math.min(150 * d, (W - 8 * d) / 4 - 4 * d);
    for (let i = 0; i < 4; i++) {
      const c = this.ch[i];
      const bx = 4 * d + i * (bw + 4 * d);
      g.fillStyle = '#1b2228'; rr(g, bx, by + 3 * d, bw, BB - 6 * d, 3 * d); g.fill();
      if (i === this.sel) { g.strokeStyle = DSO_COLORS[i]; g.lineWidth = 1.5 * d; rr(g, bx, by + 3 * d, bw, BB - 6 * d, 3 * d); g.stroke(); g.lineWidth = 1; }
      g.fillStyle = c ? DSO_COLORS[i] : '#454c53'; g.fillRect(bx, by + 3 * d, 16 * d, BB - 6 * d);
      g.fillStyle = '#000'; g.font = `bold ${12 * d}px Arial`; g.textAlign = 'center'; g.fillText(String(i + 1), bx + 8 * d, by + BB / 2);
      g.font = `${10 * d}px "Cascadia Mono", Consolas, monospace`; g.textAlign = 'left';
      g.fillStyle = c ? DSO_COLORS[i] : '#5b636b';
      g.fillText(c ? vdiv.toFixed(2) + 'V/' : 'OFF', bx + 21 * d, by + BB / 2 - 6 * d);
      g.fillStyle = c ? '#d8dde2' : '#5b636b';
      g.fillText(c ? short(c.name, 14) : '—', bx + 21 * d, by + BB / 2 + 6 * d);
    }
    this.meas = meas.concat(this.measure());
  }

  drawTrace(g, c, gx, gw, base, h5, t0, span, d) {
    const yOf = (v) => (v === 1 ? base - h5 : v === 0 ? base : base - h5 * 0.3);
    const noise = (xx) => (rnd(xx * 0.37 + (c.sig || 0)) - 0.5) * 1.2 * d;
    g.strokeStyle = c.color; g.lineWidth = 1.4 * d;
    g.shadowColor = c.color; g.shadowBlur = 6 * d;
    const end = t0 + span;
    const rise = Math.max(1, 1.2 * d);
    if (c.synth) {
      const s = SYNTH[c.synth];
      const pxPer = (s.per / span) * gw;
      if (pxPer < 5) {
        const gr = g.createLinearGradient(0, base - h5, 0, base);
        gr.addColorStop(0, c.color + 'cc'); gr.addColorStop(0.5, c.color + '44'); gr.addColorStop(1, c.color + 'cc');
        g.fillStyle = gr; g.fillRect(gx, base - h5, gw, h5);
        g.shadowBlur = 0; return;
      }
      g.beginPath();
      let tt = Math.floor(t0 / s.per) * s.per;
      g.moveTo(gx, yOf(this.levelAt(c, t0)));
      for (; tt < end; tt += s.per) {
        const xa = gx + ((tt - t0) / span) * gw, xb = gx + ((tt + s.high - t0) / span) * gw;
        g.lineTo(xa, base); g.lineTo(xa + rise, base - h5); g.lineTo(xb, base - h5); g.lineTo(xb + rise, base);
      }
      g.lineTo(gx + gw, base); g.stroke(); g.shadowBlur = 0; return;
    }
    let lv = this.levelAt(c, t0);
    let i = this.idxAfter(c, t0);
    g.beginPath();
    let px = gx, lastPx = -1;
    g.moveTo(px, yOf(lv) + noise(px));
    for (; i < c.t.length && c.t[i] <= end; i++) {
      const nx = gx + ((c.t[i] - t0) / span) * gw;
      const ipx = Math.floor(nx);
      if (ipx === lastPx) { g.moveTo(nx, base - h5); g.lineTo(nx, base); lv = c.v[i]; g.moveTo(nx, yOf(lv)); continue; }
      // segment plat avec un peu de bruit
      for (let xx = px + 6 * d; xx < nx - 1; xx += 6 * d) g.lineTo(xx, yOf(lv) + noise(xx));
      g.lineTo(nx, yOf(lv) + noise(nx));
      lastPx = ipx;
      lv = c.v[i];
      g.lineTo(nx + rise, yOf(lv) + noise(nx + 1));
      px = nx + rise;
    }
    for (let xx = px + 6 * d; xx < gx + gw; xx += 6 * d) g.lineTo(xx, yOf(lv) + noise(xx));
    g.lineTo(gx + gw, yOf(lv));
    g.stroke();
    g.shadowBlur = 0;
  }

  /** Decodage sous la trace : octets UART (9600 8N1) et trames PS/2 en hexagones. */
  decode(g, c, gx, gw, y, t0, span, d) {
    if (c.sig === null) return;
    const end = t0 + span;
    const hex = (x0, x1, txt, ok) => {
      const hh = 8 * d, cut = Math.min(5 * d, (x1 - x0) / 3);
      g.fillStyle = ok ? 'rgba(10,30,40,0.85)' : 'rgba(60,10,10,0.85)';
      g.strokeStyle = ok ? '#d8dde2' : '#ff6b6b'; g.lineWidth = 1;
      g.beginPath(); g.moveTo(x0, y); g.lineTo(x0 + cut, y - hh); g.lineTo(x1 - cut, y - hh); g.lineTo(x1, y); g.lineTo(x1 - cut, y + hh); g.lineTo(x0 + cut, y + hh); g.closePath();
      g.fill(); g.stroke();
      if (x1 - x0 > 16 * d) { g.fillStyle = '#fff'; g.font = `bold ${10 * d}px "Segoe UI", Arial`; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(txt, (x0 + x1) / 2, y + 0.5 * d); }
    };
    if (/UART_(TX|RX)|U12-PA7|U12-PB2/.test(c.name)) {
      const bit = (CLK * 4) / 9600;
      if ((bit * 10 / span) * gw < 10 * d) return;
      let k = this.idxAfter(c, t0 - bit * 10);
      while (k < c.t.length && c.t[k] < end) {
        const ts = c.t[k];
        const prev = k > 0 ? c.v[k - 1] : c.base;
        if (!(prev === 1 && c.v[k] === 0)) { k++; continue; }
        let b = 0;
        for (let j = 0; j < 8; j++) if (this.levelAt(c, ts + bit * (1.5 + j)) === 1) b |= 1 << j;
        const stop = this.levelAt(c, ts + bit * 9.5) === 1;
        const x0 = gx + ((ts - t0) / span) * gw, x1 = x0 + (bit * 10 / span) * gw;
        hex(x0, x1, b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : b.toString(16).toUpperCase().padStart(2, '0'), stop);
        k = this.idxAfter(c, ts + bit * 9.6);
      }
    }
    if (/KBD_DATA|U12-PB1/.test(c.name)) {
      const cc = this.ch.find((q) => q && /KBD_CLK|U12-PB0/.test(q.name));
      if (!cc) return;
      let k = this.idxAfter(cc, t0 - 2e5), bits = [], tStart = 0;
      for (; k < cc.t.length && cc.t[k] < end; k++) {
        const prev = k > 0 ? cc.v[k - 1] : cc.base;
        if (!(prev === 1 && cc.v[k] === 0)) continue;
        const tt = cc.t[k];
        if (bits.length && tt - tStart > 4 * CLK * 0.002) bits = [];
        if (!bits.length) tStart = tt;
        bits.push(this.levelAt(c, tt));
        if (bits.length === 11) {
          let b = 0;
          for (let j = 0; j < 8; j++) b |= bits[1 + j] << j;
          const x0 = gx + ((tStart - t0) / span) * gw, x1 = gx + ((tt - t0) / span) * gw;
          if (x1 > gx) hex(x0, x1, b.toString(16).toUpperCase().padStart(2, '0'), bits[0] === 0 && bits[10] === 1);
          bits = [];
        }
      }
    }
  }

  /** Mesures automatiques de la voie de declenchement. */
  measure() {
    const c = this.ch[this.trig.ch];
    const out = [];
    if (!c || !this.showMeas) return out;
    const n = 'CH' + (this.trig.ch + 1);
    if (c.synth) { const s = SYNTH[c.synth]; return [[t('Fréq.') + ' ' + n, s.label], [t('Période'), fmtTime(s.per * TQ)]]; }
    const a = this.idxAfter(c, this.t0), b = this.idxAfter(c, this.t0 + this.span);
    const rises = [], falls = [];
    for (let i = a; i < b; i++) {
      const prev = i > 0 ? c.v[i - 1] : c.base;
      if (prev === 0 && c.v[i] === 1) rises.push(c.t[i]);
      if (prev === 1 && c.v[i] === 0) falls.push(c.t[i]);
    }
    out.push([t('Fronts') + ' ' + n, String(rises.length + falls.length)]);
    if (rises.length >= 2) {
      const per = (rises[rises.length - 1] - rises[0]) / (rises.length - 1);
      out.push([t('Période moy.'), fmtTime(per * TQ)], [t('Fréquence'), fmtFreq(1 / (per * TQ))]);
      let hi = 0, k = 0;
      for (const r of rises) { const f = falls.find((x) => x > r); if (f !== undefined) { hi += f - r; k++; } }
      if (k) out.push([t('Largeur +'), fmtTime((hi / k) * TQ)], [t('Rapport cyclique'), ((hi / k / per) * 100).toFixed(1) + ' %']);
    } else if (rises.length && falls.length) {
      const f = falls.find((x) => x > rises[0]);
      if (f !== undefined) out.push([t('Largeur +'), fmtTime((f - rises[0]) * TQ)]);
      const r = rises.find((x) => x > falls[0]);
      if (r !== undefined) out.push([t('Largeur −'), fmtTime((r - falls[0]) * TQ)]);
    }
    return out;
  }
}

function short(s, n = 9) { s = String(s).replace(/~\{([^}]*)\}/g, '/$1'); return s.length > n ? s.slice(0, n) + '…' : s; }
function rr(g, x, y, w, h, r) {
  g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
}
