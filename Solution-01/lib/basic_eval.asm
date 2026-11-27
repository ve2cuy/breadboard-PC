; ============================================================
; basic_eval.asm - evaluation d'expressions, variables, tableaux (lib/basic.asm)
; Valeur courante = FAC (fac_t: type 2/3/4, fac_own, fac_v: 4 octets). Operande
; gauche = ARG. Pile de valeurs (B_VSTK) pour les operandes gauches en attente;
; la pile de valeurs est un RACINE du ramasse-miettes de chaines.
; Convention: SI = pointeur de texte, prive de l'eval (avance).
; ============================================================

; ------------------------------------------------------------
; Pile de valeurs
; ------------------------------------------------------------
vpush_fac:
        mov     bx, [b_vsp]
        cmp     bx, B_VSTKE
        jb      .ok
        ERROR   ERR_ST
.ok:
        mov     ax, [fac_t]
        mov     [bx], ax
        mov     ax, [fac_v]
        mov     [bx+2], ax
        mov     ax, [fac_v+2]
        mov     [bx+4], ax
        add     bx, 8
        mov     [b_vsp], bx
        ret

vpop_arg:
        mov     bx, [b_vsp]
        sub     bx, 8
        mov     [b_vsp], bx
        mov     ax, [bx]
        mov     [arg_t], ax
        mov     ax, [bx+2]
        mov     [arg_v], ax
        mov     ax, [bx+4]
        mov     [arg_v+2], ax
        ret

vpop_fac:
        mov     bx, [b_vsp]
        sub     bx, 8
        mov     [b_vsp], bx
        mov     ax, [bx]
        mov     [fac_t], ax
        mov     ax, [bx+2]
        mov     [fac_v], ax
        mov     ax, [bx+4]
        mov     [fac_v+2], ax
        ret

; xchg_fa: echange FAC et ARG (type, propriete et valeur)
xchg_fa:
        mov     ax, [fac_t]
        xchg    ax, [arg_t]
        mov     [fac_t], ax
        mov     ax, [fac_v]
        xchg    ax, [arg_v]
        mov     [fac_v], ax
        mov     ax, [fac_v+2]
        xchg    ax, [arg_v+2]
        mov     [fac_v+2], ax
        ret

; ------------------------------------------------------------
; Conversions de type
; ------------------------------------------------------------
need_num:
        cmp     byte [fac_t], TY_STR
        jne     .ok
        ERROR   ERR_TM
.ok:
        ret

need_str:
        cmp     byte [fac_t], TY_STR
        je      .ok
        ERROR   ERR_TM
.ok:
        ret

; fac_set_int: AX -> FAC entier
fac_set_int:
        mov     [fac_v], ax
        mov     word [fac_v+2], 0
        mov     word [fac_t], TY_INT     ; type = 2, own = 0
        ret

; fac_sng: FAC numerique -> simple precision (no-op si deja)
fac_sng:
        cmp     byte [fac_t], TY_INT
        jne     .ret
        mov     ax, [fac_v]
        call    fl_from_i16
        mov     word [fac_t], TY_SNG
.ret:
        ret

; fac_i16: FAC numerique -> AX entier 16 bits signe (arrondi). Erreur OV si hors plage.
fac_i16:
        cmp     byte [fac_t], TY_INT
        jne     .f
        mov     ax, [fac_v]
        ret
.f:
        cmp     byte [fac_t], TY_STR
        jne     .n
        ERROR   ERR_TM
.n:
        mov     ax, 1
        call    fl_to_i16
        jnc     .ok
        ERROR   ERR_OV
.ok:
        ret

; fac_int: FAC numerique -> FAC entier (type 2)
fac_int:
        call    fac_i16
        jmp     fac_set_int

; arg_sng: ARG numerique -> simple precision
arg_sng:
        cmp     byte [arg_t], TY_INT
        jne     .ret
        call    xchg_fa
        call    fac_sng
        call    xchg_fa
.ret:
        ret

; eval_int: evalue une expression -> AX entier 16 bits
eval_int:
        call    eval_expr
        jmp     fac_i16

; eval_num: evalue une expression numerique (FAC)
eval_num:
        call    eval_expr
        jmp     need_num

; eval_str: evalue une expression chaine
eval_str:
        call    eval_expr
        jmp     need_str

; ------------------------------------------------------------
; Evaluation: precedence (haute = lie plus fort)
;   IMP 1, EQV 2, XOR 3, OR 4, AND 5, (NOT 6), relationnels 7, + - 8, MOD 9,
;   \ 10, * / 11, (- unaire 12), ^ 13
; Identifiants d'operateur (AH): 1 IMP 2 EQV 3 XOR 4 OR 5 AND, 6 = 7 < 8 > 9 <=
;   10 >= 11 <>, 12 + 13 - 14 MOD 15 \ 16 * 17 / 18 ^
; ------------------------------------------------------------
eval_expr:
        mov     al, 1
eval_p:
        STKCHK
        push    ax                      ; [sp] = precedence minimale
        ; ROM 1.6: operande deja vu dans le texte du programme (variable simple de BC_VAR ou constante de
        ; BC_NUM, cle = son adresse): charge ici, sans eval_unary/eval_primary/var_ref/lit_number
        SKIPSP
        mov     bx, si
        and     bx, 63
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        cmp     [bx+BC_VAR], si
        je      .var
        cmp     [bx+BC_NUM], si
        jne     .gen
        mov     ax, [bx+BC_NUM+2]       ; AL = longueur, AH = type
        mov     cl, ah
        xor     ah, ah
        add     si, ax
        mov     ch, ah                  ; (fac_own = 0)
        mov     [fac_t], cx
        mov     ax, [bx+BC_NUM+4]
        mov     [fac_v], ax
        mov     ax, [bx+BC_NUM+6]
        mov     [fac_v+2], ax
        jmp     .loop
