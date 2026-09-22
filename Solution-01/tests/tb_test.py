#!/usr/bin/env python3
"""Banc d'essai de lib/tiny_basic.asm sous emulateur (Unicorn).

Assemble tests/tb_test.asm (uart_* remplaces par des ports fictifs), l'execute
en mode reel 16 bits et verifie les sorties BASIC, le retour au menu (registres,
SP, DS restaures) et qu'AUCUNE ecriture n'a lieu hors des zones prevues.

Usage (depuis la racine de Solution-01):  python3 tests/tb_test.py
Prerequis: pip install unicorn ; nasm dans le PATH.
"""
import os, re, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, 'build', 'tb_test.bin')
LST = os.path.join(ROOT, 'build', 'tb_test.lst')
BIN_REAL = os.path.join(ROOT, 'build', 'tb_test_real.bin')
LST_REAL = os.path.join(ROOT, 'build', 'tb_test_real.lst')

# adresses physiques du tampon de reception UART du firmware (hardware.inc)
UART_HEAD = 0x10000 + 0xFC3C
UART_TAIL = 0x10000 + 0xFC3D
UART_BUF = 0x10000 + 0xFD00


def build():
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    subprocess.run(['nasm', '-f', 'bin', '-dTB_TEST', 'tests/tb_test.asm', '-o', BIN, '-l', LST],
                   cwd=ROOT, check=True)
    subprocess.run(['nasm', '-f', 'bin', '-dTB_TEST', '-dTB_REAL', 'tests/tb_test.asm',
                    '-o', BIN_REAL, '-l', LST_REAL], cwd=ROOT, check=True)


