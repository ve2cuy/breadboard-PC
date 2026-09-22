#!/usr/bin/env python3
"""Banc d'essai de lib/bridge.asm (commandes du canal 3, reponses du pont) sous emulateur.

Les VRAIES routines arduino_send / bridge_rx_get / rtc_get / rtc_set s'executent; le
8255 (ports 80h-82h) est emule et ce script joue le role du PONT et de l'ISR
(irq1_arduino_handler): il note les octets envoyes au canal 3 et, apres la commande
LIRE (01h), range 8 octets de reponse dans le tampon circulaire BRIDGE_RX_* (a
condition que BRIDGE_EXPECT_OFF soit a 1, comme le fait l'ISR).

Usage (depuis la racine de Solution-01):  python3 tests/bridge_test.py
"""
import os, subprocess, sys
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, 'build', 'bridge_test.bin')
os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
subprocess.run(['nasm', '-f', 'bin', 'tests/bridge_test.asm', '-o', BIN], cwd=ROOT, check=True)

SEG = 0x10000
HEAD, TAIL, BUF, EXPECT = SEG + 0xFC52, SEG + 0xFC53, SEG + 0xFC70, SEG + 0xFC64
RESULT, CF, SETDATA = SEG + 0x0200, SEG + 0x0210, SEG + 0x0220
fails = 0
total = 0


def check(name, cond, extra=''):
    global fails, total
    total += 1
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '   -> ' + extra))
    if not cond:
        fails += 1


def run(reply, prefill=b'', setdata=bytes(range(1, 8)), reply_gap=0):
    """reply = 8 octets a repondre a la commande 01h (None: pont muet)"""
    code = open(BIN, 'rb').read()
    uc = Uc(UC_ARCH_X86, UC_MODE_16)
    uc.mem_map(0x00000, 0x20000)
    uc.mem_map(0xC0000, 0x40000)
    uc.mem_write(0xC0000, code)
    uc.mem_write(SETDATA, setdata)
    for i, b in enumerate(prefill):                      # reponses perimees deja en attente
        uc.mem_write(BUF + i, bytes([b]))
    if prefill:
        uc.mem_write(TAIL, bytes([len(prefill) & 15]))
    st = {'cmds': [], 'chan': 0, 'expect_at_cmd': None, 'done': False, 'bad': [], 'pending': 0}

    def h_in(uc, port, size, ud):
        return 0x80 if port == 0x82 else 0               # PORTC: OBF# = 1 (tampon libre)

    def h_out(uc, port, size, value, ud):
        if port == 0x81:
            st['chan'] = value & 0xFF
        elif port == 0x80:
            st['cmds'].append((st['chan'], value & 0xFF))
            if st['chan'] != 3:
                return
            if st['pending']:                            # arguments de 02h (comme l'automate du pont)
                st['pending'] -= 1
                return
            if value == 0x02:
                st['pending'] = 7
                return
            if value == 0x01 and reply is not None:
                st['expect_at_cmd'] = uc.mem_read(EXPECT, 1)[0]
                if st['expect_at_cmd'] == 1:             # l'ISR ne range que si une reponse est attendue
                    for b in reply:
                        tail = uc.mem_read(TAIL, 1)[0]
                        uc.mem_write(BUF + tail, bytes([b]))
                        uc.mem_write(TAIL, bytes([(tail + 1) & 63]))
        elif port == 0xFF:
            st['done'] = True
            uc.emu_stop()

    def h_write(uc, access, addr, size, value, ud):
        ok = ((SEG + 0x100 <= addr < SEG + 0x300) or (SEG + 0xFC29 <= addr <= SEG + 0xFC64)
              or (SEG + 0xFF00 <= addr < SEG + 0x10000) or (0xC0000 <= addr < 0xC0100))
        if not ok:
            st['bad'].append((addr, size))

    uc.hook_add(UC_HOOK_INSN, h_in, None, 1, 0, UC_X86_INS_IN)
    uc.hook_add(UC_HOOK_INSN, h_out, None, 1, 0, UC_X86_INS_OUT)
    uc.hook_add(UC_HOOK_MEM_WRITE, h_write)
    uc.reg_write(UC_X86_REG_CS, 0xC000)
    try:
        uc.emu_start(0xC0000, 0, count=20_000_000)
    except UcError as e:
        st['err'] = str(e)
    st['result'] = bytes(uc.mem_read(RESULT, 8))
    st['cf'] = uc.mem_read(CF, 1)[0]
    st['expect'] = uc.mem_read(EXPECT, 1)[0]
    st['head'] = uc.mem_read(HEAD, 1)[0]
    st['tail'] = uc.mem_read(TAIL, 1)[0]
    return st


CLOCK = bytes([0xEA, 0x07, 9, 20, 12, 34, 56, 78])       # 2026-09-20 12:34:56.78
SET = bytes([0xEB, 0x07, 1, 2, 3, 4, 5])

st = run(CLOCK)
check('rtc_get: fin normale', st['done'] and 'err' not in st, str(st.get('err')))
check('rtc_get: CF = 0 et 8 octets recus dans l\'ordre', st['cf'] == 0 and st['result'] == CLOCK, repr(st['result']))
check('rtc_get: la commande 01h part sur le canal 3', st['cmds'][0] == (3, 0x01), str(st['cmds'][:2]))
check('rtc_get: la reponse est attendue (BRIDGE_EXPECT = 1) pendant la commande', st['expect_at_cmd'] == 1)
check('rtc_get: plus de reponse attendue ensuite (BRIDGE_EXPECT = 0)', st['expect'] == 0)
check('rtc_get: tampon vide ensuite', st['head'] == st['tail'], '%d %d' % (st['head'], st['tail']))
check('rtc_set: 02h + 7 octets sur le canal 3, dans l\'ordre',
      st['cmds'][1:] == [(3, 0x02)] + [(3, b) for b in bytes(range(1, 8))], str(st['cmds'][1:]))
st = run(CLOCK, setdata=SET)
check('rtc_set: octets a DS:SI envoyes tels quels', [c[1] for c in st['cmds'][2:]] == list(SET), str(st['cmds']))
check('aucune ecriture hors zones', not st['bad'], str(st['bad'][:4]))

st = run(CLOCK, prefill=b'\xAA\xBB\xCC')
check('rtc_get: jette les reponses perimees (flush)', st['cf'] == 0 and st['result'] == CLOCK, repr(st['result']))
st = run(CLOCK, prefill=bytes(range(1, 60)))
check('rtc_get: tampon presque plein au depart (flush puis enroulement)', st['cf'] == 0 and st['result'] == CLOCK, repr(st['result']))

st = run(None)
check('pont muet: CF = 1 (delai) sans blocage', st['done'] and st['cf'] == 1, str(st))
check('pont muet: BRIDGE_EXPECT remis a 0', st['expect'] == 0)

print('\n%d verification(s), %d echec(s)' % (total, fails))
sys.exit(1 if fails else 0)
