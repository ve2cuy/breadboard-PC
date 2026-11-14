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
        self.dernier = None          # (n instr, delai exige)
        self.erreurs = []
        self.fonction = 0            # nombre de "function set" recus

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
                exige = D_EFFACER
            elif val & 0x80:
                self.ac = val & 0x7F
            elif val & 0x20:
                self.fonction += 1
                if self.fonction == 1:
                    exige = D_FONCTION1
                if val & 0x10 == 0:
                    self.erreurs.append("function set %02Xh : mode 4 bits" % val)
            elif val & 0x08:
                self.allume = bool(val & 0x04)
        elif port == 1:
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


class PPI2:
    """2e 8255 (U12) en 30h-33h : clavier PS/2 sur PB0 (horloge) / PB1 (donnees), UART logiciel
    TX = PA7 / RX = PB2, blocage du clavier par PC0 (diode de KBD_CLK vers PC0).
    - Sortie : chaque ecriture de PA est un bit de la trame serie (depart, 8 donnees, arret) ;
      les octets emis sont decodes dans self.tx, la duree d'un bit (en instructions) est mesuree.
    - Clavier : comme un vrai clavier, une trame part a son heure, que le BIOS ecoute ou non
      (une trame passee sans etre lue est perdue). Si `diode`, PC0 = 0 bloque l'horloge : le
      clavier attend (au moins T_LIBRE apres le relachement) ; une trame bloquee avant son
      10e bit est interrompue et renvoyee.
    - UART : un octet programme demarre a la premiere lecture de PB qui suit son heure."""
    P_PS2 = 30                                # demi-periode de l'horloge PS/2 (instructions)
    T_LIBRE = 50                              # delai du clavier apres le relachement

    def __init__(self, diode=True):
        self.ctrl = None
        self.erreurs = []
        self.tx = bytearray()
        self.etat_tx = None                   # None = repos ; sinon liste des bits recus
        self.dernier_tx = None
        self.periodes = []
        self.attente = []                     # (heure, 'ps2'|'uart', octet)
        self.trame = None                     # (debut, 'ps2'|'uart', bits, octet)
        self.lectures = 0
        self.diode = diode
        self.pc0 = 1
        self.libre_depuis = 0
        self.fin_trame = 0                    # fin de la derniere trame PS/2 (+ un bit de repos)
        self.perdues = 0                      # trames PS/2 passees sans etre lues
        self.interrompues = 0

    def bit_uart(self):
        p = sorted(self.periodes)
        return p[len(p) // 2] if p else None

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
                self.fin_trame = n
                self.interrompues += 1
                self.attente.insert(0, (n, 'ps2', octet))

    def ecrire(self, port, val, n):
        if port == 0x33:
            if val & 0x80:
                self.ctrl = val
                if val != 0x82:
                    self.erreurs.append("mot de controle de U12 %02Xh (82h attendu)" % val)
                self._pc0(0, n)                # le mot de mode remet les sorties a 0
            elif (val >> 1) & 7 == 0:          # BSR sur PC0
                self._pc0(val & 1, n)
            return
        if self.ctrl != 0x82:
            self.erreurs.append("sortie en %02Xh avant le mot de controle de U12" % port)
        if port == 0x32:
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

    def _suivante(self, n):
        """Demarre la prochaine trame si son heure est venue (au besoin dans le passe)."""
        while self.trame is None and self.attente and self.attente[0][0] <= n:
            heure, genre, octet = self.attente[0]
            if genre == 'uart':
                self.attente.pop(0)
                bits = [0] + [(octet >> i) & 1 for i in range(8)] + [1]
                self.trame = (n, genre, bits, octet)
                return
            if self.bloque():
                return
            debut = max(heure, self.libre_depuis + self.T_LIBRE, self.fin_trame)
            if debut > n:
                return
            self.attente.pop(0)
            bits = [0] + [(octet >> i) & 1 for i in range(8)]
            bits += [1 - (sum(bits) & 1), 1]               # parite impaire, arret
            self.fin_trame = debut + (len(bits) + 1) * 2 * self.P_PS2
            if n - debut >= len(bits) * 2 * self.P_PS2:    # passee sans etre lue
                self.perdues += 1
                continue
            self.trame = (debut, genre, bits, octet)

    def lire(self, port, n):
        if port != 0x31:
            return 0xFF
        self.lectures += 1
        clk = data = rx = 1
        for _ in range(2):
            self._suivante(n)
            if not self.trame:
                break
            debut, genre, bits, octet = self.trame
            t = n - debut
            if genre == 'ps2':
                i, phase = divmod(t, 2 * self.P_PS2)
                if i >= len(bits):
                    self.trame = None          # finie : la suivante peut deja avoir commence
                    continue
                data = bits[i]
                clk = 1 if phase < self.P_PS2 else 0
            else:
                b = self.bit_uart() or 36
                i = t // b
                if i >= len(bits):
                    self.trame = None
                else:
                    rx = bits[i]
            break
        if self.bloque():
            clk = 0
        return 0xF8 | (rx << 2) | (data << 1) | clk

def sortie_port(lcd, ppi, port, val, n, ppi2=None):
    if port in (0, 1):
        lcd.ecrire(port, val, n)
    elif 0x10 <= port <= 0x13:
        ppi.ecrire(port, val)
    elif 0x30 <= port <= 0x33 and ppi2 is not None:
        ppi2.ecrire(port, val, n)
    else:
        lcd.erreurs.append("OUT vers le port %02Xh" % port)


# ---- clavier PS/2 (jeu 2) ----------------------------------------------------------------
CODES = {'1': 0x16, '2': 0x1E, '3': 0x26, '4': 0x25, 'a': 0x1C, 'b': 0x32, 'd': 0x23, 'e': 0x24,
         'i': 0x43, 'r': 0x2D, 'v': 0x2A, ' ': 0x29, '\r': 0x5A, '\x1b': 0x76, '\b': 0x66}
MAJ, CTRL, ALT = 0x12, 0x14, 0x11
FLECHES = {'haut': 0x75, 'bas': 0x72, 'gauche': 0x6B, 'droite': 0x74}


def appui(code, etendu=False):
    """Trame(s) d'un appui-relachement."""
    p = [0xE0] if etendu else []
    return p + [code] + p + [0xF0, code]


def texte(t):
    return [c for ch in t for c in appui(CODES[ch])]


def maj_fleche(nom):
    """Maj + fleche, comme un vrai clavier (Verr Num inactif pour lui) : Maj, puis la fleche
    precedee d'un relachement FACTICE de Maj (E0 F0 12) et suivie d'un appui factice (E0 12)."""
    c = FLECHES[nom]
    return [MAJ, 0xE0, 0xF0, 0x12, 0xE0, c, 0xE0, 0xF0, c, 0xE0, 0x12, 0xF0, MAJ]


def programmer_codes(ppi2, n, codes):
    t = n
    for i, code in enumerate(codes):
        suite = code in (0xF0, 0xE0) or (i and codes[i - 1] in (0xF0, 0xE0))
        t += 3000 if suite else 30000
        ppi2.programmer(t, 'ps2', code)
    return t


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
        cond, action = self.etapes[self.faites]
        if cond(ctx):
            self.faites += 1
            if isinstance(action, bytes):
                t = n
                for c in action:
                    t += 30000
                    ppi2.programmer(t, 'uart', c)
            else:
                t = programmer_codes(ppi2, n, action)
            self.libre = t + 60000


MENU = ["1) Load DOS         ", "2) Test memory      ", "3) LED Show         ", "4) SysInfo          "]


def au_menu(ctx):
    return ctx["lcd"].lignes() == MENU


def ecran_dos(uc):
    """Tampon d'ecran du BIOS (DSEG:0000, 24 x 80) en lignes de texte."""
    b = bytes(uc.mem_read(0x7F000, 24 * 80))
    return [b[i * 80:(i + 1) * 80].decode('latin1') for i in range(24)]


def lancer(image, defaut=None, alias=None, max_instr=80_000_000, fini=None, entrees=None, dos=False,
           diode=True):
    """defaut(a) : la cellule a ne retient rien ; alias : la RAM ignore cette ligne d'adresse
    (une ecriture en a atteint aussi a ^ alias). fini(ctx) arrete la simulation ; entrees(ctx)
    est appelee a chaque lecture de PB de U12 (pour programmer des trames).
    dos : les ecritures en ROM sont ignorees (comptees) au lieu d'arreter la simulation."""
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
    etat = {"n": 0, "restaurer": [], "fin": None, "ppi": ppi, "ppi2": ppi2, "ecritures_rom": 0,
            "ints": {}, "int_iret": {}, "out_dos": {}, "out_libres": {}}
    ctx = {"uc": uc, "lcd": lcd, "ppi2": ppi2, "etat": etat}

    def code(uc, adr, taille, ud):
        for a, v in etat["restaurer"]:       # ecriture annulee (cellule defectueuse, ROM)
            uc.mem_write(a, bytes([v]))
        etat["restaurer"] = []
        etat["n"] += 1
        if etat["n"] > max_instr:
            etat["fin"] = "limite d'instructions atteinte"
            uc.emu_stop()

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
        if cs != 0xF000:                     # OUT du DOS ou d'un programme : seuls O0, O1 et O3
            if (port & 0x80) == 0 and (port >> 4) & 7 in (0, 1, 3):   # du 138 atteignent un circuit
                etat["out_dos"][port] = etat["out_dos"].get(port, 0) + 1
            else:
                etat["out_libres"][port] = etat["out_libres"].get(port, 0) + 1
            return
        sortie_port(lcd, ppi, port, val & 0xFF, etat["n"], ppi2)
        if fini and fini(ctx):
            etat["fin"] = "ok"
            uc.emu_stop()

    def entree(uc, port, taille, ud):
        if entrees and port == 0x31:
            entrees(ctx)
        return ppi2.lire(port, etat["n"]) if 0x30 <= port <= 0x33 else 0xFF

    def interruption(uc, num, ud):          # aiguillage du mode reel (Unicorn ne le fait pas)
        off, seg = struct.unpack('<HH', bytes(uc.mem_read(num * 4, 4)))
        etat["ints"][num] = etat["ints"].get(num, 0) + 1
        if uc.mem_read(seg * 16 + off, 1)[0] == 0xCF:   # IRET : vecteur non gere
            etat["int_iret"][num] = etat["int_iret"].get(num, 0) + 1
        fl = uc.reg_read(UC_X86_REG_EFLAGS)
        ss, sp = uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP)
        for v in (fl & 0xFFFF, uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP)):
            sp = (sp - 2) & 0xFFFF
            uc.mem_write(ss * 16 + sp, struct.pack('<H', v))
        uc.reg_write(UC_X86_REG_SP, sp)
        uc.reg_write(UC_X86_REG_EFLAGS, fl & ~0x300)
        uc.reg_write(UC_X86_REG_CS, seg)
        uc.reg_write(UC_X86_REG_IP, off)

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
    print("    =>", "OK" if ok else "ECHEC")
    return ok


