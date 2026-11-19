// Langue de l'interface : francais (textes d'origine) ou anglais (dictionnaire EN).
// t('texte francais', a0, a1...) rend la traduction ; {0}, {1}... sont remplaces par les arguments.
// translateTree(racine) traduit les textes et les attributs title/placeholder du DOM statique.

import { EN } from './i18n_en.js';

let lang = 'fr';
try {
  const s = localStorage.getItem('s02-lang');
  lang = s === 'en' || s === 'fr' ? s : (navigator.language || 'fr').toLowerCase().startsWith('fr') ? 'fr' : 'en';
} catch (e) { /* stockage indisponible */ }
const params = new URLSearchParams(location.search);
if (params.get('lang') === 'en' || params.get('lang') === 'fr') lang = params.get('lang');

const listeners = [];
const original = new WeakMap();   // noeud texte -> texte francais
const originalAttr = new WeakMap(); // element -> { attr: texte francais }

export function getLang() { return lang; }

export function t(fr, ...args) {
  let r = lang === 'en' ? (EN[fr] ?? fr) : fr;
  for (let i = 0; i < args.length; i++) r = r.split('{' + i + '}').join(String(args[i]));
  return r;
}

export function onLang(f) { listeners.push(f); }

export function setLang(l) {
  lang = l === 'en' ? 'en' : 'fr';
  try { localStorage.setItem('s02-lang', lang); } catch (e) { /* rien */ }
  document.documentElement.lang = lang;
  translateTree(document.body);
  for (const f of listeners) f(lang);
}

const SKIP = new Set(['SCRIPT', 'STYLE', 'CANVAS', 'SELECT', 'TEXTAREA']);

export function translateTree(root) {
  if (!root) return;
  const walk = (n) => {
    if (n.nodeType === 3) {
      let o = original.get(n);
      if (o === undefined) { o = n.nodeValue; original.set(n, o); }
      const core = o.trim();
      if (!core) return;
      const tr = t(core);
      if (tr !== core || n.nodeValue !== o) n.nodeValue = o.replace(core, tr);
      return;
    }
    if (n.nodeType !== 1 || SKIP.has(n.tagName) || n.hasAttribute('data-no-i18n')) {
      if (n.nodeType === 1 && n.tagName === 'SELECT') translateAttrs(n);
      if (n.nodeType === 1 && n.tagName === 'SELECT') for (const o of n.options) walk(o);
      return;
    }
    translateAttrs(n);
    for (const c of n.childNodes) walk(c);
  };
  walk(root);
}

function translateAttrs(el) {
  let m = originalAttr.get(el);
  for (const a of ['title', 'placeholder', 'aria-label']) {
    if (!el.hasAttribute(a)) continue;
    if (!m) { m = {}; originalAttr.set(el, m); }
    if (m[a] === undefined) m[a] = el.getAttribute(a);
    el.setAttribute(a, t(m[a]));
  }
}

/** Traduit l'etat interne des puces (texte du simulateur en francais) ligne par ligne. */
export function tLines(txt) {
  if (lang !== 'en') return txt;
  return txt.split('\n').map((l) => {
    if (EN[l] !== undefined) return EN[l];
    const i = l.indexOf(' : ');
    if (i < 0) return tWords(l);
    return t(l.slice(0, i)) + ': ' + tWords(l.slice(i + 3));
  }).join('\n');
}
const WORDS = [
  [/\bdiviseur\b/g, 'divisor'], [/\bvaleur\b/g, 'value'], [/\bcurseur :/g, 'cursor:'], [/\bclignotement :/g, 'blink:'],
  [/\bnon chargé\b/g, 'not loaded'], [/\bsortie\b/g, 'output'], [/\bentrée\b/g, 'input'], [/\bmixte\b/g, 'mixed'],
  [/\bhaut\b/g, 'upper'], [/\bbas\b/g, 'lower'], [/\bfront\b/g, 'edge'], [/\bniveau\b/g, 'level'], [/\binsérée\b/g, 'inserted'],
  [/\babsente\b/g, 'absent'], [/\bdébranché\b/g, 'disconnected'], [/\bbranché\b/g, 'connected'], [/\btrue\b/g, 'yes'],
  [/\bfalse\b/g, 'no'], [/EOI auto/g, 'auto EOI'], [/PUCE RETIRÉE/g, 'CHIP REMOVED'],
  // messages des modeles (journal)
  [/\bcommande\b/g, 'command'], [/\bdonnee\b/g, 'data'], [/trop tot/g, 'too early'], [/mot de mode/g, 'mode word'],
  [/modes 1\/2 non simules/g, 'modes 1/2 not simulated'], [/non geree/g, 'not handled'], [/attendu/g, 'expected'],
  [/relecture : 8254 seulement/g, 'read-back: 8254 only'], [/bus de 8 bits cable/g, '8-bit bus wired'],
];
function tWords(v) {
  if (EN[v] !== undefined) return EN[v];
  for (const [re, en] of WORDS) v = v.replace(re, en);
  return v;
}
