; ============================================================
; basic_func.asm - fonctions integrees (lib/basic.asm)
; Chaque fonction est appelee avec SI apres son jeton; elle lit ses arguments
; et laisse le resultat dans FAC (SI apres l'argument).
; ============================================================

; arg_open / arg_comma / arg_close: '(' ',' ')' obligatoires. Preservent AX.
arg_open:
        push    ax
        call    skip_sp
        cmp     al, '('
        je      .ok
        ERROR   ERR_SN
.ok:
        inc     si
        pop     ax
        ret

arg_comma:
        push    ax
        call    skip_sp
        cmp     al, ','
        je      .ok
        ERROR   ERR_SN
.ok:
        inc     si
        pop     ax
        ret

arg_close:
        push    ax
        call    skip_sp
        cmp     al, ')'
        je      .ok
        ERROR   ERR_SN
.ok:
        inc     si
        pop     ax
        ret

; arg1num: '(' expression numerique ')' -> FAC
arg1num:
        call    arg_open
        call    eval_expr
        call    need_num
        jmp     arg_close

; arg1str: '(' expression chaine ')' -> FAC
arg1str:
        call    arg_open
        call    eval_expr
        call    need_str
        jmp     arg_close

; fac_u16: FAC numerique -> AX, plage -32768..65535 (adresses, ports)
fac_u16:
        cmp     byte [fac_t], TY_INT
        jne     .f
        mov     ax, [fac_v]
        ret
.f:
        mov     al, 1
        call    fl_to_i16
        jnc     .ok
        ; >= 32768: soustrait 65536
        mov     ax, [fac_v]
        mov     [fl_tmp], ax
        mov     ax, [fac_v+2]
        mov     [fl_tmp+2], ax
        xor     ax, ax
        mov     dx, 1
        call    fl_from_u32             ; FAC = 65536
        F_LDA   fl_tmp
        call    fl_sub                  ; FAC = x - 65536
        mov     al, 1
        call    fl_to_i16
        jnc     .ok
        ERROR   ERR_OV
.ok:
        ret

; eval_addr16: expression numerique -> AX (-32768..65535)
eval_addr16:
        call    eval_expr
        call    need_num
        jmp     fac_u16

; ------------------------------------------------------------
; Fonctions numeriques
; ------------------------------------------------------------
fn_sgn:
        call    arg1num
        call    fac_zero
        jz      .zero
        cmp     byte [fac_t], TY_INT
        jne     .f
        test    byte [fac_v+1], 80h
        jmp     .s
.f:
        test    byte [fac_v+3], 80h
.s:
        mov     ax, 1
        jz      .set
        mov     ax, -1
        jmp     .set
.zero:
        xor     ax, ax
.set:
        jmp     fac_set_int

fn_abs:
        call    arg1num
        cmp     byte [fac_t], TY_INT
        jne     .f
        mov     ax, [fac_v]
        or      ax, ax
        jns     .ret
        cmp     ax, 8000h
        je      .f2
        neg     ax
        jmp     fac_set_int
.f2:
        call    fac_sng
.f:
        jmp     fl_abs
.ret:
        ret

fn_int:
        call    arg1num
        cmp     byte [fac_t], TY_INT
        je      .r
        jmp     fl_int
.r:
        ret

fn_fix:
        call    arg1num
        cmp     byte [fac_t], TY_INT
        je      .r
        jmp     fl_fix
.r:
        ret

fn_cint:
        call    arg1num
        jmp     fac_int

fn_csng:
        call    arg1num
        jmp     fac_sng

%macro FNMATH 2
fn_%1:
        call    arg1num
        call    fac_sng
        call    %2
        jc      .e
        mov     word [fac_t], TY_SNG
        ret
.e:
        jmp     bas_error
%endmacro
FNMATH  sqr, fl_sqr
FNMATH  sin, fl_sin
FNMATH  cos, fl_cos
FNMATH  tan, fl_tan
FNMATH  atn, fl_atn
FNMATH  log, fl_log
FNMATH  exp, fl_exp

; RND [(x)]: x > 0 ou absent: nombre suivant; 0: dernier; < 0: reinitialise
fn_rnd:
        call    skip_sp
        cmp     al, '('
        jne     rnd_next
        inc     si
        call    eval_expr
        call    need_num
        call    arg_close
        call    fac_sng
        call    fac_zero
        jz      .last
        test    byte [fac_v+3], 80h
        jz      rnd_next
        call    reseed
        jmp     rnd_next
.last:
        F_LDF   b_lastrnd
        mov     word [fac_t], TY_SNG
        ret

; rnd_next: seed = seed * 1664525 + 1013904223; FAC = (seed >> 8) / 2^24
rnd_next:
        mov     ax, [b_seed]
        mov     bx, [b_seed+2]
        mov     cx, ax                  ; aL
        mov     di, bx                  ; aH
        mov     dx, 660Dh
        mul     dx                      ; aL * bL
        mov     [b_seed], ax
        mov     bx, dx
        mov     ax, cx
        mov     dx, 19h
        mul     dx                      ; aL * bH (mot bas)
        add     bx, ax
        mov     ax, di
        mov     dx, 660Dh
        mul     dx                      ; aH * bL (mot bas)
        add     bx, ax
        add     word [b_seed], 0F35Fh
        adc     bx, 3C6Eh
        mov     [b_seed+2], bx
        mov     ax, [b_seed+1]
        mov     dl, [b_seed+3]
        xor     dh, dh
        call    fl_from_u32
        F_FA
        F_CF    fc_2p24
        call    fl_div
        mov     word [fac_t], TY_SNG
        F_STF   b_lastrnd
        ret

fn_peek:
        call    arg_open
        call    eval_addr16
        call    arg_close
        mov     bx, ax
        mov     ax, [b_defseg]
        mov     es, ax
        mov     al, [es:bx]
        push    ds
        pop     es
        xor     ah, ah
        jmp     fac_set_int

fn_inp:
        call    arg_open
        call    eval_addr16
        call    arg_close
        mov     dx, ax
        in      al, dx
        xor     ah, ah
        jmp     fac_set_int

fn_pos:
        call    arg_open
        call    eval_expr
        call    arg_close
        mov     al, [b_col]
        xor     ah, ah
        jmp     fac_set_int

fn_fre:
        call    arg_open
        call    eval_expr
        cmp     byte [fac_t], TY_STR
        jne     .n
        call    gc
.n:
        call    arg_close
        mov     ax, [b_fretop]
        sub     ax, [b_strend]
        xor     dx, dx
        call    fl_from_u32
        mov     word [fac_t], TY_SNG
        ret

; ------------------------------------------------------------
; Fonctions de chaines
; ------------------------------------------------------------
fn_len:
        call    arg1str
        mov     al, [fac_v]
        xor     ah, ah
        jmp     fac_set_int

fn_asc:
        call    arg1str
        cmp     byte [fac_v], 0
        jne     .ok
        ERROR   ERR_FC
.ok:
        mov     bx, [fac_v+1]
        mov     al, [bx]
        xor     ah, ah
        jmp     fac_set_int

fn_val:
        call    arg1str
        mov     cl, [fac_v]
        xor     ch, ch
        cmp     cx, 40
        jbe     .c
        mov     cx, 40
.c:
        push    si
        mov     si, [fac_v+1]
        mov     di, B_NBUF
        rep     movsb
        mov     byte [di], 0
        mov     si, B_NBUF
        mov     al, 1
        call    fl_atof
        pop     si
        jc      .zero
        mov     [fac_t], al
        mov     byte [fac_own], 0
        cmp     al, TY_INT
        jne     .r
        mov     word [fac_v+2], 0
.r:
        ret
.zero:
        xor     ax, ax
        jmp     fac_set_int

fn_chrs:
        call    arg_open
        call    eval_int
        call    arg_close
        cmp     ax, 255
        jbe     .ok
        ERROR   ERR_FC
.ok:
        mov     [B_NBUF], al
        mov     bx, B_NBUF
        mov     cx, 1
        jmp     mk_str

fn_strs:
        call    arg1num
        call    fmt_num
        mov     bx, B_NBUF
        jmp     mk_str

fn_hexs:
        mov     bx, 16
        jmp     radix_str
fn_octs:
        mov     bx, 8
radix_str:
        push    bx
        call    arg_open
        call    eval_expr
        call    need_num
        call    fac_u16
        call    arg_close
        pop     bx
        mov     di, B_NBUF
        call    put_ubase
        mov     cx, di
        sub     cx, B_NBUF
        mov     bx, B_NBUF
        jmp     mk_str

; fn_lefts: LEFT$(s$, n)
fn_lefts:
        call    str_n_args              ; ARG = s$, CX = n
        mov     al, [arg_v]
        xor     ah, ah
        cmp     cx, ax
        jbe     .c
        mov     cx, ax
.c:
        xor     dx, dx
        jmp     substr

fn_rights:
        call    str_n_args
        mov     al, [arg_v]
        xor     ah, ah
        cmp     cx, ax
        jbe     .c
        mov     cx, ax
.c:
        mov     dx, ax
        sub     dx, cx
        jmp     substr

; str_n_args: '(' chaine ',' n ')' -> ARG = chaine, CX = n (>= 0)
str_n_args:
        call    arg_open
        call    eval_str
        call    vpush_fac
        call    arg_comma
        call    eval_int
        call    arg_close
        or      ax, ax
        jns     .ok
        ERROR   ERR_FC
.ok:
        push    ax
        call    vpop_arg
        pop     cx
        ret

; MID$(s$, debut [, n])
fn_mids:
        call    arg_open
        call    eval_str
        call    vpush_fac
        call    arg_comma
        call    eval_int
        cmp     ax, 1
        jge     .s1
        ERROR   ERR_FC
.s1:
        push    ax
        call    skip_sp
        cmp     al, ','
        je      .haslen
        mov     ax, 255
        jmp     .have
.haslen:
        inc     si
        call    eval_int
        or      ax, ax
        jns     .have
        ERROR   ERR_FC
.have:
        push    ax
        call    arg_close
        call    vpop_arg
        pop     cx                      ; n
        pop     dx                      ; debut (1-based)
        dec     dx
        mov     al, [arg_v]
        xor     ah, ah
        sub     ax, dx                  ; disponible
        ja      .avail
        xor     cx, cx
        xor     dx, dx
        jmp     substr
.avail:
        cmp     cx, ax
        jbe     .c
        mov     cx, ax
.c:
        jmp     substr

; STRING$(n, c ou s$), SPACE$(n)
fn_strings:
        call    arg_open
        call    eval_int
        cmp     ax, 255
        jbe     .n
        ERROR   ERR_FC
.n:
        push    ax
        call    arg_comma
        call    eval_expr
        cmp     byte [fac_t], TY_STR
        jne     .num
        cmp     byte [fac_v], 0
        jne     .s1
        ERROR   ERR_FC
.s1:
        mov     bx, [fac_v+1]
        mov     al, [bx]
        jmp     .have
.num:
        call    fac_i16
.have:
        mov     [b_bb1], al
        call    arg_close
        pop     cx
        jmp     fill_str

fn_spaces:
        call    arg_open
        call    eval_int
        call    arg_close
        cmp     ax, 255
        jbe     .ok
        ERROR   ERR_FC
.ok:
        mov     cx, ax
        mov     byte [b_bb1], ' '
        ; (continue)
; fill_str: CX = longueur, b_bb1 = caractere -> FAC
fill_str:
        mov     word [fac_t], TY_INT
        jcxz    .empty
        call    str_alloc
        mov     di, bx
        mov     [fac_v], cl
        mov     [fac_v+1], bx
        mov     al, [b_bb1]
        rep     stosb
        jmp     .set
.empty:
        mov     byte [fac_v], 0
.set:
        mov     word [fac_t], TY_STR + 100h
        ret

; INSTR([debut,] s$, t$)
fn_instr:
        call    arg_open
        call    eval_expr
        cmp     byte [fac_t], TY_STR
        je      .nostart
        call    fac_i16
        cmp     ax, 1
        jge     .st
        ERROR   ERR_FC
.st:
        push    ax
        call    arg_comma
        call    eval_str
        jmp     .have1
.nostart:
        mov     ax, 1
        push    ax
.have1:
        call    vpush_fac
        call    arg_comma
        call    eval_str
        call    arg_close
        call    vpop_arg                ; ARG = s$, FAC = t$
        pop     dx                      ; debut (1-based)
        dec     dx
        mov     al, [arg_v]
        xor     ah, ah
        cmp     dx, ax
        ja      .no
        mov     cl, [fac_v]
        xor     ch, ch
        jcxz    .empty
        sub     ax, cx                  ; derniere position de depart possible
        jb      .no
        mov     [b_t1], ax
        mov     [b_t2], dx
        mov     [b_t3], cx
        push    si
.try:
        mov     bx, [b_t2]
        cmp     bx, [b_t1]
        ja      .nf
        mov     si, [arg_v+1]
        add     si, bx
        mov     di, [fac_v+1]
        mov     cx, [b_t3]
        repe    cmpsb
        je      .yes
        inc     word [b_t2]
        jmp     .try
.yes:
        pop     si
        mov     ax, [b_t2]
        inc     ax
        jmp     .out
.nf:
        pop     si
.no:
        xor     ax, ax
        jmp     .out
.empty:
        mov     ax, dx
        inc     ax
.out:
        mov     word [arg_t], TY_INT
        jmp     fac_set_int

fn_inkeys:
        call    bas_inkey
        jc      .none
        mov     [B_NBUF], al
        mov     bx, B_NBUF
        mov     cx, 1
        jmp     mk_str
.none:
        xor     cx, cx
        jmp     mk_str

; INPUT$(n): attend n caracteres du terminal
fn_inputs:
        call    arg_open
        call    eval_int
        call    arg_close
        cmp     ax, 1
        jl      .fc
        cmp     ax, 255
        jle     .ok
.fc:
        ERROR   ERR_FC
.ok:
        mov     cx, ax
        mov     di, B_IBUF
.l:
        push    cx
        call    bas_rawin
        pop     cx
        cmp     al, 3
        jne     .k
        mov     word [b_oldptr], 0      ; Ctrl-C: Break (sans CONT: on est dans une expression)
        ERROR   ERR_BRK
.k:
        stosb
        loop    .l
        mov     cx, di
        sub     cx, B_IBUF
        mov     bx, B_IBUF
        jmp     mk_str

fn_lcases:
        mov     dl, 0
        jmp     case_str
fn_ucases:
        mov     dl, 1
case_str:
        push    dx
        call    arg1str
        pop     dx
        mov     cl, [fac_v]
        xor     ch, ch
        jcxz    .r
        push    dx
        call    str_alloc               ; BX = zone (la source FAC est une racine)
        pop     dx
        push    si
        mov     di, bx
        mov     si, [fac_v+1]
        mov     [fac_v], cl
        mov     [fac_v+1], bx
        mov     word [fac_t], TY_STR + 100h
.l:
        lodsb
        or      dl, dl
        jz      .lo
        cmp     al, 'a'
        jb      .st
        cmp     al, 'z'
        ja      .st
        sub     al, 32
        jmp     .st
.lo:
        cmp     al, 'A'
        jb      .st
        cmp     al, 'Z'
        ja      .st
        add     al, 32
.st:
        stosb
        loop    .l
        pop     si
.r:
        ret

; ============================================================
; Horloge: TIMER, TIME$, DATE$ (RTC du pont STM32, voir lib/bridge.asm)
; ============================================================
; rtc_fetch: b_rtc <- heure du pont. ERR_DT (Device Timeout) si le pont ne repond pas.
rtc_fetch:
        push    si
        mov     di, b_rtc
        call    rtc_get
        pop     si
        jnc     .ok
        ERROR   ERR_DT
.ok:
        ret

; put2: AL (0-99) -> deux chiffres a [DI] (DI avance)
put2:
        xor     ah, ah
        mov     cl, 10
        div     cl
        add     ax, 3030h
        stosb
        mov     al, ah
        stosb
        ret

; TIMER: secondes depuis minuit (simple precision, precision ~ 1/100 s)
fn_timer:
        call    rtc_fetch
        mov     al, [b_rtc+4]           ; heures * 3600
        xor     ah, ah
        mov     dx, 3600
        mul     dx
        mov     bx, ax
        mov     cx, dx
        mov     al, [b_rtc+5]           ; + minutes * 60
        xor     ah, ah
        mov     dx, 60
        mul     dx
        add     bx, ax
        adc     cx, dx
        mov     al, [b_rtc+6]           ; + secondes
        xor     ah, ah
        add     bx, ax
        adc     cx, 0
        mov     ax, bx
        mov     dx, cx
        call    fl_from_u32             ; FAC = secondes entieres
        F_STF   fl_t0
        mov     al, [b_rtc+7]           ; centiemes / 100
        xor     ah, ah
        call    fl_from_i16
        F_FA
        mov     ax, 100
        call    fl_from_i16
        call    fl_div                  ; FAC = ARG / FAC
        F_LDA   fl_t0
        call    fl_add
        mov     word [fac_t], TY_SNG
        ret

; TIME$ -> "hh:mm:ss"
fn_times:
        call    rtc_fetch
        mov     di, B_NBUF
        mov     al, [b_rtc+4]
        call    put2
        mov     al, ':'
        stosb
        mov     al, [b_rtc+5]
        call    put2
        mov     al, ':'
        stosb
        mov     al, [b_rtc+6]
        call    put2
        mov     bx, B_NBUF
        mov     cx, 8
        jmp     mk_str

; DATE$ -> "mm-dd-yyyy"
fn_dates:
        call    rtc_fetch
        mov     di, B_NBUF
        mov     al, [b_rtc+2]
        call    put2
        mov     al, '-'
        stosb
        mov     al, [b_rtc+3]
        call    put2
        mov     al, '-'
        stosb
        mov     ax, [b_rtc]             ; annee
        mov     cl, 100
        div     cl                      ; AL = siecle, AH = annee dans le siecle
        push    ax
        call    put2
        pop     ax
        mov     al, ah
        call    put2
        mov     bx, B_NBUF
        mov     cx, 10
        jmp     mk_str

; ck_str: FAC (chaine) -> copie zero-terminee dans B_NBUF (40 caracteres max); BX = B_NBUF
ck_str:
        mov     cl, [fac_v]
        xor     ch, ch
        cmp     cx, 40
        jbe     .c
        mov     cx, 40
.c:
        push    si
        mov     si, [fac_v+1]
        mov     di, B_NBUF
        rep     movsb
        mov     byte [di], 0
        pop     si
        mov     bx, B_NBUF
        ret

; pn: nombre decimal a [BX] (1 a 4 chiffres, espaces de tete ignores) -> AX;
; CL = nombre de chiffres; BX avance. CF = 1 si aucun chiffre ou trop de chiffres.
pn:
.sp:
        cmp     byte [bx], ' '
        jne     .go
        inc     bx
        jmp     .sp
.go:
        xor     ax, ax
        xor     cx, cx
.l:
        mov     dl, [bx]
        cmp     dl, '0'
        jb      .e
        cmp     dl, '9'
        ja      .e
        sub     dl, '0'
        xor     dh, dh
        push    dx
        mov     dx, 10
        mul     dx
        pop     dx
        add     ax, dx
        inc     bx
        inc     cx
        cmp     cx, 4
        jbe     .l
        stc                             ; plus de 4 chiffres
        ret
.e:
        or     cx, cx
        jz      .none
        clc
        ret
.none:
        stc
        ret

; tail_ok: [BX] ne doit plus contenir que des espaces (sinon Illegal function call)
tail_ok:
        cmp     byte [bx], ' '
        jne     .e
        inc     bx
        jmp     tail_ok
.e:
        cmp     byte [bx], 0
        jne     rtc_fc
        ret
rtc_fc:
        ERROR   ERR_FC

; TIME$ = "hh[:mm[:ss]]"
st_timeset:
        inc     si                      ; jeton TIME$
        call    skip_sp
        cmp     al, '='
        je      .eq
        ERROR   ERR_SN
.eq:
        inc     si
        call    eval_str
        call    ck_str
        call    pn
        jc      rtc_fc
        cmp     ax, 23
        ja      rtc_fc
        mov     [b_t5], ax
        mov     word [b_t6], 0
        mov     word [b_t7], 0
        cmp     byte [bx], ':'
        jne     .done
        inc     bx
        call    pn
        jc      rtc_fc
        cmp     ax, 59
        ja      rtc_fc
        mov     [b_t6], ax
        cmp     byte [bx], ':'
        jne     .done
        inc     bx
        call    pn
        jc      rtc_fc
        cmp     ax, 59
        ja      rtc_fc
        mov     [b_t7], ax
.done:
        call    tail_ok
        push    si
        call    rtc_fetch               ; conserve la date
        mov     al, [b_t5]
        mov     [b_rtc+4], al
        mov     al, [b_t6]
        mov     [b_rtc+5], al
        mov     al, [b_t7]
        mov     [b_rtc+6], al
        mov     si, b_rtc
        call    rtc_set
        pop     si
        mov     word [fac_t], TY_INT
        jmp     bas_newstt

; date_sep: [BX] doit etre '-' ou '/' (sinon Illegal function call); BX avance
date_sep:
        mov     al, [bx]
        cmp     al, '-'
        je      .ok
        cmp     al, '/'
        jne     rtc_fc
.ok:
        inc     bx
        ret

; DATE$ = "mm-dd-yy" ou "mm-dd-yyyy" (separateurs - ou /; annees 2000-2099)
st_dateset:
        inc     si                      ; jeton DATE$
        call    skip_sp
        cmp     al, '='
        je      .eq
        ERROR   ERR_SN
.eq:
        inc     si
        call    eval_str
        call    ck_str
        call    pn                      ; mois
        jc      rtc_fc
        cmp     ax, 1
        jb      rtc_fc
        cmp     ax, 12
        ja      rtc_fc
        mov     [b_t5], ax
        call    date_sep
        call    pn                      ; jour
        jc      rtc_fc
        mov     [b_t6], ax
        call    date_sep
        call    pn                      ; annee
        jc      rtc_fc
        cmp     cl, 2
        jne     .four
        add     ax, 2000
        jmp     .chk
.four:
        cmp     cl, 4
        jne     rtc_fc
.chk:
        cmp     ax, 2000
        jb      rtc_fc
        cmp     ax, 2099
        ja      rtc_fc
        mov     [b_t7], ax
        call    tail_ok
        mov     bx, [b_t5]              ; jours du mois
        mov     al, [cs:mdays + bx - 1]
        cmp     bx, 2
        jne     .day
        test    byte [b_t7], 3          ; fevrier bissextile (2000-2099: annee % 4)
        jnz     .day
        mov     al, 29
.day:
        xor     ah, ah
        mov     dx, [b_t6]
        or      dx, dx
        jz      rtc_fc
        cmp     dx, ax
        ja      rtc_fc
        push    si
        call    rtc_fetch               ; conserve l'heure
        mov     ax, [b_t7]
        mov     [b_rtc], ax
        mov     al, [b_t5]
        mov     [b_rtc+2], al
        mov     al, [b_t6]
        mov     [b_rtc+3], al
        mov     si, b_rtc
        call    rtc_set
        pop     si
        mov     word [fac_t], TY_INT
        jmp     bas_newstt

mdays:  db      31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
