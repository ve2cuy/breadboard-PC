"""Disque dur C: avec FreeDOS 1.4 installe (version 8086), pour la carte SD de Solution-02.

    python tests/gen_freedos.py [SORTIE] [Mo]
        (par defaut ../../PC-DOS/FREEDOS_C.IMG, 32 Mo)

Sources (ouvertes par le tar de Windows ; les archives et l'image ne vont PAS dans git) :
  - PC-DOS/FD14-FloppyEdition.zip, 144m/x86BOOT.img : le noyau 8086 (KERNEL.SYS) ;
  - PC-DOS/FD14-LiteUSB.zip, FD14LITE.img : le secteur d'amorce FAT16 de FreeDOS (son code,
    avec notre BPB) et les paquets PACKAGES/BASE/*.ZIP, installes comme FDINST : BIN, DOC,
    HELP, NLS, APPINFO... dans C:\\FREEDOS (sans les sources ni les paquets 286/386 :
    JEMM, HIMEMX, FDXMS*). COMMAND.COM (FreeCOM) a la racine aussi.
FDCONFIG.SYS et FDAUTO.BAT simples (8088, sans memoire etendue). MBR : tests/mbr8086.asm."""
import io
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

import fatlib

ICI = os.path.dirname(os.path.abspath(__file__))
DOS = os.path.normpath(os.path.join(ICI, '..', '..', '..', 'PC-DOS'))
TAR = os.path.join(os.environ.get('SystemRoot', 'C:\\Windows'), 'System32', 'tar.exe')
EXCLUS = ('JEMM', 'HIMEMX', 'FDXMS', 'FDXMS286', 'HTMLHELP')   # 286/386, ou trop gros

# STACKS=0,0 : sans lui, le noyau detourne IRQ0/IRQ1/IRQ4 (INT 08h, 09h, 0Ch) par un relais qui
# change de pile ; le delai fait manquer le bit de depart de l'UART logiciel (octets decales
# d'un bit) et les premiers fronts du clavier PS/2 (lus bit par bit des l'interruption).
FDCONFIG = (b'FILES=20\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\nSTACKS=0,0\r\n'
            b'SHELL=C:\\COMMAND.COM C:\\ /E:1024 /P=C:\\FDAUTO.BAT\r\n')
FDAUTO = (b'@ECHO OFF\r\nSET DOSDIR=C:\\FREEDOS\r\nSET PATH=C:\\FREEDOS\\BIN\r\n'
          b'SET NLSPATH=C:\\FREEDOS\\NLS\r\nSET HELPPATH=C:\\FREEDOS\\HELP\r\n'
          b'SET TEMP=C:\\FREEDOS\\TEMP\r\nSET TMP=%TEMP%\r\nSET LANG=FR\r\nPROMPT $P$G\r\n'
          b'ECHO FreeDOS 1.4 sur le disque C: de Solution-02\r\n')


def extraire(archive, membre):
    tmp = tempfile.mkdtemp(prefix='fd14_')
    subprocess.check_call([TAR, '-xf', os.path.join(DOS, archive), '-C', tmp, membre])
    return open(os.path.join(tmp, membre), 'rb').read()


def construire(mo=32):
    disquette = fatlib.Volume(extraire('FD14-FloppyEdition.zip', '144m/x86BOOT.img'))
    noyau = disquette.lire('KERNEL.SYS')
    assert b'386' not in noyau[:2048], "noyau 8086 attendu"
    lite = extraire('FD14-LiteUSB.zip', 'FD14LITE.img')
    debut = struct.unpack_from('<I', lite, 0x1BE + 8)[0]
    amorce = lite[debut * 512:debut * 512 + 512]
    usb = fatlib.Volume(lite, debut)
    fichiers = {}                                               # chemin sous C:\FREEDOS -> contenu
    paquets = []
    for chemin, attr, contenu in usb.fichiers():
        if not (chemin.startswith('PACKAGES/BASE/') and chemin.endswith('.ZIP')):
            continue
        nom = chemin.rsplit('/', 1)[1][:-4]
        if nom in EXCLUS:
            continue
        paquets.append(nom)
        with zipfile.ZipFile(io.BytesIO(contenu)) as z:
            for i in z.infolist():
                c = i.filename.replace('\\', '/').upper()
                if i.is_dir() or c.startswith(('SOURCE/', 'SOURCES/')) or '/' not in c:
                    continue
                if any(len(p.split('.')[0]) > 8 or len(p.split('.', 1)[-1]) > 3 and '.' in p
                       for p in c.split('/')):
                    continue                                    # pas un nom 8.3
                fichiers.setdefault(c, z.read(i))
    commande = fichiers.get('BIN/COMMAND.COM') or usb.lire('COMMAND.COM')

    def remplir(v):
        v.ajouter('KERNEL.SYS', noyau, 0x27)
        v.ajouter('COMMAND.COM', commande)
        v.ajouter('FDCONFIG.SYS', FDCONFIG)
        v.ajouter('FDAUTO.BAT', FDAUTO)
        v.repertoire('FREEDOS/TEMP')
        for c in sorted(fichiers):
            v.ajouter('FREEDOS/' + c, fichiers[c])
    return fatlib.disque_dur(mo, remplir, amorce), paquets, len(fichiers)


if __name__ == '__main__':
    sortie = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DOS, 'FREEDOS_C.IMG')
    mo = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    image, paquets, n = construire(mo)
    open(sortie, 'wb').write(image)
    print('%s : %d octets, %d paquets, %d fichiers dans C:\\FREEDOS' % (sortie, len(image), len(paquets), n))
    print(' '.join(paquets))