BANNIERE = (b"\r\nSolution-02 BIOS 0.6 - VE2CUY 2026\r\n"
            b"Menu (clavier PS/2) : 1) Load DOS  2) Test memory  3) LED Show  4) SysInfo\r\n")
RAM_OK = ["MEMOIRE 512 Ko : OK ", "Ko: 512  Defauts 000", "Adresses A0-A18: OK ", "PILE OK  Touche=menu"]
echec_ram = lambda ctx: ctx["lcd"].lignes()[0].endswith("CPT 0003")


def scenario_menu(image):
    lcd, etat, uc = lancer(image, fini=au_menu)
    p2 = etat["ppi2"]
    ok = True
    ss, sp = uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP)
    print("--- (pile SS:SP = %04X:%04X ; UART TX : bit = %s instructions, %r)" % (ss, sp, p2.bit_uart(), bytes(p2.tx)[:50]))
    if ss != 0x7F00 or sp < 0x0F00:
        ok = False
        print("    attendu: pile en 7F00:1000 (ou presque)")
    if bytes(p2.tx) != BANNIERE:
        ok = False
        print("    attendu: %r" % BANNIERE)
    return verifier("demarrage : ecran d'ouverture, DSEG, banniere, menu", lcd, etat, MENU, ok)


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


def scenario_led(image):
    lcd, etat, uc = lancer(image, fini=lambda c: c["lcd"].lignes()[1].endswith("0001"),
                           entrees=Etapes([(au_menu, texte('3'))]))
    ppi = etat["ppi"]
    print("--- 8255 : %d sorties, DEL vues allumees %s, eteintes %s" % (
        ppi.sorties, ["%02X" % v for v in ppi.allumees], ["%02X" % v for v in ppi.eteintes]))
    ok = ppi.toutes_vues()
    if not ok:
        print("    attendu: chacune des 24 DEL allumee et eteinte au moins une fois")
    return verifier("menu 3) LED Show : un cycle complet d'animations", lcd, etat,
                    ["LED SHOW  Echap=menu", "Chenillard      0001", "Clavier PS/2 >      ", "UART 9600 8N1 >     "], ok)


