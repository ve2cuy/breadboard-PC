// Disposition physique des composants de Solution-02 sur la carte (millimetres, pas de 2,54).
// Les DIP sont couches, encoche a gauche : broche 1 en bas a gauche, comme sur la platine.

export const BOARD = { w: 300, h: 206 };
const P = 2.54;

// kind, centre (x, y), options
export const PLACE = {
  // horloge et RESET
  Y1:  { kind: 'xtal', x: 22, y: 12 },
  C2:  { kind: 'cap', x: 10, y: 20 },
  C3:  { kind: 'cap', x: 34, y: 20 },
  U11: { kind: 'dip', x: 22, y: 34, row: 7.62 },
  SW1: { kind: 'button', x: 11, y: 56 },
  R1:  { kind: 'axial', x: 26, y: 52, span: 10.16 },
  C1:  { kind: 'ecap', x: 33, y: 60 },
  // processeur
  U1:  { kind: 'dip', x: 72, y: 34, row: 15.24 },
  // verrous et logique
  U2:  { kind: 'dip', x: 124, y: 22, row: 7.62 },
  U3:  { kind: 'dip', x: 124, y: 44, row: 7.62 },
  U5:  { kind: 'dip', x: 153, y: 22, row: 7.62 },
  U9:  { kind: 'dip', x: 153, y: 44, row: 7.62 },
  U8:  { kind: 'dip', x: 180, y: 22, row: 7.62 },
  U14: { kind: 'dip', x: 180, y: 44, row: 7.62 },
  U16: { kind: 'dip', x: 206, y: 44, row: 7.62 },
  BZ1: { kind: 'buzzer', x: 210, y: 18 },
  R8:  { kind: 'axial', x: 230, y: 18, span: 7.62 },
  // memoires
  U4:  { kind: 'dip', x: 62, y: 80, row: 15.24 },
  U6:  { kind: 'dip', x: 116, y: 80, row: 15.24 },
  // interruptions et minuterie
  U13: { kind: 'dip', x: 170, y: 80, row: 15.24 },
  U15: { kind: 'dip', x: 222, y: 80, row: 15.24 },
  // 8255 des DEL
  U7:  { kind: 'dip', x: 62, y: 122, row: 15.24 },
  J1:  { kind: 'header', x: 38, y: 142 },
  J2:  { kind: 'header', x: 64, y: 142 },
  J3:  { kind: 'header', x: 90, y: 142 },
  BAR1: { kind: 'bar', x: 124, y: 116 },
  BAR2: { kind: 'bar', x: 154, y: 116 },
  BAR3: { kind: 'bar', x: 184, y: 116 },
  RN1: { kind: 'sip', x: 124, y: 131 },
  RN2: { kind: 'sip', x: 154, y: 131 },
  RN3: { kind: 'sip', x: 184, y: 131 },
  R5:  { kind: 'axial', x: 124, y: 140, span: 7.62 },
  R6:  { kind: 'axial', x: 154, y: 140, span: 7.62 },
  R7:  { kind: 'axial', x: 184, y: 140, span: 7.62 },
  // 8255 du clavier, de l'UART et de la carte SD
  U12: { kind: 'dip', x: 62, y: 172, row: 15.24 },
  J4:  { kind: 'usb', x: 15, y: 172 },
  R2:  { kind: 'axial', x: 18, y: 193, span: 10.16 },
  R3:  { kind: 'axial', x: 34, y: 193, span: 10.16 },
  J5:  { kind: 'header', x: 104, y: 197 },
  R4:  { kind: 'axial', x: 104, y: 188, span: 10.16 },
  D1:  { kind: 'led', x: 98, y: 156, color: 'g' },
  D2:  { kind: 'led', x: 98, y: 166, color: 'y' },
  R11: { kind: 'axial', x: 110, y: 156, span: 7.62 },
  R12: { kind: 'axial', x: 110, y: 166, span: 7.62 },
  J9:  { kind: 'sdmod', x: 138, y: 168 },
  R9:  { kind: 'axial', x: 126, y: 197, span: 7.62 },
  R10: { kind: 'axial', x: 140, y: 197, span: 7.62 },
  // afficheur
  U10: { kind: 'lcd', x: 246, y: 170 },
  RV1: { kind: 'pot', x: 206, y: 132 },
};

