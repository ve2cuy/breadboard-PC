; ============================================================
; basic_disk.asm - disque du BASIC: SAVE, LOAD, MERGE, RUN "f", FILES, KILL, FORMAT
; (fichiers a la racine de la flash du pont STM32, voir lib/bridge.asm)
; Les programmes sont enregistres en TEXTE ASCII (une ligne par ligne, CR LF), comme
; le SAVE "f",A de GW-BASIC: relisibles au PC et rechargeables par la saisie normale.
; Nom: majuscules, 1 a 12 caracteres; ".BAS" est ajoute si le nom n'a pas de point.
; ============================================================
; dsk_errmap: etat FSE_* -> numero d'erreur BASIC
dsk_errmap:
        db      0, ERR_DNR, ERR_FNF, ERR_FAE, ERR_DIO, ERR_BN, ERR_FAO, ERR_BFM, ERR_DF, ERR_DUN, ERR_DIO

; disk_chk: apres un appel fs_*: CF = 1 -> Device Timeout; AL <> 0 -> erreur disque
disk_chk:
        jnc     .a
        ERROR   ERR_DT
.a:
        or      al, al
        jz      .ok
        cmp     al, 10
        jbe     .m
        mov     al, 10
.m:
        xor     ah, ah
        mov     bx, ax
        mov     al, [cs:dsk_errmap + bx]
        jmp     bas_error
.ok:
        ret

; disk_name: expression chaine a [SI] -> B_NBUF (majuscules, zero final). DL = 1: ajoute
; ".BAS" si le nom n'a pas de point. Erreur Bad file name si la longueur n'est pas 1-12.
disk_name:
        push    dx
        call    eval_str
        pop     dx
        push    dx
        call    ck_str
        pop     dx
        mov     di, bx
        xor     cl, cl                  ; CL = 1 si un point a ete vu
.u:
        mov     al, [di]
        or      al, al
        jz      .e
        cmp     al, 'a'
        jb      .n
        cmp     al, 'z'
        ja      .n
        sub     al, 32
        mov     [di], al
.n:
        cmp     al, '.'
        jne     .nx
        mov     cl, 1
.nx:
        inc     di
        jmp     .u
.e:
        cmp     di, B_NBUF
        je      .bad                    ; nom vide
        or      dl, dl
        jz      .chk
        or      cl, cl
        jnz     .chk
        mov     byte [di], '.'
        mov     byte [di+1], 'B'
        mov     byte [di+2], 'A'
        mov     byte [di+3], 'S'
        mov     byte [di+4], 0
        add     di, 4
.chk:
        mov     ax, di
        sub     ax, B_NBUF
        cmp     ax, 1
        jb      .bad
        cmp     ax, 12
        ja      .bad
        ret
.bad:
        ERROR   ERR_BN

; SAVE "f"[,A]
st_save:
        call    disk_nofile
        mov     dl, 1
        call    disk_name
        call    skip_stmt               ; ",A" et autres options ignorees
        push    si
        mov     si, B_NBUF
        mov     al, FS_MODE_WRITE
        call    fs_open
        call    disk_chk
        mov     bx, B_TXT
.l:
        cmp     word [bx], 0
        je      .done
        push    bx
        call    detok_line              ; B_IBUF = "numero corps", b_el = longueur
        mov     di, B_IBUF
        add     di, [b_el]
        mov     word [di], 0A0Dh        ; CR LF
        mov     cx, [b_el]
        add     cx, 2
        mov     si, B_IBUF
        call    fs_write
        call    disk_chk
        pop     bx
        mov     bx, [bx]                ; ligne suivante
        jmp     .l
.done:
        call    fs_close
        call    disk_chk
        pop     si
        jmp     bas_newstt

st_load:
        mov     byte [b_dmode], 0
        jmp     load_common
st_merge:
        mov     byte [b_dmode], 1
load_common:
        cmp     word [b_curlin], 0FFFFh
        je      .dok
        ERROR   ERR_ID                  ; mode direct seulement
.dok:
        mov     dl, 1
        call    disk_name
        call    disk_load
        jmp     bas_ready

