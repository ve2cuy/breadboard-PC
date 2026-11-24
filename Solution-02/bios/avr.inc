; =============================================================================
; avr.inc - UART par l'ATmega328P U17, esclave SPI du 8088 (schema du 2026-11-23).
;   SS = U12 PC0, SCK = PC5, MOSI = PC6 (partages avec la carte SD), MISO = U12 PB4.
;   Protocole (version 3) : arduino/atmega_uart/README_fr.md. Canal 1 = terminal (J5, UART
;   logiciel de l'ATmega, 57600 bauds a la mise sous tension) ; canal 2 (version 3) = module
;   Grove - UART WiFi V2 (J13, USART de l'ATmega, 115200 bauds, commandes AT) : INT 14h DX = 1
;   et menu 9). Sans ATmega (V_AVR = 0), le BIOS garde l'UART logiciel du 8088 (PA7, PB2) :
;   une seule ROM pour les deux cartes.
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
V_AVR_VIT2      equ     8FAh            ; vitesse du canal 2 (Wi-Fi), version 3
V_WIFI_COL3     equ     8FBh            ; menu 9) : colonne de la sortie du module (ligne 3)
V_WIFI_COL4     equ     8FCh            ; menu 9) : colonne de la commande tapee (ligne 4)

AVR_REPOS       equ     51h             ; PC0 = 1 (ATmega libre), CS de la SD = 1, MOSI = 1
AVR_SEL         equ     50h             ; PC0 = 0 : ATmega selectionne (SD toujours libre)
AVR_SCK         equ     20h             ; PC5
AVR_MOSI        equ     40h             ; PC6
AVR_MISO        equ     10h             ; PB4

AVR_SIGNATURE   equ     0A5h
AVR_IDENT       equ     00h
AVR_ETAT        equ     01h
AVR_LIRE        equ     02h
AVR_ECRIRE      equ     03h
AVR_VITESSE     equ     04h
AVR_VIDER       equ     05h
AVR_CANAL2      equ     10h             ; + ETAT ... VIDER : canal 2 (Wi-Fi), version 3
AVR_PONT        equ     06h             ; A5h : pont terminal <-> module (version 4), autre : fin
AVR_V_115200    equ     4
AVR_V_DEFAUT    equ     3               ; 57600 bauds (vitesse de l'ATmega a la mise sous tension)

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

; avr_recoit : recoit CX octets (CX >= 1) de l'ATmega selectionne vers ES:DI, en envoyant
; 00h (LIRE). 8 bits deroules par octet ; entre deux octets, ~35 us (AAM) : l'ATmega recharge
; SPDR dans son interruption (25 us suffisent, mesure au banc simavr). ~115 us par octet au
; lieu de ~215 avec avr_octet. Detruit AX, BX, CX, DX, DI.
avr_recoit:
        mov     dx, PPI2_PC
        mov     bl, AVR_SEL & ~AVR_MOSI         ; SCK = 0, MOSI = 0
        mov     bh, (AVR_SEL & ~AVR_MOSI) | AVR_SCK
.o:
%rep 8
        mov     al, bl
        out     dx, al
        mov     al, bh
        out     dx, al                  ; SCK = 1 : bit lu par les deux
        in      al, PPI2_PB
        and     al, AVR_MISO
        add     al, 0F0h                ; CF = MISO
        rcl     ah, 1
%endrep
        mov     al, ah
        stosb
        aam                             ; (~16 us : delai)
        loop    .o
        mov     al, AVR_SEL
        out     dx, al                  ; SCK = 0, MOSI = 1
        ret

; avr_envoie : envoie a l'ATmega selectionne les CX octets (CX >= 1) de DS:SI (ECRIRE ; MISO
; ignore). Deroule, ~35 us entre deux octets. Detruit AX, BX, CX, DX ; SI avance.
avr_envoie:
        mov     dx, PPI2_PC
.o:     lodsb
        mov     bl, al
%rep 8
        shl     bl, 1
        sbb     al, al                  ; FFh si le bit vaut 1
        and     al, AVR_MOSI
        or      al, AVR_SEL & ~AVR_MOSI
        out     dx, al                  ; SCK = 0, MOSI pose
        or      al, AVR_SCK
        out     dx, al                  ; SCK = 1
%endrep
        aam
        loop    .o
        mov     al, AVR_SEL
        out     dx, al
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
; version 1 (ou vitesse inconnue) : 57600 bauds imposes. Version 3 : vitesse du canal 2
; (V_AVR_VIT2). Sans ATmega, MISO (PB4) est lu a 1 : V_AVR = 0.
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
        xor     al, al
        call    avr_octet               ; vitesse du canal 2 (version 3)
        mov     [es:V_AVR_VIT2], al
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
        jb      .defaut
        cmp     byte [es:V_AVR_VIT], AVR_V_NB
        jb      .fin