/** Positions (mm) des broches d'un composant, indexees par numero de broche (chaine). */
export function pinPositions(ref, comp) {
  const pl = PLACE[ref];
  const n = comp.pins.filter((p) => /^\d+$/.test(p.n)).length;
  const pos = {};
  if (!pl) return pos;
  const { x, y } = pl;
  switch (pl.kind) {
    case 'dip':
    case 'bar': {
      const half = n / 2;
      const row = pl.kind === 'bar' ? 7.62 : pl.row;
      const x0 = x - ((half - 1) * P) / 2;
      for (let i = 1; i <= n; i++) {
        if (i <= half) pos[i] = [x0 + (i - 1) * P, y + row / 2];
        else pos[i] = [x0 + (n - i) * P, y - row / 2];
      }
      break;
    }
    case 'sip':
    case 'header': {
      const x0 = x - ((n - 1) * P) / 2;
      for (let i = 1; i <= n; i++) pos[i] = [x0 + (i - 1) * P, y];
      break;
    }
    case 'lcd': {
      // connecteur 1x16 en haut a gauche du module (98 x 60 mm)
      const x0 = x - 49 + 8;
      for (let i = 1; i <= 16; i++) pos[i] = [x0 + (i - 1) * P, y - 30 + 2.5];
      break;
    }
    case 'axial': {
      const s = pl.span / 2;
      pos[1] = [x - s, y]; pos[2] = [x + s, y];
      break;
    }
    case 'cap': pos[1] = [x - 1.27, y]; pos[2] = [x + 1.27, y]; break;
    case 'ecap': pos[1] = [x - 1.25, y]; pos[2] = [x + 1.25, y]; break;
    case 'led': pos[1] = [x - 1.27, y]; pos[2] = [x + 1.27, y]; break;
    case 'xtal': pos[1] = [x - 2.44, y]; pos[2] = [x + 2.44, y]; break;
    case 'buzzer': pos[1] = [x - 3.8, y]; pos[2] = [x + 3.8, y]; break;
    case 'button': pos[1] = [x - 3.25, y + 2.25]; pos[2] = [x + 3.25, y + 2.25]; break;
    case 'pot': pos[1] = [x - P, y + 2.5]; pos[2] = [x, y - 2.5]; pos[3] = [x + P, y + 2.5]; break;
    case 'usb': {
      // prise USB-A : contacts 1-4 a l'arriere, blindage SH
      for (let i = 1; i <= 4; i++) pos[i] = [x + 8, y - 3.5 + (i - 1) * 2.5 - 0.25 * 0];
      pos.SH = [x - 2, y + 8];
      break;
    }
    case 'sdmod': {
      // module lecteur micro-SD : connecteur 1x6 a gauche (CS SCK MOSI MISO VCC GND)
      for (let i = 1; i <= 6; i++) pos[i] = [x - 13, y - 6.35 + (i - 1) * P];
      break;
    }
  }
  return pos;
}

/** Rectangle du corps (mm) : [x, y, w, h]. */
export function bodyRect(ref, comp) {
  const pl = PLACE[ref];
  if (!pl) return null;
  const n = comp.pins.filter((p) => /^\d+$/.test(p.n)).length;
  const { x, y } = pl;
  switch (pl.kind) {
    case 'dip': {
      const L = (n / 2) * P + 0.6;
      const H = pl.row - 1.6;
      return [x - L / 2, y - H / 2, L, H];
    }
    case 'bar': return [x - 12.7, y - 5.1, 25.4, 10.2];
    case 'sip': return [x - (n * P) / 2, y - 1.6, n * P, 3.2];
    case 'header': return [x - (n * P) / 2, y - 1.27, n * P, 2.54];
    case 'lcd': return [x - 49, y - 30, 98, 60];
    case 'axial': return [x - pl.span / 2, y - 1.3, pl.span, 2.6];
    case 'cap': return [x - 2.2, y - 1.6, 4.4, 3.2];
    case 'ecap': return [x - 2.6, y - 2.6, 5.2, 5.2];
    case 'led': return [x - 2, y - 2, 4, 4];
    case 'xtal': return [x - 5.6, y - 2.4, 11.2, 4.8];
    case 'buzzer': return [x - 6, y - 6, 12, 12];
    case 'button': return [x - 3.5, y - 3.5, 7, 7];
    case 'pot': return [x - 4.8, y - 4.8, 9.6, 9.6];
    case 'usb': return [x - 7, y - 7.5, 16, 15];
    case 'sdmod': return [x - 15, y - 14, 34, 30];
  }
  return [x - 3, y - 3, 6, 6];
}

