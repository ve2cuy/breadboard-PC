; =============================================================================
; pico.inc - Raspberry Pi Pico W sur O5 du 74LS138 (ports 50h-57h), derriere U18/U19
; (SN74LVC245, schema du 2026-11-23). Protocole des registres : pico/coeur/src/lib.rs.
;   50h  donnee : file de lecture (L) / file d'ecriture (E)
;   51h  ETAT (L) / COMMANDE (E)
;   52h-55h  parametres (LBA en petit-boutiste, nombre)
;   56h  signature 50h (L)
; Le Pico a sa carte microSD (J14) et le Wi-Fi : quand il est la, le BIOS lit et ecrit les
; secteurs par lui (environ 20 fois plus vite que le SPI fait par le 8088 sur U12) et
; INT 14h DX = 1 (blocs AH = 08h / 09h des pilotes S02PKT et ttyS1 d'ELKS) passe par lui au
; lieu du canal 2 de l'ATmega. Sans Pico (ou sans carte dans J14), rien ne change.
; Une transaction a la fois (V_PICO_OCC) : une interruption (INT 1Ch de S02PKT, ELKS) qui
; trouve le Pico occupe rend 0 octet au lieu d'attendre.
; =============================================================================

PICO_DONNEE     equ     50h
PICO_ETAT       equ     51h
PICO_P0         equ     52h
PICO_P1         equ     53h
PICO_P2         equ     54h
PICO_P3         equ     55h
PICO_SIG        equ     56h
PICO_SIGNATURE  equ     50h

PE_DONNEE       equ     01h
PE_OCCUPE       equ     02h
PE_ERREUR       equ     04h
PE_RESEAU       equ     08h
PE_CARTE        equ     10h

PC_VIDER        equ     00h
PC_IDENT        equ     01h
PC_SD_INIT      equ     10h
PC_SD_LIRE      equ     11h
PC_SD_ECRIRE    equ     12h
PC_NET_LIRE     equ     20h
PC_NET_ECRIRE   equ     21h

V_PICO          equ     8A4h            ; 1 = Pico present (IDENT au demarrage)
V_PICO_SD       equ     8A5h            ; 1 = la carte SD est celle du Pico (J14)
V_PICO_VER      equ     8A6h            ; version du protocole des registres
V_PICO_OCC      equ     8A7h            ; 1 = transaction avec le Pico en cours
V_PICO_SECT     equ     8A8h            ; (dd) secteurs de la carte du Pico

; pico_attente : attend la fin de la commande (ETAT bit 1 a 0). CF = 1 si erreur (bit 2)
; ou si le Pico ne repond pas (~0,8 s). Preserve tout sauf AL et les drapeaux.
pico_attente:
        push    bx
        mov     bx, 2
        call    pico_attente_bx
        pop     bx
        ret

; pico_attente_bx : idem, au plus BX x ~0,4 s. Detruit AL, BX.
pico_attente_bx:
        push    cx
.b:     xor     cx, cx
.c:     in      al, PICO_ETAT
        test    al, PE_OCCUPE
        jz      .fin
        loop    .c
        dec     bx
        jnz     .b
        stc
        jmp     .r
.fin:   test    al, 80h                 ; bus en l'air : pas de Pico
        jnz     .err
        test    al, PE_ERREUR
        jz      .r                      ; CF = 0
.err:   stc
.r:     pop     cx
        ret

; pico_cmd : envoie la commande AL et attend sa fin. CF = 1 si erreur.
pico_cmd:
        out     PICO_ETAT, al
        jmp     pico_attente

; pico_prend / pico_rend : prend le Pico pour une transaction (CF = 1 : deja occupe).
; ES = DSEG. Preservent tout.
pico_prend:
        pushf
        cli
        cmp     byte [es:V_PICO_OCC], 0
        jne     .occ
        mov     byte [es:V_PICO_OCC], 1
        popf
        clc
        ret
.occ:   popf
        stc
        ret

pico_rend:
        mov     byte [es:V_PICO_OCC], 0
        ret

; pico_detecte : cherche le Pico (signature, puis IDENT = "S02PICO" + version). V_PICO,
; V_PICO_VER. ES = DSEG. Detruit AX, CX, SI.
pico_detecte:
        mov     byte [es:V_PICO], 0
        mov     byte [es:V_PICO_SD], 0
        mov     byte [es:V_PICO_OCC], 0
        in      al, PICO_ETAT
        test    al, 80h
        jnz     .fin
        in      al, PICO_SIG
        cmp     al, PICO_SIGNATURE
        jne     .fin
        mov     al, PC_VIDER
        out     PICO_ETAT, al
        mov     al, PC_IDENT
        call    pico_cmd
        jc      .fin
        mov     si, txt_pico_id
        mov     cx, 7
.c:     in      al, PICO_DONNEE
        cmp     al, [cs:si]
        jne     .fin
        inc     si
        loop    .c
        in      al, PICO_DONNEE
        mov     [es:V_PICO_VER], al
        mov     byte [es:V_PICO], 1
        xor     al, al
        out     PICO_SIG, al            ; pas d'interruption (scrutation)
.fin:   ret

txt_pico_id:    db      'S02PICO'
txt_pico_v:     db      'Pico v'

; pico_sd_init : carte de J14 par le Pico. CF = 0 : V_PICO_SD = 1, V_SD_TYPE = 3 (adresses en
; secteurs), V_PICO_SECT. ES = DSEG. Detruit AX, CX.
pico_sd_init:
        mov     byte [es:V_PICO_SD], 0
        cmp     byte [es:V_PICO], 1
        jne     .non
        call    pico_prend
        jc      .non
        push    bx
        mov     al, PC_VIDER
        out     PICO_ETAT, al
        mov     al, PC_SD_INIT
        out     PICO_ETAT, al
        mov     bx, 8                   ; l'initialisation d'une carte peut prendre ~1 s
        call    pico_attente_bx
        pop     bx
        jc      .rend
        in      al, PICO_DONNEE         ; 1 = carte prete
        cmp     al, 1
        jne     .rend_err
        in      al, PICO_DONNEE
        mov     [es:V_PICO_SECT], al
        in      al, PICO_DONNEE
        mov     [es:V_PICO_SECT + 1], al
        in      al, PICO_DONNEE
        mov     [es:V_PICO_SECT + 2], al
        in      al, PICO_DONNEE
        mov     [es:V_PICO_SECT + 3], al
        mov     byte [es:V_PICO_SD], 1
        mov     byte [es:V_SD_TYPE], 3
        call    pico_rend
        clc
        ret
.rend_err:
        stc
.rend:  call    pico_rend
.non:   stc
        ret

; pico_lba : DX:AX -> parametres 0-3. Detruit AL.
pico_lba:
        out     PICO_P0, al
        mov     al, ah
        out     PICO_P1, al
        mov     al, dl
        out     PICO_P2, al
        mov     al, dh
        out     PICO_P3, al
        ret

; pico_sd_lire : secteur DX:AX (512 o) en ES:DI par le Pico. CF. Detruit AX, BX, CX, DX, DI.
pico_sd_lire:
        push    es
        mov     bx, DSEG
        mov     es, bx
        call    pico_prend
        pop     es
        jc      .err0
        call    pico_lba
        mov     al, PC_SD_LIRE
        call    pico_cmd
        jc      .err
        mov     dx, PICO_DONNEE
        mov     cx, 512 / 8
        cld
.l:
%rep 8
        in      al, dx
        stosb
%endrep
        loop    .l
        call    .rend
        clc
        ret
.err:   call    .rend
.err0:  stc
        ret
.rend:  push    es
        mov     bx, DSEG
        mov     es, bx
        call    pico_rend
        pop     es
        ret

; pico_sd_ecrire : ecrit le secteur DX:AX (512 o) depuis DS:SI. CF. Detruit AX, BX, CX, DX, SI.
pico_sd_ecrire:
        push    es
        mov     bx, DSEG
        mov     es, bx
        call    pico_prend
        jc      .err0
        mov     bx, dx
        mov     al, PC_VIDER
        out     PICO_ETAT, al
        mov     dx, PICO_DONNEE
        mov     cx, 512 / 8
        cld
.l:
%rep 8
        lodsb
        out     dx, al
%endrep
        loop    .l
        mov     dx, bx
        call    pico_lba
        mov     al, PC_SD_ECRIRE
        call    pico_cmd
        call    pico_rend               ; (garde CF)
        pop     es
        ret
.err0:  pop     es
        stc
        ret

; pico_capacite : DX:AX = capacite de la carte du Pico en Mo. ES = DSEG.
pico_capacite:
        mov     ax, [es:V_PICO_SECT]
        mov     dx, [es:V_PICO_SECT + 2]
        mov     cx, 11                  ; / 2048
.d:     shr     dx, 1
        rcr     ax, 1
        loop    .d
        clc
        ret

; -----------------------------------------------------------------------------
; INT 14h, DX = 1, avec le Pico : memes appels qu'avec le module de l'ATmega (int14_wifi).
; AH = 00h / 03h : etat (AH bit 0 = octet en attente ; 60h emetteur vide ; AL = 30h) ;
; AH = 01h : envoie AL ; AH = 02h : octet recu (~0,5 s, puis AH = 80h) ;
; AH = 08h : lit au plus CX octets (1-255) vers ES:BX sans attendre ;
; AH = 09h : envoie CX octets de ES:BX. Sortie : CX = octets lus / envoyes, AH = 00h.
; AH = 0Ah : type du lien : AX = 0050h (Pico W ; le module de l'ATmega rend l'etat, AL = 30h).
; Pico occupe (interruption pendant une autre transaction) : CX = 0.
; -----------------------------------------------------------------------------
int14_pico:
        cmp     ah, 0Ah                 ; type du lien : AL = 50h (Pico W) ; avec l'ATmega,
        jne     .pas_type               ; AH = 0Ah rend l'etat (AL = 30h)
        mov     ax, 0050h
        iret
.pas_type:
        cmp     ah, 08h
        je      .bloc
        cmp     ah, 09h
        je      .bloc
        cmp     ah, 01h
        je      .tx
        cmp     ah, 02h
        je      .rx
        in      al, PICO_ETAT           ; 00h, 03h : etat
        and     al, PE_RESEAU
        mov     ah, 60h
        jz      .e
        or      ah, 01h
.e:     mov     al, 30h
        iret
.tx:    push    bx
        push    cx
        push    es
        push    ax
        mov     cx, ss
        mov     es, cx
        mov     bx, sp                  ; l'octet est en SS:SP (AL empile)
        mov     cx, 1
        mov     ah, 09h
        pushf
        push    cs
        call    .bloc
        pop     ax
        mov     ah, 60h
        or      cx, cx
        jnz     .tx_ok
        mov     ah, 80h
.tx_ok: pop     es
        pop     cx
        pop     bx
        iret
.rx:    push    cx
        push    dx
        push    es
        push    bx
        push    ax
        mov     dx, 2000                ; ~0,5 s
.rx_l:  mov     cx, ss
        mov     es, cx
        mov     bx, sp                  ; l'octet recu ecrase AL empile
        mov     cx, 1
        mov     ah, 08h
        pushf
        push    cs
        call    .bloc
        or      cx, cx
        jnz     .rx_ok
        mov     cx, 30
.p:     loop    .p
        dec     dx
        jnz     .rx_l
        pop     ax
        mov     ah, 80h
        jmp     .rx_f
.rx_ok: pop     ax
        xor     ah, ah
.rx_f:  pop     bx
        pop     es
        pop     dx
        pop     cx
        iret

.bloc:  push    ds
        push    es
        push    dx
        push    di
        push    si
        push    ax
        mov     dx, es
        mov     ds, dx                  ; DS = segment du tampon de l'appelant
        mov     dx, DSEG
        mov     es, dx
        call    pico_prend
        jc      .occ
        pop     ax
        push    ax
        cmp     ah, 08h
        jne     .ecrire
        ; lecture : NET_LIRE de CX (1-255) octets au plus -> nombre, puis les octets
        cmp     cx, 255
        jbe     .n
        mov     cx, 255
.n:     mov     al, cl
        out     PICO_P0, al
        mov     al, PC_NET_LIRE
        call    pico_cmd
        mov     cx, 0
        jc      .fin
        in      al, PICO_DONNEE
        mov     cl, al
        jcxz    .fin
        mov     di, bx
        push    cx
        mov     dx, PICO_DONNEE
.r:     in      al, dx
        mov     [di], al
        inc     di
        loop    .r
        pop     cx
        jmp     .fin
.ecrire:
        ; ecriture : par paquets de 2048 octets au plus (file d'ecriture du Pico : 4096)
        mov     si, bx
        xor     di, di                  ; octets envoyes
        mov     al, PC_VIDER
        out     PICO_ETAT, al
.paquet:
        jcxz    .fait
        mov     bx, cx
        cmp     bx, 2048
        jbe     .m
        mov     bx, 2048
.m:     sub     cx, bx
        add     di, bx
        mov     dx, PICO_DONNEE
.w:     lodsb
        out     dx, al
        dec     bx
        jnz     .w
        mov     al, PC_NET_ECRIRE
        call    pico_cmd
        jnc     .paquet
.fait:  mov     cx, di
.fin:   call    pico_rend
        pop     ax
        xor     ah, ah
        jmp     .sortie
.occ:   pop     ax
        xor     ah, ah
        xor     cx, cx
.sortie:
        pop     si
        pop     di
        pop     dx
        pop     es
        pop     ds
        iret
