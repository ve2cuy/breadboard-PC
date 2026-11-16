; =============================================================================
; ramtest.inc - "2) Test memory" (BIOS 2.3) : le test EXHAUSTIF de Solution-01
; (Solution-01/solution-01.asm : test_ram, test_ram_map, test_ram_loop, test_segment,
; zone_reservee_test, test_adressage, ram_map_print), adapte a Solution-02, avec rapport
; sur l'UART (toujours) et sur le LCD. Le test du demarrage (bios.asm) ne change pas.
;
; Sous-menu : 1) Trace (une ligne par bloc de 1 Ko, chaque defaut detaille), 2) MAP
; (memes essais, carte et bilan a la fin), 3) Loop (MAP en boucle, Echap entre deux
; passes). Echap : retour au menu.
;
; Deroulement (NON destructif : chaque octet est sauve puis remis) :
;   1) 00000h-7EFFFh octet par octet, 4 motifs (AAh, 55h, 00h, FFh) : segments 0000h-6000h
;      entiers, puis 7000:0000-EFFFh (508 blocs de 1 Ko). Interruptions masquees pendant le
;      segment 0 (vecteurs, BDA, carte) ; permises ailleurs (Echap en mode Loop) : les
;      gestionnaires n'utilisent que DSEG, teste a part.
;   2) DSEG (7F000h-7FFFFh, 4 Ko : donnees, ecran et pile du BIOS) : pile deplacee dans un
;      bloc bas trouve bon, aucun appel ni affichage pendant l'essai (IF = 0), defauts notes
;      dans ce bloc (64 au plus), rapportes apres.
;   3) lignes d'adresse A0-A18 (comme Solution-01 : ecritures par DS avec IF = 1, relectures
;      par ES avec IF = 0 : les lignes multiplexees A16-A19/S3-S6 sont aussi vues).
;   4) carte memoire (UART) et bilan.
; Carte des 512 blocs en 0000:8000h (0 bon, 1 defectueux, 2 non teste) ; compteurs en DSEG
; (lus par SS : la pile du menu est en DSEG pendant les phases 1, 3 et 4).
; =============================================================================
RT_CARTE        equ     8000h           ; (segment 0) 512 octets
RT_MODE         equ     0EC0h           ; (DSEG) 0 = Trace, 1 = MAP
RT_DERNIERE     equ     0EC1h           ; resultat de la derniere passe (0 = bonne)
RT_TA           equ     0EC2h           ; lignes d'adresse : 0 = OK
RT_OCTETS       equ     0EC4h           ; (dw) octets defectueux
RT_BLOCS        equ     0EC6h           ; (dw) blocs defectueux
RT_Z            equ     0EC8h           ; drapeau de defaut de la zone (rt_zone)
RT_ZONE         equ     DSEG            ; zone reservee : 4 Ko
RT_TA_HI        equ     0003h           ; lignes d'adresse : base 35555h
RT_TA_LO        equ     5555h
RT_TA_N         equ     20

; ---- sous-menu ------------------------------------------------------------------------
ram_menu:
        mov     si, txt_rt_menu_lcd
        call    lcd_ecran
        mov     si, txt_rt_menu
        call    uart_texte
.touche:
        call    kbd_attend
        cmp     al, 27
        jne     .t1
        jmp     menu
.t1:    cmp     al, '1'
        jne     .t2
        xor     al, al
        call    rt_test
        jmp     .attend
.t2:    cmp     al, '2'
        jne     .t3
        mov     al, 1
        call    rt_test
        jmp     .attend
.t3:    cmp     al, '3'
        jne     .touche
        call    rt_boucle
        jmp     ram_menu
.attend:
        mov     si, txt_rt_touche
        call    uart_texte
        call    kbd_attend
        jmp     ram_menu

; ---- sorties : UART (DS = CS pour les textes), LCD. Preservent tout. -------------------
rt_us:                                  ; texte DS:SI (zero final) a l'UART
        push    ax
        push    si
        call    uart_texte
        pop     si
        pop     ax
        ret
rt_uc:  jmp     uart_tx                 ; AL a l'UART
rt_uhex16:                              ; AX en 4 chiffres hexadecimaux
        push    ax
        mov     al, ah
        call    rt_uhex8
        pop     ax
rt_uhex8:                               ; AL en 2 chiffres
        push    ax
        push    cx
        push    ax
        mov     cl, 4
        shr     al, cl
        call    rt_uhexq
        pop     ax
        call    rt_uhexq
        pop     cx
        pop     ax
        ret