def symbols(real=False):
    """offsets des variables 'saved_*' du banc d'essai (depuis le listing nasm)"""
    syms = {}
    for line in open(LST_REAL if real else LST, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*\d+\s+([0-9A-F]{8})\s+\S+\s+(saved_\w+)\s+dw', line)
        if m:
            syms[m.group(2)] = int(m.group(1), 16)
    return syms


# zones ecrites autorisees (adresses PHYSIQUES)
ALLOWED = [
    (0x10100, 0x18000),      # texte du programme + donnees TB (1000:0100-7FFF)
    (0x1F000, 0x1F420),      # pile de l'interpreteur (1000:F000-F41F)
    (0x1FF00, 0x20000),      # pile de l'appelant (SS=1000h, SP=0 -> FFxx)
    (0xC0000, 0xC0100),      # variables du banc d'essai (saved_*), "ROM" mappee RW
    (0x1FC29, 0x1FC2A),      # ARD_TX_STATE_OFF (arduino_send), mode reel
    (0x1FC3C, 0x1FC3D),      # UART_RX_HEAD_OFF (uart_rx_byte), mode reel
]


def run(text, max_idle=3000, max_insns=30_000_000, real=False):
    """Execute tiny_basic avec `text` (str ou bytes) comme entree UART."""
    data = text.encode('latin-1') if isinstance(text, str) else bytes(text)
    # Le texte est livre par "paquets" (une ligne = jusqu'au CR inclus; Ctrl-C/Ctrl-X
    # = un paquet a eux), comme un utilisateur qui tape: un paquet n'est livre que
    # lorsque l'interpreteur ATTEND (getln scrute l'UART sans rien afficher). Sinon
    # les octets d'avance seraient avales par le test Ctrl-C de chaque instruction
    # ('chkio'), comme dans le PATB86 d'origine. Les paquets Ctrl-C/Ctrl-X sont livres
    # apres 300 scrutations meme si le programme tourne (pas d'attente).
    chunks = []
    cur = b''
    for b in data:
        if b in (0x03, 0x18):
            if cur:
                chunks.append(cur); cur = b''
            chunks.append(bytes([b]))
        else:
            cur += bytes([b])
            if b == 0x0D:
                chunks.append(cur); cur = b''
    if cur:
        chunks.append(cur)
    code = open(BIN_REAL if real else BIN, 'rb').read()
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0x00000, 0x20000)
    uc.mem_map(0xC0000, 0x40000)
    uc.mem_write(0xC0000, code)
    st = {'rem': b'', 'idle': 0, 'polls': 0, 'out': bytearray(), 'done': False,
          'bad': [], 'stopped': 'insns'}

    def ring_feed(uc):
        # emule irq1_arduino_handler/uart_rx_push: un octet a la fois dans le tampon
        # circulaire UART de 16 octets (tete = queue -> vide)
        head = uc.mem_read(UART_HEAD, 1)[0]
        tail = uc.mem_read(UART_TAIL, 1)[0]
        if head == tail and st['rem']:
            uc.mem_write(UART_BUF + tail, bytes([st['rem'][0]]))
            uc.mem_write(UART_TAIL, bytes([(tail + 1) & 0xFF]))
            st['rem'] = st['rem'][1:]
            st['idle'] = 0
            return True
        return False

    def h_poll(uc, access, addr, size, value, ud):
        # lecture de UART_RX_HEAD_OFF = un uart_rx_available: meme logique d'attente
        if not st['rem'] and chunks:
            st['polls'] += 1
            c = chunks[0]
            if (c[0] in (0x03, 0x18) and st['polls'] >= 300) or st['idle'] >= 20:
                st['rem'] = chunks.pop(0)
                st['polls'] = 0
        if not ring_feed(uc):
            st['idle'] += 1
            if not chunks and not st['rem'] and st['idle'] > max_idle:
                st['stopped'] = 'idle'
                uc.emu_stop()

    def h_in(uc, port, size, ud):
        if real:
            return 0x80 if port == 0x82 else 0          # PORTC: OBF# = 1 (tampon libre)
        if port == 0xE1:
            if not st['rem'] and chunks:
                st['polls'] += 1
                c = chunks[0]
                if (c[0] in (0x03, 0x18) and st['polls'] >= 300) or st['idle'] >= 20:
                    st['rem'] = chunks.pop(0)
                    st['polls'] = 0
            if st['rem']:
                return 1
            st['idle'] += 1
            if not chunks and st['idle'] > max_idle:
                st['stopped'] = 'idle'
                uc.emu_stop()
            return 0
        if port == 0xE2:
            b = st['rem'][0]
            st['rem'] = st['rem'][1:]
            st['idle'] = 0
            return b
        return 0

    def h_out(uc, port, size, value, ud):
        if real and port == 0x81:
            st['chan'] = value & 0xFF                   # PORTB: canal
        elif real and port == 0x80:
            if st.get('chan', 0) == 0:                  # PORTA: canal 0 = octet UART emis
                st['out'].append(value & 0xFF)
                st['idle'] = 0
        elif port == 0xE0:
            st['out'].append(value & 0xFF)
            st['idle'] = 0
        elif port == 0xFF:
            st['done'] = True
            st['stopped'] = 'done'
            uc.emu_stop()

    def h_write(uc, access, addr, size, value, ud):
        if not any(a <= addr and addr + size <= b for a, b in ALLOWED):
            st['bad'].append((addr, size))

    uc.hook_add(UC_HOOK_INSN, h_in, None, 1, 0, UC_X86_INS_IN)
    uc.hook_add(UC_HOOK_INSN, h_out, None, 1, 0, UC_X86_INS_OUT)
    uc.hook_add(UC_HOOK_MEM_WRITE, h_write)
    if real:
        uc.hook_add(UC_HOOK_MEM_READ, h_poll, None, UART_HEAD, UART_HEAD)
    uc.reg_write(UC_X86_REG_CS, 0xC000)
    try:
        uc.emu_start(0xC0000, 0, count=max_insns)
    except UcError as e:
        st['stopped'] = 'error: %s (cs:ip=%04X:%04X)' % (
            e, uc.reg_read(UC_X86_REG_CS), uc.reg_read(UC_X86_REG_IP))
    out = st['out'].decode('latin-1').replace('\r\n', '\n').replace('\r', '\n')
    regs = {}
    if st['done']:
        for name, off in symbols(real).items():
            regs[name[6:]] = int.from_bytes(uc.mem_read(0xC0000 + off, 2), 'little')
    return out, st, regs


fails = 0


