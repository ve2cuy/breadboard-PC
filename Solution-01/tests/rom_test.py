#!/usr/bin/env python3
"""Scenarios de bout en bout avec IRQ1 ASYNCHRONES (tests/rom_sim.py): DOS reels, trace, points
d'amorcage, et - option --complet, plusieurs minutes - la ROM COMPLETE (menu, Ctrl-\\, BASIC).

Ce que les autres bancs ne voient pas: le passage de chaque octet par le 8255, le 8259 et l'ISR, le
masquage d'IR1 pendant les commandes au pont (scrutation), le redemarrage a chaud.

Usage (depuis la racine de Solution-01):  python tests/rom_test.py [--complet]   (ou: make test-rom)
"""
import os, re, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import rom_sim as S

DOS = os.path.join(S.ROOT, '..', 'PC-DOS')
fails = total = 0


def check(name, cond, extra=''):
    global fails, total
    total += 1
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '   -> ' + str(extra)[-300:]))
    if not cond:
        fails += 1


def img(name):
    return open(os.path.join(DOS, name), 'rb').read()


def dos(image, dos3, commands, **kw):
    cases, mem = S.boot_image('D.IMG')
    kw.setdefault('tail_blocks', 200_000)
    st = S.run_bios(cases, mem, S.dos_script(dos3, commands), bridge=S.H.BridgeModel(files={'D.IMG': img(image)}), **kw)
    return st, st['out'].decode('latin-1')


def common(tag, st, out):
    check(tag + ': scenario complet (FIN_OK)', st['done'] and 'FIN_OK\r\n' in out and not st['err'], out[-300:] + str(st['err']))
    check(tag + ': aucune interruption non implementee', 'non implementee' not in out, out[-300:])
    check(tag + ': reponses du pont lues par scrutation (IR1 masquee/demasquee, peu d IRQ1)',
          st['masks'].get(0xFE, 0) > 10 and st['masks'].get(0xFC, 0) > 10 and st['irqs'] < 2000,
          '%s irqs=%d' % (st['masks'], st['irqs']))


# --- MS-DOS 3.30: creer, lire, supprimer un fichier ---
if os.path.exists(os.path.join(DOS, 'Dos33-d1.IMG')):
    # (copy con: le texte et Ctrl-Z suivent la commande sans attendre A> - elle ne revient qu'apres)
    st, out = dos('Dos33-d1.IMG', True, [b'copy con t.txt\rhello world\r\x1a\r', b'type t.txt\r',
                                         b'del t.txt\r', b'dir t.txt\r'])
    common('MS-DOS 3.30', st, out)
    check('MS-DOS 3.30: copy con / type / del / dir',
          '1 File(s) copied' in out and out.count('hello world') >= 2 and 'File not found' in out, out[-600:])

# --- PC-DOS 2.1: la copie a jokers qui avait fige le materiel ---
if os.path.exists(os.path.join(DOS, 'pcdos2_1.img')):
    st, out = dos('pcdos2_1.img', False, [b'copy con test.txt\r0123456789ab\r\x1a\r',
                                          b'copy con test2.txt\r' + b'x' * 37 + b'\r\x1a\r',
                                          b'copy test?.* test?.abc\r', b'del test.abc\r', b'dir test*.*\r'])
    common('PC-DOS 2.1', st, out)
    check('PC-DOS 2.1: copie a jokers puis del (TEST2.ABC present, TEST.ABC supprime)',
          re.search(r'TEST2 +ABC +39', out) is not None and re.search(r'\r\nTEST +ABC', out.split('dir test')[-1]) is None,
          out[-500:])
    i, j = out.find('(A:)'), out.find('Current date')
    check('PC-DOS 2.1: points de progression pendant l amorcage, puis passage a la ligne',
          i >= 0 and j > i and out[i:j].count('.') >= 20 and '.\r\n' in out[i:j], repr(out[i:j][-120:]))

    # --- trace basculee par Ctrl-T (14h): lignes <13 ...> completes, INT 1Ah AH=00h filtre ---
    st, out = dos('pcdos2_1.img', False, [b'\x14dir more.com\r', b'\x14ver\r'])
    trc = out.split('ACTIVE')[-1].split('ARRETEE')[0] if 'ACTIVE' in out else ''
    check('Trace: Ctrl-T annonce ACTIVE puis ARRETEE, sans transmettre la touche au DOS',
          'Trace BIOS ACTIVE' in out and 'Trace BIOS ARRETEE' in out and st['done'], out[-300:])
    check('Trace: lignes INT 13h completes pendant DIR, aucune ligne INT 1Ah AH=00h',
          len(re.findall(r'<13 [0-9A-F ]+-[0-9A-F ]+ [01]>', trc)) >= 3 and '<1A 00' not in trc, trc[-300:])