rt_uhexq:                               ; quartet bas de AL
        push    ax
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .c
        add     al, 'A' - '9' - 1
.c:     call    uart_tx
        pop     ax
        ret
rt_udec:                                ; AX en decimal (sans zeros de tete)
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d:     xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d
.e:     pop     ax
        add     al, '0'
        call    uart_tx
        loop    .e
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
rt_ubin20:                              ; DX:AX : les 20 bits bas en binaire (A19 ... A0)
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, ax
        mov     cl, 4
        shl     dl, cl                  ; bits 19-16 en haut de DL
        mov     cx, 4
.h:     shl     dl, 1
        mov     al, '0'
        adc     al, 0
        call    uart_tx
        loop    .h
        mov     cx, 16
.b:     shl     bx, 1
        mov     al, '0'
        adc     al, 0
        call    uart_tx
        loop    .b
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
rt_ligne:                               ; LCD : debut de la ligne AL (LIGNEx)
        push    ax
        push    cx
        or      al, 80h
        call    lcd_cmd
        pop     cx
        pop     ax
        ret
rt_ls:                                  ; LCD : texte DS:SI (zero final)
        push    ax
        push    cx
        push    si
.c:     lodsb
        or      al, al
        jz      .f
        call    lcd_car
        jmp     .c
.f:     pop     si
        pop     cx
        pop     ax
        ret
rt_lc:  push    cx                      ; LCD : caractere AL
        call    lcd_car
        pop     cx
        ret
rt_lhex16:                              ; LCD : AX en hexadecimal
        push    ax
        push    cx
        push    ax
        mov     al, ah
        call    lcd_hex8
        pop     ax
        call    lcd_hex8
        pop     cx
        pop     ax
        ret
rt_ldec3:                               ; LCD : AX (0-999) en 3 chiffres
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 100
        xor     dx, dx
        div     bx
        add     al, '0'
        call    lcd_car
        mov     ax, dx
        mov     bl, 10
        div     bl
        push    ax
        add     al, '0'
        call    lcd_car
        pop     ax
        mov     al, ah
        add     al, '0'
        call    lcd_car
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; rt_bloc_num : ES:DI = juste apres un bloc de 1 Ko -> AX = son numero (0-511).
rt_bloc_num:
        push    cx
        push    dx
        mov     ax, es
        mov     cl, 6
        shr     ax, cl                  ; segment / 64 = Ko
        mov     dx, di
        sub     dx, 0400h
        mov     cl, 10
        shr     dx, cl
        add     ax, dx
        pop     dx
        pop     cx
        ret

; ---- un passage complet ---------------------------------------------------------------
; rt_test : AL = 0 (Trace) ou 1 (MAP). Preserve tout. [SS:RT_DERNIERE] = 0 si la RAM est bonne.
rt_test:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es
        pushf
        mov     [ss:RT_MODE], al
        xor     ax, ax
        mov     [ss:RT_OCTETS], ax
        mov     [ss:RT_BLOCS], ax
        mov     si, txt_rt_lcd1         ; LCD : titre, "En cours..."
        call    lcd_ecran
        mov     si, txt_rt_ban1
        call    rt_us
        mov     si, txt_rt_ban2
        call    rt_us
        xor     bh, bh                  ; BH = defaut quelque part
        xor     bp, bp                  ; BP = defaut dans le bloc courant
        cli
        call    rt_adresses             ; lignes d'adresse D'ABORD, avant toute autre
        or      bh, bh                  ; ecriture : si deux adresses se recouvrent, la carte
        jz      .octets                 ; (0000:8000h) et l'essai octet par octet ecriraient
        mov     si, txt_rt_saute        ; aussi ailleurs (vecteurs, DSEG) : ils sont sautes
        call    rt_us
        jmp     .fin_essais
.octets:
        xor     ax, ax                  ; carte : 2 = non teste
        mov     es, ax
        mov     di, RT_CARTE
        mov     cx, 512
        mov     al, 2
        cld
        rep     stosb
        xor     ax, ax                  ; phase 1 : segments 0000h-6000h
.seg:   mov     es, ax
        cli                             ; segment 0 : vecteurs et BDA sous essai
        or      ax, ax
        jz      .s1
        sti
.s1:    xor     di, di
        xor     cx, cx                  ; 65536 octets
        push    ax
        call    rt_segment
        pop     ax
        add     ax, 1000h
        cmp     ax, 7000h
        jb      .seg
        mov     es, ax                  ; 7000:0000-EFFFh (DSEG ensuite, a part)
        xor     di, di
        mov     cx, 0F000h
        call    rt_segment
        cli
        call    rt_zone                 ; phase 2 : DSEG (BH = 1 si defaut)
        call    rt_carte                ; carte et bilan