.var:
        mov     ax, [bx+BC_VAR+4]       ; AL = longueur, AH = type
        test    ah, 80h
        jnz     .gen                    ; tableau: chemin normal
        mov     [b_bb3], ah
        mov     cl, ah
        xor     ah, ah
        add     si, ax
        mov     ch, ah
        mov     [fac_t], cx
        mov     bx, [bx+BC_VAR+2]       ; adresse de la valeur
        mov     ax, [bx]
        mov     [fac_v], ax
        xor     ax, ax
        cmp     cl, TY_INT
        je      .vi
        mov     ax, [bx+2]
.vi:
        mov     [fac_v+2], ax
        jmp     .loop
.gen:
        call    eval_unary
.loop:
        ; ROM 1.6: classe du caractere par table ici (sans appel s'il n'y a pas d'operateur)
        SKIPSP
        mov     bl, al
        xor     bh, bh
        mov     bl, [cs:op_cls + bx]
        or      bl, bl
        jz      .done
        cmp     bl, 13
        jae     .rel
        mov     dl, 1
        shl     bx, 1
        mov     ax, [cs:op_val - 2 + bx]
        jmp     .op
.rel:
        call    peek_op                 ; = < > (un ou deux caracteres): AL = precedence, AH = op, DL
.op:
        mov     bx, sp
        cmp     al, [bx]
        jb      .done
        push    ax                      ; (precedence, op)
        xor     dh, dh
        add     si, dx                  ; consomme l'operateur
        call    vpush_fac               ; operande gauche
        pop     ax
        push    ax
        inc     al                      ; operande droit: precedence + 1
        call    eval_p
        pop     dx                      ; DH = operateur
        call    vpop_arg
        mov     al, dh
        call    apply_op                ; FAC = ARG op FAC
        mov     word [arg_t], TY_INT    ; ARG n'est plus une racine
        jmp     .loop
.done:
        pop     ax
        ret

; peek_op: examine l'operateur a [SI] sans le consommer. AL = precedence (0 si aucun),
; AH = identifiant, DL = nombre de caracteres. Passe les espaces (SI avance dessus).
peek_op:
        SKIPSP
        mov     dl, 1
        mov     bl, al                  ; ROM 1.5: classe de l'octet par table (pas d'operateur: tout de suite)
        xor     bh, bh
        mov     bl, [cs:op_cls + bx]
        or      bl, bl
        jz      .none
        cmp     bl, 13
        jae     .n6                     ; = < > : deux caracteres possibles
        shl     bx, 1
        mov     ax, [cs:op_val - 2 + bx]
        ret
.n0:
        cmp     al, '+'
        jne     .n1
        mov     ax, 0C08h
        ret
.n1:
        cmp     al, '-'
        jne     .n2
        mov     ax, 0D08h
        ret
.n2:
        cmp     al, '*'
        jne     .n3
        mov     ax, 100Bh
        ret
.n3:
        cmp     al, '/'
        jne     .n4
        mov     ax, 110Bh
        ret
.n4:
        cmp     al, '^'
        jne     .n5
        mov     ax, 120Dh
        ret
.n5:
        cmp     al, '\'
        jne     .n6
        mov     ax, 0F0Ah
        ret
.n6:
        cmp     al, '='
        jne     .n7
        mov     al, [si+1]
        cmp     al, '<'
        je      .le2
        cmp     al, '>'
        je      .ge2
        mov     ax, 0607h
        ret
.le2:
        mov     dl, 2
        mov     ax, 0907h
        ret
.ge2:
        mov     dl, 2
        mov     ax, 0A07h
        ret
.n7:
        cmp     al, '<'
        jne     .n8
        mov     al, [si+1]
        cmp     al, '>'
        je      .ne2
        cmp     al, '='
        je      .le2
        mov     ax, 0707h
        ret
.ne2:
        mov     dl, 2
        mov     ax, 0B07h
        ret
.n8:
        cmp     al, '>'
        jne     .n9
        mov     al, [si+1]
        cmp     al, '='
        je      .ge2
        cmp     al, '<'
        je      .ne2
        mov     ax, 0807h
        ret
.n9:
        cmp     al, T_MOD
        jne     .n10
        mov     ax, 0E09h
        ret
.n10:
        cmp     al, T_AND
        jne     .n11
        mov     ax, 0505h
        ret
.n11:
        cmp     al, T_OR
        jne     .n12
        mov     ax, 0404h
        ret
.n12:
        cmp     al, T_XOR
        jne     .n13
        mov     ax, 0303h
        ret
.n13:
        cmp     al, T_EQV
        jne     .n14
        mov     ax, 0202h
        ret
.n14:
        cmp     al, T_IMP
        jne     .none
        mov     ax, 0101h
        ret
.none:
        xor     ax, ax
        ret