def check(name, cond, extra=''):
    global fails
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '   -> ' + extra))
    if not cond:
        fails += 1


def has(out, *subs):
    return all(s in out for s in subs)


def results(out):
    """sortie du programme SANS l'echo des lignes saisies (lignes '>...'), la
    banniere ni les 'Ok'"""
    keep = []
    for ln in out.split('\n'):
        if ln.startswith('>') or ln == 'Ok' or ln.startswith('Tiny BASIC') or ln.startswith('Ctrl-C'):
            continue
        keep.append(ln)
    return '\n'.join(keep)


def numbers(out):
    return [int(x) for x in re.findall(r'-?\d+', results(out))]


build()

# --- banniere / invite -----------------------------------------------------
out, st, _ = run('')
check('banniere + Ok + invite', has(out, 'Tiny BASIC 8088', 'Ctrl-X', 'Ok', '>'), out + ' ' + st['stopped'])
check('aucune ecriture hors zones (banniere)', not st['bad'], str(st['bad'][:5]))

# --- expressions -----------------------------------------------------------
out, st, _ = run('PRINT 2+3*4\r')
check('PRINT 2+3*4 = 14', numbers(out)[-1:] == [14], out)
out, st, _ = run('PRINT (2+3)*4, 100/7, -5+2, 7-10\r')
check('parentheses, division entiere, negatifs', numbers(out) == [20, 14, -3, -3], out)
out, st, _ = run('PRINT 5>3, 5<3, 4=4, 4#4, 3>=3, 2<=1\r')
check('operateurs relationnels', numbers(out) == [1, 0, 1, 0, 1, 0], out)
out, st, _ = run('PRINT ABS(-9), ABS(9)\r')
check('ABS', numbers(out) == [9, 9], out)
out, st, _ = run('PRINT 32767+1\r')
check('depassement -> How?', 'How?' in out, out)
out, st, _ = run('PRINT 1/0\r')
check('division par zero -> How?', 'How?' in out, out)
out, st, _ = run('FOO\r')
check('commande inconnue -> What?', 'What?' in out, out)
out, st, _ = run('print 6*7\r')
check('minuscules acceptees', numbers(out)[-1:] == [42], out)
out, st, _ = run('P. 8\r')
check('abreviation P.', numbers(out)[-1:] == [8], out)
out, st, _ = run('PRINT "HELLO WORLD"\r')
check('chaine entre guillemets', 'HELLO WORLD' in out, out)
out, st, _ = run("PRINT 'AB','CD'\r")
check('chaines entre apostrophes', 'ABCD' in out.replace(' ', ''), out)
out, st, _ = run('PRINT #3,5,6\r')
check('format #3', '  5  6' in out, repr(out))
out, st, _ = run('PRINT SIZE\r')
check('SIZE = 32000 (memoire vide)', numbers(out)[-1:] == [32000], out)

# --- variables, tableau @() ------------------------------------------------
out, st, _ = run('A=5;B=A*3\rPRINT A+B\r')
check('variables et ;', numbers(out)[-1:] == [20], out)
out, st, _ = run('@(1)=5\r@(2)=@(1)*2\rPRINT @(2)\r')
check('tableau @()', numbers(out)[-1:] == [10], out)
out, st, _ = run('@(0)=3\rPRINT @(0)\rPRINT 1\r')
check("@(0) ne casse pas le tampon de ligne", numbers(out)[-2:] == [3, 1], out)

