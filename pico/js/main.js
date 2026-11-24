// Solution-02 — simulateur : programme principal de l'interface.

import init, { Sim } from '../pkg/s02picosim.js';
import { NETLIST } from './netlist.js';
import { LcdView, parseLcd, lcdText } from './lcd.js';
import { BoardView, cleanName } from './board.js';
import { Terminal } from './terminal.js';
import { Scope, DSO_COLORS } from './scope.js';
import { LogicAnalyzer, LA_COLORS, LA_DEPTHS, DECODERS } from './la.js';
import { Debugger } from './debugger.js';
import { ps2Make, ps2Break, uartBytes, uartText, ps2Text } from './keyboard.js';
import { DATASHEET, DATASHEET_EXTRA, DATASHEET_URL, role } from './layout.js';
import { PanneauPico } from './pico.js';
import { t, getLang, setLang, onLang, translateTree, tLines } from './i18n.js';

const $ = (id) => document.getElementById(id);
const CLK = 16e6 / 3;
const SLICE = 20000;                  // cycles par tranche quand des sondes sont posees
const num = (v, d = 2) => v.toLocaleString(getLang() === 'en' ? 'en-CA' : 'fr-CA', { minimumFractionDigits: d, maximumFractionDigits: d });

const S = {
  sim: null, running: true, speed: 1, kbdMode: 'ps2', sound: false, audio: null, audioT: 0,
  sig: null, lcd: null, powered: true, contrast: 0.62, uartQ: [], kbdQ: [], lastUart: 0, lastKbd: 0,
  pressed: new Set(), images: [], userImages: [], romList: [], stats: null, tab: 'term',
  perf: { cyc: 0, t: performance.now(), instr: 0, speed: 0, ips: 0 }, inspect: null, probing: false,
};

// ====================================================================== demarrage
async function main() {
  await init();
  document.documentElement.lang = getLang();
  translateTree(document.body);
  const romList = await fetch('roms/index.json').then((r) => r.json()).catch(() => [{ file: 'solution-02-bios.bin', name: 'BIOS', name_en: 'BIOS' }]);
  S.romList = romList;
  // ROM de la langue de l'interface au premier chargement
  S.romIdx = Math.max(0, romList.findIndex((r) => r.lang === getLang()));
  const rom = new Uint8Array(await fetch('roms/' + romList[S.romIdx].file).then((r) => r.arrayBuffer()));
  S.sim = new Sim(rom);
  S.sim.uart_gap_us(0);
  S.names = Sim.signal_names().split('\n');
  S.sigIdx = new Map(S.names.map((n, i) => [n, i]));

  S.lcdView = new LcdView($('lcdCanvas'));
  S.board = new BoardView($('pcbCanvas'), NETLIST, S.names, {
    onHover: hoverPin, onProbe: (p) => probePin(p), onContext: contextMenu, onComp: (c, e) => contextMenu(null, c, e),
    onReset: (d) => resetButton(d),
  });
  S.term = new Terminal($('term'));
  S.term.bell = () => { $('term').animate([{ boxShadow: 'inset 0 0 0 2px #ffb000' }, { boxShadow: 'none' }], 250); };
  S.scope = new Scope($('scopeCanvas'), {
    setProbes: syncProbes,
    signalNow: (i) => (S.sig ? S.sig[i] & 3 : 0),
    onTb: () => rotateKnobs(),
  });
  S.la = new LogicAnalyzer($('laCanvas'), {
    setProbes: syncProbes, names: S.names, now: () => S.sim.cycles() * 4,
    signalNow: (i) => (S.sig ? S.sig[i] & 3 : 0),
    onState: laState, onResults: laResults,
    onLaneClick: (i, e) => laLaneClick(i, e),
  });
  S.dbg = new Debugger(S.sim, $('tab-dbg'), {
    pause: () => setRunning(false), resume: () => setRunning(true), isRunning: () => S.running,
    refreshAll: () => refreshAll(true),
  });

  buildToolbar();
  buildFrontPanel();
  buildTabs();
  buildScopeUi();
  buildLaUi();
  buildSdPanel();
  buildFaults();
  // montage actuel : ATmega U17 (terminal, module Grove) et Pico W (A1) avec sa carte (J14)
  const fa = document.querySelector('[data-fault="atmega"]');
  if (fa && !fa.checked) { fa.checked = true; S.sim.set_atmega(true); $('f-atmega').classList.add('on'); }
  S.pico = new PanneauPico(S, log);
  S.pico.construire();
  S.pico.appliquer();
  buildIrq();
  buildKeyboard();
  buildSplitter();
  buildDrop();
  onLang(applyLang);
  window.addEventListener('resize', onResize);
  onResize();
  await loadImageIndex();
  await insertDefaultCard();
  log('i', t('Simulateur prêt : {0}. Mise sous tension.', romName(S.romList[S.romIdx])));
  setPower(true);
  // ?onglet=pico (liens du README, captures)
  const ong = new URLSearchParams(location.search).get('onglet');
  if (ong && $('tab-' + ong)) selectTab(ong);
  window.simulateur = S;   // pour la console du navigateur
  requestAnimationFrame(frame);
}

function romName(r) { return getLang() === 'en' ? r.name_en || r.name : r.name; }

// ====================================================================== boucle temps reel
let lastFrame = performance.now();
function frame(now) {
  const dt = Math.min(0.1, (now - lastFrame) / 1000);
  lastFrame = now;
  const sim = S.sim;
  if (S.running && S.powered) {
    let stop = 0;
    // reseau reel en cours (DoH, fetch, relais) : pas plus vite que le temps reel
    const lent = S.pico && S.pico.pont.occupe() && S.speed > 1;
    const vitesse = lent ? 1 : S.speed;
    const budget = vitesse >= 1000 ? Infinity : dt * CLK * vitesse;
    const t0 = performance.now();
    let done = 0;
    // en tranches si des sondes sont posees (les evenements sont recueillis a chaque tranche)
    const slice = S.probing ? SLICE : budget;
    while (stop === 0 && done < budget && performance.now() - t0 < 14) {
      const n = Math.min(slice, budget - done, vitesse >= 1000 ? 250000 : Infinity);
      stop = sim.run(n);
      done += n;
      if (S.probing) dispatchEvents();
    }
    if (stop === 1) {
      setRunning(false);
      selectTab('dbg');
      const r = sim.regs();
      log('w', t("Point d'arrêt atteint en {0}", hex(r[9]) + ':' + hex(r[12])));
    }
  }
  pumpQueues();
  S.pico.image(performance.now());
  pollIrq();
  const tx = sim.uart_take();
  if (tx.length) { S.term.write(tx); flash('ledTx'); }
  dispatchEvents();
  pumpAudio();
  S.sig = sim.signals();
  S.lcd = parseLcd(sim.lcd());
  const tm = performance.now();
  S.lcdView.draw(S.lcd, S.contrast, S.powered, tm);
  const vp = S.pico.voyants(tm, S.powered);
  S.board.draw(S.sig, S.lcd, {
    contrast: S.contrast, powered: S.powered, t: tm, sd: S.sdPresent, sdAct: act('SD_SCK'), spk: S.sound && lvl('SPK') === 1,
    sdSlot: S.sim.sd_pico() ? 'J14' : 'J9', sdActPico: vp.sd,
  });
  updateFrontPanel();
  S.term.render();
  if (S.tab === 'scope') { S.scope.update(); S.scope.draw(); updateScopeUi(); }
  if (S.tab === 'la') S.la.draw();
  if (tm - S.perf.t > 500) slowUpdate(tm);
  requestAnimationFrame(frame);
}

function dispatchEvents() {
  const ev = S.sim.take_events();
  const nowQ = S.sim.cycles() * 4;
  S.scope.ingest(ev, nowQ);
  S.la.ingest(ev, nowQ);
}

function slowUpdate(tm) {
  const sim = S.sim;
  const cyc = sim.cycles(), ins = sim.instructions();
  const dt = (tm - S.perf.t) / 1000;
  S.perf.speed = (cyc - S.perf.cyc) / CLK / dt;
  S.perf.ips = (ins - S.perf.instr) / dt;
  S.perf.cyc = cyc; S.perf.instr = ins; S.perf.t = tm;
  $('roSpeed').textContent = S.powered && S.running ? Math.round(S.perf.speed * 100) + ' %' : '—';
  $('roTime').textContent = num(cyc / CLK, 2) + ' s';
  $('roIps').textContent = S.powered && S.running ? num(S.perf.ips / 1e6, 3) + ' M' : '—';
  $('sbInfo').textContent = S.powered ? t('{0} M instr/s · {1}', num(S.perf.ips / 1e6, 2), S.running ? t('en marche') : t('en pause')) : t('hors tension');
  try { S.stats = JSON.parse(sim.stats()); } catch (e) { S.stats = null; }
  const l = sim.take_log();
  if (l) l.split('\n').forEach((x) => log('w', tLines(x)));
  if (S.tab === 'log') renderStats();
  if (S.tab === 'dbg') S.dbg.refresh(true);
  if (S.tab === 'sd') renderSdFiles();
  S.pico.rafraichir(S.tab === 'pico');
  if (S.inspect) S.inspect();
}

function refreshAll() {
  S.sig = S.sim.signals();
  S.lcd = parseLcd(S.sim.lcd());
  S.dbg.refresh(true);
  const tx = S.sim.uart_take();
  if (tx.length) S.term.write(tx);
}

// ====================================================================== files du clavier et de l'UART
function pumpQueues() {
  const sim = S.sim;
  const now = sim.cycles();
  if (S.uartQ.length && sim.uart_pending() === 0 && now - S.lastUart > CLK * 0.004) {
    sim.uart_send(S.uartQ.shift());
    S.lastUart = now;
    flash('ledRx');
  }
  if (S.kbdQ.length && sim.kbd_pending() === 0 && now - S.lastKbd > CLK * 0.03) {
    sim.kbd(S.kbdQ.shift());
    S.lastKbd = now;
  }
}
function sendKbd(bytes) { if (bytes && bytes.length) S.kbdQ.push(Uint8Array.from(bytes)); }
function sendUart(bytes) { if (bytes && bytes.length) S.uartQ.push(Uint8Array.from(bytes)); }

// ====================================================================== son (piezo BZ1)
function pumpAudio() {
  if (!S.sound || !S.audio) return;
  const a = S.audio;
  const smp = S.sim.audio(a.sampleRate);
  if (!smp.length || S.speed !== 1 || !S.running) return;
  const buf = a.createBuffer(1, smp.length, a.sampleRate);
  buf.copyToChannel(smp, 0);
  const src = a.createBufferSource();
  src.buffer = buf;
  src.connect(a.destination);
  const tt = Math.max(a.currentTime + 0.04, S.audioT);
  if (S.audioT - a.currentTime > 0.3) return;
  src.start(tt);
  S.audioT = tt + buf.duration;
}
function setSound(on) {
  S.sound = on;
  $('btnSound').classList.toggle('off', !on);
  $('btnSound').title = on ? t('Piézo BZ1 : son actif (non câblé sur le montage)') : t('Piézo BZ1 : muet (non câblé sur le montage)');
  if (on && !S.audio) { try { S.audio = new AudioContext(); } catch (e) { S.audio = null; } }
  if (S.audio && on) S.audio.resume();
  S.sim.audio_enable(on);
  S.audioT = 0;
}