# --- Clavier PS/2: un relachement (F0 xx) ne doit pas bloquer une verification d'Echap ---
# (Configuration -> '2' Test CPU speed et '4' Information: le relachement de la touche qui lance
# l'action faisait attendre une vraie touche a chaque checkpoint / rafraichissement - voir ps2_poll_char)
class TickingBridge(S.H.BridgeModel):
    """pont dont l'horloge avance d'une seconde a chaque lecture (GET_TIME)"""
    def _exec(self, c):
        r = super()._exec(c)
        if c[0] == 0x01:
            self.clock[6] = (self.clock[6] + 1) % 60
        return r

st = S.run_rom([(S.MENU, S.ps2(0x25)), (b'2) ', S.ps2(0x1E)), (b'Vitesse estimee: ', b'')],
               count=400_000_000, tail_blocks=200_000)
out = st['out'].decode('latin-1')
check('PS/2: Test CPU speed avance seul (30 points) et se termine sans aucune frappe',
      st['done'] and '.' * 30 in out, out[-300:])
st = S.run_rom([(S.MENU, S.ps2(0x25)), (b'2) ', S.ps2(0x25)), (b'12:34:59', S.ps2(0x76)), (b'2) ', b'')],
               bridge=TickingBridge(), count=400_000_000, tail_blocks=200_000)
out = st['out'].decode('latin-1')
check('PS/2: Information rafraichit l heure sans frappe (56 -> 59), puis Echap revient au sous-menu',
      st['done'] and out.count('Sous-menu Configuration') == 2, out[-300:])

# --- RAM de 512 Ko (-dRAM_512K, make rom-512): zone reservee en 7000:F800, 510 Ko annonces au DOS ---
st = S.run_rom([(S.MENU, b'4'), (b'4) ', b'4'), (b'Disque', b'\x1b'), (b'1) ', b'')], defines=('RAM_512K',),
               tail_blocks=50_000)
out = st['out'].decode('latin-1')
check('RAM 512K: l ecran Information annonce 510 Ko', st['done'] and 'RAM:510K' in out, out[-300:])
if os.path.exists(os.path.join(DOS, 'pcdos2_1.img')):
    st = S.run_rom([(S.MENU, b'3'), (b'Boot disk image', b'3'), (b'): ', b'1'), (b'Enter new date: ', b'\r'),
                    (b'Enter new time: ', b'\r'), (b'A>', b'chkdsk\r'), (b'A>', b'')], defines=('RAM_512K',),
                   bridge=S.H.BridgeModel(files={'D.IMG': img('pcdos2_1.img')}), tail_blocks=200_000)
    out = st['out'].decode('latin-1')
    check('RAM 512K: PC-DOS 2.1 demarre et CHKDSK voit 522240 octets (INT 12h = 510 Ko)',
          st['done'] and '522240 bytes total memory' in out, out[-400:])

st = S.run_rom([(S.MENU, b'4'), (b'4) ', b'4'), (b'Disque', b'\x1b'), (b'1) ', b'')], defines=(),
               tail_blocks=50_000)
out = st['out'].decode('latin-1')
check('RAM 128K (make rom-128): l ecran Information annonce 126 Ko', st['done'] and 'RAM:126K' in out, out[-300:])
# Edit+Run: code edite ET execute en 1000:0000 (EDIT_RUN_SEG), meme quand VAR_SEG = 7000h
st = S.run_rom([(S.MENU, b'2'), (b'6) ', b'4'), (b'Echap', b'r'), (b'DI', b'\x1b'), (b'6) Test RAM', b'')],
               tail_blocks=200_000, count=300_000_000)
out = st['out'].decode('latin-1')
check('Edit+Run (512K): R execute le code par defaut en 1000:0000 (AX=0001 BX=0002), Echap revient au menu',
      st['done'] and 'AX=0001' in out and 'BX=0002' in out, out[-400:])

