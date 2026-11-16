"""Disque dur C: avec MS-DOS 6.22 installe, pour la carte SD de Solution-02.

    python tests/gen_dos622.py [SORTIE] [Mo]
        (par defaut ../../PC-DOS/DOS622_C.IMG, 32 Mo)

Source : PC-DOS/"Microsoft MS-DOS 6.22 [French] (3.5-1.44mb).7z" (4 disquettes de 1,44 Mo ;
ouverte par le tar de Windows ; l'archive et l'image ne vont PAS dans git). Comme SETUP :
IO.SYS et MSDOS.SYS (caches, systeme) puis COMMAND.COM a la racine, CONFIG.SYS et
AUTOEXEC.BAT simples (sans KEYB ni HIMEM : 8088), tous les fichiers des disquettes dans
C:\\DOS (les *.??_ decompresses). Secteur d'amorce de MS-DOS 6.22 (celui de la disquette 1)
avec un BPB de disque dur ; MBR : tests/mbr8086.asm. Partition FAT16 active (16 tetes x
63 secteurs)."""
import glob
import os
import subprocess
import sys
import tempfile

import fatlib

ICI = os.path.dirname(os.path.abspath(__file__))
DOS = os.path.normpath(os.path.join(ICI, '..', '..', '..', 'PC-DOS'))
ARCHIVE = os.path.join(DOS, 'Microsoft MS-DOS 6.22 [French] (3.5-1.44mb).7z')

CONFIG = b'FILES=30\r\nBUFFERS=20\r\nLASTDRIVE=E\r\nSHELL=C:\\COMMAND.COM C:\\ /P\r\n'
AUTOEXEC = (b'@ECHO OFF\r\nPROMPT $P$G\r\nPATH C:\\DOS\r\nSET TEMP=C:\\DOS\r\n'
            b'ECHO MS-DOS 6.22 sur le disque C: de Solution-02\r\n')
EXT = {'CO_': 'COM', 'EX_': 'EXE', 'SY_': 'SYS', 'HL_': 'HLP', 'TX_': 'TXT', 'CP_': 'CPI',
       '38_': '386', 'DL_': 'DLL', 'IN_': 'INI', 'GR_': 'GRP', 'OV_': 'OVL', 'BI_': 'BIN',
       'PI_': 'PIF', 'BA_': 'BAS', 'IC_': 'ICO', 'VI_': 'VID', 'DO_': 'DOS'}
NOMS = {'DRVBOOT.BA_': 'DRVBOOT.BAT'}                          # ni dans PACKING.LST ni par l'extension
RACINE = ('IO.SYS', 'MSDOS.SYS', 'COMMAND.COM', 'AUTOEXEC.BAT', 'CONFIG.SYS')


def disquettes():
    tmp = tempfile.mkdtemp(prefix='dos622_')
    subprocess.check_call([os.path.join(os.environ.get('SystemRoot', 'C:\\Windows'), 'System32', 'tar.exe'),
                           '-xf', ARCHIVE, '-C', tmp])
    return [open(f, 'rb').read() for f in sorted(glob.glob(os.path.join(tmp, '*', 'DISK0*.IMG')))]


def construire(mo=32):
    images = disquettes()
    assert len(images) == 4, "4 disquettes attendues"
    d1 = fatlib.Volume(images[0])
    amorce = images[0][0:512]
    noms = {}                                                 # PACKING.LST : compresse -> nom
    for ligne in d1.lire('PACKING.LST').decode('cp850').splitlines():
        m = ligne.split()
        if len(m) == 2 and m[0].endswith('_'):
            noms[m[0].upper()] = m[1].upper()
    noms.update(NOMS)
    dos = {}                                                  # C:\DOS : nom -> contenu
    for im in images:
        for chemin, attr, contenu in fatlib.Volume(im).fichiers():
            if '/' in chemin or chemin in ('IO.SYS', 'MSDOS.SYS', 'AUTOEXEC.BAT', 'CONFIG.SYS'):
                continue
            nom, brut = chemin, contenu
            clair = fatlib.kwaj(contenu)
            if clair is not None:
                contenu = clair
                if nom in noms:
                    nom = noms[nom]
                elif nom.rsplit('.', 1)[1] in EXT:            # absent de la liste : l'extension
                    nom = nom[:-3] + EXT[nom.rsplit('.', 1)[1]]
                else:                                         # inconnue (reseau : *.1X_, *.2X_) :
                    contenu = brut                            # laisse compresse, pour EXPAND
            dos.setdefault(nom, contenu)

    def remplir(v):
        v.ajouter('IO.SYS', d1.lire('IO.SYS'), 0x27)          # d'abord : l'amorce les charge
        v.ajouter('MSDOS.SYS', d1.lire('MSDOS.SYS'), 0x27)
        v.ajouter('COMMAND.COM', d1.lire('COMMAND.COM'))
        v.ajouter('CONFIG.SYS', CONFIG)
        v.ajouter('AUTOEXEC.BAT', AUTOEXEC)
        for nom in sorted(dos):
            v.ajouter('DOS/' + nom, dos[nom])
    return fatlib.disque_dur(mo, remplir, amorce), len(dos)


if __name__ == '__main__':
    sortie = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DOS, 'DOS622_C.IMG')
    mo = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    image, n = construire(mo)
    open(sortie, 'wb').write(image)
    print('%s : %d octets, %d fichiers dans C:\\DOS' % (sortie, len(image), n))