// ====================================================================== barre d'outils
function buildToolbar() {
  $('btnPower').onclick = () => setPower(!S.powered);
  const rb = $('btnReset');
  rb.addEventListener('mousedown', () => resetButton(true));
  rb.addEventListener('mouseup', () => resetButton(false));
  rb.addEventListener('mouseleave', () => { if (rb.classList.contains('down')) resetButton(false); });
  $('btnRun').onclick = () => setRunning(!S.running);
  $('btnStep').onclick = () => { S.dbg.step(); selectTab('dbg'); };
  $('selSpeed').onchange = (e) => { S.speed = +e.target.value; S.audioT = 0; };
  $('btnSound').onclick = () => setSound(!S.sound);
  $('btnSnap').onclick = () => { S.sim.snapshot(); $('btnRestore').disabled = false; log('i', t('Instantané mémorisé (t = {0} s).', num(S.sim.cycles() / CLK))); };
  $('btnRestore').onclick = () => { if (S.sim.restore()) { log('i', t("Retour à l'instantané.")); refreshAll(); } };
  $('btnHelp').onclick = showHelp;
  renderRomSelect();
  $('selRom').onchange = async () => {
    S.romIdx = +$('selRom').value;
    const r = S.romList[S.romIdx];
    const rom = new Uint8Array(await fetch('roms/' + r.file).then((x) => x.arrayBuffer()));
    loadRom(rom, romName(r));
  };
  $('btnRomFile').onclick = () => $('fileRom').click();
  $('fileRom').onchange = async (e) => {
    const f = e.target.files[0]; if (!f) return;
    loadRom(new Uint8Array(await f.arrayBuffer()), f.name);
    e.target.value = '';
  };
  const mk = $('menuKeys');
  $('btnKeys').onclick = (e) => { e.stopPropagation(); mk.classList.toggle('open'); };
  document.addEventListener('click', () => { for (const m of document.querySelectorAll('.menu.open')) m.classList.remove('open'); hideCtx(); });
  mk.addEventListener('click', (e) => { const b = e.target.closest('button'); if (!b) return; specialKey(b.dataset.key); mk.classList.remove('open'); });
  $('kbdMode').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) setKbdMode(b.dataset.mode); });
  $('langSel').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) setLang(b.dataset.l); });
  markLang();
}
function renderRomSelect() {
  $('selRom').innerHTML = S.romList.map((r, i) => `<option value="${i}">${esc(romName(r))}</option>`).join('');
  $('selRom').value = S.romIdx;
}
function markLang() { for (const b of $('langSel').children) b.classList.toggle('on', b.dataset.l === getLang()); }

function loadRom(rom, name) {
  if (rom.length !== 262144) log('w', t('ROM de {0} octets (256 Ko attendus) : complétée par FFh.', rom.length));
  S.sim.set_rom(rom);
  log('i', t('ROM gravée dans U4 : {0}. Redémarrage.', name));
  setPower(false); setPower(true);
}

function setPower(on) {
  S.powered = on;
  S.sim.power(on);
  document.body.classList.toggle('off', !on);
  $('btnPower').classList.toggle('on', on);
  $('ledPwr').classList.toggle('on', on);
  S.audioT = 0;
  log('i', on ? t('Mise sous tension (+5 V).') : t('Hors tension.'));
  S.board.staticDirty = true;
}

function resetButton(down) {
  $('btnReset').classList.toggle('down', down);
  S.board.buttonDown = down;
  S.sim.reset_button(down);
  if (down) log('i', t('RESET (SW1) appuyé.'));
}

function setRunning(r) {
  S.running = r;
  $('btnRun').classList.toggle('paused', !r);
  $('runLbl').textContent = r ? t('Pause') : t('Exécuter');
  $('dbgPause').textContent = r ? t('Pause') : t('Continuer');
  if (r) S.sim.set_breakpoints(Uint32Array.from(S.dbg.bps));
  S.dbg.refresh(true);
  S.audioT = 0;
}

function setKbdMode(m) {
  S.kbdMode = m;
  releaseAll();
  for (const b of $('kbdMode').children) b.classList.toggle('on', b.dataset.mode === m);
  document.body.classList.toggle('kbd-uart', m === 'uart');
  $('sbKbd').textContent = m === 'uart' ? t('⌨ UART (terminal J5)') : '⌨ PS/2 (J4)';
  $('termHint').textContent = m === 'uart' ? t('Les touches vont au terminal UART (J5), comme avec PuTTY.') : t('Cliquer dans le terminal pour taper au clavier UART (comme PuTTY).');
}

function specialKey(k) {
  // un evenement (appui ou relachement) par element, envoyes a 30 ms d'intervalle
  const ps = {
    cad: [[0x14], [0x11], [0xE0, 0x71], [0xE0, 0xF0, 0x71], [0xF0, 0x11], [0xF0, 0x14]],
    cai: [[0x14], [0x11], [0xE0, 0x70], [0xE0, 0xF0, 0x70], [0xF0, 0x11], [0xF0, 0x14]],
    f12: [[0x07], [0xF0, 0x07]], ctrlbs: [[0x14], [0x5D], [0xF0, 0x5D], [0xF0, 0x14]],
    ctrlc: [[0x14], [0x21], [0xF0, 0x21], [0xF0, 0x14]], ctrlz: [[0x14], [0x1A], [0xF0, 0x1A], [0xF0, 0x14]],
    esc: [[0x76], [0xF0, 0x76]],
  };
  const ua = { cad: '\x1b[3;7~', cai: '\x1b[2;7~', f12: '\x1b[24~', ctrlbs: '\x1c', ctrlc: '\x03', ctrlz: '\x1a', esc: '\x1b' };
  if (k === 'paste') {
    navigator.clipboard.readText().then((txt) => {
      if (S.kbdMode === 'uart') for (const ch of txt.replace(/\r\n?/g, '\n')) sendUart(uartText(ch));
      else for (const ev of ps2Text(txt)) sendKbd(ev);
      log('i', t('Collé : {0} caractères ({1}).', txt.length, S.kbdMode === 'uart' ? 'UART' : 'PS/2'));
    }).catch(() => log('w', t('Presse-papiers inaccessible.')));
    return;
  }
  if (S.kbdMode === 'uart') sendUart(new TextEncoder().encode(ua[k]));
  else for (const ev of ps[k]) sendKbd(ev);
}