# LED Show : Maj+a, b, 1, retour arriere, fleche haut ; "Hi" recu sur l'UART ; Echap
CLAVIER = [MAJ] + appui(0x1C) + [0xF0, MAJ] + texte('b1\b') + appui(0x75, True)
TX_ATTENDU = b"Ab1\x08 \x08\x1b[AHi"


def scenario_terminal(image):
    vu = {"lignes": None}
    lance = lambda c: c["lcd"].lignes()[0] == "LED SHOW  Echap=menu" and c["ppi2"].lectures > 2000

    def ecrit(c):
        l = c["lcd"].lignes()
        if l[3].startswith("Hi") and vu["lignes"] is None:
            vu["lignes"] = l
        return vu["lignes"] is not None

    pas = Etapes([(au_menu, texte('3')), (lance, CLAVIER), (lance, b"Hi"), (ecrit, texte('\x1b'))])

    def fini(c):
        ecrit(c)
        return vu["lignes"] is not None and c["lcd"].lignes() == MENU
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas)
    p2 = etat["ppi2"]
    recu = bytes(p2.tx)[len(BANNIERE):]
    print("--- LED Show : lignes vues %s ; UART TX apres la banniere : %r" % (vu["lignes"], recu))
    ok = bool(vu["lignes"]) and vu["lignes"][2] == "Ab                  " and vu["lignes"][3] == "Hi                  "
    if recu != TX_ATTENDU:
        ok = False
        print("    attendu: %r" % TX_ATTENDU)
    return verifier("menu 3) terminal clavier + UART, Echap = retour au menu", lcd, etat, MENU, ok)