# --- programmes ------------------------------------------------------------
out, st, _ = run('10 FOR I=1 TO 5\r20 PRINT I\r30 NEXT I\rRUN\r')
check('FOR/NEXT 1..5', numbers(out)[-5:] == [1, 2, 3, 4, 5], out)
check('aucune ecriture hors zones (programme)', not st['bad'], str(st['bad'][:5]))
out, st, _ = run('10 FOR I=10 TO 1 STEP -3\r20 PRINT I\r30 NEXT I\rRUN\r')
check('FOR STEP negatif', numbers(out)[-4:] == [10, 7, 4, 1], out)
out, st, _ = run('10 FOR I=1 TO 3\r20 FOR J=1 TO 2\r30 PRINT I*10+J\r40 NEXT J\r50 NEXT I\rRUN\r')
check('FOR imbriques', numbers(out)[-6:] == [11, 12, 21, 22, 31, 32], out)
out, st, _ = run('10 A=0\r20 GOSUB 100\r30 GOSUB 100\r40 PRINT A\r50 STOP\r100 A=A+7\r110 RETURN\rRUN\r')
check('GOSUB/RETURN', numbers(out)[-1:] == [14], out)
out, st, _ = run('10 A=0;B=1\r20 FOR I=1 TO 10\r30 C=A+B;A=B;B=C\r40 NEXT I\r50 PRINT A\rRUN\r')
check('Fibonacci(10) = 55', numbers(out)[-1:] == [55], out)
FIB = '10 LET A=0\r20 LET B=1\r30 PRINT A\r100 PRINT B\r110 LET B=A+B\r120 LET A=B-A\r'
out, st, _ = run(FIB + '130 IF B<=32000 GOTO 100\rRUN\r')
check('exemple README: Fibonacci jusqu\'a 28657 puis depassement -> How? (ligne 110)',
      numbers(out)[-4:] == [17711, 28657, 110, 0] or (numbers(out)[-3:-1] == [17711, 28657] and 'How?' in out
                                                       and '110 LET B=A+B?' in out), out)
out, st, _ = run(FIB + '130 IF B<=17711 GOTO 100\rRUN\r')
check('exemple README corrige (B<=17711): s\'arrete sur 17711 sans erreur',
      numbers(out)[-1:] == [17711] and 'How?' not in out, out)
out, st, _ = run('10 A=3\r20 IF A=3 PRINT "OUI"\r30 IF A=4 PRINT "NON"\r40 PRINT "FIN"\rRUN\r')
check('IF', has(results(out), 'OUI', 'FIN') and 'NON' not in results(out), out)
out, st, _ = run('10 INPUT A,B\r20 PRINT A+B\rRUN\r3\r4\r')
check('INPUT', numbers(out)[-1:] == [7], out)
out, st, _ = run('10 INPUT "VALEUR",A\r20 PRINT A*2\rRUN\r21\r')
check('INPUT avec invite', 'VALEUR' in out and numbers(out)[-1:] == [42], out)
out, st, _ = run('10 INPUT A\r20 PRINT A\rRUN\rXYZ\r9\r')
check('INPUT invalide -> What? puis nouvelle saisie', 'What?' in out and numbers(out)[-1:] == [9], out)
out, st, _ = run('10 PRINT 1/0\rRUN\r')
check('erreur en programme: ligne affichee avec ?', has(out, 'How?', '10 PRINT 1/0?'), out)
out, st, _ = run('10 GOTO 999\rRUN\r')
check('GOTO ligne absente -> How?', 'How?' in out, out)
out, st, _ = run('10 REM COMMENTAIRE\r20 PRINT 5\rRUN\r')
check('REM', numbers(out)[-1:] == [5], out)
out, st, _ = run('10 PRINT RND(10)\r20 GOTO 10\rRUN\r' + '\x03' + 'PRINT 1\r')
vals = numbers(out)
check('RND dans [1,10], Ctrl-C interrompt, retour a Ok',
      len(vals) > 3 and all(1 <= v <= 10 for v in vals[:-1]) and vals[-1] == 1, str(vals[-10:]))
check('RND varie', len(set(vals[:-1])) > 1, str(vals[:20]))

