// Clavier : codes PS/2 (jeu 2) pour J4, sequences de terminal (comme PuTTY) pour l'UART (J5).

// KeyboardEvent.code -> code de balayage du jeu 2 (prefixe E0 si > 0xFF : 0xE0xx)
export const PS2 = {
  Escape: 0x76, F1: 0x05, F2: 0x06, F3: 0x04, F4: 0x0C, F5: 0x03, F6: 0x0B, F7: 0x83, F8: 0x0A,
  F9: 0x01, F10: 0x09, F11: 0x78, F12: 0x07, ScrollLock: 0x7E,
  Backquote: 0x0E, Digit1: 0x16, Digit2: 0x1E, Digit3: 0x26, Digit4: 0x25, Digit5: 0x2E, Digit6: 0x36,
  Digit7: 0x3D, Digit8: 0x3E, Digit9: 0x46, Digit0: 0x45, Minus: 0x4E, Equal: 0x55, Backspace: 0x66,
  Tab: 0x0D, KeyQ: 0x15, KeyW: 0x1D, KeyE: 0x24, KeyR: 0x2D, KeyT: 0x2C, KeyY: 0x35, KeyU: 0x3C,
  KeyI: 0x43, KeyO: 0x44, KeyP: 0x4D, BracketLeft: 0x54, BracketRight: 0x5B, Backslash: 0x5D,
  CapsLock: 0x58, KeyA: 0x1C, KeyS: 0x1B, KeyD: 0x23, KeyF: 0x2B, KeyG: 0x34, KeyH: 0x33, KeyJ: 0x3B,
  KeyK: 0x42, KeyL: 0x4B, Semicolon: 0x4C, Quote: 0x52, Enter: 0x5A,
  ShiftLeft: 0x12, IntlBackslash: 0x61, KeyZ: 0x1A, KeyX: 0x22, KeyC: 0x21, KeyV: 0x2A, KeyB: 0x32,
  KeyN: 0x31, KeyM: 0x3A, Comma: 0x41, Period: 0x49, Slash: 0x4A, ShiftRight: 0x59,
  ControlLeft: 0x14, AltLeft: 0x11, Space: 0x29, AltRight: 0xE011, ControlRight: 0xE014,
  MetaLeft: 0xE01F, MetaRight: 0xE027, ContextMenu: 0xE02F,
  Insert: 0xE070, Home: 0xE06C, PageUp: 0xE07D, Delete: 0xE071, End: 0xE069, PageDown: 0xE07A,
  ArrowUp: 0xE075, ArrowLeft: 0xE06B, ArrowDown: 0xE072, ArrowRight: 0xE074,
  NumLock: 0x77, NumpadDivide: 0xE04A, NumpadMultiply: 0x7C, NumpadSubtract: 0x7B, NumpadAdd: 0x79,
  NumpadEnter: 0xE05A, NumpadDecimal: 0x71, Numpad0: 0x70, Numpad1: 0x69, Numpad2: 0x72, Numpad3: 0x7A,
  Numpad4: 0x6B, Numpad5: 0x73, Numpad6: 0x74, Numpad7: 0x6C, Numpad8: 0x75, Numpad9: 0x7D,
};

export function ps2Make(code) {
  const c = PS2[code];
  if (c === undefined) return null;
  return c > 0xFF ? [0xE0, c & 0xFF] : [c];
}
export function ps2Break(code) {
  const c = PS2[code];
  if (c === undefined) return null;
  return c > 0xFF ? [0xE0, 0xF0, c & 0xFF] : [0xF0, c];
}

const enc = new TextEncoder();
const ESC = '\x1b';

