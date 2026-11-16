"""Image de disque dur C: pour la carte SD (Solution-02, BIOS 1.6+) : MBR + 1 partition FAT16
active, geometrie 16 tetes x 63 secteurs (celle que le BIOS prend sans table de partitions).

    python tests/gen_hdd.py SORTIE.IMG [Mo]        (32 Mo par defaut)
    python tests/gen_hdd.py SORTIE.IMG [Mo] --vierge  (zeros : FDISK et FORMAT sous DOS)

Le code d'amorce du MBR fait seulement INT 18h (retour au menu du BIOS) : pour demarrer
depuis C:, installer le DOS sous DOS (FDISK /MBR, puis FORMAT C: /S ou SYS C:).
DOS 3.3 lit une partition FAT16 de 16 a 32 Mo (type 04h) ; DOS 4+ au-dela (type 06h). Amas comme FORMAT
(4 secteurs jusqu'a 128 Mo)."""
import struct
import sys

SECT, TETES, SPT = 512, 16, 63


def _nom83(nom):
    base, _, ext = nom.upper().partition('.')
    return (base.ljust(8)[:8] + ext.ljust(3)[:3]).encode('ascii')


def disque(mo=32, fichiers=()):
    cyl = (mo * 1024 * 1024) // (TETES * SPT * SECT)
    total = cyl * TETES * SPT
    out = bytearray(total * SECT)
    debut, n = SPT, total - SPT                                  # partition : tete 1, cylindre 0
    type_part = 0x04 if n < 65536 else 0x06
    mbr = bytearray(SECT)
    mbr[0:4] = b'\xCD\x18\xEB\xFE'                                # INT 18h (pas de systeme)
    c = cyl - 1
    mbr[0x1BE:0x1CE] = struct.pack('<BBBBBBBBII', 0x80, 1, 1, 0, type_part, TETES - 1,
                                   SPT | ((c >> 8) << 6), c & 0xFF, debut, n)
    mbr[510:512] = b'\x55\xAA'
    out[0:SECT] = mbr
    # taille d'amas comme FORMAT de MS-DOS (DOS 3.x recalcule le BPB des disques durs d'apres
    # la taille de la partition) : FAT16 a partir de 16 Mo, 2 Ko par amas jusqu'a 128 Mo
    assert n >= 32680, "16 Mo au moins (en dessous, DOS veut du FAT12)"
    spc = 4
    while n // spc > 65524:
        spc *= 2
    reserves, nfat, nrac = 1, 2, 512
    racine = nrac * 32 // SECT
    fatsz = 1
    while True:
        amas = (n - reserves - nfat * fatsz - racine) // spc
        if (amas + 2) * 2 <= fatsz * SECT:
            break
        fatsz += 1
    assert 4085 <= amas <= 65524, "taille hors FAT16"
    bpb = bytearray(SECT)
    bpb[0:3] = b'\xEB\x3C\x90'
    bpb[3:11] = b'SOL02 HD'
    struct.pack_into('<HBHBHHBHHHII', bpb, 11, SECT, spc, reserves, nfat, nrac,
                     n if n < 65536 else 0, 0xF8, fatsz, SPT, TETES, debut, n if n >= 65536 else 0)
    struct.pack_into('<BBBI11s8s', bpb, 36, 0x80, 0, 0x29, 0x5002, b'DISQUE C   ', b'FAT16   ')
    bpb[0x3E:0x40] = b'\xCD\x18'
    bpb[510:512] = b'\x55\xAA'
    p = debut * SECT
    out[p:p + SECT] = bpb
    fat = {0: 0xFFF8, 1: 0xFFFF}
    rac = bytearray(racine * SECT)
    rac[0:32] = struct.pack('<11sB10sHHHI', b'DISQUE C   ', 0x08, bytes(10), 0x6000, 0x4B70, 0, 0)
    prochain = 2
    donnees = debut + reserves + nfat * fatsz + racine
    for i, (nom, contenu) in enumerate(fichiers):
        k = max(1, (len(contenu) + spc * SECT - 1) // (spc * SECT))
        for j in range(k):
            fat[prochain + j] = prochain + j + 1 if j < k - 1 else 0xFFFF
        o = (donnees + (prochain - 2) * spc) * SECT
        out[o:o + len(contenu)] = contenu
        rac[(i + 1) * 32:(i + 2) * 32] = struct.pack('<11sB10sHHHI', _nom83(nom), 0x20, bytes(10),
                                                       0x6000, 0x4B70, prochain, len(contenu))
        prochain += k
    for f in range(nfat):
        base = (debut + reserves + f * fatsz) * SECT
        for a, v in fat.items():
            struct.pack_into('<H', out, base + a * 2, v)
    o = (debut + reserves + nfat * fatsz) * SECT
    out[o:o + len(rac)] = rac
    return bytes(out)


def racine(image):
    """Noms 8.3 de la racine de la 1re partition (pour les verifications)."""
    debut = struct.unpack_from('<I', image, 0x1C6)[0]
    b = image[debut * SECT:(debut + 1) * SECT]
    spc, res, nfat, nrac = b[13], struct.unpack_from('<H', b, 14)[0], b[16], struct.unpack_from('<H', b, 17)[0]
    fatsz = struct.unpack_from('<H', b, 22)[0]
    o = (debut + res + nfat * fatsz) * SECT
    noms = []
    for i in range(nrac):
        e = image[o + i * 32:o + i * 32 + 32]
        if e[0] == 0:
            break
        if e[0] != 0xE5 and not e[11] & 0x08:
            noms.append(e[0:11].decode('latin1'))
    return noms


if __name__ == '__main__':
    sortie = sys.argv[1]
    mo = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 32
    if '--vierge' in sys.argv:
        cyl = (mo * 1024 * 1024) // (TETES * SPT * SECT)
        image = bytes(cyl * TETES * SPT * SECT)
    else:
        image = disque(mo, [('LISEZMOI.TXT', b'Disque C: de Solution-02 (carte SD).\r\n')])
    open(sortie, 'wb').write(image)
    print('%s : %d octets (%d cylindres x %d tetes x %d secteurs)' % (
        sortie, len(image), len(image) // (TETES * SPT * SECT), TETES, SPT))
