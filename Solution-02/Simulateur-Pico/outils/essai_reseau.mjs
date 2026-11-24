// Essai de bout en bout du reseau de la page, hors fureteur (Node 22+ : fetch et WebSocket) :
// le meme WebAssembly et le meme pont (www/js/reseau.js) que la page ; FreeDOS + mTCP
// (FDNET_C.IMG) demarre depuis la carte du Pico, puis :
//   - DNS d'un vrai nom par DNS-over-HTTPS ;
//   - HTTP par fetch() (sans relais) ;
//   - avec --relais ws://127.0.0.1:8765 (python outils/relais.py) : vrai TCP.
//
//   node outils/essai_reseau.mjs [--relais ws://127.0.0.1:8765] [--site example.com]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import init, { Sim } from '../www/pkg/s02picosim.js';
import { PontReseau } from '../www/js/reseau.js';

const ICI = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const relais = opt('--relais', '');
const site = opt('--site', 'example.com');

await init({ module_or_path: fs.readFileSync(path.join(ICI, '../www/pkg/s02picosim_bg.wasm')) });
const CLK = Sim.clk_hz();
const rom = fs.readFileSync(path.join(ICI, '../www/roms/solution-02-bios.bin'));
const img = fs.readFileSync(path.join(ICI, '../../../PC-DOS/FDNET_C.IMG'));
const sim = new Sim(rom);
sim.set_atmega(true);
sim.set_pico(true);
sim.net_js(true);
sim.sd_add_file('FDNET.IMG', img);
sim.sd_insert_built();
sim.set_sd_pico(true);
sim.power(true);

const pont = new PontReseau(sim, { log: (k, m) => console.log('   [pont] ' + m), onEtat: (e, t) => console.log('   [relais] ' + e + (t ? ' ' + t : '')) });
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
let ecran = '';
const td = new TextDecoder('latin1');

/** Avance de `s` secondes simulees, a peu pres en temps reel (le reseau est reel). */
async function avancer(s, fin) {
  const pas = 0.02;
  for (let t = 0; t < s; t += pas) {
    sim.run(pas * CLK);
    pont.pump();
    ecran += td.decode(sim.uart_take()).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').replace(/\r/g, '');
    if (fin && ecran.includes(fin)) return true;
    await dormir(10);
  }
  return false;
}

async function touche(code) {
  sim.kbd(new Uint8Array([code])); await avancer(0.4);
  sim.kbd(new Uint8Array([0xF0, code]));
}

async function commande(c, s, fin) {
  ecran = '';
  sim.uart_send(new TextEncoder().encode(c + '\r'));
  const ok = await avancer(s, fin, c);
  await avancer(0.5);
  console.log('> ' + c + '\n' + ecran.trim().split('\n').slice(0, 14).join('\n') + '\n');
  return ok ? ecran : ecran;
}

let echecs = 0;
const verifier = (c, m) => { console.log((c ? 'REUSSI ' : 'ECHEC  ') + m); if (!c) echecs++; };

if (relais) {
  pont.connecter(relais);
  await dormir(1000);
  verifier(pont.relaisOk, 'relais ' + relais);
}

// menu : 1) DOS, C: (FDNET), Entree
await avancer(6);
await touche(0x16);
await avancer(6);
for (let i = 0; i < 2; i++) { sim.kbd(new Uint8Array([0xE0, 0x72])); await avancer(0.4); sim.kbd(new Uint8Array([0xE0, 0xF0, 0x72])); await avancer(0.5); }
ecran = '';
await touche(0x5A);
const demarre = await avancer(40, 'C:\\>', 'Essais :');
verifier(demarre && ecran.includes('Pico W'), 'FreeDOS + S02PKT par le Pico');

let r = await commande('HTGET http://www.s02/texte.txt', 20, 'C:\\>');
verifier(r.includes('Solution-02 + Pico W : OK'), 'www.s02 (Internet integre)');

r = await commande(`HTGET http://${site}/`, 40, 'C:\\>');
verifier(/200 OK|Server return code: 200/.test(r) && /<html|<!doctype/i.test(r), `${site} : DNS-over-HTTPS + ${relais ? 'relais TCP' : 'fetch()'}`);

if (relais) {
  r = await commande('SNTP -set pool.ntp.org', 20, 'C:\\>');
  console.log('(SNTP : UDP 123 sans relais UDP, heure de l\'ordinateur si le pont la fournit)');
}
console.log(JSON.parse(sim.pico_state()));
console.log(echecs ? `${echecs} echec(s)` : 'tout est reussi');
process.exit(echecs ? 1 : 0);
