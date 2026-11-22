; =============================================================================
; avr.inc - UART par l'ATmega328P U17 (schema du 2026-11-21), esclave SPI du 8088.
;   SS = U12 PC0, SCK = PC5, MOSI = PC6 (partages avec la carte SD), MISO = U12 PB4.
;   Protocole (version 1) : arduino/atmega_uart/README_fr.md. Sans ATmega (V_AVR = 0),
;   le BIOS garde l'UART logiciel (PA7, PB2) : une seule ROM pour les deux cartes.
;
; Aucune transaction SPI en interruption n'est necessaire : IRQ4 (irq_uart_avr) ne fait que
; noter qu'un octet attend (V_AVR_DISPO). Les octets sont lus au premier plan, quand on
; consulte les files (file_regarde, file_retire, ufile_retire -> avr_service) ; l'ATmega
; les garde en attendant (1 Ko). Une transaction ne commence que si le bus est libre :
; aucune autre transaction avec l'ATmega en cours (V_AVR_OCC) et carte SD desselectionnee
; (PC4 = 1 : tout acces a la carte finit par sd_libere). Sinon (INT 10h appele depuis une
; interruption au milieu d'un acces SPI), l'octet a emettre est abandonne (V_AVR_PERDUS).
; =============================================================================

V_AVR_VIT       equ     7F9h            ; vitesse de l'UART (code : 0 = 9600 ... 4 = 115200)
V_AVR           equ     7FAh            ; 1 = ATmega present (IDENT a la mise en route)
V_AVR_OCC       equ     7FBh            ; 1 = transaction avec l'ATmega en cours
V_AVR_DISPO     equ     7FCh            ; 1 = IRQ4 : un octet recu attend dans l'ATmega
V_AVR_SERV      equ     7FDh            ; 1 = avr_service en cours (pas de 2e appel)
V_AVR_VER       equ     7FEh            ; version du protocole de l'ATmega
V_AVR_PERDUS    equ     7FFh            ; octets a emettre abandonnes (bus occupe, ATmega plein)

AVR_REPOS       equ     51h             ; PC0 = 1 (ATmega libre), CS de la SD = 1, MOSI = 1
AVR_SEL         equ     50h             ; PC0 = 0 : ATmega selectionne (SD toujours libre)
AVR_SCK         equ     20h             ; PC5
AVR_MOSI        equ     40h             ; PC6
AVR_MISO        equ     10h             ; PB4

AVR_SIGNATURE   equ     0A5h
AVR_IDENT       equ     00h
AVR_LIRE        equ     02h
AVR_ECRIRE      equ     03h
AVR_VITESSE     equ     04h
AVR_VIDER       equ     05h

AVR_V_NB        equ     7               ; codes de vitesse connus de l'ATmega
AVR_V_MENU      equ     5               ; menu 8) : 9600, 19200, 38400, 57600, 115200
AVR_ESSAIS_TX   equ     1000            ; ATmega plein : ~1,3 s d'essais, puis l'octet est perdu
AVR_ESSAIS_SUIV equ     20              ; octet suivant d'une sequence ANSI/UTF-8 : ~5 ms

; avr_octet : echange un octet avec l'ATmega selectionne (mode 0, poids fort en premier).
; AL = octet envoye -> octet recu. Preserve le reste. Les interruptions restent permises.
avr_octet:
        push    bx
        push    cx
        mov     bl, al
        mov     cx, 8
.b:     mov     al, AVR_SEL             ; MOSI = 1
        shl     bl, 1
        jc      .un
        mov     al, AVR_SEL & ~AVR_MOSI ; MOSI = 0
.un:    out     PPI2_PC, al             ; SCK = 0, MOSI pose
        or      al, AVR_SCK
        out     PPI2_PC, al             ; SCK = 1 : l'ATmega lit MOSI
        in      al, PPI2_PB
        and     al, AVR_MISO
        add     al, 0F0h                ; CF = MISO
        rcl     bh, 1
        loop    .b
        mov     al, AVR_SEL
        out     PPI2_PC, al             ; SCK = 0
        mov     al, bh
        pop     cx
        pop     bx
        ret

; avr_debut : prend le bus et selectionne l'ATmega. CF = 1 si le bus est occupe (autre
; transaction, ou carte SD selectionnee). ES = DSEG. Detruit AL.
avr_debut:
        pushf
        cli
        cmp     byte [es:V_AVR_OCC], 0
        jne     .occupe
        in      al, PPI2_PC
        test    al, SD_CS
        jz      .occupe                 ; acces a la carte SD en cours
        mov     byte [es:V_AVR_OCC], 1
        popf
        mov     al, AVR_SEL
        out     PPI2_PC, al
        clc
        ret
.occupe:
        popf
        stc
        ret