.defaut:
        mov     al, AVR_V_DEFAUT        ; 57600 bauds
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
        push    dx
        mov     dl, AVR_ECRIRE
        call    avr_ecrire_c
        pop     dx
        ret

; avr_tx2 : envoie AL au module Wi-Fi (ECRIRE du canal 2), comme avr_tx. CF = 1 : perdu.
; Preserve le reste.
avr_tx2:
        push    dx
        mov     dl, AVR_CANAL2 | AVR_ECRIRE
        call    avr_ecrire_c
        pop     dx
        ret

; avr_ecrire_c : envoie AL par la commande ECRIRE DL (03h ou 13h). CF = 1 si l'octet est
; perdu (bus occupe, ATmega plein ~1,3 s). Preserve le reste.
avr_ecrire_c:
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
        mov     al, dl
        call    avr_octet
        xor     al, al
        call    avr_octet               ; place libre
        or      al, al
        jz      .plein
        mov     al, bh
        call    avr_octet
        call    avr_fin
        clc
        jmp     .fin
.plein: call    avr_fin
        push    cx
        mov     cx, 200                 ; ~1 ms
.p:     loop    .p
        pop     cx
        loop    .essai
.perdu: cmp     byte [es:V_AVR_PERDUS], 0FFh
        je      .stc
        inc     byte [es:V_AVR_PERDUS]
.stc:   stc
.fin:   pop     es
        pop     cx
        pop     bx
        pop     ax
        ret

; avr_lire1 : un octet recu de l'ATmega (LIRE, on n'en prend qu'un : les autres restent
; dans l'ATmega). AL = octet, CF = 0 ; CF = 1 : rien (ou bus occupe). ES = DSEG.
; Preserve le reste. avr_lire_c : idem avec la commande DL (02h ou 12h).
avr_lire1:
        push    dx
        mov     dl, AVR_LIRE
        call    avr_lire_c
        pop     dx
        ret
avr_lire_c:
        push    bx
        call    avr_debut
        jc      .r
        mov     al, dl
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

; avr_lire_bloc : LIRE DL (02h ou 12h) : au plus CX octets (1 a 255) vers SS:DI, en une
; transaction. CX = nombre lu (0 : rien, ou bus occupe). ES = DSEG. Preserve le reste.
avr_lire_bloc:
        push    ax
        push    bx
        push    di
        xor     bx, bx
        call    avr_debut
        jc      .r
        mov     al, dl
        call    avr_octet               ; A5h
        xor     al, al
        call    avr_octet               ; nombre en attente
        xor     ah, ah
        cmp     ax, cx
        jae     .n
        mov     cx, ax
.n:     jcxz    .f
        mov     bx, cx
        push    bx
        push    dx
        push    es
        push    ss
        pop     es
        call    avr_recoit              ; vers SS:DI
        pop     es
        pop     dx
        pop     bx
.f:     call    avr_fin
.r:     mov     cx, bx
        pop     di
        pop     bx
        pop     ax
        ret

; avr_attente2 : nombre d'octets recus du module Wi-Fi en attente dans l'ATmega (ETAT du
; canal 2) -> CX ; CF = 1 si le bus est occupe (CX = 0). ES = DSEG. Preserve le reste.
avr_attente2:
        push    ax
        xor     cx, cx
        call    avr_debut
        jc      .r
        mov     al, AVR_CANAL2 | AVR_ETAT
        call    avr_octet               ; A5h
        xor     al, al
        call    avr_octet
        mov     cl, al                  ; recus (poids faible)
        xor     al, al
        call    avr_octet
        mov     ch, al                  ; recus (poids fort)
        mov     al, 0
        call    avr_octet               ; place libre, drapeaux : ignores
        call    avr_octet
        call    avr_octet
        call    avr_fin
        clc
.r:     pop     ax
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

txt_115k2:      db      '115k2 '


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

