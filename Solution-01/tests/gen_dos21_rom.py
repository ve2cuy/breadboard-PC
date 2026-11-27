"""Fabrique la disquette PC-DOS 2.1 de la ROM de Solution-01 (lecteur A: en ROM, ROM 1.4).

    python tests/gen_dos21_rom.py      (depuis Solution-01)
        -> ../PC-DOS/pcdos2_1_s01.img      disquette complete de 180 Ko (FCh), pour l'essayer ailleurs
        -> build/dos21_rom.bin             les secteurs UTILISES seulement (debut de l'image), inclus
                                           dans la ROM par solution-01.asm (incbin); le BIOS rend des
                                           zeros pour les secteurs suivants (amas libres)

Contenu (minimal): demarrage (IBMBIO.COM, IBMDOS.COM, COMMAND.COM de PC-DOS 2.1), EDLIN.COM (editeur),
MASM.EXE = MASM1.EXE (Microsoft MACRO Assembler 1.00) et LINK.EXE = LINK1.EXE (Object Linker 1.08),
compatibles DOS 2.1 (essayes sur Solution-02), HELLO.ASM (exemple) et AUTOEXEC.BAT (date, heure,
PATH A:\\, copie de HELLO.ASM sur B: et passage sur B:, le disque en RAM ou MASM et LINK ecrivent).
Meme methode que Solution-02/bios/tests/gen_dos_rom.py: secteur d'amorce de PC-DOS 2.1 garde, IBMBIO et
IBMDOS aux amas 2 et suivants (debut de la zone de donnees, comme l'exige l'amorce), fichiers d'un seul
tenant, FAT et racine refaites."""
import os
import struct

ICI = os.path.dirname(os.path.abspath(__file__))
S01 = os.path.join(ICI, '..')
DOS = os.path.join(S01, '..', 'PC-DOS')
SOURCE = os.path.join(DOS, 'pcdos2_1.img')
SORTIE = os.path.join(DOS, 'pcdos2_1_s01.img')
SORTIE_ROM = os.path.join(S01, 'build', 'dos21_rom.bin')
GARDES = ['IBMBIO.COM', 'IBMDOS.COM', 'COMMAND.COM', 'EDLIN.COM']
AJOUTS = [('MASM.EXE', os.path.join(DOS, 'MASM', 'MASM1.EXE')),
          ('LINK.EXE', os.path.join(DOS, 'MASM', 'LINK1.EXE'))]

HELLO = r"""; HELLO.ASM - exemple pour MASM 1.0 et LINK 1.08 (PC-DOS 2.1 de la ROM)
;   MASM HELLO;      -> HELLO.OBJ
;   LINK HELLO;      -> HELLO.EXE
;   HELLO
CODE    SEGMENT
        ASSUME  CS:CODE,DS:CODE
START:  PUSH    CS
        POP     DS
        MOV     DX,OFFSET MSG
        MOV     AH,9
        INT     21H
        MOV     AX,4C00H
        INT     21H
MSG     DB      'Hello, world! (8088, VE2CUY)',13,10,'$'
CODE    ENDS
STACK   SEGMENT STACK
        DW      64 DUP (?)
STACK   ENDS
        END     START
"""

AUTOEXEC = r"""DATE
TIME
PATH A:\
COPY A:HELLO.ASM B:
B:
"""


def texte_dos(t):
    return t.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii') + b'\x1a'


def lire_fat12(im, fat_off, n):
    o = fat_off + (n * 3) // 2
    v = struct.unpack_from('<H', im, o)[0]
    return (v >> 4) if n & 1 else (v & 0xFFF)


def ecrire_fat12(fat, n, val):
    o = (n * 3) // 2
    v = struct.unpack_from('<H', fat, o)[0]
    if n & 1:
        v = (v & 0x000F) | (val << 4)
    else:
        v = (v & 0xF000) | val
    struct.pack_into('<H', fat, o, v)


def main():
    im = open(SOURCE, 'rb').read()
    bps, spc, res, nfat, nrac, tot, media, fatsz = struct.unpack_from('<HBHBHHBH', im, 11)
    assert (bps, spc, tot, media) == (512, 1, 360, 0xFC), "pcdos2_1.img : 180 Ko FCh attendu"
    fat_off = res * bps
    rac_off = (res + nfat * fatsz) * bps
    donnees = rac_off + nrac * 32
    namas = (tot * bps - donnees) // bps + 2          # amas 2 .. namas-1
    orig = {}
    for i in range(nrac):
        e = im[rac_off + i * 32:rac_off + i * 32 + 32]
        if e[0] in (0, 0xE5) or e[11] & 0x18:
            continue
        nom = e[0:8].decode().strip() + '.' + e[8:11].decode().strip()
        taille, amas = struct.unpack_from('<I', e, 28)[0], struct.unpack_from('<H', e, 26)[0]
        contenu = bytearray()
        while 2 <= amas < 0xFF8:
            contenu += im[donnees + (amas - 2) * bps:donnees + (amas - 1) * bps]
            amas = lire_fat12(im, fat_off, amas)
        orig[nom] = (bytes(e), bytes(contenu[:taille]))
    fichiers = [orig[nom] for nom in GARDES]

    def entree(nom, contenu):
        e = bytearray(orig['EDLIN.COM'][0])            # meme date; attribut normal
        base, ext = nom.split('.')
        e[0:11] = (base.ljust(8) + ext.ljust(3)).encode()
        e[11] = 0x20
        return (bytes(e), contenu)
    for nom, chemin in AJOUTS:
        fichiers.append(entree(nom, open(chemin, 'rb').read()))
    fichiers.append(entree('HELLO.ASM', texte_dos(HELLO)))
    fichiers.append(entree('AUTOEXEC.BAT', texte_dos(AUTOEXEC)))

    out = bytearray(tot * bps)
    out[0:res * bps] = im[0:res * bps]
    fat = bytearray(fatsz * bps)
    fat[0], fat[1], fat[2] = media, 0xFF, 0xFF
    racine = bytearray(nrac * 32)
    amas = 2
    for i, (e, c) in enumerate(fichiers):
        n = max(1, (len(c) + bps - 1) // bps)
        assert amas + n <= namas, "la disquette deborde (%s)" % e[0:11]
        e = bytearray(e)
        struct.pack_into('<H', e, 26, amas)
        struct.pack_into('<I', e, 28, len(c))
        racine[i * 32:i * 32 + 32] = e
        for k in range(n):
            ecrire_fat12(fat, amas + k, amas + k + 1 if k < n - 1 else 0xFFF)
        out[donnees + (amas - 2) * bps:donnees + (amas - 2) * bps + len(c)] = c
        amas += n
    for k in range(nfat):
        out[fat_off + k * fatsz * bps:fat_off + (k + 1) * fatsz * bps] = fat
    out[rac_off:rac_off + nrac * 32] = racine
    open(SORTIE, 'wb').write(out)
    utiles = donnees // bps + (amas - 2)             # secteurs 0 .. utiles-1
    os.makedirs(os.path.dirname(SORTIE_ROM), exist_ok=True)
    open(SORTIE_ROM, 'wb').write(out[:utiles * bps])
    print('%s : %d fichiers, %d amas utilises, %d octets libres ; ROM : %d secteurs (%d octets)' % (
        os.path.basename(SORTIE), len(fichiers), amas - 2, (namas - amas) * bps, utiles, utiles * bps))


if __name__ == '__main__':
    main()