/** Noms des broches des portes logiques (les symboles KiCad ne les nomment pas). */
export const GATE_NAMES = {
  '74LS00': ['1A', '1B', '1Y', '2A', '2B', '2Y', 'GND', '3Y', '3A', '3B', '4Y', '4A', '4B', 'VCC'],
  '74LS02': ['1Y', '1A', '1B', '2Y', '2A', '2B', 'GND', '3A', '3B', '3Y', '4A', '4B', '4Y', 'VCC'],
  '74HC14': ['1A', '1Y', '2A', '2Y', '3A', '3Y', 'GND', '4Y', '4A', '5Y', '5A', '6Y', '6A', 'VCC'],
};

/** Fiche technique (PDF local) par reference. */
export const DATASHEET = {
  U1: '8088.pdf', U2: 'SN74HC573A.pdf', U3: 'SN74HC573A.pdf', U4: 'W29C020C.pdf', U5: 'DM74LS00.pdf',
  U6: 'HM628512.pdf', U7: '8255.pdf', U8: 'SN74LS138.pdf', U9: 'SN74LS02.pdf', U10: 'NHD-0420H1Z.pdf',
  U11: '82C84A.pdf', U12: '8255.pdf', U13: '8259A.pdf', U14: 'SN74LS14.pdf', U15: 'uPD8253.pdf',
  U16: 'SN74LS74A.pdf', BAR1: 'HDSP-4830.pdf', BAR2: 'HDSP-4830.pdf', BAR3: 'HDSP-4830.pdf',
};
export const DATASHEET_EXTRA = { U10: 'HD44780.pdf' };

/** Description courte de chaque composant (francais). */
export const ROLE = {
  U1: 'Processeur 8088 (ou NEC V20), mode minimum, 5,333 MHz',
  U2: 'Verrou des adresses A0-A7 (ALE)', U3: 'Verrou des adresses A16-A19 (ALE)',
  U4: 'ROM 256 Ko (W29C020C) : BIOS, BASIC et disquette PC-DOS 2.1, en 80000h-FFFFFh',
  U5: 'NAND : sélection ROM / RAM (A19, IO/M)', U6: 'RAM statique 512 Ko en 00000h-7FFFFh',
  U7: '8255 des DEL (ports 10h-13h, mode 0, 3 ports en sortie)', U8: 'Décodeur des ports d\'E/S 00h-7Fh (A4-A6)',
  U9: 'NOR : E du LCD, horloge du port 61h, sortie du son', U10: 'Afficheur LCD 20x4 (ports 00h-01h)',
  U11: 'Générateur d\'horloge 82C84 (16 MHz / 3) et RESET', U12: '8255 : clavier PS/2, UART logiciel, carte SD (30h-33h)',
  U13: '8259A : interruptions IRQ0 (minuterie), IRQ1 (clavier), IRQ4 (UART) (20h-21h)',
  U14: 'Inverseurs de Schmitt : KBD_CLK -> IRQ1, RX -> IRQ4, RESET', U15: 'Minuterie 8253 (40h-43h), CLK = PCLK 2,667 MHz',
  U16: 'Verrou du port 61h (GATE2, SPK_EN)', BAR1: 'Bargraphe : PC7-PC4', BAR2: 'Bargraphe : PC3-PC0, PA7-PA2',
  BAR3: 'Bargraphe : PA1-PA0, PB7-PB0', J4: 'Prise USB-A du clavier (PS/2)', J5: 'UART TTL 9600 8N1 (TX, RX, GND)',
  J9: 'Lecteur de carte micro-SD (SPI)', SW1: 'Bouton RESET', Y1: 'Quartz 16 MHz', BZ1: 'Piezo passif (son)',
  RV1: 'Contraste du LCD', D1: 'Voyant des disquettes A:/B: de la carte', D2: 'Voyant du disque dur C:',
  J1: 'DEL du port A de U7', J2: 'DEL du port B de U7', J3: 'DEL du port C de U7',
};

import { t } from './i18n.js';
/** Role d'un composant dans la langue de l'interface. */
export function role(ref) { return ROLE[ref] ? t(ROLE[ref]) : ''; }
