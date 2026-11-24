// Terminal serie (J5) : VT100/ANSI, UTF-8, 80 colonnes, historique. Rendu DOM (texte copiable).

const COLS = 80, ROWS = 25, KEEP = 1500;
const PAL = ['#1b1d1e', '#e0453d', '#4ec95a', '#d9b54a', '#4a7fe0', '#c75ed6', '#42c3cf', '#c8ccc8',
             '#6b7076', '#ff6b61', '#7dff8c', '#ffe27a', '#79a7ff', '#f08cff', '#7df0ff', '#ffffff'];

function blankLine() { return { ch: new Array(COLS).fill(' '), at: new Array(COLS).fill(0x07) }; }

export class Terminal {
  constructor(el) {
    this.el = el;
    this.lines = [];
    for (let i = 0; i < ROWS; i++) this.lines.push(blankLine());
    this.top = 0;           // indice de la 1re ligne de l'ecran
    this.x = 0; this.y = 0;
    this.attr = 0x07;       // fond << 4 | encre ; bit 8 = gras ; bit 9 = inverse
    this.saved = [0, 0];
    this.state = 0; this.params = '';
    this.dec = new TextDecoder('utf-8');
    this.dirty = true;
    this.all = '';          // journal brut de la session
    this.bell = null;
  }
  get rows() { return this.lines.length; }
  line(y) { return this.lines[this.top + y]; }

  write(bytes) {
    if (!bytes || !bytes.length) return;
    const s = this.dec.decode(bytes, { stream: true });
    for (const c of s) this.put(c);
    this.dirty = true;
  }

  scroll() {
    this.lines.push(blankLine());
    if (this.lines.length - this.top > ROWS) this.top++;
    if (this.top > KEEP) { this.lines.splice(0, this.top - ROWS); this.top = this.lines.length - ROWS; this.full = true; }
  }

  put(c) {
    const code = c.codePointAt(0);
    if (this.state === 1) {                  // apres ESC
      if (c === '[') { this.state = 2; this.params = ''; return; }
      if (c === '7') this.saved = [this.x, this.y];
      else if (c === '8') [this.x, this.y] = this.saved;
      else if (c === 'c') { this.clear(); }
      this.state = 0; return;
    }
    if (this.state === 2) {                  // CSI
      if (/[0-9;?]/.test(c)) { this.params += c; return; }
      this.csi(c, this.params); this.state = 0; return;
    }
    switch (code) {
      case 0x1B: this.state = 1; return;
      case 0x0D: this.x = 0; this.all += '\n'; return;
      case 0x0A: this.newline(); return;
      case 0x08: if (this.x > 0) this.x--; return;
      case 0x09: this.x = Math.min(COLS - 1, (this.x + 8) & ~7); return;
      case 0x07: if (this.bell) this.bell(); return;
      case 0x0C: this.clear(); return;
      case 0x00: return;
    }
    if (code < 0x20) return;
    if (this.x >= COLS) { this.x = 0; this.newline(); }
    const l = this.line(this.y);
    l.ch[this.x] = c;
    l.at[this.x] = this.attr;
    this.x++;
    if (this.all.length < 2_000_000) this.all += c;
  }

  newline() {
    if (this.y < ROWS - 1) this.y++;
    else this.scroll();
  }

  clear() {
    for (let y = 0; y < ROWS; y++) this.lines[this.top + y] = blankLine();
    this.x = this.y = 0;
  }

  csi(f, p) {
    const a = p.replace('?', '').split(';').map((v) => parseInt(v, 10));
    const n = (i, d = 1) => (isNaN(a[i]) || a[i] === 0 ? d : a[i]);
    switch (f) {
      case 'A': this.y = Math.max(0, this.y - n(0)); break;
      case 'B': this.y = Math.min(ROWS - 1, this.y + n(0)); break;
      case 'C': this.x = Math.min(COLS - 1, this.x + n(0)); break;
      case 'D': this.x = Math.max(0, this.x - n(0)); break;
      case 'G': this.x = Math.min(COLS - 1, n(0) - 1); break;
      case 'H': case 'f': this.y = Math.min(ROWS - 1, n(0) - 1); this.x = Math.min(COLS - 1, n(1) - 1); break;
      case 'J': {
        const m = isNaN(a[0]) ? 0 : a[0];
        if (m === 2 || m === 3) { this.clear(); break; }
        if (m === 0) { this.eraseLine(0); for (let y = this.y + 1; y < ROWS; y++) this.lines[this.top + y] = blankLine(); }
        if (m === 1) { this.eraseLine(1); for (let y = 0; y < this.y; y++) this.lines[this.top + y] = blankLine(); }
        break;
      }
      case 'K': this.eraseLine(isNaN(a[0]) ? 0 : a[0]); break;
      case 'm': this.sgr(a); break;
      case 's': this.saved = [this.x, this.y]; break;
      case 'u': [this.x, this.y] = this.saved; break;
    }
  }