.fin_essais:
        mov     [ss:RT_DERNIERE], bh
        mov     al, LIGNE1
        call    rt_ligne
        mov     si, txt_rt_lcd_ok
        or      bh, bh
        jz      .lcd
        mov     si, txt_rt_lcd_err
.lcd:   call    rt_ls
        cmp     byte [ss:RT_MODE], 0    ; MAP : ligne 2 "Termine" (Trace : le dernier bloc)
        je      .l2
        mov     al, LIGNE2
        call    rt_ligne
        mov     si, txt_rt_lcd_fin
        call    rt_ls
.l2:
        or      bh, bh
        jnz     .defaut
        mov     si, txt_rt_ok
        jmp     .bilan
.defaut:
        mov     si, txt_rt_err
        cmp     byte [ss:RT_MODE], 0
        je      .bilan
        mov     si, txt_rt_err_carte
.bilan: call    rt_us
        mov     si, txt_rt_total        ; "TOTAL DEFAUT: xxxxh, n octet(s)"
        call    rt_us
        mov     ax, [ss:RT_OCTETS]
        call    rt_uhex16
        mov     al, 'h'
        call    rt_uc
        mov     al, ','
        call    rt_uc
        mov     al, ' '
        call    rt_uc
        mov     ax, [ss:RT_OCTETS]
        call    rt_udec
        mov     si, txt_rt_total_fin
        call    rt_us
        popf
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; rt_segment : teste CX octets (0 = 65536) a partir de ES:DI, 4 motifs, chaque octet
; remis. BH = 1 et BP = 1 au premier defaut ; a chaque fin de bloc : rt_bloc (BP = 0).
rt_segment:
.octet: mov     bl, [es:di]             ; octet d'origine
        mov     al, 0AAh
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        cmp     al, 0AAh
        jne     .d1
        mov     al, 55h
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        cmp     al, 55h
        jne     .d2
        xor     al, al
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        or      al, al
        jnz     .d3
        mov     al, 0FFh
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        cmp     al, 0FFh
        jne     .d4
        jmp     .remet
.d1:    mov     dh, 0AAh
        jmp     .defaut
.d2:    mov     dh, 55h
        jmp     .defaut
.d3:    mov     dh, 00h
        jmp     .defaut
.d4:    mov     dh, 0FFh
.defaut:
        mov     bh, 1
        mov     bp, 1
        call    rt_defaut               ; ES:DI, DH = attendu, DL = lu
.remet: mov     [es:di], bl
        inc     di
        test    di, 03FFh
        jnz     .suite
        call    rt_bloc
.suite: loop    .octet
        ret

; rt_defaut : octet ES:DI defectueux (DH attendu, DL lu) : compte ; Trace : detail en rouge.
rt_defaut:
        inc     word [ss:RT_OCTETS]
        cmp     byte [ss:RT_MODE], 0
        jne     .f
        push    ax
        push    si
        mov     si, txt_rt_rouge
        call    rt_us
        mov     si, txt_rt_defaut
        call    rt_us
        mov     ax, es
        call    rt_uhex16
        mov     al, ':'
        call    rt_uc
        mov     ax, di
        call    rt_uhex16
        mov     si, txt_rt_attendu
        call    rt_us
        mov     al, dh
        call    rt_uhex8
        mov     si, txt_rt_lu
        call    rt_us
        mov     al, dl
        call    rt_uhex8
        mov     si, txt_rt_blanc_crlf
        call    rt_us
        pop     si
        pop     ax
.f:     ret