/** Octets envoyes par un terminal (PuTTY, xterm) pour une touche, ou null. */
export function uartBytes(e) {
  const k = e.key;
  const mod = 1 + (e.shiftKey ? 1 : 0) + (e.altKey ? 2 : 0) + (e.ctrlKey ? 4 : 0);
  const csi = (n, fin) => ESC + '[' + n + (mod > 1 ? ';' + mod : '') + fin;
  const tilde = (n) => ESC + '[' + n + (mod > 1 ? ';' + mod : '') + '~';
  let s = null;
  switch (k) {
    case 'Enter': s = '\r'; break;
    case 'Backspace': s = '\x7f'; break;
    case 'Tab': s = '\t'; break;
    case 'Escape': s = ESC; break;
    case 'ArrowUp': s = mod > 1 ? csi('1', 'A') : ESC + '[A'; break;
    case 'ArrowDown': s = mod > 1 ? csi('1', 'B') : ESC + '[B'; break;
    case 'ArrowRight': s = mod > 1 ? csi('1', 'C') : ESC + '[C'; break;
    case 'ArrowLeft': s = mod > 1 ? csi('1', 'D') : ESC + '[D'; break;
    case 'Home': s = tilde(1); break;
    case 'Insert': s = tilde(2); break;
    case 'Delete': s = tilde(3); break;
    case 'End': s = tilde(4); break;
    case 'PageUp': s = tilde(5); break;
    case 'PageDown': s = tilde(6); break;
    case 'F1': s = tilde(11); break;
    case 'F2': s = tilde(12); break;
    case 'F3': s = tilde(13); break;
    case 'F4': s = tilde(14); break;
    case 'F5': s = tilde(15); break;
    case 'F6': s = tilde(17); break;
    case 'F7': s = tilde(18); break;
    case 'F8': s = tilde(19); break;
    case 'F9': s = tilde(20); break;
    case 'F10': s = tilde(21); break;
    case 'F11': s = tilde(23); break;
    case 'F12': s = tilde(24); break;
    default:
      if (e.ctrlKey && !e.altKey && k.length === 1) {
        const c = k.toUpperCase().charCodeAt(0);
        if (c >= 0x40 && c <= 0x5F) s = String.fromCharCode(c - 0x40);
        else if (k === ' ' || k === '2') s = '\x00';
        else if (k === '6') s = '\x1e';
        else if (k === '-') s = '\x1f';
      } else if (k.length === 1) {
        s = (e.altKey && !e.ctrlKey ? ESC : '') + k;
      } else if (k === 'Dead') return null;
  }
  return s === null ? null : enc.encode(s);
}

/** Texte a envoyer par l'UART (coller) : fins de ligne en CR. */
export function uartText(t) {
  return enc.encode(t.replace(/\r\n?|\n/g, '\r'));
}

// Caracteres ASCII -> sequence PS/2 (pour coller au clavier PS/2, disposition US)
const SHIFTED = { '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
  '_': '-', '+': '=', '{': '[', '}': ']', '|': '\\', ':': ';', '"': "'", '<': ',', '>': '.', '?': '/', '~': '`' };
const BASE = { '-': 'Minus', '=': 'Equal', '[': 'BracketLeft', ']': 'BracketRight', '\\': 'Backslash', ';': 'Semicolon',
  "'": 'Quote', ',': 'Comma', '.': 'Period', '/': 'Slash', '`': 'Backquote', ' ': 'Space', '\n': 'Enter', '\t': 'Tab' };
export function ps2Text(t) {
  const out = [];
  for (const ch of t.replace(/\r\n?/g, '\n')) {
    let shift = false, code = null;
    if (ch >= 'a' && ch <= 'z') code = 'Key' + ch.toUpperCase();
    else if (ch >= 'A' && ch <= 'Z') { code = 'Key' + ch; shift = true; }
    else if (ch >= '0' && ch <= '9') code = 'Digit' + ch;
    else if (SHIFTED[ch]) { shift = true; const b = SHIFTED[ch]; code = b >= '0' && b <= '9' ? 'Digit' + b : BASE[b]; }
    else code = BASE[ch];
    if (!code) continue;
    // un evenement par appui / relachement (le BIOS perd une trame collee a la precedente)
    if (shift) out.push(ps2Make('ShiftLeft'));
    out.push(ps2Make(code), ps2Break(code));
    if (shift) out.push(ps2Break('ShiftLeft'));
  }
  return out;
}
