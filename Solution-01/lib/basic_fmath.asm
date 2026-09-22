; ============================================================
; basic_fmath.asm
; Suite de lib/basic_float.asm (a inclure APRES): conversion decimale
; (fl_ftoa / fl_atof) et fonctions mathematiques (SQR, EXP, LOG, SIN, COS,
; TAN, ATN, puissance) sur les flottants simple precision emballes.
; Memes conventions que basic_float.asm (FAC/ARG en memoire, DS = segment de
; donnees, constantes en ROM lues par CS). Codes d'erreur retournes avec CF=1
; dans AL: ERR_FC (appel de fonction illegal), ERR_OV (depassement), ERR_DZ
; (division par zero) - constantes fournies par l'includeur.
; Variables (equ de l'includeur): fl_t0..fl_t9 (4 octets chacune), fl_x,
; fl_k (mots), fl_cnt, fl_inv (octets), fl_sgw (mot), fl_dig (8 octets),
; fl_dexp (mot), fl_fsg, fl_try (octets), fl_m (4 octets), fl_dx (mot),
; fl_nd, fl_dot, fl_any, fl_ng, fl_isf, fl_sgnok, fl_en (octets), fl_si0 (mot).
; ============================================================

%macro F_LDA 1                          ; ARG = [%1]
        mov     ax, [%1]
        mov     [arg_v], ax
        mov     ax, [%1+2]
        mov     [arg_v+2], ax
%endmacro
%macro F_LDF 1                          ; FAC = [%1]
        mov     ax, [%1]
        mov     [fac_v], ax
        mov     ax, [%1+2]
        mov     [fac_v+2], ax
%endmacro
%macro F_STF 1                          ; [%1] = FAC
        mov     ax, [fac_v]
        mov     [%1], ax
        mov     ax, [fac_v+2]
        mov     [%1+2], ax
%endmacro
%macro F_CA 1                           ; ARG = constante ROM (CS)
        mov     ax, [cs:%1]
        mov     [arg_v], ax
        mov     ax, [cs:%1+2]
        mov     [arg_v+2], ax
%endmacro
%macro F_CF 1                           ; FAC = constante ROM (CS)
        mov     ax, [cs:%1]
        mov     [fac_v], ax
        mov     ax, [cs:%1+2]
        mov     [fac_v+2], ax
%endmacro
%macro F_FA 0                           ; ARG = FAC
        mov     ax, [fac_v]
        mov     [arg_v], ax
        mov     ax, [fac_v+2]
        mov     [arg_v+2], ax
%endmacro

; ------------------------------------------------------------
; fl_mul64: fl_q64 = ua.M * ub.M (64 bits, mot bas d'abord)
; ------------------------------------------------------------
fl_mul64:
        mov     ax, [fl_ua+FU_M]        ; a0*b0
        mul     word [fl_ub+FU_M]
        mov     [fl_q64], ax
        mov     [fl_q64+2], dx
        mov     word [fl_q64+4], 0
        mov     word [fl_q64+6], 0
        mov     ax, [fl_ua+FU_M]        ; a0*b1
        mul     word [fl_ub+FU_M+2]
        add     [fl_q64+2], ax
        adc     [fl_q64+4], dx
        adc     word [fl_q64+6], 0
        mov     ax, [fl_ua+FU_M+2]      ; a1*b0
        mul     word [fl_ub+FU_M]
        add     [fl_q64+2], ax
        adc     [fl_q64+4], dx
        adc     word [fl_q64+6], 0
        mov     ax, [fl_ua+FU_M+2]      ; a1*b1
        mul     word [fl_ub+FU_M+2]
        add     [fl_q64+4], ax
        adc     [fl_q64+6], dx
        ret

; ------------------------------------------------------------
; fl_pow10_get: AX = k (-50..50) -> DX:AX = mantisse 32 bits, CX = exposant
; binaire (x = m/2^31 * 2^e) de 10^k, depuis la table en ROM. Detruit BX.
; ------------------------------------------------------------
fl_pow10_get:
        add     ax, 50
        mov     bx, 6
        mul     bx
        mov     bx, ax
        add     bx, fl_pow10
        mov     ax, [cs:bx]
        mov     dx, [cs:bx+2]
        mov     cx, [cs:bx+4]
        ret

; ------------------------------------------------------------
; fl_ftoa: FAC -> 7 chiffres significatifs ASCII dans fl_dig[0..6], exposant
; decimal fl_dexp (valeur = D.DDDDDD * 10^fl_dexp), signe fl_fsg (0/1). Le
; chiffre de tete est non nul (sauf pour 0: "0000000", exposant 0).
; ------------------------------------------------------------
fl_ftoa:
        mov     ax, [fac_v]
        mov     dx, [fac_v+2]
        mov     di, fl_ua
        call    fl_unpack
        mov     al, [fl_ua+FU_S]
        mov     [fl_fsg], al
        mov     ax, [fl_ua+FU_M]
        or      ax, [fl_ua+FU_M+2]
        jnz     .nz
        mov     word [fl_dexp], 0
        mov     byte [fl_fsg], 0
        mov     di, fl_dig
        mov     cx, 7
        mov     al, '0'
.z:
        mov     [di], al
        inc     di
        loop    .z
        ret
.nz:
        mov     ax, [fl_ua+FU_E]
        mov     bx, 19728               ; log10(2) * 65536
        imul    bx                      ; DX:AX = e * 19728
        mov     [fl_dexp], dx           ; estimation de floor(log10|x|)
        mov     byte [fl_try], 0
.retry:
        mov     ax, 6
        sub     ax, [fl_dexp]           ; k = 6 - d10
        call    fl_pow10_get
        mov     [fl_ub+FU_M], ax
        mov     [fl_ub+FU_M+2], dx
        mov     [fl_ub+FU_E], cx
        call    fl_mul64                ; P = m * pm
        mov     ax, [fl_ua+FU_E]
        add     ax, [fl_ub+FU_E]        ; t = e + pe
        mov     cx, 62
        sub     cx, ax                  ; s = 62 - t : N = P >> s
        js      .big
        cmp     cx, 63
        ja      .small
        jcxz    .havey
        dec     cx
        jz      .last
.shr:
        shr     word [fl_q64+6], 1
        rcr     word [fl_q64+4], 1
        rcr     word [fl_q64+2], 1
        rcr     word [fl_q64], 1
        loop    .shr
.last:
        shr     word [fl_q64+6], 1
        rcr     word [fl_q64+4], 1
        rcr     word [fl_q64+2], 1
        rcr     word [fl_q64], 1        ; CF = bit de garde
        adc     word [fl_q64], 0
        adc     word [fl_q64+2], 0
        adc     word [fl_q64+4], 0
        adc     word [fl_q64+6], 0
.havey:
        mov     ax, [fl_q64+4]
        or      ax, [fl_q64+6]
        jnz     .big
        mov     dx, [fl_q64+2]
        mov     ax, [fl_q64]
        ; N >= 10^7 (0x00989680) ?
        cmp     dx, 0098h
        ja      .big
        jb      .lo7
        cmp     ax, 9680h
        jae     .big
.lo7:
        ; N < 10^6 (0x000F4240) ?
        cmp     dx, 000Fh
        jb      .small
        ja      .ok
        cmp     ax, 4240h
        jb      .small
.ok:
        mov     bx, 10000
        div     bx                      ; AX = N / 10000 (0..999), DX = reste
        mov     [fl_tmp], ax
        mov     ax, dx
        mov     di, fl_dig + 7
        mov     cx, 4
        mov     bx, 10
.r4:
        xor     dx, dx
        div     bx
        add     dl, '0'
        dec     di
        mov     [di], dl
        loop    .r4
        mov     ax, [fl_tmp]
        mov     cx, 3
.q3:
        xor     dx, dx
        div     bx
        add     dl, '0'
        dec     di
        mov     [di], dl
        loop    .q3
        ret
.big:
        inc     word [fl_dexp]
        jmp     .again
.small:
        dec     word [fl_dexp]
.again:
        inc     byte [fl_try]
        cmp     byte [fl_try], 6
        jae     .give_up
        jmp     .retry
.give_up:
        mov     di, fl_dig
        mov     cx, 7
        mov     al, '0'
.gz:
        mov     [di], al
        inc     di
        loop    .gz
        ret

; ------------------------------------------------------------
; fl_atof: analyse un nombre decimal a DS:SI. Entree AL = 1 si un signe
; (+/-) et des espaces de tete sont acceptes (VAL), 0 sinon (litteraux).
; Sortie: CF=1, AH=0: aucun nombre (SI inchange); CF=1, AH=1: depassement;
;         CF=0: SI avance, AL=2 (entier 16 bits dans fac_v[0..1]) ou
;         AL=4 (flottant dans fac_v).
; Un nombre est entier s'il n'a ni '.', ni exposant et tient dans 16 bits.
; ------------------------------------------------------------
fl_atof:
        mov     [fl_sgnok], al
        mov     [fl_si0], si
        xor     ax, ax
        mov     [fl_m], ax
        mov     [fl_m+2], ax
        mov     [fl_dx], ax
        mov     [fl_nd], al
        mov     [fl_dot], al
        mov     [fl_any], al
        mov     [fl_ng], al
        mov     [fl_isf], al
        cmp     byte [fl_sgnok], 0
        je      .digits
.sp:
        mov     al, [si]
        cmp     al, ' '
        jne     .sg
        inc     si
        jmp     .sp
.sg:
        cmp     al, '-'
        jne     .plus
        mov     byte [fl_ng], 1
        inc     si
        jmp     .digits
.plus:
        cmp     al, '+'
        jne     .digits
        inc     si
.digits:
        mov     al, [si]
        cmp     al, '0'
        jb      .nd
        cmp     al, '9'
        ja      .nd
        inc     si
        mov     byte [fl_any], 1
        sub     al, '0'
        mov     dl, al                  ; DL = chiffre
        cmp     byte [fl_nd], 9
        jae     .drop                   ; deja 9 chiffres significatifs
        mov     ax, [fl_m]
        mov     cx, [fl_m+2]            ; CX:AX = M
        shl     ax, 1
        rcl     cx, 1                   ; M*2
        mov     [fl_t0], ax
        mov     [fl_t0+2], cx
        shl     ax, 1
        rcl     cx, 1
        shl     ax, 1
        rcl     cx, 1                   ; M*8
        add     ax, [fl_t0]
        adc     cx, [fl_t0+2]           ; M*10
        xor     dh, dh
        add     ax, dx
        adc     cx, 0                   ; + chiffre
        mov     [fl_m], ax
        mov     [fl_m+2], cx
        or      ax, cx
        jz      .after
        inc     byte [fl_nd]
.after:
        cmp     byte [fl_dot], 0
        je      .digits
        dec     word [fl_dx]
        jmp     .digits
.drop:
        cmp     byte [fl_dot], 0
        jne     .digits                 ; fraction au-dela de 9 chiffres: ignoree
        inc     word [fl_dx]
        jmp     .digits
.nd:
        cmp     al, '.'
        jne     .notdot
        cmp     byte [fl_dot], 0
        jne     .fin
        mov     byte [fl_dot], 1
        mov     byte [fl_isf], 1
        inc     si
        jmp     .digits
.notdot:
        or      al, 20h
        cmp     al, 'e'
        je      .exp
        cmp     al, 'd'
        jne     .fin
.exp:
        cmp     byte [fl_any], 0
        je      .fin
        mov     bx, si
        inc     bx
        mov     al, [bx]
        cmp     al, '+'
        je      .es
        cmp     al, '-'
        jne     .ed
.es:
        inc     bx
        mov     al, [bx]
.ed:
        cmp     al, '0'
        jb      .fin
        cmp     al, '9'
        ja      .fin
        inc     si                      ; consomme E/D
        mov     byte [fl_isf], 1
        mov     byte [fl_en], 0
        xor     cx, cx
        mov     al, [si]
        cmp     al, '-'
        jne     .ep
        mov     byte [fl_en], 1
        inc     si
        jmp     .eloop
.ep:
        cmp     al, '+'
        jne     .eloop
        inc     si
.eloop:
        mov     al, [si]
        cmp     al, '0'
        jb      .edone
        cmp     al, '9'
        ja      .edone
        inc     si
        sub     al, '0'
        mov     ah, 0
        mov     dx, ax
        mov     ax, cx
        mov     bx, 10
        push    dx
        mul     bx
        pop     dx
        add     ax, dx
        mov     cx, ax
        cmp     cx, 999
        jbe     .eloop
        mov     cx, 999
        jmp     .eloop
.edone:
        cmp     byte [fl_en], 0
        je      .eadd
        neg     cx
.eadd:
        add     [fl_dx], cx
.fin:
        cmp     byte [fl_any], 0
        jne     .have
        mov     si, [fl_si0]
        xor     ax, ax
        stc
        ret
.have:
        cmp     byte [fl_isf], 0
        jne     .float
        cmp     word [fl_dx], 0
        jne     .float
        mov     dx, [fl_m+2]
        mov     ax, [fl_m]
        or      dx, dx
        jnz     .float
        cmp     byte [fl_ng], 0
        je      .ipos
        cmp     ax, 8000h
        ja      .float
        neg     ax
        jmp     .iset
.ipos:
        cmp     ax, 7FFFh
        ja      .float
.iset:
        mov     [fac_v], ax
        mov     word [fac_v+2], 0
        mov     al, 2
        clc
        ret
.float:
        mov     dx, [fl_m+2]
        mov     ax, [fl_m]
        mov     bx, ax
        or      bx, dx
        jnz     .fnz
        xor     ax, ax                  ; valeur nulle
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        mov     al, 4
        clc
        ret
.fnz:
        mov     cx, 31
.fn:
        test    dx, 8000h
        jnz     .fgo
        shl     ax, 1
        rcl     dx, 1
        dec     cx
        jmp     .fn
.fgo:
        mov     [fl_ua+FU_M], ax
        mov     [fl_ua+FU_M+2], dx
        mov     [fl_ua+FU_E], cx
        mov     byte [fl_ua+FU_S], 0
        mov     ax, [fl_dx]
        cmp     ax, -50
        jl      .under
        cmp     ax, 50
        jg      .over
        or      ax, ax
        jz      .nomul
        call    fl_pow10_get            ; DX:AX = pm, CX = pe
        mov     [fl_ub+FU_M], ax
        mov     [fl_ub+FU_M+2], dx
        mov     [fl_ub+FU_E], cx
        mov     byte [fl_ub+FU_S], 0
        call    fl_mul_ab
        jc      .over
        jmp     .sgn
.nomul:
        mov     byte [fl_st], 0
        mov     di, fl_ua
        call    fl_store
        jc      .over
.sgn:
        cmp     byte [fl_ng], 0
        je      .fdone
        call    fl_neg
.fdone:
        mov     al, 4
        clc
        ret
.under:
        xor     ax, ax
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        jmp     .fdone
.over:
        mov     ah, 1
        stc
        ret

; ------------------------------------------------------------
; fl_madd: FAC = FAC * [fl_x] + constante ROM a CS:BX
; ------------------------------------------------------------
fl_madd:
        push    bx
        F_LDA   fl_x
        call    fl_mul
        F_FA
        pop     bx
        mov     ax, [cs:bx]
        mov     [fac_v], ax
        mov     ax, [cs:bx+2]
        mov     [fac_v+2], ax
        jmp     fl_add

; fl_dbl: FAC = FAC * 2 (exposant + 1) si non nul
fl_dbl:
        test    word [fac_v+2], 7F80h
        jz      .z
        add     word [fac_v+2], 0080h
.z:
        ret

; ------------------------------------------------------------
; fl_sqr: FAC = racine carree (Newton, 6 iterations). CF=1 si FAC < 0 (AL=ERR_FC).
; ------------------------------------------------------------
fl_sqr:
        mov     ax, [fac_v+2]
        test    ax, 8000h
        jnz     .fc
        test    ax, 7F80h
        jz      .zero
        F_STF   fl_t0                   ; x
        mov     cl, 7
        shr     ax, cl
        and     ax, 00FFh               ; exposant biaise
        sub     ax, 127
        sar     ax, 1                   ; floor(e / 2)
        add     ax, 127
        shl     ax, cl
        mov     [fac_v+2], ax           ; r0 = 2^floor(e/2)
        mov     word [fac_v], 0
        F_STF   fl_t1
        mov     byte [fl_cnt], 6
.it:
        F_LDA   fl_t0
        F_LDF   fl_t1
        call    fl_div                  ; x / r
        F_LDA   fl_t1
        call    fl_add                  ; r + x/r
        sub     word [fac_v+2], 0080h   ; / 2
        F_STF   fl_t1
        dec     byte [fl_cnt]
        jnz     .it
.zero:
        clc
        ret
.fc:
        mov     al, ERR_FC
        stc
        ret

; ------------------------------------------------------------
; fl_exp: FAC = e^FAC. CF=1 (AL=ERR_OV) si depassement; sous-depassement -> 0.
; ------------------------------------------------------------
fl_exp:
        F_STF   fl_t0                   ; x
        F_LDA   fl_t0
        F_CF    fc_expmax
        call    fl_cmp
        cmp     al, 1
        je      .ovf
        F_LDA   fl_t0
        F_CF    fc_expmin
        call    fl_cmp
        cmp     al, 0FFh
        je      .zero
        F_LDA   fl_t0
        F_CF    fc_log2e
        call    fl_mul                  ; y = x * log2(e)
        mov     ax, 1
        call    fl_to_i16               ; k = arrondi(y)
        mov     [fl_k], ax
        call    fl_from_i16
        F_STF   fl_t1                   ; kf
        F_LDA   fl_t1
        F_CF    fc_ln2_hi
        call    fl_mul
        F_LDA   fl_t0
        call    fl_sub                  ; x - kf*ln2hi
        F_STF   fl_t2
        F_LDA   fl_t1
        F_CF    fc_ln2_lo
        call    fl_mul
        F_LDA   fl_t2
        call    fl_sub                  ; r
        F_STF   fl_x
        F_CF    fc_inv5040
        mov     bx, fc_inv720
        call    fl_madd
        mov     bx, fc_inv120
        call    fl_madd
        mov     bx, fc_inv24
        call    fl_madd
        mov     bx, fc_inv6
        call    fl_madd
        mov     bx, fc_inv2
        call    fl_madd
        mov     bx, fc_one
        call    fl_madd
        mov     bx, fc_one
        call    fl_madd                 ; e^r
        mov     ax, [fac_v+2]
        mov     bx, ax
        mov     cl, 7
        and     bx, 7F80h
        shr     bx, cl
        add     bx, [fl_k]              ; * 2^k
        jle     .zero
        cmp     bx, 255
        jge     .ovf
        shl     bx, cl
        and     ax, 807Fh
        or      ax, bx
        mov     [fac_v+2], ax
        clc
        ret
.zero:
        xor     ax, ax
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        clc
        ret
.ovf:
        mov     al, ERR_OV
        stc
        ret

; ------------------------------------------------------------
; fl_log: FAC = ln(FAC). CF=1 (AL=ERR_FC) si FAC <= 0.
; ------------------------------------------------------------
fl_log:
        mov     ax, [fac_v+2]
        test    ax, 8000h
        jnz     .fc
        test    ax, 7F80h
        jz      .fc
        mov     cl, 7
        mov     bx, ax
        and     bx, 7F80h
        shr     bx, cl
        sub     bx, 127
        mov     [fl_k], bx              ; e
        and     ax, 007Fh
        or      ax, 3F80h
        mov     [fac_v+2], ax           ; m = 1.f dans [1,2)
        F_STF   fl_t1
        F_LDA   fl_t1
        F_CF    fc_sqrt2
        call    fl_cmp
        cmp     al, 1
        jne     .noadj
        sub     word [fl_t1+2], 0080h   ; m / 2
        inc     word [fl_k]
.noadj:
        F_LDA   fl_t1
        F_CF    fc_one
        call    fl_sub                  ; m - 1
        F_STF   fl_t2
        F_LDA   fl_t1
        F_CF    fc_one
        call    fl_add                  ; m + 1
        F_LDA   fl_t2
        call    fl_div                  ; s = (m-1)/(m+1)
        F_STF   fl_t2
        F_LDA   fl_t2
        F_LDF   fl_t2
        call    fl_mul                  ; t = s*s
        F_STF   fl_x
        F_CF    fc_inv9
        mov     bx, fc_inv7
        call    fl_madd
        mov     bx, fc_inv5
        call    fl_madd
        mov     bx, fc_inv3
        call    fl_madd
        mov     bx, fc_one
        call    fl_madd
        F_LDA   fl_t2
        call    fl_mul                  ; s * p
        call    fl_dbl                  ; ln m = 2 s p
        F_STF   fl_t3
        mov     ax, [fl_k]
        call    fl_from_i16
        F_STF   fl_t4                   ; e
        F_LDA   fl_t4
        F_CF    fc_ln2_hi
        call    fl_mul
        F_STF   fl_t5                   ; e * ln2hi
        F_LDA   fl_t4
        F_CF    fc_ln2_lo
        call    fl_mul                  ; e * ln2lo
        F_LDA   fl_t3
        call    fl_add
        F_LDA   fl_t5
        call    fl_add
        clc
        ret
.fc:
        mov     al, ERR_FC
        stc
        ret

; ------------------------------------------------------------
; fl_sin / fl_cos / fl_tan: FAC en radians. CF=1 (ERR_FC) si |x| > 2e5.
; ------------------------------------------------------------
; fl_reduce: FAC = x -> FAC = r = x - k*2pi dans [-pi, pi]. CF=1 (ERR_FC) si |x| > 2e5.
fl_reduce:
        F_STF   fl_t0                   ; x
        call    fl_abs
        F_FA
        F_CF    fc_2e5
        call    fl_cmp
        cmp     al, 1
        jne     .in
        mov     al, ERR_FC
        stc
        ret
.in:
        F_LDA   fl_t0
        F_CF    fc_inv2pi
        call    fl_mul
        mov     ax, 1
        call    fl_to_i16               ; k = arrondi(x / 2pi)
        call    fl_from_i16
        F_STF   fl_t1                   ; kf
        F_LDA   fl_t1
        F_CF    fc_2pi_hi
        call    fl_mul
        F_LDA   fl_t0
        call    fl_sub
        F_STF   fl_t2
        F_LDA   fl_t1
        F_CF    fc_2pi_lo
        call    fl_mul
        F_LDA   fl_t2
        call    fl_sub                  ; r
        clc
        ret

fl_sin:
        mov     ax, [fac_v+2]
        and     ax, 7F80h
        cmp     ax, 3980h               ; |x| < 2^-12: sin x = x (a la precision simple)
        jae     .go
        clc
        ret
.go:
        call    fl_reduce
        jnc     fl_sin_core
        ret
; fl_sin_core: FAC = r dans [-pi/2, 3pi/2]
fl_sin_core:
        F_STF   fl_t2
        F_LDA   fl_t2
        F_CF    fc_pi2
        call    fl_cmp
        cmp     al, 1
        jne     .chkneg
        F_LDF   fl_t2                   ; r > pi/2 : r = pi - r
        F_CA    fc_pi_hi
        call    fl_sub
        F_FA
        F_CF    fc_pi_lo
        call    fl_add
        F_STF   fl_t2
        jmp     .poly
.chkneg:
        F_CF    fc_pi2
        call    fl_neg                  ; -pi/2
        F_LDA   fl_t2
        call    fl_cmp
        cmp     al, 0FFh
        jne     .poly
        F_LDA   fl_t2                   ; r < -pi/2 : r = -((r + pi_hi) + pi_lo)
        F_CF    fc_pi_hi
        call    fl_add
        F_FA
        F_CF    fc_pi_lo
        call    fl_add
        call    fl_neg
        F_STF   fl_t2
.poly:
        F_LDA   fl_t2
        F_LDF   fl_t2
        call    fl_mul
        F_STF   fl_x                    ; t = r*r
        F_CF    fc_sin6
        mov     bx, fc_sin5
        call    fl_madd
        mov     bx, fc_sin4
        call    fl_madd
        mov     bx, fc_sin3
        call    fl_madd
        mov     bx, fc_sin2
        call    fl_madd
        mov     bx, fc_sin1
        call    fl_madd
        mov     bx, fc_sin0
        call    fl_madd
        F_LDA   fl_t2
        call    fl_mul                  ; * r
        clc
.ret:
        ret

; cos x = sin(r + pi/2) avec r = x reduit (precision conservee pour les grands x)
fl_cos:
        mov     ax, [fac_v+2]
        and     ax, 7F80h
        cmp     ax, 3980h               ; |x| < 2^-12: cos x = 1 (a la precision simple)
        jae     .go
        F_CF    fc_one
        clc
        ret
.go:
        call    fl_reduce
        jc      .ret
        F_FA
        F_CF    fc_pi2
        call    fl_add
        jmp     fl_sin_core
.ret:
        ret

fl_tan:
        F_STF   fl_t6
        call    fl_sin
        jc      .err
        F_STF   fl_t7                   ; sin
        F_LDF   fl_t6
        call    fl_cos
        jc      .err
        test    word [fac_v+2], 7F80h
        jz      .ovf                    ; cos = 0
        F_LDA   fl_t7
        call    fl_div
        ret
.ovf:
        mov     al, ERR_OV
        stc
.err:
        ret

; ------------------------------------------------------------
; fl_atn: FAC = arctangente (radians)
; ------------------------------------------------------------
fl_atn:
        mov     ax, [fac_v+2]
        and     ax, 8000h
        mov     [fl_sgw], ax
        call    fl_abs
        F_STF   fl_t4                   ; a = |x|
        mov     byte [fl_inv], 0
        F_LDA   fl_t4
        F_CF    fc_one
        call    fl_cmp
        cmp     al, 1
        jne     .le1
        mov     byte [fl_inv], 1
        F_CA    fc_one
        F_LDF   fl_t4
        call    fl_div                  ; 1/a
        F_STF   fl_t4
.le1:
        F_LDA   fl_t4
        F_LDF   fl_t4
        call    fl_mul                  ; a*a
        F_FA
        F_CF    fc_one
        call    fl_add                  ; 1 + a*a
        call    fl_sqr
        F_FA
        F_CF    fc_one
        call    fl_add                  ; 1 + sqrt(1 + a*a)
        F_LDA   fl_t4
        call    fl_div                  ; b = a / (1 + sqrt(1 + a*a))
        F_STF   fl_t5
        F_LDA   fl_t5
        F_LDF   fl_t5
        call    fl_mul
        F_STF   fl_x                    ; t = b*b
        F_CF    fc_atn5
        mov     bx, fc_atn4
        call    fl_madd
        mov     bx, fc_atn3
        call    fl_madd
        mov     bx, fc_atn2
        call    fl_madd
        mov     bx, fc_atn1
        call    fl_madd
        mov     bx, fc_atn0
        call    fl_madd
        F_LDA   fl_t5
        call    fl_mul
        call    fl_dbl                  ; 2 * atn(b)
        cmp     byte [fl_inv], 0
        je      .sgn
        F_CA    fc_pi2
        call    fl_sub                  ; pi/2 - resultat
.sgn:
        test    word [fac_v+2], 7F80h
        jz      .done
        mov     ax, [fl_sgw]
        or      [fac_v+2], ax
.done:
        clc
        ret

; ------------------------------------------------------------
; fl_pow: FAC = ARG ^ FAC. CF=1: AL = ERR_FC / ERR_OV / ERR_DZ.
; ------------------------------------------------------------
fl_pow:
        F_STF   fl_t8                   ; y
        mov     ax, [arg_v]
        mov     [fl_t9], ax
        mov     ax, [arg_v+2]
        mov     [fl_t9+2], ax           ; x
        test    word [fl_t8+2], 7F80h
        jnz     .ynz
        F_CF    fc_one                  ; x^0 = 1
        clc
        ret
.ynz:
        test    word [fl_t9+2], 7F80h
        jnz     .xnz
        test    word [fl_t8+2], 8000h
        jnz     .dz                     ; 0 ^ negatif
        xor     ax, ax
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        clc
        ret
.xnz:
        F_LDF   fl_t8
        call    fl_fix
        F_FA
        F_LDF   fl_t8
        call    fl_cmp
        or      al, al
        jne     .general                ; y non entier
        F_LDF   fl_t8
        call    fl_abs
        F_FA
        F_CF    fc_255
        call    fl_cmp
        cmp     al, 1
        je      .general                ; |y| > 255
        F_LDF   fl_t8
        call    fl_abs
        xor     ax, ax
        call    fl_to_i16
        mov     [fl_k], ax              ; n = |y|
        F_CF    fc_one
        F_STF   fl_t4                   ; r = 1
.sq:
        test    word [fl_k], 1
        jz      .noml
        F_LDA   fl_t4
        F_LDF   fl_t9
        call    fl_mul
        jc      .oflow
        F_STF   fl_t4
.noml:
        shr     word [fl_k], 1
        jz      .sqdone
        F_LDA   fl_t9
        F_LDF   fl_t9
        call    fl_mul
        jc      .oflow
        F_STF   fl_t9
        jmp     .sq
.sqdone:
        F_LDF   fl_t4
        test    word [fl_t8+2], 8000h
        jz      .okp
        F_CA    fc_one
        call    fl_div                  ; y < 0: 1 / r
        ret
.okp:
        clc
        ret
.oflow:
        test    word [fl_t8+2], 8000h
        jz      .ov
        xor     ax, ax                  ; y < 0: 1/inf = 0
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        clc
        ret
.ov:
        mov     al, ERR_OV
        stc
        ret
.dz:
        mov     al, ERR_DZ
        stc
        ret
.general:
        test    word [fl_t9+2], 8000h
        jnz     .fc                     ; base negative, exposant non entier
        F_LDF   fl_t9
        call    fl_log
        jc      .ret
        F_FA
        F_LDF   fl_t8
        call    fl_mul
        call    fl_exp
.ret:
        ret
.fc:
        mov     al, ERR_FC
        stc
        ret

; ------------------------------------------------------------
; Tables en ROM (lues par CS)
; ------------------------------------------------------------
; fl_pow10: 10^k, k = -50..50; 6 octets par entree (mantisse 32 bits
; normalisee, exposant binaire: valeur = m/2^31 * 2^e)
fl_pow10:
        dd 0xEF73D257
        dw -167              ; 10^-50
        dd 0x95A86376
        dw -163              ; 10^-49
        dd 0xBB127C54
        dw -160              ; 10^-48
        dd 0xE9D71B69
        dw -157              ; 10^-47
        dd 0x92267121
        dw -153              ; 10^-46
        dd 0xB6B00D6A
        dw -150              ; 10^-45
        dd 0xE45C10C4
        dw -147              ; 10^-44
        dd 0x8EB98A7B
        dw -143              ; 10^-43
        dd 0xB267ED19
        dw -140              ; 10^-42
        dd 0xDF01E860
        dw -137              ; 10^-41
        dd 0x8B61313C
        dw -133              ; 10^-40
        dd 0xAE397D8B
        dw -130              ; 10^-39
        dd 0xD9C7DCED
        dw -127              ; 10^-38
        dd 0x881CEA14
        dw -123              ; 10^-37
        dd 0xAA242499
        dw -120              ; 10^-36
        dd 0xD4AD2DC0
        dw -117              ; 10^-35
        dd 0x84EC3C98
        dw -113              ; 10^-34
        dd 0xA6274BBE
        dw -110              ; 10^-33
        dd 0xCFB11EAD
        dw -107              ; 10^-32
        dd 0x81CEB32C
        dw -103              ; 10^-31
        dd 0xA2425FF7
        dw -100              ; 10^-30
        dd 0xCAD2F7F5
        dw -97              ; 10^-29
        dd 0xFD87B5F3
        dw -94              ; 10^-28
        dd 0x9E74D1B8
        dw -90              ; 10^-27
        dd 0xC6120625
        dw -87              ; 10^-26
        dd 0xF79687AF
        dw -84              ; 10^-25
        dd 0x9ABE14CD
        dw -80              ; 10^-24
        dd 0xC16D9A01
        dw -77              ; 10^-23
        dd 0xF1C90081
        dw -74              ; 10^-22
        dd 0x971DA050
        dw -70              ; 10^-21
        dd 0xBCE50865
        dw -67              ; 10^-20
        dd 0xEC1E4A7E
        dw -64              ; 10^-19
        dd 0x9392EE8F
        dw -60              ; 10^-18
        dd 0xB877AA32
        dw -57              ; 10^-17
        dd 0xE69594BF
        dw -54              ; 10^-16
        dd 0x901D7CF7
        dw -50              ; 10^-15
        dd 0xB424DC35
        dw -47              ; 10^-14
        dd 0xE12E1342
        dw -44              ; 10^-13
        dd 0x8CBCCC09
        dw -40              ; 10^-12
        dd 0xAFEBFF0C
        dw -37              ; 10^-11
        dd 0xDBE6FECF
        dw -34              ; 10^-10
        dd 0x89705F41
        dw -30              ; 10^-9
        dd 0xABCC7712
        dw -27              ; 10^-8
        dd 0xD6BF94D6
        dw -24              ; 10^-7
        dd 0x8637BD06
        dw -20              ; 10^-6
        dd 0xA7C5AC47
        dw -17              ; 10^-5
        dd 0xD1B71759
        dw -14              ; 10^-4
        dd 0x83126E98
        dw -10              ; 10^-3
        dd 0xA3D70A3D
        dw -7              ; 10^-2
        dd 0xCCCCCCCD
        dw -4              ; 10^-1
        dd 0x80000000
        dw 0              ; 10^0
        dd 0xA0000000
        dw 3              ; 10^1
        dd 0xC8000000
        dw 6              ; 10^2
        dd 0xFA000000
        dw 9              ; 10^3
        dd 0x9C400000
        dw 13              ; 10^4
        dd 0xC3500000
        dw 16              ; 10^5
        dd 0xF4240000
        dw 19              ; 10^6
        dd 0x98968000
        dw 23              ; 10^7
        dd 0xBEBC2000
        dw 26              ; 10^8
        dd 0xEE6B2800
        dw 29              ; 10^9
        dd 0x9502F900
        dw 33              ; 10^10
        dd 0xBA43B740
        dw 36              ; 10^11
        dd 0xE8D4A510
        dw 39              ; 10^12
        dd 0x9184E72A
        dw 43              ; 10^13
        dd 0xB5E620F4
        dw 46              ; 10^14
        dd 0xE35FA932
        dw 49              ; 10^15
        dd 0x8E1BC9BF
        dw 53              ; 10^16
        dd 0xB1A2BC2F
        dw 56              ; 10^17
        dd 0xDE0B6B3A
        dw 59              ; 10^18
        dd 0x8AC72305
        dw 63              ; 10^19
        dd 0xAD78EBC6
        dw 66              ; 10^20
        dd 0xD8D726B7
        dw 69              ; 10^21
        dd 0x87867832
        dw 73              ; 10^22
        dd 0xA968163F
        dw 76              ; 10^23
        dd 0xD3C21BCF
        dw 79              ; 10^24
        dd 0x84595161
        dw 83              ; 10^25
        dd 0xA56FA5BA
        dw 86              ; 10^26
        dd 0xCECB8F28
        dw 89              ; 10^27
        dd 0x813F3979
        dw 93              ; 10^28
        dd 0xA18F07D7
        dw 96              ; 10^29
        dd 0xC9F2C9CD
        dw 99              ; 10^30
        dd 0xFC6F7C40
        dw 102              ; 10^31
        dd 0x9DC5ADA8
        dw 106              ; 10^32
        dd 0xC5371912
        dw 109              ; 10^33
        dd 0xF684DF57
        dw 112              ; 10^34
        dd 0x9A130B96
        dw 116              ; 10^35
        dd 0xC097CE7C
        dw 119              ; 10^36
        dd 0xF0BDC21B
        dw 122              ; 10^37
        dd 0x96769951
        dw 126              ; 10^38
        dd 0xBC143FA5
        dw 129              ; 10^39
        dd 0xEB194F8E
        dw 132              ; 10^40
        dd 0x92EFD1B9
        dw 136              ; 10^41
        dd 0xB7ABC627
        dw 139              ; 10^42
        dd 0xE596B7B1
        dw 142              ; 10^43
        dd 0x8F7E32CE
        dw 146              ; 10^44
        dd 0xB35DBF82
        dw 149              ; 10^45
        dd 0xE0352F63
        dw 152              ; 10^46
        dd 0x8C213D9E
        dw 156              ; 10^47
        dd 0xAF298D05
        dw 159              ; 10^48
        dd 0xDAF3F046
        dw 162              ; 10^49
        dd 0x88D8762C
        dw 166              ; 10^50

; constantes flottantes (float32)
fc_one:  dd 0x3F800000                ; 1.0
fc_half:  dd 0x3F000000                ; 0.5
fc_two:  dd 0x40000000                ; 2.0
fc_ten:  dd 0x41200000                ; 10.0
fc_log2e:  dd 0x3FB8AA3B                ; 1.4426950408889634
fc_ln2_hi:  dd 0x3F317200                ; 0.693145751953125
fc_ln2_lo:  dd 0x35BFBE8E                ; 1.4286068202862268e-06
fc_expmax:  dd 0x42B17213                ; 88.7228
fc_expmin:  dd 0xC2AEAC4A                ; -87.3365
fc_inv2:  dd 0x3F000000                ; 0.5
fc_inv6:  dd 0x3E2AAAAB                ; 0.16666666666666666
fc_inv24:  dd 0x3D2AAAAB                ; 0.041666666666666664
fc_inv120:  dd 0x3C088889                ; 0.008333333333333333
fc_inv720:  dd 0x3AB60B61                ; 0.001388888888888889
fc_inv5040:  dd 0x39500D01                ; 0.0001984126984126984
fc_inv3:  dd 0x3EAAAAAB                ; 0.3333333333333333
fc_inv5:  dd 0x3E4CCCCD                ; 0.2
fc_inv7:  dd 0x3E124925                ; 0.14285714285714285
fc_inv9:  dd 0x3DE38E39                ; 0.1111111111111111
fc_inv2pi:  dd 0x3E22F983                ; 0.15915494309189535
fc_2pi_hi:  dd 0x40C90000                ; 6.28125
fc_2pi_lo:  dd 0x3AFDAA22                ; 0.001935307179586232
fc_pi_hi:  dd 0x40490000                ; 3.140625
fc_pi_lo:  dd 0x3A7DAA22                ; 0.000967653589793116
fc_pi2:  dd 0x3FC90FDB                ; 1.5707963267948966
fc_pi:  dd 0x40490FDB                ; 3.141592653589793
fc_2e5:  dd 0x48483200                ; 205000.0
fc_sqrt2:  dd 0x3FB504F3                ; 1.4142135623730951
fc_2p24:  dd 0x4B800000                ; 16777216.0
fc_rndm:  dd 0x33800000                ; 5.960464477539063e-08
fc_255:  dd 0x437F0000                ; 255.0
fc_sin0:  dd 0x3F800000                ; 1.0
fc_sin1:  dd 0xBE2AAAAB                ; -0.1666666716337204
fc_sin2:  dd 0x3C088889                ; 0.008333333767950535
fc_sin3:  dd 0xB9500CFD                ; -0.00019841264293063432
fc_sin4:  dd 0x3638EE4B                ; 2.7556841359910322e-06
fc_sin5:  dd 0xB2D6FA24                ; -2.5026629657531885e-08
fc_sin6:  dd 0x2F28F354                ; 1.5365958505597632e-10
fc_atn0:  dd 0x3F800000                ; 1.0
fc_atn1:  dd 0xBEAAAA93                ; -0.3333326280117035
fc_atn2:  dd 0x3E4CC411                ; 0.1999666839838028
fc_atn3:  dd 0xBE119A30                ; -0.14218974113464355
fc_atn4:  dd 0x3DD5F874                ; 0.10447779297828674
fc_atn5:  dd 0xBD6C0C81                ; -0.05762911215424538