// ====================================================================== clavier de l'ordinateur
function buildKeyboard() {
  const tk = $('touchKbd');
  const typing = (e) => {
    const tg = e.target;
    if (tg === tk) return false;
    return tg && (tg.tagName === 'INPUT' || tg.tagName === 'SELECT' || tg.tagName === 'TEXTAREA');
  };
  window.addEventListener('keydown', (e) => {
    if (typing(e) || $('modal').classList.contains('open')) { if (e.key === 'Escape') closeModal(); return; }
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyK') { setKbdMode(S.kbdMode === 'ps2' ? 'uart' : 'ps2'); e.preventDefault(); return; }
    if (e.ctrlKey && e.shiftKey && e.code === 'KeyP') { setPower(!S.powered); e.preventDefault(); return; }
    if (S.tab === 'dbg' && !S.running && (e.code === 'F10' || e.code === 'F11')) {
      e.preventDefault(); e.code === 'F10' ? S.dbg.step() : S.dbg.stepOver(); return;
    }
    if (!S.powered) return;
    // clavier virtuel (iPad) : les caracteres imprimables arrivent par l'evenement input
    if (e.target === tk && (e.isComposing || e.key === 'Unidentified' || e.key === 'Process'
      || (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey))) return;
    if (S.kbdMode === 'uart') {
      const b = uartBytes(e);
      if (b) { sendUart(b); e.preventDefault(); }
      return;
    }
    const code = keyCode(e);
    const mk = ps2Make(code);
    if (!mk) return;
    e.preventDefault();
    S.pressed.add(code);
    sendKbd(mk);
    flash('ledKbd');
  });
  window.addEventListener('keyup', (e) => {
    const code = keyCode(e);
    if (S.kbdMode !== 'ps2' || !S.pressed.has(code)) return;
    S.pressed.delete(code);
    const br = ps2Break(code);
    if (br) { sendKbd(br); e.preventDefault(); }
  });
  // texte saisi au clavier virtuel : envoye tel quel puis efface du champ invisible
  const flushTouch = () => {
    const txt = tk.value;
    tk.value = '';
    if (!txt || !S.powered) return;
    if (S.kbdMode === 'uart') sendUart(uartText(txt));
    else { for (const ev of ps2Text(txt)) sendKbd(ev); flash('ledKbd'); }
  };
  tk.addEventListener('input', (e) => {
    if (e.isComposing) return;
    flushTouch();
  });
  tk.addEventListener('compositionend', flushTouch);
  tk.addEventListener('focus', () => $('term').classList.toggle('touch-focus', S.kbdMode === 'uart'));
  tk.addEventListener('blur', () => $('term').classList.remove('touch-focus'));
  // un toucher sur le terminal ou l'ecran LCD donne le focus au champ invisible -> clavier virtuel
  let touch = false;
  const openTouchKbd = (mode) => {
    if (!touch) return;
    setKbdMode(mode);
    tk.focus({ preventScroll: true });
    $('term').classList.toggle('touch-focus', mode === 'uart');
  };
  window.addEventListener('pointerdown', (e) => { touch = e.pointerType === 'touch' || e.pointerType === 'pen'; }, true);
  $('term').addEventListener('click', () => openTouchKbd('uart'));
  $('lcdCanvas').addEventListener('click', () => openTouchKbd('ps2'));
  window.addEventListener('blur', releaseAll);
  $('term').addEventListener('mousedown', () => setKbdMode('uart'));
  $('pcbWrap').addEventListener('mousedown', () => { if (S.kbdMode !== 'ps2') setKbdMode('ps2'); });
  $('lcdCanvas').addEventListener('mousedown', () => setKbdMode('ps2'));
}
// e.code est parfois vide avec un clavier virtuel : le deduire de e.key
const KEY_CODE = { Enter: 'Enter', Backspace: 'Backspace', Tab: 'Tab', Escape: 'Escape', ' ': 'Space',
  ArrowUp: 'ArrowUp', ArrowDown: 'ArrowDown', ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight' };
function keyCode(e) { return e.code || KEY_CODE[e.key] || ''; }
function releaseAll() {
  for (const c of S.pressed) { const br = ps2Break(c); if (br) sendKbd(br); }
  S.pressed.clear();
}

// ====================================================================== face avant
function buildFrontPanel() {
  const bars = $('bargraphs');
  S.barPins = [];
  for (const ref of ['BAR1', 'BAR2', 'BAR3']) {
    const comp = S.board.comps.find((c) => c.ref === ref);
    const pins = [];
    let segs = '', bits = '';
    for (let i = 1; i <= 10; i++) {
      const p = comp.pinList.find((q) => q.n === String(i));
      pins.push(p);
      const nc = !p || p.res.kind === 'nc';
      const lbl = nc ? '' : (p.net || '').replace(/^\//, '').replace(/^P/, '');
      segs += `<i class="seg10${nc ? ' nc' : ''}" title="${ref} ${i}${nc ? '' : ' : ' + lbl}"></i>`;
      bits += `<span>${lbl}</span>`;
    }
    S.barPins.push(pins);
    bars.insertAdjacentHTML('beforeend', `<div class="bar"><div class="body">${segs}</div><div class="bits">${bits}</div><div class="blbl">${ref}</div></div>`);
  }
  S.barEls = [...bars.querySelectorAll('.seg10')];
  const rc = $('rngContrast');
  rc.oninput = () => { S.contrast = rc.value / 100; };
  S.contrast = rc.value / 100;
}

const flashes = {};
function flash(id) { flashes[id] = performance.now(); }
function lvl(name) { const i = S.sigIdx.get(name); return i === undefined || !S.sig ? 0 : S.sig[i] & 3; }
function act(name) { const i = S.sigIdx.get(name); return i !== undefined && S.sig && (S.sig[i] & 4) !== 0; }

function updateFrontPanel() {
  const on = S.powered;
  let k = 0;
  for (const pins of S.barPins) for (const p of pins) {
    const el = S.barEls[k++];
    const lit = on && p && p.res.kind === 'sig' && S.board.pinState(p, S.sig).v === 1;
    if (el._lit !== lit) { el._lit = lit; el.classList.toggle('on', lit); }
  }
  const now = performance.now();
  const set = (id, v) => { const e = $(id); if (e._v !== v) { e._v = v; e.classList.toggle('on', v); } };
  set('ledD1', on && lvl('VOY_DISQ') === 1);
  set('ledD2', on && lvl('VOY_HD') === 1);
  set('ledSpk', on && lvl('SPK') === 1);
  set('ledKbd', on && (act('KBD_CLK') || now - (flashes.ledKbd || 0) < 80));
  set('ledTx', on && (act('UART_TX') || now - (flashes.ledTx || 0) < 60));
  set('ledRx', on && (act('UART_RX') || now - (flashes.ledRx || 0) < 60));
  const vp = S.pico.voyants(now, on);
  set('ledSd', on && (act('SD_SCK') || vp.sd));
  set('ledPico', vp.pico);
  set('ledNet', on && !!vp.wifi && !(vp.net && Math.floor(now / 70) % 2 === 1));
  const lbl = S.sim.sd_pico() ? 'J14 SD' : 'J9 SD';
  if ($('ledSdLbl').textContent !== lbl) $('ledSdLbl').textContent = lbl;
}

// ====================================================================== survol, sondes, menus
function hoverPin(p, comp, e) {
  const tip = $('tooltip');
  if (!p && !comp) { tip.style.display = 'none'; $('sbHover').textContent = t('Survoler une broche pour voir son net et son niveau.'); return; }
  const wrap = $('pcbWrap').getBoundingClientRect();
  let html;
  if (p) {
    html = S.board.describe(p, S.sig, S.powered);
    const st = S.powered ? S.board.pinState(p, S.sig).txt : t('hors tension');
    $('sbHover').textContent = `${p.comp.ref}.${p.n} ${cleanName(p.name)} — ${(p.net || '—').replace(/^\//, '')} — ${st}`;
  } else {
    html = `<b>${comp.ref}</b> · ${esc(comp.value || '')}<div class="d">${esc(role(comp.ref) || comp.part || '')}</div><div class="d">${t('Clic : menu (fiche technique, inspecteur…)')}</div>`;
    if (comp.ref === 'U10' && S.lcd) html += `<pre style="margin:4px 0 0;color:#b9d84a">${esc(lcdText(S.lcd))}</pre>`;
    $('sbHover').textContent = `${comp.ref} — ${comp.value} — ${role(comp.ref)}`;
  }
  tip.innerHTML = html;
  tip.style.display = 'block';
  if (e) placeTip(tip, e.clientX - wrap.left, e.clientY - wrap.top, wrap, p ? S.board.netSegments(p.net) : S.board.compRect(comp));
}

/**
 * Place la bulle autour du curseur (cx, cy) a l'endroit qui cache le moins le net mis en
 * evidence : segments de ses pistes (ou rectangle du composant), en pixels de la vue.
 */
function placeTip(tip, cx, cy, wrap, avoid) {
  const w = tip.offsetWidth, h = tip.offsetHeight, g = 18;
  const cands = [[g, g], [g, -h - g], [-w - g, g], [-w - g, -h - g], [-w / 2, g + 10], [-w / 2, -h - g - 10], [g + 30, -h / 2], [-w - g - 30, -h / 2]];
  let best = null;
  for (const [dx, dy] of cands) {
    const x = Math.max(4, Math.min(cx + dx, wrap.width - w - 4));
    const y = Math.max(4, Math.min(cy + dy, wrap.height - h - 4));
    const r = { x0: x - 6, y0: y - 6, x1: x + w + 6, y1: y + h + 6 };
    // le curseur lui-meme ne doit pas etre sous la bulle
    let score = cx >= r.x0 && cx <= r.x1 && cy >= r.y0 && cy <= r.y1 ? 1000 : 0;
    for (const s of avoid) if (segRect(s, r)) score += s[4] || 1;
    if (!best || score < best.score) best = { x, y, score };
    if (score === 0) break;
  }
  tip.style.left = best.x + 'px';
  tip.style.top = best.y + 'px';
}
function segRect([x1, y1, x2, y2], r) {
  const inside = (x, y) => x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1;
  if (inside(x1, y1) || inside(x2, y2)) return true;
  const cross = (ax, ay, bx, by, cx, cy, dx, dy) => {
    const d = (bx - ax) * (dy - cy) - (by - ay) * (dx - cx);
    if (!d) return false;
    const u = ((cx - ax) * (dy - cy) - (cy - ay) * (dx - cx)) / d, v = ((cx - ax) * (by - ay) - (cy - ay) * (bx - ax)) / d;
    return u >= 0 && u <= 1 && v >= 0 && v <= 1;
  };
  return cross(x1, y1, x2, y2, r.x0, r.y0, r.x1, r.y0) || cross(x1, y1, x2, y2, r.x0, r.y1, r.x1, r.y1)
    || cross(x1, y1, x2, y2, r.x0, r.y0, r.x0, r.y1) || cross(x1, y1, x2, y2, r.x1, r.y0, r.x1, r.y1);
}

/** Definition de sonde pour une broche (signal du simulateur ou horloge). */
function chanDef(p) {
  const r = p.res;
  const net = (p.net || '').replace(/^\//, '');
  const pins = (S.board.netPins.get(p.net) || []).map((q) => q.comp.ref + '.' + q.n).slice(0, 6).join(' ');
  if (r.kind === 'sig') {
    const n = S.names[r.i];
    if (n === 'CLK' || n === 'PCLK') return { sig: null, synth: n, name: n, net, pins };
    return { sig: r.i, synth: null, name: n + (r.inv ? ' (inv.)' : ''), net, pins };
  }
  if (r.kind === 'clock') return { sig: null, synth: 'OSC', name: 'OSC 16 MHz', net, pins };
  return null;
}

function probePin(p) {
  const d = chanDef(p);
  if (!d) { log('w', t('{0} : rien à mesurer ({1}).', p.comp.ref + '.' + p.n, S.board.pinState(p, S.sig).txt)); return; }
  if (S.tab === 'la') {
    if (d.sig === null) { log('w', t("L'analyseur logique ne sonde pas les horloges (CLK, PCLK, OSC).")); return; }
    const i = S.la.ch.findIndex((c) => c && c.sig === d.sig);
    if (i >= 0) { S.la.set(i, null); log('i', t('Voie {0} retirée ({1}).', i, d.name)); }
    else {
      const k = S.la.add(d.sig);
      if (k < 0) log('w', t('Les 32 voies sont occupées.')); else log('i', t('Voie {0} de l’analyseur sur {1} ({2}).', k, d.name, p.comp.ref + '.' + p.n));
    }
    renderLaSelects();
    return;
  }
  const i = S.scope.find(d);
  if (i >= 0) { S.scope.remove(i); log('i', t('Sonde retirée de {0}.', d.name)); }
  else {
    const k = S.scope.add(d);
    log('i', t('Sonde CH{0} sur {1} ({2}).', k + 1, d.name, p.comp.ref + '.' + p.n));
  }
  if (S.tab !== 'scope') selectTab('scope');
  renderScopeUi();
}

/** Sondes demandees au simulateur = voies de l'oscilloscope + voies de l'analyseur. */
function syncProbes() {
  const ids = [...new Set([...S.scope.ids(), ...S.la.ids()])];
  S.sim.set_probes(Uint8Array.from(ids));
  S.probing = ids.length > 0;
  S.scope.resetData();
  // reperes sur la carte
  const m = new Map(), first = new Map();
  const mark = (match, label, color) => {
    for (const [net, ps] of S.board.netPins) {
      const r = ps[0].res;
      if (!match(r)) continue;
      m.set(net, { label, color });
      if (!first.has(net)) first.set(net, ps.find((q) => q.comp.ref.startsWith('U')) || ps[0]);
    }
  };
  S.la.ch.forEach((c, i) => { if (c) mark((r) => r.kind === 'sig' && r.i === c.sig, 'D' + i, LA_COLORS[i % 8]); });
  S.scope.ch.forEach((c, i) => {
    if (!c) return;
    mark((r) => (c.sig !== null && r.kind === 'sig' && r.i === c.sig) || (c.synth === 'OSC' && r.kind === 'clock') || (c.synth && r.kind === 'sig' && S.names[r.i] === c.synth), 'CH' + (i + 1), DSO_COLORS[i]);
  });
  S.board.probes = m;
  S.board.probes.firstPin = first;
  if (S.scope) renderScopeUi();
}

function contextMenu(p, comp, e) {
  const cm = $('ctxmenu');
  const items = [];
  if (p) {
    items.push(['hd', `${p.comp.ref}.${p.n} · ${cleanName(p.name)}`]);
    const d = chanDef(p);
    if (d) items.push(['◉', t("Sonder à l'oscilloscope"), () => { const was = S.tab; S.tab = 'scope'; probePin(p); if (was === 'la') selectTab('scope'); }]);
    if (d && d.sig !== null) items.push(['▤', t("Ajouter à l'analyseur logique"), () => { selectTab('la'); probePin(p); }]);
    const fq = FREE_IRQ.find((q) => 'IRQ' + q.n === (p.net || '').replace(/^\//, ''));
    if (fq) items.push(['⚡', t('Déclencher {0} (INT {1})', 'IR' + fq.n, hex2(fq.v)), () => irqTrigger(fq.n)]);
    items.push(['✦', t('Mettre le net en évidence'), () => { S.board.highlight = S.board.highlight === p.net ? null : p.net; }]);
    items.push(['hr']);
  }
  if (comp) {
    items.push(['hd', `${comp.ref} · ${comp.value || ''}`]);
    if (DATASHEET[comp.ref]) items.push(['📄', t('Fiche technique (PDF)'), () => showPdf(DATASHEET[comp.ref], comp.ref)]);
    if (DATASHEET_EXTRA[comp.ref]) items.push(['📄', t('Fiche du contrôleur HD44780'), () => showPdf(DATASHEET_EXTRA[comp.ref], 'HD44780')]);
    if (DATASHEET_URL[comp.ref]) items.push(['📄', t('Fiche technique (en ligne)'), () => window.open(DATASHEET_URL[comp.ref], '_blank', 'noopener')]);
    if (['A1', 'U18', 'U19', 'Q1', 'J15', 'J16', 'RN4'].includes(comp.ref)) items.push(['📡', t('Pico W et réseau…'), () => selectTab('pico')]);
    if (comp.ref === 'J16') items.push(['⚡', $('picoJ16').checked ? t('Retirer le cavalier J16') : t('Poser le cavalier J16'), () => { $('picoJ16').checked = !$('picoJ16').checked; $('picoJ16').onchange({ target: $('picoJ16') }); }]);
    if (comp.ref === 'J14') items.push(['💾', t('Gérer la carte SD…'), () => selectTab('sd')]);
    if (S.sim.chip_info(comp.ref)) items.push(['🔍', t("Inspecter l'état interne"), () => inspect(comp.ref)]);
    const removable = { U13: 'no_pic', U15: 'no_pit', U10: 'no_lcd', U4: 'no_rom' }[comp.ref];
    if (removable) {
      const inp = document.querySelector(`[data-fault="${removable}"]`);
      const out = inp && inp.checked;
      items.push(['⏏', out ? t('Remettre la puce') : t('Retirer la puce du montage'), () => { inp.checked = !out; inp.onchange(); }]);
    }
    if (comp.ref === 'SW1') items.push(['⟲', t('Appuyer sur RESET'), () => { resetButton(true); setTimeout(() => resetButton(false), 150); }]);
    if (comp.ref === 'J12') {
      for (const q of FREE_IRQ) items.push(['⚡', t('Déclencher {0} (INT {1})', 'IR' + q.n, hex2(q.v)), () => irqTrigger(q.n)]);
      items.push(['⚙', t('Interruptions libres…'), () => selectTab('irq')]);
    }
    if (comp.ref === 'J9') items.push(['💾', t('Gérer la carte SD…'), () => selectTab('sd')]);
    if (comp.ref === 'J5') items.push(['⌨', t('Ouvrir le terminal UART'), () => { selectTab('term'); setKbdMode('uart'); $('term').focus(); }]);
    if (comp.ref === 'J4') items.push(['⌨', t('Taper au clavier PS/2'), () => setKbdMode('ps2')]);
    if (comp.ref === 'U1') items.push(['🐞', t('Ouvrir le débogueur'), () => selectTab('dbg')]);
    if (comp.ref === 'BZ1') items.push(['🔊', S.sound ? t('Couper le son') : t('Activer le son'), () => setSound(!S.sound)]);
  }
  if (!items.length) return;
  $('tooltip').style.display = 'none';
  cm.innerHTML = items.map((it, i) => it[0] === 'hd' ? `<div class="hd">${esc(it[1])}</div>` : it[0] === 'hr' ? '<hr>' : `<button data-i="${i}"><i>${it[0]}</i>${esc(it[1])}</button>`).join('');
  cm.onclick = (ev) => { const b = ev.target.closest('button'); if (b) { hideCtx(); items[+b.dataset.i][2](); } };
  cm.classList.add('open');
  const w = cm.offsetWidth, h = cm.offsetHeight;
  cm.style.left = Math.min(e.clientX, innerWidth - w - 6) + 'px';
  cm.style.top = Math.min(e.clientY, innerHeight - h - 6) + 'px';
  e.stopPropagation && e.stopPropagation();
}
function hideCtx() { $('ctxmenu').classList.remove('open'); }

// ====================================================================== fenetres
function openModal(title, html, small, ext) {
  $('modalTitle').textContent = title;
  $('modalBody').innerHTML = html;
  $('modal').querySelector('.modal-box').classList.toggle('small', !!small);
  const a = $('modalExt');
  if (ext) { a.href = ext; a.hidden = false; } else a.hidden = true;
  $('modal').classList.add('open');
}
function closeModal() { $('modal').classList.remove('open'); $('modalBody').innerHTML = ''; S.inspect = null; }
$('modalClose').onclick = closeModal;
$('modal').addEventListener('mousedown', (e) => { if (e.target === $('modal')) closeModal(); });

function showPdf(file, ref) {
  openModal(t('Fiche technique — {0} ({1})', ref, file), `<iframe src="pdf/${encodeURIComponent(file)}" title="${file}"></iframe>`, false, 'pdf/' + encodeURIComponent(file));
}
function inspect(ref) {
  const comp = S.board.comps.find((c) => c.ref === ref);
  openModal(t('Inspecteur — {0}', ref + ' ' + (comp ? comp.value : '')), '<div class="info" id="inspectInfo"></div>', true);
  S.inspect = () => { const el = $('inspectInfo'); if (el) el.textContent = (role(ref) ? role(ref) + '\n\n' : '') + tLines(S.sim.chip_info(ref)); };
  S.inspect();
}

function showHelp() {
  const fr = `<div class="help">
<p>Ce simulateur reproduit <b>Solution-02</b>, l'ordinateur 8088 sur platine d'essai : processeur 8088 à 5,333 MHz (quartz 16 MHz / 3),
512 Ko de RAM, ROM de 256 Ko, LCD 20×4, 30 DEL, clavier PS/2 et UART logiciel sur un 8255, 8259, 8253 et lecteur de carte SD en SPI bit par bit.
Le BIOS de la ROM s'exécute tel quel, au cycle près pour les délais logiciels (UART à 9600 bauds, trames PS/2, délais du LCD).</p>
<h3>Pico W (montage du 23 novembre 2026)</h3>
<p>Cette version ajoute le <b>Raspberry Pi Pico W</b> (A1) sur les ports <b>50h-57h</b>, derrière deux SN74LVC245 (U18, U19), avec READY (Q1),
IRQ3 (J16) et sa carte microSD (J14) ; l'ATmega U17 (terminal à 57600 bauds) est monté aussi. Le <b>BIOS 3.3</b> lit la carte par le Pico et
fait passer le réseau des pilotes S02PKT (DOS) et ttyS1 (ELKS) par lui. Le comportement du Pico est celui de son <b>vrai micrologiciel</b>
(pico/coeur, compilé ici en WebAssembly). Onglet <b>Pico W · Réseau</b> : montage, registres, Internet (DNS-over-HTTPS, HTTP par le navigateur,
relais TCP <code>outils/relais.py</code>).</p>
<h3>Démarrage</h3>
<p><b>ALIM</b> met sous tension (RAM au contenu quelconque, LCD non initialisé). <b>RESET</b> (ou SW1 sur la carte) se maintient appuyé.
Menu du BIOS 2.6 : <kbd>1</kbd> DOS, <kbd>2</kbd> test mémoire, <kbd>3</kbd> animations des DEL, <kbd>4</kbd> Info, <kbd>5</kbd> console UART, <kbd>6</kbd> BASIC, <kbd>7</kbd> animations des DEL ON/OFF.
Deux ROM : BIOS 2.6 français et anglais (sélecteur « ROM U4 »).</p>
<h3>Claviers</h3>
<table>
<tr><td><b>PS/2 (J4)</b></td><td>par défaut ; cliquer sur la carte ou le LCD. Les touches partent en trames PS/2 réelles (jeu 2, 10 kHz) vers PB0/PB1 de U12 et IRQ1.</td></tr>
<tr><td><b>UART (J5)</b></td><td>cliquer dans le terminal. Les touches partent comme avec PuTTY (9600 8N1, UTF-8, séquences ESC [).</td></tr>
<tr><td><kbd>Ctrl</kbd>+<kbd>Maj</kbd>+<kbd>K</kbd></td><td>basculer PS/2 ↔ UART</td></tr>
<tr><td><b>Touches ▾</b></td><td>Ctrl+Alt+Suppr, Ctrl+Alt+Inser (changer A:), F12, Ctrl+\\, coller du texte…</td></tr>
</table>
<h3>Carte</h3>
<table>
<tr><td>Survol</td><td>broche, net, niveau logique (rouge = 1, bleu = 0, jaune = activité, gris = flottant)</td></tr>
<tr><td>Clic sur une broche</td><td>pose (ou retire) une sonde de l'oscilloscope — ou une voie de l'analyseur logique si son onglet est ouvert</td></tr>
<tr><td><kbd>Maj</kbd>+clic</td><td>continuité : met le net et ses pistes en évidence</td></tr>
<tr><td>Clic sur un composant / clic droit</td><td>fiche technique PDF, inspecteur, retirer la puce…</td></tr>
<tr><td>Molette, glisser, double-clic</td><td>zoom, déplacement, tout voir</td></tr>
</table>
<h3>Instruments</h3>
<table>
<tr><td><b>Oscilloscope DSO-804</b></td><td>4 voies : choisir la voie (1-4) puis cliquer sur une broche. RUN/STOP, SINGLE, AUTO, bouton SCALE (base de temps), POS, déclenchement (source, front, mode), curseurs (glisser sur l'écran), mesures, décodage UART et PS/2.</td></tr>
<tr><td><b>Analyseur logique</b></td><td>32 voies, capture déclenchée de 20 µs à 2 s, résolution 47 ns, zoom ; décodeurs bus du 8088, UART, PS/2 et SPI de la carte SD ; tableau des résultats. ⛶ agrandit les instruments.</td></tr>
<tr><td><b>Débogueur</b></td><td>Pause, pas à pas (<kbd>F10</kbd>), par-dessus (<kbd>F11</kbd>), points d'arrêt (clic dans la marge), registres et drapeaux modifiables, mémoire, E/S.</td></tr>
<tr><td><b>Carte SD</b></td><td>composer une carte FAT32 avec des images .IMG (disquettes, disques C:), récupérer les images modifiées par le DOS.</td></tr>
<tr><td><b>Pannes</b></td><td>retirer le 8259 ou la 8253, inverser des fils, couper une ligne d'adresse… comme sur le vrai montage.</td></tr>
</table>
<h3>Vitesse</h3>
<p>« Réelle » = 5,333 MHz comme le montage. Les vitesses lentes permettent de voir l'activité des broches ; « Max » accélère le démarrage du DOS.</p>
</div>`;
  const en = `<div class="help">
<p>This simulator reproduces <b>Solution-02</b>, the 8088 computer on a breadboard: 8088 CPU at 5.333 MHz (16 MHz crystal / 3),
512 KB of RAM, 256 KB ROM, 20×4 LCD, 30 LEDs, PS/2 keyboard and software UART on an 8255, 8259, 8253 and an SD card reader in bit-banged SPI.
The ROM BIOS runs unmodified, cycle-accurate for its software delays (9600 baud UART, PS/2 frames, LCD delays).</p>
<h3>Pico W (board of November 23, 2026)</h3>
<p>This version adds the <b>Raspberry Pi Pico W</b> (A1) on ports <b>50h-57h</b>, behind two SN74LVC245 (U18, U19), with READY (Q1),
IRQ3 (J16) and its microSD card (J14); the ATmega U17 (57600 baud terminal) is fitted too. <b>BIOS 3.3</b> reads the card through the Pico and
routes the network of the S02PKT (DOS) and ttyS1 (ELKS) drivers through it. The Pico behaves as its <b>real firmware</b> does
(pico/coeur, compiled here to WebAssembly). <b>Pico W · Network</b> tab: board options, registers, Internet (DNS-over-HTTPS, HTTP through the
browser, TCP relay <code>outils/relais.py</code>).</p>
<h3>Power-up</h3>
<p><b>PWR</b> powers the board (random RAM content, uninitialized LCD). <b>RESET</b> (or SW1 on the board) can be held down.
BIOS 2.6 menu: <kbd>1</kbd> Load DOS, <kbd>2</kbd> memory test, <kbd>3</kbd> LED Show, <kbd>4</kbd> Info, <kbd>5</kbd> UART console, <kbd>6</kbd> BASIC, <kbd>7</kbd> LED Show ON/OFF.
Two ROMs: BIOS 2.6 English and French (« ROM U4 » selector).</p>
<h3>Keyboards</h3>
<table>
<tr><td><b>PS/2 (J4)</b></td><td>default; click on the board or the LCD. Keys are sent as real PS/2 frames (set 2, 10 kHz) to PB0/PB1 of U12 and IRQ1.</td></tr>
<tr><td><b>UART (J5)</b></td><td>click in the terminal. Keys are sent like PuTTY does (9600 8N1, UTF-8, ESC [ sequences).</td></tr>
<tr><td><kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>K</kbd></td><td>toggle PS/2 ↔ UART</td></tr>
<tr><td><b>Keys ▾</b></td><td>Ctrl+Alt+Del, Ctrl+Alt+Ins (change A:), F12, Ctrl+\\, paste text…</td></tr>
</table>
<h3>Board</h3>
<table>
<tr><td>Hover</td><td>pin, net, logic level (red = 1, blue = 0, yellow = activity, grey = floating)</td></tr>
<tr><td>Click a pin</td><td>attach (or remove) an oscilloscope probe — or a logic analyzer channel when its tab is open</td></tr>
<tr><td><kbd>Shift</kbd>+click</td><td>continuity: highlight the net and its traces</td></tr>
<tr><td>Click a part / right-click</td><td>PDF datasheet, inspector, remove the chip…</td></tr>
<tr><td>Wheel, drag, double-click</td><td>zoom, pan, fit</td></tr>
</table>
<h3>Instruments</h3>
<table>
<tr><td><b>DSO-804 oscilloscope</b></td><td>4 channels: pick the channel (1-4) then click a pin. RUN/STOP, SINGLE, AUTO, SCALE knob (time base), POS, trigger (source, slope, mode), cursors (drag on the screen), measurements, UART and PS/2 decoding.</td></tr>
<tr><td><b>Logic analyzer</b></td><td>32 channels, triggered capture from 20 µs to 2 s, 47 ns resolution, zoom; 8088 bus, UART, PS/2 and SD card SPI decoders; results table. ⛶ widens the instruments.</td></tr>
<tr><td><b>Debugger</b></td><td>Pause, single step (<kbd>F10</kbd>), step over (<kbd>F11</kbd>), breakpoints (click in the margin), editable registers and flags, memory, I/O.</td></tr>
<tr><td><b>SD card</b></td><td>build a FAT32 card with .IMG images (floppies, C: disks), download the images modified by DOS.</td></tr>
<tr><td><b>Faults</b></td><td>remove the 8259 or the 8253, swap wires, cut an address line… as on the real board.</td></tr>
</table>
<h3>Speed</h3>
<p>« Real » = 5.333 MHz like the board. Slow speeds let you watch pin activity; « Max » speeds up DOS boot.</p>
</div>`;
  openModal(t('Aide — simulateur de Solution-02'), getLang() === 'en' ? en : fr, true);
}

// ====================================================================== onglets
function buildTabs() {
  $('tabs').addEventListener('click', (e) => { const b = e.target.closest('button[data-tab]'); if (b) selectTab(b.dataset.tab); });
  $('btnMax').onclick = () => { document.body.classList.toggle('dock-max'); setTimeout(onResize, 0); };
}
function selectTab(tb) {
  S.tab = tb;
  for (const b of $('tabs').querySelectorAll('button[data-tab]')) b.classList.toggle('on', b.dataset.tab === tb);
  for (const p of document.querySelectorAll('.panel')) p.classList.toggle('on', p.id === 'tab-' + tb);
  S.dbg.visible = tb === 'dbg';
  if (tb === 'term') setTimeout(onResize, 0);
  if (tb === 'dbg') S.dbg.refresh(true);
  if (tb === 'log') renderStats();
  if (tb === 'sd') renderSdFiles(true);
  if (tb === 'scope') renderScopeUi();
  if (tb === 'irq') renderIrq();
  if (tb === 'pico') S.pico.rafraichir(true);
}

// ====================================================================== J12 : IRQ libres du 8259
// vecteur = base 08h (ICW2 du BIOS) + n ; broche de J12 = position + 2 (1 = +5V)
const FREE_IRQ = [2, 3, 5, 6, 7].map((n, k) => ({ n, v: 8 + n, pin: k + 2 }));
const hex2 = (v) => v.toString(16).toUpperCase().padStart(2, '0') + 'h';
S.irq = { en: new Set(), count: {} };
function buildIrq() {
  $('irqEoi').onchange = () => S.sim.irq_sim_eoi($('irqEoi').checked);
  S.sim.irq_sim_eoi($('irqEoi').checked);
  $('irqTbl').addEventListener('change', (e) => {
    const c = e.target.closest('input[data-irq]');
    if (!c) return;
    const n = +c.dataset.irq;
    if (c.checked) S.irq.en.add(n); else S.irq.en.delete(n);
    S.sim.irq_enable(n, c.checked);
    irqMsg('i', c.checked ? t('IR{0} activée (démasquée) : INT {1}', n, hex2(8 + n)) : t('IR{0} désactivée (masque du BIOS)', n));
    renderIrq();
  });
  $('irqTbl').addEventListener('click', (e) => { const b = e.target.closest('button[data-trig]'); if (b) irqTrigger(+b.dataset.trig); });
  renderIrq(true);
}
function irqTrigger(n) {
  if (!S.powered) { toast(t('Carte hors tension'), 'w'); return; }
  const st = S.sim.irq_state();
  const masked = st[0] & (1 << n) && !(st[1] & (1 << n));
  if (!S.sim.irq_trigger(n, 100)) { irqMsg('w', t('IR{0} déjà à 1 : attendre la reconnaissance', n)); return; }
  const q = FREE_IRQ.find((x) => x.n === n);
  if (masked) {
    const m = t("IR{0} (J12.{1}) : front envoyé, mais l'entrée est masquée (IMR = {2}) : cocher « Activer »", n, q.pin, hex2(st[0]));
    irqMsg('w', m); toast(m, 'w');
  } else irqMsg('i', t('IR{0} (J12.{1}) : front montant', n, q.pin));
  renderIrq();
}
function pollIrq() {
  const ev = S.sim.take_irq_events();
  for (let i = 0; i < ev.length; i += 3) {
    const n = ev[i + 1], v = ev[i + 2];
    S.irq.count[n] = (S.irq.count[n] || 0) + 1;
    const q = FREE_IRQ.find((x) => x.n === n);
    const m = t('INT {0} Déclenchée', hex2(v)) + ` (IR${n}, J12.${q ? q.pin : '?'})`;
    toast(m, 'ok');
    irqMsg('ok', m);
    log('i', m);
  }
  if (ev.length && S.tab === 'irq') renderIrq();
  if (S.tab === 'irq' && S.powered) {
    const k = S.sim.irq_state().join(',');
    if (k !== S.irq.key) renderIrq();
  }
}
function renderIrq(force) {
  const st = S.sim.irq_state();
  S.irq.key = st.join(',');
  const [imr, frc, isr, irr, ir, ext, init] = st;
  const rows = FREE_IRQ.map((q) => {
    const b = 1 << q.n;
    const en = !!(frc & b);
    let etat;
    if (!init) etat = t('8259 non programmé');
    else if (isr & b) etat = t('en service (ISR)');
    else if (ir & b) etat = (imr & b) && !en ? t('demande masquée') : t('demande (IRR)');
    else etat = (imr & b) && !en ? t('masquée (IMR)') : t('prête');
    return `<tr><td><b>IR${q.n}</b></td><td>J12.${q.pin}</td><td class="mono">${hex2(q.v)}</td>
      <td><input type="checkbox" data-irq="${q.n}" ${en ? 'checked' : ''}></td>
      <td><button class="sbtn" data-trig="${q.n}">${esc(t('Déclencher'))}</button></td>
      <td class="${isr & b ? 'irq-busy' : ir & b ? 'irq-req' : ''}">${esc(etat)}</td><td class="mono">${S.irq.count[q.n] || 0}</td></tr>`;
  }).join('');
  const tb = $('irqTbl').querySelector('tbody');
  if (force || S.irq.rows !== rows) { tb.innerHTML = rows; S.irq.rows = rows; }
}
function irqMsg(kind, msg) {
  const el = $('irqLog');
  const tt = num(S.sim.cycles() / CLK, 3);
  el.insertAdjacentHTML('beforeend', `<div class="${kind}" data-no-i18n><span class="t">[${tt} s]</span> ${esc(msg)}</div>`);
  while (el.childElementCount > 200) el.firstChild.remove();
  el.scrollTop = el.scrollHeight;
}
function toast(msg, kind) {
  const box = $('toasts');
  const el = document.createElement('div');
  el.className = 'toast ' + (kind || '');
  el.textContent = msg;
  box.appendChild(el);
  while (box.childElementCount > 4) box.firstChild.remove();
  setTimeout(() => el.classList.add('out'), 2600);
  setTimeout(() => el.remove(), 3100);
}

// ====================================================================== oscilloscope (commandes)
const SIG_LABEL = (n) => n.replace(/~\{([^}]*)\}/g, '/$1');
function signalOptions(withClocks) {
  return ['<option value="">' + esc(t('Ajouter un signal…')) + '</option>']
    .concat(withClocks ? ['<option value="s:CLK">CLK (5,333 MHz)</option>', '<option value="s:PCLK">PCLK (2,667 MHz)</option>', '<option value="s:OSC">OSC (16 MHz)</option>'] : [])
    .concat(S.names.map((n, i) => (withClocks || (n !== 'CLK' && n !== 'PCLK')) ? `<option value="${i}">${SIG_LABEL(n)}</option>` : '')).join('');
}
function defOf(v) {
  if (v.startsWith('s:')) return { sig: null, synth: v.slice(2), name: v.slice(2), net: v.slice(2), pins: '' };
  const n = S.names[+v];
  if (n === 'CLK' || n === 'PCLK') return { sig: null, synth: n, name: n, net: n, pins: '' };
  return { sig: +v, synth: null, name: n, net: n, pins: '' };
}
function buildScopeUi() {
  const sc = S.scope;
  $('bncs').innerHTML = [0, 1, 2, 3].map((i) => `<div class="bnc" data-ch="${i}" style="--cc:${DSO_COLORS[i]}"><div class="hexa"><div class="jack"></div></div><span class="tri"></span><span class="num">${i + 1}</span><small>—</small></div>`).join('');
  for (const b of document.querySelectorAll('.chb')) b.style.setProperty('--cc', DSO_COLORS[+b.dataset.ch]);
  const pick = (i) => { sc.sel = i; renderScopeUi(); };
  $('bncs').addEventListener('click', (e) => { const b = e.target.closest('.bnc'); if (b) pick(+b.dataset.ch); });
  $('bncs').addEventListener('contextmenu', (e) => { const b = e.target.closest('.bnc'); if (b) { e.preventDefault(); sc.remove(+b.dataset.ch); } });
  document.querySelector('.chans .chs').addEventListener('click', (e) => { const b = e.target.closest('.chb'); if (b) pick(+b.dataset.ch); });
  document.querySelector('.chans .chs').addEventListener('contextmenu', (e) => { const b = e.target.closest('.chb'); if (b) { e.preventDefault(); sc.remove(+b.dataset.ch); } });
  $('scRun').onclick = () => { if (sc.running) sc.running = false; else { sc.mode = sc.mode === 'single' ? 'auto' : sc.mode; sc.arm(); } };
  $('scSingle').onclick = () => { sc.mode = 'single'; sc.arm(); };
  $('scAuto').onclick = () => { sc.autoset(); rotateKnobs(); };
  $('scClear').onclick = () => sc.clear();
  $('scSlope').onclick = () => { sc.trig.edge = { r: 'f', f: 'a', a: 'r' }[sc.trig.edge]; };
  $('scMode').onclick = () => { sc.mode = sc.mode === 'auto' ? 'norm' : 'auto'; sc.arm(); };
  $('scSrc').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) sc.trig.ch = +b.dataset.s; });
  $('scMeasure').onclick = () => { sc.showMeas = !sc.showMeas; };
  $('scCursor').onclick = () => { sc.mA = sc.mB = null; };
  $('scopeCanvas').addEventListener('click', () => {});
  knob($('knTime'), (d) => { sc.setTb(sc.tb + d); rotateKnobs(); });
  knob($('knPos'), (d) => { sc.pos = Math.max(0, Math.min(0.9, sc.pos + d * 0.05)); rotateKnobs(); });
  document.querySelector('.dso-la').onclick = () => selectTab('la');
  $('scAddSel').innerHTML = signalOptions(true);
  $('scAddBtn').onclick = () => { const v = $('scAddSel').value; if (!v) return; sc.add(defOf(v)); $('scAddSel').value = ''; };
  const pm = $('menuPreset');
  $('scPreset').onclick = (e) => { e.stopPropagation(); pm.classList.toggle('open'); };
  pm.addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (!b) return;
    const P = {
      uart: ['UART_TX', 'UART_RX'], ps2: ['KBD_CLK', 'KBD_DATA', 'IRQ1', 'INTR'], bus: ['ALE', '~{RD}', '~{WR}', 'IO/~{M}'],
      sd: ['SD_CS', 'SD_SCK', 'SD_MOSI', 'SD_MISO'], irq: ['IRQ0', 'IRQ1', 'IRQ4', 'INTR'], lcd: ['U10-E', 'A0', 'D0', 'D1'], clk: ['s:CLK', 's:PCLK', 'IRQ0'],
    }[b.dataset.p];
    sc.ch = [null, null, null, null];
    P.forEach((n, i) => sc.add(defOf(n.startsWith('s:') ? n : String(S.sigIdx.get(n))), i));
    sc.trig.ch = 0; sc.sel = 0;
    const tbs = { uart: 13, ps2: 11, bus: 2, sd: 9, irq: 15, lcd: 8, clk: 1 }[b.dataset.p];
    sc.setTb(tbs); rotateKnobs();
    syncProbes();
    pm.classList.remove('open');
  });
  rotateKnobs();
  renderScopeUi();
}
function knob(el, step) {
  el.addEventListener('wheel', (e) => { e.preventDefault(); step(e.deltaY > 0 ? 1 : -1); }, { passive: false });
  el.addEventListener('click', (e) => { const r = el.getBoundingClientRect(); step(e.clientX < r.left + r.width / 2 ? -1 : 1); });
  let y0 = null;
  el.addEventListener('mousedown', (e) => { y0 = e.clientY; });
  window.addEventListener('mousemove', (e) => { if (y0 !== null && Math.abs(e.clientY - y0) > 14) { step(e.clientY > y0 ? 1 : -1); y0 = e.clientY; } });
  window.addEventListener('mouseup', () => { y0 = null; });
}
function rotateKnobs() {
  $('knTime').querySelector('i').style.transform = `rotate(${(S.scope.tb - 10) * 14}deg)`;
  $('knPos').querySelector('i').style.transform = `rotate(${(S.scope.pos - 0.5) * 240}deg)`;
}
function renderScopeUi() {
  const sc = S.scope;
  document.querySelectorAll('.bnc').forEach((b) => {
    const i = +b.dataset.ch, c = sc.ch[i];
    b.classList.toggle('used', !!c); b.classList.toggle('sel', i === sc.sel);
    b.querySelector('small').textContent = c ? SIG_LABEL(c.name) : '—';
    b.title = c ? t('Voie {0} : {1} — clic droit : retirer', i + 1, SIG_LABEL(c.name)) : t('Voie {0} libre — cliquer puis choisir une broche', i + 1);
  });
  document.querySelectorAll('.chb').forEach((b) => { const i = +b.dataset.ch; b.classList.toggle('used', !!sc.ch[i]); b.classList.toggle('sel', i === sc.sel); });
}
function updateScopeUi() {
  const sc = S.scope;
  $('scRun').classList.toggle('stopped', !sc.running);
  $('scSingle').classList.toggle('lit', sc.mode === 'single' && sc.running);
  $('scSlope').textContent = 'Slope ' + { r: '↑', f: '↓', a: '↕' }[sc.trig.edge];
  $('scMode').textContent = sc.mode === 'auto' ? 'Auto' : sc.mode === 'norm' ? 'Normal' : 'Single';
  for (const b of $('scSrc').children) b.classList.toggle('on', +b.dataset.s === sc.trig.ch);
  $('scMeasure').classList.toggle('on', sc.showMeas);
  const html = (sc.meas || []).map(([k, v]) => `<span>${esc(k)} : <b>${v}</b></span>`).join('');
  if ($('scopeMeas')._h !== html) { $('scopeMeas').innerHTML = html; $('scopeMeas')._h = html; }
}