def scenario_sysinfo(image):
    vu = {"l": None}

    def fini(c):
        l = c["lcd"].lignes()
        if l[0] == "SOLUTION-02 BIOS 0.6" and l[3].startswith("A:"):
            vu["l"] = l
        return vu["l"] is not None and l == MENU
    pas = Etapes([(au_menu, texte('4')), (lambda c: c["lcd"].lignes()[3].startswith("A:"), texte(' '))])
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas)
    attendu = ["SOLUTION-02 BIOS 0.6", "CPU 8088    5.33 MHz", "RAM 512Ko  ROM 256Ko", "A: PC-DOS 2.1  180Ko"]
    ok = vu["l"] == attendu
    print("--- SysInfo vu : %s" % vu["l"])
    if not ok:
        print("    attendu : %s" % attendu)
    return verifier("menu 4) SysInfo puis retour au menu", lcd, etat, MENU, ok)


def scenario_dos(image):
    """Menu 1 : PC-DOS 2.1 demarre depuis la ROM ; date et heure (Entree), puis DIR, puis
    Maj + fleches (fenetre du LCD), puis Ctrl + Alt + Suppr (retour au menu)."""
    ecran = lambda c: "\n".join(ecran_dos(c["uc"]))

    vu = {}

    def invites(c):
        n = ecran(c).count("A>")
        if n and "accueil" not in vu:
            vu["accueil"] = ecran(c)                     # avant DIR (qui fera defiler)
        return n

    def fenetre(c):
        """Apres DIR : la fenetre montre les 4 dernieres lignes ; on note le LCD."""
        e = ecran(c)
        if "bytes free" in e and e.rstrip().endswith("A>"):
            vu.setdefault("apres_dir", c["lcd"].lignes())
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

    pas = Etapes([
        (au_menu, texte('1')),
        (lambda c: "Enter new date" in ecran(c), texte('\r')),
        (lambda c: "Enter new time" in ecran(c), texte('\r')),
        (lambda c: invites(c) >= 1, texte('dir\r')),
        (fenetre, maj_fleche('haut') + maj_fleche('haut') + maj_fleche('haut')),
        (deplacee, maj_fleche('droite')),
        (droite, [CTRL, ALT] + appui(0x71, True) + [0xF0, ALT, 0xF0, CTRL]),
    ])

    def fini(c):
        return pas.faites == len(pas.etapes) and au_menu(c)
    lcd, etat, uc = lancer(image, fini=fini, entrees=pas, dos=True, max_instr=200_000_000)
    lignes = vu.get("ecran") or ecran_dos(uc)
    print("--- ecran du DOS avant Ctrl+Alt+Suppr (tampon 24 x 80, lignes non vides) :")
    for l in lignes:
        if l.strip():
            print("    |%s|" % l.rstrip())
    for cle in ("apres_dir", "haut"):
        print("    LCD %-9s: %s" % (cle, vu.get(cle)))
    if "droite" in vu:
        print("    LCD droite   : %s (fenetre col,ligne = %d,%d)" % (vu["droite"][0], vu["droite"][1][0], vu["droite"][1][1]))
    ints = etat["ints"]
    print("    INT appelees : %s" % " ".join("%02Xh x%d" % (k, v) for k, v in sorted(ints.items())))
    non_geres = {k: v for k, v in etat["int_iret"].items() if k < 0x20}
    print("    vecteurs BIOS non geres appeles : %s ; ecritures en ROM : %d" % (non_geres or "aucun", etat["ecritures_rom"]))
    print("    OUT du DOS vers le LCD/U7/U12 : %s ; vers des ports libres : %s" % (
        {"%02Xh" % k: v for k, v in etat["out_dos"].items()} or "aucun",
        {"%02Xh" % k: v for k, v in etat["out_libres"].items()} or "aucun"))
    p2 = etat["ppi2"]
    print("    clavier : %d trame(s) perdue(s), %d interrompue(s) puis renvoyee(s)" % (p2.perdues, p2.interrompues))
    texte_ecran = "\n".join(lignes)
    ok = not p2.perdues
    if p2.perdues:
        print("    attendu : aucune trame perdue")
    print("    accueil du DOS : %r" % [l.strip() for l in vu.get("accueil", "").splitlines() if l.strip()][-4:])
    if "Version 2.10" not in vu.get("accueil", ""):
        ok = False
        print("    attendu avant DIR : 'Version 2.10'")
    for attendu in ("BASICA   COM    26112", "23 File(s)", "bytes free"):
        if attendu not in texte_ecran:
            ok = False
            print("    attendu dans l'ecran : %r" % attendu)
    if vu.get("apres_dir") is None or not vu["apres_dir"][3].startswith("A>"):
        ok = False
        print("    attendu : apres DIR, l'invite A> en derniere ligne du LCD")
    if vu.get("haut") is None or vu["haut"][3] != vu["apres_dir"][0]:
        ok = False
        print("    attendu : Maj + haut x3 -> la 1re ligne d'avant descend en ligne 4")
    if vu.get("droite") is None or vu["droite"][1][0] != NAV_C:
        ok = False
        print("    attendu : Maj + droite -> fenetre en colonne %d" % NAV_C)
    if non_geres or etat["out_dos"]:
        ok = False
    return verifier("menu 1) Load DOS : PC-DOS 2.1 en ROM, DIR, Maj + fleches, Ctrl+Alt+Suppr", lcd, etat, MENU, ok)


