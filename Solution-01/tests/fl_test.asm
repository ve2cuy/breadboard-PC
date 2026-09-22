; banc d'essai de lib/basic_float.asm (voir tests/fl_test.py) - segments plats (DS=ES=SS=0)
BITS    16
CPU     8086
ORG     1000h

arg_v   equ     0100h
fac_v   equ     0104h
fl_ua   equ     0110h
fl_ub   equ     0118h
fl_q64  equ     0120h
fl_r64  equ     0128h
fl_st   equ     0130h
fl_dz   equ     0131h
fl_dq   equ     0132h
fl_sgn  equ     0133h
fl_fl   equ     0134h
fl_tmp  equ     0136h

ERR_FC  equ     5
ERR_OV  equ     6
ERR_DZ  equ     11
fl_t0   equ     0140h
fl_t1   equ     0144h
fl_t2   equ     0148h
fl_t3   equ     014Ch
fl_t4   equ     0150h
fl_t5   equ     0154h
fl_t6   equ     0158h
fl_t7   equ     015Ch
fl_t8   equ     0160h
fl_t9   equ     0164h
fl_x    equ     0168h
fl_k    equ     016Ch
fl_cnt  equ     016Eh
fl_inv  equ     016Fh
fl_sgw  equ     0170h
fl_dig  equ     0178h
fl_dexp equ     0180h
fl_fsg  equ     0182h
fl_try  equ     0183h
fl_m    equ     0184h
fl_dx   equ     0188h
fl_nd   equ     018Ah
fl_dot  equ     018Bh
fl_any  equ     018Ch
fl_ng   equ     018Dh
fl_isf  equ     018Eh
fl_sgnok equ    018Fh
fl_en   equ     0190h
fl_si0  equ     0192h

%include "lib/basic_float.asm"
%include "lib/basic_fmath.asm"