; wifi_menu : menu 9) : le terminal (et le clavier PS/2) parle au module Wi-Fi (canal 2 de
; l'ATmega, commandes AT a 115200 bauds). Les touches vont au module (Entree = CR LF) ; ce que
; le module rend va tel quel au terminal (il renvoie lui-meme l'echo des commandes, ATE1)
; et, ligne par ligne, aux lignes 2 et 3 du LCD ; la commande tapee s'affiche en ligne 4.
; Echap : retour au menu. Sans ATmega de version 3 : message, puis retour. L'appelant
; redessine le menu. DS = CS, ES = DSEG. Detruit AX, BX, CX, DX, SI, DI, BP.
WIFI_BLOC       equ     32

wifi_menu:
        cmp     byte [es:V_AVR], 0
        je      .r
        cmp     byte [es:V_AVR_VER], 3
        jae     .ok
        mov     si, txt_wifi_v3         ; micrologiciel de l'ATmega trop ancien
        call    lcd_ecran
        call    ecran_uart
        PAUSE   10
.r:     ret
.ok:    mov     si, txt_wifi_ecran
        call    lcd_ecran
        mov     byte [es:V_WIFI_COL3], 0
        mov     byte [es:V_WIFI_COL4], 2
        call    uart_calme
        mov     si, txt_wifi_uart
        call    uart_texte
        sub     sp, WIFI_BLOC
        mov     bp, sp
.boucle:
        sti
        cmp     byte [es:V_PIC], 0      ; sans 8259 : clavier PS/2 scrute ici
        jne     .touche
        call    kbd_libere
        mov     cx, 300
        call    kbd_scrute
        call    kbd_bloque
.touche:
        call    file_retire             ; (amene aussi les octets du terminal)
        jc      .module
        cmp     al, 1Bh                 ; Echap : retour au menu
        je      .fin
        cmp     al, 02h                 ; Ctrl+B : pont terminal <-> module (esptool)
        jne     .pas_pont
        call    wifi_pont
        jmp     .fin
.pas_pont:
        cmp     al, 13
        je      .entree
        or      al, al                  ; touches sans caractere (fleches...) : ignorees
        jz      .boucle
        call    avr_tx2
        call    wifi_tape
        jmp     .boucle
.entree:
        call    avr_tx2                 ; CR LF : fin de la commande AT
        mov     al, 10
        call    avr_tx2
        call    wifi_l4_vide
        jmp     .boucle
.module:
        mov     di, bp
        mov     cx, WIFI_BLOC
        mov     dl, AVR_CANAL2 | AVR_LIRE
        call    avr_lire_bloc
        jcxz    .boucle
        mov     si, bp
.m:     mov     al, [ss:si]
        inc     si
        call    uart_tx                 ; au terminal, tel quel
        call    wifi_lcd                ; aux lignes 2 et 3
        loop    .m
        jmp     .boucle
.fin:   add     sp, WIFI_BLOC
        mov     si, txt_wifi_fin        ; CR LF au terminal
        call    uart_texte
        ret

; wifi_pont : menu 9), Ctrl+B : pont terminal <-> module (commande PONT, ATmega version 4) pour
; graver le module avec esptool a travers la carte (adaptateur du terminal sur J5). Le terminal
; passe a 115200 bauds (vitesse du module) le temps du pont ; Echap au clavier PS/2 y met fin
; et rend la vitesse d'avant. Pendant le pont, le BIOS n'envoie rien au terminal.
; DS = CS, ES = DSEG. Detruit AX, BX, CX, DX, SI.
wifi_pont:
        cmp     byte [es:V_AVR_VER], 4
        jae     .ok
        mov     si, txt_pont_v4         ; micrologiciel de l'ATmega trop ancien
        call    lcd_ecran
        PAUSE   10
        ret
.ok:    mov     si, txt_pont_ecran
        call    lcd_ecran
        mov     si, txt_pont_uart       ; annonce, a la vitesse du terminal en service
        call    uart_texte
        mov     al, [es:V_AVR_VIT]
        push    ax                      ; vitesse a rendre a la fin
        mov     al, AVR_V_115200
        call    avr_vitesse             ; (appliquee quand l'annonce est partie)
        mov     al, AVR_SIGNATURE
        call    avr_pont                ; PONT
.att:   call    kbd_attend              ; seul le clavier PS/2 arrive ici (le terminal va au module)
        cmp     al, 1Bh
        jne     .att
        xor     al, al
        call    avr_pont                ; fin du pont
        pop     ax
        call    avr_vitesse             ; vitesse d'avant
        mov     si, txt_pont_fin
        call    uart_texte
        ret

; avr_pont : PONT, AL = A5h (pont) ou autre (fin). ES = DSEG. Preserve tout.
avr_pont:
        push    ax
        push    ax
        call    avr_debut
        pop     ax
        jc      .r
        push    ax
        mov     al, AVR_PONT
        call    avr_octet
        pop     ax
        call    avr_octet
        call    avr_fin
.r:     pop     ax
        ret

; wifi_lcd : caractere AL du module aux lignes 2 et 3 du LCD : la ligne en cours s'ecrit en
; ligne 3 ; apres LF, le caractere suivant la monte en ligne 2 (lignes vides sautees) ; CR et
; autres controles ignores.
; ES = DSEG. Preserve tout.
wifi_lcd:
        push    ax
        push    bx
        push    cx
        cmp     al, 10
        je      .lf
        cmp     al, ' '
        jb      .r
        cmp     al, 7Eh
        ja      .r
        cmp     byte [es:V_WIFI_COL3], LCD_COLS
        jb      .ecrit
        push    ax
        call    wifi_monte              ; ligne pleine : a la suivante
        pop     ax
.ecrit: push    ax
        mov     al, [es:V_WIFI_COL3]
        add     al, 80h | LIGNE3
        call    lcd_cmd
        pop     ax
        call    lcd_car
        inc     byte [es:V_WIFI_COL3]
        jmp     .r
.lf:    cmp     byte [es:V_WIFI_COL3], 0
        je      .r                      ; ligne vide : rien
        mov     byte [es:V_WIFI_COL3], LCD_COLS ; montee au prochain caractere : les deux
                                        ; dernieres lignes restent visibles
.r:     pop     cx
        pop     bx
        pop     ax
        ret

; wifi_monte : ligne 3 -> ligne 2 (depuis la copie V_OMBRE), ligne 3 videe. Detruit AX, BX, CX.
wifi_monte:
        mov     al, 80h | LIGNE2
        call    lcd_cmd
        mov     bx, 40                  ; V_OMBRE : ligne 3 = octets 40 a 59
.c:     mov     al, [es:V_OMBRE + bx]
        call    lcd_car
        inc     bx
        cmp     bx, 60
        jb      .c
        mov     al, 80h | LIGNE3
        call    lcd_cmd
        mov     bx, LCD_COLS
.e:     mov     al, ' '
        call    lcd_car
        dec     bx
        jnz     .e
        mov     byte [es:V_WIFI_COL3], 0
        ret

; wifi_tape : caractere AL tape, en ligne 4 apres "> " (retour arriere : efface le dernier).
; ES = DSEG. Preserve tout.
wifi_tape:
        push    ax
        push    cx
        cmp     al, 8
        jne     .car
        cmp     byte [es:V_WIFI_COL4], 2
        jbe     .r
        dec     byte [es:V_WIFI_COL4]
        mov     al, [es:V_WIFI_COL4]
        add     al, 80h | LIGNE4
        call    lcd_cmd
        mov     al, ' '
        call    lcd_car
        jmp     .r
.car:   cmp     al, ' '
        jb      .r
        cmp     byte [es:V_WIFI_COL4], LCD_COLS
        jb      .ecrit
        push    ax
        call    wifi_l4_vide            ; ligne pleine : on repart au debut
        pop     ax
.ecrit: push    ax
        mov     al, [es:V_WIFI_COL4]
        add     al, 80h | LIGNE4
        call    lcd_cmd
        pop     ax
        call    lcd_car
        inc     byte [es:V_WIFI_COL4]
.r:     pop     cx
        pop     ax
        ret

; wifi_l4_vide : ligne 4 = "> " (commande vide). ES = DSEG. Preserve tout.
wifi_l4_vide:
        push    ax
        push    bx
        push    cx
        mov     al, 80h | LIGNE4
        call    lcd_cmd
        mov     al, '>'
        call    lcd_car
        mov     bx, LCD_COLS - 1
.e:     mov     al, ' '
        call    lcd_car
        dec     bx
        jnz     .e
        mov     byte [es:V_WIFI_COL4], 2
        pop     cx
        pop     bx
        pop     ax
        ret

; int14_wifi : INT 14h, DX = 1 : module Wi-Fi (canal 2 de l'ATmega, version 3). AH = 00h ou
; 03h : etat (AH bit 0 = octet en attente, 60h emetteur vide ; AL = 30h) ; AH = 01h : envoie
; AL ; AH = 02h : octet recu (attente ~0,5 s, puis AH = 80h). Sans module : AH = 80h.
; Par blocs (BIOS 3.1, pour les pilotes d'ELKS et du DOS) : AH = 08h : lit au plus CX octets
; (1 a 255) recus du module vers ES:BX, sans attendre ; AH = 09h : envoie CX octets de ES:BX
; au module (attend la place, ~1 s au plus). Sortie : CX = octets lus / envoyes, AH = 00h
; (80h : pas d'ATmega de version 3). Une seule transaction SPI pour jusqu'a 255 octets.
int14_wifi:
        cmp     ah, 08h
        je      int14_bloc
        cmp     ah, 09h
        je      int14_bloc
        push    es
        push    cx
        push    dx
        mov     cx, DSEG
        mov     es, cx
        cmp     byte [es:V_AVR], 0
        je      .absent
        cmp     byte [es:V_AVR_VER], 3
        jb      .absent
        cmp     ah, 01h
        jne     .pas_tx
        call    avr_tx2
        mov     ah, 60h
        jnc     .fin
.absent:
        mov     ah, 80h
        jmp     .fin
.pas_tx:
        cmp     ah, 02h
        jne     .etat
        mov     cx, 2000                ; ~0,5 s
.l:     mov     dl, AVR_CANAL2 | AVR_LIRE
        call    avr_lire_c
        jnc     .recu
        push    cx
        mov     cx, 30
.p:     loop    .p
        pop     cx
        loop    .l
        mov     ah, 80h
        jmp     .fin
.recu:  xor     ah, ah
        jmp     .fin
.etat:  call    avr_attente2
        mov     ax, 6030h               ; emetteur vide ; CTS, DSR
        jcxz    .fin
        or      ah, 01h                 ; donnee prete
.fin:   pop     dx
        pop     cx
        pop     es
        iret

int14_bloc:
        push    ds
        push    es
        push    si
        push    di
        push    dx
        push    ax
        mov     dx, es
        mov     ds, dx                  ; DS = segment du tampon de l'appelant
        mov     dx, DSEG
        mov     es, dx
        cmp     byte [es:V_AVR], 0
        je      .absent
        cmp     byte [es:V_AVR_VER], 3
        jb      .absent
        pop     ax
        push    ax
        cmp     ah, 08h
        jne     .ecrire
        cmp     cx, 255
        jbe     .n
        mov     cx, 255
.n:     mov     di, bx
        mov     dl, AVR_CANAL2 | AVR_LIRE
        call    avr_lire_bloc_ds
        jmp     .ok
.ecrire:
        mov     si, bx
        call    avr_ecrire_bloc2
.ok:    pop     ax
        xor     ah, ah
        jmp     .fin
.absent:
        pop     ax
        mov     ah, 80h
        xor     cx, cx
.fin:   pop     dx
        pop     di
        pop     si
        pop     es
        pop     ds
        iret

; avr_lire_bloc_ds : comme avr_lire_bloc, vers DS:DI. ES = DSEG. Preserve le reste.
avr_lire_bloc_ds:
        push    ax
        push    bx
        push    di
        xor     bx, bx
        call    avr_debut
        jc      .r
        mov     al, dl
        call    avr_octet               ; A5h
        xor     al, al
        call    avr_octet               ; nombre en attente
        xor     ah, ah
        cmp     ax, cx
        jae     .n
        mov     cx, ax
.n:     jcxz    .f
        mov     bx, cx
        push    bx
        push    dx
        push    es
        push    ds
        pop     es
        call    avr_recoit              ; vers DS:DI
        pop     es
        pop     dx
        pop     bx
.f:     call    avr_fin
.r:     mov     cx, bx
        pop     di
        pop     bx
        pop     ax
        ret

; avr_ecrire_bloc2 : envoie au module (ECRIRE du canal 2) les CX octets de DS:SI, par
; transactions d'au plus la place libre dans l'ATmega ; ATmega plein ou bus occupe : nouvel
; essai ~1 ms plus tard, ~1 s au plus. CX = octets envoyes. ES = DSEG. Detruit SI.
avr_ecrire_bloc2:
        push    ax
        push    bx
        push    dx
        push    bp
        xor     bp, bp                  ; octets envoyes
        mov     dx, AVR_ESSAIS_TX
.essai: jcxz    .fin
        call    avr_debut
        jc      .attente                ; bus occupe (carte SD, autre transaction)
        mov     al, AVR_CANAL2 | AVR_ECRIRE
        call    avr_octet               ; A5h
        xor     al, al
        call    avr_octet               ; place libre (au plus 255)
        xor     ah, ah
        mov     bx, ax
        cmp     bx, cx
        jbe     .m
        mov     bx, cx
.m:     or      bx, bx
        jz      .plein
        push    cx
        push    dx
        push    bx
        mov     cx, bx
        call    avr_envoie              ; DS:SI, SI avance
        pop     bx
        pop     dx
        pop     cx
        add     bp, bx
        sub     cx, bx
        call    avr_fin
        jmp     .essai
.plein: call    avr_fin
.attente:
        push    cx
        mov     cx, 200                 ; ~1 ms
.p:     loop    .p
        pop     cx
        dec     dx
        jnz     .essai
.fin:   mov     cx, bp
        pop     bp
        pop     dx
        pop     bx
        pop     ax
        ret

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
