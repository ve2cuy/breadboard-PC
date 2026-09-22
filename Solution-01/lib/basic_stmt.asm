; ============================================================
; basic_stmt.asm - programme, boucle d'execution et instructions (lib/basic.asm)
; Programme: [lien:2][numero:2][jetons...][0] ...; fin = mot 0 a b_vartab-2.
; Cadres de pile (sommet = sp): voir FR_* dans basic.asm.
;   GOSUB/WHILE: [marqueur][SI][ligne][adresse de ligne]                (4 mots)
;   FOR: [marqueur][variable][type|signe du pas<<8][pas:2][limite:2]
;        [SI][ligne][adresse de ligne]                                  (10 mots)
; ============================================================

; ------------------------------------------------------------
; NEW / CLEAR
; ------------------------------------------------------------
bas_new:
        mov     word [B_TXT], 0
        mov     word [b_vartab], B_TXT + 2
        mov     word [b_oldptr], 0
        ; (continue: efface les variables)
bas_clear:
        mov     ax, [b_vartab]
        mov     [b_arytab], ax
        mov     [b_strend], ax
        mov     word [b_fretop], B_STRTOP
        mov     word [b_vsp], B_VSTK
        mov     word [b_datptr], 0
        mov     byte [b_datmode], 0
        mov     byte [b_nfn], 0
        mov     word [fac_t], TY_INT
        mov     word [arg_t], TY_INT
        mov     di, b_deftbl
        mov     cx, 26
        mov     al, TY_SNG
        rep     stosb
        ret

; ------------------------------------------------------------
; Programme: recherche, suppression, insertion
; ------------------------------------------------------------
; find_line: AX = numero -> BX = premiere ligne de numero >= AX (ou la fin);
; ZF = 1 si la ligne existe exactement.
find_line:
        mov     bx, B_TXT
.l:
        mov     dx, [bx]
        or      dx, dx
        jz      .end
        cmp     [bx+2], ax
        jae     .found
        mov     bx, dx
        jmp     .l
.found:
        ret                             ; ZF de CMP
.end:
        xor     dx, dx
        inc     dx                      ; ZF = 0
        ret

; relink: recalcule tous les liens de lignes.
relink:
        mov     bx, B_TXT
        mov     dx, [b_vartab]
        sub     dx, 2
.l:
        cmp     bx, dx
        jae     .done
        lea     di, [bx+4]
.s:
        cmp     byte [di], 0
        je      .e
        inc     di
        jmp     .s
.e:
        inc     di
        mov     [bx], di
        mov     bx, di
        jmp     .l
.done:
        mov     bx, dx
        mov     word [bx], 0
        ret

; del_line: BX = adresse de la ligne a supprimer.
del_line:
        mov     dx, [bx]
        mov     ax, dx
        sub     ax, bx                  ; taille de la ligne
        push    ax
        mov     si, dx
        mov     di, bx
        mov     cx, [b_vartab]
        sub     cx, dx
        rep     movsb
        pop     ax
        sub     [b_vartab], ax
        jmp     relink

; prog_edit: insere/remplace/supprime la ligne b_lineno (corps dans B_TBUF).
prog_edit:
        mov     byte [b_bb2], 0         ; 1 si la ligne existait
        mov     ax, [b_lineno]
        mov     [b_lastln], ax
        call    find_line
        jnz     .noold
        mov     byte [b_bb2], 1
        call    del_line
.noold:
        cmp     byte [B_TBUF], 0
        jne     .ins
        cmp     byte [b_bb2], 0
        jne     .fin
        ERROR   ERR_UL                  ; suppression d'une ligne inexistante
.ins:
        mov     di, B_TBUF
        xor     cx, cx
.len:
        cmp     byte [di], 0
        je      .lend
        inc     di
        inc     cx
        jmp     .len
.lend:
        add     cx, 5                   ; lien + numero + corps + zero
        mov     [b_t6], cx
        mov     ax, [b_vartab]
        add     ax, cx
        jc      .om
        cmp     ax, B_STRTOP - 1024
        jb      .room
.om:
        ERROR   ERR_OM
.room:
        mov     ax, [b_lineno]
        call    find_line               ; BX = point d'insertion
        mov     si, [b_vartab]
        dec     si
        mov     di, si
        add     di, [b_t6]
        mov     cx, [b_vartab]
        sub     cx, bx
        std
        rep     movsb
        cld
        mov     ax, [b_lineno]
        mov     [bx+2], ax
        lea     di, [bx+4]
        mov     si, B_TBUF
        mov     cx, [b_t6]
        sub     cx, 4
        rep     movsb
        mov     ax, [b_t6]
        add     [b_vartab], ax
        call    relink
.fin:
        call    bas_clear
        mov     word [b_stkbase], B_STK
        mov     word [b_oldptr], 0
        ret

; parse_lineno: SI -> AX = numero de ligne; CF = 1 si pas de chiffre.
parse_lineno:
        call    skip_sp
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        ja      .no
        xor     bx, bx
.l:
        mov     al, [si]
        cmp     al, '0'
        jb      .d
        cmp     al, '9'
        ja      .d
        sub     al, '0'
        xor     ah, ah
        mov     cx, ax
        mov     ax, bx
        mov     dx, 10
        mul     dx
        jc      .sn
        add     ax, cx
        jc      .sn
        mov     bx, ax
        inc     si
        jmp     .l
.d:
        mov     ax, bx
        cmp     ax, 65529
        ja      .sn
        clc
        ret
.no:
        stc
        ret
.sn:
        ERROR   ERR_SN

; ------------------------------------------------------------
; Boucle d'execution
; ------------------------------------------------------------
; bas_stmt: SI = debut d'une instruction.
bas_stmt:
        mov     word [fac_t], TY_INT
        call    bas_chkbrk
.again:
        call    skip_sp
        or      al, al
        jz      bas_eol
        cmp     al, ':'
        jne     .n1
        inc     si
        jmp     .again
.n1:
        cmp     al, T_MIDS
        je      st_mids
        cmp     al, T_TIMES
        je      st_timeset
        cmp     al, T_DATES
        je      st_dateset
        cmp     al, 80h
        jb      st_let                  ; affectation implicite
        cmp     al, T_SQ
        jbe     .tok
        ERROR   ERR_SN
.tok:
        inc     si
        sub     al, 80h
        xor     ah, ah
        shl     ax, 1
        mov     bx, ax
        jmp     [cs:tok_handlers + bx]

; bas_newstt: fin d'instruction: ':' = suite, 0 = ligne suivante, ELSE = fin de ligne.
bas_newstt:
        call    skip_sp
        cmp     al, ':'
        jne     .n1
        inc     si
        jmp     bas_stmt
.n1:
        or      al, al
        jz      bas_eol
        cmp     al, T_ELSE
        je      .else
        cmp     al, T_SQ
        je      .else
        ERROR   ERR_SN
.else:
        cmp     byte [si], 0
        je      bas_eol
        inc     si
        jmp     .else

; bas_eol: passe a la ligne suivante (ou retourne au "Ok").
bas_eol:
        mov     bx, [b_curptr]
        or      bx, bx
        jz      .ready
        mov     bx, [bx]
        cmp     word [bx], 0
        je      .end
        mov     [b_curptr], bx
        mov     ax, [bx+2]
        mov     [b_curlin], ax
        lea     si, [bx+4]
        cmp     byte [b_tron], 0
        je      bas_stmt
        call    trace_line
        jmp     bas_stmt
.end:
        call    file_end                ; fin du programme: ferme le fichier de donnees
        mov     word [b_stkbase], B_STK
.ready:
        jmp     bas_ready

trace_line:
        mov     al, '['
        call    bas_putc
        mov     ax, [b_curlin]
        call    print_uint
        mov     al, ']'
        jmp     bas_putc

; goto_line: AX = numero de ligne -> continue l'execution a cette ligne.
goto_line:
        call    find_line
        je      .ok
        ERROR   ERR_UL
.ok:
        mov     [b_curptr], bx
        mov     ax, [bx+2]
        mov     [b_curlin], ax
        lea     si, [bx+4]
        mov     byte [b_run], 1
        cmp     byte [b_tron], 0
        je      bas_stmt
        call    trace_line
        jmp     bas_stmt

; skip_stmt: SI avance jusqu'a ':' (hors guillemets) ou 0.
skip_stmt:
        xor     dl, dl
.l:
        mov     al, [si]
        or      al, al
        jz      .d
        cmp     al, '"'
        jne     .nq
        xor     dl, 1
        jmp     .a
