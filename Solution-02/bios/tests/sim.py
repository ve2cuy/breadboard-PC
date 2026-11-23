#!/usr/bin/env python3
"""Simulateur du BIOS de Solution-02 (unicorn, mode reel 16 bits).

Materiel modelise (Solution02.kicad_sch) :
  - RAM 512 Ko en 00000h-7FFFFh ;
  - ROM 256 Ko en 80000h-FFFFFh, image presente DEUX fois (A18 non relie a la ROM),
    en lecture seule (une ecriture en ROM arrete la simulation) ;
  - LCD 20x4 (HD44780 / ST7066U) en ecriture seule : port 00h = commande, 01h = donnee.
    Le modele verifie les delais minimaux entre deux ecritures, comptes en
    instructions (une iteration de LOOP = 1 instruction >= 0,8 us jusqu'a 16 MHz).

Usage : python tests/sim.py build/solution-02-bios.bin   (lance tous les scenarios)
"""
import os
import struct
import sys
from unicorn import *
from unicorn.x86_const import *

RAM, ROM_BASE, ROM_LEN = 0x80000, 0x80000, 0x40000
# delais minimaux (instructions ~ microsecondes) apres une ecriture au LCD
D_ORDINAIRE, D_EFFACER, D_FONCTION1, D_DEMARRAGE = 37, 1520, 4100, 40000
ADR_LIGNES = (0x00, 0x40, 0x14, 0x54)


class LCD:
    def __init__(self):
        self.ddram = [0x20] * 0x80
        self.ac = 0
        self.allume = False
        self.ecritures = 0
        self.donnees = 0             # caracteres ecrits (port 1)
        self.dernier = None          # (n instr, delai exige)
        self.erreurs = []
        self.fonction = 0            # nombre de "function set" recus
        self.cgram = [0] * 64        # caracteres programmables (codes 0-7)
        self.en_cg = False           # True apres une commande 40h-7Fh (adresse CGRAM)
        self.acg = 0

    def ecrire(self, port, val, n):
        if self.dernier is not None:
            ecart = n - self.dernier[0]
            if ecart < self.dernier[1]:
                self.erreurs.append("ecriture %02Xh/port %d apres %d instr (< %d)" % (val, port, ecart, self.dernier[1]))
        elif n < D_DEMARRAGE:
            self.erreurs.append("premiere ecriture apres %d instr (< %d)" % (n, D_DEMARRAGE))
        self.ecritures += 1
        exige = D_ORDINAIRE
        if port == 0:
            if val == 0x01:
                self.ddram = [0x20] * 0x80
                self.ac = 0
                self.en_cg = False
                exige = D_EFFACER
            elif val & 0x80:
                self.ac = val & 0x7F
                self.en_cg = False
            elif val & 0x40:
                self.acg = val & 0x3F
                self.en_cg = True
            elif val & 0x20:
                self.fonction += 1
                if self.fonction == 1:
                    exige = D_FONCTION1
                if val & 0x10 == 0:
                    self.erreurs.append("function set %02Xh : mode 4 bits" % val)
            elif val & 0x08:
                self.allume = bool(val & 0x04)
        elif port == 1 and self.en_cg:
            self.cgram[self.acg] = val
            self.acg = (self.acg + 1) & 0x3F
        elif port == 1:
            self.donnees += 1
            self.ddram[self.ac] = val
            self.ac += 1
            if self.ac == 0x28:
                self.ac = 0x40
            elif self.ac == 0x68:
                self.ac = 0x00
        self.dernier = (n, exige)

    def lignes(self):
        return ["".join(chr(c) for c in self.ddram[a:a + 20]) for a in ADR_LIGNES]


class PPI:
    """8255 (U7) en 10h-13h : verifie le mot de controle (mode 0, sorties) avant toute sortie
    et note, pour chacune des 24 DEL, si elle a ete vue allumee et eteinte."""
    def __init__(self):
        self.ctrl = None
        self.ports = [0, 0, 0]
        self.allumees = [0, 0, 0]
        self.eteintes = [0, 0, 0]
        self.sorties = 0
        self.erreurs = []

    def ecrire(self, port, val):
        if port == 0x13:
            if not val & 0x80:                 # BSR : un bit de PC (voyant de la carte SD, PC7)
                if self.ctrl != 0x80:
                    self.erreurs.append("BSR %02Xh avant le mot de controle" % val)
                bit = (val >> 1) & 7
                self.ports[2] = (self.ports[2] & ~(1 << bit)) | ((val & 1) << bit)
                self.bsr = getattr(self, 'bsr', 0) + 1
                return
            self.ctrl = val
            if val != 0x80:
                self.erreurs.append("mot de controle %02Xh (80h attendu)" % val)
            return
        if self.ctrl != 0x80:
            self.erreurs.append("sortie en %02Xh avant le mot de controle" % port)
        i = port - 0x10
        self.ports[i] = val
        self.allumees[i] |= val
        self.eteintes[i] |= ~val & 0xFF
        self.sorties += 1

    def toutes_vues(self):
        return self.allumees == [0xFF] * 3 and self.eteintes == [0xFF] * 3


class CarteSD:
    """Carte SDHC sur le SPI de U12 : PC4 = CS, PC5 = SCK, PC6 = MOSI, PB3 = MISO (mode 0 :
    la carte lit MOSI au front montant, change MISO au front descendant). Commandes CMD0, 8,
    9, 16, 17, 24, 55, 58 et ACMD41 (prete au 3e essai). `secteurs` : {lba: 512 octets}
    (creux) ; `presente=False` : MISO reste a 1 (tirage R9)."""
    def __init__(self, secteurs=None, nb=131072, presente=True):
        self.s = secteurs if secteurs is not None else {}
        self.nb, self.presente = nb, presente
        self.cs, self.sck = 1, 0
        self.k, self.entree, self.cour = 8, 0, 0xFF
        self.sortie, self.cmd = [], []
        self.idle, self.app, self.essais41 = True, False, 0
        self.ecr = None
        self.commandes = []                   # (n de commande, argument)
        self.ecrits = []                      # secteurs ecrits

    def port_c(self, v):
        cs, sck, mosi = (v >> 4) & 1, (v >> 5) & 1, (v >> 6) & 1
        if cs != self.cs:
            self.k = 8
        if not cs and sck and not self.sck and self.presente:
            if self.k == 8:                   # debut d'un octet : la carte presente le suivant
                self.k = 0
                self.cour = self.sortie.pop(0) if self.sortie else 0xFF
            self.entree = ((self.entree << 1) | mosi) & 0xFF
            self.k += 1
            if self.k == 8:
                self._octet(self.entree)
        self.cs, self.sck = cs, sck

    def miso(self):
        if self.cs or not self.presente:
            return 1
        i = self.k - 1 if self.sck else self.k
        return (self.cour >> (7 - i)) & 1 if 0 <= i < 8 else 1

    def _octet(self, b):
        if self.ecr is not None:
            e = self.ecr
            if e['etat'] == 'jeton':
                if b == 0xFE:
                    e['etat'] = 'donnees'
            elif e['etat'] == 'donnees':
                e['d'].append(b)
                if len(e['d']) == 514:        # 512 + CRC
                    self.s[e['lba']] = bytes(e['d'][:512])
                    self.ecrits.append(e['lba'])
                    self.ecr = None
                    self.sortie = [0x05, 0x00, 0x00, 0x00]
            return
        if not self.cmd and (b & 0xC0) != 0x40:
            return
        self.cmd.append(b)
        if len(self.cmd) < 6:
            return
        c, arg = self.cmd[0] & 0x3F, int.from_bytes(bytes(self.cmd[1:5]), 'big')
        self.cmd = []
        self.commandes.append((c, arg))
        r1 = 0x01 if self.idle else 0x00
        app, self.app = self.app, False
        if c == 0:
            self.idle, self.essais41 = True, 0
            rep = [0x01]
        elif c == 8:
            rep = [r1, 0x00, 0x00, 0x01, arg & 0xFF]
        elif c == 55:
            self.app = True
            rep = [r1]
        elif c == 41 and app:
            self.essais41 += 1
            if self.essais41 >= 3:
                self.idle = False
            rep = [0x01 if self.idle else 0x00]
        elif c == 58:
            rep = [r1, 0xC0, 0xFF, 0x80, 0x00]
        elif c == 9:
            csize = self.nb // 1024 - 1
            csd = bytearray(16)
            csd[0] = 0x40
            csd[7], csd[8], csd[9] = (csize >> 16) & 0x3F, (csize >> 8) & 0xFF, csize & 0xFF
            rep = [0x00, 0xFF, 0xFE] + list(csd) + [0xFF, 0xFF]
        elif c == 16:
            rep = [r1]
        elif c == 17:
            if arg >= self.nb:
                rep = [0x20]
            else:
                rep = [0x00, 0xFF, 0xFF, 0xFE] + list(self.s.get(arg, bytes(512))) + [0xFF, 0xFF]
        elif c == 24:
            rep = [0x00]
            self.ecr = {'lba': arg, 'etat': 'jeton', 'd': []}
        else:
            rep = [r1 | 0x04]
        self.sortie = [0xFF] + rep


