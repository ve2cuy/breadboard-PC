// Schema interne des circuits logiques 74xx, dessine sur le boitier (vue de la carte).
// Les DIP sont couches, encoche a gauche : broches 1..n/2 en bas (de gauche a droite),
// broches n..n/2+1 en haut (de gauche a droite).

const INK = '#f0de8c';          // traits du schema
const FILL = '#33363b';         // corps des portes
const TXT = 'rgba(240,222,140,0.95)';

/** Type de schema par composant (champ « part » de la netliste). */
export const LOGIC = {
  '74LS00': { kind: 'gates', shape: 'nand', gates: [[1, 2, 3], [4, 5, 6], [13, 12, 11], [10, 9, 8]] },
  '74LS02': { kind: 'gates', shape: 'nor', gates: [[2, 3, 1], [5, 6, 4], [11, 12, 13], [8, 9, 10]] },
  '74HC14': { kind: 'inv', gates: [[1, 2], [3, 4], [5, 6], [13, 12], [11, 10], [9, 8]] },
  '74LS74': { kind: 'ff', ffs: [[1, 2, 3, 4, 5, 6], [13, 12, 11, 10, 9, 8]] },
  '74LS573': { kind: 'latch' },
  '74LS138': { kind: 'dec' },
};

export function hasLogic(c) { return !!LOGIC[c.part]; }

