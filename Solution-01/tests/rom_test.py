#!/usr/bin/env python3
"""Scenarios de bout en bout avec IRQ1 ASYNCHRONES (tests/rom_sim.py): DOS reels, trace, points
d'amorcage, et - option --complet, plusieurs minutes - la ROM COMPLETE (menu, Ctrl-\\, BASIC).

Ce que les autres bancs ne voient pas: le passage de chaque octet par le 8255, le 8259 et l'ISR, le
masquage d'IR1 pendant les commandes au pont (scrutation), le redemarrage a chaud.

Usage (depuis la racine de Solution-01):  python tests/rom_test.py [--complet]   (ou: make test-rom)
"""
import os, re, sys
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