; classes de peek_op: 1-12 = operateur d'un caractere (AX dans op_val), 13 = '=', '<' ou '>', 0 = aucun
op_cls:
%assign OPI 0
%rep 256
        db      (OPI = '+') * 1 + (OPI = '-') * 2 + (OPI = '*') * 3 + (OPI = '/') * 4 + (OPI = '^') * 5 + \
                (OPI = '\') * 6 + (OPI = T_MOD) * 7 + (OPI = T_AND) * 8 + (OPI = T_OR) * 9 + (OPI = T_XOR) * 10 + \
                (OPI = T_EQV) * 11 + (OPI = T_IMP) * 12 + ((OPI = '=') | (OPI = '<') | (OPI = '>')) * 13
%assign OPI OPI + 1
%endrep
op_val: dw      0C08h, 0D08h, 100Bh, 110Bh, 120Dh, 0F0Ah, 0E09h, 0505h, 0404h, 0303h, 0202h, 0101h

; eval_unary: operande avec operateurs prefixes (-, +, NOT)
eval_unary:
        SKIPSP
        cmp     al, '-'
        jne     .np
        inc     si
        mov     al, 13
        call    eval_p                  ; l'operande lie plus fort que * / (mais pas ^)
        call    need_num
        cmp     byte [fac_t], TY_INT
        jne     .fneg
        mov     ax, [fac_v]
        cmp     ax, 8000h
        je      .ovneg
        neg     ax
        jmp     fac_set_int
.ovneg:
        call    fac_sng
.fneg:
        call    fl_neg
        ret
.np:
        cmp     al, '+'
        jne     .nn
        inc     si
        mov     al, 13
        call    eval_p
        jmp     need_num
.nn:
        cmp     al, T_NOT
        jne     eval_primary
        inc     si
        mov     al, 7
        call    eval_p
        call    fac_i16
        not     ax
        jmp     fac_set_int

; eval_primary: constante, variable, (expression), fonction
eval_primary:
        mov     al, [si]
        cmp     al, '('
        jne     .np
        inc     si
        call    eval_expr
        call    skip_sp
        cmp     al, ')'
        je      .cp
        ERROR   ERR_SN
.cp:
        inc     si
        ret
.np:
        cmp     al, '"'
        je      lit_string
        cmp     al, '.'
        je      lit_number
        cmp     al, '0'
        jb      .nd
        cmp     al, '9'
        jbe     lit_number
.nd:
        cmp     al, '&'
        je      lit_radix
        cmp     al, 80h
        jae     .tok
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .sn
        cmp     ah, 'Z'
        ja      .sn
        jmp     var_load                ; variable (ou element de tableau)
.sn:
        ERROR   ERR_SN
.tok:
        cmp     al, T_FN
        je      fn_user
        cmp     al, T_SGN
        jb      .sn
        cmp     al, T_EOF
        ja      .sn
        inc     si
        sub     al, 80h
        xor     ah, ah
        shl     ax, 1
        mov     bx, ax
        call    [cs:tok_handlers + bx]
        ret

; lit_number: litteral numerique a [SI]. ROM 1.5: une constante du programme n'est convertie qu'une
; fois (cache BC_NUM, cle = son adresse dans le texte): ensuite, valeur et type sont recopies.
lit_number:
        mov     bx, si
        and     bx, 63
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        add     bx, BC_NUM
        cmp     [bx], si
        jne     .miss
        mov     ax, [bx+2]              ; AL = longueur, AH = type
        mov     [fac_t], ah
        mov     byte [fac_own], 0
        xor     ah, ah
        add     si, ax
        mov     ax, [bx+4]
        mov     [fac_v], ax
        mov     ax, [bx+6]
        mov     [fac_v+2], ax
        ret
.miss:
        cmp     si, B_TXT
        jb      lit_parse
        cmp     si, [b_vartab]
        jae     lit_parse
        push    bx
        push    si
        call    lit_parse
        pop     ax                      ; debut de la constante
        pop     bx                      ; case du cache
        mov     dx, si
        sub     dx, ax
        or      dh, dh
        jnz     .r                      ; (plus de 255 caracteres: pas gardee)
        mov     [bx], ax
        mov     dh, [fac_t]
        mov     [bx+2], dx
        mov     ax, [fac_v]
        mov     [bx+4], ax
        mov     ax, [fac_v+2]
        mov     [bx+6], ax
.r:
        ret

lit_parse:
        xor     al, al
        call    fl_atof
        jnc     .ok
        cmp     ah, 1
        jne     .sn
        ERROR   ERR_OV
.sn:
        ERROR   ERR_SN
.ok:
        mov     [fac_t], al
        mov     byte [fac_own], 0
        cmp     al, TY_INT
        jne     .sfx
        mov     word [fac_v+2], 0
.sfx:
        mov     al, [si]                ; suffixe de type ignore/applique
        cmp     al, '%'
        jne     .n1
        inc     si
        call    fac_int
        ret
.n1:
        cmp     al, '!'
        je      .fsng
        cmp     al, '#'
        jne     .ret
.fsng:
        inc     si
        call    fac_sng
.ret:
        ret

; lit_radix: &H hex, &O octal (defaut octal) -> entier 16 bits
lit_radix:
        inc     si
        mov     al, [si]
        and     al, 0DFh
        mov     cx, 8                   ; base
        cmp     al, 'H'
        jne     .o
        mov     cx, 16
        inc     si
        jmp     .go
.o:
        cmp     al, 'O'
        jne     .go
        inc     si
.go:
        xor     bx, bx                  ; valeur
.l:
        mov     al, [si]
        call    is_hex
        jnc     .end
        mov     dl, al
        cmp     dl, '9'
        jbe     .dg
        and     dl, 0DFh
        sub     dl, 'A' - 10
        jmp     .have
.dg:
        sub     dl, '0'
.have:
        xor     dh, dh
        cmp     dx, cx
        jae     .end
        mov     ax, bx
        push    dx
        mul     cx
        pop     dx
        add     ax, dx
        mov     bx, ax
        inc     si
        jmp     .l
.end:
        mov     ax, bx
        jmp     fac_set_int

; lit_string: litteral chaine "..." -> descripteur pointant dans le texte
lit_string:
        inc     si
        mov     bx, si
        xor     cx, cx
.l:
        mov     al, [si]
        or      al, al
        jz      .end
        cmp     al, '"'
        je      .close
        inc     si
        inc     cx
        jmp     .l
.close:
        inc     si
.end:
        cmp     cx, 255
        jbe     .ok
        ERROR   ERR_LS
.ok:
        mov     [fac_v], cl
        mov     [fac_v+1], bx
        mov     word [fac_t], TY_STR
        ret

; ------------------------------------------------------------
; Variables
; Table des variables simples [b_vartab, b_arytab): entrees
;   [type][len][nom...][valeur: 4 octets]
; Table des tableaux [b_arytab, b_strend): entrees
;   [type][len][nom...][taille:2][ndims:1][bornes:2*n][elements...]
; ------------------------------------------------------------
; parse_name: SI sur une lettre. Lit le nom (lettres/chiffres, 40 max) dans b_word
; (zero termine, SANS suffixe), longueur dans b_wlen, type dans b_bb3. SI avance
; apres le suffixe.
parse_name:
        mov     bx, b_word
        xor     cx, cx
.l:
        mov     al, [si]
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .d
        cmp     ah, 'Z'
        ja      .d
        jmp     .st
.d:
        cmp     al, '0'
        jb      .end
        cmp     al, '9'
        ja      .end
.st:
        cmp     cx, 40
        jae     .sk
        mov     [bx], al
        inc     bx
        inc     cx
.sk:
        inc     si
        jmp     .l
.end:
        mov     byte [bx], 0
        mov     [b_wlen], cl
        mov     al, [si]
        mov     dl, TY_STR
        cmp     al, '$'
        je      .suf
        mov     dl, TY_INT
        cmp     al, '%'
        je      .suf
        mov     dl, TY_SNG
        cmp     al, '!'
        je      .suf
        cmp     al, '#'
        je      .suf
        mov     al, [b_word]
        sub     al, 'A'
        xor     ah, ah
        mov     bx, ax
        mov     dl, [b_deftbl + bx]
        jmp     .set
.suf:
        inc     si
.set:
        mov     [b_bb3], dl
        ret

; find_var: variable simple (b_word, b_wlen, b_bb3) -> BX = adresse de la valeur
; (creee a 0 si absente). Preserve SI.
find_var:
        mov     bx, [b_vartab]
.l:
        cmp     bx, [b_arytab]
        jae     .new
        mov     cl, [bx+1]
        xor     ch, ch
        mov     al, [bx]
        cmp     al, [b_bb3]
        jne     .next
        cmp     cl, [b_wlen]
        jne     .next
        push    bx
        add     bx, 2
        mov     di, b_word
        mov     dx, cx
.c:
        mov     al, [bx]
        cmp     al, [di]
        jne     .cn
        inc     bx
        inc     di
        dec     dx
        jnz     .c
        pop     ax
        ret                             ; BX = valeur
.cn:
        pop     bx
.next:
        add     bx, cx
        add     bx, 6
        jmp     .l
.new:
        push    si
        mov     cl, [b_wlen]
        xor     ch, ch
        add     cx, 6                   ; taille de l'entree
        mov     [b_t1], cx
        mov     ax, [b_strend]
        add     ax, cx
        jc      .om
        call    mem_check
        mov     si, [b_strend]
        mov     cx, si
        sub     cx, [b_arytab]          ; octets a deplacer (tableaux)
        inc     word [b_agen]           ; les tableaux bougent (cache des variables)
        mov     di, si
        add     di, [b_t1]
        dec     si
        dec     di
        std
        rep     movsb
        cld
        mov     di, [b_arytab]
        mov     al, [b_bb3]
        stosb
        mov     al, [b_wlen]
        stosb
        mov     si, b_word
        mov     cl, [b_wlen]
        xor     ch, ch
        rep     movsb
        xor     ax, ax
        stosw
        stosw
        mov     ax, [b_t1]
        add     [b_arytab], ax
        add     [b_strend], ax
        mov     bx, di
        sub     bx, 4
        pop     si
        ret
.om:
        ERROR   ERR_OM

; mem_check: AX = fin de zone souhaitee. Erreur OM si AX + marge >= b_fretop
; (apres un ramasse-miettes).
mem_check:
        add     ax, 40
        jc      .om
        cmp     ax, [b_fretop]
        jb      .ok
        push    ax
        call    gc
        pop     ax
        cmp     ax, [b_fretop]
        jb      .ok
.om:
        ERROR   ERR_OM
.ok:
        ret

; load_slot: BX = adresse de la valeur, CL = type -> FAC
load_slot:
        mov     [fac_t], cl
        mov     byte [fac_own], 0
        cmp     cl, TY_INT
        jne     .n
        mov     ax, [bx]
        mov     [fac_v], ax
        mov     word [fac_v+2], 0
        ret
.n:
        mov     ax, [bx]
        mov     [fac_v], ax
        mov     ax, [bx+2]
        mov     [fac_v+2], ax
        ret

; store_slot: BX = adresse de la valeur, CL = type; FAC -> variable (avec
; conversion de type). Preserve BX.
store_slot:
        cmp     cl, TY_STR
        je      .str
        cmp     byte [fac_t], TY_STR
        jne     .num
        ERROR   ERR_TM
.num:
        push    bx
        cmp     cl, TY_INT
        jne     .sng
        call    fac_i16
        pop     bx
        mov     [bx], ax
        ret
.sng:
        call    fac_sng
        pop     bx
        mov     ax, [fac_v]
        mov     [bx], ax
        mov     ax, [fac_v+2]
        mov     [bx+2], ax
        ret
.str:
        cmp     byte [fac_t], TY_STR
        je      .s2
        ERROR   ERR_TM
.s2:
        push    bx
        call    str_stable
        pop     bx
        mov     al, [fac_v]
        mov     [bx], al
        mov     ax, [fac_v+1]
        mov     [bx+1], ax
        ret

; coerce_fac: CL = type cible; FAC -> ce type (TM si chaine/nombre incompatibles)
coerce_fac:
        cmp     cl, TY_STR
        jne     .n
        jmp     need_str
.n:
        call    need_num
        cmp     cl, TY_INT
        je      fac_int
        jmp     fac_sng

; var_load: variable/tableau a [SI] -> FAC
var_load:
        call    var_ref
        jmp     load_slot

; var_ref: [SI] sur une lettre -> BX = adresse de la valeur, CL = type (aussi dans b_bb3); SI avance.
; ROM 1.5: une variable SIMPLE du programme n'est cherchee qu'une fois (cache BC_VAR, cle = adresse du
; nom dans le texte; les variables simples ne bougent pas: une nouvelle s'insere avant les tableaux).
; Sur un succes du cache, b_word/b_wlen ne sont pas recharges (aucun appelant ne s'en sert).
var_ref:
        mov     word [b_vck], 0
        mov     bx, si
        and     bx, 63
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        add     bx, BC_VAR
        cmp     [bx], si
        jne     .miss
        mov     ax, [bx+4]              ; AL = longueur, AH = type
        test    ah, 80h
        jnz     .hit_arr
        mov     cl, ah
        mov     [b_bb3], ah
        xor     ah, ah
        add     si, ax
        mov     bx, [bx+2]
        ret
.hit_arr:
        mov     cx, [bx+6]
        cmp     cx, [b_agen]
        jne     .miss                   ; le tableau a bouge: recherche normale
        and     ah, 7Fh
        mov     cl, ah                  ; CL = type
        push    si                      ; debut du nom (comme le chemin lent)
        xor     ah, ah
        add     si, ax                  ; SI apres '('
        mov     bx, [bx+2]              ; BX = entete
        mov     word [b_vck], 0         ; rien a remplir
        ; ROM 1.6: un seul indice deja vu (variable simple ou constante entiere des caches), suivi de ')':
        ; lu directement (meme conversion que fac_i16), sans l'evaluateur ni le contexte sur la pile
        mov     di, si
        and     di, 63
        shl     di, 1
        shl     di, 1
        shl     di, 1
        cmp     [di+BC_VAR], si
        je      .fx_v
        cmp     [di+BC_NUM], si
        jne     .arr_go
        mov     ax, [di+BC_NUM+2]       ; AL = longueur, AH = type
        cmp     ah, TY_INT
        jne     .arr_go
        mov     dx, [di+BC_NUM+4]       ; DX = indice
        mov     di, si
        xor     ah, ah
        add     di, ax                  ; DI = apres la constante
        cmp     byte [di], ')'
        jne     .arr_go
        mov     ax, dx
        mov     dx, di
        jmp     .fx_ok
.fx_v:
        mov     ax, [di+BC_VAR+4]       ; AL = longueur, AH = type
        mov     dx, [di+BC_VAR+2]       ; DX = adresse de la valeur
        mov     di, ax
        and     di, 00FFh
        add     di, si                  ; DI = apres le nom
        cmp     byte [di], ')'
        jne     .arr_go
        xchg    dx, di                  ; DI = valeur, DX = ')'
        cmp     ah, TY_INT
        jne     .fx_s
        mov     ax, [di]
        jmp     .fx_ok
.fx_s:
        cmp     ah, TY_SNG
        jne     .arr_go                 ; chaine ou tableau: chemin normal (erreur, ou indices)
        push    cx
        push    dx
        push    bx
        mov     ax, [di]
        mov     [fac_v], ax
        mov     ax, [di+2]
        mov     [fac_v+2], ax
        mov     word [fac_t], TY_SNG
        mov     al, 1
        call    fl_to_i16               ; (comme fac_i16)
        pop     bx
        pop     dx
        pop     cx
        jnc     .fx_ok
        ERROR   ERR_OV
.fx_ok:                                 ; AX = indice, DX -> ')', BX = entete, CL = type
        mov     [b_idx], ax
        inc     dx
        mov     [b_t7], dx              ; SI final
        mov     [b_bb3], cl
        add     sp, 2                   ; debut du nom
        mov     cx, 1
        call    arr_elem_at
        jmp     .fin
.miss:
        cmp     si, B_TXT
        jb      .slow
        cmp     si, [b_vartab]
        jae     .slow
        mov     [b_vck], bx
.slow:
        mov     [b_vks], si
        push    si                      ; debut du nom
        call    parse_name
        SKIPSP
        cmp     al, '('
        je      .arr
        add     sp, 2
        push    si
        call    find_var
        pop     si
        mov     cl, [b_bb3]
        mov     di, [b_vck]
        or      di, di
        jz      .r
        mov     ax, si
        sub     ax, [b_vks]
        or      ah, ah
        jnz     .r
        mov     ah, cl
        mov     [di+4], ax
        mov     [di+2], bx
        mov     ax, [b_vks]
        mov     [di], ax
.r:
        ret
.arr:
        inc     si
        xor     bx, bx                  ; entete inconnu
        mov     cl, [b_bb3]
.arr_go:                                ; BX = entete (0 = inconnu), CL = type, SI apres '('; pile: [debut du nom]
        push    word [b_vck]            ; (les indices peuvent appeler var_ref: contexte sur la pile)
        push    bx
        push    word [b_agen]
        push    si
        push    cx
        xor     cx, cx
.idx:
        cmp     cx, 8
        jb      .i1
        ERROR   ERR_SN
.i1:
        push    cx
        call    eval_int
        pop     cx
        push    ax
        inc     cx
        call    skip_sp
        cmp     al, ','
        jne     .idone
        inc     si
        jmp     .idx
.idone:
        cmp     al, ')'
        je      .close
        ERROR   ERR_SN
.close:
        inc     si
        mov     [b_t7], si              ; SI final
        mov     [b_t8], cx
        mov     bx, cx
        shl     bx, 1
.pop:
        sub     bx, 2
        pop     ax
        mov     [b_idx + bx], ax
        jnz     .pop
        pop     ax                      ; AL = type
        mov     [b_bb3], al
        pop     dx                      ; DX = SI apres '('
        pop     ax                      ; generation du tableau connu
        pop     bx                      ; entete (0 = inconnu)
        pop     di                      ; case du cache (0 = rien)
        pop     si                      ; debut du nom
        mov     cx, [b_t8]
        or      bx, bx
        jz      .find
        cmp     ax, [b_agen]
        jne     .find                   ; les indices ont cree une variable: le tableau a bouge
        call    arr_elem_at             ; BX = adresse de l'element
        jmp     .fin
.find:
        push    di
        push    dx
        push    si
        call    parse_name              ; recharge b_word / b_wlen / b_bb3
        pop     si                      ; debut du nom (b_vks a pu changer: indices)
        mov     cx, [b_t8]
        call    arr_element             ; BX = adresse de l'element, b_vae = entete
        pop     dx
        pop     di
        or      di, di
        jz      .fin
        mov     ax, dx
        sub     ax, si
        or      ah, ah
        jnz     .fin
        mov     ah, [b_bb3]
        or      ah, 80h
        mov     [di+4], ax
        mov     ax, [b_vae]
        mov     [di+2], ax
        mov     ax, [b_agen]
        mov     [di+6], ax
        mov     [di], si
.fin:
        mov     si, [b_t7]
        mov     cl, [b_bb3]
        ret

; var_skip: SI sur une variable SIMPLE connue du cache -> SI apres (comme skip_target), BX = adresse
; de la valeur, CL = type, CF = 0; sinon CF = 1, SI inchange. Detruit AX, BX, CL.
var_skip:
        mov     bx, si
        and     bx, 63
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        add     bx, BC_VAR
        cmp     [bx], si
        jne     .no
        mov     ax, [bx+4]
        test    ah, 80h
        jnz     .no
        mov     cl, ah
        xor     ah, ah
        add     si, ax
        mov     bx, [bx+2]
        clc
        ret
.no:
        stc
        ret

; ------------------------------------------------------------
; Tableaux
; ------------------------------------------------------------
; elt_size: taille d'un element selon [b_bb3] -> AX
elt_size:
        mov     ax, 4
        cmp     byte [b_bb3], TY_INT
        jne     .r
        mov     ax, 2
.r:
        ret

; arr_find: recherche b_word/b_wlen/b_bb3 dans les tableaux.
; Retour BX = debut de l'entree, ZF=1 si trouve.
arr_find:
        mov     bx, [b_arytab]
.l:
        cmp     bx, [b_strend]
        jae     .no
        mov     cl, [bx+1]
        xor     ch, ch
        mov     al, [bx]
        cmp     al, [b_bb3]
        jne     .next
        cmp     cl, [b_wlen]
        jne     .next
        push    bx
        add     bx, 2
        mov     di, b_word
        mov     dx, cx
.c:
        mov     al, [bx]
        cmp     al, [di]
        jne     .cn
        inc     bx
        inc     di
        dec     dx
        jnz     .c
        pop     bx
        xor     ax, ax                  ; ZF = 1
        ret
.cn:
        pop     bx
.next:
        mov     di, bx
        add     di, cx
        mov     ax, [di+2]              ; taille de l'entree
        add     bx, ax
        jmp     .l
.no:
        mov     ax, 1
        or      ax, ax                  ; ZF = 0
        ret

; arr_element: CX = nombre d'indices (dans b_idx); nom dans b_word. Retour
; BX = adresse de l'element. Cree le tableau (bornes 10) s'il n'existe pas.
; Preserve SI.
arr_element:
        push    cx
        call    arr_find
        pop     cx
        jz      arr_elem_at
        push    cx
        mov     bx, 0
        mov     ax, 10
.fb:
        mov     [b_bnd + bx], ax
        add     bx, 2
        loop    .fb
        pop     cx
        push    cx
        call    arr_create
        pop     cx
; arr_elem_at: BX = entete du tableau, CX = nombre d'indices (b_idx) -> BX = adresse de l'element
; (b_vae = entete). Type dans b_bb3. Preserve SI.
arr_elem_at:
        mov     [b_vae], bx
        mov     al, [bx+1]
        xor     ah, ah
        mov     di, bx
        add     di, ax
        add     di, 2                   ; DI -> taille
        mov     al, [di+2]              ; ndims
        xor     ah, ah
        cmp     ax, cx
        je      .nd
        ERROR   ERR_BS
.nd:
        add     di, 3                   ; DI -> bornes
        xor     ax, ax                  ; index lineaire
        xor     bx, bx
.k:
        mov     dx, [b_idx + bx]
        cmp     dx, [di]                ; non signe: negatif = tres grand
        jbe     .in
        ERROR   ERR_BS
.in:
        or      ax, ax                  ; ROM 1.6: pas de MUL tant que l'index lineaire est nul
        jz      .z
        push    dx
        mov     dx, [di]
        inc     dx
        mul     dx
        pop     dx
.z:
        add     ax, dx
        add     di, 2
        add     bx, 2
        loop    .k
        shl     ax, 1                   ; ROM 1.6: x taille de l'element (2 ou 4) par decalages
        cmp     byte [b_bb3], TY_INT
        je      .i2
        shl     ax, 1
.i2:
        add     ax, di                  ; DI = debut des elements
        mov     bx, ax
        ret

; arr_create: CX = nombre de dimensions, bornes dans b_bnd, nom dans b_word.
; Cree le tableau (elements a zero). Retour BX = debut de l'entree. Preserve SI.
arr_create:
        inc     word [b_agen]           ; (cache des variables)
        push    si
        mov     [b_t3], cx
        mov     ax, 1
        xor     bx, bx
.p:
        mov     dx, [b_bnd + bx]
        inc     dx
        mul     dx
        jc      .om
        add     bx, 2
        loop    .p
        mov     [b_t4], ax              ; nombre d'elements
        call    elt_size
        mul     word [b_t4]
        jc      .om
        mov     [b_t5], ax              ; octets de donnees
        mov     bx, [b_t3]
        shl     bx, 1
        add     ax, bx
        jc      .om
        mov     cl, [b_wlen]
        xor     ch, ch
        add     ax, cx
        jc      .om
        add     ax, 5                   ; type + len + taille(2) + ndims
        jc      .om
        mov     [b_t6], ax              ; taille de l'entree
        add     ax, [b_strend]
        jc      .om
        call    mem_check
        mov     di, [b_strend]
        mov     bx, di
        mov     al, [b_bb3]
        stosb
        mov     al, [b_wlen]
        stosb
        mov     si, b_word
        mov     cl, [b_wlen]
        xor     ch, ch
        rep     movsb
        mov     ax, [b_t6]
        stosw
        mov     al, [b_t3]
        stosb
        mov     cx, [b_t3]
        xor     dx, dx
.b:
        mov     si, dx
        mov     ax, [b_bnd + si]
        stosw
        add     dx, 2
        loop    .b
        mov     cx, [b_t5]
        xor     al, al
        rep     stosb
        mov     [b_strend], di
        pop     si
        ret
.om:
        ERROR   ERR_OM

; ------------------------------------------------------------
; Operateurs: AL = identifiant; FAC = ARG op FAC
; ------------------------------------------------------------
apply_op:
        cmp     al, 6
        jb      .logic
        cmp     al, 11
        jbe     op_rel
        cmp     al, 12
        je      op_add
        cmp     al, 13
        je      op_sub
        cmp     al, 16
        je      op_mul
        cmp     al, 17
        je      op_div
        cmp     al, 18
        je      op_pow
        cmp     al, 14
        je      op_mod
        jmp     op_idiv
.logic:
        mov     [b_bb1], al
        cmp     byte [arg_t], TY_STR
        jne     .a
        ERROR   ERR_TM
.a:
        cmp     byte [fac_t], TY_STR
        jne     .b
        ERROR   ERR_TM
.b:
        call    fac_i16
        push    ax
        call    xchg_fa
        call    fac_i16
        mov     bx, ax                  ; BX = gauche
        pop     cx                      ; CX = droite
        mov     al, [b_bb1]
        cmp     al, 5
        jne     .n5
        and     bx, cx
        jmp     .r
.n5:
        cmp     al, 4
        jne     .n4
        or      bx, cx
        jmp     .r
.n4:
        cmp     al, 3
        jne     .n3
        xor     bx, cx
        jmp     .r
.n3:
        cmp     al, 2
        jne     .n2
        xor     bx, cx
        not     bx                      ; EQV
        jmp     .r
.n2:
        not     bx                      ; IMP = (NOT gauche) OR droite
        or      bx, cx
.r:
        mov     ax, bx
        jmp     fac_set_int

; --- comparaisons -> -1 / 0 (entier) ---
op_rel:
        mov     [b_bb1], al
        mov     al, [arg_t]
        cmp     al, TY_STR
        je      .sa
        cmp     byte [fac_t], TY_STR
        jne     .num
        ERROR   ERR_TM
.sa:
        cmp     byte [fac_t], TY_STR
        je      .strs
        ERROR   ERR_TM
.strs:
        call    str_cmp                 ; AL = -1/0/1
        jmp     .res
.num:
        mov     al, [arg_t]
        cmp     al, TY_INT
        jne     .fl
        cmp     byte [fac_t], TY_INT
        jne     .fl
        mov     ax, [arg_v]
        cmp     ax, [fac_v]
        je      .eq
        jl      .lt
        mov     al, 1
        jmp     .res
.lt:
        mov     al, 0FFh
        jmp     .res
.eq:
        xor     al, al
        jmp     .res
.fl:
        call    fac_sng
        call    arg_sng
        call    fl_cmp
.res:
        mov     ah, [b_bb1]             ; 6 = 7 < 8 > 9 <= 10 >= 11 <>
        xor     bx, bx                  ; resultat faux
        cmp     ah, 6
        jne     .r7
        or      al, al
        jnz     .out
        dec     bx
        jmp     .out
.r7:
        cmp     ah, 7
        jne     .r8
        cmp     al, 0FFh
        jne     .out
        dec     bx
        jmp     .out
.r8:
        cmp     ah, 8
        jne     .r9
        cmp     al, 1
        jne     .out
        dec     bx
        jmp     .out
.r9:
        cmp     ah, 9
        jne     .r10
        cmp     al, 1
        je      .out
        dec     bx
        jmp     .out
.r10:
        cmp     ah, 10
        jne     .r11
        cmp     al, 0FFh
        je      .out
        dec     bx
        jmp     .out
.r11:
        or      al, al
        jz      .out
        dec     bx
.out:
        mov     ax, bx
        jmp     fac_set_int

; --- + ---
op_add:
        mov     al, [arg_t]
        cmp     al, TY_STR
        je      .sa
        cmp     byte [fac_t], TY_STR
        jne     .n
        ERROR   ERR_TM
.sa:
        cmp     byte [fac_t], TY_STR
        je      str_concat
        ERROR   ERR_TM
.n:
        cmp     al, TY_INT
        jne     .f
        cmp     byte [fac_t], TY_INT
        jne     .f
        mov     ax, [arg_v]
        add     ax, [fac_v]
        jo      .f
        jmp     fac_set_int
.f:
        call    fac_sng
        call    arg_sng
        call    fl_add
        jc      .ov
        mov     word [fac_t], TY_SNG
        ret
.ov:
        ERROR   ERR_OV

op_sub:
        mov     al, [arg_t]
        cmp     al, TY_STR
        jne     .a
        ERROR   ERR_TM
.a:
        cmp     byte [fac_t], TY_STR
        jne     .b
        ERROR   ERR_TM
.b:
        cmp     al, TY_INT
        jne     .f
        cmp     byte [fac_t], TY_INT
        jne     .f
        mov     ax, [arg_v]
        sub     ax, [fac_v]
        jo      .f
        jmp     fac_set_int
.f:
        call    fac_sng
        call    arg_sng
        call    fl_sub
        jc      .ov
        mov     word [fac_t], TY_SNG
        ret
.ov:
        ERROR   ERR_OV

op_mul:
        mov     al, [arg_t]
        cmp     al, TY_STR
        jne     .a
        ERROR   ERR_TM
.a:
        cmp     byte [fac_t], TY_STR
        jne     .b
        ERROR   ERR_TM
.b:
        cmp     al, TY_INT
        jne     .f
        cmp     byte [fac_t], TY_INT
        jne     .f
        mov     ax, [arg_v]
        imul    word [fac_v]
        jo      .f
        jmp     fac_set_int
.f:
        call    fac_sng
        call    arg_sng
        call    fl_mul
        jc      .ov
        mov     word [fac_t], TY_SNG
        ret
.ov:
        ERROR   ERR_OV

op_div:
        cmp     byte [arg_t], TY_STR
        jne     .a
        ERROR   ERR_TM
.a:
        cmp     byte [fac_t], TY_STR
        jne     .b
        ERROR   ERR_TM
.b:
        call    fac_sng
        call    arg_sng
        call    fl_div
        jc      .e
        mov     word [fac_t], TY_SNG
        ret
.e:
        cmp     byte [fl_dz], 0
        je      .ov
        ERROR   ERR_DZ
.ov:
        ERROR   ERR_OV

op_pow:
        cmp     byte [arg_t], TY_STR
        jne     .a
        ERROR   ERR_TM
.a:
        cmp     byte [fac_t], TY_STR
        jne     .b
        ERROR   ERR_TM
.b:
        call    fac_sng
        call    arg_sng
        call    fl_pow
        jc      .e
        mov     word [fac_t], TY_SNG
        ret
.e:
        jmp     bas_error               ; AL = code d'erreur de la bibliotheque

; --- \ et MOD (entiers) ---
op_idiv:
        mov     byte [b_bb1], 0
        jmp     idivmod
op_mod:
        mov     byte [b_bb1], 1
idivmod:
        cmp     byte [arg_t], TY_STR
        jne     .a
        ERROR   ERR_TM
.a:
        cmp     byte [fac_t], TY_STR
        jne     .b
        ERROR   ERR_TM
.b:
        call    fac_i16
        push    ax                      ; diviseur
        call    xchg_fa
        call    fac_i16                 ; AX = dividende
        pop     cx
        or      cx, cx
        jnz     .ok
        ERROR   ERR_DZ
.ok:
        cmp     cx, -1
        jne     .div
        cmp     byte [b_bb1], 0
        jne     .zero                   ; MOD -1 = 0
        cmp     ax, 8000h
        jne     .neg
        ERROR   ERR_OV
.neg:
        neg     ax
        jmp     fac_set_int
.zero:
        xor     ax, ax
        jmp     fac_set_int
.div:
        cwd
        idiv    cx
        cmp     byte [b_bb1], 0
        je      .q
        mov     ax, dx                  ; reste
.q:
        jmp     fac_set_int
