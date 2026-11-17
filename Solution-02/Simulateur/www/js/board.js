// Vue de la carte : composants, broches colorees selon leur niveau, nets, sondes, menu contextuel.

import { BOARD, PLACE, pinPositions, bodyRect, GATE_NAMES, role } from './layout.js';
import { drawLcd } from './lcd.js';
import { t } from './i18n.js';

const C = {
  hi: '#ff5a4f', lo: '#3f7dff', act: '#ffd23f', z: '#7b828a', vcc: '#ff8a7a', gnd: '#5c7cc4',
  silk: 'rgba(235,242,236,0.88)', silkDim: 'rgba(235,242,236,0.45)', pad: '#c9b26b', padDark: '#8a7a45',
};
const CH_COLORS = ['#ffe14d', '#3fe0ff', '#ff6bd6', '#5cff7a', '#ff9f43', '#7aa2ff', '#ff5e7e', '#e6e6e6'];
export { CH_COLORS };

const RES_BANDS = { '10k': ['#8b4513', '#111', '#ff8c00'], '390': ['#ff8c00', '#f2f2f2', '#8b4513'], '220': ['#d22', '#d22', '#8b4513'] };

/** Resout le signal du simulateur qui porte un net (ou un etat fixe). */
export function makeResolver(signalNames, netlist) {
  const idx = new Map(signalNames.map((n, i) => [n, i]));
  const nets = netlist.nets;
  const comps = new Map(netlist.components.map((c) => [c.ref, c]));
  const netOfPin = (ref, n) => {
    const c = comps.get(ref);
    const p = c && c.pins.find((q) => q.n === String(n));
    return p ? p.net : null;
  };
  const cache = new Map();
  const resolve = (net, depth = 0) => {
    if (!net) return { kind: 'nc' };
    if (cache.has(net)) return cache.get(net);
    let r = null;
    const s = net.replace(/^\//, '');
    if (s === '+5V') r = { kind: 'vcc' };
    else if (s === 'GND') r = { kind: 'gnd' };
    else if (idx.has(s)) r = { kind: 'sig', i: idx.get(s) };
    else if (/^Net-\(U11-X[12]\)$/.test(s)) r = { kind: 'clock', name: 'OSC' };
    else if (s === 'Net-(U10-VO)') r = { kind: 'analog', name: 'VO' };
    else {
      let m = s.match(/^Net-\((.+)\)$/);
      if (m && idx.has(m[1])) r = { kind: 'sig', i: idx.get(m[1]) };
      m = s.match(/^unconnected-\((U\d+)[AB]?-(.+)-Pad(\d+)\)$/);
      if (!r && m) {
        const [, ref, pin] = m;
        const special = {
          'U16:~{Q}': ['GATE2', true], 'U16:Q': ['~{SPK_EN}', true], 'U15:OUT1': ['OUT1', false],
          'U1:DEN': ['U1-DEN', false], 'U1:DT/~{R}': ['U1-DT/~{R}', false], 'U1:~{SSO}': ['U1-~{SSO}', false],
          'U1:HLDA': ['U1-HLDA', false],
        }[ref + ':' + pin];
        if (special && idx.has(special[0])) r = { kind: 'sig', i: idx.get(special[0]), inv: special[1] };
        else if (idx.has(ref + '-' + pin)) r = { kind: 'sig', i: idx.get(ref + '-' + pin) };
        else if (ref === 'U13' && /^IR/.test(pin)) r = { kind: 'z' };
        else if (ref === 'U13' && /^CAS/.test(pin)) r = { kind: 'gnd' };
        else if (ref === 'U11' && pin === 'OSC') r = { kind: 'clock', name: 'OSC' };
        else r = { kind: 'nc' };
      }
      // cathode d'une DEL : suit l'anode (courant dans la DEL)
      if (!r && depth === 0) {
        const nodes = nets[s] || nets['/' + s] || [];
        for (const nd of nodes) {
          const [ref, pin] = nd.split('.');
          if (/^BAR\d$/.test(ref)) {
            const k = +pin;
            const an = netOfPin(ref, k > 10 ? 21 - k : k);
            if (an && an !== net) { r = { ...resolve(an, depth + 1), led: true }; break; }
          }
          if (/^D\d$/.test(ref) && pin === '1') {
            const an = netOfPin(ref, 2);
            if (an) { r = { ...resolve(an, depth + 1), led: true }; break; }
          }
        }
      }
    }
    if (!r) r = { kind: 'nc' };
    cache.set(net, r);
    return r;
  };
  return resolve;
}

export class BoardView {
  constructor(canvas, netlist, signalNames, hooks) {
    this.cv = canvas;
    this.g = canvas.getContext('2d');
    this.net = netlist;
    this.hooks = hooks;
    this.names = signalNames;
    this.resolve = makeResolver(signalNames, netlist);
    this.view = { s: 4, ox: 0, oy: 0 };
    this.showAir = false;
    this.showNames = true;
    this.hover = null;          // broche survolee
    this.hoverComp = null;
    this.highlight = null;      // net mis en evidence (Maj+clic)
    this.probes = new Map();    // net -> numero de voie
    this.static = document.createElement('canvas');
    this.staticDirty = true;
    this.buttonDown = false;
    this.build();
    this.bind();
  }

  build() {
    this.comps = [];
    this.pins = [];
    this.netPins = new Map();
    for (const c of this.net.components) {
      if (!PLACE[c.ref]) continue;
      const pos = pinPositions(c.ref, c);
      const gate = GATE_NAMES[c.part];
      const comp = { ...c, place: PLACE[c.ref], body: bodyRect(c.ref, c), pinList: [] };
      for (const p of c.pins) {
        const xy = pos[p.n];
        if (!xy) continue;
        let name = p.name;
        if (gate && /^\d+$/.test(p.n)) name = gate[+p.n - 1] || name;
        const pin = { comp, n: p.n, name, net: p.net, x: xy[0], y: xy[1], res: this.resolve(p.net), type: p.type };
        comp.pinList.push(pin);
        this.pins.push(pin);
        if (p.net) {
          if (!this.netPins.has(p.net)) this.netPins.set(p.net, []);
          this.netPins.get(p.net).push(pin);
        }
      }
      this.comps.push(comp);
    }
    // arbres couvrants (liaisons) pour chaque net
    this.air = [];
    for (const [net, ps] of this.netPins) {
      if (ps.length < 2) continue;
      const power = net === '+5V' || net === 'GND';
      const inT = [ps[0]], rest = ps.slice(1);
      while (rest.length) {
        let best = null, bd = 1e9, bi = -1;
        for (const a of inT) for (let i = 0; i < rest.length; i++) {
          const d = (a.x - rest[i].x) ** 2 + (a.y - rest[i].y) ** 2;
          if (d < bd) { bd = d; best = [a, rest[i]]; bi = i; }
        }
        this.air.push({ net, a: best[0], b: best[1], power });
        inT.push(rest[bi]); rest.splice(bi, 1);
      }
    }
    // pistes : chemins orthogonaux avec chanfreins a 45 degres, decales selon le net
    this.routes = [];
    this.vias = [];
    let k = 0;
    for (const a of this.air) {
      this.routes.push({ net: a.net, pts: route(a.a, a.b, ((hash(a.net) % 9) - 4) * 0.3), power: a.power });
      const r = this.routes[this.routes.length - 1].pts;
      if (r.length > 6 && (k++ % 3) === 0) this.vias.push([r[4], r[5]]);
    }
  }

  // ------------------------------------------------------------------ vue
  resize() {
    const r = this.cv.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    this.dpr = dpr;
    this.cv.width = Math.max(1, Math.round(r.width * dpr));
    this.cv.height = Math.max(1, Math.round(r.height * dpr));
    this.static.width = this.cv.width;
    this.static.height = this.cv.height;
    if (!this.fitted) this.fit();
    this.staticDirty = true;
  }
  fit() {
    const w = this.cv.width, h = this.cv.height;
    const s = Math.min(w / (BOARD.w + 12), h / (BOARD.h + 12));
    this.view = { s, ox: (w - BOARD.w * s) / 2, oy: (h - BOARD.h * s) / 2 };
    this.fitted = true;
    this.staticDirty = true;
  }
  zoom(f, cx, cy) {
    const v = this.view;
    const ns = Math.max(1.2, Math.min(60, v.s * f));
    const k = ns / v.s;
    v.ox = cx - (cx - v.ox) * k;
    v.oy = cy - (cy - v.oy) * k;
    v.s = ns;
    this.staticDirty = true;
  }
  toScreen(x, y) { return [x * this.view.s + this.view.ox, y * this.view.s + this.view.oy]; }
  toBoard(px, py) { return [(px - this.view.ox) / this.view.s, (py - this.view.oy) / this.view.s]; }

  pinAt(px, py) {
    const [x, y] = this.toBoard(px, py);
    let best = null, bd = 1.4 ** 2;
    for (const p of this.pins) {
      const d = (p.x - x) ** 2 + (p.y - y) ** 2;
      if (d < bd) { bd = d; best = p; }
    }
    return best;
  }
  compAt(px, py) {
    const [x, y] = this.toBoard(px, py);
    for (let i = this.comps.length - 1; i >= 0; i--) {
      const c = this.comps[i];
      const [bx, by, bw, bh] = c.body;
      if (x >= bx - 1 && x <= bx + bw + 1 && y >= by - 1 && y <= by + bh + 1) return c;
    }
    return null;
  }

  // ------------------------------------------------------------------ evenements
  bind() {
    const cv = this.cv;
    let drag = null;
    const pt = (e) => {
      const r = cv.getBoundingClientRect();
      return [(e.clientX - r.left) * this.dpr, (e.clientY - r.top) * this.dpr];
    };
    cv.addEventListener('wheel', (e) => {
      e.preventDefault();
      const [x, y] = pt(e);
      this.zoom(Math.exp(-e.deltaY * 0.0015), x, y);
    }, { passive: false });
    cv.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return;
      const [x, y] = pt(e);
      const comp = this.compAt(x, y);
      if (comp && comp.ref === 'SW1') {
        this.buttonDown = true;
        this.hooks.onReset(true);
        const up = () => { this.buttonDown = false; this.hooks.onReset(false); window.removeEventListener('mouseup', up); };
        window.addEventListener('mouseup', up);
        return;
      }
      drag = { x, y, ox: this.view.ox, oy: this.view.oy, moved: false, pin: this.pinAt(x, y), shift: e.shiftKey, comp };
      cv.classList.add('drag');
    });
    window.addEventListener('mousemove', (e) => {
      if (drag) {
        const [x, y] = pt(e);
        if (Math.abs(x - drag.x) + Math.abs(y - drag.y) > 4 * this.dpr) drag.moved = true;
        if (drag.moved) {
          this.view.ox = drag.ox + (x - drag.x);
          this.view.oy = drag.oy + (y - drag.y);
          this.staticDirty = true;
        }
      }
    });
    window.addEventListener('mouseup', (e) => {
      if (!drag) return;
      cv.classList.remove('drag');
      const d = drag; drag = null;
      if (d.moved) return;
      if (d.pin) {
        if (d.shift) this.highlight = this.highlight === d.pin.net ? null : d.pin.net;
        else this.hooks.onProbe(d.pin);
      } else if (d.comp) {
        this.hooks.onComp(d.comp, e);
      } else if (e.shiftKey) this.highlight = null;
    });
    cv.addEventListener('dblclick', () => this.fit());
    cv.addEventListener('mousemove', (e) => {
      const [x, y] = pt(e);
      const p = this.pinAt(x, y);
      this.hover = p;
      this.hoverComp = p ? p.comp : this.compAt(x, y);
      cv.classList.toggle('pin', !!p);
      this.hooks.onHover(p, this.hoverComp, e);
    });
    cv.addEventListener('mouseleave', () => { this.hover = null; this.hoverComp = null; this.hooks.onHover(null, null); });
    cv.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      const [x, y] = pt(e);
      const p = this.pinAt(x, y);
      const c = p ? p.comp : this.compAt(x, y);
      this.hooks.onContext(p, c, e);
    });
  }

  // ------------------------------------------------------------------ etat d'une broche
  pinState(pin, sig) {
    const r = pin.res;
    switch (r.kind) {
      case 'vcc': return { v: 1, txt: t('+5 V'), col: C.vcc };
      case 'gnd': return { v: 0, txt: t('0 V (masse)'), col: C.gnd };
      case 'clock': return { v: 3, txt: t('oscillation 16 MHz'), col: C.act };
      case 'analog': return { v: 2, txt: t('analogique (contraste)'), col: '#b48cff' };
      case 'z': return { v: 2, txt: t('entrée non connectée'), col: C.z };
      case 'nc': return { v: -1, txt: t('non connectée'), col: '#444a50' };
    }
    const s = sig ? sig[r.i] : 0;
    let lv = s & 3;
    if (r.inv && lv < 2) lv ^= 1;
    const act = (s & 4) !== 0 && lv !== 2;
    if (lv === 2) return { v: 2, txt: t('Z (flottant)'), col: C.z, act };
    return { v: lv, act, txt: t(lv ? '1 (haut)' : '0 (bas)') + (act ? t(', activité') : ''), col: act ? C.act : lv ? C.hi : C.lo };
  }

  // ------------------------------------------------------------------ dessin
  drawStatic() {
    const g = this.static.getContext('2d');
    const { s } = this.view;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, this.static.width, this.static.height);
    g.setTransform(s, 0, 0, s, this.view.ox, this.view.oy);
    // carte : vernis epargne bleu sur FR4, cadre de cuivre dore (ENIG), trous metallises
    g.save();
    g.shadowColor = 'rgba(0,0,0,0.7)'; g.shadowBlur = 22; g.shadowOffsetY = 8;
    g.fillStyle = '#c9a646';
    rrect(g, 0, 0, BOARD.w, BOARD.h, 3); g.fill();
    g.restore();
    const grd = g.createLinearGradient(0, 0, BOARD.w * 0.3, BOARD.h);
    grd.addColorStop(0, '#0d2f7a'); grd.addColorStop(0.55, '#0a2766'); grd.addColorStop(1, '#0b2a6e');
    g.fillStyle = grd;
    rrect(g, 2.2, 2.2, BOARD.w - 4.4, BOARD.h - 4.4, 1.5); g.fill();
    // pistes de cuivre sous le vernis (chemins a 45 degres entre les broches de chaque net)
    g.lineCap = 'round'; g.lineJoin = 'round';
    for (const r of this.routes) {
      g.strokeStyle = r.power ? 'rgba(70,118,222,0.6)' : 'rgba(58,104,206,0.58)';
      g.lineWidth = r.power ? 0.75 : 0.3;
      g.beginPath(); g.moveTo(r.pts[0], r.pts[1]);
      for (let i = 2; i < r.pts.length; i += 2) g.lineTo(r.pts[i], r.pts[i + 1]);
      g.stroke();
    }
    for (const v of this.vias) {
      g.fillStyle = '#c9a646'; circ(g, v[0], v[1], 0.42); g.fill();
      g.fillStyle = '#071a45'; circ(g, v[0], v[1], 0.18); g.fill();
    }
    // trous de fixation et reperes optiques
    for (const [hx, hy] of [[5, 5], [BOARD.w - 5, 5], [5, BOARD.h - 5], [BOARD.w - 5, BOARD.h - 5]]) {
      g.fillStyle = '#d8b75a'; circ(g, hx, hy, 2.6); g.fill();
      g.fillStyle = '#0b0d10'; circ(g, hx, hy, 1.55); g.fill();
    }
    for (const [fx, fy] of [[12, 5], [BOARD.w - 12, BOARD.h - 5]]) {
      g.fillStyle = '#05163d'; circ(g, fx, fy, 1.2); g.fill();
      g.fillStyle = '#e0c56a'; circ(g, fx, fy, 0.5); g.fill();
    }
    // serigraphie : nom de la carte et encarts blancs, comme une vraie carte
    const silk = '#f2f4f7';
    g.fillStyle = silk; g.font = 'bold 4.2px "Segoe UI", Arial, sans-serif'; g.textAlign = 'right'; g.textBaseline = 'alphabetic';
    g.fillText('SOLUTION-02', BOARD.w - 9, BOARD.h - 8);
    g.font = '2.1px "Segoe UI", Arial, sans-serif';
    g.fillText('8088 / NEC V20 · 512 KB · VE2CUY · REV 2.4 · 2026', BOARD.w - 9, BOARD.h - 4.6);
    labelBox(g, 6, BOARD.h - 10.5, ['+5V', 'GND'], silk);
    // zones fonctionnelles : encarts blancs, texte bleu
    const zones = [
      [4, 8, 41, 62, t('HORLOGE · RESET')], [104, 9, 116, 47, t('DÉCODAGE')],
      [38, 63, 104, 34, t('MÉMOIRES')], [148, 63, 94, 34, t('INTERRUPTIONS · MINUTERIE')],
      [33, 100, 168, 46, t('DEL (U7)')], [5, 151, 165, 52, t('CLAVIER · UART · CARTE SD (U12)')],
    ];
    g.lineWidth = 0.22; g.strokeStyle = 'rgba(242,244,247,0.5)';
    for (const [x, y, w, h, txt] of zones) {
      rrect(g, x, y, w, h, 0.8); g.stroke();
      g.font = 'bold 2px "Segoe UI", Arial, sans-serif';
      const tw = g.measureText(txt).width + 2;
      g.fillStyle = silk; g.fillRect(x + 1.5, y + h - 3.6, tw, 2.8);
      g.fillStyle = '#0a2766'; g.textAlign = 'left'; g.textBaseline = 'middle';
      g.fillText(txt, x + 2.5, y + h - 2.15);
    }
    g.textBaseline = 'alphabetic';
    // contours de serigraphie des composants
    g.strokeStyle = 'rgba(242,244,247,0.75)'; g.lineWidth = 0.18;
    for (const c of this.comps) {
      const [bx, by, bw, bh] = c.body;
      if (c.place.kind === 'lcd' || c.place.kind === 'sdmod' || c.place.kind === 'usb') continue;
      rrect(g, bx - 0.9, by - 0.9, bw + 1.8, bh + 1.8, 0.3); g.stroke();
    }
    // liaisons (toutes, en fil volant)
    if (this.showAir) {
      g.lineWidth = 0.22;
      for (const a of this.air) {
        g.strokeStyle = a.power ? 'rgba(255,140,120,0.18)' : 'rgba(255,220,120,0.4)';
        g.beginPath(); g.moveTo(a.a.x, a.a.y); g.lineTo(a.b.x, a.b.y); g.stroke();
      }
    }
    for (const c of this.comps) this.drawComp(g, c, s);
  }

  drawComp(g, c, s) {
    const [bx, by, bw, bh] = c.body;
    const k = c.place.kind;
    // pastilles
    for (const p of c.pinList) {
      const carre = p.n === '1' && k !== 'axial' && k !== 'cap';
      g.fillStyle = '#9c7d2c';
      if (carre) g.fillRect(p.x - 0.95, p.y - 0.95, 1.9, 1.9); else { circ(g, p.x, p.y, 0.95); g.fill(); }
      g.fillStyle = '#e2c46a';
      if (carre) g.fillRect(p.x - 0.8, p.y - 0.8, 1.6, 1.6); else { circ(g, p.x, p.y, 0.8); g.fill(); }
      g.fillStyle = '#f6e3a0'; circ(g, p.x - 0.25, p.y - 0.25, 0.22); g.fill();
      g.fillStyle = '#2b2410'; circ(g, p.x, p.y, 0.36); g.fill();
    }
    g.save();
    switch (k) {
      case 'dip': {
        g.shadowColor = 'rgba(0,0,0,0.55)'; g.shadowBlur = 3; g.shadowOffsetY = 0.8;
        const gr = g.createLinearGradient(0, by, 0, by + bh);
        gr.addColorStop(0, '#2a2b2e'); gr.addColorStop(0.5, '#1a1b1d'); gr.addColorStop(1, '#121214');
        g.fillStyle = gr; rrect(g, bx, by, bw, bh, 0.6); g.fill();
        g.shadowColor = 'transparent';
        // pattes
        g.fillStyle = '#b8bcc2';
        for (const p of c.pinList) {
          const top = p.y < c.place.y;
          g.fillRect(p.x - 0.32, top ? p.y + 0.5 : by + bh, 0.64, top ? by - p.y - 0.5 : p.y - (by + bh) - 0.5);
        }
        // encoche et point de la broche 1
        g.fillStyle = '#0b0b0c'; g.beginPath(); g.arc(bx, c.place.y, Math.min(1.4, bh / 4), -Math.PI / 2, Math.PI / 2); g.fill();
        g.fillStyle = '#3a3b3e'; circ(g, bx + 1.6, by + bh - 1.4, 0.5); g.fill();
        // marquage
        const fs = Math.min(2.6, bh / 3.2);
        g.fillStyle = '#d9dcdf'; g.font = `600 ${fs}px "Segoe UI", sans-serif`; g.textAlign = 'center'; g.textBaseline = 'middle';
        g.fillText(c.value, c.place.x, c.place.y - (bh > 8 ? fs * 0.45 : 0));
        if (bh > 8) { g.fillStyle = '#8d9196'; g.font = `${fs * 0.75}px "Segoe UI", sans-serif`; g.fillText(c.ref, c.place.x, c.place.y + fs * 0.8); }
        else { g.fillStyle = C.silk; g.font = `bold 2.2px "Segoe UI", sans-serif`; g.fillText(c.ref, bx - 2.6, c.place.y); }
        break;
      }
      case 'bar': {
        g.fillStyle = '#151515'; rrect(g, bx, by, bw, bh, 0.4); g.fill();
        for (let i = 1; i <= 10; i++) {
          const p = c.pinList.find((q) => q.n === String(i));
          if (!p) continue;
          g.fillStyle = '#3a1010'; g.fillRect(p.x - 0.8, by + 1.2, 1.6, bh - 2.4);
        }
        g.fillStyle = C.silk; g.font = 'bold 2.2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(c.ref, c.place.x, by - 2.4);
        break;
      }
      case 'sip': {
        g.fillStyle = '#d8c79a'; rrect(g, bx, by, bw, bh, 1.2); g.fill();
        g.fillStyle = '#5a4b25'; circ(g, bx + 1.2, c.place.y, 0.45); g.fill();
        g.fillStyle = '#3a3220'; g.font = '1.6px "Segoe UI", sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
        g.fillText(c.ref + ' ' + c.value + 'Ω', c.place.x + 1, c.place.y);
        break;
      }
      case 'header': {
        g.fillStyle = '#141414'; g.fillRect(bx, by, bw, bh);
        for (const p of c.pinList) { g.fillStyle = '#c9b26b'; g.fillRect(p.x - 0.32, p.y - 0.32, 0.64, 0.64); }
        g.fillStyle = C.silk; g.font = 'bold 2.2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(c.ref + ' · ' + c.value, c.place.x, by - 1.3);
        break;
      }
      case 'axial': {
        const y = c.place.y;
        g.strokeStyle = '#b8bcc2'; g.lineWidth = 0.4;
        g.beginPath(); g.moveTo(bx, y); g.lineTo(bx + bw, y); g.stroke();
        const L = Math.min(6.3, bw - 1.6), x0 = c.place.x - L / 2;
        g.fillStyle = '#d8c79a'; rrect(g, x0, y - 1.2, L, 2.4, 1.1); g.fill();
        const bands = RES_BANDS[c.value] || ['#888', '#888', '#888'];
        bands.forEach((col, i) => { g.fillStyle = col; g.fillRect(x0 + 1 + i * 1.2, y - 1.2, 0.6, 2.4); });
        g.fillStyle = '#c8a64a'; g.fillRect(x0 + L - 1.5, y - 1.2, 0.6, 2.4);
        g.fillStyle = C.silkDim; g.font = '1.7px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(c.ref, c.place.x, y - 1.8);
        break;
      }
      case 'cap': {
        g.fillStyle = '#d9a43a'; circ(g, c.place.x, c.place.y, 1.8); g.fill();
        g.fillStyle = C.silkDim; g.font = '1.7px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(c.ref + ' ' + c.value, c.place.x, c.place.y - 2.3);
        break;
      }
      case 'ecap': {
        g.fillStyle = '#1d3d8a'; circ(g, c.place.x, c.place.y, 2.5); g.fill();
        g.fillStyle = '#9fb4e6'; g.beginPath(); g.arc(c.place.x, c.place.y, 2.5, Math.PI * 0.6, Math.PI * 1.4); g.fill();
        g.strokeStyle = '#c0c4ca'; g.lineWidth = 0.2; circ(g, c.place.x, c.place.y, 1.4); g.stroke();
        g.fillStyle = C.silkDim; g.font = '1.7px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(c.ref + ' ' + c.value + 'F', c.place.x, c.place.y - 3);
        break;
      }
      case 'xtal': {
        const gr = g.createLinearGradient(0, by, 0, by + bh);
        gr.addColorStop(0, '#e8eaee'); gr.addColorStop(1, '#8e949c');
        g.fillStyle = gr; rrect(g, bx, by, bw, bh, 2.3); g.fill();
        g.fillStyle = '#333'; g.font = '1.8px "Segoe UI", sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
        g.fillText('16.000', c.place.x, c.place.y);
        g.fillStyle = C.silk; g.font = 'bold 2px "Segoe UI", sans-serif'; g.fillText('Y1', c.place.x, by - 1.3);
        break;
      }
      case 'buzzer': {
        g.fillStyle = '#111'; circ(g, c.place.x, c.place.y, 6); g.fill();
        g.strokeStyle = '#333'; g.lineWidth = 0.3; circ(g, c.place.x, c.place.y, 4.5); g.stroke();
        g.fillStyle = '#000'; circ(g, c.place.x, c.place.y, 1); g.fill();
        g.fillStyle = C.silk; g.font = 'bold 2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(t('BZ1 piézo'), c.place.x, by - 1.2);
        g.fillStyle = C.silkDim; g.font = '1.6px "Segoe UI", sans-serif';
        g.fillText(t('(non câblé)'), c.place.x, by + bh + 2);
        break;
      }
      case 'button': {
        g.fillStyle = '#2a2d31'; rrect(g, bx, by, bw, bh, 0.6); g.fill();
        g.fillStyle = '#5a5f66'; circ(g, c.place.x, c.place.y, 2.2); g.fill();
        g.fillStyle = C.silk; g.font = 'bold 2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(t('SW1 RESET'), c.place.x, by - 1.2);
        break;
      }
      case 'pot': {
        g.fillStyle = '#1f5fbf'; rrect(g, bx, by, bw, bh, 0.8); g.fill();
        g.fillStyle = '#e8e8e8'; circ(g, c.place.x, c.place.y, 2.6); g.fill();
        g.strokeStyle = '#555'; g.lineWidth = 0.6; g.beginPath(); g.moveTo(c.place.x - 1.8, c.place.y); g.lineTo(c.place.x + 1.8, c.place.y);
        g.moveTo(c.place.x, c.place.y - 1.8); g.lineTo(c.place.x, c.place.y + 1.8); g.stroke();
        g.fillStyle = C.silk; g.font = 'bold 2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(t('RV1 contraste'), c.place.x, by - 1.2);
        break;
      }
      case 'usb': {
        const gr = g.createLinearGradient(bx, 0, bx + bw, 0);
        gr.addColorStop(0, '#9aa0a8'); gr.addColorStop(0.5, '#e4e7eb'); gr.addColorStop(1, '#8d939b');
        g.fillStyle = gr; rrect(g, bx, by, 14, bh, 0.8); g.fill();
        g.fillStyle = '#20242a'; g.fillRect(bx + 1.2, by + 3, 2.4, bh - 6);
        g.fillStyle = '#f2f2f2'; g.fillRect(bx + 2.2, by + 4, 0.8, bh - 8);
        g.fillStyle = C.silk; g.font = 'bold 2.2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(t('J4 clavier'), c.place.x, by - 1.3);
        g.font = '1.6px "Segoe UI", sans-serif'; g.fillStyle = C.silkDim; g.textAlign = 'left';
        ['VBUS', 'D-  DATA', 'D+  CLK', 'GND'].forEach((t, i) => g.fillText(t, c.place.x + 9.4, c.place.y - 3.5 + i * 2.5 + 0.5));
        break;
      }
      case 'led': {
        g.fillStyle = c.place.color === 'g' ? '#1d4d2a' : '#5a4310'; circ(g, c.place.x, c.place.y, 1.9); g.fill();
        g.fillStyle = C.silk; g.font = 'bold 1.9px "Segoe UI", sans-serif'; g.textAlign = 'right'; g.textBaseline = 'middle';
        g.fillText(c.ref, c.place.x - 2.6, c.place.y);
        break;
      }
      case 'sdmod': {
        g.fillStyle = '#123f86'; rrect(g, bx, by, bw, bh, 1.2); g.fill();
        g.strokeStyle = 'rgba(255,255,255,0.25)'; g.lineWidth = 0.2; rrect(g, bx + 0.6, by + 0.6, bw - 1.2, bh - 1.2, 1); g.stroke();
        // fente micro-SD
        g.fillStyle = '#b8bcc2'; rrect(g, bx + 12, by + 6, 15, 16, 0.8); g.fill();
        g.fillStyle = '#7e848c'; g.fillRect(bx + 12, by + 19, 15, 3);
        // regulateur, 74LVC125
        g.fillStyle = '#1a1a1a'; g.fillRect(bx + 4, by + 22, 5, 3.5); g.fillRect(bx + 4, by + 3, 4, 6);
        g.fillStyle = '#fff'; g.font = '1.5px "Segoe UI", sans-serif'; g.textAlign = 'left';
        ['CS', 'SCK', 'MOSI', 'MISO', 'VCC', 'GND'].forEach((t, i) => g.fillText(t, bx + 3.6 - 1.4, by + 8.2 + i * 2.54 - 0.3 + 0.6 * 0));
        g.fillStyle = C.silk; g.font = 'bold 2.2px "Segoe UI", sans-serif'; g.textAlign = 'center';
        g.fillText(t('J9 lecteur micro-SD'), c.place.x, by - 1.3);
        break;
      }
      case 'lcd': {
        g.shadowColor = 'rgba(0,0,0,0.5)'; g.shadowBlur = 4;
        g.fillStyle = '#0f5c2e'; rrect(g, bx, by, bw, bh, 1.5); g.fill();
        g.shadowColor = 'transparent';
        g.fillStyle = '#222'; rrect(g, bx + 4, by + 8.5, bw - 8, bh - 15, 1.2); g.fill();
        g.fillStyle = C.silk; g.font = 'bold 2.2px "Segoe UI", sans-serif'; g.textAlign = 'left';
        g.fillText('U10 · NHD-0420H1Z (HD44780) 20x4', bx + 50, by + 3.4);
        g.font = '1.4px "Segoe UI", sans-serif'; g.fillStyle = C.silkDim;
        ['VSS', 'VDD', 'VO', 'RS', 'RW', 'E', 'D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'A', 'K'].forEach((t, i) => {
          g.textAlign = 'center'; g.fillText(t, bx + 8 + i * 2.54, by + 6.2);
        });
        break;
      }
    }
    g.restore();
    // noms des broches (zoom suffisant)
    if (this.showNames && s > 9 && (k === 'dip')) {
      g.save();
      const fs = 0.9;
      g.font = `${fs}px "Cascadia Mono", Consolas, monospace`; g.fillStyle = 'rgba(220,225,230,0.75)';
      g.textAlign = 'center';
      for (const p of c.pinList) {
        const top = p.y < c.place.y;
        g.save();
        g.translate(p.x, top ? by + 0.4 : by + bh - 0.4);
        g.rotate(-Math.PI / 2);
        g.textAlign = top ? 'right' : 'left'; g.textBaseline = 'middle';
        g.fillText(cleanName(p.name), 0, 0);
        g.restore();
        g.fillStyle = 'rgba(235,242,236,0.6)';
        g.textAlign = 'center'; g.textBaseline = 'middle';
        g.fillText(p.n, p.x, top ? p.y - 1.5 : p.y + 1.5);
        g.fillStyle = 'rgba(220,225,230,0.75)';
      }
      g.restore();
    }
  }

  /** Dessin d'une image : sig = etats des signaux, st = etat du LCD, extra = {contrast, powered, t, sd}. */
  draw(sig, lcd, extra) {
    if (this.staticDirty) { this.drawStatic(); this.staticDirty = false; }
    const g = this.g;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, this.cv.width, this.cv.height);
    g.drawImage(this.static, 0, 0);
    const { s } = this.view;
    g.setTransform(s, 0, 0, s, this.view.ox, this.view.oy);
    const powered = extra.powered;
    // net mis en evidence
    const hnet = this.hover ? this.hover.net : null;
    for (const net of [this.highlight, hnet]) {
      if (!net) continue;
      const ps = this.netPins.get(net) || [];
      g.lineWidth = Math.max(0.35, 1.6 / s);
      g.strokeStyle = net === this.highlight ? 'rgba(255,225,77,0.9)' : 'rgba(120,230,255,0.85)';
      for (const r of this.routes) if (r.net === net) {
        g.beginPath(); g.moveTo(r.pts[0], r.pts[1]);
        for (let i = 2; i < r.pts.length; i += 2) g.lineTo(r.pts[i], r.pts[i + 1]);
        g.stroke();
      }
      for (const p of ps) { g.beginPath(); g.arc(p.x, p.y, 1.35, 0, 7); g.stroke(); }
    }
    // niveaux des broches
    for (const p of this.pins) {
      let col;
      if (!powered) col = '#3a3f45';
      else col = this.pinState(p, sig).col;
      g.fillStyle = col;
      circ(g, p.x, p.y, 0.55); g.fill();
    }
    // sondes de l'oscilloscope
    for (const p of this.pins) {
      const pr = this.probes.get(p.net);
      if (pr === undefined) continue;
      g.strokeStyle = pr.color; g.lineWidth = 0.45;
      g.beginPath(); g.arc(p.x, p.y, 1.6, 0, 7); g.stroke();
      if (this.probes.firstPin && this.probes.firstPin.get(p.net) === p) {
        // pointe de sonde : crochet et etiquette de la voie
        g.fillStyle = pr.color; g.font = 'bold 2px "Segoe UI", sans-serif'; g.textAlign = 'left'; g.textBaseline = 'middle';
        g.beginPath(); g.moveTo(p.x + 1.2, p.y - 1.2); g.lineTo(p.x + 3.4, p.y - 3.4); g.lineWidth = 0.6; g.stroke();
        const w = g.measureText(pr.label).width + 1.2;
        g.fillRect(p.x + 3.2, p.y - 4.9, w, 2.6);
        g.fillStyle = '#111'; g.fillText(pr.label, p.x + 3.8, p.y - 3.55);
      }
    }
    // peripheriques vivants
    for (const c of this.comps) {
      if (c.place.kind === 'bar') {
        for (let i = 1; i <= 10; i++) {
          const p = c.pinList.find((q) => q.n === String(i));
          if (!p) continue;
          const st = powered ? this.pinState(p, sig) : { v: 0 };
          if (st.v === 1) {
            g.save(); g.shadowColor = '#ff2d1d'; g.shadowBlur = 6 * s / 4;
            g.fillStyle = '#ff3b2b'; g.fillRect(p.x - 0.8, c.body[1] + 1.2, 1.6, c.body[3] - 2.4);
            g.restore();
          }
        }
      } else if (c.place.kind === 'led') {
        const a = c.pinList.find((q) => q.n === '2');
        const st = powered && a ? this.pinState(a, sig) : { v: 0 };
        if (st.v === 1) {
          g.save(); g.shadowColor = c.place.color === 'g' ? '#39ff88' : '#ffb000'; g.shadowBlur = 10 * s / 4;
          g.fillStyle = c.place.color === 'g' ? '#7dffb0' : '#ffd060'; circ(g, c.place.x, c.place.y, 1.7); g.fill(); g.restore();
        }
      } else if (c.place.kind === 'lcd') {
        const [bx, by, bw, bh] = c.body;
        g.save();
        g.translate(bx + 6, by + 10.5);
        g.scale(1 / 8, 1 / 8);
        drawLcd(g, 0, 0, (bw - 12) * 8, (bh - 19) * 8, lcd, extra.contrast, powered, extra.t);
        g.restore();
      } else if (c.place.kind === 'sdmod') {
        if (extra.sd) {
          const [bx, by] = c.body;
          g.fillStyle = '#1a1d22'; rrect(g, bx + 13.5, by + 2, 12, 15, 0.6); g.fill();
          g.fillStyle = '#2c5fc0'; rrect(g, bx + 14.2, by + 2.6, 10.6, 9, 0.4); g.fill();
          g.fillStyle = '#fff'; g.font = 'bold 1.7px "Segoe UI", sans-serif'; g.textAlign = 'center';
          g.fillText('microSD', bx + 19.5, by + 7.6);
        }
        if (extra.sdAct) {
          const [bx, by] = c.body;
          g.fillStyle = '#ff3b30'; g.save(); g.shadowColor = '#ff3b30'; g.shadowBlur = 8; circ(g, bx + 30, by + 25, 0.9); g.fill(); g.restore();
        }
      } else if (c.place.kind === 'button') {
        if (this.buttonDown) { g.fillStyle = '#383c42'; circ(g, c.place.x, c.place.y, 2.2); g.fill(); }
      } else if (c.place.kind === 'buzzer' && extra.spk) {
        g.strokeStyle = 'rgba(77,163,255,0.8)'; g.lineWidth = 0.35;
        for (let r = 7; r <= 9; r += 1) { g.beginPath(); g.arc(c.place.x, c.place.y, r + (extra.t / 80 % 1), -0.6, 0.6); g.stroke(); }
      }
    }
    // composant survole
    if (this.hoverComp && !this.hover) {
      const [bx, by, bw, bh] = this.hoverComp.body;
      g.strokeStyle = 'rgba(57,255,136,0.6)'; g.lineWidth = Math.max(0.25, 1.2 / s);
      rrect(g, bx - 0.8, by - 0.8, bw + 1.6, bh + 1.6, 1); g.stroke();
    }
    if (this.hover) {
      g.strokeStyle = '#fff'; g.lineWidth = Math.max(0.25, 1.2 / s);
      circ(g, this.hover.x, this.hover.y, 1.25); g.stroke();
    }
  }

  /** Segments des pistes d'un net (et un petit carre par broche), en pixels CSS de la vue. */
  netSegments(net) {
    const out = [];
    const d = this.dpr || 1;
    const P = (x, y) => [(x * this.view.s + this.view.ox) / d, (y * this.view.s + this.view.oy) / d];
    for (const r of this.routes) {
      if (r.net !== net) continue;
      for (let i = 0; i + 3 < r.pts.length; i += 2) {
        const [a, b] = P(r.pts[i], r.pts[i + 1]), [c, e] = P(r.pts[i + 2], r.pts[i + 3]);
        out.push([a, b, c, e, 3]);
      }
    }
    for (const p of this.netPins.get(net) || []) {
      const [x, y] = P(p.x, p.y);
      out.push([x - 3, y, x + 3, y, 2]);
    }
    return out;
  }
  /** Contour d'un composant (4 segments) en pixels CSS de la vue. */
  compRect(c) {
    if (!c) return [];
    const d = this.dpr || 1;
    const [bx, by, bw, bh] = c.body;
    const x0 = (bx * this.view.s + this.view.ox) / d, y0 = (by * this.view.s + this.view.oy) / d;
    const x1 = ((bx + bw) * this.view.s + this.view.ox) / d, y1 = ((by + bh) * this.view.s + this.view.oy) / d;
    return [[x0, y0, x1, y0, 1], [x0, y1, x1, y1, 1], [x0, y0, x0, y1, 1], [x1, y0, x1, y1, 1]];
  }

  describe(pin, sig, powered) {
    const st = powered ? this.pinState(pin, sig) : { txt: t('hors tension'), v: -2 };
    const cls = st.v === 1 ? (st.act ? 'va' : 'v1') : st.v === 0 ? (st.act ? 'va' : 'v0') : st.v === 3 ? 'va' : 'vz';
    const net = pin.net ? pin.net.replace(/^\//, '') : '—';
    const others = (this.netPins.get(pin.net) || []).filter((q) => q !== pin).map((q) => q.comp.ref + '.' + q.n);
    return `<b>${pin.comp.ref}</b> ${t('broche')} <b>${pin.n}</b> · <b>${esc(cleanName(pin.name))}</b>`
      + `<div><span class="k">net</span> ${esc(net)} · <span class="${cls}">${st.txt}</span></div>`
      + (others.length ? `<div class="d">${t('relié à :')} ${others.slice(0, 14).join(', ')}${others.length > 14 ? '…' : ''}</div>` : '')
      + `<div class="d">${esc(role(pin.comp.ref) || pin.comp.value || '')}</div>`;
  }
}

