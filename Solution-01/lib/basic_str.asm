; ============================================================
; basic_str.asm - chaines: tas, ramasse-miettes, concatenation, comparaison,
; mise en forme des nombres (lib/basic.asm)
;
; Descripteur (3 octets, dans une variable, un element de tableau, la pile de
; valeurs, FAC ou ARG): [longueur][pointeur:2]. L'espace des chaines est un tas
; qui DESCEND de B_STRTOP vers b_fretop.
; Regles de propriete:
;   - une chaine du tas est possedee par UN descripteur de variable/tableau, ou
;     par un temporaire (FAC/ARG/pile de valeurs avec fac_own = 1);
;   - un descripteur non possedant (fac_own = 0) qui pointe dans le tas est un
;     ALIAS (valeur d'une variable chargee dans FAC): le ramasse-miettes le met
;     a jour avec la variable; il est copie (str_stable) avant d'etre stocke;
;   - les litteraux pointent dans le texte du programme (hors tas).
; ============================================================

; str_alloc: CX = longueur (> 0) -> BX = pointeur. Preserve CX et SI.
str_alloc:
        mov     bx, [b_fretop]
        sub     bx, cx
        mov     ax, [b_strend]
        add     ax, 40
        cmp     bx, ax
        jae     .ok
        push    cx
        call    gc
        pop     cx
        mov     bx, [b_fretop]
        sub     bx, cx
        mov     ax, [b_strend]
        add     ax, 40
        cmp     bx, ax
        jae     .ok
        ERROR   ERR_OS
.ok:
        mov     [b_fretop], bx
        ret

; ------------------------------------------------------------
; Ramasse-miettes: compacte le tas vers le haut (B_STRTOP). Les chaines vivantes
; sont traitees par adresse DECROISSANTE; un descripteur deja deplace a un
; pointeur >= a la limite (ancienne adresse de la derniere chaine deplacee).
; ------------------------------------------------------------
gc:
        push    si
        push    di
        push    bp
        mov     word [b_g1], B_STRTOP   ; nouveau sommet
        mov     word [b_g2], B_STRTOP   ; limite (ancienne adresse)
.pass:
        mov     word [b_g3], 0          ; meilleure candidate
        mov     dx, gc_find
        call    gc_walk
        mov     bx, [b_g3]
        or      bx, bx
        jz      .done
        mov     cx, [b_g4]              ; longueur
        mov     ax, [b_g1]
        sub     ax, cx
        mov     [b_g1], ax              ; nouvelle adresse
        mov     si, bx
        add     si, cx
        dec     si
        mov     di, ax
        add     di, cx
        dec     di
        std
        rep     movsb
        cld
        mov     dx, gc_upd
        call    gc_walk
        mov     ax, [b_g3]
        mov     [b_g2], ax
        jmp     .pass
.done:
        mov     ax, [b_g1]
        mov     [b_fretop], ax
        pop     bp
        pop     di
        pop     si
        ret

; gc_find: BX = descripteur. Cherche la plus haute adresse < limite.
gc_find:
        mov     al, [bx]
        or      al, al
        jz      .r
        mov     cx, [bx+1]
        cmp     cx, [b_fretop]
        jb      .r
        cmp     cx, [b_g2]
        jae     .r
        cmp     cx, [b_g3]
        jbe     .r
        mov     [b_g3], cx
        xor     ah, ah
        mov     [b_g4], ax
.r:
        ret

; gc_upd: BX = descripteur. Met a jour tous ceux qui pointent sur l'ancienne adresse.
gc_upd:
        mov     cx, [bx+1]
        cmp     cx, [b_g3]
        jne     .r
        mov     ax, [b_g1]
        mov     [bx+1], ax
.r:
        ret

; gc_walk: appelle DX (BX = adresse d'un descripteur) pour chaque descripteur de
; chaine: FAC, ARG, pile de valeurs, variables, elements de tableaux. Les
; fonctions appelees preservent DX, SI, DI, BP.
gc_walk:
        cmp     byte [fac_t], TY_STR
        jne     .a1
        mov     bx, fac_v
        call    dx
.a1:
        cmp     byte [arg_t], TY_STR
        jne     .v0
        mov     bx, arg_v
        call    dx
.v0:
        mov     si, B_VSTK
.v:
        cmp     si, [b_vsp]
        jae     .s0
        cmp     byte [si], TY_STR
        jne     .vn
        lea     bx, [si+2]
        call    dx
.vn:
        add     si, 8
        jmp     .v
.s0:
        mov     si, [b_vartab]
.s:
        cmp     si, [b_arytab]
        jae     .a0
        mov     cl, [si+1]
        xor     ch, ch
        cmp     byte [si], TY_STR
        jne     .sn
        lea     bx, [si+2]
        add     bx, cx
        push    cx
        call    dx
        pop     cx
.sn:
        add     si, cx
        add     si, 6
        jmp     .s
.a0:
        mov     si, [b_arytab]
.a:
        cmp     si, [b_strend]
        jae     .end
        mov     cl, [si+1]
        xor     ch, ch
        mov     di, si
        add     di, cx
        add     di, 2                   ; DI -> taille
        mov     bp, [di]
        add     bp, si                  ; BP = fin de l'entree
        cmp     byte [si], TY_STR
        jne     .an
        mov     al, [di+2]              ; ndims
        xor     ah, ah
        shl     ax, 1
        lea     di, [di+3]
        add     di, ax                  ; DI = premier element
.e:
        cmp     di, bp
        jae     .an
        mov     bx, di
        call    dx
        add     di, 4
        jmp     .e
.an:
        mov     si, bp
        jmp     .a
.end:
        ret

; ------------------------------------------------------------
; str_stable: FAC (chaine) devient stockable dans une variable: copie dans le
; tas sauf si possedee, vide, ou dans le texte du programme.
; ------------------------------------------------------------
str_stable:
        cmp     byte [fac_own], 0
        jne     .ret
        cmp     byte [fac_v], 0
        je      .ret
        mov     ax, [fac_v+1]
        cmp     ax, B_TXT
        jb      .copy
        cmp     ax, [b_vartab]
        jb      .ret
.copy:
        mov     cl, [fac_v]
        xor     ch, ch
        push    si
        call    str_alloc               ; BX = nouvelle zone (FAC est une racine)
        mov     di, bx
        mov     si, [fac_v+1]           ; relu APRES l'allocation
        rep     movsb
        pop     si
        mov     [fac_v+1], bx
        mov     byte [fac_own], 1
.ret:
        ret

; mk_str: BX = source (hors tas), CX = longueur -> FAC = nouvelle chaine
mk_str:
        push    si
        mov     si, bx
        mov     word [fac_t], TY_INT    ; FAC n'est plus une racine
        jcxz    .empty
        call    str_alloc
        mov     di, bx
        mov     [fac_v], cl
        mov     [fac_v+1], bx
        rep     movsb
        jmp     .set
.empty:
        mov     byte [fac_v], 0
.set:
        mov     word [fac_t], TY_STR + 100h
        pop     si
        ret

; substr: ARG = chaine source, DX = decalage, CX = longueur (deja bornes) ->
; FAC = copie (nouvelle chaine)
substr:
        mov     word [fac_t], TY_INT
        jcxz    .empty
        push    cx
        push    dx
        call    str_alloc               ; BX = zone
        pop     dx
        pop     cx
        push    si
        mov     di, bx
        mov     si, [arg_v+1]           ; relu apres l'allocation
        add     si, dx
        mov     [fac_v], cl
        mov     [fac_v+1], bx
        rep     movsb
        pop     si
        jmp     .set
.empty:
        mov     byte [fac_v], 0
.set:
        mov     word [fac_t], TY_STR + 100h
        mov     word [arg_t], TY_INT
        ret

; str_concat: FAC = ARG + FAC (chaines)
str_concat:
        mov     dl, [arg_v]
        mov     cl, [fac_v]
        or      dl, dl
        jnz     .a
        ret                             ; ARG vide: FAC inchange
.a:
        or      cl, cl
        jnz     .b
        call    xchg_fa                 ; FAC vide: resultat = ARG
        ret
.b:
        xor     dh, dh
        xor     ch, ch
        mov     ax, dx
        add     ax, cx
        cmp     ax, 255
        jbe     .ok
        ERROR   ERR_LS
.ok:
        mov     cx, ax
        push    cx
        call    str_alloc               ; BX = zone (ARG et FAC sont des racines)
        pop     cx
        push    si
        mov     di, bx
        mov     [b_g4], cx
        mov     cl, [arg_v]
        xor     ch, ch
        mov     si, [arg_v+1]
        rep     movsb
        mov     cl, [fac_v]
        xor     ch, ch
        mov     si, [fac_v+1]
        rep     movsb
        pop     si
        mov     cx, [b_g4]
        mov     [fac_v], cl
        mov     [fac_v+1], bx
        mov     word [fac_t], TY_STR + 100h
        ret

; str_cmp: compare ARG a FAC -> AL = 0FFh (<), 0 (=), 1 (>)
str_cmp:
        push    si
        mov     bl, [arg_v]
        mov     bh, [fac_v]
        mov     si, [arg_v+1]
        mov     di, [fac_v+1]
        mov     cl, bl
        cmp     bh, cl
        jae     .m
        mov     cl, bh
.m:
        xor     ch, ch
        jcxz    .lens
        repe    cmpsb
        je      .lens
        ja      .gt
        jmp     .lt
.lens:
        cmp     bl, bh
        je      .eq
        jb      .lt
.gt:
        mov     al, 1
        jmp     .out
.lt:
        mov     al, 0FFh
        jmp     .out
.eq:
        xor     al, al
.out:
        pop     si
        ret

; ------------------------------------------------------------
; Mise en forme des nombres
; ------------------------------------------------------------
; put_ubase: AX (non signe) en base BX -> caracteres a [DI] (DI avance)
put_ubase:
        push    cx
        push    dx
        xor     cx, cx
.d:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d
.p:
        pop     ax
        add     al, '0'
        cmp     al, '9'
        jbe     .c
        add     al, 7
.c:
        stosb
        loop    .p
        pop     dx
        pop     cx
        ret

put_udec:
        push    bx
        mov     bx, 10
        call    put_ubase
        pop     bx
        ret

; fmt_num: FAC numerique -> B_NBUF (signe ' ' ou '-', chiffres, zero final),
; CX = longueur (sans espace final).
fmt_num:
        mov     di, B_NBUF
        mov     byte [di], ' '
        cmp     byte [fac_t], TY_INT
        jne     .flt
        mov     ax, [fac_v]
        or      ax, ax
        jns     .ip
        mov     byte [di], '-'
        neg     ax
.ip:
        inc     di
        call    put_udec
        jmp     .fin
.flt:
        call    fl_ftoa
        mov     di, B_NBUF
        mov     byte [di], ' '
        cmp     byte [fl_fsg], 0
        je      .fp
        mov     byte [di], '-'
.fp:
        inc     di
        cmp     byte [fl_dig], '0'
        jne     .nz
        mov     byte [di], '0'
        inc     di
        jmp     .fin
.nz:
        mov     bx, 6                   ; chiffres significatifs (zeros finaux retires)
.strip:
        cmp     byte [fl_dig + bx], '0'
        jne     .got
        or      bx, bx
        jz      .got
        dec     bx
        jmp     .strip
.got:
        inc     bx
        mov     [b_g4], bx              ; n
        mov     ax, [fl_dexp]
        cmp     ax, -2
        jl      .exp
        cmp     ax, 6
        jg      .exp
        or      ax, ax
        js      .small
        mov     cx, ax
        inc     cx                      ; chiffres avant la virgule
        xor     bx, bx
.i:
        mov     al, '0'
        cmp     bx, [b_g4]
        jae     .ip2
        mov     al, [fl_dig + bx]
.ip2:
        stosb
        inc     bx
        loop    .i
        cmp     bx, [b_g4]
        jae     .fin
        mov     al, '.'
        stosb
.f:
        mov     al, [fl_dig + bx]
        stosb
        inc     bx
        cmp     bx, [b_g4]
        jb      .f
        jmp     .fin
.small:
        mov     cx, ax
        neg     cx
        dec     cx                      ; zeros apres la virgule
        mov     al, '.'
        stosb
        jcxz    .sd
.z:
        mov     al, '0'
        stosb
        loop    .z
.sd:
        xor     bx, bx
.d:
        mov     al, [fl_dig + bx]
        stosb
        inc     bx
        cmp     bx, [b_g4]
        jb      .d
        jmp     .fin
.exp:
        mov     al, [fl_dig]
        stosb
        cmp     word [b_g4], 1
        je      .e
        mov     al, '.'
        stosb
        mov     bx, 1
.ed:
        mov     al, [fl_dig + bx]
        stosb
        inc     bx
        cmp     bx, [b_g4]
        jb      .ed
.e:
        mov     al, 'E'
        stosb
        mov     ax, [fl_dexp]
        mov     dl, '+'
        or      ax, ax
        jns     .es
        mov     dl, '-'
        neg     ax
.es:
        mov     [di], dl
        inc     di
        mov     cl, 10
        div     cl                      ; AL = dizaines, AH = unites (|e| < 100)
        add     al, '0'
        add     ah, '0'
        stosb
        mov     al, ah
        stosb
.fin:
        mov     byte [di], 0
        mov     cx, di
        sub     cx, B_NBUF
        ret

; print_fac: affiche FAC (chaine ou nombre; un nombre est suivi d'un espace)
print_fac:
        cmp     byte [fac_t], TY_STR
        jne     .num
        mov     cl, [fac_v]
        xor     ch, ch
        mov     bx, [fac_v+1]
        jcxz    .r
.l:
        mov     al, [bx]
        call    bas_putc
        inc     bx
        loop    .l
.r:
        ret
.num:
        call    fmt_num
        mov     bx, B_NBUF
.n:
        mov     al, [bx]
        call    bas_putc
        inc     bx
        loop    .n
        mov     al, ' '
        jmp     bas_putc
