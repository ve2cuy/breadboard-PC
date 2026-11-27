; ============================================================
; basic_float.asm
; Arithmetique en virgule flottante LOGICIELLE simple precision (IEEE-754
; binary32, arrondi au plus proche pair, sans denormalises/NaN/infinis:
; sous-depassement -> 0, depassement -> CF=1) pour l'interpreteur BASIC
; (lib/basic.asm). Ecrit pour un 8086 strict (CPU 8086): pas de decalage
; immediat > 1, pas de PUSHA.
;
; CONVENTIONS
;   - Un flottant EMBALLE = 4 octets little-endian (mot bas d'abord): bit 31 =
;     signe, bits 30-23 = exposant biaise (127), bits 22-0 = fraction (bit
;     cache a 1). Zero = exposant 0 (toujours +0 en sortie).
;   - Registres FAC et ARG (memoire): fac_v / arg_v (4 octets). Operations
;     binaires: FAC = ARG op FAC (l'operande gauche est dans ARG - ordre utile
;     pour la soustraction et la division).
;   - Structure DEBALLEE (8 octets, en memoire) utilisee en interne:
;       +0 signe (0/1)  +2 exposant (mot signe, x = m/2^31 * 2^e)
;       +4 mantisse 32 bits (bit 31 = 1, sauf zero: 0)
;   - Detruisent AX, BX, CX, DX, DI. PRESERVENT SI et BP (SI = pointeur de
;     texte de l'interpreteur, BP = ancre de pile).
;   - Les adresses fac_v/arg_v/fl_* (equ) sont definies par l'includeur
;     (lib/basic.asm ou le banc d'essai tests/fl_test.asm).
; ============================================================

FU_S    equ     0                       ; signe
FU_E    equ     2                       ; exposant (non biaise)
FU_M    equ     4                       ; mantisse 32 bits

; ------------------------------------------------------------
; fl_unpack: DX:AX (emballe) -> structure a [DI]. Detruit AX,BX,CX,DX.
; ------------------------------------------------------------
fl_unpack:
        mov     byte [di+FU_S], 0
        test    dx, 8000h
        jz      .pos
        mov     byte [di+FU_S], 1
.pos:
        mov     bx, dx
        mov     cl, 7
        shr     bx, cl
        and     bx, 00FFh               ; BX = exposant biaise
        jz      .zero
        sub     bx, 127
        mov     [di+FU_E], bx
        and     dx, 007Fh
        or      dl, 80h                 ; DL = bits 23..16 avec bit cache
        mov     dh, dl
        mov     dl, ah
        mov     ah, al
        xor     al, al                  ; DX:AX = mantisse 24 bits << 8
        mov     [di+FU_M], ax
        mov     [di+FU_M+2], dx
        ret
.zero:
        xor     ax, ax
        mov     [di+FU_E], ax
        mov     [di+FU_M], ax
        mov     [di+FU_M+2], ax
        ret

; ------------------------------------------------------------
; fl_pack: structure [DI] (mantisse normalisee bit31=1, ou 0) + octet
; fl_st (bits perdus non nuls = 1) -> DX:AX emballe, arrondi au plus proche
; pair. CF=1 si depassement (AX:DX = plus grand flottant signe).
; Sous-depassement -> +0, CF=0. Detruit BX,CX.
; ------------------------------------------------------------
fl_pack:
        mov     ax, [di+FU_M]
        mov     dx, [di+FU_M+2]
        mov     bx, ax
        or      bx, dx
        jz      .zero
        ; arrondi: 8 bits bas = bits d'arrondi (bit7 = garde)
        mov     cl, al
        and     cl, 7Fh
        or      cl, [fl_st]             ; reste non nul ?
        mov     bl, al
        xor     al, al                  ; tronque les 8 bits bas
        test    bl, 80h
        jz      .noround                ; bit de garde nul: pas d'arrondi
        or      cl, cl
        jnz     .up                     ; reste non nul: arrondit vers le haut
        test    ah, 1                   ; egalite: pair ? (lsb = bit 8)
        jz      .noround
.up:
        add     ax, 0100h
        adc     dx, 0
        jnc     .noround
        mov     dx, 8000h               ; mantisse devenue 2^32 -> 1,0 * 2
        xor     ax, ax
        inc     word [di+FU_E]
.noround:
        mov     bx, [di+FU_E]
        add     bx, 127                 ; exposant biaise
        jle     .zero                   ; <= 0: sous-depassement -> 0
        cmp     bx, 255
        jge     .ovf
        ; assemblage: bits 22-16 = DH & 7F, bits 15-8 = DL, bits 7-0 = AH
        mov     al, ah
        mov     ah, dl                  ; AX = bits 15..0 de l'emballe
        mov     dl, dh
        and     dl, 7Fh                 ; DL = bits 22..16
        mov     cl, 7
        shl     bx, cl                  ; exposant en bits 14..7
        xor     dh, dh
        or      dx, bx
        cmp     byte [di+FU_S], 0
        je      .out
        or      dx, 8000h
.out:
        clc
        ret
.zero:
        xor     ax, ax
        xor     dx, dx
        clc
        ret
.ovf:
        mov     ax, 0FFFFh
        mov     dx, 7F7Fh
        cmp     byte [di+FU_S], 0
        je      .ovfp
        or      dx, 8000h
.ovfp:
        stc
        ret

; ------------------------------------------------------------
; fl_load_a / fl_load_b: ARG -> ua, FAC -> ub (deballes)
; ------------------------------------------------------------
fl_load_a:
        mov     ax, [arg_v]
        mov     dx, [arg_v+2]
        mov     di, fl_ua
        jmp     fl_unpack
fl_load_b:
        mov     ax, [fac_v]
        mov     dx, [fac_v+2]
        mov     di, fl_ub
        jmp     fl_unpack

; fl_store: pack [DI] (fl_st deja positionne) -> FAC. CF=1 si depassement.
fl_store:
        call    fl_pack
        mov     [fac_v], ax
        mov     [fac_v+2], dx
        ret

; ------------------------------------------------------------
; fl_neg / fl_abs: FAC
; ------------------------------------------------------------
fl_neg:
        mov     ax, [fac_v+2]
        test    ax, 7F80h
        jz      .z                      ; zero: reste +0
        xor     ax, 8000h
        mov     [fac_v+2], ax
.z:
        ret
fl_abs:
        and     word [fac_v+2], 7FFFh
        ret

; ------------------------------------------------------------
; fl_sub / fl_add: FAC = ARG -/+ FAC. CF=1 si depassement.
; ------------------------------------------------------------
fl_sub:
        call    fl_neg
fl_add:
        call    fl_load_a
        call    fl_load_b
        mov     byte [fl_st], 0
        ; zero ?
        mov     ax, [fl_ub+FU_M]
        or      ax, [fl_ub+FU_M+2]
        jnz     .b_nz
        ; B nul: resultat = A
        mov     di, fl_ua
        jmp     fl_store
.b_nz:
        mov     ax, [fl_ua+FU_M]
        or      ax, [fl_ua+FU_M+2]
        jnz     .a_nz
        mov     di, fl_ub               ; A nul: resultat = B
        jmp     fl_store
.a_nz:
        ; ordonne: |A| >= |B| (exposant puis mantisse)
        mov     ax, [fl_ua+FU_E]
        cmp     ax, [fl_ub+FU_E]
        jg      .ordered
        jl      .swap
        mov     ax, [fl_ua+FU_M+2]
        cmp     ax, [fl_ub+FU_M+2]
        ja      .ordered
        jb      .swap
        mov     ax, [fl_ua+FU_M]
        cmp     ax, [fl_ub+FU_M]
        jae     .ordered
.swap:
        mov     cx, 4
        mov     bx, fl_ua
.sw:
        mov     ax, [bx]
        xchg    ax, [bx + (fl_ub - fl_ua)]
        mov     [bx], ax
        add     bx, 2
        loop    .sw
.ordered:
        ; ROM 1.5: en registres. Mantisses de 32 bits (24 bits significatifs << 8: 8 bits de garde);
        ; B decale de d bits vers la droite, les bits perdus "colles" au bit 0 (comme softfloat:
        ; shiftRightJam). Resultat arrondi au plus proche pair par fl_pack, identique au calcul exact
        ; sur 64 bits de la version precedente (d <= 1: rien n'est perdu; d >= 2: au plus un decalage
        ; a gauche apres la soustraction, le bit colle reste sous le bit de garde).
        mov     cx, [fl_ua+FU_E]
        sub     cx, [fl_ub+FU_E]        ; CX = d >= 0
        cmp     cx, 25
        jbe     .align
        mov     di, fl_ua               ; B negligeable
        jmp     fl_store
.align:
        mov     ax, [fl_ub+FU_M]
        mov     dx, [fl_ub+FU_M+2]      ; DX:AX = mb
        xor     bx, bx                  ; BX <> 0: bits perdus
        jcxz    .aligned
        cmp     cl, 16
        jb      .a8
        mov     bx, ax
        mov     ax, dx
        xor     dx, dx
        sub     cl, 16
.a8:
        cmp     cl, 8
        jb      .a1
        or      bl, al
        mov     al, ah
        mov     ah, dl
        mov     dl, dh
        xor     dh, dh
        sub     cl, 8
.a1:
        jcxz    .aligned
.sh:
        shr     dx, 1
        rcr     ax, 1
        adc     bx, 0
        loop    .sh
.aligned:
        or      bx, bx
        jz      .nj
        or      al, 1                   ; bit colle
.nj:
        mov     cl, [fl_ua+FU_S]
        cmp     cl, [fl_ub+FU_S]
        jne     .diff
        add     ax, [fl_ua+FU_M]        ; memes signes: A + B
        adc     dx, [fl_ua+FU_M+2]
        jnc     .store
        rcr     dx, 1                   ; retenue: un bit a droite, la retenue en tete
        rcr     ax, 1
        jnc     .nst
        mov     byte [fl_st], 1
.nst:
        inc     word [fl_ua+FU_E]
        jmp     .store
.diff:
        mov     bx, [fl_ua+FU_M]        ; A - B (|A| >= |B|)
        mov     cx, [fl_ua+FU_M+2]
        sub     bx, ax
        sbb     cx, dx
        mov     ax, bx
        mov     dx, cx
        or      bx, cx
        jnz     .n16
        mov     [fac_v], ax             ; resultat nul: +0
        mov     [fac_v+2], ax
        clc
        ret
.n16:
        or      dx, dx
        jnz     .n8
        xchg    ax, dx
        sub     word [fl_ua+FU_E], 16
.n8:
        or      dh, dh
        jnz     .n1
        mov     dh, dl
        mov     dl, ah
        mov     ah, al
        xor     al, al
        sub     word [fl_ua+FU_E], 8
        jmp     .n8
.n1:
        test    dh, 80h
        jnz     .store
        shl     ax, 1
        rcl     dx, 1
        dec     word [fl_ua+FU_E]
        jmp     .n1
.store:
        mov     [fl_ua+FU_M], ax
        mov     [fl_ua+FU_M+2], dx
        mov     di, fl_ua
        jmp     fl_store

; ------------------------------------------------------------
; fl_mul: FAC = ARG * FAC. CF=1 si depassement.
; ------------------------------------------------------------
fl_mul:
        call    fl_load_a
        call    fl_load_b
fl_mul_ab:                              ; entree avec ua, ub deja deballes
        mov     byte [fl_st], 0
        mov     ax, [fl_ua+FU_M]
        or      ax, [fl_ua+FU_M+2]
        jz      .zero
        mov     ax, [fl_ub+FU_M]
        or      ax, [fl_ub+FU_M+2]
        jz      .zero
        mov     al, [fl_ua+FU_S]
        xor     al, [fl_ub+FU_S]
        mov     [fl_ua+FU_S], al
        mov     ax, [fl_ub+FU_E]
        add     [fl_ua+FU_E], ax
        call    fl_mul64                ; P = ma * mb (64 bits) -> fl_q64
        ; P dans [2^62, 2^64)
        test    word [fl_q64+6], 8000h
        jnz     .top
        shl     word [fl_q64], 1        ; decale d'un bit: bit 63 a 1
        rcl     word [fl_q64+2], 1
        rcl     word [fl_q64+4], 1
        rcl     word [fl_q64+6], 1
        jmp     .have
.top:
        inc     word [fl_ua+FU_E]
.have:
        mov     ax, [fl_q64+4]
        mov     dx, [fl_q64+6]
        mov     [fl_ua+FU_M], ax
        mov     [fl_ua+FU_M+2], dx
        mov     ax, [fl_q64]
        or      ax, [fl_q64+2]
        jz      .nost
        mov     byte [fl_st], 1
.nost:
        mov     di, fl_ua
        jmp     fl_store
.zero:
        xor     ax, ax
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        clc
        ret

; ------------------------------------------------------------
; fl_div: FAC = ARG / FAC. CF=1 si depassement OU division par zero (le
; diviseur nul est signale par ZF=1 au retour: AX=0 et fl_dz=1).
; ------------------------------------------------------------
fl_div:
        call    fl_load_a
        call    fl_load_b
        mov     byte [fl_st], 0
        mov     byte [fl_dz], 0
        mov     ax, [fl_ub+FU_M]
        or      ax, [fl_ub+FU_M+2]
        jnz     .b_ok
        mov     byte [fl_dz], 1         ; division par zero
        mov     ax, 0FFFFh
        mov     [fac_v], ax
        mov     word [fac_v+2], 7F7Fh
        stc
        ret
.b_ok:
        mov     ax, [fl_ua+FU_M]
        or      ax, [fl_ua+FU_M+2]
        jz      .zero
        mov     al, [fl_ua+FU_S]
        xor     al, [fl_ub+FU_S]
        mov     [fl_ua+FU_S], al
        mov     ax, [fl_ub+FU_E]
        sub     [fl_ua+FU_E], ax
        ; r = ma ; qtop = (ma >= mb)
        mov     ax, [fl_ua+FU_M]
        mov     dx, [fl_ua+FU_M+2]      ; DX:AX = r
        xor     bx, bx                  ; BL = qtop
        cmp     dx, [fl_ub+FU_M+2]
        jb      .noq
        ja      .q1
        cmp     ax, [fl_ub+FU_M]
        jb      .noq
.q1:
        sub     ax, [fl_ub+FU_M]
        sbb     dx, [fl_ub+FU_M+2]
        mov     bl, 1
.noq:
        mov     [fl_dq], bl             ; bit de tete du quotient
        ; ROM 1.5: les 32 pas en registres (meme calcul): reste DX:AX, diviseur BX:BP, quotient SI:DI
        push    si
        push    bp
        mov     bx, [fl_ub+FU_M+2]
        mov     bp, [fl_ub+FU_M]
        xor     si, si
        xor     di, di
        mov     cx, 32
.bit:
        shl     di, 1                   ; decale le quotient (le bit sera mis apres)
        rcl     si, 1
        shl     ax, 1                   ; r = r*2 (33 bits)
        rcl     dx, 1
        jc      .sub                    ; r >= 2^32 > mb
        cmp     dx, bx
        jb      .next
        ja      .sub
        cmp     ax, bp
        jb      .next
.sub:
        sub     ax, bp
        sbb     dx, bx
        or      di, 1
.next:
        loop    .bit
        or      ax, dx                  ; reste non nul ?
        jz      .norem
        mov     byte [fl_st], 1
.norem:
        mov     ax, di
        mov     dx, si
        pop     bp
        pop     si
        cmp     byte [fl_dq], 0
        je      .noshift
        ; quotient a 33 bits: >>1, le bit perdu devient collant
        test    al, 1
        jz      .even
        mov     byte [fl_st], 1
.even:
        shr     dx, 1
        rcr     ax, 1
        or      dx, 8000h
        jmp     .have
.noshift:
        dec     word [fl_ua+FU_E]
.have:
        mov     [fl_ua+FU_M], ax
        mov     [fl_ua+FU_M+2], dx
        mov     di, fl_ua
        jmp     fl_store
.zero:
        xor     ax, ax
        mov     [fac_v], ax
        mov     [fac_v+2], ax
        clc
        ret

; ------------------------------------------------------------
; fl_cmp: compare ARG a FAC. Retour AL = 0FFh (ARG<FAC), 0 (=), 1 (>) et les
; flags positionnes comme par "cmp al,0" (signe). Detruit AX,BX,CX,DX.
; ------------------------------------------------------------
fl_cmp:
        mov     ax, [arg_v]
        mov     dx, [arg_v+2]
        mov     bx, [fac_v]
        mov     cx, [fac_v+2]
        ; canonise les zeros (exposant nul -> +0)
        test    dx, 7F80h
        jnz     .a_ok
        xor     ax, ax
        xor     dx, dx
.a_ok:
        test    cx, 7F80h
        jnz     .b_ok
        xor     bx, bx
        xor     cx, cx
.b_ok:
        ; signes differents ?
        mov     [fl_tmp], ax
        mov     [fl_tmp+2], dx
        mov     ax, dx
        xor     ax, cx
        test    ax, 8000h
        jz      .same
        ; signes differents: le negatif est le plus petit (sauf 0 = 0)
        mov     ax, [fl_tmp]
        or      ax, dx
        and     dx, 7FFFh
        or      ax, dx
        jnz     .nz1
        or      bx, cx
        and     cx, 7FFFh
        or      bx, cx
        jz      .eq
.nz1:
        test    word [fl_tmp+2], 8000h
        jnz     .less                   ; ARG negatif, FAC positif
        jmp     .greater
.same:
        ; meme signe: compare les magnitudes (dword non signe)
        mov     ax, [fl_tmp+2]
        and     ax, 7FFFh
        mov     dx, cx
        and     dx, 7FFFh
        cmp     ax, dx
        jb      .maglt
        ja      .maggt
        mov     ax, [fl_tmp]
        cmp     ax, bx
        jb      .maglt
        ja      .maggt
.eq:
        xor     al, al
        cmp     al, 0
        ret
.maglt:
        test    word [fl_tmp+2], 8000h
        jnz     .greater                ; negatifs: plus petite magnitude = plus grand
        jmp     .less
.maggt:
        test    word [fl_tmp+2], 8000h
        jnz     .less
.greater:
        mov     al, 1
        cmp     al, 0
        ret
.less:
        mov     al, 0FFh
        cmp     al, 0
        ret

; ------------------------------------------------------------
; fl_from_i16: AX (entier signe) -> FAC (flottant)
; ------------------------------------------------------------
fl_from_i16:
        xor     dx, dx
        or      ax, ax
        jns     fl_from_u32_p
        neg     ax
        mov     dx, 0
        mov     byte [fl_sgn], 1
        jmp     fl_from_u32_s
fl_from_u32_p:
        mov     byte [fl_sgn], 0
        jmp     fl_from_u32_s

; fl_from_u32: DX:AX (non signe) -> FAC positif
fl_from_u32:
        mov     byte [fl_sgn], 0
fl_from_u32_s:                          ; signe dans fl_sgn
        mov     bx, ax
        or      bx, dx
        jnz     .nz
        mov     [fac_v], bx
        mov     [fac_v+2], bx
        ret
.nz:
        mov     cx, 31                  ; exposant = 31 - decalages
        or      dx, dx                  ; ROM 1.5: normalisation par mot puis par octet, ensuite bit a bit
        jnz     .b
        xchg    ax, dx
        mov     cl, 15
.b:
        or      dh, dh
        jnz     .clz
        mov     dh, dl
        mov     dl, ah
        mov     ah, al
        xor     al, al
        sub     cx, 8
.clz:
        ; ROM 1.5: DH <> 0 ici; ses zeros de tete (0-7) par table, puis un seul decalage
        push    cx
        mov     bl, dh
        xor     bh, bh
        mov     cl, [cs:fl_clz8 + bx]
        xor     ch, ch
        jcxz    .nz0
        shl     dx, cl
        mov     bx, ax
        shl     ax, cl
        neg     cl
        add     cl, 16
        shr     bx, cl
        or      dx, bx
        mov     bx, cx                  ; 16 - n
        pop     cx
        add     cx, bx
        sub     cx, 16                  ; exposant - n
        jmp     .nl
.nz0:
        pop     cx
.nl:
        test    dx, 8000h
        jnz     .go
        shl     ax, 1
        rcl     dx, 1
        dec     cx
        jmp     .nl
.go:
        or      al, al                  ; ROM 1.5: 8 bits d'arrondi nuls = valeur exacte: emballee directement
        jnz     .round
        add     cx, 127
        mov     bx, cx
        mov     cl, 7
        shl     bx, cl                  ; exposant biaise, bits 14-7
        and     dh, 7Fh
        or      bl, dh                  ; fraction, bits 22-16
        cmp     byte [fl_sgn], 0
        je      .pos
        or      bh, 80h
.pos:
        mov     al, ah
        mov     ah, dl                  ; fraction, bits 15-0
        mov     [fac_v], ax
        mov     [fac_v+2], bx
        clc
        ret
.round:
        mov     [fl_ua+FU_M], ax
        mov     [fl_ua+FU_M+2], dx
        mov     [fl_ua+FU_E], cx
        mov     al, [fl_sgn]
        mov     [fl_ua+FU_S], al
        mov     byte [fl_st], 0
        mov     di, fl_ua
        jmp     fl_store

; fl_clz8: nombre de zeros de tete d'un octet non nul (0 -> 8, inutilise)
fl_clz8:
%assign CLZI 0
%rep 256
        db      (CLZI < 1) + (CLZI < 2) + (CLZI < 4) + (CLZI < 8) + (CLZI < 16) + (CLZI < 32) + (CLZI < 64) + (CLZI < 128)
%assign CLZI CLZI + 1
%endrep

; ------------------------------------------------------------
; fl_to_i16: FAC -> AX. mode: AL = 0 tronque (FIX), 1 arrondi (CINT).
; CF=1 si hors de -32768..32767 (depassement).
; ------------------------------------------------------------
fl_to_i16:
        push    ax                      ; mode
        mov     ax, [fac_v]
        mov     dx, [fac_v+2]
        mov     di, fl_ua
        call    fl_unpack
        pop     cx                      ; CL = mode
        mov     ax, [fl_ua+FU_M]
        or      ax, [fl_ua+FU_M+2]
        jnz     .nz
        xor     ax, ax
        clc
        ret
.nz:
        mov     bx, [fl_ua+FU_E]
        or      bx, bx
        js      .small                  ; |x| < 1
        cmp     bx, 15
        ja      .ovf                    ; |x| >= 65536
        ; entier = m32 >> (31 - e) (troncature), reste pour l'arrondi
        mov     ax, [fl_ua+FU_M]
        mov     dx, [fl_ua+FU_M+2]
        mov     ch, 0                   ; CH = bit de garde
        push    cx
        mov     cx, 31
        sub     cx, bx                  ; CX = decalage (16..31)
        mov     bx, 0                   ; BX = reste (bits perdus, pour la garde)
        cmp     cx, 17                  ; ROM 1.5: par mot puis par octet tant qu'il reste plus d'un bit
        jb      .sh                     ; (seul le dernier bit sorti, la garde, compte)
        mov     ax, dx
        xor     dx, dx
        sub     cx, 16
        cmp     cx, 9
        jb      .sh
        mov     al, ah
        xor     ah, ah
        sub     cx, 8
.sh:
        cmp     cx, 1
        jbe     .last
        shr     dx, 1
        rcr     ax, 1
        loop    .sh
.last:
        ; il reste a decaler d'un bit: le bit sorti est la garde
        shr     dx, 1
        rcr     ax, 1
        mov     bl, 0
        rcl     bl, 1                   ; BL = garde
        pop     cx
        cmp     cl, 0
        je      .trunc
        add     ax, bx                  ; arrondi: +garde (demi vers le haut)
        adc     dx, 0
.trunc:
        or      dx, dx
        jnz     .ovf
        ; signe
        cmp     byte [fl_ua+FU_S], 0
        je      .pos
        cmp     ax, 8000h
        ja      .ovf
        neg     ax
        clc
        ret
.pos:
        cmp     ax, 7FFFh
        ja      .ovf
        clc
        ret
.small:
        ; |x| < 1: FIX -> 0 ; CINT: 0.5 <= |x| < 1 -> +-1 (e == -1)
        xor     ax, ax
        cmp     cl, 0
        je      .z
        cmp     bx, -1
        jne     .z
        mov     ax, 1
        cmp     byte [fl_ua+FU_S], 0
        je      .z
        neg     ax
.z:
        clc
        ret
.ovf:
        stc
        ret

; ------------------------------------------------------------
; fl_int / fl_fix: FAC = partie entiere (plancher / vers zero), en flottant.
; ------------------------------------------------------------
fl_int:
        mov     byte [fl_fl], 1
        jmp     fl_intfix
fl_fix:
        mov     byte [fl_fl], 0
fl_intfix:
        mov     ax, [fac_v]
        mov     dx, [fac_v+2]
        mov     di, fl_ua
        call    fl_unpack
        mov     ax, [fl_ua+FU_M]
        or      ax, [fl_ua+FU_M+2]
        jz      .done                   ; zero
        mov     bx, [fl_ua+FU_E]
        cmp     bx, 23
        jge     .done                   ; deja entier
        or      bx, bx
        jns     .frac
        ; |x| < 1
        xor     ax, ax
        xor     dx, dx
        cmp     byte [fl_fl], 0
        je      .zero                   ; FIX -> 0
        cmp     byte [fl_ua+FU_S], 0
        je      .zero                   ; INT positif -> 0
        mov     word [fac_v], 0         ; INT negatif -> -1
        mov     word [fac_v+2], 0BF80h
        ret
.zero:
        mov     [fac_v], ax
        mov     [fac_v+2], dx
        ret
.frac:
        ; masque des bits fractionnaires: les (31 - e) bits de poids faible
        mov     cx, 31
        sub     cx, bx                  ; nombre de bits fractionnaires (9..31)
        xor     ax, ax
        xor     dx, dx                  ; DX:AX = masque bas (2^k - 1)
.mk:
        shl     ax, 1
        rcl     dx, 1
        or      ax, 1
        loop    .mk
        mov     bx, ax
        mov     cx, dx                  ; CX:BX = masque fractionnaire
        mov     ax, [fl_ua+FU_M]
        mov     dx, [fl_ua+FU_M+2]
        and     ax, bx
        and     dx, cx                  ; DX:AX = partie fractionnaire
        mov     [fl_tmp], ax
        mov     [fl_tmp+2], dx
        not     bx
        not     cx
        and     [fl_ua+FU_M], bx
        and     [fl_ua+FU_M+2], cx      ; mantisse tronquee
        mov     ax, [fl_tmp]
        or      ax, [fl_tmp+2]
        jz      .rep
        cmp     byte [fl_fl], 0
        je      .rep                    ; FIX: vers zero
        cmp     byte [fl_ua+FU_S], 0
        je      .rep                    ; INT positif: tronque
        ; INT negatif avec fraction: magnitude + 1 unite entiere (2^k, k = bits fractionnaires)
        mov     bx, [fl_ua+FU_E]
        mov     cx, 31
        sub     cx, bx
        mov     ax, 1
        xor     dx, dx
.un:
        shl     ax, 1
        rcl     dx, 1
        loop    .un                     ; DX:AX = 2^k
        add     [fl_ua+FU_M], ax
        adc     [fl_ua+FU_M+2], dx
        jnc     .rep
        mov     word [fl_ua+FU_M+2], 8000h
        mov     word [fl_ua+FU_M], 0
        inc     word [fl_ua+FU_E]
.rep:
        mov     byte [fl_st], 0
        mov     di, fl_ua
        jmp     fl_store
.done:
        clc
        ret
