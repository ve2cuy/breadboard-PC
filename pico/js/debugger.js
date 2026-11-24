// Debogueur : registres, drapeaux, desassemblage, points d'arret, pile, memoire, E/S.

import { t } from './i18n.js';

const REGS = ['AX', 'BX', 'CX', 'DX', 'SI', 'DI', 'BP', 'SP', 'CS', 'DS', 'ES', 'SS', 'IP', 'FLAGS'];
// indices dans Sim.regs() : AX CX DX BX SP BP SI DI ES CS SS DS IP FLAGS HALT
const RIDX = { AX: 0, CX: 1, DX: 2, BX: 3, SP: 4, BP: 5, SI: 6, DI: 7, ES: 8, CS: 9, SS: 10, DS: 11, IP: 12, FLAGS: 13 };
const FLAGS = [['O', 11], ['D', 10], ['I', 9], ['T', 8], ['S', 7], ['Z', 6], ['A', 4], ['P', 2], ['C', 0]];
const hex = (v, n = 4) => v.toString(16).toUpperCase().padStart(n, '0');

/** "F000:E05B", "FE05B", "ds:si" -> adresse lineaire (ou null). */
export function parseAddr(s, regs) {
  s = String(s).trim().toLowerCase();
  if (!s) return null;
  const val = (t) => {
    t = t.trim();
    if (regs && RIDX[t.toUpperCase()] !== undefined) return regs[RIDX[t.toUpperCase()]];
    const h = t.replace(/h$/, '');
    if (!/^[0-9a-f]+$/.test(h)) return null;
    return parseInt(h, 16);
  };
  if (s.includes(':')) {
    const [a, b] = s.split(':');
    const sg = val(a), of = val(b);
    if (sg === null || of === null) return null;
    return ((sg << 4) + of) & 0xFFFFF;
  }
  const v = val(s);
  return v === null ? null : v & 0xFFFFF;
}

export class Debugger {
  constructor(sim, el, hooks) {
    this.sim = sim;
    this.el = el;
    this.hooks = hooks;          // { pause(), resume(), isRunning(), refreshAll() }
    this.bps = [];
    this.prev = null;
    this.memAddr = 0x400;
    this.build();
  }

