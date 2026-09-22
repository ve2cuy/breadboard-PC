#!/usr/bin/env python3
"""Banc d'essai de lib/basic_float.asm (flottants logiciels IEEE simple precision)
sous emulateur Unicorn, compare a numpy.float32.

Usage (depuis la racine de Solution-01):  python3 tests/fl_test.py
Prerequis: pip install unicorn numpy ; nasm dans le PATH.
"""
import os, re, random, struct, subprocess, sys
import numpy as np
np.seterr(all='ignore')
from unicorn import *
from unicorn.x86_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, 'build', 'fl_test.bin')
LST = os.path.join(ROOT, 'build', 'fl_test.lst')
BASE = 0x1000
RET = 0x0FF0
ARG, FAC = 0x100, 0x104


def build(extra=()):
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    subprocess.run(['nasm', '-f', 'bin', 'tests/fl_test.asm', '-o', BIN, '-l', LST] + list(extra),
                   cwd=ROOT, check=True)


def symbols():
    """adresses des etiquettes globales, depuis le listing nasm (une etiquette seule sur sa
    ligne prend l'adresse de la premiere ligne assemblee qui suit)"""
    syms = {}
    pending = []
    for line in open(LST, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*\d+\s+(?:([0-9A-F]{8})\s+)?(?:[0-9A-F]+\s+)?(?:<\d+>\s+)?(\w+):\s*(?:;.*)?$', line)
        if m and not m.group(2).startswith('.'):
            if m.group(1):
                syms[m.group(2)] = int(m.group(1), 16)
            else:
                pending.append(m.group(2))
            continue
        a = re.match(r'\s*\d+\s+([0-9A-F]{8})\s+[0-9A-F]+', line)
        if a and pending:
            for n in pending:
                syms[n] = int(a.group(1), 16)
            pending = []
    return syms


class Emu:
    def __init__(self):
        self.syms = symbols()
        self.uc = Uc(UC_ARCH_X86, UC_MODE_16)
        self.uc.mem_map(0, 0x10000)
        self.uc.mem_write(BASE, open(BIN, 'rb').read())
        for r in (UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS, UC_X86_REG_CS):
            self.uc.reg_write(r, 0)

    def call(self, name, **regs):
        uc = self.uc
        uc.reg_write(UC_X86_REG_SP, 0x8000)
        uc.mem_write(0x7FFE, struct.pack('<H', RET))
        uc.reg_write(UC_X86_REG_SP, 0x7FFE)
        for k in ('AX', 'BX', 'CX', 'DX', 'SI', 'DI', 'BP'):
            uc.reg_write(getattr(sys.modules[__name__], 'UC_X86_REG_' + k),
                         regs.get(k.lower(), 0))
        uc.emu_start(self.syms[name] + BASE, RET, count=2_000_000)
        return {k: uc.reg_read(getattr(sys.modules[__name__], 'UC_X86_REG_' + k))
                for k in ('AX', 'BX', 'CX', 'DX', 'SI', 'DI', 'BP')}, \
            (uc.reg_read(UC_X86_REG_EFLAGS) & 1)

    def wr(self, addr, v):
        self.uc.mem_write(addr, struct.pack('<I', v & 0xFFFFFFFF))

    def rd(self, addr):
        return struct.unpack('<I', bytes(self.uc.mem_read(addr, 4)))[0]

    def setf(self, addr, f):
        self.wr(addr, struct.unpack('<I', struct.pack('<f', f))[0])

    def getf(self, addr):
        return struct.unpack('<f', struct.pack('<I', self.rd(addr)))[0]


def bits(f):
    return struct.unpack('<I', struct.pack('<f', f))[0]


def rnd_float(rng, lo=-30, hi=30):
    kind = rng.random()
    if kind < 0.05:
        return 0.0
    m = rng.random() * 2 + 1
    e = rng.randint(lo, hi)
    v = m * (2.0 ** e)
    return float(np.float32(-v if rng.random() < 0.5 else v))


fails = 0
total = 0


def check(name, cond, extra=''):
    global fails
    if not cond:
        fails += 1
        print('FAIL  %s  %s' % (name, extra))


def main():
    global total
    build()
    em = Emu()
    rng = random.Random(1234)
    f32 = np.float32

    def binop(sym, a, b, ref):
        em.setf(ARG, a)
        em.setf(FAC, b)
        _, cf = em.call(sym)
        got = em.getf(FAC)
        exp = ref(f32(a), f32(b))
        return got, exp, cf

    # --- + - * / sur des flottants aleatoires ---------------------------
    ops = [('fl_add', lambda a, b: a + b), ('fl_sub', lambda a, b: a - b),
           ('fl_mul', lambda a, b: a * b), ('fl_div', lambda a, b: a / b)]
    for sym, ref in ops:
        bad = 0
        for i in range(3000):
            a = rnd_float(rng)
            b = rnd_float(rng)
            if sym == 'fl_div' and b == 0.0:
                continue
            if i % 4 == 0 and sym in ('fl_add', 'fl_sub'):
                b = float(f32(a * (1 + rng.random() * 1e-3)))     # quasi-annulation
            got, exp, cf = binop(sym, a, b, ref)
            total += 1
            if float(exp) == 0.0 or abs(float(exp)) < 1.2e-38:
                ok = got == 0.0
            else:
                ok = bits(got) == bits(float(exp))
            if not ok:
                bad += 1
                if bad <= 5:
                    print('FAIL  %s(%r, %r): got %r (%08X) expected %r (%08X)' % (
                        sym, a, b, got, bits(got), float(exp), bits(float(exp))))
        fails_local = bad
        check(sym + ' aleatoire (3000)', bad == 0, '%d erreurs' % bad)

    # --- cas particuliers -------------------------------------------------
    cases = [(1.0, 1.0), (1.0, -1.0), (0.1, 0.2), (1e10, 1.0), (1.0, 1e10), (3.0, 7.0),
             (16777216.0, 1.0), (16777217.0, 1.0), (1.5, 2.5), (0.0, 5.0), (5.0, 0.0),
             (1e30, 1e30), (2.0 ** 100, 2.0 ** 100)]
    for a, b in cases:
        for sym, ref in ops:
            if sym == 'fl_div' and b == 0.0:
                continue
            got, exp, cf = binop(sym, a, b, ref)
            exp = float(exp)
            if exp == float('inf'):
                ok = cf == 1                      # depassement signale par CF
            else:
                ok = (got == 0.0) if exp == 0.0 else bits(got) == bits(exp)
            check('%s(%r,%r)' % (sym, a, b), ok, 'got %r expected %r' % (got, exp))

    # depassement / division par zero
    em.setf(ARG, 3e38); em.setf(FAC, 3e38)
    _, cf = em.call('fl_mul')
    check('fl_mul depassement -> CF', cf == 1)
    em.setf(ARG, 1.0); em.setf(FAC, 0.0)
    _, cf = em.call('fl_div')
    check('fl_div par zero -> CF et fl_dz', cf == 1 and em.uc.mem_read(0x131, 1)[0] == 1)
    em.setf(ARG, 1e-30); em.setf(FAC, 1e-30)
    _, cf = em.call('fl_mul')
    check('fl_mul sous-depassement -> 0', em.getf(FAC) == 0.0 and cf == 0)

    # --- comparaison ------------------------------------------------------
    bad = 0
    for i in range(3000):
        a = rnd_float(rng)
        b = a if i % 7 == 0 else rnd_float(rng)
        em.setf(ARG, a); em.setf(FAC, b)
        r, _ = em.call('fl_cmp')
        al = r['AX'] & 0xFF
        got = -1 if al == 0xFF else al
        exp = (a > b) - (a < b)
        if got != exp:
            bad += 1
            if bad <= 5:
                print('FAIL cmp(%r,%r): got %d expected %d' % (a, b, got, exp))
    check('fl_cmp aleatoire (3000)', bad == 0, '%d erreurs' % bad)

    # --- int16 <-> float ---------------------------------------------------
    bad = 0
    for v in list(range(-40, 41)) + [32767, -32768, 12345, -12345, 256, 255, 257, 1000, -1000] + \
            [rng.randint(-32768, 32767) for _ in range(500)]:
        em.call('fl_from_i16', ax=v & 0xFFFF)
        if em.getf(FAC) != float(v):
            bad += 1
            if bad <= 5:
                print('FAIL from_i16(%d): %r' % (v, em.getf(FAC)))
    check('fl_from_i16', bad == 0, '%d erreurs' % bad)

    bad = 0
    tests = [0.0, 0.4, 0.5, 0.6, 1.0, 1.5, 2.5, 3.5, -0.5, -0.6, -1.5, -2.5, 32767.0, -32768.0,
             32767.4, 32767.5, 32768.0, -32768.4, -32768.5, 100.7, -100.7, 1e-10, 65535.0]
    tests += [rnd_float(rng, -5, 15) for _ in range(500)]
    for x in tests:
        for mode in (0, 1):
            em.setf(FAC, x)
            r, cf = em.call('fl_to_i16', ax=mode)
            if mode == 0:
                exp = int(x) if abs(int(x)) <= 32768 else None   # tronque
            else:
                exp = int(np.floor(abs(x) + 0.5)) * (1 if x >= 0 else -1)
            if exp is not None and (exp > 32767 or exp < -32768):
                exp = None
            v = r['AX'] - 0x10000 if r['AX'] >= 0x8000 else r['AX']
            good = (cf == 1) if exp is None else (cf == 0 and v == exp)
            if not good:
                bad += 1
                if bad <= 8:
                    print('FAIL to_i16(%r, mode %d): got ax=%d cf=%d expected %r' % (x, mode, v, cf, exp))
    check('fl_to_i16 (FIX/CINT)', bad == 0, '%d erreurs' % bad)

    # --- INT / FIX ---------------------------------------------------------
    bad = 0
    tests = [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.999, -2.999, 100.25, -100.25, 8388608.0, 8388609.0,
             -8388607.5, 1e20, -1e20, 0.999999, -0.000001]
    tests += [rnd_float(rng, -8, 26) for _ in range(800)]
    for x in tests:
        for sym, ref in (('fl_int', np.floor), ('fl_fix', np.trunc)):
            em.setf(FAC, x)
            em.call(sym)
            got = em.getf(FAC)
            exp = float(ref(f32(x)))
            if got != exp and not (got == 0.0 and exp == 0.0):
                bad += 1
                if bad <= 8:
                    print('FAIL %s(%r): got %r expected %r' % (sym, x, got, exp))
    check('fl_int / fl_fix', bad == 0, '%d erreurs' % bad)

    # --- fl_ftoa: 7 chiffres significatifs ---------------------------------
    from decimal import Decimal, ROUND_HALF_UP, getcontext
    getcontext().prec = 60
    bad = 0
    vals = [1.0, 0.1, 0.5, 100.0, 1234567.0, 12345678.0, 0.01, 0.001, 3.14159265, 1e10, 1e-10, 9999999.0,
            9999999.5, 0.99999995, 123456.75, 1.0000001, 2.5e-5, 3e38, 1.2e-38, 16777216.0]
    vals += [abs(rnd_float(rng, -100, 100)) for _ in range(1500)]
    for x in vals:
        if x == 0.0:
            continue
        em.setf(FAC, x)
        em.call('fl_ftoa')
        dig = bytes(em.uc.mem_read(0x178, 7)).decode()
        dexp = struct.unpack('<h', bytes(em.uc.mem_read(0x180, 2)))[0]
        d = Decimal(float(f32(x)))
        exp10 = d.adjusted()
        n = (d.scaleb(6 - exp10)).quantize(Decimal(1), rounding=ROUND_HALF_UP)
        if n >= 10 ** 7:
            n = n / 10
            exp10 += 1
        exp_dig = str(int(n)).rjust(7, '0')
        if not (dig == exp_dig and dexp == exp10):
            if abs(int(dig) - int(exp_dig)) <= 1 and dexp == exp10:
                continue                      # frontiere d'arrondi
            bad += 1
            if bad <= 8:
                print('FAIL ftoa(%r): got %s e%d expected %s e%d' % (x, dig, dexp, exp_dig, exp10))
    check('fl_ftoa (7 chiffres)', bad == 0, '%d erreurs' % bad)

    # --- fl_atof --------------------------------------------------------------
    STR = 0x4000

    def atof(text, sgn=0):
        em.uc.mem_write(STR, text.encode() + b'\x00')
        r, cf = em.call('fl_atof', ax=sgn, si=STR)
        return r, cf

    bad = 0
    good = ['0', '1', '123', '32767', '32768', '-5', '0.5', '.5', '1.', '3.14159265', '1E5', '1e-5', '1.5E+3',
            '2.5D2', '123456789', '1234567890', '99999999999', '0.000001', '1E38', '3.4E38',
            '000123', '0.1', '0.2', '0.3', '1E0', '5E-1', '12345.6789']
    for t_ in good:
        sgn = 1 if t_.startswith('-') else 0
        r, cf = atof(t_, sgn)
        if cf:
            bad += 1
            print('FAIL atof(%r): CF=1' % t_)
            continue
        typ = r['AX'] & 0xFF
        exp_v = float(np.float32(Decimal(t_.replace('D', 'E').replace('d', 'e'))))
        if typ == 2:
            got = float(struct.unpack('<h', bytes(em.uc.mem_read(FAC, 2)))[0])
        else:
            got = em.getf(FAC)
        ok = (got == exp_v) or (typ == 4 and abs(bits(got) - bits(exp_v)) <= 1 and (got > 0) == (exp_v > 0))
        if not ok:
            bad += 1
            print('FAIL atof(%r): type %d got %r expected %r' % (t_, typ, got, exp_v))
    check('fl_atof (cas fixes)', bad == 0, '%d erreurs' % bad)
    bad = 0
    for _ in range(1500):
        x = abs(rnd_float(rng, -60, 60))
        if x == 0:
            continue
        txt = '%.9g' % x
        r, cf = atof(txt)
        if cf:
            bad += 1
            print('FAIL atof(%s): CF' % txt)
            continue
        if (r['AX'] & 0xFF) == 4:
            got = em.getf(FAC)
        else:
            got = float(struct.unpack('<h', bytes(em.uc.mem_read(FAC, 2)))[0])
        exp_v = float(np.float32(Decimal(txt)))
        if abs(bits(got) - bits(exp_v)) > 1:
            bad += 1
            if bad <= 6:
                print('FAIL atof(%s): got %r (%08X) expected %r (%08X)' % (txt, got, bits(got), exp_v, bits(exp_v)))
    check('fl_atof aleatoire (1500, +-1 ulp)', bad == 0, '%d erreurs' % bad)
    r, cf = atof('abc')
    check('fl_atof sans nombre -> CF=1, SI inchange', cf == 1 and r['SI'] == STR)
    r, cf = atof('1E99')
    check('fl_atof depassement -> CF=1 AH=1', cf == 1 and (r['AX'] >> 8) == 1)
    r, cf = atof('12ABC')
    check("fl_atof s'arrete apres les chiffres", cf == 0 and r['SI'] == STR + 2)
    r, cf = atof(' -7.5 ', 1)
    check('fl_atof VAL: espaces et signe', cf == 0 and em.getf(FAC) == -7.5)

    # --- fonctions mathematiques ------------------------------------------------
    import math

    def fn(sym, x):
        em.setf(FAC, x)
        r, cf = em.call(sym)
        return em.getf(FAC), cf, r['AX'] & 0xFF

    def relerr(got, ref):
        return abs(got - ref) / max(abs(ref), 1e-30)

    specs = [
        ('fl_sqr', lambda x: math.sqrt(x), lambda: abs(rnd_float(rng, -60, 60)), 'rel', 3e-7),
        ('fl_exp', lambda x: math.exp(x), lambda: rng.uniform(-80, 85), 'rel', 1e-6),
        ('fl_log', lambda x: math.log(x), lambda: abs(rnd_float(rng, -60, 60)), 'abs', 4e-7),
        ('fl_sin', lambda x: math.sin(x), lambda: rng.uniform(-1000, 1000), 'abs', 6e-7),
        ('fl_cos', lambda x: math.cos(x), lambda: rng.uniform(-1000, 1000), 'abs', 6e-7),
        ('fl_tan', lambda x: math.tan(x), lambda: rng.uniform(-1.5, 1.5), 'rel', 2e-6),
        ('fl_atn', lambda x: math.atan(x), lambda: rnd_float(rng, -20, 20), 'abs', 4e-7),
    ]
    for sym, ref, gen, kind, tol in specs:
        bad = 0
        worst = 0.0
        for _ in range(600):
            x = float(f32(gen()))
            if x == 0.0 and sym in ('fl_sqr', 'fl_log'):
                continue
            got, cf, al = fn(sym, x)
            exp = ref(float(f32(x)))
            e = relerr(got, exp) if kind == 'rel' else abs(got - exp) / max(1.0, abs(exp))
            worst = max(worst, e)
            if cf or e > tol:
                bad += 1
                if bad <= 4:
                    print('FAIL %s(%r): got %r cf=%d expected %r (err %.3g)' % (sym, x, got, cf, exp, e))
        check('%s (600, err max %.2g)' % (sym, worst), bad == 0, '%d erreurs' % bad)
    got, cf, al = fn('fl_sqr', -4.0)
    check('sqr(-4) -> ERR_FC', cf == 1 and al == 5)
    got, cf, al = fn('fl_sqr', 0.0)
    check('sqr(0) = 0', cf == 0 and got == 0.0)
    got, cf, al = fn('fl_sqr', 16.0)
    check('sqr(16) = 4', got == 4.0)
    got, cf, al = fn('fl_log', 0.0)
    check('log(0) -> ERR_FC', cf == 1 and al == 5)
    got, cf, al = fn('fl_log', 1.0)
    check('log(1) = 0', got == 0.0)
    got, cf, al = fn('fl_exp', 100.0)
    check('exp(100) -> ERR_OV', cf == 1 and al == 6)
    got, cf, al = fn('fl_exp', -100.0)
    check('exp(-100) = 0', cf == 0 and got == 0.0)
    got, cf, al = fn('fl_exp', 0.0)
    check('exp(0) = 1', got == 1.0)
    got, cf, al = fn('fl_sin', 0.0)
    check('sin(0) = 0', got == 0.0)
    got, cf, al = fn('fl_cos', 0.0)
    check('cos(0) = 1', abs(got - 1.0) < 3e-7, repr(got))
    got, cf, al = fn('fl_atn', 1.0)
    check('atn(1) = pi/4', abs(got - math.pi / 4) < 1e-7)
    got, cf, al = fn('fl_sin', 3e5)
    check('sin(3e5) -> ERR_FC', cf == 1 and al == 5)
    bad = 0
    for x, y in [(2.0, 10.0), (3.0, 2.0), (2.0, -2.0), (10.0, 5.0), (2.0, 0.5), (9.0, 0.5), (-2.0, 3.0), (-2.0, 2.0),
                 (1.5, 7.0), (0.5, 3.0), (7.0, 0.0), (0.0, 3.0), (2.0, 100.0), (10.0, 0.3), (5.0, 1.0)]:
        em.setf(ARG, x)
        em.setf(FAC, y)
        r, cf = em.call('fl_pow')
        got = em.getf(FAC)
        exp = float(x) ** float(y)
        ok = cf == 0 and relerr(got, exp) < 2e-6
        if not ok:
            bad += 1
            print('FAIL pow(%r,%r): got %r cf=%d expected %r' % (x, y, got, cf, exp))
    check('fl_pow (cas)', bad == 0, '%d erreurs' % bad)
    em.setf(ARG, -2.0)
    em.setf(FAC, 0.5)
    r, cf = em.call('fl_pow')
    check('pow(-2,0.5) -> ERR_FC', cf == 1 and (r['AX'] & 0xFF) == 5)
    em.setf(ARG, 0.0)
    em.setf(FAC, -1.0)
    r, cf = em.call('fl_pow')
    check('pow(0,-1) -> ERR_DZ', cf == 1 and (r['AX'] & 0xFF) == 11)

    print('%d verifications de cas, %d echec(s)' % (total, fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
