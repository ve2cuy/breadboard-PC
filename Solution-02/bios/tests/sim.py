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


def sortie_port(lcd, ppi, port, val, n):
    if port in (0, 1):
        lcd.ecrire(port, val, n)
    elif 0x10 <= port <= 0x13:
        ppi.ecrire(port, val)
    else:
        lcd.erreurs.append("OUT vers le port %02Xh" % port)


def fini(lcd):
    """Le BIOS a termine : RAM defectueuse -> compteur "CPT 0003" en ligne 1 ;
    RAM bonne -> un cycle complet d'animations (compteur 0001 en fin de ligne 4)."""
    l = lcd.lignes()
    return l[0].endswith("CPT 0003") or (l[2].startswith("DEL") and l[3].endswith("0001"))


def lancer(image, defaut=None, max_instr=30_000_000):
    rom = open(image, "rb").read()
    assert len(rom) == ROM_LEN, "image de %d octets (256 Ko attendus)" % len(rom)
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, RAM)
    uc.mem_write(0, bytes(0x00 for _ in range(RAM)))
    uc.mem_map(ROM_BASE, 0x80000, UC_PROT_READ | UC_PROT_EXEC)
    uc.mem_write(ROM_BASE, rom)              # 80000h-BFFFFh
    uc.mem_write(ROM_BASE + ROM_LEN, rom)    # C0000h-FFFFFh
    lcd = LCD()
    ppi = PPI()
    etat = {"n": 0, "restaurer": [], "fin": None, "ppi": ppi}

    def code(uc, adr, taille, ud):
        for a, v in etat["restaurer"]:       # cellule defectueuse : l'ecriture n'a pas pris
            uc.mem_write(a, bytes([v]))
        etat["restaurer"] = []
        etat["n"] += 1
        if etat["n"] > max_instr:
            etat["fin"] = "limite d'instructions atteinte"
            uc.emu_stop()

    def ecriture(uc, acces, adr, taille, val, ud):
        if adr >= ROM_BASE:
            etat["fin"] = "ecriture en ROM a %05Xh" % adr
            uc.emu_stop()
            return True
        if defaut:
            for i in range(taille):          # ecritures de mots (REP STOSW) : chaque octet
                if defaut(adr + i):
                    etat["restaurer"].append((adr + i, uc.mem_read(adr + i, 1)[0]))
        return True

    def sortie(uc, port, taille, val, ud):
        sortie_port(lcd, ppi, port, val & 0xFF, etat["n"])
        if "pile" not in etat and lcd.lignes()[3].startswith("PILE"):
            etat["pile"] = (uc.reg_read(UC_X86_REG_SS), uc.reg_read(UC_X86_REG_SP))
        if fini(lcd):
            etat["fin"] = "ok"
            uc.emu_stop()

    uc.hook_add(UC_HOOK_CODE, code)
    uc.hook_add(UC_HOOK_MEM_WRITE, ecriture)
    uc.hook_add(UC_HOOK_INSN, sortie, None, 1, 0, UC_X86_INS_OUT)
    uc.reg_write(UC_X86_REG_CS, 0xFFFF)      # etat du 8088 apres RESET
    uc.reg_write(UC_X86_REG_IP, 0x0000)
    try:
        uc.emu_start(0xFFFF0, 0)
    except UcError as e:
        etat["fin"] = "erreur unicorn %s a %04X:%04X" % (e, uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP))
    return lcd, etat


def afficher(titre, lcd, etat):
    print("--- %s (%s, %d instructions, %d ecritures LCD)" % (titre, etat["fin"], etat["n"], lcd.ecritures))
    print("    +" + "-" * 20 + "+")
    for l in lcd.lignes():
        print("    |%s|" % l)
    print("    +" + "-" * 20 + "+")
    for e in lcd.erreurs[:10]:
        print("    ERREUR LCD:", e)