class PPI2:
    """2e 8255 (U12) en 30h-33h : clavier PS/2 sur PB0 (horloge) / PB1 (donnees), UART logiciel
    TX = PA7 / RX = PB2, blocage du clavier par PC0 (diode de KBD_CLK vers PC0, si `diode`).
    - Sortie : chaque ecriture de PA est un bit de la trame serie (depart, 8 donnees, arret) ;
      les octets emis sont decodes dans self.tx, la duree d'un bit (en instructions) est mesuree.
    - Clavier et UART : comme les vrais, une trame part a son heure (le temps avance a chaque
      instruction), que le BIOS ecoute ou non. Une trame PS/2 pendant laquelle le BIOS n'a pas
      lu PB est comptee perdue. Si `diode`, PC0 = 0 bloque l'horloge : le clavier attend (au
      moins T_LIBRE apres le relachement) ; une trame bloquee avant son 10e bit est
      interrompue et renvoyee.
    - niveaux(n) donne les lignes vues par le 74HC14 (U14) : IR1 = KBD_CLK inversee,
      IR4 = UART_RX inversee (bits du 8259)."""
    P_PS2 = 30                                # demi-periode de l'horloge PS/2 (instructions)
    T_LIBRE = 50                              # delai du clavier apres le relachement
    BIT_UART = 36                             # duree d'un bit recu si TX n'a rien mesure

    def __init__(self, diode=False):
        self.ctrl = None
        self.erreurs = []
        self.tx = bytearray()
        self.etat_tx = None                   # None = repos ; sinon liste des bits recus
        self.dernier_tx = None
        self.periodes = []
        self.attente = []                     # (heure, 'ps2'|'uart', octet)
        self.trame = None                     # (debut, 'ps2'|'uart', bits, octet)
        self.lues = 0                         # lectures de PB pendant la trame en cours
        self.lectures = 0
        self.diode = diode
        self.pc0 = 1
        self.libre_depuis = 0
        self.perdues = 0                      # trames PS/2 passees sans etre lues
        self.interrompues = 0
        self.trames = 0
        self.fin_ps2 = 0                      # fin de la derniere trame PS/2 (une a la fois)
        self.sd = None                        # CarteSD sur PC4-PC6 / PB3
        self.pc = 0

    def bit_uart(self):
        p = sorted(self.periodes)
        return p[len(p) // 2] if p else self.BIT_UART

    def bloque(self):
        return self.diode and self.pc0 == 0

    def _pc0(self, v, n):
        if v == self.pc0:
            return
        self.pc0 = v
        if v:
            self.libre_depuis = n
        elif self.diode and self.trame and self.trame[1] == 'ps2':
            debut, genre, bits, octet = self.trame
            if (n - debut) // (2 * self.P_PS2) < 10:      # interrompue : sera renvoyee
                self.trame = None
                self.interrompues += 1
                self.attente.insert(0, (n, 'ps2', octet))

    def ecrire(self, port, val, n):
        if port == 0x33:
            if val & 0x80:
                self.ctrl = val
                if val != 0x82:
                    self.erreurs.append("mot de controle de U12 %02Xh (82h attendu)" % val)
                self._pc0(0, n)                # le mot de mode remet les sorties a 0
                self.pc = 0
            else:                              # BSR : un bit de PC
                bit = (val >> 1) & 7
                self.pc = (self.pc & ~(1 << bit)) | ((val & 1) << bit)
                if bit == 0:
                    self._pc0(val & 1, n)
            if self.sd is not None:
                self.sd.port_c(self.pc)
            return
        if self.ctrl != 0x82:
            self.erreurs.append("sortie en %02Xh avant le mot de controle de U12" % port)
        if port == 0x32:
            self.pc = val
            if self.sd is not None:
                self.sd.port_c(val)
            self._pc0(val & 1, n)
            return
        if port != 0x30:
            return
        b = val >> 7
        if self.dernier_tx is not None and self.etat_tx is not None:
            self.periodes.append(n - self.dernier_tx)
        self.dernier_tx = n
        if self.etat_tx is None:
            if b == 0:
                self.etat_tx = []              # bit de depart
        elif len(self.etat_tx) < 8:
            self.etat_tx.append(b)
        else:
            if b != 1:
                self.erreurs.append("UART TX : bit d'arret a 0")
            self.tx.append(sum(v << i for i, v in enumerate(self.etat_tx)))
            self.etat_tx = None

    def programmer(self, heure, genre, octet):
        self.attente.append((heure, genre, octet))
        self.attente.sort(key=lambda e: e[0])

    def _fin_trame(self):
        if self.trame[1] == 'ps2':
            self.fin_ps2 = self.trame[0] + len(self.trame[2]) * 2 * self.P_PS2
            self.trames += 1
            if not self.lues:
                self.perdues += 1
        self.trame = None

    def _suivante(self, n):
        """Demarre la prochaine trame si son heure est venue (au besoin dans le passe)."""
        while self.trame is None and self.attente and self.attente[0][0] <= n:
            heure, genre, octet = self.attente[0]
            if genre == 'uart':
                bits = [0] + [(octet >> i) & 1 for i in range(8)] + [1]
                debut = heure
                duree = len(bits) * self.bit_uart()
            else:
                if self.bloque():
                    return
                debut = max(heure, self.libre_depuis + self.T_LIBRE, self.fin_ps2 + self.T_LIBRE)
                if debut > n:
                    return
                bits = [0] + [(octet >> i) & 1 for i in range(8)]
                bits += [1 - (sum(bits) & 1), 1]               # parite impaire, arret
                duree = len(bits) * 2 * self.P_PS2
            self.attente.pop(0)
            self.lues = 0
            if n - debut >= duree:                         # passee sans etre lue
                if genre == 'ps2':
                    self.trames += 1
                    self.perdues += 1
                    self.fin_ps2 = debut + duree
                continue
            self.trame = (debut, genre, bits, octet)

    def _lignes(self, n):
        """(clk, data, rx) a l'instant n."""
        clk = data = rx = 1
        if self.trame is None and not (self.attente and self.attente[0][0] <= n):
            return (0 if self.bloque() else 1), 1, 1
        for _ in range(2):
            self._suivante(n)
            if not self.trame:
                break
            debut, genre, bits, octet = self.trame
            t = n - debut
            if genre == 'ps2':
                i, phase = divmod(t, 2 * self.P_PS2)
                if i >= len(bits):
                    self._fin_trame()          # finie : la suivante peut deja avoir commence
                    continue
                data = bits[i]
                clk = 1 if phase < self.P_PS2 else 0
            else:
                i = t // self.bit_uart()
                if i >= len(bits):
                    self._fin_trame()
                    continue
                rx = bits[i]
            break
        if self.bloque():
            clk = 0
        return clk, data, rx

    def niveaux(self, n):
        """Bits IR du 8259 : IR1 = KBD_CLK inversee, IR4 = UART_RX inversee (U14)."""
        clk, data, rx = self._lignes(n)
        return ((1 - clk) << 1) | ((1 - rx) << 4)

    def lire(self, port, n):
        if port != 0x31:
            return 0xFF
        self.lectures += 1
        clk, data, rx = self._lignes(n)
        if self.trame and self.trame[1] == 'ps2':
            self.lues += 1
        miso = self.sd.miso() if self.sd is not None else 1
        return 0xF0 | (miso << 3) | (rx << 2) | (data << 1) | clk


class PIC:
    """8259A (U13) en 20h-21h : ICW1-ICW4, masque (OCW1), EOI (OCW2), lecture de IRR / ISR
    (OCW3). Mode front : une demande est memorisee au front montant de IR, mais n'est valable
    que si IR est encore haute ; INT, une fois levee, reste haute jusqu'a INTA ; si plus
    aucune demande n'est valable a INTA, le 8259 donne le vecteur de IR7 (IRQ7 parasite)."""
    def __init__(self):
        self.init = False
        self.etape = 0
        self.icw4 = False
        self.base = 0
        self.imr = 0xFF
        self.isr = 0
        self.verrou = 0
        self.niv = 0
        self.int_haut = False
        self.lire_isr = False
        self.erreurs = []
        self.servies = {}
        self.parasites = 0
        self.eoi = 0

    def ecrire(self, port, val):
        if port & 1 == 0:
            if val & 0x10:                                  # ICW1
                self.etape, self.icw4, self.init = 1, bool(val & 1), False
                self.imr = self.isr = self.verrou = 0
                self.int_haut = False
                if val & 0x08:
                    self.erreurs.append("ICW1 %02Xh : mode niveau (front attendu)" % val)
                if not val & 0x02:
                    self.erreurs.append("ICW1 %02Xh : cascade (8259 unique attendu)" % val)
            elif val & 0x08:                                # OCW3
                if val & 0x02:
                    self.lire_isr = bool(val & 1)
            else:                                           # OCW2
                self.eoi += 1
                if val & 0xE0 == 0x20 and self.isr:         # EOI non specifique
                    self.isr &= self.isr - 1
                elif val & 0xE0 == 0x60:                    # EOI specifique
                    self.isr &= ~(1 << (val & 7))
        else:
            if self.etape == 1:                             # ICW2
                self.base = val & 0xF8
                self.etape = 2 if self.icw4 else 0
                self.init = not self.icw4
            elif self.etape == 2:                           # ICW4
                self.etape, self.init = 0, True
                if not val & 1:
                    self.erreurs.append("ICW4 %02Xh : mode 8080 (8086 attendu)" % val)
            else:
                self.imr = val                              # OCW1

    def lire(self, port):
        if port & 1:
            return self.imr
        return self.isr if self.lire_isr else (self.verrou & self.niv)

    def entrees(self, niv):
        self.verrou |= niv & ~self.niv
        self.niv = niv
        if self.demande() is not None:
            self.int_haut = True

    def demande(self):
        if not self.init:
            return None
        req = self.verrou & self.niv & ~self.imr & 0xFF
        if not req:
            return None
        irq = (req & -req).bit_length() - 1
        if self.isr and (self.isr & -self.isr).bit_length() - 1 <= irq:
            return None                                     # une plus prioritaire est servie
        return irq

    def inta(self):
        self.int_haut = False
        irq = self.demande()
        if irq is None:
            self.parasites += 1
            return self.base + 7
        self.isr |= 1 << irq
        self.verrou &= ~(1 << irq)
        self.servies[irq] = self.servies.get(irq, 0) + 1
        return self.base + irq


class PIT:
    """8253-2 (U15) en 40h-43h, CLK0-2 = PCLK. PAR_INSTR periodes de PCLK par instruction
    (~15 cycles du 8088 = ~7,5 PCLK). Compteur 0 (mode 36h attendu) : lecture verrouillee
    (mot 00h) ; OUT0 en onde carree (mode 3) -> IR0 du 8259. Compteur 2 (mode B6h attendu) :
    les diviseurs programmes sont notes dans self.notes (son)."""
    PAR_INSTR = 8

    def __init__(self):
        self.diviseur = None
        self.debut = 0
        self.etape = None
        self.lsb = 0
        self.lecture = []
        self.erreurs = []
        self.compteur = 0
        self.notes = []

    def _t(self, n):
        return ((n - self.debut) * self.PAR_INSTR) % self.diviseur

    def ecrire(self, port, val, n):
        if port & 3 == 3:
            if val >> 6 == 0 and (val >> 4) & 3 == 0:              # verrouillage du compteur 0
                c = (self.diviseur - self._t(n)) if self.diviseur else 0
                self.lecture = [c & 0xFF, (c >> 8) & 0xFF]
            elif val >> 6 in (0, 2):
                attendu = 0x36 if val >> 6 == 0 else 0xB6
                if val != attendu:
                    self.erreurs.append("8253 : mot de mode %02Xh (%02Xh attendu)" % (val, attendu))
                self.compteur, self.etape = val >> 6, 'lsb'
            else:
                self.erreurs.append("8253 : mot de mode %02Xh (compteur 1 ou relecture)" % val)
            return
        if port & 3 == self.compteur:
            if self.etape == 'lsb':
                self.lsb, self.etape = val, 'msb'
            elif self.etape == 'msb':
                d = (self.lsb | val << 8) or 0x10000
                self.etape = None
                if self.compteur == 0:
                    self.diviseur, self.debut = d, n
                else:
                    self.notes.append((n, d))

    def lire(self, port, n):
        if port & 3 == 0 and self.lecture:
            return self.lecture.pop(0)
        return 0xFF

    def niveau(self, n):
        """Bit IR0 : OUT0, haut pendant la premiere moitie de chaque periode."""
        if not self.diviseur:
            return 0
        return 1 if self._t(n) < self.diviseur // 2 else 0


def sortie_port(lcd, ppi, port, val, n, ppi2=None, pic=None, pit=None, hp=None):
    if port in (0, 1):
        lcd.ecrire(port, val, n)
    elif 0x10 <= port <= 0x13:
        ppi.ecrire(port, val)
    elif 0x30 <= port <= 0x33 and ppi2 is not None:
        ppi2.ecrire(port, val, n)
    elif 0x20 <= port <= 0x2F:                 # O2 : 8259 (A0), ou rien s'il est absent
        if pic is not None:
            pic.ecrire(port, val)
    elif 0x40 <= port <= 0x4F:                 # O4 : 8253, ou rien s'il est absent
        if pit is not None:
            pit.ecrire(port, val, n)
    elif 0x60 <= port <= 0x6F:                 # O6 : verrou du port 61h (U16)
        if hp is not None:
            hp.append((n, val))
    else:
        lcd.erreurs.append("OUT vers le port %02Xh" % port)


# ---- clavier PS/2 (jeu 2) ----------------------------------------------------------------
CODES = {'1': 0x16, '2': 0x1E, '3': 0x26, '4': 0x25, 'a': 0x1C, 'b': 0x32, 'd': 0x23, 'e': 0x24,
         'i': 0x43, 'm': 0x3A, '0': 0x45, '5': 0x2E, '6': 0x36, '7': 0x3D, '8': 0x3E, '9': 0x46,
         'r': 0x2D, 'v': 0x2A, 'c': 0x21, ' ': 0x29, '\r': 0x5A, '\x1b': 0x76, '\b': 0x66}
MAJ, CTRL, ALT = 0x12, 0x14, 0x11
FLECHES = {'haut': 0x75, 'bas': 0x72, 'gauche': 0x6B, 'droite': 0x74}


def appui(code, etendu=False):
    """Trame(s) d'un appui-relachement."""
    p = [0xE0] if etendu else []
    return p + [code] + p + [0xF0, code]


def texte(t):
    return [c for ch in t for c in appui(CODES[ch])]


def maj_fleche(nom, maj=0x12, appui_perdu=False):
    """Maj + fleche, comme un vrai clavier (Verr Num inactif pour lui) : Maj (12h gauche,
    59h droite), puis la fleche precedee d'un relachement FACTICE de cette Maj (E0 F0 xx)
    et suivie d'un appui factice (E0 xx). `appui_perdu` : l'appui reel de Maj manque
    (trame perdue sur le montage sans diode)."""
    c = FLECHES[nom]
    return ([] if appui_perdu else [maj]) + [0xE0, 0xF0, maj, 0xE0, c, 0xE0, 0xF0, c, 0xE0, maj, 0xF0, maj]


def programmer_codes(ppi2, n, codes):
    t = n
    for i, code in enumerate(codes):
        suite = code in (0xF0, 0xE0) or (i and codes[i - 1] in (0xF0, 0xE0))
        t += 3000 if suite else 30000
        ppi2.programmer(t, 'ps2', code)
    return t


class Rafale(bytes):
    """Octets UART envoyes d'un trait (sans pause entre les trames), comme une sequence
    ANSI d'un terminal."""


class Etapes:
    """Suite d'etapes (condition(ctx) -> codes PS/2 ou octets UART) : chaque etape part une
    fois, dans l'ordre, quand sa condition est vraie et que les trames precedentes sont parties."""
    def __init__(self, etapes):
        self.etapes = list(etapes)
        self.faites = 0
        self.libre = 0

    def __call__(self, ctx):
        ppi2, n = ctx["ppi2"], ctx["etat"]["n"]
        if self.faites >= len(self.etapes) or ppi2.attente or n < self.libre:
            return
        if ppi2.dernier_tx is not None and n - ppi2.dernier_tx < 4000:
            return                            # l'UART emet (interruptions masquees) : attendre
        cond, action = self.etapes[self.faites]
        if cond(ctx):
            self.faites += 1
            if isinstance(action, Rafale):
                t = n + 30000
                for i, c in enumerate(action):
                    ppi2.programmer(t + i * 10 * ppi2.bit_uart(), 'uart', c)
                t += len(action) * 10 * ppi2.bit_uart()
            elif isinstance(action, bytes):
                t = n
                for c in action:
                    t += 30000
                    ppi2.programmer(t, 'uart', c)
            else:
                t = programmer_codes(ppi2, n, action)
            self.libre = t + 60000


MENU = ["1) DOS      6) BASIC", "2) Test memoire     ", "3) Anim. DEL 7) ON  ", "4) Info  5) UART:ON "]
MENU_OFF = MENU[:3] + ["4) Info  5) UART:OFF"]
MENU_TX = b"\r\n1) DOS      6) BASIC\r\n2) Test memoire\r\n3) Anim. DEL 7) ON\r\n4) Info  5) UART:ON\r\n"


def au_menu(ctx):
    return ctx["lcd"].lignes() == MENU


def ecran_dos(uc):
    """Tampon d'ecran du BIOS (DSEG:0000, 24 x 80) en lignes de texte."""
    b = bytes(uc.mem_read(0x7F000, 24 * 80))
    return [b[i * 80:(i + 1) * 80].decode('latin1') for i in range(24)]


def empiler_int(uc, num, ip):
    """Entree dans le vecteur num comme le 8088 : indicateurs, CS, IP empiles ; IF = TF = 0."""
    off, seg = struct.unpack('<HH', bytes(uc.mem_read(num * 4, 4)))
    fl = uc.reg_read(UC_X86_REG_EFLAGS)
    ss, sp = uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP)
    for v in (fl & 0xFFFF, uc.reg_read(UC_X86_REG_CS), ip):
        sp = (sp - 2) & 0xFFFF
        uc.mem_write(ss * 16 + sp, struct.pack('<H', v))
    uc.reg_write(UC_X86_REG_SP, sp)
    uc.reg_write(UC_X86_REG_EFLAGS, fl & ~0x300)
    uc.reg_write(UC_X86_REG_CS, seg)
    uc.reg_write(UC_X86_REG_IP, off)