; avr_fin : desselectionne l'ATmega (SS a 1 : fin de la transaction) et rend le bus.
; ES = DSEG. Detruit AL.
avr_fin:
        mov     al, AVR_REPOS
        out     PPI2_PC, al
        mov     byte [es:V_AVR_OCC], 0
        ret

; avr_detecte : IDENT ; A5h 'S' '2' -> V_AVR = 1, V_AVR_VER ; puis tampons vides. Version 2 :
; IDENT rend aussi la vitesse en service, gardee (V_AVR_VIT) : apres RESET ou Ctrl+Alt+Suppr,
; le terminal reste a la vitesse choisie au menu 8) (l'ATmega n'est pas remis a zero) ;
; version 1 : 9600 bauds imposes. Sans ATmega, MISO (PB4) est lu a 1 : V_AVR = 0.
; ES = DSEG. Preserve tout.
avr_detecte:
        push    ax
        push    bx
        mov     al, AVR_REPOS
        out     PPI2_PC, al
        mov     byte [es:V_AVR], 0
        mov     byte [es:V_AVR_OCC], 0
        mov     byte [es:V_AVR_DISPO], 0
        mov     byte [es:V_AVR_SERV], 0
        mov     byte [es:V_AVR_PERDUS], 0
        call    avr_debut
        jc      .fin
        mov     al, AVR_IDENT
        call    avr_octet
        mov     bl, al                  ; A5h
        xor     al, al
        call    avr_octet
        mov     bh, al                  ; 'S'
        xor     al, al
        call    avr_octet
        mov     ah, al                  ; '2'
        xor     al, al
        call    avr_octet               ; version
        push    ax
        xor     al, al
        call    avr_octet               ; vitesse en service (version 2 ; 00h en version 1)
        mov     [es:V_AVR_VIT], al
        call    avr_fin
        pop     ax
        cmp     bx, AVR_SIGNATURE | ('S' << 8)
        jne     .fin
        cmp     ah, '2'
        jne     .fin
        mov     [es:V_AVR_VER], al
        mov     byte [es:V_AVR], 1
        call    avr_debut               ; VIDER (confirme par A5h)
        mov     al, AVR_VIDER
        call    avr_octet
        mov     al, AVR_SIGNATURE
        call    avr_octet
        call    avr_fin
        cmp     byte [es:V_AVR_VER], 2  ; version 2 : vitesse en service gardee
        jb      .v9600
        cmp     byte [es:V_AVR_VIT], AVR_V_NB
        jb      .fin
.v9600: xor     al, al                  ; VITESSE 0 = 9600 bauds
        call    avr_vitesse
.fin:   pop     bx
        pop     ax
        ret

; avr_vitesse : AL = code de vitesse de l'ATmega (0 = 9600, 5 = 4800, 6 = 2400...), note dans
; V_AVR_VIT. L'ATmega change de vitesse quand tout ce qui attend est parti. ES = DSEG.
; Preserve tout.
avr_vitesse:
        mov     [es:V_AVR_VIT], al
        push    ax
        push    ax
        call    avr_debut
        pop     ax
        jc      .fin
        push    ax
        mov     al, AVR_VITESSE
        call    avr_octet
        pop     ax
        call    avr_octet
        call    avr_fin
.fin:   pop     ax
        ret

