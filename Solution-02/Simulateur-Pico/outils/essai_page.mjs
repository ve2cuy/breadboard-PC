// Essai de la vraie page dans Edge (ou Chrome) sans fenetre, pilote par le protocole DevTools :
// la page demarre FreeDOS + mTCP depuis la carte du Pico (FDNET.IMG), puis PING, HTGET de www.s02
// (Internet integre) et d'un vrai site (DNS-over-HTTPS et fetch() depuis la page, ou relais).
// Capture d'ecran a la fin.
//
//   python outils/serveur.py --port 8099 --pas-de-navigateur      (dans une autre fenetre)
//   node outils/essai_page.mjs [--url http://localhost:8099/] [--site example.com] [--relais ws://127.0.0.1:8765]
//        [--capture page.png] [--navigateur "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const URL_PAGE = opt('--url', 'http://localhost:8099/');
const SITE = opt('--site', 'api.ipify.org');
const RELAIS = opt('--relais', '');
const CAPTURE = opt('--capture', path.join(os.tmpdir(), 'simulateur-pico.png'));
const NAV = opt('--navigateur', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe');
const PORT = 9333;
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

const profil = fs.mkdtempSync(path.join(os.tmpdir(), 's02-nav-'));
const nav = spawn(NAV, ['--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profil}`,
  '--window-size=1700,1050', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', 'about:blank'],
  { stdio: 'ignore' });
let ws;
for (let i = 0; i < 50 && !ws; i++) {
  try {
    const l = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const p = l.find((x) => x.type === 'page');
    if (p) ws = new WebSocket(p.webSocketDebuggerUrl);
  } catch (e) { /* le navigateur demarre */ }
  if (!ws) await dormir(200);
}
await new Promise((r) => { ws.onopen = r; });
let n = 0;
const attente = new Map();
const consoles = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && attente.has(m.id)) { attente.get(m.id)(m); attente.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') consoles.push(m.params.args.map((a) => a.value ?? a.description).join(' '));
  if (m.method === 'Runtime.exceptionThrown') consoles.push('EXCEPTION ' + m.params.exceptionDetails.exception?.description);
};
const cdp = (method, params = {}) => new Promise((r) => { const id = ++n; attente.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expr) => {
  const r = await cdp('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description || 'erreur');
  return r.result?.result?.value;
};

let echecs = 0;
const verifier = (c, m) => { console.log((c ? 'REUSSI ' : 'ECHEC  ') + m); if (!c) echecs++; };
try {
  await cdp('Runtime.enable');
  await cdp('Page.enable');
  await cdp('Page.navigate', { url: URL_PAGE + '?onglet=pico' });
  for (let i = 0; i < 100 && !(await js('!!(window.simulateur && window.simulateur.pico)').catch(() => false)); i++) await dormir(200);
  verifier(await js('!!window.simulateur.sim.pico()'), 'page chargee, Pico monte');
  // vitesse maximale, carte FDNET seule dans J14
  await js(`(async () => {
    const S = window.simulateur;
    document.getElementById('selSpeed').value = document.getElementById('selSpeed').options[document.getElementById('selSpeed').options.length - 1].value;
    document.getElementById('selSpeed').dispatchEvent(new Event('change'));
    const img = new Uint8Array(await (await fetch('images/FDNET_C.IMG')).arrayBuffer());
    S.sim.sd_clear_files(); S.sim.sd_add_file('FDNET.IMG', img); S.sim.sd_insert_built(); S.sdPresent = true;
    S.sim.set_sd_pico(true);
    document.getElementById('btnReset').dispatchEvent(new MouseEvent('mousedown'));
    await new Promise((r) => setTimeout(r, 100));
    document.getElementById('btnReset').dispatchEvent(new MouseEvent('mouseup'));
    return true; })()`);
  if (RELAIS) {
    await js(`(() => { document.getElementById('netRelais').value = '${RELAIS}'; document.getElementById('netRelaisBtn').click(); return 1; })()`);
  }
  const temps = () => js('window.simulateur.sim.cycles() / 5333333.33');
  const ecran = () => js('window.simulateur.term.text()');
  const attendre = async (cond, simS, nom) => {
    const t0 = await temps();
    while ((await temps()) - t0 < simS) {
      if (cond(await ecran())) return true;
      await dormir(250);
    }
    console.log('  (delai depasse : ' + nom + ')');
    return false;
  };
  const touche = async (code, ext = false) => {
    const p = ext ? [0xE0, code] : [code];
    await js(`window.simulateur.sim.kbd(new Uint8Array([${p}]))`);
    const t0 = await temps(); while ((await temps()) - t0 < 0.4) await dormir(50);
    await js(`window.simulateur.sim.kbd(new Uint8Array([${ext ? '0xE0,' : ''}0xF0,${code}]))`);
    const t1 = await temps(); while ((await temps()) - t1 < 0.5) await dormir(50);
  };
  await attendre((t) => t.includes('6) BASIC'), 15, 'menu');
  await touche(0x16);
  for (const t0 = await temps(); (await temps()) - t0 < 4;) await dormir(100);   // liste des images
  await touche(0x72, true);
  await touche(0x72, true);
  await touche(0x5A);
  const ok = await attendre((t) => t.includes('Installe sur INT 60h') && /Essais :[\s\S]*C:\\>/.test(t), 60, 'FreeDOS');
  verifier(ok, 'FreeDOS + S02PKT par le Pico dans la page');
  const commande = async (c, fin, s) => {
    const avant = (await ecran()).length;
    await js(`window.simulateur.sim.uart_send(new TextEncoder().encode(${JSON.stringify(c + '\r')}))`);
    await attendre((t) => t.slice(avant).split(c).slice(1).join(c).includes(fin), s, c);
    const r = (await ecran()).slice(avant);
    console.log('> ' + c + '\n' + r.trim().split('\n').slice(0, 12).join('\n'));
    return r;
  };
  let r = await commande('PING 8.8.8.8', 'Replies received', 30);
  verifier(r.includes('received from 8.8.8.8'), 'PING 8.8.8.8');
  r = await commande('HTGET http://www.s02/texte.txt', 'C:\\>', 30);
  verifier(r.includes('Solution-02 + Pico W : OK'), 'HTGET www.s02 (Internet integre)');
  r = await commande(`HTGET http://${SITE}/`, 'C:\\>', 60);
  verifier(/200 OK/.test(r), `HTGET ${SITE} (DNS-over-HTTPS + ${RELAIS ? "relais" : "fetch() de la page"})`);
  await js("document.querySelector('[data-tab=pico]').click()");
  await dormir(800);
  const cap = await cdp('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(CAPTURE, Buffer.from(cap.result.data, 'base64'));
  console.log('capture : ' + CAPTURE);
  console.log('journal du reseau :\n' + (await js("document.getElementById('picoLog').innerText")).split('\n').slice(-12).join('\n'));
} catch (e) {
  console.log('ERREUR ' + e.message);
  echecs++;
}
for (const c of consoles.filter((x) => /error|exception/i.test(x))) console.log('console : ' + c);
ws.close();
nav.kill();
console.log(echecs ? `${echecs} echec(s)` : 'tout est reussi');
process.exit(echecs ? 1 : 0);