; rt_bloc : bloc de 1 Ko qui finit en ES:DI (DI = 0 apres le dernier d'un segment) teste,
; BP = 0 bon. Carte, compteur ; Trace : ligne UART + LCD ; MAP : tous les 64 Ko. BP = 0.
rt_bloc:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    es
        call    rt_bloc_num             ; AX = numero (0-511)
        push    es
        push    di
        xor     di, di
        mov     es, di
        mov     di, ax
        mov     byte [es:RT_CARTE + di], 0
        or      bp, bp
        jz      .bon
        mov     byte [es:RT_CARTE + di], 1
        inc     word [ss:RT_BLOCS]
.bon:   pop     di
        pop     es
        inc     ax                      ; Ko testes
        cmp     byte [ss:RT_MODE], 0
        je      .trace
        test    al, 3Fh                 ; MAP : tous les 64 Ko
        jnz     .fin
        call    rt_ko_uart
        call    rt_lcd_compteurs
        jmp     .fin
.trace: push    ax
        mov     si, txt_rt_blanc        ; "SSSS:OOOO-SSSS:OOOO aaaaa... OK"
        call    rt_us
        mov     ax, es
        call    rt_uhex16
        mov     al, ':'
        call    rt_uc
        mov     ax, di
        sub     ax, 0400h
        call    rt_uhex16
        mov     al, '-'
        call    rt_uc
        mov     ax, es
        call    rt_uhex16
        mov     al, ':'
        call    rt_uc
        mov     ax, di
        dec     ax
        call    rt_uhex16
        mov     al, ' '
        call    rt_uc
        pop     ax
        push    ax
        dec     ax                      ; adresse physique du debut du bloc = n x 1024
        mov     dx, ax
        mov     cl, 10
        shl     ax, cl
        mov     cl, 6
        shr     dx, cl
        call    rt_ubin20
        mov     al, ' '
        call    rt_uc
        mov     si, txt_rt_vert_ok
        or      bp, bp
        jz      .etat
        mov     si, txt_rt_rouge_err
.etat:  call    rt_us
        pop     ax
        call    rt_ko_uart
        push    ax                      ; LCD ligne 2 : la plage ; ligne 3 : l'etat
        mov     al, LIGNE2
        call    rt_ligne
        mov     ax, es
        call    rt_lhex16
        mov     al, ':'
        call    rt_lc
        mov     ax, di
        sub     ax, 0400h
        call    rt_lhex16
        mov     al, '-'
        call    rt_lc
        mov     ax, es
        call    rt_lhex16
        mov     al, ':'
        call    rt_lc
        mov     ax, di
        dec     ax
        call    rt_lhex16
        mov     al, LIGNE3
        call    rt_ligne
        mov     si, txt_rt_etat_ok
        or      bp, bp
        jz      .e
        mov     si, txt_rt_etat_err
.e:     call    rt_ls
        pop     ax
        call    rt_lcd_compteurs
.fin:   xor     bp, bp
        pop     es
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

rt_ko_uart:                             ; "  -> NNNK testes" (AX = Ko)
        push    si
        mov     si, txt_rt_ko1
        call    rt_us
        call    rt_udec
        mov     si, txt_rt_ko2
        call    rt_us
        pop     si
        ret

rt_lcd_compteurs:                       ; LCD ligne 4 : "Bloc:NNN/512 Def:NNN" (AX = bloc)
        push    ax
        push    si
        push    ax
        mov     al, LIGNE4
        call    rt_ligne
        mov     si, txt_rt_bloc
        call    rt_ls
        pop     ax
        call    rt_ldec3
        mov     si, txt_rt_bloc2
        call    rt_ls
        mov     ax, [ss:RT_BLOCS]
        cmp     ax, 999
        jbe     .a
        mov     ax, 999
.a:     call    rt_ldec3
        pop     si
        pop     ax
        ret

; ---- phase 2 : DSEG (7F000h-7FFFFh) ----------------------------------------------------
; Pile dans un bloc bas trouve bon (2 a 447, sauf celui de la carte) ; IF = 0 ; aucun appel
; pendant l'essai ; defauts notes au debut du bloc (4 octets : decalage, lu, attendu ; 64 au
; plus) ; puis rapport (rt_defaut) et les 4 blocs (rt_bloc). Sans bloc bas bon : 'R'.
; Sortie : BH = 1 si defaut. Preserve le reste (BP = 0).
rt_motifs:      db      0AAh, 55h, 00h, 0FFh

rt_zone:
        push    bx
        push    ax
        push    cx
        push    dx
        push    si
        push    di
        push    es
        xor     ax, ax
        mov     es, ax
        mov     si, RT_CARTE + 2
        mov     cx, 446
.cherche:
        cmp     byte [es:si], 0
        jne     .s
        cmp     si, RT_CARTE + (RT_CARTE >> 10)   ; le bloc de la carte elle-meme
        jne     .trouve
.s:     inc     si
        loop    .cherche
        jmp     .fin
.trouve:
        sub     si, RT_CARTE
        mov     ax, si
        mov     cl, 6
        shl     ax, cl                  ; segment du bloc
        mov     dx, ss
        mov     cx, sp
        mov     ss, ax
        mov     sp, 0400h
        push    dx
        push    cx
        mov     ax, RT_ZONE
        mov     es, ax
        xor     di, di
        mov     cx, 1000h
        xor     bp, bp                  ; SS:BP = defauts notes
        xor     dx, dx                  ; DX = defauts