def lancer(image, defaut=None, alias=None, max_instr=80_000_000, fini=None, entrees=None, dos=False,
           diode=False, pic=True, pit=True, sd=None):
    """defaut(a) : la cellule a ne retient rien ; alias : la RAM ignore cette ligne d'adresse
    (une ecriture en a atteint aussi a ^ alias). fini(ctx) arrete la simulation ; entrees(ctx)
    est appelee a chaque lecture de PB de U12 (pour programmer des trames).
    dos : les ecritures en ROM sont ignorees (comptees) au lieu d'arreter la simulation.
    pic : 8259 (U13) present ; ses demandes sont servies entre deux instructions quand IF = 1
    (sauf juste apres STI), comme le 8088 : indicateurs, CS, IP empiles, IF = TF = 0.
    entrees(ctx) est aussi appelee toutes les 512 instructions."""
    rom = open(image, "rb").read()
    assert len(rom) == ROM_LEN, "image de %d octets (256 Ko attendus)" % len(rom)
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, RAM)
    uc.mem_write(0, bytes(RAM))
    uc.mem_map(ROM_BASE, 0x80000)            # en lecture-ecriture : les ecritures sont annulees
    uc.mem_write(ROM_BASE, rom)              # 80000h-BFFFFh
    uc.mem_write(ROM_BASE + ROM_LEN, rom)    # C0000h-FFFFFh
    lcd = LCD()
    ppi = PPI()
    ppi2 = PPI2(diode)
    ppi2.sd = sd
    pic8259 = PIC() if pic else None
    pit8254 = PIT() if pit else None
    etat = {"n": 0, "restaurer": [], "fin": None, "ppi": ppi, "ppi2": ppi2, "pic": pic8259, "pit": pit8254, "hp": [],
            "ecritures_rom": 0, "ints": {}, "int_iret": {}, "out_dos": {}, "out_libres": {},
            "irq": {}, "ombre": False}
    ctx = {"uc": uc, "lcd": lcd, "ppi2": ppi2, "etat": etat}

    def code(uc, adr, taille, ud):
        for a, v in etat["restaurer"]:       # ecriture annulee (cellule defectueuse, ROM)
            uc.mem_write(a, bytes([v]))
        etat["restaurer"] = []
        etat["n"] += 1
        n = etat["n"]
        if n > max_instr:
            etat["fin"] = "limite d'instructions atteinte"
            uc.emu_stop()
            return
        if entrees and n & 511 == 0:
            entrees(ctx)
        if pic8259 is not None:
            pic8259.entrees(ppi2.niveaux(n) | (pit8254.niveau(n) if pit8254 is not None else 0))
            if pic8259.int_haut and not etat["ombre"] and uc.reg_read(UC_X86_REG_EFLAGS) & 0x200:
                vec = pic8259.inta()                     # INTA : interruption materielle
                etat["irq"][vec] = etat["irq"].get(vec, 0) + 1
                empiler_int(uc, vec, uc.reg_read(UC_X86_REG_IP))
                return
        etat["ombre"] = uc.mem_read(adr, 1)[0] == 0xFB  # STI : pas d'interruption juste apres

    def ecriture(uc, acces, adr, taille, val, ud):
        if adr >= ROM_BASE:
            if not dos:
                etat["fin"] = "ecriture en ROM a %05Xh" % adr
                uc.emu_stop()
                return True
            etat["ecritures_rom"] += 1
            for i in range(taille):
                etat["restaurer"].append((adr + i, uc.mem_read(adr + i, 1)[0]))
            return True
        for i in range(taille):
            a = adr + i
            if defaut and defaut(a):
                etat["restaurer"].append((a, uc.mem_read(a, 1)[0]))
            elif alias and a < RAM:
                etat["restaurer"].append((a ^ alias, (val >> (8 * i)) & 0xFF))
        return True

    def sortie(uc, port, taille, val, ud):
        cs = uc.reg_read(UC_X86_REG_CS)
        if cs != 0xF000:                     # OUT du DOS ou d'un programme : O0, O1 et O3 du 138
            if (port & 0x80) == 0 and (port >> 4) & 7 in (0, 1, 3):   # sont interdits ; O2 = 8259
                etat["out_dos"][port] = etat["out_dos"].get(port, 0) + 1
            else:
                etat["out_libres"][port] = etat["out_libres"].get(port, 0) + 1
                if pic8259 is not None and 0x20 <= port <= 0x2F:
                    pic8259.ecrire(port, val & 0xFF)
            return
        sortie_port(lcd, ppi, port, val & 0xFF, etat["n"], ppi2, pic8259, pit8254, etat["hp"])
        if fini and fini(ctx):
            etat["fin"] = "ok"
            uc.emu_stop()

    def entree(uc, port, taille, ud):
        if entrees and port == 0x31:
            entrees(ctx)
        if 0x20 <= port <= 0x2F:
            return pic8259.lire(port) if pic8259 is not None else 0xFF
        if 0x40 <= port <= 0x4F:
            return pit8254.lire(port, etat["n"]) if pit8254 is not None else 0xFF
        return ppi2.lire(port, etat["n"]) if 0x30 <= port <= 0x33 else 0xFF

    def interruption(uc, num, ud):          # aiguillage du mode reel (Unicorn ne le fait pas)
        off, seg = struct.unpack('<HH', bytes(uc.mem_read(num * 4, 4)))
        etat["ints"][num] = etat["ints"].get(num, 0) + 1
        if uc.mem_read(seg * 16 + off, 1)[0] == 0xCF:   # IRET : vecteur non gere
            etat["int_iret"][num] = etat["int_iret"].get(num, 0) + 1
        empiler_int(uc, num, uc.reg_read(UC_X86_REG_IP))

    uc.hook_add(UC_HOOK_CODE, code)
    uc.hook_add(UC_HOOK_MEM_WRITE, ecriture)
    uc.hook_add(UC_HOOK_INSN, sortie, None, 1, 0, UC_X86_INS_OUT)
    uc.hook_add(UC_HOOK_INSN, entree, None, 1, 0, UC_X86_INS_IN)
    uc.hook_add(UC_HOOK_INTR, interruption)
    uc.reg_write(UC_X86_REG_CS, 0xFFFF)      # etat du 8088 apres RESET
    uc.reg_write(UC_X86_REG_IP, 0x0000)
    try:
        uc.emu_start(0xFFFF0, 0)
    except UcError as e:
        etat["fin"] = "erreur unicorn %s a %04X:%04X" % (e, uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP))
    return lcd, etat, uc


def afficher(titre, lcd, etat):
    print("--- %s (%s, %d instructions, %d ecritures LCD)" % (titre, etat["fin"], etat["n"], lcd.ecritures))
    print("    +" + "-" * 20 + "+")
    for l in lcd.lignes():
        print("    |%s|" % l)
    print("    +" + "-" * 20 + "+")
    for e in lcd.erreurs[:10]:
        print("    ERREUR LCD:", e)


def verifier(titre, lcd, etat, attendu, ok=True):
    """Bilan commun : fin normale, LCD sans erreur, lignes attendues, 8255 sans erreur."""
    afficher(titre, lcd, etat)
    ok = ok and etat["fin"] == "ok" and not lcd.erreurs and lcd.allume
    for l, a in zip(lcd.lignes(), attendu or [None] * 4):
        if a is not None and l != a:
            ok = False
            print("    attendu: |%s|" % a)
    for e in (etat["ppi"].erreurs + etat["ppi2"].erreurs)[:5]:
        ok = False
        print("    ERREUR 8255:", e)
    pit = etat.get("pit")
    if pit is not None:
        for e in pit.erreurs[:5]:
            ok = False
            print("    ERREUR 8253:", e)
    pic = etat["pic"]
    if pic is not None:
        for e in pic.erreurs[:5]:
            ok = False
            print("    ERREUR 8259:", e)
        if pic.servies or pic.parasites:
            print("    8259 : IRQ servies %s, IRQ7 parasites %d, trames PS/2 %d (perdues %d)" % (
                pic.servies, pic.parasites, etat["ppi2"].trames, etat["ppi2"].perdues))
    print("    =>", "OK" if ok else "ECHEC")
    return ok


BANNIERE = (b"\r\nSolution-02 BIOS 2.9 - VE2CUY 2026\r\n"
            b"Menu (clavier PS/2) : 1) DOS  2) Test memoire  3) Anim. DEL  4) Info"
            b"  5) UART:ON/OFF (console)  6) BASIC  7) Anim. DEL ON/OFF"
            b"  8) Vitesse UART (ATmega)  9) Wi-Fi (AT)\r\n")
RAM_OK = ["MEMOIRE 512 Ko : OK ", "Ko: 512  Defauts 000", "Adresses A0-A18: OK ", "PILE OK  Touche=menu"]
echec_ram = lambda ctx: ctx["lcd"].lignes()[0].endswith("CPT 0003")


def scenario_menu(image):
    import gen_accueil
    attendu_tx = BANNIERE + gen_accueil.octets() + MENU_TX
    lcd, etat, uc = lancer(image, fini=lambda c: au_menu(c) and bytes(c["ppi2"].tx).endswith(MENU_TX))
    p2 = etat["ppi2"]
    ok = True
    ss, sp = uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP)
    print("--- (pile SS:SP = %04X:%04X ; UART TX : bit = %s instructions, %r)" % (ss, sp, p2.bit_uart(), bytes(p2.tx)[:50]))
    if ss != 0x7F00 or sp < 0x0F00:
        ok = False
        print("    attendu: pile en 7F00:1000 (ou presque)")
    if bytes(p2.tx) != attendu_tx:
        ok = False
        print("    attendu: banniere, accueil ANSI et menu sur l'UART (console a ON par defaut)")
    return verifier("demarrage : ecran d'ouverture, DSEG, banniere, menu", lcd, etat, MENU, ok)


