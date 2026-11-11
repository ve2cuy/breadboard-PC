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


def lancer(image, defaut=None, compteur_fin="0003", max_instr=8_000_000):
    rom = open(image, "rb").read()
    assert len(rom) == ROM_LEN, "image de %d octets (256 Ko attendus)" % len(rom)
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0, RAM)
    uc.mem_write(0, bytes(0x00 for _ in range(RAM)))
    uc.mem_map(ROM_BASE, 0x80000, UC_PROT_READ | UC_PROT_EXEC)
    uc.mem_write(ROM_BASE, rom)              # 80000h-BFFFFh
    uc.mem_write(ROM_BASE + ROM_LEN, rom)    # C0000h-FFFFFh
    lcd = LCD()
    etat = {"n": 0, "restaurer": [], "fin": None}

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
        if defaut and defaut(adr):
            etat["restaurer"].append((adr, uc.mem_read(adr, 1)[0]))
        return True

    def sortie(uc, port, taille, val, ud):
        if port in (0, 1):
            lcd.ecrire(port, val & 0xFF, etat["n"])
            if lcd.lignes()[3].endswith(compteur_fin):
                etat["fin"] = "ok"
                uc.emu_stop()
        else:
            lcd.erreurs.append("OUT vers le port %02Xh" % port)

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
        ("RAM saine", None,
         ["SOLUTION-02 BIOS 0.1", "CPU 8088/V20 5.33MHz", "RAM 512 Ko : OK     ", "VE2CUY-2026 CPT 0003"]),
        ("cellule 7B3FFh qui ne retient rien", lambda a: a == 0x7B3FF,
         [None, None, "RAM ERR 7B3FF 55/00 ", None]),
        ("RAM absente", lambda a: a < RAM,
         [None, None, "RAM ERR 00000 55/00 ", "VE2CUY-2026 CPT 0003"]),
        ("ligne A15 coupee (8000h repond comme 0)",
         None, [None, None, "RAM ERR 00000 00/10 ", None]),
    ]
    for titre, defaut, attendu in cas:
        if titre.startswith("ligne A15"):
            lcd, etat = lancer_alias(image, 1 << 15)
        else:
            lcd, etat = lancer(image, defaut)
        afficher(titre, lcd, etat)
        ok = etat["fin"] == "ok" and not lcd.erreurs and lcd.allume
        for l, a in zip(lcd.lignes(), attendu):
            if a is not None and l != a:
                ok = False
                print("    attendu: |%s|" % a)
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
    etat = {"n": 0, "fin": None, "copie": []}

    def code(uc, adr, taille, ud):
        for a, v in etat["copie"]:
            uc.mem_write(a, bytes([v]))
        etat["copie"] = []
        etat["n"] += 1
        if etat["n"] > 8_000_000:
            etat["fin"] = "limite d'instructions atteinte"
            uc.emu_stop()

    def ecriture(uc, acces, adr, taille, val, ud):
        if adr < RAM:
            for i in range(taille):
                etat["copie"].append(((adr + i) ^ bit, (val >> (8 * i)) & 0xFF))
        return True

    def sortie(uc, port, taille, val, ud):
        lcd.ecrire(port, val & 0xFF, etat["n"])
        if lcd.lignes()[3].endswith("0003"):
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
