; ============================================================
; basic_data.asm - tables en ROM du BASIC (lib/basic.asm): mots-cles,
; gestionnaires, messages (lus par CS)
; ============================================================
kw_table:
%assign KW_MODE 0
%include "lib/basic_tokens.inc"
        db      0

tok_handlers:
%assign KW_MODE 1
%include "lib/basic_tokens.inc"

; kw_ptr: adresse du texte (dans kw_table) de chaque mot-cle, par numero de jeton - 80h
kw_ptr:
%assign KW_MODE 4
%include "lib/basic_tokens.inc"

; kw_idx: pour chaque lettre A-Z, adresse de son seau (numeros de jeton, fin 0FFh)
%macro KWB 1
kwb_%1:
%defstr KW_LETTER %1
%assign KW_MODE 3
%include "lib/basic_tokens.inc"
        db      0FFh
%endmacro
        KWB A
        KWB B
        KWB C
        KWB D
        KWB E
        KWB F
        KWB G
        KWB H
        KWB I
        KWB J
        KWB K
        KWB L
        KWB M
        KWB N
        KWB O
        KWB P
        KWB Q
        KWB R
        KWB S
        KWB T
        KWB U
        KWB V
        KWB W
        KWB X
        KWB Y
        KWB Z
kw_idx:
        dw      kwb_A, kwb_B, kwb_C, kwb_D, kwb_E, kwb_F, kwb_G, kwb_H, kwb_I
        dw      kwb_J, kwb_K, kwb_L, kwb_M, kwb_N, kwb_O, kwb_P, kwb_Q, kwb_R
        dw      kwb_S, kwb_T, kwb_U, kwb_V, kwb_W, kwb_X, kwb_Y, kwb_Z

ansi_colors:                            ; couleur GW-BASIC (0-7) -> couleur ANSI
        db      0, 4, 2, 6, 1, 5, 3, 7

msg_banner:
        db      13, 10, 'VE2CUY 86 BASIC Version 1.0 (inspired by GW-BASIC)', 13, 10
        db      'HELP: help, Ctrl-C: Break, Ctrl-X: menu, USB ON/OFF', 13, 10
        db      'Edit last command: UP arrow', 13, 10, 0
msg_help:
        db      13, 10, '--- VE2CUY 86 BASIC, V1.0: command summary (HELP) ---', 13, 10
        db      'Program   : LIST [n[-m]]  RUN [n]  NEW  CONT  DELETE n-m  CLEAR', 13, 10
        db      '            TRON  TROFF  EDIT n|.  SYSTEM/BYE  Ctrl-C  Ctrl-X  Up: last cmd', 13, 10
        db      'Flow      : IF..THEN..ELSE  GOTO  GOSUB/RETURN  ON n GOTO|GOSUB', 13, 10
        db      '            FOR..TO..STEP/NEXT  WHILE/WEND  END  STOP  REM  ', 27h, 13, 10
        db      'Data      : LET  DIM  ERASE  SWAP  DATA/READ/RESTORE  DEF FNx(..)=..', 13, 10
        db      '            DEFINT/DEFSNG/DEFSTR  MID$(v$,i,n)=s$', 13, 10
        db      'Screen    : PRINT (; , TAB( SPC()  INPUT  LINE INPUT  CLS  LOCATE r,c', 13, 10
        db      '            COLOR f,b  BEEP', 13, 10
        db      'Machine   : PEEK  POKE  DEF SEG  INP  OUT  WAIT  CALL  RANDOMIZE', 13, 10
        db      'Operators : ^ * / \ MOD + - = <> < > <= >= NOT AND OR XOR EQV IMP', 13, 10
        db      'Math      : ABS SGN INT FIX CINT CSNG SQR SIN COS TAN ATN LOG EXP RND', 13, 10
        db      'Memory    : PRINT FRE(0) = free bytes (FRE("") after cleanup)', 13, 10
        db      '            POS(0) = cursor column', 13, 10
        db      'Disk      : SAVE "f"  LOAD "f"  MERGE "f"  RUN "f"  FILES  KILL "f"  FORMAT "YES"', 13, 10
        db      '            DSKREAD lba,addr  DSKWRITE lba,addr  (512-byte sectors at DEF SEG)', 13, 10
        db      '            USB ON (the PC gets the disk as a USB drive)  USB OFF (back to the 8088)', 13, 10
        db      '            DSKREAD/DSKWRITE lba,addr = raw sectors   BOOT = start DOS from the flash', 13, 10
        db      'Files     : OPEN "f" FOR INPUT|OUTPUT|APPEND AS #1  CLOSE  EOF(1)', 13, 10
        db      '            PRINT #1,..  WRITE #1,..  INPUT #1,v  LINE INPUT #1,a$', 13, 10
        db      'Clock     : TIMER  TIME$  DATE$  (TIME$="h:m:s"  DATE$="m-d-y")', 13, 10
        db      'Text      : LEN ASC VAL INSTR CHR$ STR$ HEX$ OCT$ LEFT$ RIGHT$ MID$', 13, 10
        db      '            STRING$ SPACE$ UCASE$ LCASE$ INKEY$ INPUT$', 13, 10
        db      'Types     : I% integer   X! real (7 digits)   A$ string (255 max)', 13, 10, 0
msg_ok:
        db      'Ok', 13, 10, 0
msg_in:
        db      ' in ', 0
msg_redo:
        db      '?Redo from start', 13, 10, 0

; messages d'erreur (numerotation GW-BASIC): entrees [numero][texte][0], fin 0FFh;
; un numero absent de la table donne msg_unk
msg_unk:
        db      'Unprintable error', 0
msg_err:
        db      1, 'NEXT without FOR', 0
        db      2, 'Syntax error', 0
        db      3, 'RETURN without GOSUB', 0
        db      4, 'Out of DATA', 0
        db      5, 'Illegal function call', 0
        db      6, 'Overflow', 0
        db      7, 'Out of memory', 0
        db      8, 'Undefined line number', 0
        db      9, 'Subscript out of range', 0
        db      10, 'Duplicate Definition', 0
        db      11, 'Division by zero', 0
        db      12, 'Illegal direct', 0
        db      13, 'Type mismatch', 0
        db      14, 'Out of string space', 0
        db      15, 'String too long', 0
        db      16, 'String formula too complex', 0
        db      17, "Can't continue", 0
        db      18, 'Undefined user function', 0
        db      23, 'Line buffer overflow', 0
        db      24, 'Device Timeout', 0
        db      26, 'FOR without NEXT', 0
        db      29, 'WHILE without WEND', 0
        db      30, 'WEND without WHILE', 0
        db      31, 'Break', 0
        db      52, 'Bad file number', 0
        db      53, 'File not found', 0
        db      54, 'Bad file mode', 0
        db      55, 'File already open', 0
        db      57, 'Disk I/O error', 0
        db      58, 'File already exists', 0
        db      61, 'Disk full', 0
        db      62, 'Input past end', 0
        db      64, 'Bad file name', 0
        db      66, 'Direct statement in file', 0
        db      68, 'Device unavailable', 0
        db      71, 'Disk not Ready', 0
        db      0FFh
msg_dsk_free:
        db      ' bytes free', 13, 10, 0
