10 REM *** ASCII SINE WAVE PLOT IN GW-BASIC ***
20 CLS
30 PRINT "ASCII Plot of SIN(x) from 0 to 2*PI"
40 PRINT "-----------------------------------"
50 REM Set parameters
60 PI = 3.14159265
70 AMPL = 20          ' Horizontal scaling for ASCII plot
80 HEIGHT = 10        ' Vertical scaling (number of rows above/below center)
90 REM Loop over X values
100 FOR X = 0 TO 2*PI STEP 0.1
110   Y = SIN(X)      ' Compute sine value
120   P = INT(AMPL * Y + AMPL)  ' Shift sine to positive column index
130   REM Build line: center at AMPL, mark sine position
140   L$ = ""
150   FOR C = 0 TO AMPL*2
160     IF C = AMPL THEN L$ = L$ + "|"
170     IF C = P THEN L$ = L$ + "*"
180     IF C <> AMPL AND C <> P THEN L$ = L$ + " "
190   NEXT C
200   PRINT L$
210 NEXT X
220 PRINT "-----------------------------------"
230 PRINT "Done."
