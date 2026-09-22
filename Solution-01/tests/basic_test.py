#!/usr/bin/env python3
"""Banc d'essai de lib/basic.asm (BASIC "GW-BASIC-like") sous emulateur (Unicorn).

Voir tests/basic_harness.py: assemble tests/basic_test.asm (uart_* remplaces par
des ports fictifs, ou VRAIES routines en mode reel), execute en mode reel 16
bits et verifie sorties, erreurs, ramasse-miettes, arithmetique flottante,
retour au menu et qu'AUCUNE ecriture n'a lieu hors des zones prevues.

Usage (depuis la racine de Solution-01):  python3 tests/basic_test.py
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import basic_harness as H
from basic_harness import R, run, check, has

CR = '\r'


def ok_run(name, text, expected, **kw):
    got = R(text, **kw)
    check(name, got == expected, '%r != %r' % (got, expected))
    return got


def has_run(name, text, *subs, **kw):
    got = R(text, **kw)
    check(name, all(s in got for s in subs), repr(got))
    return got


# --- banniere / invite ------------------------------------------------------
out, st, _ = run('', max_idle=3000)
check('banniere + Ok', has(out, 'VE2CUY 86 BASIC', 'GW-BASIC', 'Ctrl-X', 'UP arrow', 'Ok'), out + ' ' + st['stopped'])
check('aucune ecriture hors zones (banniere)', not st['bad'], str(st['bad'][:5]))

# --- arithmetique et priorites ----------------------------------------------
ok_run('2+3*4', 'PRINT 2+3*4\r', ' 14 ')
ok_run('parentheses', 'PRINT (2+3)*4\r', ' 20 ')
check('division = flottant', R('PRINT 7/2, 10/4, 1/3\r').split() == ['3.5', '2.5', '.3333333'])
check('division entiere \\ et MOD', R('PRINT 7\\2, -7\\2, 7 MOD 3, -7 MOD 3\r').split() == ['3', '-3', '1', '-1'])
check('puissance (^ prioritaire sur le moins unaire)', R('PRINT 2^10, -2^2, 2^0.5, 2^-1\r').split() == ['1024', '-4', '1.414214', '.5'])
check('priorite ^ > * > + et gauche-droite', R('PRINT 2+3*2^2, 2^3^2, 100/10/5\r').split() == ['14', '64', '2'])
check('operateurs logiques', R('PRINT 5 AND 3, 5 OR 3, 5 XOR 3, NOT 5, 6 EQV 3, 5 IMP 3\r').split() == ['1', '7', '6', '-6', '-6', '-5'])
check('relationnels -> -1/0', R('PRINT 1<2, 2<1, 3=3, 3<>3, 2<=2, 3>=4\r').split() == ['-1', '0', '-1', '0', '-1', '0'])
check('priorite NOT/AND/OR', R('PRINT NOT 0 AND 1, 1 OR 0 AND 0, 1<2 AND 2<3\r').split() == ['1', '1', '-1'])
check('entiers 16 bits puis flottant', R('PRINT 32767+1, 200*200, -32768-1, 100*100\r').split() == ['32768', '40000', '-32769', '10000'])
check('&H et &O', R('PRINT &HFF, &H7FFF, &HFFFF, &O17, &H10+1\r').split() == ['255', '32767', '-1', '15', '17'])
check("\\ et MOD avec -1 (pas d'exception #DE)", R('PRINT 5\\-1, -32768 MOD -1\r').split() == ['-5', '0'])
ok_run('minuscules', 'print 6*7\r', ' 42 ')
got = R('? 1+1\r')
check('? = PRINT (mode direct)', got.endswith(' 2 '), repr(got))
check('? reecrit en PRINT a l\'ecran apres Entree (direct)', '\x1b[A' in R.out and 'PRINT 1+1' in R.out, repr(R.out))
got = R('10 ?"a";1\rRUN\r')
check('ligne numerotee: reecrite "10 PRINT ..." puis executee', '10 PRINT"a";1' in R.out and got.endswith('a 1 '), repr(R.out))
got = R('PRINT "?"\r')
check('"?" dans une chaine: pas de reecriture', '\x1b[A' not in R.out and got == '?', repr(R.out))
got = R('PRINT 1\r')
check('sans ?: pas de reecriture', '\x1b[A' not in R.out)

# --- affichage des nombres ---------------------------------------------------
ok_run('format flottant', 'PRINT .5;-.05;.001;100000!;123456.7;1234567;12345678;16777216;1E-5;3E38\r',
       ' .5 -.05  1E-03  100000  123456.7  1234567  1.234568E+07  1.677722E+07  1E-05  3E+38 ')
ok_run('sept chiffres, arrondi', 'PRINT 3.14159265;2/3;1E7;9999999;99999999\r',
       ' 3.141593  .6666667  1E+07  9999999  1E+08 ')
ok_run('zero et negatif', 'PRINT 0;-0;0.0;-1.5;-3\r', ' 0  0  0 -1.5 -3 ')
ok_run('litteral D et E', 'PRINT 1.5E3;2D2;1E+2\r', ' 1500  200  100 ')
ok_run('STR$ garde le signe', 'PRINT "[";STR$(5);STR$(-5);STR$(.5);"]"\r', '[ 5-5 .5]')
ok_run('TAB, SPC, virgule (zones de 14)', 'PRINT "A";TAB(5);"B";SPC(2);"C","D"\r', 'A   B  C      D')

# --- fonctions numeriques ----------------------------------------------------
ok_run('INT FIX SGN ABS', 'PRINT INT(-2.5);INT(2.5);FIX(-2.5);SGN(-3);SGN(0);SGN(2.2);ABS(-7);ABS(-1.5)\r',
       '-3  2 -2 -1  0  1  7  1.5 ')
ok_run('CINT CSNG', 'PRINT CINT(2.5);CINT(-2.5);CINT(3.49);CSNG(3)\r', ' 3 -3  3  3 ')
ok_run('SQR EXP LOG', 'PRINT SQR(16);SQR(2);EXP(1);LOG(10)\r', ' 4  1.414214  2.718282  2.302585 ')
ok_run('SIN COS TAN ATN', 'PRINT SIN(1);COS(1);TAN(1);ATN(1)*4\r', ' .841471  .5403022  1.557408  3.141593 ')
ok_run('FRE > 0', 'PRINT FRE(0)>1000\r', '-1 ')

# --- erreurs ---------------------------------------------------------------
ok_run('division par zero', 'PRINT 1/0\r', 'Division by zero')
ok_run('SQR(-1)', 'PRINT SQR(-1)\r', 'Illegal function call')
ok_run('LOG(0)', 'PRINT LOG(0)\r', 'Illegal function call')
ok_run('depassement 10^40', 'PRINT 10^40\r', 'Overflow')
ok_run('EXP(100)', 'PRINT EXP(100)\r', 'Overflow')
ok_run('type mismatch', 'PRINT "A"+1\r', 'Type mismatch')
ok_run('type mismatch (affectation)', 'A$=5\r', 'Type mismatch')
ok_run('syntax error', 'PRINT 1+\r', 'Syntax error')
ok_run('syntax error (mot inconnu)', 'FOO BAR\r', 'Syntax error')
ok_run('ligne inexistante', 'GOTO 999\r', 'Undefined line number')
ok_run('sous-programme sans GOSUB', 'RETURN\r', 'RETURN without GOSUB')
ok_run('NEXT sans FOR', 'NEXT\r', 'NEXT without FOR')
ok_run('WEND sans WHILE', 'WEND\r', 'WEND without WHILE')
ok_run('CONT impossible', 'CONT\r', "Can't continue")
ok_run('DEF FN en direct', 'DEF FNA(X)=X\r', 'Illegal direct')
ok_run('fonction non definie', 'PRINT FNZ(1)\r', 'Undefined user function')
ok_run('ASC("")', 'PRINT ASC("")\r', 'Illegal function call')
ok_run('CHR$(256)', 'PRINT CHR$(256)\r', 'Illegal function call')
ok_run('entier hors limites', 'A%=40000\r', 'Overflow')
ok_run('erreur en programme: ligne indiquee', '10 PRINT 1/0\rRUN\r', 'Division by zero in 10')
ok_run('erreur arrete le programme', '10 PRINT "A"\r20 A=1/0\r30 PRINT "B"\rRUN\r', 'A\nDivision by zero in 20')
ok_run('chaine trop longue', 'A$=STRING$(200,"X"):B$=A$+A$\r', 'String too long')

# --- variables et types -------------------------------------------------------
ok_run('variables', 'A=5:B=A*3:PRINT A+B\r', ' 20 ')
ok_run('noms longs, majuscules/minuscules', 'total=3:PRINT TOTAL+total\r', ' 6 ')
ok_run('A% entier arrondi, A! A$ distinctes', 'A%=3.7:A!=1.5:A$="Z":PRINT A%;A!;A$\r', ' 4  1.5 Z')
ok_run('DEFINT / DEFSTR / DEFSNG', 'DEFINT I-K:DEFSTR S:I=2.6:S="ok":PRINT I;S\r', ' 3 ok')
ok_run('variable non initialisee', 'PRINT X;Y$;"|"\r', ' 0 |')
ok_run('SWAP', 'A=5:B=7:SWAP A,B:PRINT A;B:A$="x":B$="yz":SWAP A$,B$:PRINT A$;B$\r', ' 7  5 \nyzx')
ok_run('SWAP type mismatch', 'A=1:B$="x":SWAP A,B$\r', 'Type mismatch')
ok_run('tableaux 1 et 2 dimensions', 'DIM A(3),B(2,2):A(3)=7:B(2,1)=9:B(1,2)=4:PRINT A(3);B(2,1);B(1,2)\r', ' 7  9  4 ')
ok_run('tableau implicite (0..10)', 'A(10)=5:PRINT A(10);A(0)\r', ' 5  0 ')
ok_run('indice hors limites', 'DIM A(3):A(4)=1\r', 'Subscript out of range')
ok_run('indice negatif', 'A(-1)=1\r', 'Subscript out of range')
ok_run('DIM redefini', 'DIM A(3):DIM A(4)\r', 'Duplicate Definition')
ok_run('tableau de chaines', 'DIM S$(3):S$(1)="AB":S$(2)="CD":PRINT S$(1)+S$(2);S$(3);"|"\r', 'ABCD|')
ok_run('tableau d\'entiers', 'DIM I%(5):I%(2)=300:I%(3)=I%(2)*2:PRINT I%(3)\r', ' 600 ')
ok_run('ERASE puis redimensionner', 'DIM A(3):A(1)=5:ERASE A:DIM A(9):PRINT A(1);A(9)\r', ' 0  0 ')
ok_run('acces tableau imbrique', 'DIM A(3):A(1)=2:A(2)=3:PRINT A(A(1))\r', ' 3 ')

# --- chaines ---------------------------------------------------------------
ok_run('concatenation et LEN', 'A$="HELLO":B$=A$+" WORLD":PRINT B$;LEN(B$)\r', 'HELLO WORLD 11 ')
ok_run('LEFT$ RIGHT$ MID$', 'PRINT LEFT$("ABCDEF",2);RIGHT$("ABCDEF",3);MID$("ABCDEF",2,3);MID$("ABCDEF",5)\r', 'ABDEFBCDEF')
ok_run('bornes des sous-chaines', 'PRINT "[";LEFT$("AB",5);"|";RIGHT$("AB",0);"|";MID$("AB",3);"|";MID$("AB",0+1,0);"]"\r', '[AB|||]')
ok_run('CHR$ ASC STR$ VAL', 'PRINT CHR$(72);CHR$(105);ASC("A");VAL("3.5")+1;VAL("  -2xyz");VAL("abc");VAL("1E3")\r', 'Hi 65  4.5 -2  0  1000 ')
ok_run('INSTR', 'PRINT INSTR("HELLO","LL");INSTR("HELLO","Z");INSTR(3,"HELLOLL","LL");INSTR("AB","");INSTR("AB","ABC")\r', ' 3  0  3  1  0 ')
ok_run('UCASE$ LCASE$', 'PRINT UCASE$("abC1");LCASE$("ABc1")\r', 'ABC1abc1')
ok_run('HEX$ OCT$', 'PRINT HEX$(255);HEX$(-1);HEX$(0);OCT$(8);HEX$(65535)\r', 'FFFFFF0' + '10FFFF')
ok_run('STRING$ SPACE$', 'PRINT STRING$(3,"ab");STRING$(2,65);"[";SPACE$(3);"]"\r', 'aaaAA[   ]')
ok_run('comparaison de chaines', 'PRINT "A"<"B";"B"<"A";"AB">"A";"A"="A";"a">"A";""<"A";"A"<>"a"\r', '-1  0 -1 -1 -1 -1 -1 ')
ok_run('MID$ en instruction', 'A$="HELLO WORLD":MID$(A$,1,5)="JELLY!":PRINT A$:MID$(A$,7)="Wo":PRINT A$\r', 'JELLY WORLD\nJELLY WoRLD')
ok_run('MID$ instruction sur litteral (copie)', 'A$="ABC":MID$(A$,2,1)="x":PRINT A$:B$="ABC":PRINT B$\r', 'AxC\nABC')
ok_run('chaine vide / affectation d\'un litteral', 'A$="":PRINT LEN(A$);"|";A$;"|"\r', ' 0 ||')
ok_run('egal dans une chaine', 'A$="A=B":PRINT A$\r', 'A=B')
ok_run('guillemet non ferme', 'PRINT "abc\r', 'abc')
ok_run('STR$/VAL aller-retour', 'PRINT VAL(STR$(123.456))\r', ' 123.456 ')

# --- ramasse-miettes ---------------------------------------------------------
GC = ('10 DIM S$(20)\r20 FOR I=0 TO 20:S$(I)="ITEM"+STR$(I):NEXT\r'
      '30 FOR I=1 TO 1500:B$=STR$(I)+"abcdefghijklmnopqrstuvwxyz":C$=LEFT$(B$,10)+RIGHT$(B$,3):NEXT\r'
      '40 PRINT C$;"|";B$\r50 FOR I=0 TO 20 STEP 5:PRINT S$(I);:NEXT\r60 PRINT\rRUN\r')
got = R(GC, max_insns=400_000_000)
check('ramasse-miettes: chaines vivantes preservees (tableau, variables)',
      got.startswith(' 1500abcdexyz| 1500abcdefghijklmnopqrstuvwxyz\nITEM 0ITEM 5ITEM 10ITEM 15ITEM 20'), repr(got))
check('ramasse-miettes: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:5]))
ok_run('alias de variable survit au GC (A$+A$ pendant allocations)',
       '10 A$="0123456789"\r20 FOR I=1 TO 2500:B$=A$+A$+A$:NEXT\r30 PRINT B$;LEN(A$+B$)\rRUN\r',
       '012345678901234567890123456789 40 ', max_insns=400_000_000)
ok_run('chaines temporaires dans une expression longue',
       '10 FOR I=1 TO 1500:X$=LEFT$(STR$(I)+STRING$(20,"z"),8)+MID$("abcdefgh",2,3):NEXT\r20 PRINT X$\rRUN\r',
       ' 1500zzzbcd', max_insns=400_000_000)
ok_run('memoire epuisee -> Out of string space / memory',
       '10 A$=STRING$(250,"x")\r20 DIM B$(300)\r30 FOR I=0 TO 300:B$(I)=A$+STR$(I):NEXT\r40 PRINT "fini"\rRUN\r',
       'Out of string space in 30')

# --- flot de controle ----------------------------------------------------------
ok_run('FOR/NEXT', '10 FOR I=1 TO 5\r20 PRINT I;\r30 NEXT I\rRUN\r', ' 1  2  3  4  5 ')
ok_run('FOR STEP negatif et flottant', '10 FOR I=10 TO 1 STEP -3:PRINT I;:NEXT\r20 FOR X=0 TO 1 STEP .25:PRINT X;:NEXT\rRUN\r',
       ' 10  7  4  1  0  .25  .5  .75  1 ')
ok_run('FOR imbriques et NEXT I,J', '10 FOR I=1 TO 2:FOR J=1 TO 2:PRINT I*10+J;:NEXT J,I\rRUN\r', ' 11  12  21  22 ')
ok_run('FOR: corps execute une fois si debut > fin', '10 FOR I=5 TO 1:PRINT I;:NEXT\rRUN\r', ' 5 ')
ok_run('FOR entier (A%) et valeur finale', '10 FOR I%=1 TO 3:NEXT:PRINT I%\rRUN\r', ' 4 ')
ok_run('FOR relance de la meme variable (cadre remplace)',
       '10 FOR I=1 TO 2\r20 FOR I=1 TO 2:PRINT I;:NEXT\r30 NEXT\rRUN\r', ' 1  2 \nNEXT without FOR in 30')
ok_run('FOR sans NEXT -> fin du programme', '10 FOR I=1 TO 3\r20 PRINT I;\rRUN\r', ' 1 ')
ok_run('GOSUB/RETURN', '10 GOSUB 100:GOSUB 100:PRINT A:END\r100 A=A+7:RETURN\rRUN\r', ' 14 ')
ok_run('RETURN depuis une boucle FOR', '10 GOSUB 100:PRINT "ok":END\r100 FOR I=1 TO 5:IF I=3 THEN RETURN\r110 NEXT:RETURN\rRUN\r', 'ok')
ok_run('ON GOTO / ON GOSUB', '10 FOR I=0 TO 3:ON I GOTO 100,200:PRINT "x";:GOTO 300\r100 PRINT "a";:GOTO 300\r'
       '200 PRINT "b";\r300 NEXT:ON 2 GOSUB 500,600:PRINT "z":END\r500 PRINT "5":RETURN\r600 PRINT "6";:RETURN\rRUN\r',
       'xabx6z')
ok_run('WHILE/WEND imbriques', '10 I=0\r20 WHILE I<3:J=0\r30 WHILE J<2:PRINT I*10+J;:J=J+1:WEND\r40 I=I+1:WEND:PRINT "e"\rRUN\r',
       ' 0  1  10  11  20  21 e')
ok_run('WHILE faux d\'emblee', '10 WHILE 0:PRINT "no":WEND:PRINT "fin"\rRUN\r', 'fin')
ok_run('WHILE sans WEND', '10 WHILE 0:PRINT "no"\rRUN\r', 'WHILE without WEND in 10')
ok_run('IF THEN ELSE', '10 FOR I=1 TO 3:IF I=2 THEN PRINT "deux" ELSE PRINT I\r20 NEXT\rRUN\r', ' 1 \ndeux\n 3 ')
ok_run('IF GOTO et THEN numero', '10 IF 1 THEN 30\r20 PRINT "non"\r30 IF 0 GOTO 20 ELSE 50\r40 PRINT "non"\r50 PRINT "oui"\rRUN\r', 'oui')
ok_run('IF imbriques ELSE', '10 FOR I=1 TO 3:IF I>1 THEN IF I>2 THEN PRINT "c" ELSE PRINT "b" ELSE PRINT "a"\r20 NEXT\rRUN\r', 'a\nb\nc')
ok_run('IF sur une chaine -> Type mismatch', 'IF "A" THEN PRINT 1\r', 'Type mismatch')
ok_run('END arrete', '10 PRINT 1:END:PRINT 2\rRUN\r', ' 1 ')
ok_run(':, lignes multiples, REM et \'', '10 PRINT 1:REM PRINT 2:PRINT 3\r20 PRINT 4 \' commentaire\rRUN\r', ' 1 \n 4 ')
ok_run('DATA/READ/RESTORE', '10 DATA 1,2.5,"A, B", x y ,-3\r20 READ A,B,C$,D$,E\r30 PRINT A;B;C$;"|";D$;"|";E\r'
       '40 RESTORE:READ Z:PRINT Z:READ Z:READ Z$:READ Z$:READ Z:READ Z\rRUN\r', ' 1  2.5 A, B|x y|-3 \n 1 \nOut of DATA in 40')
ok_run('DATA sur plusieurs lignes', '10 DATA 1,2\r20 DATA 3\r30 FOR I=1 TO 3:READ A:PRINT A;:NEXT\rRUN\r', ' 1  2  3 ')
ok_run('READ type incorrect', '10 DATA abc\r20 READ A\rRUN\r', 'Syntax error in 10')
ok_run('RESTORE n', '10 DATA 1\r20 DATA 2\r30 READ A:RESTORE 20:READ B:PRINT A;B\rRUN\r', ' 1  2 ')
ok_run('DEF FN (plusieurs parametres, chaines)', '10 DEF FNA(X,Y)=X*10+Y:DEF FNB$(S$)=S$+"!"\r'
       '20 X=5:PRINT FNA(1,2);X;FNB$("HI");FNA(FNA(1,1),2)\rRUN\r', ' 12  5 HI! 112 ')
ok_run('DEF FN sans parametre, redefinition', '10 DEF FNP=3.5\r20 PRINT FNP*2:DEF FNP=1:PRINT FNP\rRUN\r', ' 7 \n 1 ')
ok_run('DEF FN: mauvais nombre d\'arguments', '10 DEF FNA(X)=X\r20 PRINT FNA(1,2)\rRUN\r', 'Syntax error in 20')
ok_run('TRON/TROFF', '10 TRON\r20 PRINT "a"\r30 TROFF\r40 PRINT "b"\rRUN\r', '[20]a\n[30]b')

# --- entrees -----------------------------------------------------------------
got = R('10 INPUT A,B\r20 PRINT A+B\rRUN\r3,4\r')
check('INPUT numerique, deux valeurs', got.endswith(' 7 '), repr(got))
got = R('10 INPUT "Nom";N$\r20 INPUT "Age",A\r30 PRINT N$;A\rRUN\rBOB\r42\r')
check('INPUT avec invite ; et ,', got == 'Nom? BOB\nAge42\nBOB 42 ', repr(got))
got = R('10 LINE INPUT "L? ";L$\r20 PRINT L$\rRUN\rhello, "w" x\r')
check('LINE INPUT garde la ligne', got == 'L? hello, "w" x' or got.endswith('hello, "w" x'), repr(got))
got = R('10 INPUT A\r20 PRINT A\rRUN\rXYZ\r9\r')
check('INPUT invalide -> ?Redo from start', '?Redo from start' in got and got.endswith(' 9 '), repr(got))
got = R('10 INPUT A,B$\r20 PRINT A;B$\rRUN\r1\r2,"a,b"\r')
check('INPUT: champ manquant -> Redo, champ entre guillemets', '?Redo from start' in got and got.endswith(' 2 a,b'), repr(got))
got = R('10 A$=INKEY$:B$=INKEY$:PRINT LEN(A$)+LEN(B$)\rRUN\r')
check('INKEY$ sans touche -> chaine vide', got == ' 0 ', repr(got))
got = R('10 X$=INPUT$(3):PRINT X$\rRUN\rabcdef\r')
check('INPUT$(3)', 'abc' in got, repr(got))

# --- HELP ---------------------------------------------------------------------
got = R('help\r')
check('HELP: sommaire des commandes', all(w in got for w in ('command summary', 'LIST', 'PRINT', 'FOR..TO', 'LEFT$', 'PEEK', 'RND', 'INPUT$', 'FRE(0)', 'free bytes')), repr(got))
got = R('10 HELP:PRINT "apres"\rRUN\r')
check('HELP dans un programme, puis suite', 'command summary' in got and got.endswith('apres'), repr(got[-40:]))

# --- horloge: TIMER, TIME$, DATE$ (simulacre du pont: 2026-09-20 12:34:56.78) -------
ok_run('TIME$ et DATE$ (fonctions)', 'PRINT TIME$;" ";DATE$\r', '12:34:56 09-20-2026')
ok_run('TIMER = secondes depuis minuit', 'PRINT TIMER\r', ' 45296.78 ')
ok_run('TIMER dans une expression', 'T=TIMER:PRINT INT(T/3600);INT((T-3600*12)/60)\r', ' 12  34 ')
ok_run('RANDOMIZE TIMER', 'RANDOMIZE TIMER:PRINT RND<1\r', '-1 ')
ok_run('TIME$ = "hh:mm:ss"', 'TIME$="01:02:03":PRINT TIME$;" ";DATE$\r', '01:02:03 09-20-2026')
ok_run('TIME$ = "h" et "h:m"', 'TIME$="7":PRINT TIME$:TIME$="8:5":PRINT TIME$\r', '07:00:00\n08:05:00')
ok_run('DATE$ = "mm-dd-yyyy" (heure conservee)', 'DATE$="12-25-2027":PRINT DATE$;" ";TIME$\r', '12-25-2027 12:34:56')
ok_run('DATE$ = "m/d/yy" (annee sur 2 chiffres)', 'DATE$="1/2/30":PRINT DATE$\r', '01-02-2030')
ok_run('DATE$ = 29 fevrier bissextile', 'DATE$="02-29-2028":PRINT DATE$\r', '02-29-2028')
ok_run('TIME$ dans une chaine', 'A$="Il est "+TIME$:PRINT A$\r', 'Il est 12:34:56')
ok_run('TIME$ invalide -> Illegal function call', 'TIME$="25:00:00"\r', 'Illegal function call')
ok_run('TIME$ invalide (texte)', 'TIME$="abc"\r', 'Illegal function call')
ok_run('DATE$ invalide (mois 13)', 'DATE$="13-01-2027"\r', 'Illegal function call')
ok_run('DATE$ invalide (30 fevrier)', 'DATE$="02-30-2027"\r', 'Illegal function call')
ok_run('DATE$ invalide (29 fevrier non bissextile)', 'DATE$="02-29-2027"\r', 'Illegal function call')
ok_run('DATE$ hors 2000-2099', 'DATE$="01-01-1999"\r', 'Illegal function call')
ok_run('DATE$ sans = : Syntax error', 'DATE$ "01-01-2027"\r', 'Syntax error')
ok_run('TIME$ type mismatch', 'TIME$=5\r', 'Type mismatch')
ok_run('pont muet -> Device Timeout', 'PRINT TIME$\r', 'Device Timeout', bridge=H.BridgeModel(mute=True))
ok_run('pont muet (TIMER, en programme)', '10 PRINT TIMER\rRUN\r', 'Device Timeout in 10', bridge=H.BridgeModel(mute=True))
check('horloge: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:5]))
got = R('HELP\r')
check('HELP mentionne TIMER TIME$ DATE$', all(w in got for w in ('TIMER', 'TIME$', 'DATE$')), repr(got[-200:]))

# --- disque: SAVE, LOAD, MERGE, RUN "f", FILES, KILL, FORMAT (modele du pont: fichiers en dict) ---
BM = H.BridgeModel
NL = chr(10)
CRLF = chr(13) + chr(10)
got = R('files\r')
check('FILES (disque vide): espace libre seul', got == '1000000 bytes free', repr(got))
got = R('10 print 1\r20 print "a b"\rsave "t1"\rfiles\r')
b = R.st['bridge']
check('SAVE: fichier T1.BAS en texte ASCII (CR LF)', b.files.get('T1.BAS') == bytearray(('10 PRINT 1' + CRLF + '20 PRINT "a b"' + CRLF).encode()),
      repr(dict(b.files)))
check('FILES: nom, taille et espace libre', 'T1.BAS' in got and '28' in got and got.endswith('999972 bytes free'), repr(got))
b = BM(files={'P.BAS': (b'10 PRINT 5' + CRLF.encode() + b'20 PRINT 6' + CRLF.encode())})
got = R('load "p"\rlist\r', bridge=b)
check('LOAD puis LIST', got.endswith('10 PRINT 5' + NL + '20 PRINT 6'), repr(got))
got = R('10 print 9\rload "p"\rlist\r', bridge=BM(files={'P.BAS': b'10 PRINT 5\r\n20 PRINT 6\r\n'}))
check('LOAD remplace le programme en memoire', got.endswith('10 PRINT 5' + NL + '20 PRINT 6') and 'PRINT 9' not in got.split('LOAD')[-1], repr(got))
got = R('5 print 0\r20 print 8\rmerge "p"\rlist\r', bridge=BM(files={'P.BAS': b'10 PRINT 5\r\n20 PRINT 6\r\n'}))
check('MERGE fusionne (meme numero: remplace)', got.endswith('5 PRINT 0' + NL + '10 PRINT 5' + NL + '20 PRINT 6'), repr(got))
got = R('run "p"\r', bridge=BM(files={'P.BAS': b'10 PRINT 5\r\n20 PRINT 6\r\n'}))
check('RUN "f": charge puis execute', got.endswith(' 5 ' + NL + ' 6 '), repr(got))
got = R('LOAD "x.txt"\rLIST\r', bridge=BM(files={'X.TXT': b'10 PRINT 1\r\n'}))
check('LOAD: extension explicite respectee, nom en minuscules accepte', got.endswith('10 PRINT 1'), repr(got))
got = R('10 print 1\rsave "abc"\rsave "d.txt"\rkill "abc.bas"\rfiles\r')
check('KILL (nom exact) et FILES', got.startswith('D.TXT') and 'ABC' not in got, repr(got))
got = R('kill "abc"\r')
check('KILL sans extension: nom exact, fichier absent', got == 'File not found', repr(got))
ok_run('LOAD: fichier absent', 'load "zz"\r', 'File not found')
ok_run('SAVE: nom vide', 'save ""\r', 'Bad file name')
ok_run('SAVE: nom trop long', 'save "abcdefghijklmn"\r', 'Bad file name')
ok_run('SAVE: caractere interdit', 'save "a/b"\r', 'Bad file name')
ok_run('disque non pret', 'files\r', 'Disk not Ready', bridge=BM(ready=False))
ok_run('pont muet -> Device Timeout (FILES)', 'files\r', 'Device Timeout', bridge=BM(mute=True))
ok_run('LOAD dans un programme: Illegal direct', '10 LOAD "p"\rRUN\r', 'Illegal direct in 10', bridge=BM(files={'P.BAS': b'10 PRINT 1\r\n'}))
ok_run('fichier avec une instruction sans numero', 'load "p"\r', 'Direct statement in file', bridge=BM(files={'P.BAS': b'PRINT 1\r\n'}))
got = R('10 print "un programme assez long pour depasser le disque"\r20 print 2\rsave "big"\r', bridge=BM(free=30))
check('SAVE: disque plein', got == 'Disk full', repr(got))
got = R('format "yes"\rfiles\r', bridge=BM(files={'A.BAS': b'10 PRINT 1\r\n'}))
check('FORMAT "YES" efface les fichiers', got == '1000000 bytes free', repr(got))
ok_run('FORMAT sans confirmation', 'format "no"\r', 'Illegal function call', bridge=BM(files={'A.BAS': b'x'}))
check('FORMAT sans confirmation: fichiers intacts', 'A.BAS' in R.st['bridge'].files)
LONG = ''.join('%d print "ligne %d";x+%d:let y=y+%d\r' % (10 * i, i, i, i) for i in range(1, 41))
got = R(LONG + 'save "long"\rnew\rload "long"\rlist\r', max_insns=200_000_000)
lst = got.split(NL)
check('SAVE/NEW/LOAD/LIST: 40 lignes (fichier de plusieurs blocs de 32 octets)',
      len(lst) == 40 and lst[0] == '10 PRINT "ligne 1";X+1:LET Y=Y+1' and lst[-1] == '400 PRINT "ligne 40";X+40:LET Y=Y+40'
      and len(R.st['bridge'].files['LONG.BAS']) > 1000, str(len(lst)) + ' ' + repr(got[-120:]))
check('disque: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:4]))

# --- fichiers de donnees: OPEN, CLOSE, PRINT#, WRITE#, INPUT#, LINE INPUT#, EOF ---------------
got = R('OPEN "d.txt" FOR OUTPUT AS #1:PRINT #1,"hello";" world":PRINT #1,42:CLOSE #1\r')
b = R.st['bridge']
check('OPEN OUTPUT + PRINT# + CLOSE: rien sur la console, tout dans le fichier',
      got == '' and b.files.get('D.TXT') == bytearray(b'hello world' + CRLF.encode() + b' 42 ' + CRLF.encode()) and b.cur is None,
      repr(got) + repr(dict(b.files)))
R('OPEN "O",#1,"e.txt":PRINT #1,"a","b":WRITE #1,"a,b",5,-2.5,0:CLOSE\r')
check('OPEN "O",#1,"f" (ancienne forme), PRINT# avec zone (,), WRITE# (guillemets, sans espace)',
      R.st['bridge'].files.get('E.TXT') == bytearray(b'a' + b' ' * 13 + b'b' + CRLF.encode() + b'"a,b",5,-2.5,0' + CRLF.encode()),
      repr(dict(R.st['bridge'].files)))
got = R('OPEN "i" FOR INPUT AS #1\rINPUT #1,A$,B$:PRINT A$;"|";B$:CLOSE #1\r', bridge=BM(files={'I': b'hi,there\r\n'}))
check('INPUT# de deux chaines', got == 'hi|there', repr(got))
got = R('OPEN "i" FOR INPUT AS #1\rINPUT#1,A,B$,C\rPRINT A;B$;C\r', bridge=BM(files={'I': b'12,"x,y",3.5\r\n'}))
check('INPUT#1 (sans espace) : nombres et chaine entre guillemets avec virgule', got == ' 12 x,y 3.5 ', repr(got))
got = R('OPEN "i" FOR INPUT AS #1\rINPUT #1,A,B\rPRINT A;B\r', bridge=BM(files={'I': b'1\r\n2\r\n'}))
check('INPUT# : champs sur plusieurs lignes du fichier', got == ' 1  2 ', repr(got))
got = R('OPEN "i" FOR INPUT AS #1\rLINE INPUT #1,A$\rPRINT A$\rLINE INPUT #1,B$\rPRINT B$\r', bridge=BM(files={'I': b'un, deux\r\ntrois\n'}))
check('LINE INPUT# (CR LF, puis LF seul)', got == 'un, deux\ntrois', repr(got))
got = R('OPEN "d" FOR OUTPUT AS #1\rFOR I=1 TO 60:PRINT #1,"line";I:NEXT:CLOSE\r'
        'OPEN "d" FOR INPUT AS #1\rN=0\rWHILE NOT EOF(1):LINE INPUT #1,A$:N=N+1:WEND\rPRINT N;A$\rCLOSE\r', max_insns=200_000_000)
check('60 lignes (plusieurs blocs de 32 octets) ecrites puis relues avec EOF', got == ' 60 line 60 ' and len(R.st['bridge'].files['D']) > 400, repr(got))
got = R('OPEN "d" FOR OUTPUT AS #1\rFOR I=1 TO 20:WRITE #1,"n",I,I/4:NEXT:CLOSE\r'
        'OPEN "d" FOR INPUT AS #1\rS=0\rWHILE NOT EOF(1):INPUT #1,A$,I,X:S=S+I+X:WEND\rPRINT S\r', max_insns=200_000_000)
check('WRITE# puis INPUT# (aller-retour de champs)', got == ' 262.5 ', repr(got))
got = R('OPEN "d" FOR INPUT AS #1\rPRINT EOF(1)\rINPUT #1,A\rPRINT A;EOF(1)\rPRINT EOF(2)\r', bridge=BM(files={'D': b'5\r\n'}))
check('EOF(1): 0 avant, -1 apres la derniere ligne (le LF final est absorbe); EOF(2) = Bad file number',
      got == ' 0 \n 5 -1 \nBad file number', repr(got))
R('OPEN "d" FOR APPEND AS #1\rPRINT #1,"z"\rCLOSE\r', bridge=BM(files={'D': b'x\r\n'}))
check('APPEND ajoute a la fin', R.st['bridge'].files['D'] == bytearray(b'x\r\nz\r\n'), repr(R.st['bridge'].files))
ok_run('PRINT # sans OPEN', 'PRINT #1,"x"\r', 'Bad file number')
ok_run('INPUT # sans OPEN', 'INPUT #1,A\r', 'Bad file number')
ok_run('EOF sans OPEN', 'PRINT EOF(1)\r', 'Bad file number')
ok_run('numero de fichier 2 refuse', 'OPEN "d" FOR OUTPUT AS #2\r', 'Bad file number')
ok_run('OPEN deux fois', 'OPEN "d" FOR OUTPUT AS #1\rOPEN "e" FOR OUTPUT AS #1\r', 'File already open')
ok_run('SAVE pendant un fichier ouvert', 'OPEN "d" FOR OUTPUT AS #1\rSAVE "z"\r', 'File already open')
ok_run('OPEN INPUT: fichier absent', 'OPEN "d" FOR INPUT AS #1\r', 'File not found')
ok_run('PRINT # sur un fichier ouvert en lecture', 'OPEN "d" FOR INPUT AS #1\rPRINT #1,"x"\r', 'Bad file mode', bridge=BM(files={'D': b'x\r\n'}))
ok_run('INPUT # en fin de fichier', 'OPEN "d" FOR INPUT AS #1\rINPUT #1,A$\rINPUT #1,B$\r', 'Input past end', bridge=BM(files={'D': b'x\r\n'}))
ok_run('OPEN: mode inconnu', 'OPEN "X",#1,"d"\r', 'Bad file mode')
ok_run('OPEN: syntaxe', 'OPEN "d" AS #1\r', 'Syntax error')
got = R('OPEN "d" FOR OUTPUT AS #1\rPRINT #1,1/0\rPRINT "ok"\rCLOSE\r')
check('erreur pendant PRINT#: message a la console, la sortie revient a la console',
      got == 'Division by zero\nok' and R.st['bridge'].files['D'] == bytearray(), repr(got))
R('10 OPEN "d" FOR OUTPUT AS #1\r20 PRINT #1,"q"\r30 END\rRUN\r')
check('END ferme le fichier de donnees', R.st['bridge'].cur is None and R.st['bridge'].files['D'] == bytearray(b'q' + CRLF.encode()), repr(R.st['bridge'].files))
R('10 OPEN "d" FOR OUTPUT AS #1\r20 PRINT #1,"q"\rRUN\r')
check('fin du programme ferme le fichier de donnees', R.st['bridge'].cur is None)
got = R('10 OPEN "d" FOR OUTPUT AS #1\r20 STOP\rRUN\rPRINT #1,"z"\rCLOSE\r')
check('STOP laisse le fichier ouvert (comme GW-BASIC)', 'Break in 20' in got and R.st['bridge'].files['D'] == bytearray(b'z' + CRLF.encode()), repr(got))
R('OPEN "d" FOR OUTPUT AS #1\rPRINT #1,"a"\rNEW\r')
check('NEW ferme le fichier', R.st['bridge'].cur is None)
got = R('A#=5\rPRINT A#\r')
check("'#' suffixe de type toujours reconnu (A#, comme A)", got == ' 5 ', repr(got))
got = R('10 open "d" for output as #1\r20 print#1,"x"\r30 close#1\rlist\r')
check('LIST: PRINT#1 et CLOSE#1', got.endswith('10 OPEN "d" FOR OUTPUT AS #1\n20 PRINT#1,"x"\n30 CLOSE#1'), repr(got))
got = R('OPEN "d" FOR OUTPUT AS #1\r', bridge=BM(mute=True))
check('OPEN: pont muet -> Device Timeout', got == 'Device Timeout', repr(got))
got = R('OPEN "d" FOR OUTPUT AS #1\rFOR I=1 TO 30:PRINT #1,"0123456789";:NEXT:CLOSE\r', bridge=BM(free=100))
check('disque plein pendant PRINT#: erreur a la fin de l\'instruction ou a CLOSE', got == 'Disk full', repr(got))
check('fichiers de donnees: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:4]))

# --- acces direct aux secteurs: DSKREAD, DSKWRITE -------------------------------------------
b = BM()
b.sectors[5] = bytes(range(256)) * 2
got = R('DSKREAD 5,&HF400\rPRINT PEEK(&HF400);PEEK(&HF401);PEEK(&HF4FF);PEEK(&HF500);PEEK(&HF5FF)\r', bridge=b)
check('DSKREAD: secteur 5 en memoire (512 octets, blocs de 32)', got == ' 0  1  255  0  255 ', repr(got))
got = R('FOR I=0 TO 511:POKE &HF400+I,(I*7+3) AND 255:NEXT\rDSKWRITE 7,&HF400\r', bridge=b, max_insns=200_000_000)
check('DSKWRITE: secteur 7 ecrit', b.sectors.get(7) == bytes(((i * 7 + 3) & 255) for i in range(512)), repr(b.sectors.get(7))[:80] + ' ' + repr(got))
got = R('FOR I=0 TO 511:POKE &HF400+I,I AND 255:NEXT\rDSKWRITE 3,&HF400\rFOR I=0 TO 511:POKE &HF400+I,0:NEXT\r'
        'DSKREAD 3,&HF400\rS=0:FOR I=0 TO 511:S=S+PEEK(&HF400+I):NEXT:PRINT S\r', max_insns=400_000_000)
check('DSKWRITE puis DSKREAD: aller-retour (somme des 512 octets)', got == ' 65280 ', repr(got))
ok_run('DSKREAD: secteur hors du disque', 'DSKREAD 10,&HF400\r', 'Disk I/O error', bridge=BM(nsec=10))
ok_run('DSKREAD: disque non pret', 'DSKREAD 1,&HF400\r', 'Disk not Ready', bridge=BM(ready=False))
ok_run('DSKREAD: pont muet', 'DSKREAD 1,&HF400\r', 'Device Timeout', bridge=BM(mute=True))
ok_run('DSKREAD: zone protegee (table des vecteurs)', 'DEF SEG=0:DSKREAD 1,0\r', 'Illegal function call')
ok_run('DSKREAD: 512 octets debordent du segment', 'DSKREAD 1,&HFF00\r', 'Illegal function call')
ok_run('DSKREAD: syntaxe', 'DSKREAD 1\r', 'Syntax error')
ok_run('DSKREAD pendant un fichier ouvert', 'OPEN "d" FOR OUTPUT AS #1\rDSKREAD 1,&HF400\r', 'File already open')
check('secteurs: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:4]))

# --- USB ON / USB OFF: le PC prend le disque (jamais les deux a la fois) ---------------------
b = BM(files={'P.BAS': b'10 PRINT 5\r\n'})
got = R('USB ON\rFILES\rLOAD "p"\rDSKREAD 0,&HF400\rUSB OFF\rFILES\r', bridge=b)
check('USB ON: FILES, LOAD et DSKREAD donnent Disk not Ready; USB OFF rend le disque',
      got == 'Disk not Ready\nDisk not Ready\nDisk not Ready\nP.BAS        12\n999988 bytes free' and not b.usb, repr(got))
ok_run('USB en minuscules', 'usb on\rusb off\r', '', bridge=BM())
ok_run('USB OFF sans USB ON', 'USB OFF\r', '', bridge=BM())
ok_run('USB sans argument', 'USB\r', 'Syntax error', bridge=BM())
ok_run('USB avec un mot inconnu', 'USB FOO\r', 'Syntax error', bridge=BM())
ok_run('pont sans USB de masse', 'USB ON\r', 'Device unavailable', bridge=BM(usb_ok=False))
ok_run('USB ON: pont muet', 'USB ON\r', 'Device Timeout', bridge=BM(mute=True))
ok_run('USB pendant un fichier de donnees ouvert', 'OPEN "d" FOR OUTPUT AS #1\rUSB ON\r', 'File already open')
got = R('USB ON\rOPEN "d" FOR OUTPUT AS #1\r')
check('USB ON: OPEN donne Disk not Ready', got == 'Disk not Ready', repr(got))
check('USB: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:4]))

# --- fleche haut: rappel de la derniere commande, puis edition (prompt seulement) ------------
UP, LT, RT, HM, DL, INS = '\x1b[A', '\x1b[D', '\x1b[C', '\x1b[H', '\x1b[3~', '\x1b[2~'


def last_out(got):
    return got.split('\n')[-1]


ok_run('fleche haut puis Entree: la derniere commande est re-executee', 'PRINT 1+1\r' + UP + '\r', ' 2 \nPRINT 1+1\x1b[K\n\x1b[9C\n 2 ')
got = R('PRINT "a"\r' + UP + ';"b"\r')
check('fleche haut: le curseur est a la fin (on peut completer la commande)', last_out(got) == 'ab' and '\x1b[9C;"b"' in got, repr(got))
got = R('PRINT 5\rPRINT 6\r' + UP + '\r')
check('fleche haut: c\'est la DERNIERE commande', last_out(got) == ' 6 ' and got.count(' 6 ') == 2, repr(got))
ok_run('fleche haut sans commande memorisee: sans effet', UP + '\rPRINT 7\r', ' 7 ')
got = R('PRINT 3\rPRINT 99' + UP + '\r')
check('fleche haut remplace la saisie en cours', last_out(got) == ' 3 ' and 'PRINT 3\x1b[K' in got, repr(got))
got = R('PRINT 4\r\x1bOA\r')
check('fleche haut en mode application (ESC O A)', last_out(got) == ' 4 ' and got.count(' 4 ') == 2, repr(got))
ok_run('fleche haut sans effet dans INPUT', 'PRINT 4\rINPUT A$\r' + UP + '\rPRINT 8\r', ' 4 \n? \n 8 ')
got = R('PRINT 1\r\r' + UP + '\r')
check('une ligne vide ne remplace pas la commande memorisee', last_out(got) == ' 1 ' and got.count(' 1 ') == 2, repr(got))
# edition de la commande rappelee: fleches gauche/droite, Debut, Insert, Suppr, retour arriere
got = R('PRINT 12\r' + UP + LT + LT + '3\r')
check('rappel + fleche gauche + insertion: PRINT 12 -> PRINT 312', last_out(got) == ' 312 ', repr(got))
got = R('PRINT 12\r' + UP + HM + RT * 6 + DL + '5\r')
check('rappel + Debut + droite + Suppr: PRINT 12 -> PRINT 52', last_out(got) == ' 52 ', repr(got))
got = R('PRINT 12\r' + UP + LT + INS + '9\r')
check('rappel + Inser (ecrasement) au milieu: PRINT 12 -> PRINT 19', last_out(got) == ' 19 ', repr(got))
got = R('PRINT 111\r' + UP + LT * 3 + INS + '23\r')
check('ecrasement de plusieurs caracteres: PRINT 111 -> PRINT 231', last_out(got) == ' 231 ', repr(got))
got = R('PRINT 12\r' + UP + LT + INS + INS + '9\r')
check('Inser deux fois: retour au mode insertion (PRINT 192)', last_out(got) == ' 192 ', repr(got))
got = R('PRINT 12\r' + UP + '\x7f\x7f' + '34\r')
check('rappel + retour arriere en fin de ligne: PRINT 12 -> PRINT 34', last_out(got) == ' 34 ', repr(got))
got = R('PRINT 5\r' + UP + '\x03' + 'PRINT 6\r')
check('rappel puis Ctrl-C: annule, la saisie suivante fonctionne', '^C' in got and last_out(got) == ' 6 ' and got.count(' 5 ') == 1, repr(got))
got = R('PRINT 1\r' + UP + LT + '2\r' + UP + '\r')
check('la ligne editee devient la commande memorisee (PRINT 21, deux fois)', got.count(' 21 ') == 2, repr(got))
check('fleche haut: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:4]))

# --- ? = PRINT: un espace est ajoute si un mot suit directement ------------------------------
got = R('?rnd\r')
check('?rnd -> PRINT RND (espace ajoute), la commande s\'execute', 'PRINT RND\x1b[K' in got and got.endswith(' .843267 '), repr(got))
got = R('10 ?rnd\rlist\r')
check('ligne numerotee: 10 ?rnd -> LIST montre 10 PRINT RND', got.endswith('10 PRINT RND'), repr(got))
got = R('?abs(-1)\r')
check('?abs(-1) -> PRINT ABS(-1)', 'PRINT ABS(-1)\x1b[K' in got and got.endswith(' 1 '), repr(got))
got = R('?a$\r')
check('?a$ -> PRINT A$ (inchange)', 'PRINT A$\x1b[K' in got, repr(got))
got = R('?"x"\r')
check('?"x" -> PRINT"x" (pas de mot: pas d\'espace)', 'PRINT"x"\x1b[K' in got and got.endswith('x'), repr(got))
got = R('? rnd\r')
check('? rnd (espace deja saisi): pas de deuxieme espace', 'PRINT RND\x1b[K' in got and 'PRINT  RND' not in got, repr(got))

# --- BOOT: amorcage du DOS (INT 19h) ---------------------------------------------------------
R('BOOT\r')
check('BOOT declenche INT 19h (amorcage: lib/bios.asm)', R.st.get('ints') == [0x19], repr(R.st.get('ints')))
R('OPEN "d" FOR OUTPUT AS #1\rPRINT #1,"x"\rBOOT\r')
check('BOOT ferme d\'abord le fichier de donnees (donnees ecrites, fichier ferme)',
      R.st.get('ints') == [0x19] and R.st['bridge'].cur is None and R.st['bridge'].files['D'] == bytearray(b'x\r\n'), repr(dict(R.st['bridge'].files)))

# --- EDIT: edition d'une ligne au terminal ------------------------------------------
L, RT, HOME, END_, DELK = '\x1b[D', '\x1b[C', '\x1b[H', '\x1b[F', '\x1b[3~'
got = R('10 print "abc"\redit 10\r' + L + L + 'X\r' + 'list\r')
check('EDIT: fleches + insertion au milieu', got.endswith('10 PRINT "abXc"') and 'Undefined' not in got, repr(got))
got = R('10 print "abc"\redit 10\r' + L + '\x7f\r' + 'list\r')
check('EDIT: retour arriere au milieu', got.endswith('10 PRINT "ab"'), repr(got))
got = R('10 print "abc"\redit 10\r' + HOME + '1' + '\r' + 'list\r')
check('EDIT: Debut + insertion (numero change: nouvelle ligne 110, l\'ancienne reste)',
      got.endswith('10 PRINT "abc"\n110 PRINT "abc"'), repr(got))
got = R('10 print "abc"\redit 10\r' + HOME + RT + DELK + '\r' + 'list\r')
check('EDIT: Suppr', got.endswith('10 PRINT "abc"\n1 PRINT "abc"') or got.endswith('1 PRINT "abc"\n10 PRINT "abc"'), repr(got))
got = R('10 print "abc"\redit 10\r' + '\x7f\x7f\x7f\x7f' + 'de"\r' + 'list\r')
check('EDIT: retour arriere en fin de ligne et saisie', got.endswith('10 PRINT "de"'), repr(got))
got = R('10 print "abc"\redit 10\r' + HOME + '\x0b' + '20 print 5\r' + 'list\r')
check('EDIT: Ctrl-K efface jusqu\'a la fin, Entree valide', got.endswith('10 PRINT "abc"\n20 PRINT 5'), repr(got))
got = R('10 print "abc"\redit 10\r' + L + 'ZZ\x03' + 'list\r')
check('EDIT: Ctrl-C annule sans modifier', got.endswith('10 PRINT "abc"') and 'ZZ"' not in got.split('\n')[-1], repr(got))
got = R('10 print "abc"\redit 10\r' + '\x1b[1;5D' + '\x1bOD' + 'Q\r' + 'list\r')
check('EDIT: sequences ANSI avec parametres/mode application', got.endswith('10 PRINT "aQbc"') or got.endswith('10 PRINT "abQc"'), repr(got))
got = R('10 print "x"\r20 ?a\redit 20\r' + END_ + '\r' + 'list\r')
check('EDIT: mots-cles en clair, PRINT A garde son espace apres re-saisie', got.endswith('10 PRINT "x"\n20 PRINT A'), repr(got))
got = R('30 goto100\r100 end\redit 30\r\rlist\r')
check('EDIT/LIST: GOTO100 -> GOTO 100', got.endswith('30 GOTO 100\n100 END'), repr(got))
got = R('10 print 1\r20 print 2\redit .\r' + HOME + '\x0b' + '20 print 9\r' + 'list\r')
check('EDIT .: derniere ligne entree', got.endswith('10 PRINT 1\n20 PRINT 9'), repr(got))
ok_run('EDIT: ligne inexistante', 'EDIT 99\r', 'Undefined line number')
ok_run('EDIT: en programme -> Illegal direct', '10 EDIT 10\rRUN\r', 'Illegal direct in 10')
ok_run('EDIT: sans numero', 'EDIT\r', 'Syntax error')
out, st, r = run('10 print 1\redit 10\r\x18', max_idle=3000)
check('EDIT: Ctrl-X quitte vers le menu', st['done'] and r.get('sp') == 0 and not st['bad'], str(r) + str(st['bad'][:3]))
check('EDIT: aucune ecriture hors zones', not R.st['bad'])
got = R('10 ?a\rlist\r')
check('LIST: ?A -> PRINT A', got.endswith('10 PRINT A'), repr(got))

# --- programme: liste, edition ---------------------------------------------------
got = R('30 print 3\r10 print 1\r20 print "A B"\rlist\r')
check('LIST trie les lignes', got == '10 PRINT 1\n20 PRINT "A B"\n30 PRINT 3', repr(got))
got = R('10 print 1\r20 print 2\r30 print 3\rlist 20\rlist 20-30\rlist -10\rlist 30-\r')
check('LIST n, n-m, -m, n-', got == '20 PRINT 2\n20 PRINT 2\n30 PRINT 3\n10 PRINT 1\n30 PRINT 3', repr(got))
got = R('10 for i=1 to 3:print i;:next i:if a>1 then goto 10 else print "x":rem fin\rLIST\r')
check('LIST: mots-cles en majuscules', got == '10 FOR I=1 TO 3:PRINT I;:NEXT I:IF A>1 THEN GOTO 10 ELSE PRINT "x":REM fin', repr(got))
got = R('10 print 1\r20 print 2\r20\rlist\r')
check('ligne supprimee (numero seul)', got == '10 PRINT 1', repr(got))
got = R('20\r')
check('supprimer une ligne inexistante', got == 'Undefined line number', repr(got))
got = R('10 print 1\r10 print 9\rlist\r')
check('ligne remplacee', got == '10 PRINT 9', repr(got))
got = R('10 PRINT 1\rNEW\rLIST\rPRINT FRE(0)>50000\r')
check('NEW efface le programme', got == '-1 ', repr(got))
got = R('10 A=5\r20 PRINT A\rRUN\r30 PRINT A+1\rPRINT A\r')
check('modifier le programme efface les variables', got == ' 5 \n 0 ', repr(got))
got = R('10 print 1\r20 print 2\r30 print 3\r40 print 4\rdelete 20-30\rlist\r')
check('DELETE n-m', got == '10 PRINT 1\n40 PRINT 4', repr(got))
got = R('10 PRINT "a"\r20 PRINT "b"\rRUN 20\r')
check('RUN n', got == 'b', repr(got))
got = R('10 A=1\r20 PRINT A\rRUN\rA=7\rGOTO 20\rCONT\r')
check('GOTO en direct conserve les variables', got == ' 1 \n 7 ' or got.startswith(' 1 \n 7 '), repr(got))
got = R('10 PRINT "A":STOP:PRINT "B"\rRUN\rCONT\r')
check('STOP puis CONT', got == 'A\nBreak in 10\nB', repr(got))
got = R('10 GOSUB 100:PRINT "fin":END\r100 PRINT "s":STOP:PRINT "t":RETURN\rRUN\rCONT\r')
check('CONT conserve la pile (GOSUB)', got == 's\nBreak in 100\nt\nfin', repr(got))
got = R('10 FOR I=1 TO 3\r20 PRINT I;:STOP\r30 NEXT\rRUN\rPRINT "d"\rCONT\rCONT\r')
check('CONT dans une boucle FOR (commande directe entre les deux)', got.startswith(' 1 \nBreak in 20\nd\n') and got.endswith(' 3 \nBreak in 20'), repr(got))
got = R('10 A=1\rRUN\r20 END\rCONT\r')
check('CONT invalide apres modification', got.endswith("Can't continue"), repr(got))
got = R('PRINX\x7fT 5\r')
check('DEL corrige la saisie', got.endswith(' 5 '), repr(got))
got = R('PRINX\x08T 6\r')
check('BS corrige la saisie', got.endswith(' 6 '), repr(got))
got = R('PRI\x1b[ANT\n 8\r')
check('sequence ANSI (fleche) ignoree dans la saisie', got == ' 8 ' or got.endswith(' 8 '), repr(got))
got = R('PRINT 12\x03PRINT 7\r')
check('Ctrl-C annule la ligne en cours', got.endswith(' 7 ') and ' 12 ' not in got, repr(got))

# --- Ctrl-C, RND, PEEK/POKE, E/S -------------------------------------------------
got = R('10 PRINT "A":GOTO 10\rRUN\r' + '\x03' + 'PRINT 1\r')
lines = got.split('\n')
check('Ctrl-C interrompt un programme (Break in 10) et rend la main',
      'Break in 10' in lines and lines[-1] == ' 1 ' and len(lines) > 5, repr(got[-60:]))
got = R('10 INPUT A\rRUN\r\x03PRINT 2\r')
check('Ctrl-C pendant INPUT -> Break in 10', 'Break in 10' in got and got.endswith(' 2 '), repr(got))
got = R('10 FOR I=1 TO 6:PRINT INT(RND*10);:NEXT\rRUN\r')
digits = re.findall(r'\d', got)
check('RND: 6 chiffres 0-9, variables', len(digits) == 6 and len(set(digits)) > 1, repr(got))
ok_run('RND(0) repete, RANDOMIZE n reproductible',
       'RANDOMIZE 5:A=RND:B=RND(0):RANDOMIZE 5:C=RND:PRINT A=B;A=C;A<1 AND A>=0\r', '-1 -1 -1 ')
ok_run('RND(-x) reinitialise', 'X=RND(-3):A=RND:X=RND(-3):B=RND:PRINT A=B\r', '-1 ')
ok_run('RND: deux appels differents', 'A=RND:B=RND:PRINT A<>B\r', '-1 ')
vals = [float(x) for x in R('FOR I=1 TO 40:PRINT RND;:NEXT\r').split()]
check('RND uniforme (40 valeurs dans [0,1[, moyenne ~0.5)', len(vals) == 40 and all(0 <= v < 1 for v in vals)
      and 0.3 < sum(vals) / 40 < 0.7, str(vals[:6]))
ok_run('PEEK/POKE (segment par defaut)', 'POKE 8192,77:PRINT PEEK(8192);PEEK(8193)\r', ' 77  0 ')
ok_run('POKE -1 (0FFh) et 255', 'POKE 8192,255:PRINT PEEK(8192):POKE 8192,-1:PRINT PEEK(8192)\r', ' 255 \n 255 ')
ok_run('POKE adresse 0..65535', 'POKE 40000,5:PRINT PEEK(40000);PEEK(-25536)\r', ' 5  5 ')
ok_run('PEEK: segment:decalage equivalents', 'DEF SEG=&H1000:POKE 9000,1:DEF SEG=&H1001:PRINT PEEK(8984)\r', ' 1 ')
ok_run('DEF SEG ecrit ailleurs', 'DEF SEG=&H1100:POKE 5,44:PRINT PEEK(5):DEF SEG:PRINT PEEK(5)\r', ' 44 \n 0 ')
ok_run('POKE protege l\'espace de travail', 'POKE 300,1\r', 'Illegal function call')
ok_run('POKE protege l\'etat du micrologiciel', 'POKE &HF800,1\r', 'Illegal function call')
ok_run('POKE protege la table des vecteurs', 'DEF SEG=0:POKE 4,1\r', 'Illegal function call')
ok_run('POKE valeur hors limite', 'POKE 8192,256\r', 'Illegal function call')
check('POKE: aucune ecriture hors zones', not R.st['bad'], str(R.st['bad'][:5]))
got = R('OUT &HE0,65:OUT &HE0,66\r')
check('OUT vers un port (port fictif E0h du banc = sortie UART)', got.startswith('AB'), repr(got))
got = R('CLS:LOCATE 3,5:COLOR 4:COLOR 12,1:BEEP:PRINT "x"\r')
seq = R.out
check('sequences ESC emises', all(t in seq for t in ('\x1b[2J\x1b[H', '\x1b[3;5H', '\x1b[31m', '\x1b[91m', '\x1b[44m', '\x07')), repr(seq))
ok_run('CALL: retour d\'un sous-programme en langage machine',
       'DEF SEG=&H1100:POKE 0,&HCB:PRINT "a";:CALL 0:PRINT "b"\r', 'ab')

# --- retour au menu -------------------------------------------------------------
for label, quit_txt in (('SYSTEM', 'SYSTEM\r'), ('BYE', 'BYE\r'), ('Ctrl-X', '\x18'), ('Ctrl-X en programme', '10 GOTO 10\rRUN\r\x18')):
    out, st, r = run(quit_txt, max_idle=3000)
    ok = (st['done'] and r.get('ax') == 0x1111 and r.get('bx') == 0x2222 and r.get('cx') == 0x3333
          and r.get('dx') == 0x4444 and r.get('si') == 0x5555 and r.get('di') == 0x6666
          and r.get('bp') == 0x7777)
    check("%s: retour a l'appelant, registres restaures" % label, ok, str(r) + ' ' + st['stopped'])
    check('%s: DS = CS (C000h), SP restaure' % label, r.get('ds') == 0xC000 and r.get('sp') == 0x0000, str(r))
    check('%s: aucune ecriture hors zones' % label, not st['bad'], str(st['bad'][:5]))

# --- memes scenarios avec les VRAIES routines uart_* -----------------------------
print('--- mode reel: vraies routines uart_* (arduino_send, tampon circulaire) ---')
PASTE = ('10 LET A=0\r20 LET B=1\r30 PRINT A\r100 PRINT B\r110 LET B=A+B\r120 LET A=B-A\r'
         '130 IF B<=10000 GOTO 100\r')
got = R(PASTE + 'list\r', real=True, paced=300, max_idle=400000)
lost = R.st['pace']['lost']
check('collage a debit fixe (1 octet / 300 instructions): aucun octet perdu, programme intact',
      lost == 0 and R.out.rstrip().endswith('list' + chr(10) + PASTE.replace(chr(13), chr(10)).rstrip() + chr(10) + 'Ok'),
      'perdus=%d %r' % (lost, R.out[-300:]))
got = R(PASTE + 'run\r', real=True, paced=300, max_idle=400000)
check('collage puis RUN: la suite de Fibonacci s affiche jusqu a 6765', got.endswith(' 6765 '), repr(got[-80:]))
got = R('PRINT 2+3*4\r', real=True)
check('reel: PRINT 2+3*4', got == ' 14 ', repr(got))
got = R('10 FOR I=1 TO 5\r20 PRINT I;\r30 NEXT I\rRUN\r', real=True)
check('reel: FOR/NEXT', got == ' 1  2  3  4  5 ', repr(got))
got = R('10 INPUT "V";A\r20 PRINT A*2\rRUN\r21\r', real=True)
check('reel: INPUT', got == 'V? 21\n 42 ' or got.endswith(' 42 '), repr(got))
got = R('A$="AB":PRINT A$+STR$(1.5)+LEFT$("xyz",2)\r', real=True)
check('reel: chaines', got == 'AB 1.5xy', repr(got))
got = R('10 PRINT "A":GOTO 10\rRUN\r' + '\x03' + 'PRINT 1\r', real=True)
check('reel: Ctrl-C interrompt, retour a Ok', 'Break in 10' in got and got.endswith(' 1 '), repr(got[-40:]))

print('\n%d verification(s), %d echec(s)' % (H.total, H.fails))
sys.exit(1 if H.fails else 0)