  build() {
    const $ = (id) => document.getElementById(id);
    this.$regs = $('dbgRegs'); this.$flags = $('dbgFlags'); this.$dis = $('dbgDis');
    this.$bps = $('dbgBps'); this.$stack = $('dbgStack'); this.$mem = $('dbgMem'); this.$io = $('dbgIo');
    this.$regs.innerHTML = REGS.map((r) => `<div class="reg" data-r="${r}" title="${t('Double-clic : modifier')}"><label>${r}</label><span>0000</span></div>`).join('');
    this.$flags.innerHTML = FLAGS.map(([f, b]) => `<span class="flag" data-b="${b}" title="${t('Cliquer pour inverser')}">${f}F</span>`).join('');
    this.$regs.addEventListener('dblclick', (e) => {
      const d = e.target.closest('.reg'); if (!d) return;
      const r = d.dataset.r;
      const cur = this.sim.regs()[RIDX[r]];
      const v = prompt(t('Nouvelle valeur de {0} (hexadécimal)', r), hex(cur));
      if (v === null) return;
      const n = parseInt(v.replace(/h$/i, ''), 16);
      if (!isNaN(n)) { this.sim.set_reg(RIDX[r], n & 0xFFFF); this.refresh(true); }
    });
    this.$flags.addEventListener('click', (e) => {
      const f = e.target.closest('.flag'); if (!f) return;
      const fl = this.sim.regs()[13];
      this.sim.set_reg(13, fl ^ (1 << +f.dataset.b));
      this.refresh(true);
    });
    this.$dis.addEventListener('click', (e) => {
      const l = e.target.closest('.dl'); if (!l) return;
      if (e.target.classList.contains('bp')) this.toggleBp(+l.dataset.a);
    });
    this.$bps.addEventListener('click', (e) => {
      const d = e.target.closest('[data-a]'); if (d) this.toggleBp(+d.dataset.a);
    });
    $('dbgBpAdd').onclick = () => {
      const a = parseAddr($('dbgBpIn').value, this.sim.regs());
      if (a === null) { $('dbgBpIn').focus(); return; }
      if (!this.bps.includes(a)) this.toggleBp(a);
      $('dbgBpIn').value = '';
    };
    $('dbgBpIn').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('dbgBpAdd').click(); e.stopPropagation(); });
    const go = () => {
      const a = parseAddr($('dbgMemAddr').value, this.sim.regs());
      if (a !== null) {
        const t = $('dbgMemAddr').value;
        const sg = t.includes(':') ? parseAddr(t.split(':')[0] + ':0', this.sim.regs()) : null;
        this.memSeg = sg !== null ? sg >> 4 : null;
        this.memAddr = a & 0xFFFF0;
        this.refresh(true);
      }
    };
    $('dbgMemGo').onclick = go;
    $('dbgMemAddr').addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); e.stopPropagation(); });
    $('dbgMemQuick').onchange = (e) => { if (e.target.value) { $('dbgMemAddr').value = e.target.value; go(); e.target.value = ''; } };
    this.$mem.addEventListener('wheel', (e) => { e.preventDefault(); this.memAddr = (this.memAddr + (e.deltaY > 0 ? 0x40 : -0x40)) & 0xFFFF0; this.refresh(true); }, { passive: false });
    $('dbgPause').onclick = () => (this.hooks.isRunning() ? this.hooks.pause() : this.hooks.resume());
    $('dbgStep').onclick = () => this.step();
    $('dbgOver').onclick = () => this.stepOver();
    $('dbgOut').onclick = () => this.stepOut();
  }

  toggleBp(a) {
    const i = this.bps.indexOf(a);
    if (i >= 0) this.bps.splice(i, 1); else this.bps.push(a);
    this.sim.set_breakpoints(Uint32Array.from(this.bps));
    this.refresh(true);
  }

  step() {
    this.hooks.pause();
    this.sim.step();
    this.hooks.refreshAll();
  }

  /** Par-dessus : CALL, INT, LOOP, REP... (arret temporaire apres l'instruction). */
  stepOver() {
    this.hooks.pause();
    const r = this.sim.regs();
    const cs = r[9], ip = r[12];
    const line = this.sim.disasm(cs, ip, 1).split('|')[3] || '';
    if (/^(call|int|loop|rep|repne)/.test(line.trim())) {
      const next = ((cs << 4) + ((ip + this.sim.insn_len(cs, ip)) & 0xFFFF)) & 0xFFFFF;
      this.runUntil((sim) => { const q = sim.regs(); return ((q[9] << 4) + q[12]) % 0x100000 === next; });
    } else this.step();
  }

  /** Jusqu'au prochain RET/IRET au meme niveau de pile. */
  stepOut() {
    this.hooks.pause();
    const sp0 = this.sim.regs()[4];
    this.runUntil((sim) => {
      const q = sim.regs();
      const t = (sim.disasm(q[9], q[12], 1).split('|')[3] || '').trim();
      if (/^(ret|retf|iret)/.test(t) && q[4] >= sp0) { sim.step(); return true; }
      return false;
    });
  }

  runUntil(done) {
    const sim = this.sim;
    let n = 0;
    sim.step();
    while (n < 2_000_000 && !done(sim)) { sim.step(); n++; }
    this.hooks.refreshAll();
  }

  refresh(force) {
    if (!force && this.hooks.isRunning() && !this.visible) return;
    const r = this.sim.regs();
    const v = { AX: r[0], CX: r[1], DX: r[2], BX: r[3], SP: r[4], BP: r[5], SI: r[6], DI: r[7], ES: r[8], CS: r[9], SS: r[10], DS: r[11], IP: r[12], FLAGS: r[13] };
    for (const d of this.$regs.children) {
      const k = d.dataset.r;
      d.querySelector('span').textContent = hex(v[k]);
      d.classList.toggle('chg', !!this.prev && this.prev[k] !== v[k] && !this.hooks.isRunning());
    }
    for (const f of this.$flags.children) f.classList.toggle('on', (v.FLAGS >> +f.dataset.b) & 1);
    // desassemblage : quelques instructions avant (depuis la trace) et apres
    const cur = ((v.CS << 4) + v.IP) & 0xFFFFF;
    const trace = Array.from(this.sim.trace()).slice(-6, -0 || undefined).filter((a) => a !== cur);
    let start = v.IP;
    const prior = trace.filter((a) => a >= (v.CS << 4) && a < cur && cur - a < 40);
    if (prior.length) start = (prior[Math.max(0, prior.length - 4)] - (v.CS << 4)) & 0xFFFF;
    const lines = this.sim.disasm(v.CS, start, 22).trim().split('\n');
    this.$dis.innerHTML = lines.map((l) => {
      const [lin, at, by, tx] = l.split('|');
      const a = +lin;
      const c = (a === cur ? ' cur' : '') + (this.bps.includes(a) ? ' has-bp' : '');
      return `<div class="dl${c}" data-a="${a}"><span class="bp">●</span><span class="ad">${at}</span><span class="by">${by}</span><span class="tx" title="${esc(tx || '')}">${esc(tx || '')}</span></div>`;
    }).join('');
    this.$bps.innerHTML = this.bps.length
      ? this.bps.map((a) => `<div data-a="${a}" title="${t('Cliquer pour retirer')}"><span>${hex(a, 5)}</span><span>✕</span></div>`).join('')
      : `<span style="color:var(--faint)">${t('aucun')}</span>`;
    const st = this.sim.peek(((v.SS << 4) + v.SP) & 0xFFFFF, 16);
    let s = '';
    for (let i = 0; i < 8; i++) s += `${hex((v.SP + i * 2) & 0xFFFF)}  ${hex(st[i * 2] | (st[i * 2 + 1] << 8))}\n`;
    this.$stack.textContent = s;
    // memoire
    const m = this.sim.peek(this.memAddr, 128);
    let h = '';
    for (let row = 0; row < 8; row++) {
      const a = (this.memAddr + row * 16) & 0xFFFFF;
      let hx = '', asc = '';
      for (let k = 0; k < 16; k++) {
        const b = m[row * 16 + k];
        hx += hex(b, 2) + (k === 7 ? '  ' : ' ');
        asc += b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : '.';
      }
      let seg = (a >> 4) & 0xF000;
      if (this.memSeg != null && a >= this.memSeg << 4 && a - (this.memSeg << 4) <= 0xFFFF) seg = this.memSeg;
      h += `<span class="a">${hex(seg)}:${hex(a - (seg << 4))}</span>  <span class="h">${hx}</span> <span class="c">${esc(asc)}</span>\n`;
    }
    this.$mem.innerHTML = h;
    // E/S
    const io = this.sim.io_history().trim().split('\n').filter(Boolean).slice(0, 40);
    this.$io.innerHTML = io.map((l) => {
      const [t, d, p, val] = l.split('|');
      return `<span class="${d === 'OUT' ? 'w' : 'r'}">${d.padEnd(3)}</span> ${p.slice(2)}h ${d === 'OUT' ? '←' : '→'} ${val}h   <span style="color:var(--faint)">${(t / 5333.333).toFixed(3)} ms ${portName(parseInt(p, 16))}</span>`;
    }).join('\n');
    if (!this.hooks.isRunning()) this.prev = v;
  }
}

function portName(p) {
  p &= 0xFF;
  if (p & 0x80) return t('(non décodé)');
  return t(['LCD', 'U7 8255 (DEL)', '8259', 'U12 8255', '8253', 'libre (O5)', 'port 61h', 'libre (O7)'][p >> 4] || '');
}
function esc(s) { return String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }
