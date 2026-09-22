; ============================================================
; basic.asm
; Interpreteur BASIC "GW-BASIC-like" pour le 8088, lance par l'option 4 du
; menu principal et pilote par le TERMINAL UART. Reimplementation
; ORIGINALE, INSPIREE de GW-BASIC de Microsoft (github.com/microsoft/GW-BASIC,
; licence MIT - voir ci-dessous): memes mots-cles, memes messages d'erreur
; (et leurs numeros), memes regles de types (%, !, $) et de priorite des
; operateurs, meme format d'affichage des nombres. NE SONT PAS repris:
; acces disque/fichiers, imprimante, graphiques, son, port serie, joystick,
; ON ERROR, etc.
;
; ---- LICENCE de GW-BASIC (source d'inspiration, MIT) --------------------
; MIT License - Copyright (c) Microsoft Corporation.
; Permission is hereby granted, free of charge, to any person obtaining a copy
; of this software and associated documentation files (the "Software"), to
; deal in the Software without restriction, including without limitation the
; rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
; sell copies of the Software, and to permit persons to whom the Software is
; furnished to do so, subject to the following conditions: The above copyright
; notice and this permission notice shall be included in all copies or
; substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
; WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
; TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
; FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
; OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
; ------------------------------------------------------------------------
;
; ARCHITECTURE (voir README.md, section BASIC)
;   - DS = ES = SS = VAR_SEG (1000h) pendant l'execution, comme Tiny BASIC:
;     un seul segment de donnees, pile privee; les tables (mots-cles,
;     messages, constantes) sont en ROM et lues par CS.
;   - SI = pointeur de texte (jeton) de l'interpreteur. Les routines le
;     preservent sauf mention contraire.
;   - Le programme est stocke TOKENISE: [lien:2][numero:2][jetons...][0]; le
;     lien = adresse de la ligne suivante (0 = fin). Les jetons (>= 80h)
;     representent les mots-cles; le reste est du texte ASCII.
;   - Types: 2 = entier 16 bits (%), 3 = chaine (descripteur 3 octets:
;     longueur, pointeur), 4 = simple precision (float32 logiciel, voir
;     lib/basic_float.asm / basic_fmath.asm). Les doubles (#) sont
;     traites comme des simples.
;   - Les instructions se terminent par "jmp bas_newstt" (jamais RET): les
;     cadres FOR/GOSUB/WHILE vivent directement sur la pile.
; ============================================================
%ifndef BASIC_ASM
%define BASIC_ASM

%include "include/hardware.inc"
%ifndef BASIC_TEST                      ; le banc d'essai (tests/) fournit uart_tx_byte,
%include "lib/uart.asm"                 ; uart_rx_available et uart_rx_byte
%include "lib/bridge.asm"               ; rtc_get / rtc_set (horloge du pont); le banc d'essai
                                        ; les remplace par des simulacres
%endif

; --- numeros d'erreur (numerotation GW-BASIC) ---
ERR_NF  equ     1                       ; NEXT without FOR
ERR_SN  equ     2                       ; Syntax error
ERR_RG  equ     3                       ; RETURN without GOSUB
ERR_OD  equ     4                       ; Out of DATA
ERR_FC  equ     5                       ; Illegal function call
ERR_OV  equ     6                       ; Overflow
ERR_OM  equ     7                       ; Out of memory
ERR_UL  equ     8                       ; Undefined line number
ERR_BS  equ     9                       ; Subscript out of range
ERR_DD  equ     10                      ; Duplicate Definition
ERR_DZ  equ     11                      ; Division by zero
ERR_ID  equ     12                      ; Illegal direct
ERR_TM  equ     13                      ; Type mismatch
ERR_OS  equ     14                      ; Out of string space
ERR_LS  equ     15                      ; String too long
ERR_ST  equ     16                      ; String formula too complex
ERR_CN  equ     17                      ; Can't continue
ERR_UF  equ     18                      ; Undefined user function
ERR_BFN equ     52                      ; Bad file number
ERR_DT  equ     24                      ; Device Timeout (le pont ne repond pas)
ERR_FNF equ     53                      ; File not found
ERR_BFM equ     54                      ; Bad file mode
ERR_FAO equ     55                      ; File already open
ERR_DIO equ     57                      ; Disk I/O error
ERR_FAE equ     58                      ; File already exists
ERR_DF  equ     61                      ; Disk full
ERR_BN  equ     64                      ; Bad file name
ERR_DUN equ     68                      ; Device unavailable
ERR_IPE equ     62                      ; Input past end
ERR_DSF equ     66                      ; Direct statement in file
ERR_DNR equ     71                      ; Disk not Ready
ERR_LB  equ     23                      ; Line buffer overflow
ERR_FN  equ     26                      ; FOR Without NEXT
ERR_WH  equ     29                      ; WHILE without WEND
ERR_WE  equ     30                      ; WEND without WHILE
ERR_BRK equ     31                      ; Break

TY_INT   equ     2
TY_STR   equ     3
TY_SNG   equ     4

FR_FOR   equ     1                      ; marqueurs de cadres sur la pile
FR_GOSUB equ     2
FR_WHILE equ     3

; Raccourcis: levent l'erreur AL = n
%macro ERROR 1
        mov     al, %1
        jmp     bas_error
%endmacro

; STKCHK: erreur "Out of memory" si la pile approche de sa limite basse
%macro STKCHK 0
        cmp     sp, B_STKLIM + 96
        ja      %%ok
        ERROR   ERR_OM
%%ok:
%endmacro

; --- jetons (numero = 80h + rang dans lib/basic_tokens.inc) ---
; KW_MODE: 2 = definit le jeton T_<nom>; 0 = texte (kw_table, un label kwt_<nom> par
; mot-cle); 1 = gestionnaire (tok_handlers); 3 = numero du jeton si le mot commence par
; la lettre KW_LETTER (seau de kw_idx); 4 = adresse du texte (kw_ptr)
%macro KW 3
%if KW_MODE == 2
T_%1    equ     KW_N
%assign KW_N KW_N + 1
%elif KW_MODE == 0
kwt_%1:
        db      %2, 0
%elif KW_MODE == 3
%substr KW_C %2 1 1
%if KW_C == KW_LETTER
        db      T_%1 - 80h
%endif
%elif KW_MODE == 4
        dw      kwt_%1
%else
        dw      %3
%endif
%endmacro
%assign KW_MODE 2
%assign KW_N 80h
%include "lib/basic_tokens.inc"

; --- disposition memoire du segment de travail (1000h) ---
B_IBUF  equ     0400h                   ; tampon de saisie (256 octets)
B_TBUF  equ     0500h                   ; tampon de ligne tokenisee (512 octets)
B_NBUF  equ     0700h                   ; tampon de mise en forme des nombres (48 octets)
B_VSTK  equ     0740h                   ; pile de valeurs des expressions: 128 entrees de 8 octets
B_VSTKE equ     0B40h
B_HIST  equ     0B40h                   ; derniere commande saisie au prompt (192 octets, zero final)
B_TXT   equ     0C00h                   ; debut du programme
B_STRTOP equ    0DFF0h                  ; haut de l'espace des chaines (descend)
B_STK   equ     0F3F0h                  ; sommet de la pile
B_STKLIM equ    0E000h                  ; limite basse de la pile

; --- variables de l'interpreteur (a partir de 0100h) ---
%assign BVP 0100h
%macro BVAR 2
%1      equ     BVP
%assign BVP BVP + %2
%endmacro

BVAR    arg_t, 1                        ; arg_t/arg_own et fac_t/fac_own: ADJACENTS (mot)
BVAR    arg_own, 1                      ; arg_own = 1: chaine temporaire possedee (voir eval)
BVAR    arg_v, 4
BVAR    fac_t, 1
BVAR    fac_own, 1
BVAR    fac_v, 4
; -- bibliotheque flottante (lib/basic_float.asm, basic_fmath.asm)
BVAR    fl_ua, 8
BVAR    fl_ub, 8
BVAR    fl_q64, 8
BVAR    fl_r64, 8
BVAR    fl_st, 1
BVAR    fl_dz, 1
BVAR    fl_dq, 1
BVAR    fl_sgn, 1
BVAR    fl_fl, 1
BVAR    fl_tmp, 4
BVAR    fl_t0, 4
BVAR    fl_t1, 4
BVAR    fl_t2, 4
BVAR    fl_t3, 4
BVAR    fl_t4, 4
BVAR    fl_t5, 4
BVAR    fl_t6, 4
BVAR    fl_t7, 4
BVAR    fl_t8, 4
BVAR    fl_t9, 4
BVAR    fl_x, 4
BVAR    fl_k, 2
BVAR    fl_cnt, 1
BVAR    fl_inv, 1
BVAR    fl_sgw, 2
BVAR    fl_dig, 8
BVAR    fl_dexp, 2
BVAR    fl_fsg, 1
BVAR    fl_try, 1
BVAR    fl_m, 4
BVAR    fl_dx, 2
BVAR    fl_nd, 1
BVAR    fl_dot, 1
BVAR    fl_any, 1
BVAR    fl_ng, 1
BVAR    fl_isf, 1
BVAR    fl_sgnok, 1
BVAR    fl_en, 1
BVAR    fl_si0, 2
; -- etat de l'interpreteur
BVAR    b_savsp, 2                      ; SP de l'appelant (menu)
BVAR    b_stkbase, 2                    ; SP de la boucle principale (deroulement des erreurs)
BVAR    b_vartab, 2                     ; debut des variables simples (= fin du programme)
BVAR    b_arytab, 2                     ; debut des tableaux
BVAR    b_strend, 2                     ; fin des tableaux (debut de la memoire libre)
BVAR    b_fretop, 2                     ; bas de l'espace des chaines
BVAR    b_curlin, 2                     ; numero de la ligne courante (0FFFFh = mode direct)
BVAR    b_curptr, 2                     ; adresse de la ligne courante
BVAR    b_oldtxt, 2                     ; pour CONT
BVAR    b_oldptr, 2
BVAR    b_oldlin, 2
BVAR    b_datptr, 2                     ; pointeur DATA (0 = debut du programme)
BVAR    b_datln, 2
BVAR    b_col, 1                        ; colonne d'affichage courante
BVAR    b_tron, 1
BVAR    b_defseg, 2                     ; DEF SEG
BVAR    b_seed, 4                       ; graine RND
BVAR    b_lastrnd, 4                    ; derniere valeur de RND
BVAR    b_deftbl, 26                    ; type par defaut de chaque lettre (DEFINT...)
BVAR    b_vsp, 2                        ; pointeur de la pile de valeurs
BVAR    b_lineno, 2                     ; numero de la ligne tokenisee
BVAR    b_hasline, 1
BVAR    b_wlen, 1
BVAR    b_word, 48                      ; mot en cours de tokenisation
BVAR    b_t1, 2                         ; temporaires de travail
BVAR    b_t2, 2
BVAR    b_t3, 2
BVAR    b_t4, 2
BVAR    b_t5, 2
BVAR    b_t6, 2
BVAR    b_t7, 2
BVAR    b_t8, 2
BVAR    b_bb1, 1
BVAR    b_bb2, 1
BVAR    b_bb3, 1
BVAR    b_run, 1                        ; 1 si un programme s'execute
BVAR    b_zone, 1
BVAR    b_kh, 1                         ; file d'attente des touches (INKEY$/INPUT$)
BVAR    b_kt, 1
BVAR    b_kq, 16
BVAR    b_brk, 1                        ; 1 si bas_getline a ete interrompu par Ctrl-C
BVAR    b_oldsi, 2                      ; pour CONT
BVAR    b_datmode, 1                    ; 0 = chercher DATA depuis b_datptr, 1 = b_datptr sur un element
BVAR    b_pfl, 1                        ; PRINT: dernier separateur
BVAR    b_inp0, 2                       ; INPUT: debut de la liste de variables
BVAR    b_inpp, 2                       ; INPUT: texte de l'invite
BVAR    b_inpl, 1
BVAR    b_inpq, 1                       ; 1 = afficher "? "
BVAR    b_inpmode, 1                    ; 1 = LINE INPUT
BVAR    b_ip, 2                         ; INPUT: pointeur dans la ligne saisie (0 = epuisee)
BVAR    b_forlim, 4
BVAR    b_qflag, 1                      ; la ligne saisie contenait un '?' (raccourci de PRINT)
BVAR    b_el, 2                         ; EDIT: longueur de la ligne
BVAR    b_ec, 2                         ; EDIT: position du curseur
BVAR    b_edp, 1                        ; EDIT: parametre de sequence ANSI
BVAR    b_lastln, 2                     ; derniere ligne entree/listee/en erreur (EDIT .)
BVAR    b_forstep, 4
BVAR    b_nfn, 1                        ; nombre de DEF FN
BVAR    b_idx, 16                       ; indices d'un acces tableau
BVAR    b_bnd, 16                       ; bornes d'un DIM
BVAR    b_fntab, 192                    ; DEF FN: 16 entrees de 12 octets
BVAR    b_g1, 2                         ; variables du ramasse-miettes
BVAR    b_g2, 2
BVAR    b_g3, 2
BVAR    b_g4, 2
BVAR    b_dmode, 1                      ; LOAD (0) ou MERGE (1)
BVAR    b_dlen, 2                       ; LOAD: longueur de la ligne en cours d'assemblage
BVAR    b_ovr, 1                        ; correcteur de ligne: 1 = mode ecrasement (touche Inser)
BVAR    b_hist, 1                       ; 1 = la fleche haut rappelle la derniere commande (prompt seulement)
BVAR    b_fmode, 1                      ; fichier de donnees: 0 ferme, 1 lecture, 2 ecriture, 3 ajout
BVAR    b_fnew, 1                       ; mode demande par OPEN
BVAR    b_fout, 1                       ; 1 = bas_putc ecrit dans le fichier (PRINT# / WRITE#)
BVAR    b_fcol, 1                       ; colonne dans le fichier
BVAR    b_ccol, 1                       ; colonne de la console (sauvee pendant PRINT#)
BVAR    b_ferr, 1                       ; erreur d'ecriture differee (etat FSE_*, 0FFh = delai)
BVAR    b_rpos, 1                       ; tampon de lecture: position, longueur, fin de fichier
BVAR    b_rlen, 1
BVAR    b_reof, 1
BVAR    b_fwlen, 1                      ; tampon d'ecriture: octets en attente
BVAR    b_fname, 13                     ; nom du fichier ouvert (zero final)
BVAR    b_rbuf, 32
BVAR    b_wbuf, 32
BVAR    b_rtc, 8                        ; heure lue au pont: annee (2), mois, jour, h, min, s, centiemes
%if BVP > B_IBUF
%error "variables de l'interpreteur trop nombreuses"
%endif

; ============================================================
; Point d'entree: basic_run (appele depuis le menu, DS=CS)
; ============================================================
basic_run:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es
        push    ds
        cld
        mov     ax, VAR_SEG
        mov     ds, ax
        mov     es, ax
        mov     [b_savsp], sp
        mov     sp, B_STK
        mov     word [b_stkbase], B_STK
        mov     byte [b_kh], 0
        mov     byte [b_kt], 0
        mov     byte [b_brk], 0
        mov     byte [b_tron], 0
        mov     byte [b_fmode], 0       ; aucun fichier de donnees ouvert
        mov     byte [b_hist], 0
        mov     byte [B_HIST], 0        ; pas encore de commande a rappeler
        mov     byte [b_fout], 0
        mov     byte [b_ferr], 0
        sti
        ; graine initiale (brassee ensuite par l'attente de saisie)
        mov     word [b_seed], 0ACE1h
        mov     word [b_seed+2], 5A5Ah
        mov     word [b_defseg], VAR_SEG
        call    bas_new
        mov     si, msg_banner
        call    bas_puts_cs
        ; --- boucle principale ---
bas_ready:
        mov     sp, [b_stkbase]
        mov     byte [b_run], 0
        mov     word [b_curlin], 0FFFFh
        cmp     byte [b_col], 0
        je      .ok
        call    bas_crlf
.ok:
        mov     si, msg_ok
        call    bas_puts_cs
bas_prompt:
        mov     sp, [b_stkbase]
        mov     byte [b_hist], 1        ; fleche haut = rappel de la derniere commande
        call    bas_getline             ; SI = tampon de saisie, zero termine
        mov     byte [b_hist], 0
        call    hist_save
bas_gotline:                            ; (aussi appele par EDIT avec la ligne editee)
        mov     sp, [b_stkbase]
        mov     si, B_IBUF
        call    skip_sp
        or      al, al
        jz      bas_prompt              ; ligne vide
        call    bas_tokenize            ; -> B_TBUF (jetons), b_hasline/b_lineno
        cmp     byte [b_qflag], 0
        je      .noq
        call    echo_rewrite            ; '?' -> PRINT: reaffiche la ligne avec le vrai mot-cle
.noq:
        cmp     byte [b_hasline], 0
        jne     .edit
        ; commande directe
        mov     word [b_curlin], 0FFFFh
        mov     word [b_curptr], 0
        mov     si, B_TBUF
        mov     byte [b_run], 1
        jmp     bas_stmt
.edit:
        call    prog_edit
        jmp     bas_prompt

; bas_exit: retour au menu (restaure pile, segments et registres)
bas_exit:
        call    file_close_all          ; vide et ferme le fichier de donnees ouvert
        mov     sp, [b_savsp]
        pop     ds
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; Entrees/sorties (terminal UART)
; ============================================================
; bas_putc: envoie AL. Preserve tous les registres. Suit la colonne.
bas_putc:
        push    ax
        cmp     byte [b_fout], 0
        jne     .file
        call    uart_tx_byte
        jmp     .col
.file:
        call    file_put                ; PRINT# / WRITE#: octet vers le fichier ouvert
.col:
        cmp     al, 13
        jne     .n13
        mov     byte [b_col], 0
        jmp     .done
.n13:
        cmp     al, 8
        jne     .n8
        cmp     byte [b_col], 0
        je      .done
        dec     byte [b_col]
        jmp     .done
.n8:
        cmp     al, 9
        jne     .n9
        mov     al, [b_col]
        or      al, 7
        inc     al
        mov     [b_col], al
        jmp     .done
.n9:
        cmp     al, 32
        jb      .done
        inc     byte [b_col]
.done:
        pop     ax
        ret

bas_crlf:
        push    ax
        mov     al, 13
        call    bas_putc
        mov     al, 10
        call    bas_putc
        pop     ax
        ret

; bas_puts: chaine zero-terminee en RAM (DS:SI). Preserve SI.
bas_puts:
        push    si
        push    ax
.l:
        lodsb
        or      al, al
        jz      .d
        call    bas_putc
        jmp     .l
.d:
        pop     ax
        pop     si
        ret

; bas_puts_cs: chaine zero-terminee en ROM (CS:SI). Preserve SI.
bas_puts_cs:
        push    si
        push    ax
.l:
        mov     al, [cs:si]
        inc     si
        or      al, al
        jz      .d
        call    bas_putc
        jmp     .l
.d:
        pop     ax
        pop     si
        ret

; bas_rawin: attend un octet du terminal (scrute; brasse la graine). AL = octet.
bas_rawin:
.w:
        call    bas_inkey
        jnc     .got
        inc     word [b_seed]
        jmp     .w
.got:
        ret

; bas_inkey: octet du terminal sans attendre. CF=1 si aucun; sinon AL.
bas_inkey:
        push    bx
        mov     bl, [b_kh]
        cmp     bl, [b_kt]
        je      .hw
        xor     bh, bh
        mov     al, [b_kq + bx]
        inc     bl
        and     bl, 0Fh
        mov     [b_kh], bl
        pop     bx
        clc
        ret
.hw:
        pop     bx
        call    uart_rx_available
        jc      .none
        call    uart_rx_byte
        clc
        ret
.none:
        stc
        ret

; bas_chkbrk: surveille le terminal entre deux instructions: Ctrl-C = Break,
; Ctrl-X = menu, autre octet = mis en file (15 touches) pour INKEY$/INPUT$
; (les suivantes sont perdues si la file est pleine). Detruit AX.
bas_chkbrk:
        call    uart_rx_available
        jc      .ret
        call    uart_rx_byte
        cmp     al, 3
        je      bas_break
        cmp     al, 18h
        je      bas_exit
        push    bx
        mov     bl, [b_kt]
        xor     bh, bh
        mov     [b_kq + bx], al
        inc     bl
        and     bl, 0Fh
        cmp     bl, [b_kh]
        je      .full
        mov     [b_kt], bl
.full:
        pop     bx
        jmp     bas_chkbrk
.ret:
        ret

; bas_break: interruption (Ctrl-C ou STOP). Conserve les cadres de la pile et
; le point de reprise pour CONT. SI = debut de l'instruction interrompue.
bas_break:
        mov     [b_oldsi], si
        mov     ax, [b_curptr]
        mov     [b_oldptr], ax
        mov     ax, [b_curlin]
        mov     [b_oldlin], ax
        mov     [b_stkbase], sp
        cmp     word [b_curlin], 0FFFFh
        jne     .go
        mov     word [b_oldptr], 0      ; commande directe: pas de CONT
.go:
        ERROR   ERR_BRK

; bas_getline: lit une ligne (echo, BS/DEL, Ctrl-C annule, Ctrl-X quitte) dans
; B_IBUF (zero termine, 254 max). Les sequences ANSI (fleches...) sont avalees.
bas_getline:
        mov     byte [b_brk], 0
        mov     di, B_IBUF
        mov     byte [b_bb1], 0         ; etat ESC: 0 normal, 1 ESC vu, 2 dans la sequence
.next:
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
        jmp     .next
.inseq:
        cmp     al, 40h
        jb      .next
        cmp     al, 7Eh
        ja      .next
        mov     byte [b_bb1], 0
        cmp     al, 'A'                 ; fleche haut (ESC [ A ou ESC O A)
        jne     .next
        cmp     byte [b_hist], 0
        je      .next
        cmp     byte [B_HIST], 0
        je      .next                   ; rien a rappeler
        jmp     hist_edit               ; rappel + edition (curseur a la fin)
.normal:
        cmp     al, 1Bh
        jne     .noesc
        mov     byte [b_bb1], 1
        jmp     .next
.noesc:
        cmp     al, 18h                 ; Ctrl-X: quitte
        jne     .nx
        jmp     bas_exit
.nx:
        cmp     al, 3                   ; Ctrl-C: annule la ligne
        jne     .nc
        mov     al, '^'
        call    bas_putc
        mov     al, 'C'
        call    bas_putc
        call    bas_crlf
        mov     di, B_IBUF
        mov     byte [di], 0
        mov     byte [b_brk], 1
        ret
.nc:
        cmp     al, 7Fh
        jne     .nd
        mov     al, 8
.nd:
        cmp     al, 8
        jne     .nb
        cmp     di, B_IBUF
        jbe     .next
        dec     di
        mov     al, 8
        call    bas_putc
        mov     al, ' '
        call    bas_putc
        mov     al, 8
        call    bas_putc
        jmp     .next
.nb:
        cmp     al, 13
        jne     .ncr
        mov     byte [di], 0
        call    bas_crlf
        ret
.ncr:
        cmp     al, 32
        jb      .next                   ; autres caracteres de controle: ignores
        cmp     di, B_IBUF + 254
        jae     .next
        call    bas_putc
        stosb
        jmp     .next

; hist_save: memorise la ligne saisie (B_IBUF) comme derniere commande. Une ligne vide, ou trop
; longue pour B_HIST (191 caracteres), ne remplace pas la precedente.
hist_save:
        push    cx
        push    si
        push    di
        mov     si, B_IBUF
        xor     cx, cx
.l:
        cmp     byte [si], 0
        je      .e
        inc     si
        inc     cx
        jmp     .l
.e:
        jcxz    .r
        cmp     cx, 191
        ja      .r
        inc     cx                      ; avec le zero final
        mov     si, B_IBUF
        mov     di, B_HIST
        rep     movsb
.r:
        pop     di
        pop     si
        pop     cx
        ret

; hist_edit: fleche haut au prompt. La derniere commande (B_HIST) devient la ligne editee
; (b_el = b_ec = sa longueur: le curseur est a la FIN) et passe au correcteur de ligne de EDIT
; (bas_editbuf: fleches gauche/droite, Debut/Fin, Insert, Suppr, retour arriere, Ctrl-K);
; Entree valide, Ctrl-C annule. Saute ici depuis bas_getline: le RET rend la main a l'appelant de
; bas_getline (bas_prompt) avec B_IBUF = ligne validee, comme une saisie normale.
hist_edit:
        mov     si, B_HIST
        mov     di, B_IBUF
        xor     cx, cx
.c:
        lodsb
        stosb
        or      al, al
        jz      .d
        inc     cx
        jmp     .c
.d:
        mov     [b_el], cx
        mov     [b_ec], cx
        call    bas_editbuf
        jc      .cancel
        ret
.cancel:
        mov     byte [B_IBUF], 0
        mov     byte [b_brk], 1
        ret

; skip_sp: SI avance sur les espaces; AL = premier caractere non espace (SI le designe).
skip_sp:
.l:
        mov     al, [si]
        cmp     al, ' '
        jne     .d
        inc     si
        jmp     .l
.d:
        ret

; ============================================================
; Erreurs
; ============================================================
; bas_error: AL = numero d'erreur. Affiche le message (et " in <ligne>"), puis
; retourne au "Ok". Ne revient jamais.
bas_error:
        cmp     byte [b_fout], 0
        je      .con
        call    file_out_abort          ; le message va a la console, pas au fichier
.con:
        mov     [b_bb2], al
        cmp     word [b_curlin], 0FFFFh
        je      .nolast
        mov     dx, [b_curlin]
        mov     [b_lastln], dx
.nolast:
        mov     word [b_vsp], B_VSTK
        mov     word [fac_t], TY_INT
        mov     word [arg_t], TY_INT
        cmp     al, ERR_BRK
        je      .keep
        mov     word [b_stkbase], B_STK
        mov     word [b_oldptr], 0
.keep:
        mov     sp, [b_stkbase]
        cmp     byte [b_col], 0
        je      .nocr
        call    bas_crlf
.nocr:
        ; trouve le message n dans msg_err: entrees [numero][texte][0], fin 0FFh
        mov     si, msg_err
        mov     cl, [b_bb2]
.find:
        mov     al, [cs:si]
        inc     si
        cmp     al, 0FFh
        je      .unk
        cmp     al, cl
        je      .found
.skip:
        mov     al, [cs:si]
        inc     si
        or      al, al
        jnz     .skip
        jmp     .find
.unk:
        mov     si, msg_unk
.found:
        call    bas_puts_cs
        cmp     word [b_curlin], 0FFFFh
        je      .noline
        mov     si, msg_in
        call    bas_puts_cs
        mov     ax, [b_curlin]
        call    print_uint
.noline:
        call    bas_crlf
        jmp     bas_ready

; print_uint: affiche AX (non signe) en decimal. Preserve tous les registres.
print_uint:
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
        call    bas_putc
        loop    .p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret


; ============================================================
; Tokenisation: SI = texte source (zero termine) -> B_TBUF.
; Sortie: b_hasline/b_lineno (ligne numerotee ?). Le corps commence a B_TBUF.
; ============================================================
bas_tokenize:
        mov     di, B_TBUF
        mov     byte [b_hasline], 0
        mov     byte [b_qflag], 0
        call    skip_sp
        cmp     al, '0'
        jb      .body
        cmp     al, '9'
        ja      .body
        xor     bx, bx                  ; numero de ligne
.dl:
        mov     al, [si]
        cmp     al, '0'
        jb      .dd
        cmp     al, '9'
        ja      .dd
        inc     si
        sub     al, '0'
        mov     ah, 0
        mov     cx, ax
        mov     ax, bx
        mov     dx, 10
        mul     dx
        add     ax, cx
        mov     bx, ax
        jmp     .dl
.dd:
        mov     [b_lineno], bx
        mov     byte [b_hasline], 1
        cmp     byte [si], ' '
        jne     .body
        inc     si
.body:
.loop:
        mov     al, [si]
        or      al, al
        jnz     .nz
        jmp     .end
.nz:
        cmp     al, ' '
        jne     .nsp
        inc     si
        stosb                           ; conserve les espaces (LIST fidele)
        jmp     .loop
.nsp:
        cmp     al, '"'
        jne     .nstr
        movsb                           ; guillemet ouvrant
.sl:
        mov     al, [si]
        or      al, al
        jz      .loop
        movsb
        cmp     al, '"'
        jne     .sl
        jmp     .loop
.nstr:
        cmp     al, '?'
        jne     .nq
        inc     si
        mov     byte [b_qflag], 1
        mov     al, T_PRINT
        stosb
        mov     al, [si]                ; ?RND -> PRINT RND: espace si un mot suit directement
        and     al, 0DFh
        cmp     al, 'A'
        jb      .loop
        cmp     al, 'Z'
        ja      .loop
        mov     al, ' '
        stosb
        jmp     .loop
.nq:
        cmp     al, "'"
        jne     .nap
        inc     si
        mov     al, T_SQ
        stosb
        jmp     .rest
.nap:
        cmp     al, '&'
        jne     .namp
        movsb                           ; &H / &O
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'H'
        je      .amp1
        cmp     al, 'O'
        jne     .loop
.amp1:
        stosb
        inc     si
.hx:
        mov     al, [si]
        call    is_hex
        jnc     .loop
        and     al, 0DFh
        cmp     al, 'A'
        jb      .hxc
        cmp     al, 'F'
        ja      .hxc
        jmp     .hxs
.hxc:
        mov     al, [si]
.hxs:
        stosb
        inc     si
        jmp     .hx
.namp:
        cmp     al, '.'
        je      .num
        cmp     al, '0'
        jb      .nnum
        cmp     al, '9'
        ja      .nnum
.num:
        call    copy_number
        jmp     .loop
.nnum:
        ; lettre ?
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .other
        cmp     ah, 'Z'
        ja      .other
        call    tok_word
        cmp     al, T_REM
        je      .rest
        cmp     al, T_SQ
        je      .rest
        cmp     al, T_DATA
        je      .data
        jmp     .loop
.other:
        movsb
        jmp     .loop
.rest:                                  ; copie le reste de la ligne tel quel
        lodsb
        or      al, al
        jz      .end0
        stosb
        jmp     .rest
.data:                                  ; DATA: jusqu'a ':' hors guillemets
        mov     bl, 0
.dl2:
        mov     al, [si]
        or      al, al
        jz      .end
        cmp     al, '"'
        jne     .dq
        xor     bl, 1
.dq:
        cmp     al, ':'
        jne     .dc
        or      bl, bl
        jz      .loop
.dc:
        movsb
        jmp     .dl2
.end0:
        dec     si
.end:
        xor     al, al
        stosb
        ret

; is_hex: AL = caractere; CF=1 si 0-9 A-F a-f
is_hex:
        cmp     al, '0'
        jb      .n
        cmp     al, '9'
        jbe     .y
        and     al, 0DFh
        cmp     al, 'A'
        jb      .n
        cmp     al, 'F'
        jbe     .y
.n:
        clc
        ret
.y:
        stc
        ret

; copy_number: copie un litteral numerique de [SI] vers [DI] (chiffres, '.', exposant)
copy_number:
.d1:
        mov     al, [si]
        cmp     al, '0'
        jb      .dot
        cmp     al, '9'
        ja      .dot
        movsb
        jmp     .d1
.dot:
        cmp     al, '.'
        jne     .exp
        movsb
        jmp     .d1
.exp:
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'E'
        je      .e
        cmp     ah, 'D'
        jne     .done
.e:
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
        jb      .done
        cmp     al, '9'
        ja      .done
        mov     al, ah                  ; E/D en majuscule
        stosb
        inc     si
        mov     al, [si]
        cmp     al, '+'
        je      .sg
        cmp     al, '-'
        jne     .ex
.sg:
        movsb
.ex:
        mov     al, [si]
        cmp     al, '0'
        jb      .done
        cmp     al, '9'
        ja      .done
        movsb
        jmp     .ex
.done:
        mov     al, [si]                ; suffixe de type eventuel (%, !, #)
        cmp     al, '%'
        je      .suf
        cmp     al, '!'
        je      .suf
        cmp     al, '#'
        jne     .ret
.suf:
        movsb
.ret:
        ret

; tok_word: SI sur une lettre. Lit un mot (lettres/chiffres + suffixe $ % ! #),
; le cherche dans la table des mots-cles. Emet le jeton (ou l'identifiant en
; majuscules) dans [DI]. Retour: AL = jeton emis (0 si identifiant).
tok_word:
        mov     bx, b_word
        xor     cx, cx
.wl:
        mov     al, [si]
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .wd
        cmp     ah, 'Z'
        ja      .wd
        mov     al, ah                  ; majuscule
        jmp     .ws
.wd:
        cmp     al, '0'
        jb      .suffix
        cmp     al, '9'
        ja      .suffix
.ws:
        cmp     cx, 40
        jae     .skipc
        mov     [bx], al
        inc     bx
        inc     cx
.skipc:
        inc     si
        jmp     .wl
.suffix:
        cmp     al, '$'
        je      .sf
        cmp     al, '%'
        je      .sf
        cmp     al, '!'
        je      .sf
        cmp     al, '#'
        jne     .wend
        mov     byte [bx], 0            ; PRINT# INPUT# WRITE# CLOSE#: '#' apres un mot-cle
        mov     [b_wlen], cl            ; n'est pas un suffixe de type
        push    cx
        call    kw_lookup
        pop     cx
        or      al, al
        mov     al, '#'
        jnz     .wend
.sf:
        mov     [bx], al
        inc     bx
        inc     cx
        inc     si
.wend:
        mov     byte [bx], 0
        mov     [b_wlen], cl
        ; mot suivi de '(' : essaie "MOT(" (TAB( SPC()
        cmp     byte [si], '('
        jne     .plain
        mov     byte [bx], '('
        mov     byte [bx+1], 0
        push    cx
        call    kw_lookup
        pop     cx
        or      al, al
        jz      .nolp
        inc     si                      ; consomme '('
        stosb
        ret
.nolp:
        mov     byte [bx], 0
.plain:
        call    kw_lookup
        or      al, al
        jz      .notkw
        stosb
        ret
.notkw:
        ; mot commencant par FN (+ lettres) : jeton FN puis le nom
        cmp     word [b_word], 'FN'
        jne     .split
        cmp     byte [b_wlen], 3
        jb      .split
        mov     al, T_FN
        stosb
        mov     bx, b_word + 2
        jmp     .emit
.split:
        ; mot = mot-cle + chiffres (GOTO100, THEN20...)
        mov     cl, [b_wlen]
        xor     ch, ch
        mov     bx, b_word
        add     bx, cx
.tr:
        cmp     bx, b_word
        jbe     .ident
        mov     al, [bx-1]
        cmp     al, '0'
        jb      .trd
        cmp     al, '9'
        ja      .trd
        dec     bx
        jmp     .tr
.trd:
        cmp     bx, b_word
        jbe     .ident
        cmp     byte [bx], 0
        je      .ident                  ; pas de chiffres finaux
        ; teste le prefixe [b_word, bx)
        mov     dl, [bx]
        mov     byte [bx], 0
        push    bx
        push    dx
        call    kw_lookup
        pop     dx
        pop     bx
        mov     [bx], dl
        or      al, al
        jz      .ident
        stosb                           ; jeton
        jmp     .emit                   ; puis les chiffres (BX -> chiffres)
.ident:
        mov     bx, b_word
.emit:
        mov     al, [bx]
        or      al, al
        jz      .edone
        stosb
        inc     bx
        jmp     .emit
.edone:
        xor     al, al                  ; identifiant (ou fin d'emission)
        ret

; kw_lookup: cherche b_word (majuscules, zero termine) dans la table des mots-cles.
; Retour AL = jeton (>= 80h) ou 0. Preserve BX, SI, DI. Recherche par SEAU: kw_idx
; donne, pour la premiere lettre, la liste des numeros de jeton (terminee par 0FFh);
; kw_ptr donne l'adresse du texte de chaque mot-cle (tout est construit a
; l'assemblage, voir lib/basic_data.asm). ~ 10 fois plus rapide qu'un balayage
; complet (les mots inconnus, c.-a-d. presque tous les identifiants, le parcouraient
; en entier).
kw_lookup:
        push    bx
        push    si
        push    di
        mov     al, [b_word]
        sub     al, 'A'
        cmp     al, 26
        jae     .none                   ; ne commence pas par une lettre
        xor     ah, ah
        shl     ax, 1
        mov     bx, ax
        mov     si, [cs:kw_idx + bx]    ; seau de cette lettre
.next:
        mov     al, [cs:si]
        inc     si
        cmp     al, 0FFh
        je      .none
        xor     ah, ah
        mov     bx, ax
        shl     bx, 1
        mov     di, [cs:kw_ptr + bx]    ; texte du mot-cle candidat
        push    si
        mov     si, b_word
.c:
        mov     ah, [cs:di]
        cmp     ah, [si]
        jne     .no
        or      ah, ah
        jz      .found
        inc     di
        inc     si
        jmp     .c
.no:
        pop     si
        jmp     .next
.found:
        pop     si
        add     al, 80h                 ; AL = numero de jeton (non modifie par la comparaison)
        jmp     .out
.none:
        xor     al, al
.out:
        pop     di
        pop     si
        pop     bx
        ret

; --- bibliotheques et modules de l'interpreteur ---
%include "lib/basic_float.asm"
%include "lib/basic_fmath.asm"
%include "lib/basic_eval.asm"
%include "lib/basic_str.asm"
%include "lib/basic_stmt.asm"
%include "lib/basic_func.asm"
%include "lib/basic_disk.asm"
%include "lib/basic_data.asm"

%endif ; BASIC_ASM