// ====================================================================== analyseur logique (commandes)
const LA_PRESETS = {
  data: ['D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', '~{RD}', '~{WR}', 'IO/~{M}'],
  bus32: ['A0', 'A1', 'A2', 'A3', 'A4', 'A5', 'A6', 'A7', 'A8', 'A9', 'A10', 'A11', 'A12', 'A13', 'A14', 'A15', 'A16', 'A17', 'A18', 'A19',
    'D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'ALE', '~{RD}', '~{WR}', 'IO/~{M}'],
  io: ['KBD_CLK', 'KBD_DATA', 'UART_TX', 'UART_RX', 'SD_CS', 'SD_SCK', 'SD_MOSI', 'SD_MISO', 'VOY_DISQ', 'VOY_HD', 'IRQ0', 'IRQ1', 'IRQ4', 'INTR', '~{INTA}', '~{CS_8255_2}'],
  sd: ['SD_CS', 'SD_SCK', 'SD_MOSI', 'SD_MISO', 'VOY_DISQ', 'VOY_HD', '~{CS_8255_2}', '~{WR}'],
  kbd: ['KBD_CLK', 'KBD_DATA', 'IRQ1', 'UART_TX', 'UART_RX', 'IRQ4', 'INTR', '~{INTA}', '~{CS_8259}'],
  leds: ['PA0', 'PA1', 'PA2', 'PA3', 'PA4', 'PA5', 'PA6', 'PA7', 'PB0', 'PB1', 'PB2', 'PB3', 'PB4', 'PB5', 'PB6', 'PB7', 'PC0', 'PC1', 'PC2', 'PC3', 'PC4', 'PC5', 'PC6', 'PC7', 'IRQ0', '~{CS_8255}'],
  lcd: ['U10-E', 'A0', 'D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6', 'D7', 'U8-O0', '~{WR}'],
};
const LA_TRIG_DEFAULT = { data: '~{WR}', bus32: '~{RD}', io: 'KBD_CLK', sd: 'SD_CS', kbd: 'KBD_CLK', leds: '~{CS_8255}', lcd: 'U10-E' };
function buildLaUi() {
  const la = S.la;
  $('laDepth').innerHTML = LA_DEPTHS.map((d, i) => `<option value="${i}">${d[1]}</option>`).join('');
  $('laDepth').value = la.depth;
  $('laDepth').onchange = (e) => { la.depth = +e.target.value; };
  $('laPos').oninput = (e) => { la.pos = e.target.value / 100; };
  $('laEdge').onchange = (e) => { la.trig.edge = e.target.value; };
  $('laTrig').onchange = (e) => { la.trig.ch = +e.target.value; };
  $('laStart').onclick = () => { la.start(false); };
  $('laCont').onclick = () => { la.start(true); };
  $('laStop').onclick = () => la.stop();
  $('laClear').onclick = () => { la.clear(); renderLaSelects(); };
  const pm = $('menuLaPreset');
  $('laPreset').onclick = (e) => { e.stopPropagation(); pm.classList.toggle('open'); };
  pm.addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (!b) return;
    la.preset(LA_PRESETS[b.dataset.p]);
    la.decs = [];
    for (const [type, cfg] of LA_AUTO_DEC[b.dataset.p] || []) la.addDecoder(type, typeof cfg === 'function' ? cfg(la) : cfg);
    renderLaDecs();
    la.trig.ch = la.ch.findIndex((c) => c && c.name === LA_TRIG_DEFAULT[b.dataset.p]);
    la.trig.edge = b.dataset.p === 'bus32' || b.dataset.p === 'sd' ? 'f' : b.dataset.p === 'io' || b.dataset.p === 'kbd' ? 'f' : 'r';
    if (b.dataset.p === 'bus32') la.depth = 0;
    else if (b.dataset.p === 'data') { la.depth = 1; la.trig.edge = 'f'; }
    else if (b.dataset.p === 'kbd' || b.dataset.p === 'io') la.depth = 6;
    else if (b.dataset.p === 'leds') la.depth = 12;
    else la.depth = 3;
    $('laDepth').value = la.depth; $('laEdge').value = la.trig.edge;
    renderLaSelects();
    pm.classList.remove('open');
  });
  $('laAddSel').innerHTML = signalOptions(false);
  $('laAddBtn').onclick = () => { const v = $('laAddSel').value; if (!v) return; la.add(+v); $('laAddSel').value = ''; renderLaSelects(); };
  $('laDecAdd').innerHTML = `<option value="">${esc(t('Ajouter un décodeur…'))}</option>` + Object.entries(DECODERS).map(([k, d]) => `<option value="${k}">${esc(t(d.label))}</option>`).join('');
  $('laDecAdd').onchange = (e) => {
    const k = e.target.value; if (!k) return;
    const d = la.addDecoder(k);
    S.laEdit = DECODERS[k].params.length ? d.id : null;
    e.target.value = '';
    renderLaDecs();
  };
  $('laDecs').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    const id = +b.closest('[data-id]').dataset.id;
    if (b.dataset.act === 'del') { la.removeDecoder(id); if (S.laEdit === id) S.laEdit = null; }
    if (b.dataset.act === 'cfg') S.laEdit = S.laEdit === id ? null : id;
    renderLaDecs();
  });
  $('laDecs').addEventListener('change', (e) => {
    const row = e.target.closest('[data-id]'); if (!row) return;
    const d = la.decs.find((x) => x.id === +row.dataset.id); if (!d) return;
    if (e.target.dataset.on !== undefined) d.on = e.target.checked;
    else if (e.target.dataset.k) { const v = e.target.value; d.cfg[e.target.dataset.k] = /^-?\d+$/.test(v) ? +v : v; }
    la.decodeAll();
    renderLaDecs();
  });
  renderLaDecs();
  $('laSearch').oninput = laResults;
  $('laResults').onclick = (e) => { const d = e.target.closest('[data-t]'); if (d) la.goTo(+d.dataset.t); };
  $('laCanvas').addEventListener('contextmenu', (e) => {
    e.preventDefault();
    const r = $('laCanvas').getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    const y = (e.clientY - r.top) * dpr;
    const ln = la.layout.find((l) => y >= l.y && y < l.y + l.h);
    if (ln && ln.ch !== undefined) { la.set(ln.ch, null); renderLaSelects(); }
  });
  renderLaSelects();
  laState();
}
/** Decodeurs crees par chaque prereglage (type, configuration ou fonction(la) -> configuration). */
const LA_AUTO_DEC = {
  data: [['ascii', { src: 'names' }]],
  bus32: [['bus8088', {}], ['ascii', { src: 'names' }]],
  io: [['uart', (la) => ({ ch: la.idx(/^UART_TX$/) })], ['uart', (la) => ({ ch: la.idx(/^UART_RX$/) })], ['ps2', {}], ['spi', {}]],
  sd: [['spi', {}]],
  kbd: [['ps2', {}], ['uart', (la) => ({ ch: la.idx(/^UART_TX$/) })], ['uart', (la) => ({ ch: la.idx(/^UART_RX$/) })]],
  lcd: [['ascii', (la) => ({ src: 'names', strobe: la.idx(/^U10-E$/), edge: 'f', strobe2: -1 })]],
};