def scenario_ram_s01(image, titre, mode, attendu_tx, lcd0, defaut=None, alias=None, max_instr=150_000_000):
    """BIOS 2.3 : menu 2) = test exhaustif de Solution-01 (ramtest.inc) : sous-menu, mode
    1 (Trace) ou 2 (MAP) ; rapport sur l'UART (attendu_tx : morceaux a trouver) ; LCD ligne 1
    = lcd0 a la fin ; une touche : sous-menu ; Echap : menu."""
    tx = lambda c: bytes(c["ppi2"].tx)
    sous = lambda c: (c["lcd"].lignes()[0].startswith("Test RAM 512K") and c["lcd"].lignes()[1].startswith("1) Trace")
                      and tx(c).endswith(b"retour au menu\r\n"))
    vu = {}

    def fin_test(c):
        if b"TOTAL DEFAUT" in tx(c) and b"Une touche" in tx(c)[-60:]:
            vu.setdefault("lcd", c["lcd"].lignes())
            return True
        return False
    pas = Etapes([(au_menu, texte('2')), (sous, texte(mode)), (fin_test, texte('\r')),
                  (lambda c: sous(c) and pas.faites == 3, texte('\x1b'))])
    lcd, etat, uc = lancer(image, defaut, alias, entrees=pas, max_instr=max_instr,
                           fini=lambda c: pas.faites == 4 and au_menu(c))
    t = tx({"ppi2": etat["ppi2"]})
    rapport = t[t.find(b"=== Test RAM"):]
    manque = [m for m in attendu_tx if m not in rapport]
    print("--- LCD a la fin : %s ; manque : %s" % (vu.get("lcd"), manque))
    print("    %r" % rapport[-420:])
    ok = not manque and vu.get("lcd") and vu["lcd"][0].startswith(lcd0)
    return verifier(titre, lcd, etat, MENU, ok)


def scenario_ram_boucle(image):
    """BIOS 2.3 : menu 2) 3) Loop : la passe 1 tourne ; Echap pendant la passe (interruptions
    permises hors du segment 0 : la touche attend en file) -> arret apres la passe, bilan
    'Boucle: 1 passe(s), 1 bonne(s), 0 avec defauts', retour au sous-menu, Echap : menu."""
    tx = lambda c: bytes(c["ppi2"].tx)
    sous = lambda c: (c["lcd"].lignes()[0].startswith("Test RAM 512K") and c["lcd"].lignes()[1].startswith("1) Trace")
                      and tx(c).endswith(b"retour au menu\r\n"))
    pas = Etapes([(au_menu, texte('2')), (sous, texte('3')),
                  (lambda c: b"K testes" in tx(c)[-40:], texte('\x1b')),
                  (lambda c: sous(c) and b"arrete (Echap)" in tx(c), texte('\x1b'))])
    lcd, etat, uc = lancer(image, entrees=pas, max_instr=200_000_000, fini=lambda c: pas.faites == 4 and au_menu(c))
    t = tx({"ppi2": etat["ppi2"]})
    ok = b"passe 1 " in t and b"passe 2 " not in t and b"Boucle: 1 passe(s), 1 bonne(s), 0 avec defauts" in t
    print("--- %r" % t[t.find(b"arrete"):][:160])
    if not ok:
        print("    attendu : une seule passe, arret par Echap, bilan 1 / 1 / 0")
    return verifier("menu 2) Test RAM, Loop arrete par Echap", lcd, etat, MENU, ok)


def scenario_test_ram(image):
    vu = {"bilan": None}

    def fini(ctx):
        l = ctx["lcd"].lignes()
        if l[3] == RAM_OK[3] and vu["bilan"] is None:
            vu["bilan"] = l
        return vu["bilan"] is not None and l == MENU
    pas = Etapes([(au_menu, texte('2')), (lambda c: c["lcd"].lignes()[3] == RAM_OK[3], texte('\r'))])
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas)
    ok = vu["bilan"] == RAM_OK
    print("--- bilan vu : %s" % vu["bilan"])
    if not ok:
        print("    attendu : %s" % RAM_OK)
    return verifier("menu 2) Test memory, RAM saine, puis retour au menu", lcd, etat, MENU, ok)


def scenario_ram_defaut(image, titre, attendu, defaut=None, alias=None, touche=True):
    pas = Etapes([(au_menu, texte('2'))]) if touche else None
    lcd, etat, uc = lancer(image, defaut, alias, fini=echec_ram, entrees=pas, max_instr=40_000_000)
    return verifier(titre, lcd, etat, attendu)


def scenario_led(image, pit=True):
    lcd, etat, uc = lancer(image, fini=lambda c: c["lcd"].lignes()[1].endswith("0001"),
                           entrees=Etapes([(au_menu, texte('3'))]), pit=pit)
    ppi = etat["ppi"]
    print("--- 8255 : %d sorties, DEL vues allumees %s, eteintes %s" % (
        ppi.sorties, ["%02X" % v for v in ppi.allumees], ["%02X" % v for v in ppi.eteintes]))
    ok = ppi.toutes_vues()
    if not ok:
        print("    attendu: chacune des 24 DEL allumee et eteinte au moins une fois")
    return verifier("menu 3) LED Show : un cycle complet d'animations (%s)" % (
                    "arriere-plan, IRQ0" if pit else "SANS 8254 : premier plan"), lcd, etat,
                    ["LED SHOW  Echap=menu", "Chenillard      0001", "Clavier PS/2 >      ", "UART 9600 8N1 >     "], ok)


# LED Show : Maj+a, b, 1, retour arriere, fleche haut ; "Hi" recu sur l'UART ; Echap
CLAVIER = [MAJ] + appui(0x1C) + [0xF0, MAJ] + texte('b1\b') + appui(0x75, True)
TX_ATTENDU = b"Ab1\x08 \x08\x1b[AHi"


def scenario_terminal(image):
    vu = {"lignes": None}
    lance = lambda c: c["lcd"].lignes()[0] == "LED SHOW  Echap=menu" and c["etat"]["ppi"].sorties > 30

    def ecrit(c):
        l = c["lcd"].lignes()
        if l[3].startswith("Hi") and vu["lignes"] is None:
            vu["lignes"] = l
        return vu["lignes"] is not None

    hors = lambda c: c["lcd"].lignes() == MENU_OFF
    pas = Etapes([(au_menu, texte('5')), (hors, texte('3')), (lance, CLAVIER), (lance, b"Hi"), (ecrit, texte('\x1b'))])

    def fini(c):
        ecrit(c)
        return vu["lignes"] is not None and c["lcd"].lignes() == MENU_OFF
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas)
    p2 = etat["ppi2"]
    t = bytes(p2.tx)
    recu = t[t.rfind(MENU_TX) + len(MENU_TX):]     # apres le menu (console passee a OFF)
    print("--- LED Show : lignes vues %s ; UART TX apres la banniere : %r" % (vu["lignes"], recu))
    ok = bool(vu["lignes"]) and vu["lignes"][2] == "Ab                  " and vu["lignes"][3] == "Hi                  "
    if recu != TX_ATTENDU:
        ok = False
        print("    attendu: %r" % TX_ATTENDU)
    return verifier("menu 3) terminal clavier + UART (console OFF), Echap = retour au menu", lcd, etat, MENU_OFF, ok)


def scenario_sysinfo(image, pic=True, pit=True):
    """Info ; avec ou sans 8259 (sans : detection par le masque, clavier scrute), avec ou
    sans 8254."""
    vu = {"l": None}
    ligne4 = ("8259+8253 OK I7 0000" if pit else "8259 OK  8253 absent") if pic else "8259 absent (scrut.)"
    pret = lambda c: c["lcd"].lignes()[3] == ligne4

    def fini(c):
        l = c["lcd"].lignes()
        if l[0] == "SOLUTION-02 BIOS 2.9" and pret(c):
            vu["l"] = l
        return vu["l"] is not None and l == MENU
    pas = Etapes([(au_menu, texte('4')), (pret, texte(' '))])
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, pic=pic, pit=pit)
    attendu = ["SOLUTION-02 BIOS 2.9", "CPU 8088    5.33 MHz", "RAM 512Ko  ROM 256Ko", ligne4]
    ok = vu["l"] == attendu
    print("--- SysInfo vu : %s" % vu["l"])
    if not ok:
        print("    attendu : %s" % attendu)
    return verifier("menu 4) Info puis retour au menu (%s)" % (
                        ("8259 et 8254" if pit else "SANS 8254") if pic else "SANS 8259"),
                    lcd, etat, MENU, ok)


def scenario_anticipe(image):
    """DOS : des touches frappees PENDANT l'affichage de DIR (le DOS ne lit pas le clavier)
    doivent arriver a l'invite suivante : avec le 8259, IRQ1 les met dans la file. Console
    UART a OFF (touche 5) : sinon l'envoi de DIR sur l'UART occupe tout l'affichage."""
    ecran = lambda c: "\n".join(ecran_dos(c["uc"]))
    vu = {}

    def fin_vue(c):
        lignes = [l.rstrip() for l in ecran_dos(c["uc"]) if l.strip()]
        if lignes and lignes[-1] == "A>rem abc" and "bytes free" in ecran(c):
            vu["fin"] = lignes[-3:]
            return True
        return False
    pas = Etapes([
        (au_menu, texte('5')),
        (lambda c: c["lcd"].lignes() == MENU_OFF, texte('1')),
        (lambda c: "Enter new date" in ecran(c), texte('\r')),
        (lambda c: "Enter new time" in ecran(c), texte('\r')),
        (lambda c: ecran(c).count("A>") >= 1, texte('dir\r')),
        (lambda c: "Directory of" in ecran(c) and "bytes free" not in ecran(c), texte('rem abc')),
    ])
    lcd, etat, uc = lancer(image, fini=fin_vue, entrees=pas, dos=True, max_instr=200_000_000)
    print("--- fin de l'ecran du DOS : %s" % vu.get("fin"))
    p2 = etat["ppi2"]
    ok = "fin" in vu and not p2.perdues
    if not ok:
        print("    attendu : 'A>rem abc' apres DIR, aucune trame perdue (%d perdue(s))" % p2.perdues)
    return verifier("DOS : frappe pendant DIR (touches en file par IRQ1)", lcd, etat, None, ok)


def scenario_console(image):
    """Menu 5 (UART:ON), puis Load DOS pilote depuis le terminal : date et heure, DIR, saisie
    avec la fleche gauche ANSI (ESC [ D d'un trait) et Echap seul ; la sortie du DOS doit
    arriver sur TX."""
    tx = lambda c: bytes(c["ppi2"].tx)
    lignes = lambda c: [l.rstrip() for l in ecran_dos(c["uc"]) if l.strip()]
    ecran = lambda c: "\n".join(lignes(c))
    on = lambda c: c["lcd"].lignes()[3] == "4) Info  5) UART:ON " and b"5) UART:ON\r\n" in bytes(c["ppi2"].tx)  # menu envoye
    vu = {}

    def apres_dir(c):
        return "bytes free" in ecran(c) and lignes(c)[-1] == "A>"

    def fini(c):
        l = lignes(c)
        if l and l[-1] == "A>" and "  rem ok" in l:          # (Echap : ligne suivante en retrait)
            vu["fin"] = l[-6:]
            return True
        return False
    pas = Etapes([
        (au_menu, texte('1')),
        (lambda c: b"Enter new date" in tx(c), b"\r"),
        (lambda c: b"Enter new time" in tx(c), b"\r"),
        (lambda c: tx(c).count(b"A>") >= 1, b"dir\r"),
        (apres_dir, b"rem xy"),
        (lambda c: lignes(c)[-1] == "A>rem xy", Rafale(b"\x1b[D")),
        (lambda c: lignes(c)[-1] == "A>rem x", b"z\r"),
        (lambda c: lignes(c)[-1] == "A>" and "A>rem xz" in lignes(c), b"abc\x1b"),
        (lambda c: "A>abc\\" in ecran(c), b"rem ok\r"),
    ])
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=250_000_000)
    t = tx({"ppi2": etat["ppi2"]})
    debut = len(BANNIERE)
    print("--- UART TX : %d octets ; fin : %r" % (len(t), t[-160:]))
    print("    fin de l'ecran du DOS : %s" % vu.get("fin"))
    ok = "fin" in vu and t.startswith(BANNIERE)
    for attendu in (b"Enter new date", b"Version 2.10", b"bytes free", b"A>rem xy\x08 \x08z\r", b"A>abc\\\r\n  rem ok"):
        if attendu not in t[max(debut, 0):]:
            ok = False
            print("    attendu sur TX : %r" % attendu)
    if "fin" not in vu:
        print("    attendu : 'A>rem xz' (fleche gauche ANSI), 'A>abc\\' (Echap), puis '  rem ok'")
    p2 = etat["ppi2"]
    if p2.perdues:
        ok = False
        print("    attendu : aucune trame du clavier perdue (%d)" % p2.perdues)
    return verifier("menu 5) console du DOS sur l'UART (sortie TX, entree IRQ4, ANSI)", lcd, etat, None, ok)