# --- horloge de 1 Hz a 10 MHz (pont 2.0): affichage sous 1 MHz (ROM 1.3) ---
for hz, txt in ((1, b'    1 Hz '), (500, b'  500 Hz '), (250000, b'  250 kHz'), (4800000, b' 4.80 MHz')):
    br = S.H.BridgeModel()
    br.clock_hz = hz
    st = S.run_rom([(S.MENU, b'4'), (b'4) ', b'1'), (b'Current speed: ' + txt, S.ps2(0x76)), (b'4) ', S.ps2(0x76)),
                    (S.MENU, b'')], bridge=br, tail_blocks=50_000)
    out = st['out']
    check('Clock speed a %d Hz: "%s" au sous-menu puis au menu principal' % (hz, txt.decode()),
          st['done'] and out.count(txt + b'\r\n') >= 2, out[-300:])

# --- BIOS de reglages (ROM 1.7, pont 2.2): Echap au demarrage, enregistrement, demarrage automatique ---
br = S.H.BridgeModel()
st = S.run_rom([(b'ESC pour lancer le BIOS', b'\x1b'), (b'Entree : enregistrer', b'1'), (b'Entree : enregistrer', b'4'),
                (b'Entree : enregistrer', b'5'), (b'Entree : enregistrer', b'\r'), (S.MENU, b'')], bridge=br, tail_blocks=50_000)
out = st['out'].decode('latin-1')
check('BIOS: Echap au demarrage, 3 reglages changes, Entree les envoie au pont (2Fh), puis le menu',
      st['done'] and 'Reglages enregistres' in out and bytes(br.cfg[:8]) == bytes([1, 1, 1, 1, 0x40, 0x4B, 0x4C, 0])
      and br.cfg_writes == 1, out[-300:] + ' ' + bytes(br.cfg).hex())
br = S.H.BridgeModel()
st = S.run_rom([(S.MENU, b'4'), (b'5) BIOS', b'5'), (b'Entree : enregistrer', b'2'), (b'Entree : enregistrer', b'\x1b'),
                (b'Sous-menu Configuration', b'')], bridge=br, tail_blocks=50_000)
out = st['out'].decode('latin-1')
check('BIOS: Configuration 5), Echap annule (rien envoye au pont)', st['done'] and br.cfg_writes == 0
      and 'Console LCD dans le DOS ........ Non' in out, out[-300:])
br = S.H.BridgeModel(cfg=[1, 0, 1, 1, 0xD0, 0xC8, 0x48, 0] + [0] * 8)
st = S.run_rom([(b'Ok', b'PRINT 6*7\r'), (b' 42', b'SYSTEM\r'), (S.MENU, b'')], bridge=br, tail_blocks=50_000)
check('BIOS: demarrage dans GW-BASIC (console au LCD demandee, 2Dh), SYSTEM -> menu',
      st['done'] and getattr(br, 'lcd_con', 0) == 1, st['out'][-300:])
br = S.H.BridgeModel(cfg=[1, 1, 1, 1, 0xD0, 0xC8, 0x48, 0] + [0] * 8)
st = S.run_rom([(b'Ok', b'SYSTEM\r'), (S.MENU, b'')], bridge=br, tail_blocks=50_000)
check('BIOS: console LCD du BASIC coupee -> pas de 2Dh', st['done'] and getattr(br, 'lcd_con', 0) == 0, st['out'][-300:])
br = S.H.BridgeModel(cfg_ok=False)
st = S.run_rom([(S.MENU, b'4'), (b'5) BIOS', b'5'), (b'Entree : enregistrer', b'\r'), (b'NON enregistres', b''),
                (b'Sous-menu Configuration', b'')], bridge=br, tail_blocks=50_000)
check('BIOS: pont < 2.2 (2Eh sans reponse): defauts, rien envoye, message', st['done']
      and not any(op == 0x2F for op, _ in br.log), st['out'][-300:])

# --- clavier PS/2 complet (ROM 1.8, lib/kbd.asm): saisie au BASIC et au DOS (INT 16h), Maj suivie ---
def raw(*b):
    return [(S.PC_TAG_PS2, x) for x in b]
keys = S.ps2(0x4D, 0x2D, 0x43, 0x31, 0x2C, 0x29, 0x36) + raw(0x12) + S.ps2(0x3E) + raw(0xF0, 0x12) + S.ps2(0x3D, 0x5A)
br = S.H.BridgeModel(cfg=[1, 0, 1, 1, 0xD0, 0xC8, 0x48, 0] + [0] * 8)
st = S.run_rom([(b'Ok', keys), (b' 42', b'SYSTEM\r'), (S.MENU, b'')], bridge=br, tail_blocks=50_000, count=300_000_000)
check('Clavier PS/2: "print 6*7" tape au BASIC (Maj + 8 = *) -> 42', st['done'] and b'print 6*7' in st['out'],
      st['out'][-300:])
