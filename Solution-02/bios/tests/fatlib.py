"""Outils FAT pour fabriquer les images de disque dur de la carte SD (Solution-02) :
  - Volume : lecture d'un volume FAT12/FAT16/FAT32 (disquette, ou partition d'une image)
  - szdd()  : decompression des fichiers Microsoft compresses (*.EX_, *.CO_... : COMPRESS.EXE)
  - Fat16   : fabrication d'une partition FAT16 (repertoires, fichiers d'un seul tenant)
  - disque_dur() : MBR (code d'amorce 8086 de mbr8086.asm) + 1 partition FAT16 active,
    geometrie 16 tetes x 63 secteurs (celle que prend le BIOS de Solution-02)."""
import os
import struct
import subprocess

SECT, TETES, SPT = 512, 16, 63
ICI = os.path.dirname(os.path.abspath(__file__))


def nom83(nom):
    base, _, ext = nom.upper().partition('.')
    return (base.ljust(8)[:8] + ext.ljust(3)[:3]).encode('latin1')


def nom_clair(e):
    base = e[0:8].decode('latin1').rstrip()
    ext = e[8:11].decode('latin1').rstrip()
    return base + ('.' + ext if ext else '')


class Volume:
    """Volume FAT en lecture ; `debut` = premier secteur du volume dans l'image."""

    def __init__(self, image, debut=0):
        self.im, self.d = image, debut * SECT
        b = image[self.d:self.d + SECT]
        self.bps, self.spc, self.res, self.nfat, self.nrac = struct.unpack_from('<HBHBH', b, 11)
        tot16, fatsz16 = struct.unpack_from('<H', b, 19)[0], struct.unpack_from('<H', b, 22)[0]
        tot32 = struct.unpack_from('<I', b, 32)[0]
        self.fatsz = fatsz16 or struct.unpack_from('<I', b, 36)[0]
        tot = tot16 or tot32
        self.racine = self.res + self.nfat * self.fatsz
        racsect = (self.nrac * 32 + self.bps - 1) // self.bps
        self.donnees = self.racine + racsect
        amas = (tot - self.donnees) // self.spc
        self.type = 12 if amas < 4085 else 16 if amas < 65525 else 32
        self.rclus = struct.unpack_from('<I', b, 44)[0] if self.type == 32 else 0

    def secteur(self, n, k=1):
        o = self.d + n * self.bps
        return self.im[o:o + k * self.bps]

    def suivant(self, a):
        fo = self.d + self.res * self.bps
        if self.type == 12:
            v = struct.unpack_from('<H', self.im, fo + a * 3 // 2)[0]
            v = v >> 4 if a & 1 else v & 0xFFF
            return None if v >= 0xFF8 else v
        if self.type == 16:
            v = struct.unpack_from('<H', self.im, fo + a * 2)[0]
            return None if v >= 0xFFF8 else v
        v = struct.unpack_from('<I', self.im, fo + a * 4)[0] & 0x0FFFFFFF
        return None if v >= 0x0FFFFFF8 else v

    def chaine(self, a):
        out = bytearray()
        while a and a >= 2:
            out += self.secteur(self.donnees + (a - 2) * self.spc, self.spc)
            a = self.suivant(a)
        return bytes(out)

    def entrees(self, amas=None):
        """(nom, attribut, premier amas, taille) d'un repertoire (None = racine)."""
        if amas is None and self.type != 32:
            brut = self.secteur(self.racine, (self.nrac * 32 + self.bps - 1) // self.bps)
        else:
            brut = self.chaine(amas if amas is not None else self.rclus)
        for i in range(0, len(brut), 32):
            e = brut[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08 or e[0:1] == b'.':
                continue
            a = struct.unpack_from('<H', e, 26)[0] | struct.unpack_from('<H', e, 20)[0] << 16
            yield nom_clair(e), e[11], a, struct.unpack_from('<I', e, 28)[0]

    def lire(self, chemin):
        """Contenu du fichier 'REP/NOM.EXT' (None s'il n'existe pas)."""
        amas = None
        parties = chemin.upper().replace('\\', '/').split('/')
        for k, p in enumerate(parties):
            for nom, attr, a, taille in self.entrees(amas):
                if nom == p:
                    if k == len(parties) - 1:
                        return self.chaine(a)[:taille]
                    amas = a
                    break
            else:
                return None
        return None

    def fichiers(self, amas=None, prefixe=''):
        """Tous les fichiers (chemin, attribut, contenu), sous-repertoires compris."""
        for nom, attr, a, taille in list(self.entrees(amas)):
            if attr & 0x10:
                yield from self.fichiers(a, prefixe + nom + '/')
            else:
                yield prefixe + nom, attr, self.chaine(a)[:taille]


def szdd(donnees):
    """Decompresse un fichier 'SZDD' (COMPRESS.EXE de Microsoft, mode A, LZSS). Rend (contenu,
    dernier caractere de l'extension d'origine) ; (donnees, None) si ce n'est pas du SZDD."""
    if donnees[:8] != b'SZDD\x88\xF0\x27\x33':
        return donnees, None
    car = chr(donnees[9]) if donnees[9] else None
    taille = struct.unpack_from('<I', donnees, 10)[0]
    fen = bytearray(b' ' * 4096)
    pos = 4096 - 16
    out = bytearray()
    i = 14
    while i < len(donnees) and len(out) < taille:
        drapeaux = donnees[i]
        i += 1
        for b in range(8):
            if i >= len(donnees) or len(out) >= taille:
                break
            if drapeaux & (1 << b):
                c = donnees[i]
                i += 1
                out.append(c)
                fen[pos] = c
                pos = (pos + 1) & 0xFFF
            else:
                if i + 1 >= len(donnees):
                    break
                p = donnees[i] | ((donnees[i + 1] & 0xF0) << 4)
                n = (donnees[i + 1] & 0x0F) + 3
                i += 2
                for k in range(n):
                    c = fen[(p + k) & 0xFFF]
                    out.append(c)
                    fen[pos] = c
                    pos = (pos + 1) & 0xFFF
    return bytes(out[:taille]), car


class _Bits:
    """Lecteur de bits, poids fort d'abord ; des zeros apres la fin."""

    def __init__(self, donnees):
        self.d, self.p = donnees, 0

    def lire(self, n):
        v = 0
        for _ in range(n):
            o = self.p >> 3
            b = (self.d[o] >> (7 - (self.p & 7))) & 1 if o < len(self.d) else 0
            v = (v << 1) | b
            self.p += 1
        return v

    def fini(self):
        return self.p >= 8 * len(self.d)


def _huffman(longueurs):
    """Codes canoniques -> {(longueur, code): symbole}."""
    table, code = {}, 0
    for n in range(1, 17):
        for s, l in enumerate(longueurs):
            if l == n:
                table[(n, code)] = s
                code += 1
        code <<= 1
    return table


def _symbole(bits, table):
    code = 0
    for n in range(1, 17):
        code = (code << 1) | bits.lire(1)
        if (n, code) in table:
            return table[(n, code)]
    raise ValueError("code de Huffman invalide")


def _kwaj_longueurs(bits, type_, n):
    if type_ == 0:
        return [{16: 4, 32: 5, 64: 6, 256: 8}[n]] * n
    if type_ == 3:
        return [bits.lire(4) for _ in range(n)]
    c = bits.lire(4)
    l = [c]
    for _ in range(1, n):
        if type_ == 1:
            if bits.lire(1):
                if bits.lire(1):
                    c = bits.lire(4)
                else:
                    c += 1
        else:
            sel = bits.lire(2)
            c = bits.lire(4) if sel == 3 else c + sel - 1
        l.append(c)
    return l


def kwaj(donnees):
    """Decompresse un fichier 'KWAJ' (COMPRESS de MS-DOS 6, methodes 0 a 3). Rend le contenu,
    ou None si ce n'est pas du KWAJ. La longueur d'origine borne la sortie quand elle est donnee."""
    if donnees[:8] != b'KWAJ\x88\xF0\x27\xD1':
        return None
    methode, debut, drap = struct.unpack_from('<HHH', donnees, 8)
    taille = struct.unpack_from('<I', donnees, 14)[0] if drap & 1 else None
    src = donnees[debut:]
    if methode == 0:
        out = bytearray(src)
    elif methode == 1:
        out = bytearray(b ^ 0xFF for b in src)
    elif methode == 2:
        return szdd(b'SZDD\x88\xF0\x27\x33A\x00' + struct.pack('<I', taille or 1 << 30) + src)[0]
    elif methode == 3:
        bits = _Bits(src)
        types = [bits.lire(4) for _ in range(6)]
        t_l1, t_l2, t_run, t_off, t_lit = (
            _huffman(_kwaj_longueurs(bits, t, n)) for t, n in zip(types, (16, 16, 32, 64, 256)))
        fen, pos, out, suite = bytearray(b' ' * 4096), 0, bytearray(), False
        while not bits.fini() and (taille is None or len(out) < taille):
            n = _symbole(bits, t_l2 if suite else t_l1)
            if n:
                n += 2
                suite = False
                dep = (_symbole(bits, t_off) << 6) | bits.lire(6)
                for _ in range(n):
                    c = fen[(pos - dep) & 4095]
                    fen[pos] = c
                    out.append(c)
                    pos = (pos + 1) & 4095
            else:
                n = _symbole(bits, t_run) + 1
                suite = n != 32
                for _ in range(n):
                    c = _symbole(bits, t_lit)
                    fen[pos] = c
                    out.append(c)
                    pos = (pos + 1) & 4095
    else:
        raise ValueError("KWAJ : methode %d non prise en charge" % methode)
    return bytes(out[:taille] if taille is not None else out)


class Fat16:
    """Partition FAT16 en construction (taille d'amas comme FORMAT : 4 secteurs jusqu'a 128 Mo).
    ajouter(chemin, contenu, attr) : dans l'ordre d'appel, d'un seul tenant (IO.SYS d'abord)."""

    def __init__(self, nsect, debut, etiquette=b'DISQUE C   ', oem=b'SOL02 HD'):
        assert nsect >= 32680, "16 Mo au moins"
        self.n, self.debut = nsect, debut
        self.spc = 4
        while nsect // self.spc > 65524:
            self.spc *= 2
        self.res, self.nfat, self.nrac = 1, 2, 512
        self.racs = self.nrac * 32 // SECT
        self.fatsz = 1
        while True:
            self.amas = (nsect - self.res - self.nfat * self.fatsz - self.racs) // self.spc
            if (self.amas + 2) * 2 <= self.fatsz * SECT:
                break
            self.fatsz += 1
        self.donnees = self.res + self.nfat * self.fatsz + self.racs
        self.fat = {0: 0xFFF8, 1: 0xFFFF}
        self.prochain = 2
        self.blocs = {}                                   # secteur relatif -> octets
        self.reps = {'': []}                              # chemin du repertoire -> entrees
        self.amas_rep = {}
        self.oem, self.etiquette = oem, etiquette

    def _alloue(self, n):
        a = self.prochain
        for k in range(n):
            self.fat[a + k] = a + k + 1 if k < n - 1 else 0xFFFF
        self.prochain += n
        assert self.prochain - 2 <= self.amas, "partition pleine"
        return a

    def _ecrire_amas(self, a, contenu):
        o = self.donnees + (a - 2) * self.spc
        for k in range(0, len(contenu), SECT):
            self.blocs[o + k // SECT] = contenu[k:k + SECT].ljust(SECT, b'\0')

    def repertoire(self, chemin):
        chemin = chemin.upper().strip('/')
        if chemin in self.reps:
            return
        parent, _, nom = chemin.rpartition('/')
        self.repertoire(parent)
        self.reps[chemin] = []
        self.amas_rep[chemin] = None
        self.reps[parent].append(('REP', nom, chemin))

    def ajouter(self, chemin, contenu, attr=0x20):
        chemin = chemin.upper().replace('\\', '/')
        rep, _, nom = chemin.rpartition('/')
        self.repertoire(rep)
        n = max(1, (len(contenu) + self.spc * SECT - 1) // (self.spc * SECT)) if contenu else 0
        a = self._alloue(n) if n else 0
        if n:
            self._ecrire_amas(a, contenu)
        self.reps[rep].append(struct.pack('<11sB8sHHHHI', nom83(nom), attr, bytes(8), a >> 16, 0x6000, 0x5D70,
                                          a & 0xFFFF, len(contenu)))

    def _entree_rep(self, nom, a):
        return struct.pack('<11sB8sHHHHI', nom, 0x10, bytes(8), a >> 16, 0x6000, 0x5D70, a & 0xFFFF, 0)

    def image(self, amorce):
        """Secteurs de la partition (dict secteur relatif -> octets) ; `amorce` = secteur
        d'amorce dont le code est garde (BPB remplace)."""
        # les sous-repertoires : un amas chacun (assez pour ~64 a 256 entrees), puis leur contenu
        for chemin in [c for c in self.reps if c]:
            n = max(1, ((len(self.reps[chemin]) + 2) * 32 + self.spc * SECT - 1) // (self.spc * SECT))
            self.amas_rep[chemin] = self._alloue(n)
        # etiquette du volume apres les fichiers : l'amorce de MS-DOS veut IO.SYS et MSDOS.SYS
        # dans les deux premieres entrees de la racine
        self.reps[''].append(struct.pack('<11sB10sHHHI', self.etiquette, 0x08, bytes(10), 0x6000, 0x5D70, 0, 0))
        for chemin, entrees in self.reps.items():
            brut = bytearray()
            if chemin:
                parent = chemin.rpartition('/')[0]
                brut += self._entree_rep(b'.          ', self.amas_rep[chemin])
                brut += self._entree_rep(b'..         ', self.amas_rep.get(parent) or 0)
            for e in entrees:
                if isinstance(e, tuple):
                    brut += self._entree_rep(nom83(e[1]), self.amas_rep[e[2]])
                else:
                    brut += e
            if chemin:
                self._ecrire_amas(self.amas_rep[chemin], bytes(brut))
            else:
                assert len(brut) <= self.nrac * 32
                for k in range(0, len(brut), SECT):
                    self.blocs[self.res + self.nfat * self.fatsz + k // SECT] = bytes(brut[k:k + SECT]).ljust(SECT, b'\0')
        fat = bytearray(self.fatsz * SECT)
        for a, v in self.fat.items():
            struct.pack_into('<H', fat, a * 2, v)
        for f in range(self.nfat):
            for k in range(self.fatsz):
                self.blocs[self.res + f * self.fatsz + k] = bytes(fat[k * SECT:(k + 1) * SECT])
        b = bytearray(amorce)
        struct.pack_into('<8sHBHBHHBHHHII', b, 3, self.oem, SECT, self.spc, self.res, self.nfat, self.nrac,
                         self.n if self.n < 65536 else 0, 0xF8, self.fatsz, SPT, TETES, self.debut,
                         self.n if self.n >= 65536 else 0)
        struct.pack_into('<BBBI11s8s', b, 36, 0x80, 0, 0x29, 0x5002, self.etiquette, b'FAT16   ')
        b[510:512] = b'\x55\xAA'
        self.blocs[0] = bytes(b)
        return self.blocs


def mbr_8086():
    """Code d'amorce du MBR (tests/mbr8086.asm, assemble par nasm)."""
    src = os.path.join(ICI, 'mbr8086.asm')
    out = os.path.join(ICI, '..', 'build', 'mbr8086.bin')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.check_call(['nasm', '-f', 'bin', '-o', out, src])
    code = open(out, 'rb').read()
    assert len(code) <= 446
    return code


def disque_dur(mo, remplir, amorce):
    """Image complete : MBR (code 8086) + partition FAT16 active a partir du secteur 63.
    remplir(fat16) ajoute les fichiers ; amorce = secteur d'amorce dont le code est garde."""
    cyl = (mo * 1024 * 1024) // (TETES * SPT * SECT)
    total = cyl * TETES * SPT
    n = total - SPT
    v = Fat16(n, SPT)
    remplir(v)
    blocs = v.image(amorce)
    out = bytearray(total * SECT)
    mbr = bytearray(SECT)
    code = mbr_8086()
    mbr[0:len(code)] = code
    c = cyl - 1
    mbr[0x1BE:0x1CE] = struct.pack('<BBBBBBBBII', 0x80, 1, 1, 0, 0x04 if n < 65536 else 0x06, TETES - 1,
                                   SPT | ((c >> 8) << 6), c & 0xFF, SPT, n)
    mbr[510:512] = b'\x55\xAA'
    out[0:SECT] = mbr
    for s, d in blocs.items():
        o = (SPT + s) * SECT
        out[o:o + SECT] = d
    return bytes(out)