NAV_C = 10


def main():
    image = sys.argv[1] if len(sys.argv) > 1 else "build/solution-02-bios.bin"
    seul = sys.argv[2] if len(sys.argv) > 2 else None
    scenarios = [
        ("menu", lambda: scenario_menu(image)),
        ("ram", lambda: scenario_test_ram(image)),
        ("defaut", lambda: scenario_ram_defaut(image, "menu 2) cellule 7B3FFh qui ne retient rien",
            ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 001", "Adresses A0-A18: OK ", "ERR 7B3FF 55/00     "],
            defaut=lambda a: a == 0x7B3FF)),
        ("absente", lambda: scenario_ram_defaut(image, "RAM absente (DSEG defectueux : test complet d'office)",
            ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 512", "Adresses: ERR base  ", "ERR 00000 AA/00     "],
            defaut=lambda a: a < RAM, touche=False)),
        ("a15", lambda: scenario_ram_defaut(image, "menu 2) ligne A15 coupee (8000h repond comme 0)",
            ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 000", "Adresses: ERR A15   ", "                    "],
            alias=1 << 15)),
        ("a17", lambda: scenario_ram_defaut(image, "menu 2) puce de 128 Ko (A17 ignoree)",
            ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 000", "Adresses: ERR A17   ", "                    "],
            alias=1 << 17)),
        ("led", lambda: scenario_led(image)),
        ("terminal", lambda: scenario_terminal(image)),
        ("sysinfo", lambda: scenario_sysinfo(image)),
        ("dos", lambda: scenario_dos(image)),
    ]
    echecs = 0
    for nom, f in scenarios:
        if seul is None or seul == nom:
            echecs += not f()
    print("\n%d scenario(s) en echec" % echecs)
    sys.exit(1 if echecs else 0)


if __name__ == "__main__":
    main()