export function cleanName(n) {
  return String(n || '').replace(/~\{([^}]*)\}/g, '/$1').replace(/_\d+$/, '');
}
function esc(s) { return String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }
function hash(str) { let h = 7; for (const ch of String(str)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return h; }
/** Chemin d'une piste de a a b : depart vertical, horizontale decalee de off, chanfreins a 45 degres. */
function route(a, b, off) {
  const x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y;
  const dx = x2 - x1, dy = y2 - y1;
  if (Math.abs(dx) < 0.05 || Math.abs(dy) < 0.05) return [x1, y1, x2, y2];
  const ym = (Math.abs(dy) < 3 ? y1 + dy / 2 : y1 + dy / 2) + off;
  const sx = Math.sign(dx);
  const c1 = Math.min(1.2, Math.abs(ym - y1), Math.abs(dx) / 2), c2 = Math.min(1.2, Math.abs(y2 - ym), Math.abs(dx) / 2);
  const s1 = Math.sign(ym - y1) || 1, s2 = Math.sign(y2 - ym) || 1;
  return [x1, y1, x1, ym - s1 * c1, x1 + sx * c1, ym, x2 - sx * c2, ym, x2, ym + s2 * c2, x2, y2];
}
function labelBox(g, x, y, lines, col) {
  g.font = 'bold 1.8px "Segoe UI", Arial, sans-serif';
  const w = Math.max(...lines.map((l) => g.measureText(l).width)) + 1.6;
  g.fillStyle = col; g.fillRect(x, y, w, lines.length * 2.3 + 0.6);
  g.fillStyle = '#0a2766'; g.textAlign = 'left'; g.textBaseline = 'top';
  lines.forEach((l, i) => g.fillText(l, x + 0.8, y + 0.5 + i * 2.3));
  g.textBaseline = 'alphabetic';
}
function circ(g, x, y, r) { g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); }
function rrect(g, x, y, w, h, r) {
  g.beginPath();
  g.moveTo(x + r, y); g.lineTo(x + w - r, y); g.quadraticCurveTo(x + w, y, x + w, y + r);
  g.lineTo(x + w, y + h - r); g.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  g.lineTo(x + r, y + h); g.quadraticCurveTo(x, y + h, x, y + h - r);
  g.lineTo(x, y + r); g.quadraticCurveTo(x, y, x + r, y); g.closePath();
}