; avr_tx : envoie AL au terminal par l'ATmega (ECRIRE). Si l'ATmega est plein (terminal
; lent, RTS/CTS), reessaie ~1,3 s ; bus occupe ou delai depasse : octet perdu.
; Preserve tout (appele par uart_tx, avec n'importe quels DS et ES).
avr_tx:
        push    ax
        push    bx
        push    cx
        push    es
        mov     bx, DSEG
        mov     es, bx
        mov     bh, al
        mov     cx, AVR_ESSAIS_TX
.essai: call    avr_debut
        jc      .perdu                  ; appele au milieu d'un acces SPI : ne peut attendre
        mov     al, AVR_ECRIRE
        call    avr_octet
        xor     al, al
        call    avr_octet               ; place libre
        or      al, al
        jz      .plein
        mov     al, bh
        call    avr_octet
        call    avr_fin
        jmp     .fin
.plein: call    avr_fin
        push    cx
        mov     cx, 200                 ; ~1 ms
.p:     loop    .p
        pop     cx
        loop    .essai
.perdu: cmp     byte [es:V_AVR_PERDUS], 0FFh
        je      .fin
        inc     byte [es:V_AVR_PERDUS]
.fin:   pop     es
        pop     cx
        pop     bx
        pop     ax
        ret

; avr_lire1 : un octet recu de l'ATmega (LIRE, on n'en prend qu'un : les autres restent
; dans l'ATmega). AL = octet, CF = 0 ; CF = 1 : rien (ou bus occupe). ES = DSEG.
; Preserve le reste.
avr_lire1:
        push    bx
        call    avr_debut
        jc      .r
        mov     al, AVR_LIRE
        call    avr_octet
        xor     al, al
        call    avr_octet               ; nombre en attente
        or      al, al
        jz      .vide
        xor     al, al
        call    avr_octet               ; le premier
        mov     bl, al
        call    avr_fin
        mov     al, bl
        clc
        jmp     .r
.vide:  call    avr_fin
        stc
.r:     pop     bx
        ret

; avr_service : apporte les octets recus par l'ATmega dans les files, comme le faisait IRQ4
; avec l'UART logiciel : console UART (V_UCON) -> touches (ucon_entree), sinon file de
; l'UART. Avec le 8259 : seulement apres IRQ4 (V_AVR_DISPO) ; sans 8259 : a chaque appel.
; Au plus 32 octets par appel. Appele par file_regarde, file_retire, ufile_retire.
; ES = DSEG. Preserve tout.
avr_service:
        cmp     byte [es:V_AVR], 0
        je      .r
        cmp     byte [es:V_AVR_SERV], 0
        jne     .r
        cmp     byte [es:V_AVR_OCC], 0
        jne     .r
        cmp     byte [es:V_PIC], 0
        je      .lire
        cmp     byte [es:V_AVR_DISPO], 0
        je      .r
.lire:  push    ax
        push    bx
        push    cx
        push    dx
        mov     byte [es:V_AVR_SERV], 1
        mov     byte [es:V_AVR_DISPO], 0
        mov     cx, 32
.b:     call    avr_place               ; file pleine : le reste attend dans l'ATmega
        jc      .reste                  ; (qui retient le terminal par RTS)
        call    avr_lire1
        jc      .fin
        cmp     byte [es:V_UCON], 0
        je      .ufile
        push    cx
        call    ucon_entree_avr         ; (lit les octets suivants d'une sequence)
        pop     cx
        jmp     .evt
.ufile: call    ufile_ajoute
.evt:   mov     byte [es:V_EVT], 1
        loop    .b
.reste: mov     byte [es:V_AVR_DISPO], 1 ; il en reste peut-etre : au prochain appel
.fin:   mov     byte [es:V_AVR_SERV], 0
        pop     dx
        pop     cx
        pop     bx
        pop     ax
.r:     ret

; avr_place : CF = 1 si la file de destination (clavier en console UART, sinon file de
; l'UART) a moins de 2 places libres (une sequence ANSI ou UTF-8 donne une seule touche,
; ESC suivi d'un autre octet en donne deux). ES = DSEG. Detruit AX.
avr_place:
        cmp     byte [es:V_UCON], 0
        je      .ufile
        mov     al, [es:V_FILE_T]
        sub     al, [es:V_FILE_Q]
        dec     al
        and     al, FILE_N - 1          ; places libres
        jmp     .cmp
.ufile: mov     al, [es:V_UFILE_T]
        sub     al, [es:V_UFILE_Q]
        dec     al
        and     al, UFILE_N - 1
.cmp:   cmp     al, 2
        ret                             ; CF = 1 si moins de 2

; avr_suivant : octet suivant d'une sequence (ANSI, UTF-8) envoyee d'un trait par le
; terminal : attend ~5 ms. AL = octet, CF = 1 si rien. ES = DSEG. Detruit CX.
avr_suivant:
        mov     cx, AVR_ESSAIS_SUIV
.a:     call    avr_lire1
        jnc     .r
        push    cx
        mov     cx, 30
.p:     loop    .p
        pop     cx
        loop    .a
        stc
.r:     ret

; avr_etat : ETAT. BX = place libre en emission, AL = drapeaux (40h CTS actif, 80h RTS actif,
; 01h/02h/04h pertes), CF = 1 si le bus est occupe. ES = DSEG. Detruit AH.
avr_etat:
        call    avr_debut
        jc      .r
        mov     al, 01h
        call    avr_octet               ; A5h
        xor     al, al
        call    avr_octet               ; recus (poids faible)
        xor     al, al
        call    avr_octet               ; recus (poids fort)
        xor     al, al
        call    avr_octet
        mov     bl, al                  ; place libre (poids faible)
        xor     al, al
        call    avr_octet
        mov     bh, al                  ; place libre (poids fort)
        xor     al, al
        call    avr_octet
        mov     ah, al                  ; drapeaux
        call    avr_fin
        mov     al, ah
        clc
.r:     ret

; avr_diag : ligne 3 de l'ecran Info avec l'ATmega, apres l'envoi de l'ecran au terminal :
; "AVR01 L0200 P00 FC0" = version, place libre dans l'ATmega (0200h : tout est parti),
; octets abandonnes par le BIOS (bus occupe), drapeaux d'ETAT (C0h : CTS et RTS actifs).
; DS = CS, ES = DSEG. Detruit AX, BX, CX, SI.
avr_diag:
        call    avr_etat
        jc      .r
        push    ax
        push    bx
        mov     al, 80h | LIGNE3
        call    lcd_cmd
        mov     si, txt_avr_diag
        mov     bx, 3
        call    lcd_texte               ; "AVR"
        mov     al, [es:V_AVR_VER]
        call    lcd_hex8
        mov     bx, 2
        call    lcd_texte               ; " L"
        pop     ax                      ; place libre
        push    ax
        xchg    al, ah
        call    lcd_hex8
        pop     ax
        call    lcd_hex8
        mov     bx, 2
        call    lcd_texte               ; " P"
        mov     al, [es:V_AVR_PERDUS]
        call    lcd_hex8
        mov     bx, 2
        call    lcd_texte               ; " F"
        pop     ax                      ; drapeaux
        call    lcd_hex8
        mov     bx, 1
        call    lcd_texte               ; " "
.r:     ret

txt_avr_diag:   db      'AVR L P F '

; menu_vit : ligne 2 du menu avec l'ATmega : "2) Test RAM 8)19200 " (sans ATmega : rien, la ligne
; de txt_menu reste). DS = CS, ES = DSEG. Detruit AX, BX, CX, SI.
menu_vit:
        cmp     byte [es:V_AVR], 0
        je      .r
        mov     al, 80h | LIGNE2
        call    lcd_cmd
        mov     si, txt_menu2_vit
        mov     bx, 14
        call    lcd_texte
        call    vit_si
        mov     bx, 6
        call    lcd_texte
.r:     ret

; vit_si : SI = texte de la vitesse V_AVR_VIT (6 caracteres). Detruit AX.
vit_si:
        mov     al, [es:V_AVR_VIT]
        cmp     al, AVR_V_NB
        jb      .ok
        xor     al, al
.ok:    mov     ah, 6
        mul     ah
        add     ax, txt_vitesses
        mov     si, ax
        ret

; menu_vitesse : menu 8) : sous-menu des vitesses (LCD et terminal) : ligne 1 = vitesse en
; service, 1) 9600 2) 19200 3) 38400 4) 57600 5) 115200, Echap = retour. Choix d'une autre
; vitesse : annonce au terminal, a l'ancienne vitesse, puis VITESSE (l'ATmega change quand
; tout est parti). Sans ATmega : rien. L'appelant redessine le menu. DS = CS, ES = DSEG.
; Detruit AX, BX, CX, SI.
menu_vitesse:
        cmp     byte [es:V_AVR], 0
        je      .r
        mov     si, txt_vit_ecran
        call    lcd_ecran
        mov     al, 80h | LIGNE1        ; "Vitesse UART: 19200 "
        call    lcd_cmd
        mov     si, txt_vit_titre
        mov     bx, 14
        call    lcd_texte
        call    vit_si
        mov     bx, 6
        call    lcd_texte
        call    ecran_uart              ; console UART : le sous-menu aussi sur le terminal
.att:   call    kbd_attend
        cmp     al, 1Bh                 ; Echap : retour au menu
        je      .r
        cmp     al, '1'
        jb      .att
        cmp     al, '0' + AVR_V_MENU
        ja      .att
        sub     al, '1'                 ; code de la vitesse (0 = 9600 ... 4 = 115200)
        cmp     al, [es:V_AVR_VIT]
        je      .r                      ; deja en service
        push    ax
        mov     si, txt_vit_msg1        ; "UART : " (CR LF devant)
        call    uart_texte
        pop     ax
        push    ax
        mov     [es:V_AVR_VIT], al      ; (pour vit_si ; avr_vitesse la note aussi)
        call    vit_si
        mov     cx, 6
.c:     lodsb                           ; vitesse sans les espaces
        cmp     al, ' '
        je      .s
        call    uart_tx
.s:     loop    .c
        mov     si, txt_vit_msg2        ; " bauds (regler le terminal)" CR LF
        call    uart_texte
        pop     ax
        call    avr_vitesse
.r:     ret

txt_vitesses:   db      '9600  19200 38400 57600 1152004800  2400  '

; IRQ4 (INT 0Ch) avec l'ATmega : un octet recu attend. Note seulement (aucune transaction
; en interruption) ; avr_service le lira au premier plan.
irq_uart_avr:
        push    ax
        push    es
        mov     ax, DSEG
        mov     es, ax
        mov     byte [es:V_AVR_DISPO], 1
        mov     byte [es:V_EVT], 1
        mov     al, PIC_EOI
        out     PIC_CMD, al
        pop     es
        pop     ax
        iret
