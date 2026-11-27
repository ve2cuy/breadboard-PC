; ============================================================================
; EDIT.ASM - editeur de texte plein ecran (fichiers .SYS, .BAT, .ASM...) pour le DOS de la ROM de
; Solution-01. Syntaxe NASM (pas MASM): nasm -f bin dos/EDIT.ASM -o dos/EDIT.COM (regle du Makefile).
;
;   EDIT fichier         ouvre le fichier (ou en cree un nouveau a l'enregistrement)
;
;   Fleches, Debut, Fin, PgPrec, PgSuiv    deplacement
;   Retour arriere, Suppr, Entree, Tab      edition (insertion seulement)
;   F2 ou Ctrl-S                            enregistrer et quitter
;   Echap                                   quitter; si modifie: "Enregistrer les changements? (O/N)"
;
; - TOUS les DOS: DOS 2.0 et suivants par les fonctions a numero de fichier (INT 21h AH=3Ch-40h: chemins
;   permis), DOS 1.x par les FCB (AH=0Fh, 10h, 16h, 27h, 28h: lecteur et nom seulement); fin par INT 20h.
;   Clavier par INT 16h (les touches etendues: AH = scan code), du terminal comme du clavier PS/2 (BIOS
;   de la ROM 1.8).
; - Ecran: terminal ANSI de 80 x 25 (ESC [ l;c H, ESC [ K, ESC [ 2J, ESC [ 7m), par INT 10h AH=0Eh; la
;   console du LCD du pont comprend les memes sequences. 24 lignes de texte, ligne d'etat en bas; 79
;   colonnes affichees (la 80e n'est jamais ecrite: pas de defilement du terminal), defilement
;   horizontal par 40 colonnes. Tabulations aux multiples de 8, gardees telles quelles.
; - Texte dans un tampon a trou (le curseur est le trou: insertion et suppression immediates), jusqu'a
;   ~ 53 Ko. Les CR sont retires a la lecture (arret au Ctrl-Z) et remis a l'ecriture (CR LF), suivi d'un
;   Ctrl-Z comme EDLIN.
; - Erreur critique (disque protege en ecriture - A: est en ROM -, disque plein...): INT 24h detourne
;   pendant l'edition, l'erreur est signalee et l'edition continue (sinon "Abort" du DOS la perdait).
; ============================================================================
        cpu     8086
        org     100h

ROWS    equ     24                      ; lignes de texte (la 25e: ligne d'etat)
WIDTH   equ     79                      ; colonnes affichees
BUFEND  equ     0F000h                  ; fin du tampon; la pile est au-dessus (SP = FFFEh)
LF      equ     10
CR      equ     13

start:
        cld
        mov     ax, [2]                 ; PSP:0002 = fin de la memoire: il faut 64 Ko
        mov     bx, cs
        sub     ax, bx
        cmp     ax, 1000h
        jae     .mem
        mov     dx, m_mem
        jmp     fatal
.mem:
        mov     si, 81h                 ; ligne de commande: le nom du fichier
.sk:
        lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 9
        je      .sk
        cmp     al, CR
        jne     .nom
        mov     dx, m_usage
        jmp     fatal
.nom:
        mov     di, fname
        mov     cx, 64
.cp:
        stosb
        lodsb
        cmp     al, ' '
        jbe     .fin                    ; espace, tabulation ou CR
        loop    .cp
.fin:
        mov     byte [di], 0
        mov     ah, 30h                 ; version du DOS: AL = 0 sous DOS 1.x
        int     21h
%ifdef FORCE_FCB
        xor     al, al                  ; (essais: le chemin du DOS 1.x sous un DOS plus recent)
%endif
        or      al, al
        jnz     .dos2
        mov     byte [dos1], 1
        mov     si, fname               ; DOS 1: nom -> FCB
        mov     di, fcb
        mov     ax, 2901h
        int     21h
        cmp     al, 0FFh
        mov     dx, m_open
        je      fatal
.dos2:
        call    load
        mov     dx, int24               ; erreurs critiques: signalees, pas d'"Abort" (le DOS remet
        mov     ax, 2524h               ; l'ancien vecteur, garde dans le PSP, a la sortie)
        int     21h
        mov     si, m_cls
        call    puts
.loop:
        call    view
        xor     ah, ah
        int     16h
        call    key
        jmp     .loop

fatal:                                  ; DX = message ($)
        mov     ah, 9
        int     21h
        int     20h                     ; (CS = PSP: tous les DOS)

int24:
        mov     byte [cs:crit], 1
        xor     al, al                  ; ignorer (DOS 2.x); l'appelant regarde crit
        iret

; ---------------------------------------------------------------------------- fichier
; load: lit le fichier dans le tampon (sans CR, jusqu'au Ctrl-Z), place le texte a la fin du tampon,
; le trou (le curseur) au debut.
load:
        cmp     byte [dos1], 0
        jne     load_fcb
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jnc     .ouvert
        cmp     ax, 2                   ; fichier introuvable: nouveau
        mov     dx, m_open
        jne     fatal
        mov     byte [nouveau], 1
        xor     cx, cx
        jmp     load_conv
.ouvert:
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, BUFEND - buf - 1024
        mov     dx, buf
        int     21h
        mov     dx, m_read
        jc      fatal
        push    ax
        mov     ah, 3Eh
        int     21h
        pop     cx
load_size:
        cmp     cx, BUFEND - buf - 1024
        mov     dx, m_big
        jae     fatal
load_conv:
        mov     si, buf
        mov     di, buf
        jcxz    .cfin
.conv:
        lodsb
        cmp     al, 1Ah
        je      .cfin
        cmp     al, CR
        je      .sauf
        stosb
.sauf:
        loop    .conv
.cfin:
        mov     cx, di                  ; texte en [buf, DI): a la fin du tampon
        sub     cx, buf
        mov     si, di
        dec     si
        mov     di, BUFEND - 1
        std
        rep     movsb
        cld
        inc     di
        mov     [ge_], di
        mov     word [gs_], buf
        ret

; load_fcb: DOS 1.x - meme chose par le FCB (lecture en bloc, enregistrements d'un octet)
load_fcb:
        mov     ah, 0Fh
        mov     dx, fcb
        int     21h
        or      al, al
        jz      .ouvert
        mov     byte [nouveau], 1
        xor     cx, cx
        jmp     load_conv
.ouvert:
        cmp     word [fcb + 12h], 0     ; taille > 64 Ko
        mov     dx, m_big
        jne     fatal
        call    fcb_rec1
        mov     dx, buf
        mov     ah, 1Ah                 ; zone de transfert = le tampon
        int     21h
        mov     cx, BUFEND - buf - 1024
        mov     dx, fcb
        mov     ah, 27h
        int     21h                     ; CX = octets lus
        push    cx
        mov     dx, fcb
        mov     ah, 10h
        int     21h
        pop     cx
        jmp     load_size

fcb_rec1:                               ; enregistrements d'un octet, a partir du premier
        mov     word [fcb + 0Eh], 1
        mov     word [fcb + 21h], 0
        mov     word [fcb + 23h], 0
        ret

; save: ecrit le fichier (LF -> CR LF, Ctrl-Z final). CF = 1 en cas d'erreur (message affiche).
save:
        mov     byte [crit], 0
        cmp     byte [dos1], 0
        je      .h
        mov     ah, 16h                 ; DOS 1: creer par le FCB
        mov     dx, fcb
        int     21h
        or      al, al
        jnz     .ecree
        call    fcb_rec1
        xor     ax, ax
        jmp     .cree
.h:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      .ecree
.cree:
        cmp     byte [crit], 0
        jne     .ecree
        mov     [hdl], ax
        mov     word [olen], 0
        mov     si, buf
        mov     cx, [gs_]
        sub     cx, buf
        call    wr_range
        jc      .eecr
        mov     si, [ge_]
        mov     cx, BUFEND
        sub     cx, si
        call    wr_range
        jc      .eecr
        mov     al, 1Ah
        call    wr_byte
        jc      .eecr
        call    flush
        jc      .eecr
        call    fclose
        jc      .emsg
        cmp     byte [crit], 0
        jne     .emsg
        clc
        ret
.ecree:
        mov     si, m_ecree
        jmp     .msg
.eecr:
        call    fclose
.emsg:
        mov     si, m_eecr
.msg:
        call    ask
        stc
        ret

wr_range:                               ; SI, CX octets du tampon -> fichier
        jcxz    .ok
.l:
        lodsb
        cmp     al, LF
        jne     .b
        mov     al, CR
        call    wr_byte
        jc      .r
        mov     al, LF
.b:
        call    wr_byte
        jc      .r
        loop    .l
.ok:
        clc
.r:
        ret

wr_byte:                                ; AL -> tampon de sortie (512 octets)
        push    bx
        mov     bx, [olen]
        mov     [outbuf + bx], al
        inc     bx
        mov     [olen], bx
        pop     bx
        cmp     word [olen], 512
        jae     flush
        clc
        ret

fclose:                                 ; ferme le fichier enregistre; CF = 1: erreur
        cmp     byte [dos1], 0
        je      .h
        mov     dx, fcb
        mov     ah, 10h
        int     21h
        cmp     al, 1                   ; AL = FFh: erreur (CF = 0 seulement si AL = 0)
        cmc
        ret
.h:
        mov     bx, [hdl]
        mov     ah, 3Eh
        int     21h
        ret

flush:                                  ; CF = 1: erreur d'ecriture
        push    ax
        push    bx
        push    cx
        push    dx
        mov     cx, [olen]
        jcxz    .ok
        cmp     byte [dos1], 0
        je      .h
        mov     dx, outbuf              ; DOS 1: ecriture en bloc par le FCB
        mov     ah, 1Ah
        int     21h
        mov     dx, fcb
        mov     ah, 28h
        int     21h
        or      al, al
        jnz     .err
        jmp     .verif
.h:
        mov     bx, [hdl]
        mov     dx, outbuf
        mov     ah, 40h
        int     21h
        jc      .r
        cmp     ax, cx
        jne     .err
.verif:
        cmp     byte [crit], 0
        jne     .err
        mov     word [olen], 0
.ok:
        clc
        jmp     .r
.err:
        stc
.r:
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---------------------------------------------------------------------------- tampon a trou
; Position logique: 0 .. longueur du texte. [buf, gs_) = texte avant le curseur, [ge_, BUFEND) = apres.

; ch_at: SI = position -> AL = caractere; CF = 1 au-dela de la fin. Preserve le reste.
ch_at:
        push    bx
        mov     bx, [gs_]
        sub     bx, buf                 ; BX = position du curseur
        cmp     si, bx
        jae     .apres
        mov     al, [si + buf]
        pop     bx
        clc
        ret
.apres:
        push    si
        sub     si, bx
        add     si, [ge_]
        jc      .fin
        cmp     si, BUFEND
        jae     .fin
        mov     al, [si]
        pop     si
        pop     bx
        clc
        ret
.fin:
        pop     si
        pop     bx
        stc
        ret

; curpos: SI = position du curseur
curpos:
        mov     si, [gs_]
        sub     si, buf
        ret

; line_start: SI = position -> debut de sa ligne. line_end: -> son LF (ou la fin du texte).
line_start:
        push    ax
.l:
        or      si, si
        jz      .d
        dec     si
        call    ch_at
        cmp     al, LF
        jne     .l
        inc     si
.d:
        pop     ax
        ret

line_end:
        push    ax
.l:
        call    ch_at
        jc      .d
        cmp     al, LF
        je      .d
        inc     si
        jmp     .l
.d:
        pop     ax
        ret

; advcol: colonne DX apres le caractere AL (tabulation: multiple de 8 suivant)
advcol:
        cmp     al, 9
        jne     .un
        or      dx, 7
.un:
        inc     dx
        ret

; col_of: SI = position -> AX = colonne d'affichage. Detruit DX.
col_of:
        push    bx
        push    si
        mov     bx, si
        call    line_start
        xor     dx, dx
.l:
        cmp     si, bx
        jae     .d
        call    ch_at
        call    advcol
        inc     si
        jmp     .l
.d:
        mov     ax, dx
        pop     si
        pop     bx
        ret

; pos_at_col: SI = debut d'une ligne, DX = colonne voulue -> SI = position la plus proche (sans depasser)
pos_at_col:
        push    ax
        push    bx
        push    dx
        mov     bx, dx
        xor     dx, dx
.l:
        call    ch_at
        jc      .d
        cmp     al, LF
        je      .d
        push    dx
        call    advcol
        cmp     dx, bx
        pop     ax                      ; (AX = colonne d'avant)
        ja      .d
        inc     si
        jmp     .l
.d:
        pop     dx
        pop     bx
        pop     ax
        ret

; count_lf: BX = nombre de LF dans [SI, SI + CX). Preserve le reste.
count_lf:
        push    ax
        push    cx
        push    di
        xor     bx, bx
        jcxz    .d
        mov     di, si
        mov     al, LF
.l:
        repne   scasb
        jne     .d
        inc     bx
        jcxz    .d
        jmp     .l
.d:
        pop     di
        pop     cx
        pop     ax
        ret

; move_to: DI = nouvelle position du curseur: deplace le trou (et compte les lignes traversees)
move_to:
        push    ax
        push    bx
        push    cx
        push    si
        push    di
        call    curpos
        mov     ax, si
        cmp     di, ax
        je      .d
        jb      .arriere
        mov     cx, di                  ; vers l'avant: [ge_, ge_ + n) -> gs_
        sub     cx, ax
        mov     si, [ge_]
        call    count_lf
        add     [curline], bx
        mov     di, [gs_]
        rep     movsb
        mov     [gs_], di
        mov     [ge_], si
        jmp     .d
.arriere:
        mov     cx, ax                  ; vers l'arriere: [buf + di, gs_) -> avant ge_
        sub     cx, di
        lea     si, [di + buf]
        call    count_lf
        sub     [curline], bx
        mov     si, [gs_]
        dec     si
        mov     di, [ge_]
        dec     di
        std
        rep     movsb
        cld
        inc     si
        inc     di
        mov     [gs_], si
        mov     [ge_], di
.d:
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; ---------------------------------------------------------------------------- touches
key:
        or      al, al
        jz      .ext
        cmp     al, 0E0h                ; (clavier etendu de certains BIOS)
        je      .ext
        cmp     al, 1Bh
        je      k_esc
        cmp     al, 13h                 ; Ctrl-S
        je      k_save
        cmp     al, 8
        je      k_bs
        cmp     al, 7Fh
        je      k_bs
        cmp     al, CR
        je      .entree
        cmp     al, 9
        je      k_insert
        cmp     al, ' '
        jae     k_insert
        ret                             ; autres caracteres de controle: ignores
.entree:
        mov     al, LF
        jmp     k_insert
.ext:
        mov     al, ah
        mov     bx, keytab
.f:
        cmp     byte [bx], 0
        je      .r
        cmp     al, [bx]
        je      .hit
        add     bx, 3
        jmp     .f
.hit:
        jmp     [bx + 1]
.r:
        ret

keytab:
        db      48h
        dw      k_up
        db      50h
        dw      k_down
        db      4Bh
        dw      k_left
        db      4Dh
        dw      k_right
        db      47h
        dw      k_home
        db      4Fh
        dw      k_end
        db      49h
        dw      k_pgup
        db      51h
        dw      k_pgdn
        db      53h
        dw      k_del
        db      3Ch
        dw      k_save
        db      0

k_insert:                               ; AL = caractere (LF = nouvelle ligne)
        mov     di, [gs_]
        cmp     di, [ge_]
        jae     .plein
        stosb
        mov     [gs_], di
        mov     byte [modif], 1
        mov     word [want], -1
        cmp     al, LF
        jne     .ligne
        inc     word [curline]
        or      byte [redraw], 2
        ret
.ligne:
        or      byte [redraw], 1
        ret
.plein:
        mov     si, m_plein
        jmp     ask

k_bs:
        mov     si, [gs_]
        cmp     si, buf
        jbe     .r
        dec     si
        mov     [gs_], si
        mov     byte [modif], 1
        mov     word [want], -1
        cmp     byte [si], LF
        jne     .ligne
        dec     word [curline]
        or      byte [redraw], 2
        ret
.ligne:
        or      byte [redraw], 1
.r:
        ret

k_del:
        mov     si, [ge_]
        cmp     si, BUFEND
        jae     .r
        mov     al, [si]
        inc     si
        mov     [ge_], si
        mov     byte [modif], 1
        mov     word [want], -1
        cmp     al, LF
        jne     .ligne
        or      byte [redraw], 2
        ret
.ligne:
        or      byte [redraw], 1
.r:
        ret

k_left:
        call    curpos
        or      si, si
        jz      .r
        dec     si
        mov     di, si
        call    move_to
        mov     word [want], -1
.r:
        ret

k_right:
        mov     si, [ge_]
        cmp     si, BUFEND
        jae     .r
        call    curpos
        inc     si
        mov     di, si
        call    move_to
        mov     word [want], -1
.r:
        ret

k_home:
        call    curpos
        call    line_start
        mov     di, si
        call    move_to
        mov     word [want], -1
        ret

k_end:
        call    curpos
        call    line_end
        mov     di, si
        call    move_to
        mov     word [want], -1
        ret

; get_want: DX = colonne voulue pour haut/bas (celle du curseur, gardee d'une ligne a l'autre)
get_want:
        cmp     word [want], -1
        jne     .ok
        call    curpos
        call    col_of
        mov     [want], ax
.ok:
        mov     dx, [want]
        ret

k_up:                                   ; CF = 1: deja a la premiere ligne
        call    get_want
        call    curpos
        call    line_start
        or      si, si
        jz      .non
        dec     si
        call    line_start
        call    pos_at_col
        mov     di, si
        call    move_to
        clc
        ret
.non:
        stc
        ret

k_down:                                 ; CF = 1: deja a la derniere ligne
        call    get_want
        call    curpos
        call    line_end
        call    ch_at
        jc      .non
        inc     si
        call    pos_at_col
        mov     di, si
        call    move_to
        clc
        ret
.non:
        stc
        ret

k_pgup:
        mov     cx, ROWS - 1
.l:
        push    cx
        call    k_up
        jc      .fin
        mov     si, [top]               ; la page monte avec le curseur
        or      si, si
        jz      .n
        dec     si
        call    line_start
        mov     [top], si
        dec     word [topline]
        or      byte [redraw], 2
.n:
        pop     cx
        loop    .l
        ret
.fin:
        pop     cx
        ret

k_pgdn:
        mov     cx, ROWS - 1
.l:
        push    cx
        call    k_down
        jc      .fin
        mov     si, [top]               ; la page descend avec le curseur
        call    line_end
        call    ch_at
        jc      .n
        inc     si
        mov     [top], si
        inc     word [topline]
        or      byte [redraw], 2
.n:
        pop     cx
        loop    .l
        ret
.fin:
        pop     cx
        ret

k_save:
        call    save
        jc      .r
        jmp     quit
.r:
        ret

k_esc:                                  ; quitter; si modifie: enregistrer (O), ne pas enregistrer (N),
        cmp     byte [modif], 0         ; ou continuer l'edition (Echap ou autre touche)
        je      quit
        mov     si, m_quitter
        call    ask
        cmp     al, 1Bh
        je      .r
        or      al, 20h
        cmp     al, 'o'
        je      k_save
        cmp     al, 'y'
        je      k_save
        cmp     al, 'n'
        je      quit
.r:
        ret

quit:
        mov     si, m_cls
        call    puts
        int     20h                     ; (CS = PSP: tous les DOS)

; ---------------------------------------------------------------------------- affichage
; view: fait suivre la page et le defilement horizontal, redessine ce qu'il faut, ligne d'etat, curseur
view:
        mov     ax, [curline]
        cmp     ax, [topline]
        jae     .v1
        call    curpos                  ; curseur au-dessus de la page: sa ligne en haut
        call    line_start
        mov     [top], si
        mov     [topline], ax
        or      byte [redraw], 2
        jmp     .h
.v1:
        sub     ax, [topline]
        cmp     ax, ROWS
        jb      .h
        sub     ax, ROWS - 1            ; curseur sous la page: la page descend
        mov     cx, ax
.v2:
        mov     si, [top]
        call    line_end
        inc     si
        mov     [top], si
        inc     word [topline]
        loop    .v2
        or      byte [redraw], 2
.h:
        call    curpos
        call    col_of
        mov     [ccol], ax
        mov     bx, [left]
.h1:
        cmp     ax, bx
        jae     .h2
        sub     bx, 40
        jmp     .h1
.h2:
        mov     dx, bx
        add     dx, WIDTH
        cmp     ax, dx
        jb      .h3
        add     bx, 40
        jmp     .h2
.h3:
        cmp     bx, [left]
        je      .dessin
        mov     [left], bx
        or      byte [redraw], 2
.dessin:
        test    byte [redraw], 2
        jz      .une
        mov     si, [top]
        xor     dx, dx
.tout:
        call    draw_line
        inc     dx
        cmp     dx, ROWS
        jb      .tout
        jmp     .etat
.une:
        test    byte [redraw], 1
        jz      .etat
        call    curpos
        call    line_start
        mov     dx, [curline]
        sub     dx, [topline]
        call    draw_line
.etat:
        mov     byte [redraw], 0
        call    draw_status
        mov     ax, [curline]
        sub     ax, [topline]
        inc     ax
        mov     bx, [ccol]
        sub     bx, [left]
        inc     bx
        jmp     goto

; draw_line: SI = debut de ligne, DX = rangee (0-23) -> SI = debut de la ligne suivante
draw_line:
        push    dx
        mov     ax, dx
        inc     ax
        mov     bx, 1
        call    goto
        xor     cx, cx                  ; CX = colonne d'affichage
.l:
        call    ch_at
        jc      .fin
        inc     si
        cmp     al, LF
        je      .eol
        cmp     al, 9
        je      .tab
        cmp     al, ' '
        jae     .c
        mov     al, '^'                 ; autre caractere de controle
.c:
        call    put_col
        jmp     .l
.tab:
        mov     al, ' '
.t:
        call    put_col
        test    cx, 7
        jnz     .t
        jmp     .l
.fin:
        inc     si                      ; au-dela de la fin: les rangees suivantes restent vides
.eol:
        mov     al, 27
        call    putc
        mov     al, '['
        call    putc
        mov     al, 'K'
        call    putc
        pop     dx
        ret

put_col:                                ; AL a la colonne CX, s'il est dans la fenetre
        cmp     cx, [left]
        jb      .n
        push    bx
        mov     bx, [left]
        add     bx, WIDTH
        cmp     cx, bx
        pop     bx
        jae     .n
        call    putc
.n:
        inc     cx
        ret

draw_status:
        mov     ax, ROWS + 1
        mov     bx, 1
        call    goto
        mov     si, m_inv
        call    puts
        mov     al, ' '
        call    putc
        mov     si, fname
        mov     cx, 20                  ; 20 caracteres au plus
.n:
        lodsb
        or      al, al
        jz      .n2
        call    putc
        loop    .n
.n2:
        mov     al, ' '
        cmp     byte [modif], 0
        je      .m
        mov     al, '*'
.m:
        call    putc
        cmp     byte [nouveau], 0
        je      .l
        mov     si, m_nouveau
        call    puts
.l:
        mov     si, m_ligne
        call    puts
        mov     ax, [curline]
        inc     ax
        call    putnum
        mov     si, m_col
        call    puts
        mov     ax, [ccol]
        inc     ax
        call    putnum
        mov     si, m_aide
        call    puts
        mov     si, m_eol_norm
        jmp     puts

; ask: SI = message sur la ligne d'etat, attend une touche -> AX
ask:
        push    si
        mov     ax, ROWS + 1
        mov     bx, 1
        call    goto
        mov     si, m_inv
        call    puts
        pop     si
        call    puts
        mov     si, m_eol_norm
        call    puts
        xor     ah, ah
        int     16h
        ret

; goto: AX = rangee, BX = colonne (depuis 1): ESC [ r ; c H
goto:
        push    ax
        mov     al, 27
        call    putc
        mov     al, '['
        call    putc
        pop     ax
        call    putnum
        mov     al, ';'
        call    putc
        mov     ax, bx
        call    putnum
        mov     al, 'H'
        jmp     putc

putnum:                                 ; AX en decimal
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
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
        call    putc
        loop    .p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

puts:                                   ; SI = chaine terminee par 0
        lodsb
        or      al, al
        jz      .r
        call    putc
        jmp     puts
.r:
        ret

putc:                                   ; AL -> ecran (INT 10h teletype). Preserve tout.
        push    ax
        push    bx
        mov     ah, 0Eh
        mov     bx, 7
        int     10h
        pop     bx
        pop     ax
        ret

; ---------------------------------------------------------------------------- donnees
m_usage         db      'EDIT fichier  (editeur plein ecran: F2 enregistrer et quitter, Echap quitter)', 13, 10, '$'
m_mem           db      'EDIT: il faut 64 Ko de memoire libre.', 13, 10, '$'
m_open          db      'EDIT: impossible d', 27h, 'ouvrir le fichier.', 13, 10, '$'
m_read          db      'EDIT: erreur de lecture.', 13, 10, '$'
m_big           db      'EDIT: fichier trop gros (52 Ko au plus).', 13, 10, '$'
m_cls           db      27, '[0m', 27, '[2J', 27, '[H', 0
m_inv           db      27, '[7m', 0
m_eol_norm      db      27, '[K', 27, '[0m', 0
m_nouveau       db      '(nouveau)', 0
m_ligne         db      '  Ligne ', 0
m_col           db      '  Col ', 0
m_aide          db      '   F2: enregistrer et quitter  Echap: quitter', 0
m_quitter       db      ' Enregistrer les changements? (O/N, Echap = continuer) ', 0
m_ecree         db      ' Impossible de creer le fichier (disque protege? A: est en ROM). Une touche...', 0
m_eecr          db      ' Erreur d', 27h, 'ecriture (disque plein ou protege?). Une touche...', 0
m_plein         db      ' Tampon plein. Une touche...', 0

gs_             dw      0               ; debut du trou (= curseur)
ge_             dw      0               ; fin du trou
top             dw      0               ; position du debut de la premiere ligne affichee
topline         dw      0               ; son numero (depuis 0)
curline         dw      0               ; ligne du curseur (depuis 0)
ccol            dw      0               ; colonne d'affichage du curseur
want            dw      -1              ; colonne voulue pour haut/bas (-1: celle du curseur)
left            dw      0               ; premiere colonne affichee (defilement horizontal)
redraw          db      2               ; bit 1: tout redessiner, bit 0: la ligne du curseur
modif           db      0
nouveau         db      0
crit            db      0               ; erreur critique pendant l'enregistrement (INT 24h)
dos1            db      0               ; 1 = DOS 1.x: fichier par le FCB
fcb             times 37 db 0
hdl             dw      0
olen            dw      0
fname           times 66 db 0

outbuf:                                 ; 512 octets (non ecrits dans le .COM)
buf             equ     outbuf + 512    ; le texte, jusqu'a BUFEND