def scenario_diag_sd(image):
    """ROM de diagnostic du lecteur SD (make diagsd) : carte SDHC de 64 Mo en FAT32 avec
    2 images ; puis sans carte."""
    import gen_sd
    ici = os.path.dirname(os.path.abspath(__file__))
    img = open(os.path.join(ici, '..', '..', '..', 'PC-DOS', 'pcdos2_1.img'), 'rb').read()
    secteurs, nb = gen_sd.carte_fat32([('PCDOS21.IMG', img), ('VIDE160.IMG', bytes(163840)), ('LISEZMOI.TXT', b'x' * 100)])
    attendu = ["DIAG SD 01 01 00    ", "SDHC 64 Mo          ", "FAT32 part. 2048    ", "2 IMG PCDOS21.IMG   "]
    carte = CarteSD(secteurs, nb)
    lcd, etat, uc = lancer(image, fini=lambda c: c["lcd"].lignes() == attendu, sd=carte, max_instr=40_000_000)
    t = bytes(etat["ppi2"].tx)
    print("--- UART : %r" % t[t.find(b"--- Diag"):][:400])
    print("    commandes SD : %s" % [c for c, a in carte.commandes][:20])
    ok = b"  PCDOS21.IMG  180 Ko" in t and b"  VIDE160.IMG  160 Ko" in t
    if not ok:
        print("    attendu sur l'UART : les 2 images et leur taille")
    ok1 = verifier("diagnostic SD : carte SDHC FAT32, 2 images", lcd, etat, attendu, ok)
    vide = ["DIAG SD FF FF FF    ", "Pas de carte (et. 1)"]
    lcd, etat, uc = lancer(image, fini=lambda c: c["lcd"].lignes()[:2] == vide, sd=CarteSD(presente=False),
                           max_instr=20_000_000)
    ok2 = verifier("diagnostic SD : sans carte", lcd, etat, vide + [None, None], True)
    return ok1 and ok2


def carte_dos(fragmente=False):
    """Carte SDHC FAT32 : PCDOS21.IMG (180 Ko) et une 2e image (copie, fragmentee au besoin)."""
    import gen_sd
    ici = os.path.dirname(os.path.abspath(__file__))
    img = open(os.path.join(ici, '..', '..', '..', 'PC-DOS', 'pcdos2_1.img'), 'rb').read()
    secteurs, nb = gen_sd.carte_fat32([('PCDOS21.IMG', img), ('COPIE.IMG', img)], fragmente=fragmente)
    return CarteSD(secteurs, nb), img


def scenario_sd_boot(image):
    """BIOS 2.3 : Load DOS avec une carte : choix de PCDOS21.IMG (fleche bas, Entree), le DOS
    demarre depuis la carte, puis 'dir > liste.txt' ecrit dans l'image (A:), relue sur la carte."""
    import gen_sd
    carte, img = carte_dos()
    tx = lambda c: bytes(c["ppi2"].tx)
    choix = ["Demarrer : Entree   ", ">ROM PC-DOS 2.1     ", " PCDOS21.IMG  180K  ", " COPIE.IMG    180K  "]
    vu = {}

    def liste(c):
        if c["lcd"].lignes() == choix and tx(c).endswith(b"COPIE.IMG    180K\r\n"):   # ecran envoye
            vu["choix"] = True
            return True
        return False
    on = lambda c: c["lcd"].lignes()[3] == "4) Info  5) UART:ON " and b"5) UART:ON\r\n" in tx(c)
    pas = Etapes([(au_menu, texte('1')), (liste, Rafale(b"\x1b[B")),
                  (lambda c: c["lcd"].lignes()[2].startswith(">PCDOS21"), b"\r"),
                  (lambda c: b"Enter new date" in tx(c), b"\r"),
                  (lambda c: b"Enter new time" in tx(c), b"\r"),
                  (lambda c: invite(c, 1), b"dir > liste.txt\r")])

    def fini(c):
        return pas.faites == len(pas.etapes) and invite(c, 2)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=300_000_000, sd=carte)
    lus = sum(1 for c, a in carte.commandes if c == 17)
    print("--- carte : %d secteurs lus, %d ecrits ; ecran de choix vu : %s" % (lus, len(carte.ecrits), vu.get("choix")))
    contenu = gen_sd.lire_fichier(carte.s, 'PCDOS21.IMG')
    ok = vu.get("choix") and b"Version 2.10" in tx({"ppi2": etat["ppi2"]}) and contenu is not None
    ok = ok and b'LISTE   TXT' in contenu and len(carte.ecrits) > 0
    if not ok:
        print("    attendu : ecran de choix, demarrage depuis la carte, LISTE.TXT ecrit dans l'image")
    copie = gen_sd.lire_fichier(carte.s, 'COPIE.IMG')
    if copie != img:
        ok = False
        print("    attendu : l'autre image intacte")
    return verifier("BIOS 2.3 : demarrage sur une image de la carte SD, ecriture dans l'image", lcd, etat, None, ok)


def scenario_sd_fragmentee(image):
    """Une image fragmentee est refusee (message), on revient a la liste."""
    carte, img = carte_dos(fragmente=True)
    choix = ["Demarrer : Entree   ", ">ROM PC-DOS 2.1     ", " PCDOS21.IMG  180K  ", " COPIE.IMG    180K  "]
    vu = {}

    def msg(c):
        if c["lcd"].lignes()[0] == "Image fragmentee !  ":
            vu["msg"] = True
        return vu.get("msg") and c["lcd"].lignes()[0] == choix[0]
    pas = Etapes([(au_menu, texte('1')), (lambda c: c["lcd"].lignes() == choix, appui(0x72, True) + appui(0x72, True)),
                  (lambda c: c["lcd"].lignes()[3].startswith(">COPIE"), texte('\r'))])
    lcd, etat, uc = lancer(image, fini=msg, entrees=pas, max_instr=40_000_000, sd=carte)
    return verifier("BIOS 2.3 : image fragmentee refusee", lcd, etat, None, bool(vu.get("msg")))


def scenario_basic(image):
    """Menu 6 : le BASIC de Solution-01 (banniere, Ok), PRINT 2+3 tape au terminal, SYSTEM -> menu."""
    tx = lambda c: bytes(c["ppi2"].tx)
    pas = Etapes([(au_menu, texte('6')), (lambda c: tx(c).endswith(b"Ok\r\n"), b"PRINT 2+3\r"),
                  (lambda c: tx(c).count(b"Ok\r\n") >= 2, b"SYSTEM\r")])

    def fini(c):
        return pas.faites == 3 and au_menu(c)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, max_instr=60_000_000)
    t = tx({"ppi2": etat["ppi2"]})
    i = t.find(b"VE2CUY 86 BASIC")
    print("--- UART : %r" % t[i:i + 200])
    ok = i >= 0 and b"PRINT 2+3\r\n 5 \r\nOk\r\n" in t
    if not ok:
        print("    attendu : banniere du BASIC, ' 5 ' apres PRINT 2+3, puis Ok")
    return verifier("menu 6) BASIC (Solution-01) : PRINT 2+3, SYSTEM", lcd, etat, MENU, ok)


def scenario_rom_b(image):
    """Demarrage depuis la ROM avec une carte : l'image PC-DOS 2.x de la carte devient B:
    (DIR B: montre la disquette complete), et le DOS a 507 Ko (pas de disque en RAM)."""
    import gen_sd
    ici = os.path.dirname(os.path.abspath(__file__))
    img = open(os.path.join(ici, '..', '..', '..', 'PC-DOS', 'pcdos2_1.img'), 'rb').read()
    secteurs, nb = gen_sd.carte_fat32([('PCDOS21.IMG', img)])
    carte = CarteSD(secteurs, nb)
    choix = lambda c: c["lcd"].lignes()[1] == ">ROM PC-DOS 2.1     "
    cmds = [(lambda c: invite(c, 1), b"dir b:\r")]
    pas_dos = [(au_menu, texte('1')), (choix, b"\r"),
               (lambda c: b"Enter new date" in bytes(c["ppi2"].tx), b"\r"),
               (lambda c: b"Enter new time" in bytes(c["ppi2"].tx), b"\r")] + cmds
    pas = Etapes(pas_dos)

    def fini(c):
        return pas.faites == len(pas.etapes) and invite(c, 2)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=300_000_000, sd=carte)
    t = bytes(etat["ppi2"].tx)
    memoire = struct.unpack('<H', bytes(uc.mem_read(0x413, 2)))[0]
    print("--- INT 12h (BDA) : %d Ko ; fin : %r" % (memoire, t[-300:]))
    ok = b"BASICA   COM    26112" in t and memoire == 507
    if not ok:
        print("    attendu : DIR B: = l'image de la carte (BASICA.COM), 507 Ko pour le DOS")
    return verifier("ROM + carte : B: = image PC-DOS 2.1 de la carte, 507 Ko", lcd, etat, None, ok)


def scenario_accents(image):
    """Caracteres 80h-FFh de la page de codes 437 (ceux du DOS) : PRINT CHR$(130);CHR$(135);
    CHR$(129) dans le BASIC (INT 10h) -> UTF-8 sur le terminal (e aigu, c cedille, u trema) ;
    LCD : CGRAM 0 et 5 (glyphes charges) puis 'u' (sans accent)."""
    tx = lambda c: bytes(c["ppi2"].tx)
    pas = Etapes([(au_menu, texte('6')), (lambda c: tx(c).endswith(b"Ok\r\n"), b"PRINT CHR$(130);CHR$(135);CHR$(129);CHR$(92)\r"),
                  (lambda c: tx(c).count(b"Ok\r\n") >= 2, b"SYSTEM\r")])

    def fini(c):
        return pas.faites == 3 and au_menu(c)
    vu = {}

    def entrees(c):
        if bytes([0, 5, ord('u'), 4]) in bytes(c["lcd"].ddram):     # '\' : CGRAM 4 (pas le yen)
            vu["lcd"] = True
        pas(c)
    lcd, etat, uc = lancer(image, fini=fini, entrees=entrees, max_instr=60_000_000)
    t = tx({"ppi2": etat["ppi2"]})
    utf = "\u00e9\u00e7\u00fc\\".encode('utf-8')
    print("--- UART : %r ; LCD (codes 0, 5, 'u') vu : %s ; CGRAM 0 : %s" % (
        t[t.find(b"PRINT CHR$"):][:60], vu.get("lcd"), ["%02X" % b for b in lcd.cgram[:8]]))
    ok = (utf in t and vu.get("lcd") and lcd.cgram[:8] == [0x02, 0x04, 0x0E, 0x11, 0x1F, 0x10, 0x0E, 0x00]
          and lcd.cgram[32:40] == [0x00, 0x10, 0x08, 0x04, 0x02, 0x01, 0x00, 0x00])
    if not ok:
        print("    attendu : e aigu, c cedille, u trema en UTF-8 sur l'UART ; LCD : CGRAM 0, 5 et 'u'")
    return verifier("accents (page de codes 437) : UTF-8 sur le terminal, CGRAM sur le LCD", lcd, etat, MENU, ok)