.octet: mov     bl, [es:di]
        mov     si, rt_motifs           ; DS = CS
.motif: mov     ah, [si]
        mov     [es:di], ah
        mov     al, [es:di]
        cmp     al, ah
        jne     .err
        inc     si
        cmp     si, rt_motifs + 4
        jb      .motif
        jmp     .remet
.err:   inc     dx
        cmp     bp, 0100h
        jae     .remet
        mov     [bp], di
        mov     [bp + 2], ax            ; AL = lu, AH = attendu
        add     bp, 4
.remet: mov     [es:di], bl
        inc     di
        loop    .octet
        mov     si, dx                  ; SI = defauts, DI = octets notes, AX = segment du bloc
        mov     di, bp
        mov     ax, ss
        pop     cx
        pop     dx
        mov     ss, dx
        mov     sp, cx
        ; --- rapport : defauts par bloc (4 mots sur la pile)
        xor     cx, cx
        push    cx
        push    cx
        push    cx
        push    cx
        mov     bp, sp
        xor     bx, bx
.rapport:
        cmp     bx, di
        jae     .rapport_fin
        push    ax
        push    di
        push    bx
        mov     es, ax
        mov     di, [es:bx]             ; decalage dans DSEG
        mov     dx, [es:bx + 2]         ; DL = lu, DH = attendu
        mov     ax, RT_ZONE
        mov     es, ax
        mov     bx, di
        mov     cl, 10
        shr     bx, cl                  ; bloc 0-3 de la zone
        shl     bx, 1
        add     bx, bp
        inc     word [ss:bx]
        call    rt_defaut
        pop     bx
        pop     di
        pop     ax
        add     bx, 4
        jmp     .rapport
.rapport_fin:
        mov     cx, di                  ; defauts au-dela des 64 notes : comptes
        shr     cx, 1
        shr     cx, 1
        mov     ax, si
        sub     ax, cx
        add     [ss:RT_OCTETS], ax
        xor     bx, bx                  ; BH : drapeau global (plus bas)
        or      si, si
        jz      .blocs
        mov     bh, 1
        or      ax, ax                  ; defauts non notes : comptes pour le 1er bloc
        jz      .blocs
        inc     word [bp]
.blocs: mov     ax, RT_ZONE
        mov     es, ax
        mov     di, 0400h
        mov     cx, 4
.b:     push    cx
        push    bx
        mov     bp, sp
        mov     bx, di                  ; drapeau du bloc : [mot (DI / 400h) - 1] de la pile
        mov     cl, 10
        shr     bx, cl
        dec     bx
        shl     bx, 1
        add     bx, bp
        mov     bp, [ss:bx + 4]
        call    rt_bloc
        pop     bx
        pop     cx
        add     di, 0400h
        loop    .b
        add     sp, 8
        mov     [ss:RT_Z], bh
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        pop     bx
        or      bh, [ss:RT_Z]           ; BH de l'appelant (phase 1) garde
        xor     bp, bp
        ret
.fin:   pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        pop     bx
        ret

; ---- phase 3 : lignes d'adresse A0-A18 (comme Solution-01) ----------------------------
; rt_ta_adr : CL = 0 -> base ; CL = k+1 -> base xor 2^k. SI = segment, DI = decalage.
rt_ta_adr:
        push    ax
        push    cx
        push    dx
        mov     dx, RT_TA_HI
        mov     ax, RT_TA_LO
        or      cl, cl
        jz      .conv
        dec     cl
        mov     di, 1
        cmp     cl, 16
        jae     .haut
        shl     di, cl
        xor     ax, di
        jmp     .conv
.haut:  sub     cl, 16
        shl     di, cl
        xor     dx, di
.conv:  mov     di, ax
        and     di, 0Fh
        mov     cl, 4
        shr     ax, cl
        mov     cl, 12
        shl     dx, cl
        or      ax, dx
        mov     si, ax
        pop     dx
        pop     cx
        pop     ax
        ret
rt_ta_val:                              ; CL -> AL = valeur (5Ah pour la base)
        mov     al, cl
        or      al, al
        jnz     .r
        mov     al, 5Ah
.r:     ret