/** Liste des decodeurs et formulaire de configuration de celui qu'on modifie. */
function renderLaDecs() {
  const la = S.la;
  const chOpts = (sel, opt) => (opt ? `<option value="-1"${sel < 0 ? ' selected' : ''}>—</option>` : '')
    + la.ch.map((c, i) => c ? `<option value="${i}"${i === sel ? ' selected' : ''}>${i} ${esc(SIG_LABEL(c.name))}</option>` : '').join('');
  $('laDecs').innerHTML = la.decs.map((d) => {
    const T = DECODERS[d.type];
    let form = '';
    if (S.laEdit === d.id && T.params.length) {
      form = '<div class="la-cfg">' + T.params.map((p) => {
        const v = d.cfg[p.k];
        let ctl;
        if (p.kind === 'ch' || p.kind === 'chopt') ctl = `<select data-k="${p.k}">${chOpts(v, p.kind === 'chopt')}</select>`;
        else ctl = `<select data-k="${p.k}">${p.opts.map(([ov, ol]) => `<option value="${ov}"${String(ov) === String(v) ? ' selected' : ''}>${esc(t(ol))}</option>`).join('')}</select>`;
        return `<label>${esc(t(p.label))}</label>${ctl}`;
      }).join('') + '</div>';
    }
    return `<div class="la-dec" data-id="${d.id}"><input type="checkbox" data-on ${d.on ? 'checked' : ''}><span class="nm">${esc(la.decName(d))}</span>`
      + (T.params.length ? `<button class="sbtn" data-act="cfg" title="${esc(t('Configurer'))}">⚙</button>` : '')
      + `<button class="sbtn" data-act="del" title="${esc(t('Retirer'))}">✕</button>${form}</div>`;
  }).join('') || `<div class="note">${esc(t('Aucun décodeur.'))}</div>`;
}