ver = raw(0x12) + S.ps2(0x2A, 0x24, 0x2D) + raw(0xF0, 0x12) + S.ps2(0x5A)
st = S.run_rom([(S.MENU, b'3'), (b'4) DOS 2.1', b'4'), (b'(RTC)', b''), (b'B>', ver), (b'DOS Version', b'DATE\r\r'),
                (b'Enter new date', b'')], tail_blocks=50_000, count=1_500_000_000)
out = st['out'].decode('latin-1')
check('Clavier PS/2: DOS 2.1 de la ROM, "VER" (Maj + v e r) par INT 16h', st['done'] and 'B>VER' in out, out[-300:])
check('SETTIME: l AUTOEXEC du DOS de la ROM regle la date et l heure d apres la RTC (DATE: 9-20-2026)',
      st['done'] and 'SETTIME: 20-09-2026 12:34:' in out and 'Current date is Sun  9-20-2026' in out
      and 'Enter new date' not in out.split('DATE')[0], out[-400:])

# --- SETTIME (ROM 1.8, dos/SETTIME.EXE) sous PC-DOS 2.1 et MS-DOS 3.30: date et heure du DOS = RTC du pont.
# --- (aussi: compteur de ticks a 18,2065/s et faux passages de minuit - INT 1Ah AH=00h/01h, lib/bios.asm) ---
import gen_settime as G
for image, dos3 in (('pcdos2_1.img', False), ('Dos33-d1.IMG', True)):
    if not os.path.exists(os.path.join(DOS, image)):
        continue
    disque = G.ajouter_fat12(img(image), 'SETTIME.EXE', open(os.path.join(S.ROOT, 'dos', 'SETTIME.EXE'), 'rb').read())
    cases, mem = S.boot_image('D.IMG')
    st = S.run_bios(cases, mem, S.dos_script(dos3, [b'settime\r', b'date\r\r', b'time\r\r']),
                    bridge=S.H.BridgeModel(files={'D.IMG': disque}), tail_blocks=200_000)
    out = st['out'].decode('latin-1')
    fin = out[out.rfind('settime'):]
    check('SETTIME sous %s: date 9-20-2026 (sans jour de trop) et heure 12:34:5x' % image,
          st['done'] and 'SETTIME: 20-09-2026 12:34:5' in fin and 'Current date is Sun  9-20-2026' in fin
          and 'Current time is 12:34:5' in fin, fin[-400:])

# --- EDIT.COM (ROM 1.9, dos/EDIT.ASM): editeur plein ecran. Au DOS de la ROM: saisie, haut/bas (colonne
# --- gardee), Debut/Fin, Suppr (joint deux lignes), tabulation, PgPrec/PgSuiv, Echap + N, F2; ecriture sur
# --- A: (ROM) refusee proprement (pas d'"Abort, Retry"); puis sous MS-DOS 3.30 et PC-DOS 2.1, par les
# --- numeros de fichier et par les FCB (chemin du DOS 1.x, force par -dFORCE_FCB) ---
E = b'\x1b'
UP, DOWN, HOME, END, PGUP, PGDN, DEL, F2 = (E + b'[A', E + b'[B', E + b'[H', E + b'[F', E + b'[5~', E + b'[6~',
                                            E + b'[3~', E + b'OQ')
lignes = b''.join(b'L%d\r' % i for i in range(60))
st = S.run_rom([(S.MENU, b'3'), (b'4) DOS 2.1', b'4'), (b'(RTC)', b''),
                (b'B>', b'EDIT T.TXT\r'),
                (b'quitter', b'Ligne 1\rLigne 2\r\tfin' + UP + UP + HOME + b'X' + END + b'Y' + DOWN + DEL + b'L' + E),
                (b'(O/N', b'o'), (b'B>', b'TYPE T.TXT\r'), (b'fin', b''),
                (b'B>', b'EDIT LONG.TXT\r'), (b'quitter', lignes + PGUP + PGUP + b'Z' + PGDN + b'W' + E),
                (b'(O/N', E), (b'quitter', E + b'[12~'), (b'B>', b'TYPE LONG.TXT\r'), (b'L59', b''),
                (b'B>', b'EDIT A:NEUF.TXT\r'), (b'quitter', b'abc' + F2), (b'Une touche', b'x'), (b'quitter', E),
                (b'(O/N', b'n'), (b'B>', b'')], tail_blocks=50_000, count=3_000_000_000)