; rt_adresses : BH = 1 si defaut ; [SS:RT_TA] ; LCD ligne 3. Preserve le reste.
rt_adresses:
        push    ax
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        mov     si, txt_rt_adr
        call    rt_us
        xor     cl, cl                  ; octets d'origine (pile)
.sauve: call    rt_ta_adr
        mov     es, si
        mov     al, [es:di]
        push    ax
        inc     cl
        cmp     cl, RT_TA_N
        jb      .sauve
        xor     cl, cl                  ; ecritures par DS, IF = 1
        sti
.ecrit: call    rt_ta_adr
        call    rt_ta_val
        mov     ds, si
        mov     [di], al
        inc     cl
        cmp     cl, RT_TA_N
        jb      .ecrit
        cli
        mov     ax, cs
        mov     ds, ax
        xor     cx, cx                  ; relectures par ES, IF = 0 ; CH = defauts
.relit: call    rt_ta_adr
        mov     es, si
        mov     dl, [es:di]
        call    rt_ta_val
        cmp     dl, al
        je      .bon
        inc     ch
        push    ax
        mov     al, cl                  ; AL = ligne + 1
        or      cl, cl
        jnz     .ligne
        mov     al, dl                  ; base ecrasee par la valeur k+1 : ligne k
        or      al, al
        jz      .base
        cmp     al, RT_TA_N - 1
        jbe     .ligne
.base:  mov     si, txt_rt_adr_base
        jmp     .msg
.ligne: mov     si, txt_rt_adr_ligne
        call    rt_us
        dec     al
        xor     ah, ah
        call    rt_udec
        mov     si, txt_rt_adr_ligne2
.msg:   call    rt_us
        mov     al, dl
        call    rt_uhex8
        mov     si, txt_rt_adr_attendu
        call    rt_us
        pop     ax
        call    rt_uhex8
        mov     si, txt_rt_adr_fin
        call    rt_us
.bon:   inc     cl
        cmp     cl, RT_TA_N
        jb      .relit
        mov     cl, RT_TA_N             ; octets remis, du dernier au premier
.remet: dec     cl
        call    rt_ta_adr
        pop     ax
        mov     es, si
        mov     [es:di], al
        or      cl, cl
        jnz     .remet
        mov     al, LIGNE3
        call    rt_ligne
        or      ch, ch
        jnz     .defaut
        mov     byte [ss:RT_TA], 0
        mov     si, txt_rt_adr_ok
        call    rt_us
        mov     si, txt_adr_ok
        jmp     .lcd
.defaut:
        mov     byte [ss:RT_TA], 1
        mov     bh, 1
        mov     si, txt_rt_adr_aide
        call    rt_us
        mov     si, txt_rt_lcd_adr_err
.lcd:   push    bx
        mov     bx, LCD_COLS
        call    lcd_texte
        pop     bx
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; ---- phase 4 : carte memoire et comptes (UART) -----------------------------------------
rt_carte:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        mov     si, txt_rt_carte
        call    rt_us
        xor     ax, ax
        mov     es, ax
        mov     di, RT_CARTE
        xor     dx, dx                  ; DL = segment de 64 Ko (0-7)
.ligne: mov     al, dl
        call    rt_uhexq
        mov     si, txt_rt_carte_adr
        call    rt_us
        mov     cx, 64
.bloc:  mov     al, [es:di]
        inc     di
        cmp     al, 1
        je      .x
        mov     ah, '.'
        or      al, al
        jz      .c
        mov     ah, 'R'
.c:     mov     al, ah
        call    rt_uc
        jmp     .s
.x:     mov     si, txt_rt_x
        call    rt_us
.s:     loop    .bloc
        mov     si, txt_rt_crlf
        call    rt_us
        inc     dl
        cmp     dl, 8
        jb      .ligne
        mov     si, txt_rt_legende
        call    rt_us
        mov     di, RT_CARTE            ; CX = bons, DX = defectueux
        xor     cx, cx
        xor     dx, dx
        mov     bx, 512
.compte:
        mov     al, [es:di]
        inc     di
        or      al, al
        jnz     .pb
        inc     cx
.pb:    cmp     al, 1
        jne     .pm
        inc     dx