  eraseLine(m) {
    const l = this.line(this.y);
    const [s, e] = m === 0 ? [this.x, COLS] : m === 1 ? [0, this.x + 1] : [0, COLS];
    for (let i = s; i < e; i++) { l.ch[i] = ' '; l.at[i] = this.attr & 0xF0; }
  }

  sgr(a) {
    if (!a.length || isNaN(a[0])) a = [0];
    for (const v of a) {
      if (v === 0) this.attr = 0x07;
      else if (v === 1) this.attr |= 0x100;
      else if (v === 22) this.attr &= ~0x100;
      else if (v === 7) this.attr |= 0x200;
      else if (v === 27) this.attr &= ~0x200;
      else if (v >= 30 && v <= 37) this.attr = (this.attr & ~0x0F) | (v - 30);
      else if (v >= 90 && v <= 97) this.attr = (this.attr & ~0x0F) | (v - 90 + 8);
      else if (v === 39) this.attr = (this.attr & ~0x0F) | 7;
      else if (v >= 40 && v <= 47) this.attr = (this.attr & ~0xF0) | ((v - 40) << 4);
      else if (v >= 100 && v <= 107) this.attr = (this.attr & ~0xF0) | ((v - 100 + 8) << 4);
      else if (v === 49) this.attr &= ~0xF0;
    }
  }

  buildRow(i) {
    const l = this.lines[i];
    const row = document.createElement('div');
    row.className = 'row';
    const curY = this.top + this.y;
    let run = '', ra = -1;
    const flush = () => {
      if (!run) return;
      if (ra === 0x07) row.appendChild(document.createTextNode(run));
      else {
        const sp = document.createElement('span');
        let fg = ra & 0x0F, bg = (ra >> 4) & 0x0F;
        if (ra & 0x100 && fg < 8) fg += 8;
        if (ra & 0x200) [fg, bg] = [bg, fg];
        sp.style.color = PAL[fg];
        if (bg) sp.style.background = PAL[bg];
        if (ra & 0x100) sp.style.fontWeight = '700';
        sp.textContent = run;
        row.appendChild(sp);
      }
      run = '';
    };
    let last = COLS - 1;
    while (last >= 0 && l.ch[last] === ' ' && (l.at[last] & 0xF0) === 0) last--;
    const end = Math.max(last, i === curY ? this.x : -1);
    for (let x = 0; x <= end && x < COLS; x++) {
      if (i === curY && x === this.x) {
        flush();
        const c = document.createElement('span');
        c.className = 'cur';
        c.textContent = l.ch[x];
        row.appendChild(c);
        continue;
      }
      const at = l.at[x];
      if (at !== ra) { flush(); ra = at; }
      run += l.ch[x];
    }
    flush();
    return row;
  }

  render() {
    if (!this.dirty) return;
    this.dirty = false;
    const el = this.el;
    const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 4;
    if (!this.els || this.els.length > this.lines.length || this.full) {
      this.els = [];
      this.full = false;
      el.replaceChildren();
      this.shown = new Array(0);
    }
    const curY = this.top + this.y;
    // lignes de l'ecran (les seules qui changent) + nouvelles lignes
    const from = Math.max(0, Math.min(this.prevTop ?? 0, this.top, this.els.length));
    for (let i = from; i < this.lines.length; i++) {
      const row = this.buildRow(i);
      if (i < this.els.length) el.replaceChild(row, this.els[i]);
      else el.appendChild(row);
      this.els[i] = row;
    }
    this.lastCur = curY;
    this.prevTop = this.top;
    if (atBottom) el.scrollTop = el.scrollHeight;
  }
  text() {
    return this.lines.map((l) => l.ch.join('').replace(/\s+$/, '')).join('\n').replace(/\n+$/, '\n');
  }

  reset() {
    this.lines = [];
    for (let i = 0; i < ROWS; i++) this.lines.push(blankLine());
    this.top = 0; this.x = this.y = 0; this.attr = 0x07; this.state = 0; this.all = ''; this.full = true;
    this.dirty = true;
  }
}
