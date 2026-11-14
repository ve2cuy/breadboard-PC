; clavier_us.inc - GENERE par tests/gen_clavier.py, ne pas modifier a la main.
; Codes de touche PS/2 (jeu 2) 00h-83h -> ASCII, disposition US. 0 = pas de caractere.
CLAVIER_NB_CODES equ 132
; sans Maj
clavier_normal:
        db      000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 009h, 060h, 000h   ; 00h
        db      000h, 000h, 000h, 000h, 000h, 071h, 031h, 000h, 000h, 000h, 07Ah, 073h, 061h, 077h, 032h, 000h   ; 10h
        db      000h, 063h, 078h, 064h, 065h, 034h, 033h, 000h, 000h, 020h, 076h, 066h, 074h, 072h, 035h, 000h   ; 20h
        db      000h, 06Eh, 062h, 068h, 067h, 079h, 036h, 000h, 000h, 000h, 06Dh, 06Ah, 075h, 037h, 038h, 000h   ; 30h
        db      000h, 02Ch, 06Bh, 069h, 06Fh, 030h, 039h, 000h, 000h, 02Eh, 02Fh, 06Ch, 03Bh, 070h, 02Dh, 000h   ; 40h
        db      000h, 000h, 027h, 000h, 05Bh, 03Dh, 000h, 000h, 000h, 000h, 00Dh, 05Dh, 000h, 05Ch, 000h, 000h   ; 50h
        db      000h, 000h, 000h, 000h, 000h, 000h, 008h, 000h, 000h, 031h, 000h, 034h, 037h, 000h, 000h, 000h   ; 60h
        db      030h, 02Eh, 032h, 035h, 036h, 038h, 01Bh, 000h, 000h, 02Bh, 033h, 02Dh, 02Ah, 039h, 000h, 000h   ; 70h
        db      000h, 000h, 000h, 000h   ; 80h
; avec Maj
clavier_maj:
        db      000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 009h, 07Eh, 000h   ; 00h
        db      000h, 000h, 000h, 000h, 000h, 051h, 021h, 000h, 000h, 000h, 05Ah, 053h, 041h, 057h, 040h, 000h   ; 10h
        db      000h, 043h, 058h, 044h, 045h, 024h, 023h, 000h, 000h, 020h, 056h, 046h, 054h, 052h, 025h, 000h   ; 20h
        db      000h, 04Eh, 042h, 048h, 047h, 059h, 05Eh, 000h, 000h, 000h, 04Dh, 04Ah, 055h, 026h, 02Ah, 000h   ; 30h
        db      000h, 03Ch, 04Bh, 049h, 04Fh, 029h, 028h, 000h, 000h, 03Eh, 03Fh, 04Ch, 03Ah, 050h, 05Fh, 000h   ; 40h
        db      000h, 000h, 022h, 000h, 07Bh, 02Bh, 000h, 000h, 000h, 000h, 00Dh, 07Dh, 000h, 07Ch, 000h, 000h   ; 50h
        db      000h, 000h, 000h, 000h, 000h, 000h, 008h, 000h, 000h, 031h, 000h, 034h, 037h, 000h, 000h, 000h   ; 60h
        db      030h, 02Eh, 032h, 035h, 036h, 038h, 01Bh, 000h, 000h, 02Bh, 033h, 02Dh, 02Ah, 039h, 000h, 000h   ; 70h
        db      000h, 000h, 000h, 000h   ; 80h