out = st['out'].decode('latin-1')
t1 = out[out.find('TYPE T.TXT'):]
t2 = out[out.find('TYPE LONG.TXT'):]
t3 = out[out.find('EDIT A:NEUF'):]
check('EDIT: saisie, fleches, Debut/Fin, Suppr, tabulation, Echap + O enregistre (DOS de la ROM)',
      st['done'] and 'XLigne 1Y\r\nLigne 2L        fin' in t1, repr(t1[:80]))
check('EDIT: PgPrec/PgSuiv sur 60 lignes, Echap puis Echap continue, F2 de PuTTY (ESC [ 12~) enregistre',
      st['done'] and 'ZL14' in t2 and 'LW37' in t2, t2[:200])
check('EDIT: enregistrer sur A: (ROM) -> message, pas d Abort/Retry, Echap + N quitte sans enregistrer',
      st['done'] and 'Impossible de creer' in t3 and 'Abort' not in t3, repr(t3[-300:]))
subprocess.run(['nasm', '-f', 'bin', '-dFORCE_FCB', 'dos/EDIT.ASM', '-o', 'build/EDITFCB.COM'], cwd=S.ROOT, check=True)
for image, dos3 in (('Dos33-d1.IMG', True), ('pcdos2_1.img', False)):
    if not os.path.exists(os.path.join(DOS, image)):
        continue
    for prog, src in ((b'EDIT', 'dos/EDIT.COM'), (b'EDITFCB', 'build/EDITFCB.COM')):
        disque = G.ajouter_fat12(img(image), prog.decode() + '.COM', open(os.path.join(S.ROOT, src), 'rb').read())
        script = S.dos_script(dos3, [])[:-2] + [
            (b'A>', prog + b' T.TXT\r'), (b'quitter', b'un\rdeux' + UP + HOME + b'>' + F2),
            (b'A>', prog + b' T.TXT\r'), (b'quitter', END + b'<' + F2), (b'A>', b'TYPE T.TXT\r'), (b'deux', b'')]
        cases, mem = S.boot_image('D.IMG')
        st = S.run_bios(cases, mem, script, bridge=S.H.BridgeModel(files={'D.IMG': disque}), tail_blocks=200_000)
        out = st['out'].decode('latin-1')
        check('EDIT sous %s (%s): creer, rouvrir, modifier' % (image, 'FCB, DOS 1.x' if prog == b'EDITFCB' else 'numeros de fichier'),
              st['done'] and '>un<\r\ndeux' in out[out.find('TYPE T.TXT'):], out[-300:])

# --- ELKS / Minix (ROM 2.0, pont 2.3, Solution-01/elks): image construite par elks/construire.ps1, copiee en
# --- PC-DOS/ELKS-0.9.2/fd360-minix-s01.img (hors de git). Le tic du pont (30h, 9Ch) -> INT 1Ch -> ELKS
# --- (CONFIG_TIMER_INT1C): clavier par INT 16h, horloge par INT 1Ah (clock), aucun port du 8255/8259 touche
# --- hors du BIOS (80h-83h par outb_p, 3F2h, 3FBh, 70h, 61h...): seuls 4Fh (pause d'E/S) et 510h ---
elks = os.path.join(DOS, 'ELKS-0.9.2', 'fd360-minix-s01.img')
if os.path.exists(elks):
    cases, mem = S.boot_image('E.IMG')
    br = S.H.BridgeModel(files={'E.IMG': img(os.path.join('ELKS-0.9.2', 'fd360-minix-s01.img'))})
    st = S.run_bios(cases, mem, [(b'login:', b'root\r'), (b'# ', b'ls /\r'), (b'# ', b'date\r'), (b'# ', b'')],
                    bridge=br, defines=('RAM_512K',), tail_blocks=300_000)
    out = st['out'].decode('latin-1')
    fin = out[out.find('login:'):]
    check('ELKS (Minix): login root, ls /, date = RTC du pont (2026), tic du pont en marche',
          st['done'] and 'root' in fin and 'bootopts' in fin and 'Sep 20 12:3' in fin and '2026' in fin
          and br.tick_on and st.get('ticks', 0) > 50, fin[-400:])
    check('ELKS (Minix): tic a 100 Hz demande au BIOS (INT 1Ah AH=E0h -> pont 32h, ROM 2.2)',
          getattr(br, 'tick_fast', False) and any(op == 0x32 for op, _ in br.log), sorted({hex(op) for op, _ in br.log}))
    check('ELKS (Minix): aucun port du 8255/8259 hors de ceux du BIOS (pas de 70h, 80h par outb_p, 3FBh...)',
          st['badports'] <= {0x4F, 0x510} and not st.get('etranger8255'),
          '%s 8255 hors ROM: %s' % (sorted(hex(p) for p in st['badports']), st.get('etranger8255')))

