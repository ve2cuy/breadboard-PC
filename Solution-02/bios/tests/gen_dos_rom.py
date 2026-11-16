"""Fabrique la disquette PC-DOS 2.1 de la ROM (180 Ko, FCh) : seulement le demarrage
(IBMBIO.COM, IBMDOS.COM, COMMAND.COM), EDLIN, CHKDSK, FORMAT (de PC-DOS 2.1) et MASM.EXE /
LINK.EXE (MASM 1.0 et LINK 1.x de 1982, pour DOS 1.1/2.x : PC-DOS/MASM/MASM1.EXE, LINK1.EXE).

    python tests/gen_dos_rom.py   -> ../../PC-DOS/pcdos2_1_rom.img

Le secteur d'amorce de PC-DOS 2.1 est garde ; IBMBIO et IBMDOS restent aux amas 2 et 12
(debut de la zone de donnees, comme il l'exige). Les fichiers sont d'un seul tenant."""
import os
import struct

ICI = os.path.dirname(os.path.abspath(__file__))
DOS = os.path.join(ICI, '..', '..', '..', 'PC-DOS')
SOURCE = os.path.join(DOS, 'pcdos2_1.img')
SORTIE = os.path.join(DOS, 'pcdos2_1_rom.img')
GARDES = ['IBMBIO.COM', 'IBMDOS.COM', 'COMMAND.COM', 'EDLIN.COM', 'CHKDSK.COM', 'FORMAT.COM']
AJOUTS = [('MASM.EXE', 'MASM1.EXE'), ('LINK.EXE', 'LINK1.EXE')]


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
    # fichiers d'origine : entree de repertoire et contenu (suivi de la chaine FAT)
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
    fichiers = []
    for nom in GARDES:
        e, c = orig[nom]
        fichiers.append((e, c))
    for nom, src in AJOUTS:
        chemin = os.path.join(DOS, 'MASM', src)
        c = open(chemin, 'rb').read()
        e = bytearray(orig['EDLIN.COM'][0])            # meme date ; attribut normal
        base, ext = nom.split('.')
        e[0:11] = (base.ljust(8) + ext.ljust(3)).encode()
        e[11] = 0x20
        fichiers.append((bytes(e), c))
    # nouvelle image : amorce d'origine, FAT et racine reconstruites
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
    assert struct.unpack_from('<H', racine, 26)[0] == 2 and struct.unpack_from('<H', racine, 32 + 26)[0] == 12
    open(SORTIE, 'wb').write(out)
    libre = (namas - amas) * bps
    print('%s : %d fichiers, %d amas utilises, %d octets libres' % (os.path.basename(SORTIE), len(fichiers), amas - 2, libre))


if __name__ == '__main__':
    main()