.nq:
        cmp     al, ':'
        jne     .a
        or      dl, dl
        jz      .d
.a:
        inc     si
        jmp     .l
.d:
        ret

; ------------------------------------------------------------
; Instructions simples
; ------------------------------------------------------------
st_rem:
.l:
        cmp     byte [si], 0
        je      bas_newstt
        inc     si
        jmp     .l

st_data:
        call    skip_stmt
        jmp     bas_newstt

st_end:
        call    file_end                ; END ferme le fichier de donnees
        mov     word [b_stkbase], B_STK
        jmp     bas_ready

st_stop:
        jmp     bas_break

st_cont:
        mov     ax, [b_oldptr]
        or      ax, ax
        jnz     .ok
        ERROR   ERR_CN
.ok:
        mov     [b_curptr], ax
        mov     ax, [b_oldlin]
        mov     [b_curlin], ax
        mov     si, [b_oldsi]
        mov     word [b_oldptr], 0
        mov     byte [b_run], 1
        jmp     bas_stmt

st_system:
        jmp     bas_exit

st_new:
        call    file_close_all
        call    bas_new
        mov     word [b_stkbase], B_STK
        jmp     bas_ready

st_clear:
        call    skip_stmt               ; arguments (taille de pile...) ignores
        call    file_close_all
        call    bas_clear
        mov     word [b_stkbase], B_STK
        mov     sp, B_STK
        jmp     bas_newstt

st_run:
        call    file_close_all          ; RUN ferme les fichiers
        call    skip_sp
        cmp     al, '"'
        jne     .nolit
        cmp     word [b_curlin], 0FFFFh ; RUN "fichier": charge puis lance (mode direct)
        je      .dok
        ERROR   ERR_ID
.dok:
        mov     dl, 1
        call    disk_name
        mov     byte [b_dmode], 0
        call    disk_load
        mov     ax, 0FFFFh
        jmp     .have
.nolit:
        call    parse_lineno
        jnc     .have
        mov     ax, 0FFFFh              ; pas de numero: premiere ligne
.have:
        mov     [b_t5], ax
        call    bas_clear
        mov     word [b_stkbase], B_STK
        mov     sp, B_STK
        mov     word [b_oldptr], 0
        mov     ax, [b_t5]
        cmp     ax, 0FFFFh
        jne     goto_line
        cmp     word [B_TXT], 0
        je      bas_ready               ; programme vide
        mov     ax, [B_TXT+2]
        jmp     goto_line

st_goto:
        call    parse_lineno
        jnc     goto_line
        ERROR   ERR_SN

st_gosub:
        call    parse_lineno
        jnc     .ok
        ERROR   ERR_SN
.ok:
        STKCHK
        push    word [b_curptr]
        push    word [b_curlin]
        push    si
        mov     cx, FR_GOSUB
        push    cx
        jmp     goto_line

st_return:
.l:
        cmp     sp, B_STK
        jb      .c
        ERROR   ERR_RG
.c:
        pop     ax
        cmp     ax, FR_GOSUB
        je      .g
        cmp     ax, FR_FOR
        je      .f
        add     sp, 6                   ; cadre WHILE
        jmp     .l
.f:
        add     sp, 18
        jmp     .l
.g:
        pop     si
        pop     ax
        mov     [b_curlin], ax
        pop     ax
        mov     [b_curptr], ax
        jmp     bas_newstt

st_tron:
        mov     byte [b_tron], 1
        jmp     bas_newstt
st_troff:
        mov     byte [b_tron], 0
        jmp     bas_newstt

; HELP: sommaire des commandes
st_help:
        push    si                      ; pointeur de texte
        mov     si, msg_help
        call    bas_puts_cs
        pop     si
        jmp     bas_newstt

st_beep:
        mov     al, 7
        call    uart_tx_byte
        jmp     bas_newstt

st_cls:
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, '2'
        call    uart_tx_byte
        mov     al, 'J'
        call    uart_tx_byte
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, 'H'
        call    uart_tx_byte
        mov     byte [b_col], 0
        jmp     bas_newstt

; ansi_num: AX -> chiffres decimaux envoyes directement au terminal
ansi_num:
        mov     di, B_NBUF
        mov     bx, 10
        call    put_ubase
        mov     cx, di
        sub     cx, B_NBUF
        mov     bx, B_NBUF
.l:
        mov     al, [bx]
        call    uart_tx_byte
        inc     bx
        loop    .l
        ret

; LOCATE ligne, colonne
st_locate:
        call    eval_int
        cmp     ax, 1
        jl      .fc
        cmp     ax, 255
        jg      .fc
        push    ax
        call    arg_comma
        call    eval_int
        cmp     ax, 1
        jl      .fc
        cmp     ax, 255
        jg      .fc
        pop     dx                      ; DX = ligne, AX = colonne
        push    ax
        push    dx
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        pop     ax
        call    ansi_num
        mov     al, ';'
        call    uart_tx_byte
        pop     ax
        mov     [b_col], al
        dec     byte [b_col]
        call    ansi_num
        mov     al, 'H'
        call    uart_tx_byte
        jmp     bas_newstt
.fc:
        ERROR   ERR_FC

