// La page sur un iPad emule (Edge sans fenetre, protocole DevTools) : ecran tactile, paysage puis
// portrait. Verifie que la page defile jusqu'au bas (barre d'etat, bas des onglets) ; captures.
//   node outils/essai_ipad.mjs [--url http://localhost:8099/] [--dossier C:/temp]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const URL_PAGE = opt('--url', 'http://localhost:8099/');
const DOSSIER = opt('--dossier', os.tmpdir());
const NAV = opt('--navigateur', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe');
const PORT = 9334;
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
const profil = fs.mkdtempSync(path.join(os.tmpdir(), 's02-ipad-'));
const nav = spawn(NAV, ['--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profil}`, 'about:blank'], { stdio: 'ignore' });
let ws;
for (let i = 0; i < 50 && !ws; i++) {
  try {
    const p = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find((x) => x.type === 'page');
    if (p) ws = new WebSocket(p.webSocketDebuggerUrl);
  } catch (e) { /* demarrage */ }
  if (!ws) await dormir(200);
}
await new Promise((r) => { ws.onopen = r; });
let n = 0;
const att = new Map();
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && att.has(m.id)) { att.get(m.id)(m); att.delete(m.id); } };
const cdp = (method, params = {}) => new Promise((r) => { const id = ++n; att.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (e) => (await cdp('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;

let echecs = 0;
for (const [nom, w, h] of [['paysage', 1180, 820], ['portrait', 820, 1180]]) {
  await cdp('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 2, mobile: true });
  await cdp('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await cdp('Emulation.setEmitTouchEventsForMouse', { enabled: true, configuration: 'mobile' });
  await cdp('Page.navigate', { url: URL_PAGE });
  for (let i = 0; i < 60 && !(await js('!!(window.simulateur && window.simulateur.sim)').catch(() => false)); i++) await dormir(200);
  await dormir(1000);
  const r = await js(`(() => {
    const se = document.scrollingElement;
    const coarse = matchMedia('(pointer: coarse)').matches;
    window.scrollTo(0, se.scrollHeight);
    const bas = (sel) => { const e = document.querySelector(sel); const b = e.getBoundingClientRect(); return Math.round(b.bottom); };
    return { coarse, hauteur: se.scrollHeight, vue: innerHeight, defile: se.scrollHeight > innerHeight + 10,
             statusbar: bas('.statusbar'), dock: bas('.dock'), sy: Math.round(scrollY) };
  })()`);
  const ok = r.coarse && r.statusbar <= r.vue + 2 && r.dock <= r.vue + 2;
  console.log(`${ok ? 'REUSSI' : 'ECHEC '} ${nom} ${w}x${h} : ${JSON.stringify(r)}`);
  if (!ok) echecs++;
  const cap = await cdp('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(DOSSIER, `ipad-${nom}.png`), Buffer.from(cap.result.data, 'base64'));
}
ws.close();
nav.kill();
process.exit(echecs ? 1 : 0);