def scenario_disque_c(image):
    """Disques durs : DISQUEC.IMG (20 Mo, FAT16, HELLO.TXT) et DISQUED.IMG (BONJOUR.TXT) sur la
    carte, avec DOS33.IMG : la liste du Load DOS montre les deux lignes C: ('*' = le disque
    choisi, le 1er au depart) ; Espace sur DISQUED le choisit ; DOS 3.3 demarre depuis la
    carte, DIR C: montre BONJOUR.TXT, 'dir > c:liste.txt' ecrit dans DISQUED.IMG (relue sur la
    carte ; DISQUEC.IMG intacte)."""
    import gen_sd
    import gen_hdd
    ici = os.path.dirname(os.path.abspath(__file__))
    dos33 = open(os.path.join(ici, '..', '..', '..', 'PC-DOS', 'Dos33-d1.IMG'), 'rb').read()
    hd1 = gen_hdd.disque(20, [('HELLO.TXT', b'Bonjour du disque C:\r\n')])
    hd2 = gen_hdd.disque(20, [('BONJOUR.TXT', b'Le 2e disque\r\n')])
    secteurs, nb = gen_sd.carte_fat32([('DOS33.IMG', dos33), ('DISQUEC.IMG', hd1), ('DISQUED.IMG', hd2)])
    carte = CarteSD(secteurs, nb)
    tx = lambda c: bytes(c["ppi2"].tx)
    l = lambda c, i: c["lcd"].lignes()[i]
    vu = {}

    def liste(c):
        if l(c, 1).startswith(">ROM") and l(c, 2).startswith(" DOS33.IMG") and l(c, 3).startswith("*C:DISQUEC.IMG"):
            vu["liste"] = c["lcd"].lignes()
            return tx(c).endswith(b"19M\r\n")       # 20 643 840 o = 19,7 Mo
        return False
    bas, haut = Rafale(b"\x1b[B"), Rafale(b"\x1b[A")
    vue = lambda i, debut: (lambda c: l(c, i).startswith(debut) and debut.encode() in tx(c)[-70:])
    cmds = [(au_menu, texte('1')), (liste, bas),
            (vue(2, ">DOS33"), bas), (vue(3, ">C:DISQUEC"), bas),
            (vue(3, ">C:DISQUED"), b" "),
            (lambda c: vue(3, ">C:DISQUED")(c) and l(c, 2).startswith(" C:DISQUEC") and
             b" C:DISQUEC" in tx(c)[-70:], haut),
            (vue(2, ">C:DISQUEC"), haut), (vue(1, ">DOS33"), b"\r"),
            (lambda c: tx(c).rstrip().endswith(b":") and b"new date" in tx(c)[-80:], b"\r"),
            (lambda c: tx(c).rstrip().endswith(b":") and b"new time" in tx(c)[-80:], b"\r"),
            (lambda c: invite(c, 1), b"dir c:\r"), (lambda c: invite(c, 2), b"dir > c:liste.txt\r")]
    pas = Etapes(cmds)

    def fini(c):
        return pas.faites == len(pas.etapes) and invite(c, 3)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=500_000_000, sd=carte)
    t = tx({"ppi2": etat["ppi2"]})
    relu = gen_sd.lire_fichier(carte.s, 'DISQUED.IMG')
    noms = gen_hdd.racine(relu) if relu else []
    autre = gen_sd.lire_fichier(carte.s, 'DISQUEC.IMG')
    print("--- liste : %s ; etapes %d/%d" % (vu.get("liste"), pas.faites, len(pas.etapes)))
    print("    racine de DISQUED apres : %s ; fin : %r" % (noms, t[-250:]))
    ok = ("liste" in vu and b"BONJOUR  TXT" in t and b"HELLO" not in t and 'LISTE   TXT' in noms
          and autre == hd1)
    if not ok:
        print("    attendu : 2 lignes C:, Espace -> DISQUED, BONJOUR.TXT par DIR C:, LISTE.TXT ecrit sur DISQUED")
    return verifier("disques durs C: (choix par Espace) sous DOS 3.3 : DIR, ecriture", lcd, etat, None, ok)


def scenario_change_a(image):
    """BIOS 2.3 : changement de la disquette de A: sous DOS. DOS 3.3 demarre depuis DOS33.IMG ;
    Ctrl+Alt+Inser (clavier PS/2) a l'invite : liste 'Disquette A: Entree', 2 x fleche bas ->
    PCDOS21.IMG ; DIR A: montre MASM.EXE. Puis Ctrl+] (terminal) : DOS33.IMG ; DIR A: montre
    de nouveau COUNTRY.SYS (INT 13h AH=16h signale chaque changement)."""
    import gen_sd
    ici = os.path.dirname(os.path.abspath(__file__))
    lire = lambda n: open(os.path.join(ici, '..', '..', '..', 'PC-DOS', n), 'rb').read()
    secteurs, nb = gen_sd.carte_fat32([('DOS33.IMG', lire('Dos33-d1.IMG')),
                                       ('PCDOS21.IMG', lire('pcdos2_1_rom.img'))])
    carte = CarteSD(secteurs, nb)
    tx = lambda c: bytes(c["ppi2"].tx)
    lcd = lambda c, i: c["lcd"].lignes()[i]
    fin_chg = b"A: change (Echap : rien).\r\n"
    ctrl_alt_ins = [CTRL, ALT, 0xE0, 0x70, 0xE0, 0xF0, 0x70, 0xF0, ALT, 0xF0, CTRL]
    vu = {}

    def liste(c):
        return lcd(c, 0).startswith("Disquette A:") and tx(c).rstrip().endswith(b"PCDOS21.IMG  180K")

    def apres(n):
        def f(c):
            if tx(c).count(fin_chg) >= n:
                vu.setdefault("chg%d" % n, len(tx(c)))
                return True
            return False
        return f
    cmds = [(au_menu, texte('1')),
            (lambda c: lcd(c, 2).startswith(" DOS33") and tx(c).endswith(b"180K\r\n"), Rafale(b"\x1b[B")),
            (lambda c: lcd(c, 2).startswith(">DOS33") and b">DOS33" in tx(c)[-60:], b"\r"),
            (lambda c: tx(c).rstrip().endswith(b":") and b"new date" in tx(c)[-80:], b"\r"),
            (lambda c: tx(c).rstrip().endswith(b":") and b"new time" in tx(c)[-80:], b"\r"),
            (lambda c: invite(c, 1), ctrl_alt_ins),
            (liste, Rafale(b"\x1b[B")),
            (lambda c: lcd(c, 2).startswith(">DOS33") and b">DOS33" in tx(c)[-60:], Rafale(b"\x1b[B")),
            (lambda c: lcd(c, 3).startswith(">PCDOS21") and b">PCDOS21" in tx(c)[-30:], b"\r"),
            (apres(1), b"dir a:\r"),
            (lambda c: invite(c, 2), b"\x1d"),
            (lambda c: liste(c) and tx(c).count(b"Disquette A:") >= 2, Rafale(b"\x1b[B")),
            (lambda c: lcd(c, 2).startswith(">DOS33") and b">DOS33" in tx(c)[-60:], b"\r"),
            (apres(2), b"dir a:\r")]
    pas = Etapes(cmds)

    def fini(c):
        return pas.faites == len(pas.etapes) and invite(c, 3)
    lcd_, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=600_000_000, sd=carte)
    t = tx({"ppi2": etat["ppi2"]})
    d1 = t[vu.get("chg1", len(t)):vu.get("chg2", len(t))]
    d2 = t[vu.get("chg2", len(t)):]
    print("--- etapes %d/%d ; apres le 1er changement : %r" % (pas.faites, len(pas.etapes), d1[-200:]))
    print("    apres le 2e : %r" % d2[-200:])
    ok = b"MASM     EXE" in d1 and b"COUNTRY" not in d1 and b"COUNTRY  SYS" in d2 and b"MASM" not in d2
    if not ok:
        print("    attendu : MASM.EXE apres le 1er changement, COUNTRY.SYS apres le 2e")
    return verifier("changement de la disquette de A: sous DOS 3.3 (Ctrl+Alt+Inser, Ctrl+])", lcd_, etat, None, ok)


def disquette_vide_360k():
    """Image FAT12 de 360 Ko formatee (BPB du DOS, FAT FD FF FF, racine vide)."""
    import struct as st
    im = bytearray(368640)
    b = bytearray(512)
    b[0:3] = b'\xEB\x3C\x90'
    st.pack_into('<8sHBHBHHBHHHII', b, 3, b'SOL02 FD', 512, 2, 1, 2, 112, 720, 0xFD, 2, 9, 2, 0, 0)
    b[510:512] = b'\x55\xAA'
    im[0:512] = b
    for f in range(2):
        o = (1 + 2 * f) * 512
        im[o:o + 3] = b'\xFD\xFF\xFF'
    return bytes(im)


def scenario_basic_disque(image):
    """BIOS 2.3 : fichiers du BASIC sur la disquette A: et historique. BASIC ; Ctrl+] (terminal) :
    VIDE.IMG (360 Ko vierge) en A: ; 10 PRINT "BONJOUR" ; SAVE "ESSAI" ; FILES ; NEW ; LOAD
    "ESSAI" ; LIST ; fleche haut (rappel de LIST) + Entree ; SAVE "B2" ; KILL "B2.BAS" ; FILES.
    L'image relue sur la carte doit contenir ESSAI.BAS (le programme en texte) et pas B2.BAS."""
    import gen_sd
    import fatlib
    vide = disquette_vide_360k()
    secteurs, nb = gen_sd.carte_fat32([('VIDE.IMG', vide)])
    carte = CarteSD(secteurs, nb)
    tx = lambda c: bytes(c["ppi2"].tx)
    okn = lambda k: (lambda c: tx(c).endswith(b"Ok\r\n") and tx(c).count(b"Ok\r\n") >= k)
    fin_chg = b"A: change (Echap : rien).\r\n"
    cmds = [(au_menu, texte('6')), (okn(1), b"\x1d"),
            (lambda c: c["lcd"].lignes()[0].startswith("Disquette A:") and tx(c).rstrip().endswith(b"VIDE.IMG     360K"),
             Rafale(b"\x1b[B")),
            (lambda c: c["lcd"].lignes()[2].startswith(">VIDE") and b">VIDE" in tx(c)[-40:], b"\r"),
            (lambda c: tx(c).endswith(fin_chg), b'10 PRINT "BONJOUR"\r'),
            (lambda c: tx(c).endswith(b'10 PRINT "BONJOUR"\r\n'), b'SAVE "ESSAI"\r'),
            (okn(2), b"FILES\r"), (okn(3), b"NEW\r"), (okn(4), b'LOAD "ESSAI"\r'), (okn(5), b"LIST\r"),
            (okn(6), Rafale(b"\x1b[A")), (lambda c: b"\rLIST\x1b[K" in tx(c)[-20:], b"\r"),
            (okn(7), b'SAVE "B2"\r'), (okn(8), b'KILL "B2.BAS"\r'), (okn(9), b"FILES\r"),
            (okn(10), b"SYSTEM\r")]
    pas = Etapes(cmds)

    def fini(c):
        return pas.faites == len(pas.etapes) and au_menu(c)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, max_instr=300_000_000, sd=carte)
    t = tx({"ppi2": etat["ppi2"]})
    relu = gen_sd.lire_fichier(carte.s, 'VIDE.IMG')
    v = fatlib.Volume(relu) if relu else None
    noms = [c for c, a, d in v.fichiers()] if v else []
    essai = v.lire('ESSAI.BAS') if v else None
    print("--- etapes %d/%d ; disquette : %s ; ESSAI.BAS = %r" % (pas.faites, len(pas.etapes), noms, essai))
    print("    terminal : %r" % t[t.find(b'SAVE "ESSAI"'):][:700])
    ok = (essai == b'10 PRINT "BONJOUR"\r\n' and 'B2.BAS' not in noms and t.count(b'10 PRINT "BONJOUR"') >= 3
          and b"ESSAI.BAS" in t and b"\rLIST\x1b[K" in t)
    if not ok:
        print("    attendu : ESSAI.BAS ecrit, liste et relu ; LIST rappele par fleche haut ; B2.BAS efface")
    return verifier("BASIC : fichiers sur la disquette A: (SAVE, FILES, LOAD, KILL), fleche haut",
                    lcd, etat, MENU, ok)


def scenario_basic_boot(image):
    """BIOS 2.3 : BOOT "NOM" du BASIC : INT 13h AH=F0h monte DOS33.IMG en A: (nom en minuscules,
    sans extension : .IMG ajoute ; un nom absent -> File not found), puis INT 19h prepare le
    DOS (dos_charger, DS = CS pour ivt_init) et DOS 3.3 demarre (date)."""
    import gen_sd
    ici = os.path.dirname(os.path.abspath(__file__))
    dos33 = open(os.path.join(ici, '..', '..', '..', 'PC-DOS', 'Dos33-d1.IMG'), 'rb').read()
    secteurs, nb = gen_sd.carte_fat32([('DOS33.IMG', dos33)])
    carte = CarteSD(secteurs, nb)
    tx = lambda c: bytes(c["ppi2"].tx)
    pas = Etapes([(au_menu, texte('6')), (lambda c: tx(c).endswith(b"Ok\r\n"), b'BOOT "NONE"\r'),
                  (lambda c: tx(c).count(b"Ok\r\n") >= 2, b'BOOT "dos33"\r')])
    lcd, etat, uc = lancer(image, entrees=pas, dos=True, sd=carte, max_instr=400_000_000,
                           fini=lambda c: b"new date" in tx(c))
    t = tx({"ppi2": etat["ppi2"]})
    print("--- %r" % t[t.find(b'BOOT "NONE"'):][:200])
    ok = b'BOOT "NONE"\r\nFile not found' in t and b"new date" in t
    if not ok:
        print("    attendu : File not found pour NONE, puis DOS 3.3 demarre (date)")
    return verifier("BASIC : BOOT \"NOM.IMG\" (INT 13h AH=F0h puis INT 19h)", lcd, etat, None, ok)