; ansi_sgr: AX = code -> ESC [ code m
ansi_sgr:
        push    ax
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        pop     ax
        call    ansi_num
        mov     al, 'm'
        jmp     uart_tx_byte

; COLOR avant-plan [, fond]  (couleurs GW-BASIC 0-15 -> ANSI)
st_color:
        call    eval_int
        cmp     ax, 0
        jl      .fc
        cmp     ax, 15
        jg      .fc
        mov     dx, ax
        mov     bx, ax
        and     bx, 7
        mov     al, [cs:ansi_colors + bx]
        mov     ah, 30
        cmp     dl, 8
        jb      .fg
        mov     ah, 90
.fg:
        add     al, ah
        xor     ah, ah
        call    ansi_sgr
        call    skip_sp
        cmp     al, ','
        jne     bas_newstt
        inc     si
        call    eval_int
        cmp     ax, 0
        jl      .fc
        cmp     ax, 7
        jg      .fc
        mov     bx, ax
        mov     al, [cs:ansi_colors + bx]
        add     al, 40
        xor     ah, ah
        call    ansi_sgr
        jmp     bas_newstt
.fc:
        ERROR   ERR_FC

; DEFINT / DEFSNG (DEFDBL) / DEFSTR lettre[-lettre],...
st_defint:
        mov     cl, TY_INT
        jmp     defty
st_defsng:
        mov     cl, TY_SNG
        jmp     defty
st_defstr:
        mov     cl, TY_STR
defty:
.n:
        call    skip_sp
        and     al, 0DFh
        sub     al, 'A'
        cmp     al, 26
        jb      .l1
        ERROR   ERR_SN
.l1:
        inc     si
        mov     dl, al                  ; debut
        mov     dh, al                  ; fin
        call    skip_sp
        cmp     al, '-'
        jne     .set
        inc     si
        call    skip_sp
        and     al, 0DFh
        sub     al, 'A'
        cmp     al, 26
        jb      .l2
        ERROR   ERR_SN
.l2:
        inc     si
        mov     dh, al
.set:
        cmp     dl, dh
        ja      .sn
        xor     bh, bh
        mov     bl, dl
.f:
        mov     [b_deftbl + bx], cl
        inc     bx
        cmp     bl, dh
        jbe     .f
        call    skip_sp
        cmp     al, ','
        jne     bas_newstt
        inc     si
        jmp     .n
.sn:
        ERROR   ERR_SN

; ------------------------------------------------------------
; LET
; ------------------------------------------------------------
; skip_target: SI sur une variable (nom, suffixe, indices) -> SI apres.
skip_target:
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'A'
        jb      .sn
        cmp     al, 'Z'
        ja      .sn
.n:
        inc     si
        mov     al, [si]
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .d
        cmp     ah, 'Z'
        jbe     .n
.d:
        cmp     al, '0'
        jb      .suf
        cmp     al, '9'
        jbe     .n
.suf:
        cmp     al, '$'
        je      .s1
        cmp     al, '%'
        je      .s1
        cmp     al, '!'
        je      .s1
        cmp     al, '#'
        jne     .par
.s1:
        inc     si
.par:
        call    skip_sp
        cmp     al, '('
        jne     .ret
        xor     cx, cx
.p:
        mov     al, [si]
        or      al, al
        jz      .sn
        inc     si
        cmp     al, '"'
        jne     .np
.q:
        mov     al, [si]
        or      al, al
        jz      .sn
        inc     si
        cmp     al, '"'
        jne     .q
        jmp     .p
.np:
        cmp     al, '('
        jne     .nc
        inc     cx
        jmp     .p
.nc:
        cmp     al, ')'
        jne     .p
        dec     cx
        jnz     .p
.ret:
        ret
.sn:
        ERROR   ERR_SN

st_let:
        call    skip_sp
        push    si                      ; debut de la cible
        call    skip_target
        call    skip_sp
        cmp     al, '='
        je      .eq
        ERROR   ERR_SN
.eq:
        inc     si
        call    eval_expr
        call    vpush_fac               ; (les indices de la cible ecrasent FAC)
        push    si                      ; fin de l'instruction
        mov     bp, sp
        mov     si, [bp+2]
        call    var_ref                 ; la cible est evaluee APRES le membre droit
        push    bx
        push    cx
        call    vpop_fac
        pop     cx
        pop     bx
        call    store_slot
        pop     si
        add     sp, 2
        mov     word [fac_t], TY_INT
        jmp     bas_newstt

; MID$(v$, debut [, n]) = expression
st_mids:
        inc     si
        call    arg_open
        call    skip_sp
        push    si                      ; debut de la variable
        call    skip_target
        call    arg_comma
        call    eval_int
        cmp     ax, 1
        jge     .s1
        ERROR   ERR_FC
.s1:
        push    ax                      ; debut
        call    skip_sp
        cmp     al, ','
        je      .haslen
        mov     ax, 255
        jmp     .nolen
.haslen:
        inc     si
        call    eval_int
        or      ax, ax
        jns     .nolen
        ERROR   ERR_FC
.nolen:
        push    ax                      ; longueur
        call    arg_close
        call    skip_sp
        cmp     al, '='
        je      .eq
        ERROR   ERR_SN
.eq:
        inc     si
        call    eval_str                ; FAC = nouveau texte
        call    vpush_fac
        push    si                      ; fin de l'instruction
        mov     bp, sp
        mov     si, [bp+6]
        call    var_ref                 ; BX = descripteur de la variable
        cmp     cl, TY_STR
        je      .ok
        ERROR   ERR_TM
.ok:
        mov     [b_t5], bx
        call    vpop_fac
        pop     si
        pop     cx                      ; longueur demandee
        pop     dx                      ; debut
        add     sp, 2
        ; n = min(cx, len(FAC), len(var) - (debut-1))
        dec     dx
        mov     bx, [b_t5]
        mov     al, [bx]
        xor     ah, ah
        sub     ax, dx
        jbe     .done
        cmp     cx, ax
        jbe     .a
        mov     cx, ax
.a:
        mov     al, [fac_v]
        xor     ah, ah
        cmp     cx, ax
        jbe     .b
        mov     cx, ax
.b:
        jcxz    .done
        ; la variable doit posseder son texte (pas un litteral): copie dans le tas
        push    cx
        push    dx
        mov     bx, [b_t5]
        mov     ax, [bx+1]
        cmp     ax, [b_fretop]
        jae     .inheap
        mov     cl, [bx]
        xor     ch, ch
        push    si
        call    str_alloc               ; BX = nouvelle zone (FAC et la variable sont des racines)
        mov     di, bx
        mov     bx, [b_t5]
        mov     si, [bx+1]              ; relu apres l'allocation
        mov     [bx+1], di
        rep     movsb
        pop     si
.inheap:
        pop     dx
        pop     cx
        mov     di, [b_t5]
        mov     di, [di+1]
        add     di, dx
        push    si
        mov     si, [fac_v+1]
        rep     movsb
        pop     si
.done:
        mov     word [fac_t], TY_INT
        jmp     bas_newstt

; ------------------------------------------------------------
; SWAP, DIM, ERASE
; ------------------------------------------------------------
st_swap:
        call    skip_sp
        push    si
        call    var_ref
        call    arg_comma
        call    var_ref
        push    si                      ; fin
        mov     bp, sp
        mov     si, [bp+2]
        call    var_ref                 ; 2e passe: adresses definitives
        mov     [b_t5], bx
        mov     [b_t6], cx
        call    arg_comma
        call    var_ref
        cmp     cl, [b_t6]
        je      .ok
        ERROR   ERR_TM
.ok:
        mov     di, [b_t5]
        mov     ax, [bx]
        xchg    ax, [di]
        mov     [bx], ax
        mov     ax, [bx+2]
        xchg    ax, [di+2]
        mov     [bx+2], ax
        pop     si
        add     sp, 2
        jmp     bas_newstt

st_dim:
.next:
        call    skip_sp
        push    si                      ; debut du nom
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'A'
        jb      .sn
        cmp     al, 'Z'
        ja      .sn
        call    parse_name
        call    skip_sp
        cmp     al, '('
        jne     .sn
        inc     si
        xor     cx, cx
.b:
        cmp     cx, 8
        jb      .b1
.sn:
        ERROR   ERR_SN
.b1:
        push    cx
        call    eval_int
        pop     cx
        or      ax, ax
        jns     .b2
        ERROR   ERR_FC
.b2:
        push    ax
        inc     cx
        call    skip_sp
        cmp     al, ','
        jne     .bd
        inc     si
        jmp     .b
.bd:
        cmp     al, ')'
        jne     .sn
        inc     si
        mov     [b_t7], si
        mov     [b_t8], cx
        mov     bx, cx
        shl     bx, 1
.pop:
        sub     bx, 2
        pop     ax
        mov     [b_bnd + bx], ax
        jnz     .pop
        pop     si
        call    parse_name
        call    arr_find
        jnz     .new
        ERROR   ERR_DD
.new:
        mov     cx, [b_t8]
        call    arr_create
        mov     si, [b_t7]
        call    skip_sp
        cmp     al, ','
        jne     bas_newstt
        inc     si
        jmp     .next

st_erase:
.next:
        call    skip_sp
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'A'
        jb      .fc
        cmp     al, 'Z'
        ja      .fc
        call    parse_name
        call    arr_find
        jz      .del
.fc:
        ERROR   ERR_FC
.del:
        mov     cl, [bx+1]
        xor     ch, ch
        mov     di, bx
        add     di, cx
        mov     ax, [di+2]              ; taille de l'entree
        mov     di, bx
        mov     dx, si
        mov     si, bx
        add     si, ax
        mov     cx, [b_strend]
        sub     cx, si
        push    ax
        rep     movsb
        pop     ax
        sub     [b_strend], ax
        mov     si, dx
        call    skip_sp
        cmp     al, ','
        jne     bas_newstt
        inc     si
        jmp     .next

; ------------------------------------------------------------
; PRINT
; ------------------------------------------------------------
print_zone:
        mov     al, [b_col]
        xor     ah, ah
        mov     cl, 14
        div     cl
        mov     cl, 14
        sub     cl, ah
.l:
        mov     al, ' '
        call    bas_putc
        dec     cl
        jnz     .l
        ret

; print_spc: AX = nombre d'espaces (0..255)
print_spc:
        or      ax, ax
        jle     .r
        cmp     ax, 255
        jbe     .c
        mov     ax, 255
.c:
        mov     cx, ax
.l:
        mov     al, ' '
        call    bas_putc
        loop    .l
.r:
        ret

st_print:
        mov     byte [b_pfl], 0
        call    skip_sp
        cmp     al, '#'
        jne     .item
        call    file_out_begin          ; PRINT #1,...: la sortie va au fichier
.item:
        call    skip_sp
        or      al, al
        jz      .end
        cmp     al, ':'
        je      .end
        cmp     al, T_ELSE
        je      .end
        cmp     al, T_SQ
        je      .end
        cmp     al, ';'
        jne     .n1
        inc     si
        mov     byte [b_pfl], 1
        jmp     .item
.n1:
        cmp     al, ','
        jne     .n2
        inc     si
        mov     byte [b_pfl], 1
        call    print_zone
        jmp     .item
.n2:
        cmp     al, T_TAB
        jne     .n3
        inc     si
        call    eval_int
        call    arg_close
        dec     ax
        mov     dl, [b_col]
        xor     dh, dh
        sub     ax, dx
        call    print_spc
        mov     byte [b_pfl], 0
        jmp     .item
.n3:
        cmp     al, T_SPC
        jne     .n4
        inc     si
        call    eval_int
        call    arg_close
        call    print_spc
        mov     byte [b_pfl], 0
        jmp     .item
.n4:
        call    eval_expr
        call    print_fac
        mov     byte [b_pfl], 0
        jmp     .item
.end:
        cmp     byte [b_pfl], 0
        jne     .done
        call    bas_crlf
.done:
        cmp     byte [b_fout], 0
        je      .nf
        call    file_out_end
.nf:
        jmp     bas_newstt

; ------------------------------------------------------------
; IF / ON
; ------------------------------------------------------------
; fac_zero: ZF = 1 si FAC (numerique) vaut zero
fac_zero:
        cmp     byte [fac_t], TY_STR
        jne     .n
        ERROR   ERR_TM
.n:
        mov     ax, [fac_v]
        cmp     byte [fac_t], TY_INT
        je      .i
        or      ax, [fac_v+2]
        ret
.i:
        or      ax, ax
        ret

st_if:
        call    eval_expr
        call    fac_zero
        pushf
        call    skip_sp
        cmp     al, T_THEN
        je      .then
        cmp     al, T_GOTO
        je      .go
        ERROR   ERR_SN
.then:
        inc     si
.go:
        popf
        jz      .false
        call    skip_sp
        cmp     al, '0'
        jb      bas_stmt
        cmp     al, '9'
        ja      bas_stmt
        call    parse_lineno
        jmp     goto_line
.false:
        xor     bx, bx                  ; profondeur des IF imbriques
.s:
        mov     al, [si]
        or      al, al
        jz      bas_eol                 ; pas de ELSE: ligne suivante
        cmp     al, T_IF
        jne     .ne
        inc     bx
        jmp     .a
.ne:
        cmp     al, T_ELSE
        jne     .a
        or      bx, bx
        jz      .found
        dec     bx
.a:
        inc     si
        jmp     .s
.found:
        inc     si
        call    skip_sp
        cmp     al, '0'
        jb      bas_stmt
        cmp     al, '9'
        ja      bas_stmt
        call    parse_lineno
        jmp     goto_line

st_on:
        call    eval_int
        or      ax, ax
        jns     .p
        ERROR   ERR_FC
.p:
        mov     [b_t5], ax
        call    skip_sp
        cmp     al, T_GOTO
        je      .g
        cmp     al, T_GOSUB
        je      .g
        ERROR   ERR_SN
.g:
        mov     [b_bb1], al
        inc     si
        mov     word [b_t6], 0
        mov     word [b_t7], 0
.l:
        call    parse_lineno
        jnc     .n
        ERROR   ERR_SN
.n:
        inc     word [b_t6]
        mov     cx, [b_t6]
        cmp     cx, [b_t5]
        jne     .nx
        mov     [b_t7], ax
.nx:
        call    skip_sp
        cmp     al, ','
        jne     .end
        inc     si
        jmp     .l
.end:
        mov     ax, [b_t7]
        or      ax, ax
        jz      bas_newstt
        cmp     byte [b_bb1], T_GOSUB
        jne     goto_line
        STKCHK
        push    word [b_curptr]
        push    word [b_curlin]
        push    si
        mov     cx, FR_GOSUB
        push    cx
        jmp     goto_line

; ------------------------------------------------------------
; FOR / NEXT
; ------------------------------------------------------------
; for_find: BX = variable -> AX = valeur de sp juste au-dessus du cadre FOR de
; cette variable (0 si aucun). Appelee avec un CALL (adresse de retour sur la pile).
for_find:
        mov     bp, sp
        add     bp, 2
.l:
        cmp     bp, B_STK
        jae     .no
        cmp     word [bp], FR_FOR
        jne     .no
        cmp     [bp+2], bx
        je      .yes
        add     bp, 20
        jmp     .l
.yes:
        lea     ax, [bp+20]
        ret
.no:
        xor     ax, ax
        ret

st_for:
        call    skip_sp
        call    var_ref                 ; BX = variable, CL = type
        cmp     cl, TY_STR
        jne     .t
        ERROR   ERR_TM
.t:
        push    bx
        push    cx
        call    skip_sp
        cmp     al, '='
        je      .eq
        ERROR   ERR_SN
.eq:
        inc     si
        call    eval_num
        pop     cx
        pop     bx
        push    bx
        push    cx
        call    store_slot
        call    skip_sp
        cmp     al, T_TO
        je      .to
        ERROR   ERR_SN
.to:
        inc     si
        call    eval_num
        pop     cx
        push    cx
        call    coerce_fac
        mov     ax, [fac_v]
        mov     [b_forlim], ax
        mov     ax, [fac_v+2]
        mov     [b_forlim+2], ax
        call    skip_sp
        cmp     al, T_STEP
        jne     .nostep
        inc     si
        call    eval_num
        pop     cx
        push    cx
        call    coerce_fac
        jmp     .havestep
.nostep:
        pop     cx
        push    cx
        cmp     cl, TY_INT
        jne     .one
        mov     ax, 1
        call    fac_set_int
        jmp     .havestep
.one:
        F_CF    fc_one
        mov     word [fac_t], TY_SNG
.havestep:
        mov     ax, [fac_v]
        mov     [b_forstep], ax
        mov     ax, [fac_v+2]
        mov     [b_forstep+2], ax
        pop     cx
        pop     bx
        ; signe du pas
        xor     dh, dh
        cmp     cl, TY_INT
        jne     .fs
        test    byte [b_forstep+1], 80h
        jz      .sg
        inc     dh
        jmp     .sg
.fs:
        test    byte [b_forstep+3], 80h
        jz      .sg
        inc     dh
.sg:
        mov     ch, dh                  ; CH = signe, CL = type
        ; retire un ancien cadre FOR de la meme variable
        call    for_find
        or      ax, ax
        jz      .push
        mov     sp, ax
.push:
        STKCHK
        push    word [b_curptr]
        push    word [b_curlin]
        push    si
        push    word [b_forlim+2]
        push    word [b_forlim]
        push    word [b_forstep+2]
        push    word [b_forstep]
        xchg    ch, cl                  ; AX = type | signe << 8 (octet bas = type)
        mov     al, ch
        mov     ah, cl
        push    ax
        push    bx
        mov     ax, FR_FOR
        push    ax
        mov     word [fac_t], TY_INT
        jmp     bas_newstt

st_next:
.again:
        call    skip_sp
        xor     bx, bx
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'A'
        jb      .find
        cmp     al, 'Z'
        ja      .find
        call    var_ref
.find:
        mov     bp, sp
.f:
        cmp     bp, B_STK
        jb      .f1
.nf:
        ERROR   ERR_NF
.f1:
        cmp     word [bp], FR_FOR
        jne     .nf
        or      bx, bx
        jz      .got
        cmp     [bp+2], bx
        je      .got
        add     bp, 20
        jmp     .f
.got:
        mov     sp, bp                  ; abandonne les cadres internes
        mov     bx, [bp+2]              ; variable
        mov     al, [bp+4]              ; type
        cmp     al, TY_INT
        jne     .flt
        mov     ax, [bx]
        add     ax, [bp+6]
        jo      .done
        mov     [bx], ax
        cmp     byte [bp+5], 0
        jne     .ineg
        cmp     ax, [bp+10]
        jg      .done
        jmp     .loop
.ineg:
        cmp     ax, [bp+10]
        jl      .done
        jmp     .loop
.flt:
        mov     ax, [bx]
        mov     [arg_v], ax
        mov     ax, [bx+2]
        mov     [arg_v+2], ax
        mov     ax, [bp+6]
        mov     [fac_v], ax
        mov     ax, [bp+8]
        mov     [fac_v+2], ax
        call    fl_add
        jc      .done
        mov     bx, [bp+2]
        mov     ax, [fac_v]
        mov     [bx], ax
        mov     ax, [fac_v+2]
        mov     [bx+2], ax
        F_FA
        mov     ax, [bp+10]
        mov     [fac_v], ax
        mov     ax, [bp+12]
        mov     [fac_v+2], ax
        call    fl_cmp                  ; AL = signe de (nouvelle valeur - limite)
        cmp     byte [bp+5], 0
        jne     .fneg
        cmp     al, 1
        je      .done
        jmp     .loop
.fneg:
        cmp     al, 0FFh
        je      .done
.loop:
        mov     si, [bp+14]
        mov     ax, [bp+16]
        mov     [b_curlin], ax
        mov     ax, [bp+18]
        mov     [b_curptr], ax
        jmp     bas_newstt
.done:
        add     sp, 20
        call    skip_sp
        cmp     al, ','
        jne     bas_newstt
        inc     si
        jmp     .again

; ------------------------------------------------------------
; WHILE / WEND
; ------------------------------------------------------------
st_while:
        lea     ax, [si-1]              ; adresse du jeton WHILE
        push    ax
        call    eval_expr
        call    fac_zero
        pop     dx
        mov     bx, sp
        jz      .false
        cmp     sp, B_STK
        jae     .push
        cmp     word [bx], FR_WHILE
        jne     .push
        cmp     [bx+2], dx
        je      bas_newstt              ; deja empile
.push:
        STKCHK
        push    word [b_curptr]
        push    word [b_curlin]
        push    dx
        mov     ax, FR_WHILE
        push    ax
        jmp     bas_newstt
.false:
        cmp     sp, B_STK
        jae     .scan0
        cmp     word [bx], FR_WHILE
        jne     .scan0
        cmp     [bx+2], dx
        jne     .scan0
        add     sp, 8                   ; retire le cadre
.scan0:
        xor     bx, bx                  ; profondeur
.scan:
        mov     al, [si]
        or      al, al
        jnz     .tk
        mov     di, [b_curptr]
        or      di, di
        jz      .nowend
        mov     di, [di]
        cmp     word [di], 0
        je      .nowend
        mov     [b_curptr], di
        mov     ax, [di+2]
        mov     [b_curlin], ax
        lea     si, [di+4]
        jmp     .scan
.nowend:
        ERROR   ERR_WH
.tk:
        cmp     al, T_WHILE
        jne     .nw
        inc     bx
        jmp     .a
.nw:
        cmp     al, T_WEND
        jne     .a
        or      bx, bx
        jz      .found
        dec     bx
.a:
        inc     si
        jmp     .scan
.found:
        inc     si
        jmp     bas_newstt

st_wend:
        cmp     sp, B_STK
        jae     .no
        mov     bx, sp
        cmp     word [bx], FR_WHILE
        je      .ok
.no:
        ERROR   ERR_WE
.ok:
        mov     si, [bx+2]
        mov     ax, [bx+4]
        mov     [b_curlin], ax
        mov     ax, [bx+6]
        mov     [b_curptr], ax
        jmp     bas_stmt                ; re-execute le WHILE

; ------------------------------------------------------------
; LIST / DELETE
; ------------------------------------------------------------
; parse_range: [n][-[m]] -> b_t5 = bas, b_t6 = haut
parse_range:
        mov     word [b_t5], 0
        mov     word [b_t6], 0FFFFh
        call    parse_lineno
        jc      .nolo
        mov     [b_t5], ax
        mov     [b_t6], ax
.nolo:
        call    skip_sp
        cmp     al, '-'
        jne     .ret
        inc     si
        mov     word [b_t6], 0FFFFh
        call    parse_lineno
        jc      .ret
        mov     [b_t6], ax
.ret:
        ret

; kw_text: AL = jeton -> SI = texte du mot-cle (en ROM, zero final). Preserve CX.
kw_text:
        push    cx
        mov     si, kw_table
        sub     al, 80h
        mov     cl, al
        xor     ch, ch
        jcxz    .r
.s:
        mov     al, [cs:si]
        inc     si
        or      al, al
        jnz     .s
        loop    .s
.r:
        pop     cx
        ret

; print_kw: AL = jeton -> texte du mot-cle; retour AL = dernier caractere affiche
print_kw:
        push    si
        call    kw_text
        xor     ah, ah
.p:
        mov     al, [cs:si]
        inc     si
        or      al, al
        jz      .d
        mov     ah, al
        call    bas_putc
        jmp     .p
.d:
        mov     al, ah
        pop     si
        ret

; kw_glue: AL = dernier caractere d'un mot-cle, [SI] = octet suivant du programme.
; CF = 1 si un espace doit etre ajoute (sinon "PRINTA" ne serait plus "PRINT A").
kw_glue:
        and     al, 0DFh
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        ja      .no
        mov     al, [si]
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .dg
        cmp     ah, 'Z'
        jbe     .yes
.dg:
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        ja      .no
.yes:
        stc
        ret
.no:
        clc
        ret

; list_line: BX = ligne. Preserve BX; detruit SI.
list_line:
        push    bx
        mov     ax, [bx+2]
        mov     [b_lastln], ax
        call    print_uint
        mov     al, ' '
        call    bas_putc
        lea     si, [bx+4]
.c:
        mov     al, [si]
        inc     si
        or      al, al
        jz      .e
        cmp     al, 80h
        jb      .p
        mov     dl, al
        call    print_kw
        cmp     dl, T_FN
        je      .c                      ; FNx: le nom suit directement
        call    kw_glue
        jnc     .c
        mov     al, ' '
        call    bas_putc
        jmp     .c
.p:
        call    bas_putc
        jmp     .c
.e:
        call    bas_crlf
        pop     bx
        ret

; ------------------------------------------------------------
; EDIT n | EDIT .  : edition d'une ligne au terminal (sequences ANSI)
; ------------------------------------------------------------
; detok_line: BX = ligne -> B_IBUF = "numero corps" en clair; b_el = b_ec = longueur
detok_line:
        push    bx
        mov     di, B_IBUF
        mov     ax, [bx+2]
        mov     [b_lastln], ax
        call    put_udec
        mov     al, ' '
        stosb
        pop     bx
        add     bx, 4                   ; BX = texte tokenise
        call    detok_text
        jnc     .fin
        ERROR   ERR_LB
.fin:
        sub     di, B_IBUF
        mov     [b_el], di
        mov     [b_ec], di
        ret

; detok_text: BX = texte tokenise (zero final), DI = destination -> mots-cles en clair
; a [DI], zero final; DI = position du zero. CF = 1 si la ligne depasse B_IBUF + 240.
detok_text:
.c:
        cmp     di, B_IBUF + 240
        jb      .ok
        stc
        ret
.ok:
        mov     al, [bx]
        inc     bx
        or      al, al
        jz      .e
        cmp     al, 80h
        jb      .p
        mov     dl, al
        push    bx
        call    kw_text
.k:
        mov     al, [cs:si]
        inc     si
        or      al, al
        jz      .kd
        mov     ah, al
        stosb
        jmp     .k
.kd:
        pop     bx
        cmp     dl, T_FN
        je      .c
        mov     al, ah
        mov     si, bx
        call    kw_glue
        jnc     .c
        mov     al, ' '
        stosb
        jmp     .c
.p:
        stosb
        jmp     .c
.e:
        mov     byte [di], 0
        clc
        ret

; echo_rewrite: la ligne saisie (B_IBUF) contenait '?': la reaffiche (une ligne plus
; haut, sequences ANSI) avec PRINT a la place, numero de ligne compris. Ignore si la
; ligne est trop longue pour tenir sur une ligne du terminal (78 colonnes).
echo_rewrite:
        mov     di, B_IBUF
.len:
        cmp     byte [di], 0
        je      .lend
        inc     di
        jmp     .len
.lend:
        cmp     di, B_IBUF + 70
        jae     .skip
        mov     di, B_IBUF
        cmp     byte [b_hasline], 0
        je      .body
        mov     ax, [b_lineno]
        call    put_udec
        mov     al, ' '
        stosb
.body:
        mov     bx, B_TBUF
        call    detok_text
        jc      .skip
        cmp     di, B_IBUF + 78
        jae     .skip
        mov     al, 27                  ; ESC [ A : remonte d'une ligne
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, 'A'
        call    uart_tx_byte
        mov     al, 13
        call    uart_tx_byte
        mov     bx, B_IBUF
.o:
        mov     al, [bx]
        or      al, al
        jz      .od
        call    uart_tx_byte
        inc     bx
        jmp     .o
.od:
        mov     al, 27                  ; ESC [ K : efface la fin de l'ancienne ligne
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, 'K'
        call    uart_tx_byte
        call    bas_crlf
.skip:
        ret

; ed_place: replace le curseur du terminal a la colonne b_ec (CR puis ESC[nC)
ed_place:
        mov     al, 13
        call    uart_tx_byte
        mov     ax, [b_ec]
        or      ax, ax
        jz      .r
        push    ax
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        pop     ax
        call    ansi_num
        mov     al, 'C'
        call    uart_tx_byte
.r:
        ret

; ed_redraw: reaffiche toute la ligne (CR, texte, ESC[K) puis replace le curseur
ed_redraw:
        mov     al, 13
        call    uart_tx_byte
        mov     cx, [b_el]
        mov     bx, B_IBUF
        jcxz    .e
.l:
        mov     al, [bx]
        call    uart_tx_byte
        inc     bx
        loop    .l
.e:
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, 'K'
        call    uart_tx_byte
        jmp     ed_place

; ed_del: supprime l'octet a l'indice b_ec (s'il existe)
ed_del:
        mov     bx, [b_ec]
        mov     cx, [b_el]
        cmp     bx, cx
        jae     .r
        sub     cx, bx
        dec     cx
        mov     di, B_IBUF
        add     di, bx
        mov     si, di
        inc     si
        rep     movsb
        dec     word [b_el]
.r:
        ret

; bas_editbuf: edite B_IBUF (b_el, b_ec) au clavier. Retour CF = 1: annule (Ctrl-C).
; Fleches gauche/droite, Debut/Fin, Suppr, Retour arriere, Ctrl-A/Ctrl-E/Ctrl-K,
; caracteres inseres a la position du curseur, Entree valide.
bas_editbuf:
        mov     byte [b_bb1], 0         ; etat ESC (comme bas_getline)
        mov     byte [b_ovr], 0         ; on commence en mode insertion
        call    ed_redraw
.key:
        call    bas_rawin
        mov     ah, [b_bb1]
        or      ah, ah
        jz      .normal
        cmp     ah, 1
        jne     .inseq
        cmp     al, '['
        je      .open
        cmp     al, 'O'
        je      .open
        mov     byte [b_bb1], 0
        jmp     .normal
.open:
        mov     byte [b_bb1], 2
        mov     byte [b_edp], 0
        jmp     .key
.inseq:
        cmp     al, '0'
        jb      .final
        cmp     al, '9'
        ja      .final
        sub     al, '0'
        mov     bl, al
        mov     al, [b_edp]
        mov     dl, 10
        mul     dl
        add     al, bl
        mov     [b_edp], al
        jmp     .key
.final:
        cmp     al, 40h
        jb      .key                    ; ';' et autres octets de parametre
        cmp     al, 7Eh
        ja      .key
        mov     byte [b_bb1], 0
        cmp     al, 'D'
        je      .left
        cmp     al, 'C'
        je      .right
        cmp     al, 'H'
        je      .home
        cmp     al, 'F'
        je      .end
        cmp     al, '~'
        jne     .key
        mov     al, [b_edp]
        cmp     al, 2
        je      .ovr                    ; Inser: insertion <-> ecrasement
        cmp     al, 1
        je      .home
        cmp     al, 7
        je      .home
        cmp     al, 3
        je      .del
        cmp     al, 4
        je      .end
        cmp     al, 8
        je      .end
        jmp     .key
.normal:
        cmp     al, 13
        je      .enter
        cmp     al, 3
        je      .cancel
        cmp     al, 18h
        jne     .n1
        jmp     bas_exit
.n1:
        cmp     al, 1Bh
        jne     .n2
        mov     byte [b_bb1], 1
        jmp     .key
.n2:
        cmp     al, 1
        je      .home
        cmp     al, 5
        je      .end
        cmp     al, 0Bh
        je      .kill
        cmp     al, 7Fh
        je      .bs
        cmp     al, 8
        je      .bs
        cmp     al, 32
        jb      .key
        cmp     byte [b_ovr], 0
        je      .nov
        mov     bx, [b_ec]              ; ecrasement: remplace le caractere sous le curseur
        cmp     bx, [b_el]
        jae     .nov                    ; en fin de ligne: ajout normal
        mov     [B_IBUF + bx], al
        inc     word [b_ec]
        call    uart_tx_byte
        jmp     .key
.nov:
        mov     bx, [b_el]
        cmp     bx, 240
        jae     .key
        mov     cx, bx
        sub     cx, [b_ec]              ; octets a decaler
        jz      .append
        push    ax
        mov     si, B_IBUF
        add     si, bx
        dec     si
        mov     di, si
        inc     di
        std
        rep     movsb
        cld
        pop     ax
        mov     bx, [b_ec]
        mov     [B_IBUF + bx], al
        inc     word [b_el]
        inc     word [b_ec]
        call    ed_redraw
        jmp     .key
.append:
        mov     [B_IBUF + bx], al
        inc     word [b_el]
        inc     word [b_ec]
        call    uart_tx_byte
        jmp     .key
.bs:
        mov     bx, [b_ec]
        or      bx, bx
        jz      .key
        cmp     bx, [b_el]
        jne     .bsmid
        dec     word [b_el]
        dec     word [b_ec]
        mov     al, 8
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        mov     al, 8
        call    uart_tx_byte
        jmp     .key
.bsmid:
        dec     word [b_ec]
        call    ed_del
        call    ed_redraw
        jmp     .key
.del:
        mov     bx, [b_ec]
        cmp     bx, [b_el]
        jae     .key
        call    ed_del
        call    ed_redraw
        jmp     .key
.kill:
        mov     ax, [b_ec]
        mov     [b_el], ax
        call    ed_redraw
        jmp     .key
.ovr:
        xor     byte [b_ovr], 1
        jmp     .key
.left:
        cmp     word [b_ec], 0
        je      .key
        dec     word [b_ec]
        call    ed_place
        jmp     .key
.right:
        mov     ax, [b_ec]
        cmp     ax, [b_el]
        jae     .key
        inc     word [b_ec]
        call    ed_place
        jmp     .key
.home:
        mov     word [b_ec], 0
        call    ed_place
        jmp     .key
.end:
        mov     ax, [b_el]
        mov     [b_ec], ax
        call    ed_place
        jmp     .key
.enter:
        mov     bx, [b_el]
        mov     byte [B_IBUF + bx], 0
        call    bas_crlf
        clc
        ret
.cancel:
        mov     al, '^'
        call    bas_putc
        mov     al, 'C'
        call    bas_putc
        call    bas_crlf
        stc
        ret

st_edit:
        cmp     word [b_curlin], 0FFFFh
        je      .direct
        ERROR   ERR_ID
.direct:
        call    skip_sp
        cmp     al, '.'
        jne     .num
        inc     si
        mov     ax, [b_lastln]
        jmp     .have
.num:
        call    parse_lineno
        jnc     .have
        ERROR   ERR_SN
.have:
        call    find_line
        je      .found
        ERROR   ERR_UL
.found:
        call    detok_line
        call    bas_editbuf
        jc      bas_prompt              ; annule
        jmp     bas_gotline             ; la ligne editee est traitee comme une ligne saisie

st_list:
        call    parse_range
        push    si
        mov     bx, B_TXT
.l:
        cmp     word [bx], 0
        je      .done
        mov     ax, [bx+2]
        cmp     ax, [b_t6]
        ja      .done
        cmp     ax, [b_t5]
        jb      .next
        call    list_line
        call    bas_inkey
        jc      .next
        cmp     al, 3
        je      .done
        cmp     al, 18h
        jne     .next
        jmp     bas_exit
.next:
        mov     bx, [bx]
        jmp     .l
.done:
        pop     si
        jmp     bas_newstt

st_delete:
        call    parse_range
        push    si
        xor     bp, bp                  ; nombre de lignes supprimees
.l:
        mov     ax, [b_t5]
        call    find_line
        cmp     word [bx], 0
        je      .done
        mov     ax, [bx+2]
        cmp     ax, [b_t6]
        ja      .done
        call    del_line
        inc     bp
        jmp     .l
.done:
        pop     si
        or      bp, bp
        jnz     .ok
        ERROR   ERR_FC
.ok:
        call    bas_clear
        mov     word [b_stkbase], B_STK
        mov     sp, B_STK
        mov     word [b_oldptr], 0
        jmp     bas_newstt

; ------------------------------------------------------------
; DATA / READ / RESTORE
; ------------------------------------------------------------
; data_fetch: element suivant -> DI = debut, CX = longueur. CF = 1: plus de donnees.
data_fetch:
        mov     bx, [b_datptr]
        or      bx, bx
        jnz     .st
        mov     bx, B_TXT
        cmp     word [bx], 0
        je      .od
        mov     [b_datln], bx
        add     bx, 4
        mov     byte [b_datmode], 0
.st:
        cmp     byte [b_datmode], 1
        je      .item
.scan:
        mov     al, [bx]
        or      al, al
        jnz     .sc2
        mov     bx, [b_datln]
        mov     bx, [bx]
        cmp     word [bx], 0
        je      .od
        mov     [b_datln], bx
        add     bx, 4
        jmp     .scan
.sc2:
        inc     bx
        cmp     al, T_DATA
        jne     .scan
.item:
.sp:
        cmp     byte [bx], ' '
        jne     .s3
        inc     bx
        jmp     .sp
.s3:
        cmp     byte [bx], '"'
        jne     .unq
        inc     bx
        mov     di, bx
        xor     cx, cx
.q:
        mov     al, [bx]
        or      al, al
        jz      .qe
        cmp     al, '"'
        je      .qe
        inc     bx
        inc     cx
        jmp     .q
.qe:
        cmp     byte [bx], '"'
        jne     .after
        inc     bx
.after:
        cmp     byte [bx], ' '
        jne     .delim
        inc     bx
        jmp     .after
.unq:
        mov     di, bx
.u:
        mov     al, [bx]
        or      al, al
        jz      .ue
        cmp     al, ','
        je      .ue
        cmp     al, ':'
        je      .ue
        inc     bx
        jmp     .u
.ue:
        mov     dx, bx
.t:
        cmp     dx, di
        jbe     .tl
        xchg    bx, dx
        cmp     byte [bx-1], ' '
        xchg    bx, dx
        jne     .tl
        dec     dx
        jmp     .t
.tl:
        mov     cx, dx
        sub     cx, di
.delim:
        cmp     byte [bx], ','
        jne     .nd
        inc     bx
        mov     byte [b_datmode], 1
        jmp     .save
.nd:
        mov     byte [b_datmode], 0
.save:
        mov     [b_datptr], bx
        clc
        ret
.od:
        stc
        ret

; text_store: BX = variable, DL = type, DI = texte, CX = longueur.
; CF = 1 si la conversion echoue. Preserve SI.
text_store:
        cmp     dl, TY_STR
        jne     .num
        cmp     cx, 255
        jbe     .l
        mov     cx, 255
.l:
        mov     [fac_v], cl
        mov     [fac_v+1], di
        mov     word [fac_t], TY_STR
        mov     cl, TY_STR
        call    store_slot
        clc
        ret
.num:
        jcxz    .bad
        push    si
        push    bx
        push    dx
        push    cx
        push    di
        mov     si, di
        mov     al, 1
        call    fl_atof
        jc      .abad
        mov     [fac_t], al
        mov     byte [fac_own], 0
        cmp     al, TY_INT
        jne     .ts
        mov     word [fac_v+2], 0
.ts:
        cmp     byte [si], ' '
        jne     .te
        inc     si
        jmp     .ts
.te:
        pop     di
        pop     cx
        mov     ax, di
        add     ax, cx
        cmp     si, ax
        pop     dx
        pop     bx
        pop     si
        jb      .bad
        mov     cl, dl
        call    store_slot
        clc
        ret
.abad:
        pop     di
        pop     cx
        pop     dx
        pop     bx
        pop     si
.bad:
        stc
        ret

st_read:
.next:
        call    skip_sp
        call    var_ref
        mov     [b_t5], bx
        mov     [b_t6], cx
        push    si
        call    data_fetch
        jnc     .have
        ERROR   ERR_OD
.have:
        mov     bx, [b_t5]
        mov     dl, [b_t6]
        call    text_store
        jnc     .ok
        mov     bx, [b_datln]
        mov     ax, [bx+2]
        mov     [b_curlin], ax
        ERROR   ERR_SN
.ok:
        pop     si
        call    skip_sp
        cmp     al, ','
        jne     bas_newstt
        inc     si
        jmp     .next

st_restore:
        mov     word [b_datptr], 0
        mov     byte [b_datmode], 0
        call    parse_lineno
        jc      bas_newstt
        call    find_line
        je      .ok
        ERROR   ERR_UL
.ok:
        mov     [b_datln], bx
        add     bx, 4
        mov     [b_datptr], bx
        mov     byte [b_datmode], 0
        jmp     bas_newstt

; ------------------------------------------------------------
; INPUT / LINE INPUT
; ------------------------------------------------------------
st_line:
        call    skip_sp
        cmp     al, T_INPUT
        je      .ok
        ERROR   ERR_SN
.ok:
        inc     si
        mov     byte [b_inpmode], 1
        jmp     inp_common
st_input:
        mov     byte [b_inpmode], 0
inp_common:
        call    skip_sp
        cmp     al, '#'
        je      inp_file                ; INPUT #1,v / LINE INPUT #1,a$
        mov     word [b_inpp], 0
        mov     byte [b_inpl], 0
        mov     byte [b_inpq], 1
        cmp     al, '"'
        jne     .go
        inc     si
        mov     [b_inpp], si
        xor     cl, cl
.pl:
        mov     al, [si]
        or      al, al
        jz      .pe
        cmp     al, '"'
        je      .pe
        inc     si
        inc     cl
        jmp     .pl
.pe:
        mov     [b_inpl], cl
        cmp     byte [si], '"'
        jne     .sep
        inc     si
.sep:
        call    skip_sp
        cmp     al, ';'
        je      .semi
        cmp     al, ','
        je      .comma
        ERROR   ERR_SN
.comma:
        mov     byte [b_inpq], 0
.semi:
        inc     si
.go:
        mov     [b_inp0], si
.again:
        ; invite
        mov     bx, [b_inpp]
        mov     cl, [b_inpl]
        xor     ch, ch
        jcxz    .q
.pp:
        mov     al, [bx]
        call    bas_putc
        inc     bx
        loop    .pp
.q:
        cmp     byte [b_inpq], 0
        je      .rd
        mov     al, '?'
        call    bas_putc
        mov     al, ' '
        call    bas_putc
.rd:
        call    bas_getline
        cmp     byte [b_brk], 0
        je      .got
        mov     byte [b_brk], 0
        jmp     bas_break
.got:
        mov     word [b_ip], B_IBUF
        mov     si, [b_inp0]
        cmp     byte [b_inpmode], 1
        je      .line
.var:
        call    skip_sp
        call    var_ref
        mov     [b_t5], bx
        mov     [b_t6], cx
        call    inp_field               ; DI, CX ; CF = 1: ligne epuisee
        jc      .redo
        mov     bx, [b_t5]
        mov     dl, [b_t6]
        call    text_store
        jc      .redo
        call    skip_sp
        cmp     al, ','
        jne     .fin
        inc     si
        jmp     .var
.line:
        call    skip_sp
        call    var_ref
        cmp     cl, TY_STR
        je      .ls
        ERROR   ERR_TM
.ls:
        mov     dl, TY_STR
        mov     di, B_IBUF
        xor     cx, cx
.ll:
        cmp     byte [di], 0
        je      .le
        inc     di
        inc     cx
        jmp     .ll
.le:
        mov     di, B_IBUF
        call    text_store
.fin:
        mov     word [fac_t], TY_INT
        jmp     bas_newstt
.redo:
        mov     si, msg_redo
        call    bas_puts_cs
        jmp     .again

; inp_field: prochain champ de la ligne saisie -> DI = debut, CX = longueur;
; CF = 1 si la ligne est epuisee.
inp_field:
        mov     bx, [b_ip]
        or      bx, bx
        jnz     .go
        stc
        ret
.go:
        cmp     byte [bx], ' '
        jne     .s2
        inc     bx
        jmp     .go
.s2:
        cmp     byte [bx], '"'
        jne     .unq
        inc     bx
        mov     di, bx
        xor     cx, cx
.q:
        mov     al, [bx]
        or      al, al
        jz      .qe
        cmp     al, '"'
        je      .qe
        inc     bx
        inc     cx
        jmp     .q
.qe:
        cmp     byte [bx], '"'
        jne     .aft
        inc     bx
.aft:
        cmp     byte [bx], ' '
        jne     .dl
        inc     bx
        jmp     .aft
.unq:
        mov     di, bx
.u:
        mov     al, [bx]
        or      al, al
        jz      .ue
        cmp     al, ','
        je      .ue
        inc     bx
        jmp     .u
.ue:
        mov     dx, bx
.t:
        cmp     dx, di
        jbe     .tl
        xchg    bx, dx
        cmp     byte [bx-1], ' '
        xchg    bx, dx
        jne     .tl
        dec     dx
        jmp     .t
.tl:
        mov     cx, dx
        sub     cx, di
.dl:
        cmp     byte [bx], ','
        jne     .last
        inc     bx
        mov     [b_ip], bx
        clc
        ret
.last:
        mov     word [b_ip], 0
        clc
        ret

; ------------------------------------------------------------
; RANDOMIZE, POKE, OUT, WAIT, CALL, DEF
; ------------------------------------------------------------
st_randomize:
        call    skip_sp
        or      al, al
        jz      .noarg
        cmp     al, ':'
        je      .noarg
        cmp     al, T_ELSE
        je      .noarg
        call    eval_num
        call    fac_sng
        call    reseed
        jmp     bas_newstt
.noarg:
        add     word [b_seed], 4321
        jmp     bas_newstt

; reseed: graine a partir de FAC (flottant)
reseed:
        mov     ax, [fac_v]
        mov     [b_seed], ax
        mov     ax, [fac_v+2]
        xor     ax, 0A5A5h
        mov     [b_seed+2], ax
        ret

; poke_guard: AX = segment, BX = decalage. ERR_FC si l'adresse physique est dans
; la table des vecteurs, l'espace de travail du BASIC ou l'etat du micrologiciel.
poke_guard:
        push    ax
        push    cx
        push    dx
        mov     dx, ax
        mov     cl, 4
        shl     ax, cl
        mov     cl, 12
        shr     dx, cl
        add     ax, bx
        adc     dx, 0                   ; DX:AX = adresse physique
        or      dx, dx
        jnz     .h
        cmp     ax, 0400h
        jb      .bad
        jmp     .ok
.h:
        cmp     dx, 1
        jne     .ok
        cmp     ax, 0400h
        jb      .bad
        cmp     ax, 0F800h
        jae     .bad
.ok:
        pop     dx
        pop     cx
        pop     ax
        ret
.bad:
        ERROR   ERR_FC

st_poke:
        call    eval_addr16
        push    ax
        call    arg_comma
        call    eval_int
        cmp     ax, 255
        jg      .fc
        cmp     ax, -128
        jl      .fc
        mov     dl, al
        pop     bx
        mov     ax, [b_defseg]
        call    poke_guard
        mov     es, ax
        mov     [es:bx], dl
        push    ds
        pop     es
        jmp     bas_newstt
.fc:
        ERROR   ERR_FC

st_out:
        call    eval_addr16
        push    ax
        call    arg_comma
        call    eval_int
        cmp     ax, 255
        jg      .fc
        cmp     ax, -128
        jl      .fc
        pop     dx
        out     dx, al
        jmp     bas_newstt
.fc:
        ERROR   ERR_FC

st_wait:
        call    eval_addr16
        push    ax
        call    arg_comma
        call    eval_int
        push    ax
        call    skip_sp
        cmp     al, ','
        je      .x
        xor     ax, ax
        jmp     .go
.x:
        inc     si
        call    eval_int
.go:
        mov     bl, al                  ; masque XOR
        pop     cx                      ; masque AND
        pop     dx                      ; port
.w:
        in      al, dx
        xor     al, bl
        test    al, cl
        jnz     bas_newstt
        push    dx
        call    bas_chkbrk
        pop     dx
        jmp     .w

st_call:
        call    eval_addr16
        mov     [b_t1], ax
        mov     ax, [b_defseg]
        mov     [b_t2], ax
        push    si
        push    bp
        call    far [b_t1]
        mov     ax, VAR_SEG
        mov     ds, ax
        mov     es, ax
        pop     bp
        pop     si
        call    skip_stmt               ; parametres eventuels ignores
        jmp     bas_newstt

; fn_find: b_word/b_wlen/b_bb3 -> BX = entree DEF FN, CF = 1 si absente
; Entree: [longueur][type][nom (8 octets, complete par des zeros)][texte:2]
fn_find:
        mov     al, [b_wlen]
        cmp     al, 8
        jbe     .l8
        mov     al, 8
.l8:
        mov     ah, [b_nfn]
        mov     bx, b_fntab
.l:
        or      ah, ah
        jz      .no
        cmp     al, [bx]
        jne     .n
        mov     dl, [b_bb3]
        cmp     dl, [bx+1]
        jne     .n
        push    ax
        push    bx
        mov     cl, al
        xor     ch, ch
        mov     di, b_word
        lea     bx, [bx+2]
.c:
        mov     al, [bx]
        cmp     al, [di]
        jne     .cn
        inc     bx
        inc     di
        loop    .c
        pop     bx
        pop     ax
        clc
        ret
.cn:
        pop     bx
        pop     ax
.n:
        add     bx, 12
        dec     ah
        jmp     .l
.no:
        stc
        ret

st_def:
        call    skip_sp
        cmp     al, T_SEG
        je      .seg
        cmp     al, T_FN
        je      .fn
        ERROR   ERR_SN
.seg:                                   ; DEF SEG [= segment]
        inc     si
        mov     ax, VAR_SEG
        mov     [b_defseg], ax
        call    skip_sp
        cmp     al, '='
        jne     bas_newstt
        inc     si
        call    eval_addr16
        mov     [b_defseg], ax
        jmp     bas_newstt
.fn:
        cmp     word [b_curlin], 0FFFFh
        jne     .ok
        ERROR   ERR_ID
.ok:
        inc     si
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'A'
        jb      .sn
        cmp     al, 'Z'
        jbe     .nm
.sn:
        ERROR   ERR_SN
.nm:
        call    parse_name
        call    fn_find
        jnc     .have
        cmp     byte [b_nfn], 16
        jb      .add
        ERROR   ERR_OM
.add:
        mov     al, [b_nfn]
        mov     ah, 12
        mul     ah
        mov     bx, b_fntab
        add     bx, ax
        inc     byte [b_nfn]
        mov     al, [b_wlen]
        cmp     al, 8
        jbe     .l8
        mov     al, 8
.l8:
        mov     [bx], al
        mov     al, [b_bb3]
        mov     [bx+1], al
        push    si
        mov     cl, [bx]
        xor     ch, ch
        mov     di, bx
        add     di, 2
        mov     si, b_word
        rep     movsb
        pop     si
.have:
        mov     [bx+10], si             ; texte apres le nom
        call    skip_stmt
        jmp     bas_newstt

; fn_user: FNnom(args) dans une expression -> FAC
fn_user:
        STKCHK
        inc     si                      ; jeton FN
        call    parse_name
        call    fn_find
        jnc     .found
        ERROR   ERR_UF
.found:
        push    bx                      ; entree
        call    skip_sp
        xor     cx, cx
        cmp     al, '('
        jne     .noargs
        inc     si
.arg:
        push    cx
        call    eval_expr
        pop     cx
        call    vpush_fac
        inc     cx
        call    skip_sp
        cmp     al, ','
        jne     .aend
        inc     si
        jmp     .arg
.aend:
        cmp     al, ')'
        je      .cl
        ERROR   ERR_SN
.cl:
        inc     si
.noargs:
        pop     bx
        push    si                      ; position de retour
        push    bx                      ; entree
        mov     [b_t7], cx              ; nombre d'arguments
        mov     [b_t8], cx              ; parametres restant a lier
        mov     ax, cx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        mov     dx, [b_vsp]
        sub     dx, ax
        mov     [b_t5], dx              ; premier argument
        mov     si, [bx+10]             ; definition
        call    skip_sp
        cmp     al, '('
        jne     .np
        inc     si
.pl:
        cmp     word [b_t8], 0
        jne     .p1
        ERROR   ERR_SN
.p1:
        dec     word [b_t8]
        call    skip_sp
        call    parse_name
        call    find_var                ; BX = variable du parametre
        push    bx                      ; pour la restauration
        mov     di, [b_vsp]
        cmp     di, B_VSTKE
        jb      .vs
        ERROR   ERR_ST
.vs:
        mov     al, [b_bb3]
        mov     [di], al
        mov     byte [di+1], 0
        mov     ax, [bx]
        mov     [di+2], ax
        mov     ax, [bx+2]
        mov     [di+4], ax
        add     di, 8
        mov     [b_vsp], di
        mov     di, [b_t5]
        mov     ax, [di]
        mov     [fac_t], ax
        mov     ax, [di+2]
        mov     [fac_v], ax
        mov     ax, [di+4]
        mov     [fac_v+2], ax
        add     word [b_t5], 8
        mov     cl, [b_bb3]
        call    store_slot
        call    skip_sp
        cmp     al, ','
        jne     .pe
        inc     si
        jmp     .pl
.pe:
        cmp     al, ')'
        je      .pc
        ERROR   ERR_SN
.pc:
        inc     si
        cmp     word [b_t8], 0
        je      .body
        ERROR   ERR_SN
.np:
        cmp     word [b_t8], 0
        je      .body
        ERROR   ERR_SN
.body:
        mov     cx, [b_t7]
        push    cx
        call    skip_sp
        cmp     al, '='
        je      .eq
        ERROR   ERR_SN
.eq:
        inc     si
        call    eval_expr
        pop     dx                      ; nombre d'arguments
        mov     cx, dx
        jcxz    .norestore
.rs:
        pop     bx                      ; variable du parametre
        mov     di, [b_vsp]
        sub     di, 8
        mov     [b_vsp], di
        mov     ax, [di+2]
        mov     [bx], ax
        mov     ax, [di+4]
        mov     [bx+2], ax
        loop    .rs
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        sub     [b_vsp], ax             ; retire les arguments
.norestore:
        pop     bx                      ; entree
        pop     si                      ; position de retour
        mov     cl, [bx+1]
        jmp     coerce_fac