# --- edition du programme --------------------------------------------------
out, st, _ = run('30 PRINT 3\r10 PRINT 1\r20 PRINT 2\rLIST\r')
lst = results(out)
check('LIST trie les lignes', '10 PRINT 1' in lst and lst.index('10 PRINT 1') < lst.index('20 PRINT 2') < lst.index('30 PRINT 3'), out)
out, st, _ = run('10 PRINT 1\r20 PRINT 2\r20\rLIST\r')
check('ligne supprimee (numero seul)', '10 PRINT 1' in results(out) and '20 PRINT 2' not in results(out), out)
out, st, _ = run('10 PRINT 1\r10 PRINT 9\rLIST\r')
check('ligne remplacee', '10 PRINT 9' in results(out) and '10 PRINT 1' not in results(out), out)
out, st, _ = run('10 PRINT 1\rNEW\rLIST\rPRINT SIZE\r')
check('NEW efface le programme', '10 PRINT' not in results(out) and numbers(out)[-1:] == [32000], out)
out, st, _ = run('PRINX\x7fT 5\r')
check('DEL corrige la saisie', numbers(out)[-1:] == [5], repr(out))
out, st, _ = run('PRINX\x08T 6\r')
check('BS corrige la saisie', numbers(out)[-1:] == [6], repr(out))
out, st, _ = run('PRI\x1b[ANT\n 8\r')
check('sequence ANSI (fleche) et LF ignores dans la saisie', numbers(out)[-1:] == [8], repr(out))
out, st, _ = run('PRINT\x1bOB 9\r')
check('sequence ESC O x ignoree', numbers(out)[-1:] == [9], repr(out))
out, st, _ = run('PRINT 4\x1b[1;5C+1\r')
check('sequence ANSI avec parametres ignoree', numbers(out)[-1:] == [5], repr(out))

# --- sortie vers le menu ---------------------------------------------------
for label, quit_txt in (('BYE', 'BYE\r'), ('Ctrl-X', '\x18')):
    out, st, r = run(quit_txt)
    ok = (st['done'] and r.get('ax') == 0x1111 and r.get('bx') == 0x2222 and r.get('cx') == 0x3333
          and r.get('dx') == 0x4444 and r.get('si') == 0x5555 and r.get('di') == 0x6666
          and r.get('bp') == 0x7777)
    check("%s: retour a l'appelant, registres restaures" % label, ok, str(r) + ' ' + st['stopped'])
    check('%s: DS = CS (C000h), SP restaure' % label, r.get('ds') == 0xC000 and r.get('sp') == 0x0000, str(r))
    check('%s: aucune ecriture hors zones' % label, not st['bad'], str(st['bad'][:5]))

# --- memes scenarios avec les VRAIES routines uart_* -----------------------
print('--- mode reel: vraies routines uart_* (arduino_send, tampon circulaire) ---')
out, st, _ = run('', real=True)
check('reel: banniere + Ok + invite', has(out, 'Tiny BASIC 8088', 'Ok', '>'), out + ' ' + st['stopped'])
out, st, _ = run('PRINT 2+3*4\r', real=True)
check('reel: PRINT 2+3*4 = 14', numbers(out)[-1:] == [14], out)
out, st, _ = run('10 FOR I=1 TO 5\r20 PRINT I\r30 NEXT I\rRUN\r', real=True)
check('reel: FOR/NEXT 1..5', numbers(out)[-5:] == [1, 2, 3, 4, 5], out)
out, st, _ = run('10 INPUT "VALEUR",A\r20 PRINT A*2\rRUN\r21\r', real=True)
check('reel: INPUT', 'VALEUR' in out and numbers(out)[-1:] == [42], out)
out, st, _ = run('10 PRINT RND(10)\r20 GOTO 10\rRUN\r' + '\x03' + 'PRINT 1\r', real=True)
vals = numbers(out)
check('reel: Ctrl-C interrompt, retour a Ok', len(vals) > 3 and vals[-1] == 1, str(vals[-8:]))
check('reel: aucune ecriture hors zones', not st['bad'], str(st['bad'][:5]))
for label, quit_txt in (('BYE', 'BYE\r'), ('Ctrl-X', '\x18')):
    out, st, r = run(quit_txt, real=True)
    ok = (st['done'] and r.get('ax') == 0x1111 and r.get('bx') == 0x2222 and r.get('cx') == 0x3333
          and r.get('dx') == 0x4444 and r.get('si') == 0x5555 and r.get('di') == 0x6666
          and r.get('bp') == 0x7777 and r.get('ds') == 0xC000 and r.get('sp') == 0)
    check("reel: %s: retour a l'appelant, registres/DS/SP restaures" % label, ok, str(r) + ' ' + st['stopped'])

print('\n%d echec(s)' % fails)
sys.exit(1 if fails else 0)