def main():
    image = sys.argv[1] if len(sys.argv) > 1 else "build/solution-02-bios.bin"
    echecs = 0
    cas = [
        ("RAM saine", None, None,
         ["SOLUTION-02 BIOS 0.4", "RAM 512 Ko  PILE OK ", "DEL : 8255 en 10h   ", "Chenillard      0001"]),
        ("cellule 7B3FFh qui ne retient rien", lambda a: a == 0x7B3FF, None,
         ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 001", "Adresses A0-A18: OK ", "ERR 7B3FF 55/00     "]),
        ("RAM absente", lambda a: a < RAM, None,
         ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 512", "Adresses: ERR base  ", "ERR 00000 AA/00     "]),
        ("ligne A15 coupee (8000h repond comme 0)", None, 15,
         ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 000", "Adresses: ERR A15   ", "                    "]),
        ("puce de 128 Ko (A17 ignoree)", None, 17,
         ["RAM DEFAUT  CPT 0003", "Ko: 512  Defauts 000", "Adresses: ERR A17   ", "                    "]),
    ]
    for titre, defaut, bit, attendu in cas:
        if bit is not None:
            lcd, etat = lancer_alias(image, 1 << bit)
        else:
            lcd, etat = lancer(image, defaut)
        afficher(titre, lcd, etat)
        ok = etat["fin"] == "ok" and not lcd.erreurs and lcd.allume
        for l, a in zip(lcd.lignes(), attendu):
            if a is not None and l != a:
                ok = False
                print("    attendu: |%s|" % a)
        ppi = etat["ppi"]
        for e in ppi.erreurs[:5]:
            ok = False
            print("    ERREUR 8255:", e)
        if titre == "RAM saine":
            ss, sp = etat.get("pile", (0, 1))
            print("    pile SS:SP = %04X:%04X" % (ss, sp))
            if ss != 0x7000 or not (sp == 0 or sp >= 0xFF00):   # SP = FFFEh dans lcd_car (adresse de retour)
                ok = False
                print("    attendu: pile 7000:0000 (au sommet ou presque)")
            print("    8255 : %d sorties, DEL vues allumees %s, eteintes %s" % (
                ppi.sorties, ["%02X" % v for v in ppi.allumees], ["%02X" % v for v in ppi.eteintes]))
            if not ppi.toutes_vues():
                ok = False
                print("    attendu: chacune des 24 DEL allumee et eteinte au moins une fois")
        print("    =>", "OK" if ok else "ECHEC")
        echecs += not ok
    print("\n%d scenario(s) en echec" % echecs)
    sys.exit(1 if echecs else 0)


def lancer_alias(image, bit):
    """Variante de lancer() : la RAM ignore la ligne d'adresse `bit` ; une ecriture a l'adresse a
    atteint aussi a ^ bit (les deux copies restent identiques, comme une seule cellule physique)."""
    rom = open(image, "rb").read()
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, RAM)
    uc.mem_map(ROM_BASE, 0x80000, UC_PROT_READ | UC_PROT_EXEC)
    uc.mem_write(ROM_BASE, rom)
    uc.mem_write(ROM_BASE + ROM_LEN, rom)
    lcd = LCD()
    ppi = PPI()
    etat = {"n": 0, "fin": None, "copie": [], "ppi": ppi}

    def code(uc, adr, taille, ud):
        for a, v in etat["copie"]:
            uc.mem_write(a, bytes([v]))
        etat["copie"] = []
        etat["n"] += 1
        if etat["n"] > 30_000_000:
            etat["fin"] = "limite d'instructions atteinte"
            uc.emu_stop()

    def ecriture(uc, acces, adr, taille, val, ud):
        if adr < RAM:
            for i in range(taille):
                etat["copie"].append(((adr + i) ^ bit, (val >> (8 * i)) & 0xFF))
        return True

    def sortie(uc, port, taille, val, ud):
        sortie_port(lcd, ppi, port, val & 0xFF, etat["n"])
        if fini(lcd):
            etat["fin"] = "ok"
            uc.emu_stop()

    uc.hook_add(UC_HOOK_CODE, code)
    uc.hook_add(UC_HOOK_MEM_WRITE, ecriture)
    uc.hook_add(UC_HOOK_INSN, sortie, None, 1, 0, UC_X86_INS_OUT)
    uc.reg_write(UC_X86_REG_CS, 0xFFFF)
    uc.reg_write(UC_X86_REG_IP, 0)
    uc.emu_start(0xFFFF0, 0)
    return lcd, etat


if __name__ == "__main__":
    main()
