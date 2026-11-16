"""Carte SD du simulateur : image creuse {secteur: 512 octets} d'une carte SDHC formatee en
FAT32 (MBR + 1 partition) ou en FAT16, avec des images de disquette .IMG a la racine.

    carte_fat32(fichiers) -> (secteurs, nb_secteurs)
    fichiers : liste de (nom 8.3 'PCDOS21.IMG', contenu bytes)

Seuls les secteurs non nuls sont gardes. Les fichiers sont d'un seul tenant (comme sur une
carte fraichement formatee), sauf `fragmente=True` (le 2e fichier saute un amas)."""
import struct

SECT = 512


def _nom83(nom):
    base, _, ext = nom.upper().partition('.')
    return (base.ljust(8)[:8] + ext.ljust(3)[:3]).encode('ascii')


def _entree(nom83, attr, amas, taille):
    return struct.pack('<11sBBBHHHHHHHI', nom83, attr, 0, 0, 0, 0, 0, amas >> 16, 0x6000, 0x4B70, amas & 0xFFFF, taille)


def carte_fat32(fichiers, mo=64, part=2048, spc=1, fragmente=False):
    total = mo * 2048
    taille_part = total - part
    reserves, nfat = 32, 2
    # secteurs par FAT : assez pour tous les amas
    fatsz = 1
    while True:
        amas = (taille_part - reserves - nfat * fatsz) // spc
        if (amas + 2) * 4 <= fatsz * SECT:
            break
        fatsz += 1
    assert amas >= 65525, "trop petit pour du FAT32"
    s = {}
    mbr = bytearray(SECT)
    mbr[0x1BE:0x1CE] = struct.pack('<B3sB3sII', 0x00, b'\x00\x00\x00', 0x0C, b'\x00\x00\x00', part, taille_part)
    mbr[510:512] = b'\x55\xAA'
    s[0] = bytes(mbr)
    bpb = bytearray(SECT)
    bpb[0:3] = b'\xEB\x58\x90'
    bpb[3:11] = b'MSWIN4.1'
    struct.pack_into('<HBHBHHBHHHII', bpb, 11, SECT, spc, reserves, nfat, 0, 0, 0xF8, 0, 63, 255, part, taille_part)
    struct.pack_into('<IHHIHH', bpb, 36, fatsz, 0, 0, 2, 1, 6)
    bpb[0x52:0x5A] = b'FAT32   '
    bpb[510:512] = b'\x55\xAA'
    s[part] = bytes(bpb)
    fat_lba = part + reserves
    donnees = fat_lba + nfat * fatsz
    fat = {0: 0x0FFFFFF8, 1: 0x0FFFFFFF, 2: 0x0FFFFFFF}         # amas 2 = racine
    racine = bytearray(SECT * spc)
    entrees = [_entree(b'SOLUTION02 ', 0x08, 0, 0)]               # etiquette du volume
    entrees.append(b'\x41' + b'\x00' * 10 + b'\x0F' + b'\x00' * 20)  # nom long (ignore)
    prochain = 3
    for i, (nom, contenu) in enumerate(fichiers):
        if fragmente and i == 1:
            prochain += 1                                         # un trou : fichier fragmente
        n = max(1, (len(contenu) + SECT * spc - 1) // (SECT * spc))
        premier = prochain
        chaine = list(range(premier, premier + n))
        if fragmente and i == 1 and n > 1:
            chaine = [premier] + list(range(premier + 2, premier + n + 1))
        for a, b in zip(chaine, chaine[1:] + [0x0FFFFFFF]):
            fat[a] = b
        for k, a in enumerate(chaine):
            bloc = contenu[k * SECT * spc:(k + 1) * SECT * spc]
            for j in range(spc):
                sec = bloc[j * SECT:(j + 1) * SECT]
                if any(sec):
                    s[donnees + (a - 2) * spc + j] = bytes(sec.ljust(SECT, b'\x00'))
        prochain = chaine[-1] + 1
        entrees.append(_entree(_nom83(nom), 0x20, premier, len(contenu)))
    for i, e in enumerate(entrees):
        racine[i * 32:(i + 1) * 32] = e
    for j in range(spc):
        s[donnees + j] = bytes(racine[j * SECT:(j + 1) * SECT])
    for num in range(nfat):
        for a, v in fat.items():
            sec = fat_lba + num * fatsz + (a * 4) // SECT
            buf = bytearray(s.get(sec, bytes(SECT)))
            struct.pack_into('<I', buf, (a * 4) % SECT, v)
            s[sec] = bytes(buf)
    return s, total


def lire_fichier(secteurs, nom, part=2048):
    """Relit un fichier de la racine (pour verifier les ecritures du BIOS)."""
    bpb = secteurs[part]
    spc, res, nfat = bpb[13], struct.unpack_from('<H', bpb, 14)[0], bpb[16]
    fatsz = struct.unpack_from('<I', bpb, 36)[0]
    donnees = part + res + nfat * fatsz
    racine = secteurs.get(donnees, bytes(SECT))
    for i in range(0, SECT, 32):
        e = racine[i:i + 32]
        if e[0:11] == _nom83(nom):
            amas = struct.unpack_from('<H', e, 26)[0] | struct.unpack_from('<H', e, 20)[0] << 16
            taille = struct.unpack_from('<I', e, 28)[0]
            out = bytearray()
            n = (taille + SECT * spc - 1) // (SECT * spc)
            for k in range(n):                                    # d'un seul tenant
                for j in range(spc):
                    out += secteurs.get(donnees + (amas + k - 2) * spc + j, bytes(SECT))
            return bytes(out[:taille])
    return None


if __name__ == '__main__':
    import os
    img = open(os.path.join(os.path.dirname(__file__), '..', '..', '..', 'PC-DOS', 'pcdos2_1.img'), 'rb').read()
    s, n = carte_fat32([('PCDOS21.IMG', img), ('VIDE160.IMG', bytes(163840))])
    print('%d secteurs, %d non nuls' % (n, len(s)))
    print(len(lire_fichier(s, 'PCDOS21.IMG')) == len(img), lire_fichier(s, 'PCDOS21.IMG') == img)