/** Dessine le schema interne ; rend true si le composant en a un. */
export function drawLogic(g, c) {
  const L = LOGIC[c.part];
  if (!L) return false;
  const [bx, by, bw, bh] = c.body;
  const cy = by + bh / 2;
  const pin = (n) => c.pinList.find((p) => p.n === String(n));
  const px = (n) => pin(n).x;
  const isTop = (n) => pin(n).y < cy;
  g.save();
  g.lineWidth = 0.13; g.strokeStyle = INK; g.lineJoin = 'round'; g.lineCap = 'round';
  const label = (txt, x, y, size = 0.8, align = 'center') => {
    g.fillStyle = TXT; g.font = `600 ${size}px "Segoe UI", Arial, sans-serif`; g.textAlign = align; g.textBaseline = 'middle';
    g.fillText(txt, x, y);
  };
  const power = () => {
    // alimentation : derniere broche = VCC, broche n/2 = GND
    const n = c.pinList.filter((p) => /^\d+$/.test(p.n)).length;
    for (const [num, txt] of [[n, '+5'], [n / 2, '0V']]) {
      const p = pin(num);
      if (p) label(txt, p.x, p.y < cy ? by + 0.55 : by + bh - 0.55, 0.62);
    }
  };
  // repere local d'une porte : origine sur l'axe de la porte, x vers la sortie, y vers le bord des broches
  const local = (x, top, dir, gy, fn) => {
    g.save();
    g.translate(x, gy);
    g.scale(dir, top ? -1 : 1);
    fn(Math.abs((top ? by : by + bh) - gy));
    g.restore();
  };
  const bubble = (x, y) => { g.beginPath(); g.arc(x, y, 0.2, 0, Math.PI * 2); g.fillStyle = FILL; g.fill(); g.stroke(); };

  switch (L.kind) {
    case 'gates': {
      for (const [a, b, y] of L.gates) {
        const top = isTop(y);
        const xs = [px(a), px(b)].sort((u, v) => u - v);
        const dir = px(y) > xs[1] ? 1 : -1;
        const inner = dir > 0 ? xs[1] : xs[0];        // entree voisine de la sortie
        const gy = cy + (top ? -1 : 1) * bh * 0.2;
        local(inner, top, dir, gy, (E) => {
          const x0 = 0.42, w = 1.45, h = 1.5;
          g.beginPath();
          g.moveTo(-2.54, E); g.lineTo(-2.54, -0.42); g.lineTo(x0 + (L.shape === 'nor' ? 0.22 : 0), -0.42);
          g.moveTo(0, E); g.lineTo(0, 0.42); g.lineTo(x0 + (L.shape === 'nor' ? 0.22 : 0), 0.42);
          g.moveTo(x0 + w + 0.4, 0); g.lineTo(2.54, 0); g.lineTo(2.54, E);
          g.stroke();
          g.beginPath();
          if (L.shape === 'nand') {
            g.moveTo(x0, -h / 2); g.lineTo(x0 + w - h / 2, -h / 2);
            g.arc(x0 + w - h / 2, 0, h / 2, -Math.PI / 2, Math.PI / 2);
            g.lineTo(x0, h / 2); g.closePath();
          } else {
            g.moveTo(x0, -h / 2);
            g.quadraticCurveTo(x0 + w * 0.6, -h / 2, x0 + w, 0);
            g.quadraticCurveTo(x0 + w * 0.6, h / 2, x0, h / 2);
            g.quadraticCurveTo(x0 + 0.42, 0, x0, -h / 2);
          }
          g.fillStyle = FILL; g.fill(); g.stroke();
          bubble(x0 + w + 0.2, 0);
        });
      }
      power();
      break;
    }
    case 'inv': {
      for (const [a, y] of L.gates) {
        const top = isTop(a);
        const dir = px(y) > px(a) ? 1 : -1;
        const gy = cy + (top ? -1 : 1) * bh * 0.2;
        local(px(a), top, dir, gy, (E) => {
          g.beginPath();
          g.moveTo(0, E); g.lineTo(0, 0); g.lineTo(0.45, 0);
          g.moveTo(1.95, 0); g.lineTo(2.54, 0); g.lineTo(2.54, E);
          g.stroke();
          g.beginPath(); g.moveTo(0.45, -0.7); g.lineTo(1.55, 0); g.lineTo(0.45, 0.7); g.closePath();
          g.fillStyle = FILL; g.fill(); g.stroke();
          bubble(1.75, 0);
          // hysteresis (trigger de Schmitt)
          g.save(); g.lineWidth = 0.08;
          g.beginPath(); g.moveTo(0.58, 0.2); g.lineTo(0.8, 0.2); g.lineTo(0.8, -0.2); g.lineTo(1.05, -0.2);
          g.moveTo(0.7, 0.2); g.lineTo(0.7, -0.2); g.lineTo(0.93, -0.2); g.stroke();
          g.restore();
        });
      }
      power();
      break;
    }
    case 'ff': {
      const NAMES = ['R', 'D', '>', 'S', 'Q', 'Q'];
      for (const pins of L.ffs) {
        const top = isTop(pins[0]);
        const xs = pins.map(px);
        const x0 = Math.min(...xs) - 0.95, x1 = Math.max(...xs) + 0.95;
        const edge = top ? by : by + bh;
        const ya = top ? by + 0.75 : cy + 0.3, yb = top ? cy - 0.3 : by + bh - 0.75;
        g.beginPath(); g.rect(x0, ya, x1 - x0, yb - ya); g.fillStyle = FILL; g.fill(); g.stroke();
        const near = top ? ya : yb;
        pins.forEach((n, i) => {
          const x = px(n);
          const inv = i === 0 || i === 3 || i === 5;      // CLR#, PRE#, Q#
          g.beginPath(); g.moveTo(x, edge); g.lineTo(x, near + (inv ? (top ? -0.4 : 0.4) : 0)); g.stroke();
          if (inv) bubble(x, near + (top ? -0.2 : 0.2));
          const ty = near + (top ? 0.62 : -0.62);
          if (NAMES[i] === '>') {
            g.beginPath(); g.moveTo(x - 0.35, near); g.lineTo(x, near + (top ? 0.5 : -0.5)); g.lineTo(x + 0.35, near); g.stroke();
          } else {
            label(NAMES[i], x, ty, 0.8);
            if (i === 5) { g.beginPath(); g.moveTo(x - 0.3, ty - 0.5); g.lineTo(x + 0.3, ty - 0.5); g.stroke(); }
          }
        });
        label('D-FF', (x0 + x1) / 2 + 2.5, top ? yb - 0.55 : ya + 0.55, 0.6);
      }
      power();
      break;
    }
    case 'latch': {
      // 8 verrous transparents : D (en bas) -> Q (en haut), LE commune, OE#
      for (let i = 0; i < 8; i++) {
        const x = px(2 + i);
        g.beginPath();
        g.moveTo(x, by + bh); g.lineTo(x, cy + 0.85);
        g.moveTo(x, cy - 0.85); g.lineTo(x, by);
        g.stroke();
        g.beginPath(); g.moveTo(x - 0.7, cy + 0.85); g.lineTo(x + 0.7, cy + 0.85); g.lineTo(x, cy - 0.85); g.closePath();
        g.fillStyle = FILL; g.fill(); g.stroke();
      }
      // LE (broche 11, en haut a droite) : ligne de commande commune
      const xl = px(11), xo = px(1);
      g.save(); g.setLineDash([0.35, 0.25]);
      g.beginPath(); g.moveTo(xl, by); g.lineTo(xl, cy + 0.2); g.lineTo(px(2) - 0.9, cy + 0.2); g.stroke();
      // OE# (broche 1, en bas a gauche) : validation des sorties
      g.beginPath(); g.moveTo(xo, by + bh - 0.45); g.lineTo(xo, cy - 0.45); g.lineTo(px(9) + 0.9, cy - 0.45); g.stroke();
      g.restore();
      bubble(xo, by + bh - 0.25);
      label('LE', xl, by + 1.0, 0.62);
      label('OE', xo - 0.05, cy - 1.0, 0.62);
      power();
      break;
    }
    case 'dec': {
      // decodeur 3 vers 8 : A, B, C et validations en bas, sorties actives a 0
      const x0 = px(1) - 0.95, x1 = px(8) + 0.4;
      const ya = by + 0.85, yb = by + bh - 0.85;
      g.beginPath(); g.rect(x0, ya, x1 - x0, yb - ya); g.fillStyle = FILL; g.fill(); g.stroke();
      const names = { 1: 'A', 2: 'B', 3: 'C', 4: 'G2A', 5: 'G2B', 6: 'G1', 7: 'Y7', 9: 'Y6', 10: 'Y5', 11: 'Y4', 12: 'Y3', 13: 'Y2', 14: 'Y1', 15: 'Y0' };
      const low = new Set([4, 5, 7, 9, 10, 11, 12, 13, 14, 15]);
      for (const k of Object.keys(names)) {
        const n = +k, x = px(n), top = isTop(n);
        const edge = top ? by : by + bh, near = top ? ya : yb;
        g.beginPath(); g.moveTo(x, edge); g.lineTo(x, near + (low.has(n) ? (top ? -0.4 : 0.4) : 0)); g.stroke();
        if (low.has(n)) bubble(x, near + (top ? -0.2 : 0.2));
        label(names[n], x, near + (top ? 0.55 : -0.55), names[n].length > 2 ? 0.55 : 0.7);
      }
      label('3 → 8', (x0 + x1) / 2, (ya + yb) / 2, 0.85);
      power();
      break;
    }
  }
  g.restore();
  return true;
}