def scenario_utf8_reset(image):
    """BIOS 2.3 : terminal en UTF-8 (PuTTY) : PRINT "àç" tape au terminal (chaque lettre
    accentuee = 2 octets d'un trait, C3 A0 puis C3 A7) arrive au BASIC en page 437 (85h 87h) et
    revient en UTF-8 (echo et resultat) ; Ctrl+Alt+Suppr au terminal (ESC [ 3 ; 7 ~) : retour
    au demarrage (banniere de nouveau)."""
    tx = lambda c: bytes(c["ppi2"].tx)
    ban = b"Solution-02 BIOS"
    ac = "àç".encode('utf-8')
    pas = Etapes([(au_menu, texte('6')),
                  (lambda c: tx(c).endswith(b"Ok\r\n"), b'PRINT "'),
                  (lambda c: tx(c).endswith(b'PRINT "'), Rafale("à".encode('utf-8'))),
                  (lambda c: tx(c).endswith("à".encode('utf-8')), Rafale("ç".encode('utf-8'))),
                  (lambda c: tx(c).endswith(ac), b'"\r'),
                  (lambda c: tx(c).count(b"Ok\r\n") >= 2, Rafale(b"\x1b[3;7~"))])
    lcd, etat, uc = lancer(image, entrees=pas, max_instr=60_000_000,
                           fini=lambda c: pas.faites == 6 and tx(c).count(ban) >= 2 and au_menu(c))
    t = tx({"ppi2": etat["ppi2"]})
    print("--- %r" % t[t.find(b"PRINT"):][:120])
    ok = b'PRINT "' + ac + b'"' in t and b"\r\n" + ac + b"\r\n" in t and t.count(ban) >= 2
    if not ok:
        print("    attendu : echo et resultat en UTF-8, puis redemarrage par Ctrl+Alt+Suppr (ESC [ 3 ; 7 ~)")
    return verifier("terminal UTF-8 -> page 437 (accents), Ctrl+Alt+Suppr au terminal", lcd, etat, MENU, ok)


def scenario_basic_chg(image):
    """BIOS 2.3 : dans le BASIC, la liste 'Disquette A:' s'ouvre par Ctrl+Alt+Inser (clavier PS/2),
    Ctrl+\\ et F12 (ESC [ 2 4 ~) au terminal ; Echap la referme chaque fois."""
    import gen_sd
    secteurs, nb = gen_sd.carte_fat32([('VIDE.IMG', disquette_vide_360k())])
    carte = CarteSD(secteurs, nb)
    tx = lambda c: bytes(c["ppi2"].tx)
    liste = lambda n: (lambda c: c["lcd"].lignes()[0].startswith("Disquette A:")
                       and tx(c).count(b"Disquette A:") >= n and tx(c).rstrip().endswith(b"360K"))
    fin = lambda n: (lambda c: tx(c).count(b"A: change (Echap : rien).") >= n)
    ctrl_alt_ins = [CTRL, ALT, 0xE0, 0x70, 0xE0, 0xF0, 0x70, 0xF0, ALT, 0xF0, CTRL]
    pas = Etapes([(au_menu, texte('6')), (lambda c: tx(c).endswith(b"Ok\r\n"), ctrl_alt_ins),
                  (liste(1), b"\x1b"), (fin(1), b"\x1c"), (liste(2), b"\x1b"),
                  (fin(2), Rafale(b"\x1b[24~")), (liste(3), b"\x1b"), (fin(3), b"SYSTEM\r")])
    lcd, etat, uc = lancer(image, entrees=pas, sd=carte, max_instr=120_000_000,
                           fini=lambda c: pas.faites == 8 and au_menu(c))
    t = tx({"ppi2": etat["ppi2"]})
    print("--- etapes %d/8 ; listes %d" % (pas.faites, t.count(b"Disquette A:")))
    ok = pas.faites == 8 and t.count(b"A: change (Echap : rien).") >= 3
    if not ok:
        print("    attendu : la liste par Ctrl+Alt+Inser, Ctrl+\\ et F12, refermee par Echap")
    return verifier("BASIC : changement de A: par Ctrl+Alt+Inser, Ctrl+\\, F12", lcd, etat, MENU, ok)


def scenario_nav_pave(image):
    """Maj + fleche dont le prefixe E0 est perdu (le BIOS voit la touche 8 du pave), puis
    Maj + 8 du pave : la fenetre du LCD doit remonter (Maj inverse Verr Num), sans '8'."""
    tx = lambda c: bytes(c["ppi2"].tx)
    vue = lambda c: bytes(c["uc"].mem_read(0x7F786, 2))[1]          # ligne du haut de la fenetre
    vu = {}
    sans_e0 = [MAJ, 0xE0, 0xF0, MAJ, 0x75, 0xE0, 0xF0, 0x75, 0xE0, MAJ, 0xF0, MAJ]
    pave = [MAJ, 0x75, 0xF0, 0x75, 0xF0, MAJ]

    def apres_dir(c):
        if invite(c, 2):
            vu["v0"] = vue(c)
            return True
        return False

    def fini(c):
        return pas.faites == len(pas.etapes) and vue(c) <= vu["v0"] - 2
    pas = Etapes([(au_menu, texte('1')),
                  (lambda c: b"Enter new date" in tx(c), b"\r"),
                  (lambda c: b"Enter new time" in tx(c), b"\r"),
                  (lambda c: invite(c, 1), b"dir\r"),
                  (apres_dir, sans_e0), (lambda c: vue(c) < vu["v0"], pave)])
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=150_000_000)
    lignes = [l.rstrip() for l in ecran_dos(uc) if l.strip()]
    print("--- fenetre : ligne %s -> %d ; derniere ligne du DOS : %r" % (vu.get("v0"), vue({"uc": uc}), lignes[-1:]))
    ok = etat["fin"] == "ok" and lignes[-1] == "A>"
    if not ok:
        print("    attendu : la fenetre remonte de 2 lignes, aucun '8' a l'invite")
    return verifier("Maj + fleche sans E0 et Maj + 8 du pave : navigation, pas de chiffre", lcd, etat, None, ok)


def scenario_son(image):
    """Son : melodie de demarrage au premier menu (compteur 2 + port 61h), puis silence."""
    lcd, etat, uc = lancer(image, fini=lambda c: au_menu(c) and len(c["etat"]["hp"]) >= 9 and c["etat"]["n"] > 1_500_000,
                           max_instr=6_000_000)
    pit, hp = etat["pit"], etat["hp"]
    notes = [d for n, d in pit.notes]
    p61 = [v & 3 for n, v in hp]
    print("--- diviseurs du compteur 2 : %s ; port 61h (bits 0-1) : %s" % (notes, p61))
    ok = notes == [5096, 4045, 3401, 2548] and p61 == [0, 3, 0, 3, 0, 3, 0, 3, 0]
    if ok:                                     # durees : 6, 6, 6, 14 IRQ0 (instructions entre 3 et 0)
        durees = [hp[i + 1][0] - hp[i][0] for i in range(1, 9, 2)]
        print("    durees des notes (instructions) : %s" % durees)
        ok = durees[3] > 2 * durees[0]
    else:
        print("    attendu : 5096, 4045, 3401, 2548 (do5 mi5 sol5 do6) ; 61h : 0 puis 3/0 par note")
    return verifier("son : melodie de demarrage (8253 compteur 2, port 61h)", lcd, etat, MENU, ok)


def scenario_partout(image):
    """Console UART hors DOS : menu 5 au clavier PS/2 -> le menu sur TX ; '4' tape au
    terminal -> Info sur le LCD et sur TX ; une touche du terminal -> retour au menu."""
    tx = lambda c: bytes(c["ppi2"].tx)
    on = lambda c: c["lcd"].lignes()[3] == "4) Info  5) UART:ON "
    info = lambda c: c["lcd"].lignes()[0] == "SOLUTION-02 BIOS 2.9" and c["lcd"].lignes()[3].startswith("8259")
    vu = {}

    def menu_vu(c):
        return MENU_TX in tx(c)

    def fini(c):
        if info(c):
            vu["info"] = True
        return vu.get("info") and au_menu_on(c) and tx(c).count(b"4) Info  5) UART:ON\r\n") >= 2
    pas = Etapes([(lambda c: au_menu(c) and menu_vu(c), b"4"),
                  (lambda c: info(c) and b"8259+8253 OK I7 0000" in tx(c), b" ")])
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, max_instr=40_000_000)
    t = bytes(etat["ppi2"].tx)[len(BANNIERE):]
    print("--- UART TX apres la banniere : %r" % t)
    import gen_accueil                         # ecran d'accueil ANSI, puis le menu
    attendu = gen_accueil.octets() + MENU_TX + (
               b"\r\nSOLUTION-02 BIOS 2.9\r\nCPU 8088    5.33 MHz\r\nRAM 512Ko  ROM 256Ko\r\n8259+8253 OK I7 0000\r\n") + MENU_TX
    ok = t == attendu
    if not ok:
        print("    attendu : %r" % attendu)
    return verifier("console UART hors DOS : menu et Info sur TX, touches du terminal", lcd, etat, MENU_ON, ok)


MENU_ON = MENU
au_menu_on = lambda c: c["lcd"].lignes() == MENU_ON


def scenario_dos_uart(image, titre, commandes, verif, max_instr=300_000_000, invites=None):
    """Console UART (menu 5), Load DOS, date et heure (Entree), puis les commandes
    [(condition sur l'ecran du DOS, octets tapes au terminal)] ; verif(ecran, etat) -> ok."""
    tx = lambda c: bytes(c["ppi2"].tx)
    on = lambda c: c["lcd"].lignes()[3] == "4) Info  5) UART:ON " and b"5) UART:ON\r\n" in bytes(c["ppi2"].tx)  # menu envoye
    pas = Etapes([(au_menu, texte('1')),
                  (lambda c: b"Enter new date" in tx(c), b"\r"),
                  (lambda c: b"Enter new time" in tx(c), b"\r")] + commandes)

    def fini(c):
        return pas.faites == len(pas.etapes) and invite(c, invites or len(commandes) + 1)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=max_instr)
    ecran = bytes(etat["ppi2"].tx).decode('latin1').replace('\r', '').split('\n')   # tout ce qu'a ecrit le DOS
    print("--- ecran du DOS (fin) :")
    for l in ecran[-14:]:
        print("    |%s|" % l)
    ok = verif(ecran, etat)
    return verifier(titre, lcd, etat, None, ok)


def lignes_dos(uc):
    return [l.rstrip() for l in ecran_dos(uc) if l.strip()]


def invite(c, n):
    """Au moins n invites A> recues sur TX (console UART) et le DOS attend (TX finit par A>)."""
    t = bytes(c["ppi2"].tx)
    return t.endswith(b"\r\nA>") and t.count(b"\r\nA>") >= n


def scenario_temps(image):
    """8254 : l'heure du DOS avance (TIME apres DIR), les DEL bougent sous DOS (IRQ0)."""
    vu = {}

    def apres(c):
        if "s0" not in vu:
            vu["s0"] = c["etat"]["ppi"].sorties
        return invite(c, 2)
    cmds = [(lambda c: invite(c, 1), b"dir\r"), (apres, b"time\r"),
            (lambda c: bytes(c["ppi2"].tx).count(b"Enter new time:") >= 2, b"\r")]

    def verif(ecran, etat):
        heures = [l for l in ecran if l.startswith("Current time is")]
        print("    %s ; sorties du 8255 U7 pendant le DOS : %d" % (heures, etat["ppi"].sorties - vu.get("s0", 0)))
        ok = len(heures) >= 2 and heures[-1] not in ("Current time is  0:00:00.00", heures[0])
        if not ok:
            print("    attendu : la 2e heure affichee par TIME differe de la 1re")
        if etat["ppi"].sorties - vu.get("s0", 0) < 30:
            ok = False
            print("    attendu : les animations continuent sous DOS (sorties vers U7)")
        return ok
    return scenario_dos_uart(image, "8254 : heure du DOS qui avance, DEL animees sous DOS", cmds, verif,
                             invites=3)