function laLaneClick(i) {
  const la = S.la;
  if (la.trig.ch !== i) { la.trig.ch = i; la.trig.edge = 'r'; }
  else if (la.trig.edge === 'r') la.trig.edge = 'f';
  else if (la.trig.edge === 'f') la.trig.edge = 'a';
  else la.trig.ch = -1;
  renderLaSelects();
}
function renderLaSelects() {
  const la = S.la;
  $('laTrig').innerHTML = `<option value="-1">${esc(t('immédiat'))}</option>` + la.ch.map((c, i) => c ? `<option value="${i}">${i} ${SIG_LABEL(c.name)}</option>` : '').join('');
  $('laTrig').value = la.trig.ch;
  $('laEdge').value = la.trig.edge;
  renderLaDecs();
}
function laState() {
  const la = S.la;
  const busy = la.state === 'wait' || la.state === 'run';
  $('laStart').classList.toggle('busy', busy);
  $('laStart').textContent = busy ? (la.state === 'wait' ? t('⏳ Attente…') : t('● Capture…')) : t('▶ Démarrer');
}
function laResults() {
  const q = ($('laSearch').value || '').trim().toUpperCase();
  const all = S.la.results;
  const T = S.la.data ? S.la.data.T : 0;
  const list = q ? all.filter((r) => (r.dec + ' ' + r.txt).toUpperCase().includes(q)) : all;
  $('laCount').textContent = list.length;
  const f = (tq) => { const s = (tq - T) / (CLK * 4); return (s >= 0 ? '+' : '') + (Math.abs(s) >= 1e-3 ? (s * 1e3).toFixed(3) + 'ms' : (s * 1e6).toFixed(1) + 'µs'); };
  $('laResults').innerHTML = list.slice(0, 2000).map((r) => `<div data-t="${r.t}"><span class="tm">${f(r.t)}</span><span class="dc">${esc(r.dec)}</span><span>${esc(r.txt)}</span></div>`).join('');
}

