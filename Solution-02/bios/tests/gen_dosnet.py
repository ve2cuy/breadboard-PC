"""Disque dur C: avec MS-DOS 6.22 et le reseau : pilote de paquets S02PKT (module Wi-Fi en
SLIP par le BIOS 3.1) et mTCP (ping, telnet, ftp, htget...).

    python tests/gen_dosnet.py [SORTIE] [Mo]
        (par defaut ../../PC-DOS/DOSNET_C.IMG, 32 Mo)

Sources (hors de git) : celles de gen_dos622.py, PC-DOS/mTCP_2026-10-10.zip (mTCP de Michael
Brutman, GPL : https://www.brutman.com/mTCP/) et Solution-02/dos/S02PKT.COM (nasm -f bin -o
S02PKT.COM s02pkt.asm). Au demarrage, AUTOEXEC.BAT charge S02PKT et definit MTCPCFG ;
C:\\MTCP\\MTCP.CFG : adresse fixe 192.168.240.2, passerelle 192.168.240.1 (le module)."""
import io
import os
import sys
import zipfile

import fatlib
import gen_dos622

ICI = os.path.dirname(os.path.abspath(__file__))
DOS = os.path.normpath(os.path.join(ICI, '..', '..', '..', 'PC-DOS'))
MTCP_ZIP = os.path.join(DOS, 'mTCP_2026-10-10.zip')
PILOTE = os.path.normpath(os.path.join(ICI, '..', '..', 'dos', 'S02PKT.COM'))

MTCP_CFG = (b'# mTCP sur Solution-02 : pilote S02PKT (SLIP vers le module Wi-Fi, NAT)\r\n'
            b'PACKETINT 0x60\r\nIPADDR 192.168.240.2\r\nNETMASK 255.255.255.0\r\n'
            b'GATEWAY 192.168.240.1\r\nNAMESERVER 8.8.8.8\r\nMTU 576\r\n'
            b'HOSTNAME solution02\r\n')
AUTOEXEC = (b'@ECHO OFF\r\nPROMPT $P$G\r\nPATH C:\\DOS;C:\\MTCP\r\nSET TEMP=C:\\DOS\r\n'
            b'SET MTCPCFG=C:\\MTCP\\MTCP.CFG\r\nC:\\MTCP\\S02PKT\r\n'
            b'ECHO MS-DOS 6.22 et mTCP sur le disque C: de Solution-02\r\n')


def fichiers_mtcp():
    z = zipfile.ZipFile(MTCP_ZIP)
    f = {}
    for n in z.namelist():
        base = os.path.basename(n)
        if base.lower().endswith(('.exe', '.txt', '.sys')) and '/' not in n.strip('/'):
            f['MTCP/' + base.upper()] = z.read(n)
    return f


def construire(mo=32):
    extras = fichiers_mtcp()
    extras['MTCP/S02PKT.COM'] = open(PILOTE, 'rb').read()
    extras['MTCP/MTCP.CFG'] = MTCP_CFG
    gen_dos622.AUTOEXEC = AUTOEXEC
    origine = fatlib.disque_dur

    def disque_dur(mo_, remplir, amorce):
        def remplir2(v):
            remplir(v)
            v.repertoire('MTCP')
            for nom in sorted(extras):
                v.ajouter(nom, extras[nom])
        return origine(mo_, remplir2, amorce)

    gen_dos622.fatlib.disque_dur = disque_dur
    try:
        return gen_dos622.construire(mo)
    finally:
        gen_dos622.fatlib.disque_dur = origine


if __name__ == '__main__':
    sortie = sys.argv[1] if len(sys.argv) > 1 else os.path.join(DOS, 'DOSNET_C.IMG')
    mo = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    img, n = construire(mo)
    open(sortie, 'wb').write(img)
    print('%s : %d octets, %d fichiers de MS-DOS, mTCP et S02PKT dans C:\\MTCP' % (sortie, len(img), n))