def scenario_disque_b(image):
    """Lecteur B: (disque virtuel de 128 Ko) : DIR B:, COPY EDLIN.COM B:, DIR B:."""
    cmds = [(lambda c: invite(c, 1), b"dir b:\r"), (lambda c: invite(c, 2), b"copy edlin.com b:\r"),
            (lambda c: invite(c, 3), b"dir b:\r")]

    def verif(ecran, etat):
        e = "\n".join(ecran)
        ok = True
        for attendu in ("1 File(s) copied", "EDLIN    COM     4608", "122880 bytes free"):
            if attendu not in e:
                ok = False
                print("    attendu dans l'ecran : %r" % attendu)
        return ok
    return scenario_dos_uart(image, "lecteur B: en RAM : DIR, COPY, DIR", cmds, verif)


def scenario_dos(image):
    """Menu 1 : PC-DOS 2.1 demarre depuis la ROM ; date et heure (Entree), puis DIR, puis
    Maj + fleches (fenetre du LCD), puis Ctrl + Alt + Suppr (retour au menu)."""
    ecran = lambda c: "\n".join(ecran_dos(c["uc"]))

    vu = {}

    def invites(c):
        n = ecran(c).count("A>")
        if n and "accueil" not in vu:
            vu["accueil"] = ecran(c)                     # avant DIR (qui fera defiler)
            vu["car_avant_dir"] = c["lcd"].donnees
        return n

    def fenetre(c):
        """Apres DIR : la fenetre montre les 4 dernieres lignes ; on note le LCD."""
        e = ecran(c)
        if "bytes free" in e and e.rstrip().endswith("A>") and c["lcd"].lignes()[3].startswith("A>"):
            # (le tampon est ecrit avant le LCD : attendre que '>' y soit aussi)
            vu.setdefault("apres_dir", c["lcd"].lignes())
            vu.setdefault("car_dir", c["lcd"].donnees - vu["car_avant_dir"])
            return True
        return False

    def deplacee(c):
        if c["lcd"].lignes() != vu.get("apres_dir"):
            vu.setdefault("haut", c["lcd"].lignes())
            return True
        return False

    def droite(c):
        if c["lcd"].lignes() != vu.get("haut"):
            vu.setdefault("droite", (c["lcd"].lignes(), bytes(c["uc"].mem_read(0x7F786, 2))))
            vu.setdefault("ecran", ecran_dos(c["uc"]))      # avant Ctrl+Alt+Suppr
            return True
        return False

    def suivi(c):
        """Commande tapee plus longue que 20 colonnes : la fenetre suit la saisie."""
        if c["lcd"].lignes()[3] == SAISIE_VUE:
            vu.setdefault("saisie", (c["lcd"].lignes(), bytes(c["uc"].mem_read(0x7F786, 2))))
            vu.setdefault("perdues", c["ppi2"].perdues)  # avant Ctrl+Alt+Suppr (au redemarrage,
            return True                                   # interruptions masquees : relachements perdus)
        return False

    pas = Etapes([
        (au_menu, texte('1')),
        (lambda c: "Enter new date" in ecran(c), texte('\r')),
        (lambda c: "Enter new time" in ecran(c), texte('\r')),
        (lambda c: invites(c) >= 1, texte('dir\r')),
        (fenetre, maj_fleche('haut') + maj_fleche('haut', 0x59) + maj_fleche('haut', appui_perdu=True)),
        (deplacee, maj_fleche('droite', 0x59)),
        (droite, texte(SAISIE)),
        (suivi, [CTRL, ALT] + appui(0x71, True) + [0xF0, ALT, 0xF0, CTRL]),
    ])

    def fini(c):
        return pas.faites == len(pas.etapes) and au_menu(c)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=200_000_000)
    lignes = vu.get("ecran") or ecran_dos(uc)
    print("--- ecran du DOS avant Ctrl+Alt+Suppr (tampon 24 x 80, lignes non vides) :")
    for l in lignes:
        if l.strip():
            print("    |%s|" % l.rstrip())
    print("    caracteres envoyes au LCD pendant DIR : %s" % vu.get("car_dir"))
    if vu.get("car_dir") is None or vu["car_dir"] > CAR_DIR_MAX:
        ok_lcd = False
        print("    attendu : au plus %d (seules les 20 colonnes de la fenetre vont au LCD)" % CAR_DIR_MAX)
    else:
        ok_lcd = True
    for cle in ("apres_dir", "haut"):
        print("    LCD %-9s: %s" % (cle, vu.get(cle)))
    if "droite" in vu:
        print("    LCD droite   : %s (fenetre col,ligne = %d,%d)" % (vu["droite"][0], vu["droite"][1][0], vu["droite"][1][1]))
    if "saisie" in vu:
        print("    LCD saisie   : %s (fenetre col,ligne = %d,%d)" % (vu["saisie"][0], vu["saisie"][1][0], vu["saisie"][1][1]))
    ints = etat["ints"]
    print("    INT appelees : %s" % " ".join("%02Xh x%d" % (k, v) for k, v in sorted(ints.items())))
    non_geres = {k: v for k, v in etat["int_iret"].items() if k < 0x20 and k != 0x1C}   # 1Ch : crochet des programmes
    print("    vecteurs BIOS non geres appeles : %s ; ecritures en ROM : %d" % (non_geres or "aucun", etat["ecritures_rom"]))
    print("    OUT du DOS vers le LCD/U7/U12 : %s ; vers des ports libres : %s" % (
        {"%02Xh" % k: v for k, v in etat["out_dos"].items()} or "aucun",
        {"%02Xh" % k: v for k, v in etat["out_libres"].items()} or "aucun"))
    p2 = etat["ppi2"]
    perdues = vu.get("perdues", p2.perdues)
    print("    clavier : %d trame(s) perdue(s) avant Ctrl+Alt+Suppr (%d en tout), %d interrompue(s) puis renvoyee(s)"
          % (perdues, p2.perdues, p2.interrompues))
    texte_ecran = "\n".join(lignes)
    ok = ok_lcd and not perdues
    if perdues:
        print("    attendu : aucune trame perdue avant Ctrl+Alt+Suppr")
    print("    accueil du DOS : %r" % [l.strip() for l in vu.get("accueil", "").splitlines() if l.strip()][-4:])
    if "Version 2.10" not in vu.get("accueil", ""):
        ok = False
        print("    attendu avant DIR : 'Version 2.10'")
    for attendu in ("MASM     EXE    67840", "LINK     EXE    41216", "6 File(s)", "bytes free"):
        if attendu not in texte_ecran:
            ok = False
            print("    attendu dans l'ecran : %r" % attendu)
    if vu.get("apres_dir") is None or not vu["apres_dir"][3].startswith("A>"):
        ok = False
        print("    attendu : apres DIR, l'invite A> en derniere ligne du LCD")
    if vu.get("haut") is None or vu["haut"][3] != vu["apres_dir"][0]:
        ok = False
        print("    attendu : Maj + haut x3 (gauche, droite, gauche sans son appui) -> la 1re ligne"
              " d'avant descend en ligne 4")
    if vu.get("droite") is None or vu["droite"][1][0] != NAV_C:
        ok = False
        print("    attendu : Maj + droite -> fenetre en colonne %d" % NAV_C)
    if vu.get("saisie") is None or vu["saisie"][1][0] != 20:
        ok = False
        print("    attendu : 'A>%s' tape -> fenetre en colonne 20, ligne 4 du LCD = %r" % (SAISIE, SAISIE_VUE))
    if non_geres or etat["out_dos"]:
        ok = False
    return verifier("menu 1) Load DOS : PC-DOS 2.1 en ROM, DIR, Maj + fleches, Ctrl+Alt+Suppr", lcd, etat, MENU, ok)


NAV_C = 10
SAISIE = "rem 0123456789012345678901234"     # curseur en colonne 31 apres "A>"
SAISIE_VUE = "45678901234         "           # colonnes 20 a 39
CAR_DIR_MAX = 6000      # DIR : ~30 lignes x (20 car. + 80 de redessin) ; la fenetre qui suivrait
                        # le curseur jusqu'en colonne 39 en enverrait des dizaines de milliers


def main():
    image = sys.argv[1] if len(sys.argv) > 1 else "build/solution-02-bios.bin"
    seul = sys.argv[2] if len(sys.argv) > 2 else None
    scenarios = [
        ("menu", lambda: scenario_menu(image)),
        ("ram", lambda: scenario_ram_s01(image, "menu 2) Test RAM (Solution-01), MAP, RAM saine", '2',
            [b"*** RAM OK - 524288 octets", b"RAM testee: 512 Ko", b"Defectueuse: 0 Ko", b"A0-A18 OK", b"TOTAL DEFAUT: 0000h"],
            "RAM OK")),
        ("defaut", lambda: scenario_ram_s01(image, "menu 2) Test RAM (Solution-01), Trace, cellule 7B3FFh qui ne retient rien", '1',
            [b"DEFAUT memoire @ 7000:B3FF  attendu=AA  lu=00", b"7000:B000-7000:B3FF", b"RAM DEFECTUEUSE", b"TOTAL DEFAUT: 0001h, 1 octet"],
            "RAM DEFECTUEUSE", defaut=lambda a: a == 0x7B3FF, max_instr=400_000_000)),
        ("ramboucle", lambda: scenario_ram_boucle(image)),
        ("absente", lambda: scenario_ram_defaut(image, "RAM absente (DSEG defectueux : test complet d'office)",
            ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 512", "Adresses: ERR base  ", "ERR 00000 AA/00     "],
            defaut=lambda a: a < RAM, touche=False)),
        ("a15", lambda: scenario_ram_s01(image, "menu 2) Test RAM, MAP, ligne A15 coupee (8000h repond comme 0)", '2',
            [b"LIGNE D'ADRESSE A15 EN DEFAUT", b"octet par octet SAUTE"], "RAM DEFECTUEUSE", alias=1 << 15)),
        ("a17", lambda: scenario_ram_s01(image, "menu 2) Test RAM, MAP, puce de 128 Ko (A17 ignoree)", '2',
            [b"LIGNE D'ADRESSE A17 EN DEFAUT", b"octet par octet SAUTE"], "RAM DEFECTUEUSE", alias=1 << 17)),
        ("led", lambda: scenario_led(image)),
        ("terminal", lambda: scenario_terminal(image)),
        ("led8254", lambda: scenario_led(image, pit=False)),
        ("sysinfo", lambda: scenario_sysinfo(image)),
        ("sans8259", lambda: scenario_sysinfo(image, pic=False)),
        ("sans8254", lambda: scenario_sysinfo(image, pit=False)),
        ("partout", lambda: scenario_partout(image)),
        ("son", lambda: scenario_son(image)),
        ("basic", lambda: scenario_basic(image)),
        ("basicdisque", lambda: scenario_basic_disque(image)),
        ("basicboot", lambda: scenario_basic_boot(image)),
        ("utf8", lambda: scenario_utf8_reset(image)),
        ("basicchg", lambda: scenario_basic_chg(image)),
        ("navpave", lambda: scenario_nav_pave(image)),
        ("accents", lambda: scenario_accents(image)),
        ("disquec", lambda: scenario_disque_c(image)),
        ("changea", lambda: scenario_change_a(image)),
        ("diagsd", lambda: scenario_diag_sd(image)),
        ("sdboot", lambda: scenario_sd_boot(image)),
        ("sdfrag", lambda: scenario_sd_fragmentee(image)),
        ("romb", lambda: scenario_rom_b(image)),
        ("dos", lambda: scenario_dos(image)),
        ("anticipe", lambda: scenario_anticipe(image)),
        ("console", lambda: scenario_console(image)),
        ("temps", lambda: scenario_temps(image)),
        ("disqueb", lambda: scenario_disque_b(image)),
    ]
    echecs = 0
    for nom, f in scenarios:
        if seul == nom or (seul is None and nom not in ("diagsd",)):   # diagsd : ROM make diagsd
            echecs += not f()
    print("\n%d scenario(s) en echec" % echecs)
    sys.exit(1 if echecs else 0)


if __name__ == "__main__":
    main()