; disk_load: charge le fichier B_NBUF (nom deja pret): LOAD (b_dmode = 0) efface d'abord
; le programme, MERGE (b_dmode = 1) le conserve. Chaque ligne du fichier est traitee comme
; une ligne saisie (tokenisation + insertion).
disk_load:
        call    disk_nofile
        mov     si, B_NBUF
        mov     al, FS_MODE_READ
        call    fs_open
        call    disk_chk
        cmp     byte [b_dmode], 0
        jne     .m
        call    bas_new
        mov     word [b_stkbase], B_STK
.m:
        mov     word [b_dlen], 0
.rd:
        mov     di, B_NBUF
        mov     cx, 32
        call    fs_read
        jnc     .r1
        ERROR   ERR_DT
.r1:
        jcxz    .eof
        mov     si, B_NBUF
.ch:
        push    cx
        lodsb
        push    si
        call    load_char
        pop     si
        pop     cx
        loop    .ch
        jmp     .rd
.eof:
        call    load_flush
        call    fs_close
        ret

; load_char: AL = caractere du fichier. CR/LF terminent la ligne.
load_char:
        cmp     al, 13
        je      load_flush
        cmp     al, 10
        je      load_flush
        cmp     al, 9
        jne     .nt
        mov     al, ' '
.nt:
        cmp     al, 32
        jb      .ret
        mov     bx, [b_dlen]
        cmp     bx, 250
        jb      .st
        ERROR   ERR_LB
.st:
        mov     [B_IBUF + bx], al
        inc     bx
        mov     [b_dlen], bx
.ret:
        ret

