"""Banc de vitesse et profil du BASIC de Solution-01 sous Unicorn (ROM 1.5, 1.6): bancs de Rugg/Feldman (BM1-BM8) + quelques autres.
Compte, par routine (libelle non local du listing), les instructions executees et les octets d'instruction
(le 8088 est limite par son bus: ~4 cycles par octet lu). Usage (depuis Solution-01): python tests/basic_bench.py [bm1 ... prt] [--top N] [--build]
Variable S01: autre copie de Solution-01 a mesurer (git worktree d'une version precedente).
Estimation du temps: 4 cycles par octet de bus (code + donnees), le 8088 etant limite par son bus, plus les
cycles internes des MUL/DIV (ROM 1.6)."""
import collections, os, sys
S01 = os.environ.get('S01', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(S01, 'tests'))
os.chdir(S01)
import basic_harness as H
import unicorn

BENCH = {
    'bm1': '10 FOR K=1 TO 1000\r20 NEXT K\r',
    'bm2': '10 K=0\r20 K=K+1\r30 IF K<1000 THEN 20\r',
    'bm3': '10 K=0\r20 K=K+1\r30 A=K/K*K+K-K\r40 IF K<1000 THEN 20\r',
    'bm4': '10 K=0\r20 K=K+1\r30 A=K/2*3+4-5\r40 IF K<1000 THEN 20\r',
    'bm5': '10 K=0\r20 K=K+1\r30 A=K/2*3+4-5\r40 GOSUB 820\r50 IF K<1000 THEN 20\r820 RETURN\r',
    'bm6': '10 K=0\r15 DIM M(5)\r20 K=K+1\r30 A=K/2*3+4-5\r40 GOSUB 820\r50 FOR L=1 TO 5\r60 NEXT L\r70 IF K<1000 THEN 20\r820 RETURN\r',
    'bm7': '10 K=0\r15 DIM M(5)\r20 K=K+1\r30 A=K/2*3+4-5\r40 GOSUB 820\r50 FOR L=1 TO 5\r55 M(L)=A\r60 NEXT L\r70 IF K<1000 THEN 20\r820 RETURN\r',
    'bm8': '10 K=0\r20 K=K+1\r30 A=K^2\r40 B=LOG(K)\r50 C=SIN(K)\r60 IF K<100 THEN 20\r',
    'str': '10 FOR I=1 TO 200\r20 A$=A$+"X"\r30 B$=MID$(A$,I,1)+LEFT$(A$,3)\r40 NEXT I\r',
    'prt': '10 FOR I=1 TO 200\r20 PRINT I;I*2;"ABC"\r30 NEXT I\r',
}
SUFFIX = 'RUN\rPRINT "FIN"\r'

args = [a for a in sys.argv[1:] if not a.startswith('--')]
top = 25
if '--top' in sys.argv:
    top = int(sys.argv[sys.argv.index('--top') + 1])
    args = [a for a in args if a != str(top)]
if '--build' in sys.argv or not os.path.exists(H.BIN):
    H.build()
lab = H.labels()
glob = [(a, n) for a, n in lab if not n.startswith('.')]
starts = [a for a, n in glob]
import bisect

counts = collections.Counter()
nbytes = collections.Counter()
data = [0]
extra = [0]
# cycles du 8088 au-dela de l'acces au bus (moyennes de la doc Intel): MUL/IMUL/DIV/IDIV 8 et 16 bits
MULDIV = {}
MDPEN = {(0, 4): 70, (0, 5): 90, (0, 6): 85, (0, 7): 105, (1, 4): 125, (1, 5): 145, (1, 6): 155, (1, 7): 175}


_RealUc = unicorn.Uc


def ProfUc(*a, **k):
    uc = _RealUc(*a, **k)
    def hook(uc, addr, size, ud):
        off = addr - 0xC0000
        counts[off] += 1
        nbytes[off] += size
        p = MULDIV.get(addr)
        if p is None:
            b = bytes(uc.mem_read(addr, 2))
            p = 0
            if b[0] in (0xF6, 0xF7) and (b[1] >> 3) & 7 >= 4:      # MUL, IMUL, DIV, IDIV
                p = MDPEN[(b[0] & 1, (b[1] >> 3) & 7)]
            MULDIV[addr] = p
        if p:
            extra[0] += p
    uc.hook_add(unicorn.UC_HOOK_CODE, hook, None, 0xC0000, 0xFFFFF)
    def mem(uc, access, addr, size, value, ud):
        data[0] += size
    uc.hook_add(unicorn.UC_HOOK_MEM_READ | unicorn.UC_HOOK_MEM_WRITE, mem)
    return uc


H.Uc = ProfUc
total = {}
for name in (args or list(BENCH)):
    counts.clear(); nbytes.clear(); data[0] = 0; extra[0] = 0
    out, st, _ = H.run(BENCH[name] + SUFFIX, max_insns=400_000_000, max_idle=3000)
    ok = 'FIN' in out
    byfn = collections.Counter(); byb = collections.Counter()
    for off, c in counts.items():
        i = bisect.bisect_right(starts, off) - 1
        fn = glob[i][1] if i >= 0 else '?'
        byfn[fn] += c
        byb[fn] += nbytes[off]
    ins = sum(counts.values()); by = sum(nbytes.values())
    total[name] = (ins, by, data[0], extra[0])
    print('== %s: %s, %d instructions, %d octets lus (~%.2f s a 4,77 MHz, estimation 4 cycles/octet + 2/instr)' % (
        name, 'OK' if ok else 'ECHEC ' + st['stopped'] + ' ' + out[-80:], ins, by, (by * 4 + ins * 2) / 4.77e6))
    entry = {n: counts.get(a, 0) for a, n in glob}
    for fn, c in byfn.most_common(top):
        print('   %-28s %9d  %5.1f%%  %9d o  %7d appels' % (fn, c, 100.0 * c / ins, byb[fn], entry.get(fn, 0)))
print()
for n, (i, b, dd, x) in total.items():
    print('%-5s %10d instr %10d octets code %10d octets donnees %9d cycles MUL/DIV  ~%.2f s a 4,77 MHz' % (
        n, i, b, dd, x, ((b + dd) * 4 + x) / 4.77e6))
print('(temps estime: 4 cycles par octet de bus + cycles internes des MUL/DIV)')