# --- menu principal: 5) Boot from disk (ROM 2.3): la liste des images (comme USB Disk -> 3), Echap -> menu ---
br = S.H.BridgeModel(files={'ELKSS01.IMG': bytes(368640)})
st = S.run_rom([(S.MENU, b'5'), (b'(Echap = annuler)', b'\x1b'), (S.MENU, b'')], bridge=br, tail_blocks=50_000,
               count=400_000_000)
out = st['out'].decode('latin-1')
liste = out[out.find('5) Boot from disk'):]
check('Menu principal: 5) Boot from disk = liste des images (DOS 2.1 de la ROM, ELKSS01.IMG), Echap -> menu',
      st['done'] and 'ELKSS01' in liste and 'PC-DOS 2.1' in liste and liste.count('5) Boot from disk') >= 2, liste[-400:])

# --- date et heure de la RTC (ROM 1.8): format affiche, date impossible redemandee, annee sur 2 chiffres,
# --- Entree = valeur actuelle, Echap = rien envoye ---
br = S.H.BridgeModel()
st = S.run_rom([(S.MENU, b'4'), (b'3) Heure et date', b'3'), (b'Date (JJ-MM-AAAA): ', b'31022026'),
                (b'Date invalide', b''), (b'Date (JJ-MM-AAAA): ', b'2711'), (b'27-11-', b'26\r'),
                (b'Heure (HH:MM:SS): ', b'14\r05'), (b'envoyees au pont', b'')],
               bridge=br, tail_blocks=50_000, count=400_000_000)
check('Date et heure: 31-02 refuse puis 27-11-26 -> 2026, minutes gardees (Entree) -> pont',
      st['done'] and list(br.clock[:7]) == [0xEA, 0x07, 11, 27, 14, 34, 5], str(list(br.clock)) + st['out'][-300:].decode('latin-1'))
br = S.H.BridgeModel()
st = S.run_rom([(S.MENU, b'4'), (b'3) Heure et date', b'3'), (b'Date (JJ-MM-AAAA): ', b'1\x1b'), (b'rien n', b'')],
               bridge=br, tail_blocks=50_000, count=400_000_000)
check('Date et heure: Echap annule (rien envoye au pont)', st['done'] and not any(op == 2 for op, _ in br.log),
      st['out'][-300:])

# --- ROM COMPLETE (option --complet: plusieurs minutes) ---
if '--complet' in sys.argv:
    if os.path.exists(os.path.join(DOS, 'pcdos2_1.img')):
        boot = [(S.MENU, b'3'), (b'Boot disk image', b'3'), (b'): ', b'1'), (b'Enter new date: ', b'\r'),
                (b'Enter new time: ', b'\r'), (b'A>', b'ver\r')]
        st = S.run_rom(boot + [(b'A>', b'\x1c')] + boot + [(b'A>', b'')],
                       bridge=S.H.BridgeModel(files={'PCDOS2_1.IMG': img('pcdos2_1.img')}))
        out = st['out'].decode('latin-1')
        check('ROM complete: DOS 2.1, Ctrl-\\ (retour au menu), reamorcage, VER',
              st['done'] and out.count('DOS Version  2.10') == 2 and out.count('Boot disk image') >= 2, out[-400:])
    prog = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sine.bas'), 'rb').read().replace(b'\r\n', b'\n')
    lines = [l for l in prog.split(b'\n') if l.strip()]
    st = S.run_rom([(S.MENU, b'1'), (b'2) BASIC', b'2'), (b'Ok', b'\r'.join(lines) + b'\rLIST\r'), (b'Done."', b'')])
    out = st['out'].decode('latin-1')
    listed = out[out.rfind('LIST'):]
    check('ROM complete: collage d un programme au BASIC, LIST identique (aucun caractere perdu)',
          st['done'] and all(l.decode() in listed for l in lines), listed[-400:])

print('\n%d verification(s), %d echec(s)' % (total, fails))
sys.exit(1 if fails else 0)