.pm:    dec     bx
        jnz     .compte
        mov     si, txt_rt_teste
        call    rt_us
        mov     ax, cx
        add     ax, dx
        call    rt_udec
        mov     si, txt_rt_ko
        call    rt_us
        mov     si, txt_rt_bons
        call    rt_us
        mov     ax, cx
        call    rt_udec
        mov     si, txt_rt_ko
        call    rt_us
        mov     si, txt_rt_mauvais
        call    rt_us
        mov     ax, dx
        call    rt_udec
        mov     si, txt_rt_ko_octets
        call    rt_us
        mov     ax, [ss:RT_OCTETS]
        call    rt_udec
        mov     si, txt_rt_octets
        call    rt_us
        mov     si, txt_rt_non_teste
        call    rt_us
        mov     ax, 512
        sub     ax, cx
        sub     ax, dx
        call    rt_udec
        mov     si, txt_rt_total_ko
        call    rt_us
        mov     si, txt_rt_lignes_ok
        cmp     byte [ss:RT_TA], 0
        je      .l
        mov     si, txt_rt_lignes_err
.l:     call    rt_us
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---- 3) Loop : MAP en boucle ; Echap (clavier ou terminal) entre deux passes -----------
rt_boucle:
        xor     cx, cx                  ; CX = passes, DX = passes avec defauts
        xor     dx, dx
.passe: inc     cx
        mov     si, txt_rt_passe
        call    rt_us
        mov     ax, cx
        call    rt_udec
        mov     si, txt_rt_passe_fin
        call    rt_us
        mov     al, 1
        call    rt_test
        cmp     byte [ss:RT_DERNIERE], 0
        je      .bonne
        inc     dx
.bonne: call    .bilan
        sti
.cle:   call    file_retire             ; Echap en attente ? (autres touches : ignorees)
        jc      .passe
        cmp     al, 27
        jne     .cle
        mov     si, txt_rt_arret
        call    rt_us
        call    .bilan
        ret
.bilan: mov     si, txt_rt_bilan
        call    rt_us
        mov     ax, cx
        call    rt_udec
        mov     si, txt_rt_bonnes
        call    rt_us
        mov     ax, cx
        sub     ax, dx
        call    rt_udec
        mov     si, txt_rt_defauts
        call    rt_us
        mov     ax, dx
        call    rt_udec
        mov     si, txt_rt_bilan_fin
        call    rt_us
        ret

; ---- textes ---------------------------------------------------------------------------
txt_rt_menu_lcd:
        db      'Test RAM 512K       '
        db      '1) Trace            '
        db      '2) MAP              '
        db      '3) Loop  Echap: menu'
txt_rt_menu:
        db      13, 10, 27, '[36m', '--- Sous-menu Test RAM ---', 27, '[0m', 13, 10
        db      '1) Trace (une ligne par bloc de 1 Ko, chaque defaut detaille)', 13, 10
        db      '2) MAP (carte memoire et bilan a la fin)', 13, 10
        db      '3) Loop (MAP en boucle, Echap: arret apres la passe)', 13, 10
        db      'Echap: retour au menu', 13, 10, 0
txt_rt_touche:  db      'Une touche: retour au sous-menu', 13, 10, 0
txt_rt_lcd1:
        db      'Test RAM 512K       '
        db      'En cours...         '
        db      '                    '
        db      '                    '
txt_rt_lcd_ok:  db      'RAM OK  (touche)    ', 0
txt_rt_lcd_err: db      'RAM DEFECTUEUSE     ', 0
txt_rt_lcd_fin: db      'Test termine        ', 0
txt_rt_lcd_adr_err: db  'Adresses: ERR (UART)'
txt_rt_ban1:    db      13, 10, 27, '[0m', '=== Test RAM 512K (Solution-02, rapport UART 9600 8N1) ===', 27, '[0m', 13, 10, 0
txt_rt_ban2:    db      'Plan: seg 0000h-6000h (00000h-6FFFFh, 448 blocs) + seg 7000h (70000h-7EFFFh, 60 blocs),', 13, 10
        db      'puis les 4 derniers Ko (DSEG: donnees, ecran et pile du BIOS, 7F000h-7FFFFh), pile deplacee en bas de la RAM', 13, 10, 13, 10, 0