// ====================================================================== carte SD
async function loadImageIndex() {
  try { S.images = await fetch('images/index.json').then((r) => r.json()); } catch (e) { S.images = []; }
  for (const im of S.images) im.data = null;
  S.images.push({ name: 'VIDE360.IMG', desc: 'Disquette 360 Ko vierge (FAT12)', desc_en: 'Blank 360 KB floppy (FAT12)', size: 368640, gen: true, def: true });
  renderAvail();
}
function renderAvail() {
  const all = S.images.concat(S.userImages);
  const d = (im) => (getLang() === 'en' ? im.desc_en || im.desc : im.desc) || '';
  $('sdAvail').innerHTML = all.map((im, i) => `<label title="${esc(im.file || t('fichier local'))}"><input type="checkbox" data-i="${i}" ${im.def ? 'checked' : ''}><span>${esc(im.name)}</span><small>${esc(d(im))}</small><small>${size(im.size)}</small></label>`).join('')
    || `<span class="note">${t('Aucune image (lancer outils/serveur.py pour copier celles de PC-DOS/).')}</span>`;
  $('sdAvail').onchange = (e) => { const i = +e.target.dataset.i; all[i].def = e.target.checked; };
}
function size(n) { return n >= 1048576 ? num(n / 1048576, 1) + (getLang() === 'en' ? ' MB' : ' Mo') : Math.round(n / 1024) + (getLang() === 'en' ? ' KB' : ' Ko'); }

function blank360() {
  const d = new Uint8Array(368640);
  d.set([0xEB, 0x3C, 0x90], 0);
  d.set(new TextEncoder().encode('SOL02SIM'), 3);
  const v = new DataView(d.buffer);
  v.setUint16(11, 512, true); d[13] = 2; v.setUint16(14, 1, true); d[16] = 2; v.setUint16(17, 112, true);
  v.setUint16(19, 720, true); d[21] = 0xFD; v.setUint16(22, 2, true); v.setUint16(24, 9, true); v.setUint16(26, 2, true);
  d[510] = 0x55; d[511] = 0xAA;
  for (const f of [512, 1536]) { d[f] = 0xFD; d[f + 1] = 0xFF; d[f + 2] = 0xFF; }
  return d;
}
async function imageData(im) {
  if (im.data) return im.data;
  if (im.gen) return (im.data = blank360());
  const r = await fetch('images/' + encodeURIComponent(im.file));
  if (!r.ok) throw new Error(im.file);
  return (im.data = new Uint8Array(await r.arrayBuffer()));
}
async function insertCard(list) {
  const sim = S.sim;
  sim.sd_clear_files();
  const names = new Set();
  for (const im of list) {
    try {
      const d = await imageData(im);
      let n = im.name.toUpperCase();
      while (names.has(n)) n = n.replace(/(\d?)\./, (m, k) => (k ? +k + 1 : 2) + '.');
      names.add(n);
      sim.sd_add_file(n, d);
    } catch (e) { log('e', t('Image introuvable : {0}', im.file)); }
  }
  sim.sd_insert_built();
  S.sdPresent = true;
  log('i', t('Carte SD insérée ({0} fichier(s)) : {1}.', list.length, [...names].join(', ')));
  renderSdFiles(true);
}
async function insertDefaultCard() {
  const sel = S.images.filter((i) => i.def);
  if (sel.length) await insertCard(sel);
}
function buildSdPanel() {
  $('sdInsert').onclick = async () => {
    const all = S.images.concat(S.userImages).filter((i) => i.def);
    if (!all.length) { log('w', t('Cocher au moins une image.')); return; }
    $('sdInsert').disabled = true;
    await insertCard(all);
    $('sdInsert').disabled = false;
  };
  $('sdEject').onclick = () => { S.sim.sd_eject(); S.sdPresent = false; log('i', t('Carte SD éjectée.')); renderSdFiles(true); };
  $('sdAddFiles').onclick = () => $('sdFileIn').click();
  $('sdFileIn').onchange = async (e) => { await addUserFiles([...e.target.files]); e.target.value = ''; };
  $('sdRaw').onclick = () => $('sdRawIn').click();
  $('sdRawIn').onchange = async (e) => {
    const f = e.target.files[0]; if (!f) return;
    S.sim.sd_insert_raw(new Uint8Array(await f.arrayBuffer()));
    S.sdPresent = true;
    log('i', t('Image de carte brute insérée : {0}', f.name));
    renderSdFiles(true);
    e.target.value = '';
  };
  $('sdFiles').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-dl]'); if (!b) return;
    const i = +b.dataset.dl;
    download(S.sim.sd_file(i), JSON.parse(S.sim.sd_files())[i].name);
  });
}
async function addUserFiles(files) {
  for (const f of files) {
    const data = new Uint8Array(await f.arrayBuffer());
    const n = f.name.toUpperCase().replace(/[^A-Z0-9_.~-]/g, '');
    const dot = n.lastIndexOf('.');
    let base = dot >= 0 ? n.slice(0, dot) : n;
    const ext = dot >= 0 ? n.slice(dot + 1) : 'IMG';
    base = base.replace(/\./g, '').slice(0, 8) || 'IMAGE';
    S.userImages.push({ name: base + '.' + ext.slice(0, 3), desc: f.name, size: data.length, data, def: true, file: f.name });
  }
  renderAvail();
  log('i', t('{0} image(s) ajoutée(s) à la liste. « Insérer la carte » pour les mettre sur la carte.', files.length));
}
function renderSdFiles(force) {
  const files = JSON.parse(S.sim.sd_files() || '[]');
  const present = S.sim.sd_present();
  const key = JSON.stringify(files) + present + getLang();
  const st = S.sim.sd_stats();
  $('sdState').textContent = present ? t('Insérée · {0} fichier(s) · {1} lectures · {2} écritures', files.length, st[0], st[1]) : t('Aucune carte');
  $('sdState').className = 'badge' + (present ? '' : ' warn');
  $('sdArt').classList.toggle('on', present);
  $('sdArtLbl').textContent = present ? '4 GB FAT32' : t('vide');
  if (!force && key === S.sdKey) return;
  S.sdKey = key;
  $('sdFiles').querySelector('tbody').innerHTML = files.map((f, i) => `<tr><td>${esc(f.name)}</td><td>${size(f.size)}</td><td class="${f.dirty ? 'dirty' : ''}">${f.dirty ? t('modifié') : '—'}</td><td><button class="sbtn" data-dl="${i}" title="${t('Télécharger')}">⭳</button></td></tr>`).join('')
    || '<tr><td colspan="4" style="color:var(--faint)">—</td></tr>';
}
function download(data, name) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([data], { type: 'application/octet-stream' }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}