; load_flush: traite la ligne assemblee dans B_IBUF (si elle n'est pas vide)
load_flush:
        mov     bx, [b_dlen]
        or      bx, bx
        jz      .r
        mov     byte [B_IBUF + bx], 0
        mov     word [b_dlen], 0
        mov     si, B_IBUF
        call    skip_sp
        or      al, al
        jz      .r
        call    bas_tokenize
        cmp     byte [b_hasline], 0
        jne     .e
        ERROR   ERR_DSF                 ; instruction sans numero dans le fichier
.e:
        call    prog_edit
.r:
        ret

; put_udec32: DX:AX (non signe) -> chiffres decimaux a [DI] (DI avance)
put_udec32:
        push    bx
        push    cx
        push    si
        xor     cx, cx
        mov     bx, 10
.d:
        mov     si, ax                  ; poids faible
        mov     ax, dx
        xor     dx, dx
        div     bx                      ; AX = quotient haut, DX = reste
        xchg    ax, si                  ; AX = poids faible, SI = quotient haut
        div     bx                      ; DX:AX / 10 -> AX = quotient bas, DX = reste
        push    dx
        inc     cx
        mov     dx, si                  ; DX:AX = quotient
        mov     si, dx
        or      si, ax
        jnz     .d
.p:
        pop     ax
        add     al, '0'
        stosb
        loop    .p
        pop     si
        pop     cx
        pop     bx
        ret

; FILES: liste les fichiers (nom, taille) puis l'espace libre
st_files:
        call    skip_stmt
        push    si
        call    fs_dir_first
        call    disk_chk
.n:
        mov     di, B_IBUF
        call    fs_dir_next
        jnc     .a
        ERROR   ERR_DT
.a:
        or      al, al
        jz      .done
        mov     bl, al
        xor     bh, bh                  ; BX = longueur du nom
        mov     si, B_IBUF
        call    bas_puts                ; nom
        mov     cx, 13
        sub     cx, bx
        jbe     .np
.pd:
        mov     al, ' '
        call    bas_putc
        loop    .pd
.np:
        mov     si, B_IBUF + 1
        add     si, bx
        mov     ax, [si]                ; taille (4 octets)
        mov     dx, [si+2]
        mov     di, B_NBUF
        call    put_udec32
        mov     byte [di], 0
        mov     si, B_NBUF
        call    bas_puts
        call    bas_crlf
        call    bas_inkey               ; Ctrl-C interrompt la liste
        jc      .n
        cmp     al, 3
        jne     .n
        jmp     .end
.done:
        call    fs_free
        jc      .end
        mov     di, B_NBUF
        call    put_udec32
        mov     byte [di], 0
        mov     si, B_NBUF
        call    bas_puts
        mov     si, msg_dsk_free
        call    bas_puts_cs
.end:
        pop     si
        jmp     bas_newstt

; KILL "f" (nom exact, sans extension par defaut)
st_kill:
        call    disk_nofile
        xor     dl, dl
        call    disk_name
        push    si
        mov     si, B_NBUF
        call    fs_delete
        call    disk_chk
        pop     si
        jmp     bas_newstt

; FORMAT "YES": formate le disque (DETRUIT tous les fichiers)
st_format:
        call    disk_nofile
        call    eval_str
        call    ck_str
        mov     al, [bx]
        and     al, 0DFh
        cmp     al, 'Y'
        jne     .fc
        mov     al, [bx+1]
        and     al, 0DFh
        cmp     al, 'E'
        jne     .fc
        mov     al, [bx+2]
        and     al, 0DFh
        cmp     al, 'S'
        jne     .fc
        cmp     byte [bx+3], 0
        jne     .fc
        push    si
        call    fs_format
        call    disk_chk
        pop     si
        jmp     bas_newstt
.fc:
        ERROR   ERR_FC

; ============================================================
; Fichiers de DONNEES (un seul, numero 1): OPEN, CLOSE, PRINT#, WRITE#, INPUT#,
; LINE INPUT#, EOF(1). Le pont n'ouvre qu'un fichier a la fois: SAVE, LOAD, MERGE, RUN "f",
; KILL et FORMAT donnent "File already open" tant que le fichier de donnees est ouvert.
; Ecriture: tampon b_wbuf (32 octets) vide vers le pont quand il est plein et a la fermeture.
; Lecture: tampon b_rbuf (32 octets) rempli par blocs; INPUT#/LINE INPUT# lisent une ligne
; (fin CR, LF ou CR LF) dans B_IBUF puis reutilisent l'analyse des champs de INPUT.
; b_fmode: 0 ferme, 1 lecture (INPUT), 2 ecriture (OUTPUT), 3 ajout (APPEND).
; ============================================================
; disk_nofile: erreur "File already open" si un fichier de donnees est ouvert
disk_nofile:
        cmp     byte [b_fmode], 0
        je      .r
        ERROR   ERR_FAO
.r:
        ret

; file_num: [#]n [,] -> n doit valoir 1 ("Bad file number" sinon). La virgule est consommee.
file_num:
        call    skip_sp
        cmp     al, '#'
        jne     .n
        inc     si
.n:
        call    eval_int
        cmp     ax, 1
        je      .ok
        ERROR   ERR_BFN
.ok:
        call    skip_sp
        cmp     al, ','
        jne     .r
        inc     si
.r:
        ret

; file_chk_in: le fichier 1 doit etre ouvert en lecture
file_chk_in:
        mov     al, [b_fmode]
        cmp     al, 1
        je      .r
        or      al, al
        jz      .bfn
        ERROR   ERR_BFM
.bfn:
        ERROR   ERR_BFN
.r:
        ret

; file_chk_out: le fichier 1 doit etre ouvert en ecriture ou en ajout
file_chk_out:
        mov     al, [b_fmode]
        cmp     al, 2
        jae     .r
        or      al, al
        jz      .bfn
        ERROR   ERR_BFM
.bfn:
        ERROR   ERR_BFN
.r:
        ret

; --- ecriture -------------------------------------------------------------
; file_flush: envoie le tampon d'ecriture au pont. Preserve tout. Une erreur est memorisee
; dans b_ferr (elle est signalee a la fin de l'instruction ou a la fermeture).
file_flush:
        push    ax
        push    cx
        push    si
        xor     cx, cx
        mov     cl, [b_fwlen]
        jcxz    .r
        mov     byte [b_fwlen], 0
        mov     si, b_wbuf
        call    fs_write
        jc      .to
        or      al, al
        jz      .r
        mov     [b_ferr], al
        jmp     .r
.to:
        mov     byte [b_ferr], 0FFh
.r:
        pop     si
        pop     cx
        pop     ax
        ret

; file_put: AL -> tampon d'ecriture (appelee par bas_putc). Preserve tout.
file_put:
        push    ax
        push    bx
        cmp     byte [b_ferr], 0
        jne     .r                      ; erreur en attente: on jette la suite
        xor     bh, bh
        mov     bl, [b_fwlen]
        mov     [b_wbuf + bx], al
        inc     bl
        mov     [b_fwlen], bl
        cmp     bl, 32
        jb      .r
        call    file_flush
.r:
        pop     bx
        pop     ax
        ret

; file_chk_err: leve l'erreur d'ecriture differee (b_ferr)
file_chk_err:
        mov     al, [b_ferr]
        or      al, al
        jz      .r
        mov     byte [b_ferr], 0
        cmp     al, 0FFh
        je      .to
        clc
        jmp     disk_chk
.to:
        stc
        jmp     disk_chk
.r:
        ret

; file_out_begin: [SI] = '#': PRINT # / WRITE #: analyse "#1," et redirige bas_putc
file_out_begin:
        call    file_num
        call    file_chk_out
        mov     al, [b_col]
        mov     [b_ccol], al            ; colonne de la console
        mov     al, [b_fcol]
        mov     [b_col], al             ; TAB( , ; suivent la colonne du fichier
        mov     byte [b_fout], 1
        ret

; file_out_end: fin de PRINT # / WRITE #: retour a la console (erreur d'ecriture signalee)
file_out_end:
        call    file_out_abort
        jmp     file_chk_err

; file_out_abort: retour a la console (aussi appelee par bas_error). Preserve AX.
file_out_abort:
        push    ax
        mov     al, [b_col]
        mov     [b_fcol], al
        mov     al, [b_ccol]
        mov     [b_col], al
        mov     byte [b_fout], 0
        pop     ax
        ret

; --- lecture --------------------------------------------------------------
; file_fill: remplit le tampon de lecture. CF = 1: fin de fichier (rien de lu).
file_fill:
        cmp     byte [b_reof], 0
        jne     .eof
        push    cx
        push    di
        mov     di, b_rbuf
        mov     cx, 32
        call    fs_read
        jc      .err
        mov     byte [b_rpos], 0
        mov     [b_rlen], cl
        or      cx, cx
        pop     di
        pop     cx
        jnz     .ok
        mov     byte [b_reof], 1
.eof:
        mov     byte [b_rlen], 0
        mov     byte [b_rpos], 0
        stc
        ret
.ok:
        clc
        ret
.err:
        ERROR   ERR_DT

; file_eof: CF = 1 si plus rien a lire
file_eof:
        mov     al, [b_rpos]
        cmp     al, [b_rlen]
        jb      .no
        jmp     file_fill
.no:
        clc
        ret

; file_getc: AL = octet suivant; CF = 1 en fin de fichier. Preserve BX.
file_getc:
        push    bx
.again:
        xor     bh, bh
        mov     bl, [b_rpos]
        cmp     bl, [b_rlen]
        jb      .have
        call    file_fill
        jnc     .again
        pop     bx
        stc
        ret
.have:
        mov     al, [b_rbuf + bx]
        inc     bl
        mov     [b_rpos], bl
        pop     bx
        clc
        ret

; file_getline: lit une ligne du fichier dans B_IBUF (zero final, 254 max; l'excedent est
; ignore), b_ip = B_IBUF. "Input past end" si le fichier est deja epuise. Preserve SI.
file_getline:
        push    bx
        push    cx
        push    dx
        push    di
        mov     di, B_IBUF
        xor     cx, cx                  ; longueur lue
        xor     dh, dh                  ; 1 = un octet a ete consomme
.c:
        call    file_getc
        jc      .eof
        mov     dh, 1
        cmp     al, 13
        je      .cr
        cmp     al, 10
        je      .end
        cmp     cx, 254
        jae     .c
        stosb
        inc     cx
        jmp     .c
.cr:
        call    file_eof                ; un LF apres le CR fait partie de la fin de ligne
        jc      .end
        mov     bl, [b_rpos]
        xor     bh, bh
        cmp     byte [b_rbuf + bx], 10
        jne     .end
        inc     byte [b_rpos]
        jmp     .end
.eof:
        or      dh, dh
        jnz     .end
        ERROR   ERR_IPE
.end:
        mov     byte [di], 0
        mov     word [b_ip], B_IBUF
        pop     di
        pop     dx
        pop     cx
        pop     bx
        ret

; --- instructions ---------------------------------------------------------
; tx_word: CS:BX = mot en majuscules (zero final); [SI] = texte. CF = 0 si le mot est la
; (SI avance apres lui); il ne doit pas etre suivi d'une lettre ni d'un chiffre.
tx_word:
        push    si
        push    bx
        call    skip_sp
.l:
        mov     ah, [cs:bx]
        or      ah, ah
        jz      .end
        cmp     al, ah
        jne     .no
        inc     bx
        inc     si
        mov     al, [si]
        jmp     .l
.end:
        cmp     al, '0'
        jb      .yes
        cmp     al, '9'
        jbe     .no
        mov     ah, al
        and     ah, 0DFh
        cmp     ah, 'A'
        jb      .yes
        cmp     ah, 'Z'
        jbe     .no
.yes:
        add     sp, 4                   ; garde SI avance
        clc
        ret
.no:
        pop     bx
        pop     si
        stc
        ret

txt_output:     db      'OUTPUT', 0
txt_append:     db      'APPEND', 0
txt_as:         db      'AS', 0

; OPEN "f" FOR INPUT|OUTPUT|APPEND AS [#]1    ou    OPEN "I"|"O"|"A",[#]1,"f"
st_open:
        call    disk_nofile
        xor     dl, dl
        call    disk_name               ; 1re chaine: le nom (forme FOR) ou le mode (forme "O",#1,"f")
        call    skip_sp
        cmp     al, ','
        jne     .for
        inc     si                      ; forme "O",#1,"f"
        mov     al, [B_NBUF]
        cmp     byte [B_NBUF + 1], 0
        jne     .bm
        mov     bl, 1
        cmp     al, 'I'
        je      .m
        mov     bl, 2
        cmp     al, 'O'
        je      .m
        mov     bl, 3
        cmp     al, 'A'
        je      .m
.bm:
        ERROR   ERR_BFM                 ; ("R": acces direct, non gere)
.m:
        mov     [b_fnew], bl
        call    file_num
        xor     dl, dl
        call    disk_name               ; le nom du fichier
        call    open_name
        jmp     .go
.for:
        cmp     al, T_FOR
        je      .f1
        ERROR   ERR_SN
.f1:
        call    open_name               ; garde le nom
        inc     si
        call    skip_sp
        cmp     al, T_INPUT
        jne     .o1
        inc     si
        mov     byte [b_fnew], 1
        jmp     .as
.o1:
        mov     bx, txt_output
        call    tx_word
        jc      .a1
        mov     byte [b_fnew], 2
        jmp     .as
.a1:
        mov     bx, txt_append
        call    tx_word
        jnc     .a2
        ERROR   ERR_SN
.a2:
        mov     byte [b_fnew], 3
.as:
        mov     bx, txt_as
        call    tx_word
        jnc     .n
        ERROR   ERR_SN
.n:
        call    file_num
.go:
        push    si
        mov     si, b_fname
        mov     al, [b_fnew]
        dec     al                      ; FS_MODE_READ 0, WRITE 1, APPEND 2
        call    fs_open
        call    disk_chk
        pop     si
        mov     al, [b_fnew]
        mov     [b_fmode], al
        xor     al, al
        mov     [b_fcol], al
        mov     [b_ferr], al
        mov     [b_rpos], al
        mov     [b_rlen], al
        mov     [b_reof], al
        mov     [b_fwlen], al
        jmp     bas_newstt

; open_name: B_NBUF -> b_fname
open_name:
        push    si
        push    di
        push    cx
        mov     si, B_NBUF
        mov     di, b_fname
        mov     cx, 13
        rep     movsb
        pop     cx
        pop     di
        pop     si
        ret

; CLOSE [#1]
st_close:
        call    skip_sp
        or      al, al
        jz      .go
        cmp     al, ':'
        je      .go
        cmp     al, T_ELSE
        je      .go
        call    file_num
.go:
        push    si
        cmp     byte [b_fmode], 0
        je      .r
        call    file_close
        call    disk_chk
.r:
        pop     si
        jmp     bas_newstt

; file_close: vide le tampon d'ecriture, ferme le fichier ouvert. AL = etat, CF = delai
; (une erreur d'ecriture anterieure est rendue de preference).
file_close:
        cmp     byte [b_fmode], 2
        jb      .cl
        call    file_flush
.cl:
        mov     byte [b_fmode], 0
        call    fs_close
        pushf
        cmp     byte [b_ferr], 0
        je      .ok
        popf
        mov     al, [b_ferr]
        mov     byte [b_ferr], 0
        cmp     al, 0FFh
        je      .to
        clc
        ret
.to:
        stc
        ret
.ok:
        popf
        ret

; file_close_all: ferme le fichier de donnees s'il est ouvert; erreurs ignorees
file_close_all:
        cmp     byte [b_fout], 0
        je      .n
        call    file_out_abort
.n:
        cmp     byte [b_fmode], 0
        je      .r
        call    file_close
.r:
        ret

; file_end: END / fin de programme: ferme le fichier de donnees (erreurs signalees)
file_end:
        cmp     byte [b_fmode], 0
        je      .r
        call    file_close
        call    disk_chk
.r:
        ret

; WRITE [#1,] liste: valeurs separees par des virgules, chaines entre guillemets, CR LF
st_write:
        call    skip_sp
        cmp     al, '#'
        jne     .t
        call    file_out_begin
.t:
        call    skip_sp
        or      al, al
        jz      .end
        cmp     al, ':'
        je      .end
        cmp     al, T_ELSE
        je      .end
.item:
        call    eval_expr
        cmp     byte [fac_t], TY_STR
        jne     .num
        mov     al, '"'
        call    bas_putc
        mov     cl, [fac_v]
        xor     ch, ch
        mov     bx, [fac_v + 1]
        jcxz    .qe
.sl:
        mov     al, [bx]
        call    bas_putc
        inc     bx
        loop    .sl
.qe:
        mov     al, '"'
        call    bas_putc
        jmp     .sep
.num:
        call    fmt_num
        mov     bx, B_NBUF
        cmp     byte [bx], ' '          ; WRITE: pas d'espace avant un nombre positif
        jne     .nl
        inc     bx
        dec     cx
        jz      .sep
.nl:
        mov     al, [bx]
        call    bas_putc
        inc     bx
        loop    .nl
.sep:
        call    skip_sp
        cmp     al, ','
        jne     .end
        inc     si
        mov     al, ','
        call    bas_putc
        jmp     .item
.end:
        call    bas_crlf
        cmp     byte [b_fout], 0
        je      .nf
        call    file_out_end
.nf:
        jmp     bas_newstt

; INPUT #1,v[,v...]  /  LINE INPUT #1,a$   ([SI] = '#')
inp_file:
        call    file_num
        call    file_chk_in
        cmp     byte [b_inpmode], 1
        je      .line
        call    file_getline
.var:
        call    skip_sp
        call    var_ref
        mov     [b_t5], bx
        mov     [b_t6], cx
.fld:
        call    inp_field               ; CF = 1: ligne epuisee -> ligne suivante du fichier
        jnc     .have
        call    file_getline
        jmp     .fld
.have:
        mov     bx, [b_t5]
        mov     dl, [b_t6]
        call    text_store
        jnc     .ok
        ERROR   ERR_TM
.ok:
        call    skip_sp
        cmp     al, ','
        jne     .fin
        inc     si
        jmp     .var
.line:
        call    file_getline
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

; EOF(n): -1 si plus rien a lire, 0 sinon
fn_eof:
        call    arg_open
        call    eval_int
        call    arg_close
        cmp     ax, 1
        je      .n
        ERROR   ERR_BFN
.n:
        call    file_chk_in
        call    file_eof
        sbb     ax, ax
        jmp     fac_set_int

; ============================================================
; DSKREAD lba, adresse / DSKWRITE lba, adresse: acces DIRECT aux secteurs de 512 octets de la
; flash du pont (LBA 0-65535), en memoire a DEF SEG:adresse. Base d'un futur DOS (chargeur de
; secteur, INT 13h) et outil de mise au point. ATTENTION: DSKWRITE ecrit sans verification et
; peut detruire le systeme de fichiers (FORMAT "YES" le refait). Interdits si un fichier de
; donnees est ouvert. DSKREAD refuse les zones protegees comme POKE.
; ============================================================
; dsk_args: lit "lba, adresse" -> [b_t5] = lba, DI = adresse. Verifie que 512 octets tiennent.
dsk_args:
        call    disk_nofile
        call    eval_addr16
        mov     [b_t5], ax
        call    arg_comma
        call    eval_addr16
        mov     di, ax
        cmp     di, 0FE00h
        jbe     .ok
        ERROR   ERR_FC                  ; les 512 octets deborderaient du segment
.ok:
        ret

st_dskread:
        call    dsk_args
        mov     bx, di                  ; zones protegees (comme POKE): debut et fin
        mov     ax, [b_defseg]
        call    poke_guard
        add     bx, 511
        call    poke_guard
        mov     ax, [b_defseg]
        mov     es, ax
        mov     ax, [b_t5]
        xor     dx, dx
        push    si
        call    fs_sec_read
        push    ds
        pop     es                      ; ES = DS (sans toucher aux indicateurs)
        pop     si
        call    disk_chk
        jmp     bas_newstt

st_dskwrite:
        call    dsk_args
        mov     ax, [b_defseg]
        mov     es, ax
        mov     ax, [b_t5]
        xor     dx, dx
        push    si                      ; pointeur du texte BASIC
        mov     si, di
        call    fs_sec_write
        push    ds
        pop     es
        pop     si
        call    disk_chk
        jmp     bas_newstt

; ============================================================
; USB ON / USB OFF: le disque (la flash du pont) est offert au PC comme lecteur USB (lecteur de
; masse), puis rendu au 8088. Jamais les deux a la fois: tant que USB ON est actif, toute
; commande disque du BASIC (FILES, SAVE, LOAD, DSKREAD...) donne "Disk not Ready". Ejecter le
; lecteur sur le PC AVANT USB OFF. "Device unavailable" si le pont n'a pas l'USB de masse.
; ============================================================
txt_off:        db      'OFF', 0

st_usb:
        call    disk_nofile
        call    skip_sp
        cmp     al, T_ON
        jne     .off
        inc     si
        mov     al, FS_USB_ON
        jmp     .go
.off:
        mov     bx, txt_off
        call    tx_word
        jnc     .o
        ERROR   ERR_SN
.o:
        mov     al, FS_USB_OFF
.go:
        push    si
        call    fs_cmd0
        pop     si
        call    disk_chk
        jmp     bas_newstt

; ============================================================
; BOOT: demarre le DOS depuis la flash du pont. Ferme le fichier de donnees, puis INT 19h (lib/bios.asm):
; secteur 0 (MBR) -> partition active -> son secteur d'amorce en 0000:7C00, execute avec DL = 80h. NE REVIENT
; PAS si l'amorce demarre (le BASIC et son espace de travail sont perdus: reset pour revenir au menu).
; INT 19h affiche la cause d'un echec sur l'UART, puis "Disk not Ready".
; ============================================================
st_boot:
        call    file_close_all
        call    skip_sp
        cmp     al, '"'
        jne     .go
        xor     dl, dl
        call    disk_name               ; BOOT "IMAGE.IMG": monte l'image comme disquette A: puis amorce A:
        push    si
        mov     si, B_NBUF
        mov     ax, 0F000h
        int     13h
        pop     si
        jnc     .go
        cmp     ah, 80h
        jne     .e1
        ERROR   ERR_DT
.e1:
        cmp     ah, 0E2h
        jne     .e2
        ERROR   ERR_FNF
.e2:
        cmp     ah, 0E5h
        jne     .e3
        ERROR   ERR_BN
.e3:
        cmp     ah, 0E1h
        jne     .e4
        ERROR   ERR_DNR
.e4:
        ERROR   ERR_DIO
.go:
        int     19h
        ERROR   ERR_DNR