txt_rt_rouge:   db      27, '[31m', 0
txt_rt_blanc:   db      27, '[0m', 0
txt_rt_blanc_crlf: db   27, '[0m', 13, 10, 0
txt_rt_defaut:  db      '  >> DEFAUT memoire @ ', 0
txt_rt_attendu: db      '  attendu=', 0
txt_rt_lu:      db      '  lu=', 0
txt_rt_vert_ok: db      27, '[32m', 'OK', 27, '[0m', 0
txt_rt_rouge_err: db    27, '[31m', 'DEFAUT', 27, '[0m', 0
txt_rt_ko1:     db      '  -> ', 0
txt_rt_ko2:     db      'K testes', 13, 10, 0
txt_rt_etat_ok: db      'Etat: OK            ', 0
txt_rt_etat_err: db     'Etat: DEFAUT        ', 0
txt_rt_bloc:    db      'Bloc:', 0
txt_rt_bloc2:   db      '/512 Def:', 0
txt_rt_ok:      db      27, '[32m', '*** RAM OK - 524288 octets testes (512 blocs de 1 Ko), aucune erreur ***', 27, '[0m', 13, 10, 13, 10, 0
txt_rt_err:     db      27, '[31m', '*** RAM DEFECTUEUSE - voir le detail des defauts ci-dessus ***', 27, '[0m', 13, 10, 13, 10, 0
txt_rt_err_carte: db    27, '[31m', '*** RAM DEFECTUEUSE - voir la carte memoire ci-dessus ***', 27, '[0m', 13, 10, 13, 10, 0
txt_rt_total:   db      'TOTAL DEFAUT: ', 0
txt_rt_total_fin: db    ' octet(s)', 13, 10, 13, 10, 0
txt_rt_adr:     db      13, 10, "Test des lignes d'adresse A0-A18 (ecriture par DS avec IF=1, relecture par ES avec IF=0):", 13, 10, 0
txt_rt_adr_base: db     27, '[31m', "  DEFAUT D'ADRESSAGE: case de base 35555h ecrasee: lu ", 0
txt_rt_adr_ligne: db    27, '[31m', "  LIGNE D'ADRESSE A", 0
txt_rt_adr_ligne2: db   ' EN DEFAUT (collee, coupee ou en court-circuit): lu ', 0
txt_rt_adr_attendu: db  'h, attendu ', 0
txt_rt_adr_fin: db      'h', 27, '[0m', 13, 10, 0
txt_rt_adr_ok:  db      27, '[32m', "  Lignes d'adresse A0-A18 OK: 19 lignes independantes, 512 Ko reellement adressables (capacite verifiee)", 27, '[0m', 13, 10, 0
txt_rt_adr_aide: db     27, '[31m', '  Une puce de 128/256 Ko vendue pour 512 Ko echoue sur A17/A18.', 27, '[0m', 13, 10, 0
txt_rt_carte:   db      13, 10, 'CARTE MEMOIRE (1 caractere = 1 bloc de 1 Ko)', 13, 10, '         0K              16K             32K             48K', 13, 10, 0
txt_rt_carte_adr: db    '0000h:  ', 0
txt_rt_x:       db      27, '[31m', 'X', 27, '[0m', 0
txt_rt_crlf:    db      13, 10, 0
txt_rt_legende: db      '         . = bon   X = defectueux   R = non teste', 13, 10, 13, 10, 0
txt_rt_teste:   db      'RAM testee: ', 0
txt_rt_ko:      db      ' Ko   ', 0
txt_rt_bons:    db      'Bonne: ', 0
txt_rt_mauvais: db      'Defectueuse: ', 0
txt_rt_ko_octets: db    ' Ko (', 0
txt_rt_octets:  db      ' octets)', 13, 10, 0
txt_rt_non_teste: db    'Non testee: ', 0
txt_rt_total_ko: db     ' Ko   Total: 512 Ko', 13, 10, 0
txt_rt_lignes_ok: db    27, '[32m', "Lignes d'adresse A0-A18: OK (capacite de 512 Ko verifiee)", 27, '[0m', 13, 10, 0
txt_rt_lignes_err: db   27, '[31m', "Lignes d'adresse A0-A18: DEFAUT (voir plus haut)", 27, '[0m', 13, 10, 0
txt_rt_passe:   db      13, 10, 27, '[36m', '=== Test RAM en boucle - passe ', 0
txt_rt_passe_fin: db    ' (Echap: arret apres cette passe) ===', 27, '[0m', 13, 10, 0
txt_rt_bilan:   db      27, '[36m', 'Boucle: ', 0
txt_rt_bonnes:  db      ' passe(s), ', 0
txt_rt_defauts: db      ' bonne(s), ', 0
txt_rt_bilan_fin: db    ' avec defauts', 27, '[0m', 13, 10, 0
txt_rt_saute:   db      27, '[31m', "*** Essai octet par octet SAUTE: deux adresses se recouvrent (ligne d'adresse en defaut), il ecraserait DSEG (pile et donnees du BIOS) ***", 27, '[0m', 13, 10, 0
txt_rt_arret:   db      13, 10, '*** Test RAM en boucle arrete (Echap) ***', 13, 10, 0