// ====================================================================== pannes
const FAULTS = [
  ['no_pic', 'check', 'Retirer le 8259 (U13)', 'Le BIOS passe en scrutation : Info affiche « 8259 absent (scrut.) », le clavier perd des touches sous DOS.'],
  ['no_pit', 'check', 'Retirer la minuterie 8253 (U15)', "Plus d'IRQ0 : l'heure du DOS n'avance pas, le LED Show ne tourne qu'au premier plan."],
  ['u7_data_rev', 'check', 'D0-D7 inversés vers U7 (erreur du 13 nov.)', 'Le mot de contrôle 80h arrive comme 01h (commande BSR) : les ports restent en entrée, aucune DEL.'],
  ['kbd_swap', 'check', 'D+ et D- inversés sur J4 (erreur du 14 nov.)', 'Horloge et données du clavier permutées : trames PS/2 illisibles, touches perdues.'],
  ['no_r4', 'check', 'R4 absente (tirage de RX)', 'Avec le terminal débranché (onglet Terminal), RX flotte à 0 : faux bits de départ, clavier très lent.'],
  ['ram_line_cut', 'line', "Ligne d'adresse coupée vers la RAM", 'Le test de RAM du démarrage et le menu 2) nomment la ligne en défaut.'],
  ['ram_bad', 'addr', 'Cellule de RAM défectueuse (lue à 00h)', "Adresse linéaire en hexadécimal, ex. 7B3FF. Le test l'affiche « ERR aaaaa ee/ll »."],
  ['no_lcd', 'check', 'LCD débranché (U10)', "Le BIOS écrit sans vérifier : rien à l'écran, le terminal UART fonctionne toujours."],
  ['no_rom', 'check', 'ROM retirée (U4)', 'Le 8088 lit FFh partout : rien ne démarre.'],
  ['atmega', 'check', 'ATmega328P U17 monté (montage actuel)', "Terminal J5 par l'ATmega (57600 bauds), module Wi-Fi Grove sur J13, esclave SPI du 8088 (SS = PC0, MISO = PB4), IRQ4 = octet reçu. Décoché : UART logiciel du 8088 (PA7, PB2), schéma d'avant le 21 nov. (BIOS 2.6)."],
];
function buildFaults() {
  const el = $('faults');
  el.innerHTML = FAULTS.map(([k, type, title, desc]) => {
    let ctl = '';
    if (type === 'check') ctl = `<input type="checkbox" data-fault="${k}">`;
    if (type === 'line') ctl = `<select data-fault="${k}"><option value="">${t('aucune')}</option>${Array.from({ length: 19 }, (_, i) => `<option value="${i}">A${i}</option>`).join('')}</select>`;
    if (type === 'addr') ctl = `<input class="addr" data-fault="${k}" placeholder="${t('aucune')}">`;
    return `<div class="fault" id="f-${k}"><div class="ctl">${ctl}</div><b>${t(title)}</b><span>${t(desc)}</span></div>`;
  }).join('');
  for (const inp of el.querySelectorAll('[data-fault]')) {
    const k = inp.dataset.fault;
    const apply = () => {
      let v = 0, on = false;
      if (inp.type === 'checkbox') { on = inp.checked; v = on ? 1 : 0; }
      else if (inp.tagName === 'SELECT') { on = inp.value !== ''; v = on ? 1 << +inp.value : 0; }
      else { const h = parseInt(inp.value.replace(/h$/i, ''), 16); on = !isNaN(h); v = on ? h & 0x7FFFF : 0xFFFFFFFF; }
      if (k === 'atmega') S.sim.set_atmega(on);
      else S.sim.set_fault(k, v);
      $('f-' + k).classList.toggle('on', on);
      log(on ? 'w' : 'i', t('Panne « {0} » {1}.', t(FAULTS.find((f) => f[0] === k)[2]), on ? t('activée') : t('retirée')));
      S.board.staticDirty = true;
    };
    inp.onchange = apply;
    if (inp.tagName === 'INPUT' && inp.type !== 'checkbox') inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') apply(); e.stopPropagation(); });
  }
  $('chkTermConn').onchange = (e) => { S.sim.term_connected(e.target.checked); log('i', e.target.checked ? t('Terminal branché sur J5.') : t('Terminal débranché de J5.')); };
  $('btnTermClear').onclick = () => S.term.reset();
  $('btnTermCopy').onclick = () => navigator.clipboard.writeText(S.term.text()).then(() => log('i', t('Texte du terminal copié.')));
  $('btnTermSave').onclick = () => download(new TextEncoder().encode(S.term.text()), 'terminal-solution02.txt');
}

// ====================================================================== journal et statistiques
function log(kind, msg) {
  const tt = S.sim ? num(S.sim.cycles() / CLK, 3) : '0,000';
  const el = $('log');
  if (!el) return;
  el.insertAdjacentHTML('beforeend', `<div class="${kind}" data-no-i18n><span class="t">[${tt} s]</span> ${esc(msg)}</div>`);
  while (el.childElementCount > 400) el.firstChild.remove();
  el.scrollTop = el.scrollHeight;
}
$('logClear').onclick = () => { $('log').innerHTML = ''; };
function renderStats() {
  const s = S.stats; if (!s) return;
  const bitUs = s.tx_bit ? (s.tx_bit / CLK * 1e6) : 0;
  const tiles = [
    ['Instructions', num(s.instr / 1e6, 2) + ' M'], ['Cycles', num(s.cycles / 1e6, 1) + ' M'],
    ['IRQ0 minuterie', s.irq[0]], ['IRQ1 clavier', s.irq[1]], ['IRQ4 UART', s.irq[4]], ['IRQ7 parasites', s.spurious, s.spurious > 0],
    ['Trames PS/2', s.kbd_frames], ['Trames perdues', s.kbd_lost, s.kbd_lost > 0],
    ['Octets TX (J5)', s.tx_bytes], ['Erreurs de trame TX', s.tx_err, s.tx_err > 0],
    ['Bit TX mesuré', bitUs ? num(bitUs, 1) + ' µs' : '—', bitUs && Math.abs(bitUs - 104.17) > 4],
    ['Écritures LCD', s.lcd_w], ['Délais LCD violés', s.lcd_v, s.lcd_v > 0],
    ['Secteurs SD lus', s.sd_r], ['Secteurs SD écrits', s.sd_w],
    ['Lectures E/S', s.io_r], ['Écritures E/S', s.io_w], ['Écritures en ROM', s.rom_w],
    ['Dernière INT', s.last_int >= 0 ? hex(s.last_int, 2) + 'h' : '—'], ['Processeur', s.halted ? 'HLT' : t('actif')],
  ];
  $('stats').innerHTML = tiles.map(([k, v, w]) => `<div class="stat${w ? ' warn' : ''}"><label>${t(k)}</label><span>${v}</span></div>`).join('');
}

// ====================================================================== langue
function applyLang() {
  markLang();
  renderRomSelect();
  setKbdMode(S.kbdMode);
  setRunning(S.running);
  setSound(S.sound);
  buildFaults();
  renderAvail();
  renderSdFiles(true);
  renderStats();
  renderScopeUi();
  renderLaSelects();
  laState();
  laResults();
  $('laDecAdd').innerHTML = `<option value="">${esc(t('Ajouter un décodeur…'))}</option>` + Object.entries(DECODERS).map(([k, d]) => `<option value="${k}">${esc(t(d.label))}</option>`).join('');
  $('scAddSel').innerHTML = signalOptions(true);
  $('laAddSel').innerHTML = signalOptions(false);
  S.la.decodeAll();
  S.board.staticDirty = true;
  if ($('modal').classList.contains('open')) closeModal();
}

// ====================================================================== divers
function buildSplitter() {
  const sp = $('splitter');
  let x0 = 0, w0 = 0;
  const mv = (e) => {
    const w = Math.max(360, Math.min(innerWidth - 420, w0 - (e.clientX - x0)));
    document.documentElement.style.setProperty('--dock-w', w + 'px');
    onResize();
  };
  sp.addEventListener('mousedown', (e) => {
    x0 = e.clientX; w0 = $('dock').getBoundingClientRect().width; sp.classList.add('drag');
    window.addEventListener('mousemove', mv);
    window.addEventListener('mouseup', () => { sp.classList.remove('drag'); window.removeEventListener('mousemove', mv); }, { once: true });
  });
}
function buildDrop() {
  let n = 0;
  window.addEventListener('dragenter', (e) => { e.preventDefault(); n++; document.body.classList.add('dragging'); });
  window.addEventListener('dragleave', () => { if (--n <= 0) { n = 0; document.body.classList.remove('dragging'); } });
  window.addEventListener('dragover', (e) => e.preventDefault());
  window.addEventListener('drop', async (e) => {
    e.preventDefault(); n = 0; document.body.classList.remove('dragging');
    const files = [...e.dataTransfer.files];
    const roms = files.filter((f) => /\.(bin|rom)$/i.test(f.name));
    const imgs = files.filter((f) => !/\.(bin|rom)$/i.test(f.name));
    if (roms.length) loadRom(new Uint8Array(await roms[0].arrayBuffer()), roms[0].name);
    if (imgs.length) { await addUserFiles(imgs); selectTab('sd'); }
  });
}
function onResize() {
  const tw = $('term').clientWidth;
  if (tw) $('term').style.fontSize = Math.max(8, Math.min(13, (tw - 24) / (80 * 0.6))).toFixed(2) + 'px';
  S.lcdView.resize();
  S.board.resize();
}
function hex(v, n = 4) { return (v >>> 0).toString(16).toUpperCase().padStart(n, '0'); }
function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

$('btnFit').onclick = () => S.board.fit();
// panneau du haut (LCD, DEL) : masquer / afficher ; le choix est retenu dans ce navigateur
function setFrontPanel(show) {
  document.body.classList.toggle('no-front', !show);
  $('btnPanel').textContent = show ? '▴' : '▾';
  $('btnPanel').classList.toggle('on', !show);
  try { localStorage.setItem('s02.front', show ? '1' : '0'); } catch (e) { /* stockage indisponible */ }
  setTimeout(() => { if (S.board) { onResize(); S.board.fit(); } }, 0);
}
$('btnPanel').onclick = () => setFrontPanel(document.body.classList.contains('no-front'));
try { if (localStorage.getItem('s02.front') === '0') setFrontPanel(false); } catch (e) { /* stockage indisponible */ }
$('btnZoomIn').onclick = () => S.board.zoom(1.3, S.board.cv.width / 2, S.board.cv.height / 2);
$('btnZoomOut').onclick = () => S.board.zoom(1 / 1.3, S.board.cv.width / 2, S.board.cv.height / 2);
$('chkAir').onchange = (e) => { S.board.showAir = e.target.checked; S.board.staticDirty = true; };
$('chkNames').onchange = (e) => { S.board.showNames = e.target.checked; S.board.staticDirty = true; };

main().catch((e) => {
  console.error(e);
  document.body.insertAdjacentHTML('beforeend', `<div style="position:fixed;inset:auto 20px 40px 20px;padding:14px;background:#3a0d0d;border:1px solid #f55;border-radius:8px;z-index:999">${t('Erreur au démarrage du simulateur')} : ${esc(e.message || e)}<br><small>${t('Servir le dossier www/ par HTTP (outils/serveur.py) : les modules et le WebAssembly ne se chargent pas depuis file://.')}</small></div>`);
});
