"""Disque dur C: avec FreeDOS 1.4 et le reseau : pilote de paquets S02PKT et mTCP (ping, htget,
telnet, ftp, sntp...). Tout est libre (FreeDOS, mTCP : GPL) : l'image peut etre publiee avec le
simulateur (Simulateur-Pico), contrairement a DOSNET_C.IMG (MS-DOS 6.22).

    python tests/gen_fdnet.py [SORTIE] [Mo]
        (par defaut ../../PC-DOS/FDNET_C.IMG, 32 Mo)

Sources : celles de gen_freedos.py et de gen_dosnet.py (mTCP, S02PKT.COM). FDAUTO.BAT charge
S02PKT et definit MTCPCFG ; C:\\MTCP\\MTCP.CFG : 192.168.240.2, passerelle 192.168.240.1 (le
Pico W, ou le module Wi-Fi de l'ATmega)."""
import os
import sys

import fatlib
import gen_dosnet
import gen_freedos

ICI = os.path.dirname(os.path.abspath(__file__))
DOS = os.path.normpath(os.path.join(ICI, '..', '..', '..', 'PC-DOS'))

FDAUTO = (b'@ECHO OFF\r\nSET DOSDIR=C:\\FREEDOS\r\nSET PATH=C:\\FREEDOS\\BIN;C:\\MTCP\r\n'
          b'SET NLSPATH=C:\\FREEDOS\\NLS\r\nSET HELPPATH=C:\\FREEDOS\\HELP\r\n'
          b'SET TEMP=C:\\FREEDOS\\TEMP\r\nSET TMP=%TEMP%\r\nSET LANG=FR\r\nSET TZ=EST5EDT\r\nPROMPT $P$G\r\n'
          b'SET MTCPCFG=C:\\MTCP\\MTCP.CFG\r\nC:\\MTCP\\S02PKT\r\n'
          b'ECHO FreeDOS 1.4 et mTCP sur le disque C: de Solution-02\r\n'
          b'ECHO Essais : PING 192.168.240.1   PING 8.8.8.8   HTGET http://www.s02/\r\n')


def construire(mo=32):
    extras = gen_dosnet.fichiers_mtcp()
    extras['MTCP/S02PKT.COM'] = open(gen_dosnet.PILOTE, 'rb').read()
    extras['MTCP/MTCP.CFG'] = gen_dosnet.MTCP_CFG
    gen_freedos.FDAUTO = FDAUTO
    origine = fatlib.disque_dur

    def disque_dur(mo_, remplir, amorce):
        def remplir2(v):
            remplir(v)
            v.repertoire('MTCP')
            for nom in sorted(extras):
                v.ajouter(nom, extras[nom])
        return origine(mo_, remplir2, amorce)

    gen_freedos.fatlib.disque_dur = disque_dur
    try:
        return gen_freedos.construire(mo)
    finally:
        gen_freedos.fatlib.disque_dur = origine


if __name__ == '__main__':
    sortie = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DOS, 'FDNET_C.IMG')
    mo = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    img, paquets, n = construire(mo)
    open(sortie, 'wb').write(img)
    print('%s : %d octets, FreeDOS (%d fichiers), mTCP et S02PKT dans C:\\MTCP' % (sortie, len(img), n))
