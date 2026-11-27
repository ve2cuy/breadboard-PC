"""Fabrique dos/SETTIME.EXE avec les VRAIS MASM 1.00 et LINK 1.08 de la disquette PC-DOS 2.1 de la ROM.

    python tests/gen_settime.py      (depuis Solution-01; puis make all pour remettre l'executable dans la ROM)

La ROM (build/rom_sim.bin, assemblee de solution-01.asm, disquette de tests/gen_dos21_rom.py: SETTIME.ASM y
est toujours) demarre son DOS au simulateur (tests/rom_sim.py); a l'invite B> (le disque en RAM):
COPY A:SETTIME.ASM B:, MASM SETTIME; LINK SETTIME; puis SETTIME pour l'essayer. SETTIME.EXE est ensuite lu
dans le disque B: en RAM (FAT12 de 180 Ko, RAMB_SEG de lib/bios.asm) et ecrit dans dos/."""
import os
import struct
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
S01 = os.path.dirname(ICI)
sys.path.insert(0, ICI)
import rom_sim as S

RAMB = 0x52800                      # RAMB_SEG (5280h) * 16, ROM de 512 Ko (lib/bios.asm)
SORTIE = os.path.join(S01, 'dos', 'SETTIME.EXE')


def fichier_fat12(img, nom):
    """contenu du fichier `nom` (8.3) d'une disquette FAT12 (BPB du secteur 0, sinon 180 Ko FCh)"""
    bps, spc, res, nfat, nrac, tot, media, fatsz = struct.unpack_from('<HBHBHHBH', img, 11)
    if bps != 512:
        bps, spc, res, nfat, nrac, fatsz = 512, 1, 1, 2, 64, 2
    fat = res * bps
    rac = (res + nfat * fatsz) * bps
    don = rac + nrac * 32
    base, ext = nom.split('.')
    cle = (base.ljust(8) + ext.ljust(3)).encode()
    for i in range(nrac):
        e = img[rac + i * 32:rac + i * 32 + 32]
        if e[0:11] != cle:
            continue
        amas, taille = struct.unpack_from('<H', e, 26)[0], struct.unpack_from('<I', e, 28)[0]
        out = bytearray()
        while 2 <= amas < 0xFF8:
            o = don + (amas - 2) * spc * bps
            out += img[o:o + spc * bps]
            v = struct.unpack_from('<H', img, fat + amas * 3 // 2)[0]
            amas = (v >> 4) if amas & 1 else (v & 0xFFF)
        return bytes(out[:taille])
    return None


def ajouter_fat12(img, nom, contenu):
    """copie de la disquette FAT12 `img` avec le fichier `nom` (8.3) ajoute a la racine (essais de
    tests/rom_test.py: SETTIME.EXE sous d'autres DOS)"""
    img = bytearray(img)
    bps, spc, res, nfat, nrac, tot, media, fatsz = struct.unpack_from('<HBHBHHBH', img, 11)
    fat = res * bps
    rac = (res + nfat * fatsz) * bps
    don = rac + nrac * 32
    namas = (tot * bps - don) // (spc * bps) + 2

    def lire(n):
        v = struct.unpack_from('<H', img, fat + n * 3 // 2)[0]
        return (v >> 4) if n & 1 else (v & 0xFFF)

    def ecrire(n, val):
        for k in range(nfat):
            o = fat + k * fatsz * bps + n * 3 // 2
            v = struct.unpack_from('<H', img, o)[0]
            v = (v & 0x000F) | (val << 4) if n & 1 else (v & 0xF000) | val
            struct.pack_into('<H', img, o, v)
    taille_amas = spc * bps
    besoin = max(1, -(-len(contenu) // taille_amas))
    libres = [n for n in range(2, namas) if lire(n) == 0][:besoin]
    if len(libres) < besoin:
        raise ValueError('disquette pleine')
    for i, n in enumerate(libres):
        ecrire(n, libres[i + 1] if i + 1 < len(libres) else 0xFFF)
        morceau = contenu[i * taille_amas:(i + 1) * taille_amas]
        o = don + (n - 2) * taille_amas
        img[o:o + len(morceau)] = morceau
    for i in range(nrac):
        o = rac + i * 32
        if img[o] in (0, 0xE5):
            base, ext = nom.split('.')
            e = bytearray(32)
            e[0:11] = (base.ljust(8) + ext.ljust(3)).encode()
            e[11] = 0x20
            struct.pack_into('<H', e, 26, libres[0])
            struct.pack_into('<I', e, 28, len(contenu))
            img[o:o + 32] = e
            return bytes(img)
    raise ValueError('racine pleine')


def main():
    os.chdir(S01)
    rom = S.build('solution-01.asm', 'rom_sim.bin', ('RAM_512K',))
    script = [(S.MENU, b'3'), (b'4) DOS 2.1', b'4'),
              (b'B>', b'COPY A:SETTIME.ASM B:\r'), (b'B>', b'MASM SETTIME;\r'), (b'B>', b'LINK SETTIME;\r'),
              (b'B>', b'SETTIME\r'), (b'(RTC)', b'')]
    m = S.Machine(rom, script=script, tail_blocks=50_000)
    st = m.run(3_000_000_000)
    out = st['out'].decode('latin-1')
    print(out[out.find('COPY A:SETTIME'):][-700:])
    if not st['done']:
        sys.exit('echec: le scenario ne s est pas termine')
    if 'E r r o r' in out or 'Severe' not in out:
        sys.exit('echec: MASM a signale des erreurs')
    exe = fichier_fat12(bytes(m.uc.mem_read(RAMB, 360 * 512)), 'SETTIME.EXE')
    if not exe or exe[:2] != b'MZ':
        sys.exit('echec: SETTIME.EXE introuvable sur B:')
    open(SORTIE, 'wb').write(exe)
    print('%s : %d octets' % (os.path.relpath(SORTIE, S01), len(exe)))


if __name__ == '__main__':
    main()
