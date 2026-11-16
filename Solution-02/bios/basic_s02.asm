; =============================================================================
; basic_s02.asm - le BASIC "GW-BASIC-like" de Solution-01 (Solution-01/lib/basic*.asm,
; inchange) pour Solution-02. Assemble a part (make : build/basic_s02.bin) avec
;   nasm -f bin -i ../../Solution-01/ -o build/basic_s02.bin basic_s02.asm
; et place par bios.asm en F000:8000 (BASIC_ORG). Le BIOS l'appelle par un CALL proche
; a BASIC_ORG avec SS = 1000h (VAR_SEG du BASIC), DS = CS.
;
; Couche d'adaptation (le BASIC est compile avec BASIC_TEST : sans l'UART ni le pont
; STM32 de Solution-01) :
;   uart_tx_byte      -> INT 10h AH=0Eh : tampon d'ecran 24 x 80, fenetre du LCD et, si la
;                        console UART est a ON, le terminal
;   uart_rx_available -> INT 16h AH=01h (clavier PS/2 et touches du terminal)
;   uart_rx_byte      -> INT 16h AH=00h ; fleches, Debut, Fin -> ESC [ A..D, H, F (rappel
;                        de la derniere commande par fleche haut, comme au terminal)
;   rtc_get / rtc_set -> heure : compteur de tops du BDA (INT 1Ah, avance par IRQ0) ;
;                        date gardee en RAM (DSEG:0C60h), 1980-01-01 au depart
;   fs_*              -> fichiers sur la disquette A: (fs_s02.inc) : SAVE, LOAD, FILES, KILL,
;                        OPEN/CLOSE/PRINT#/INPUT#, FORMAT, DSKREAD/DSKWRITE ; BOOT "NOM.IMG"
;                        monte l'image (INT 13h AH=F0h du BIOS) puis demarre dessus
; =============================================================================
        bits    16
        cpu     8086
BASIC_ORG       equ     8000h
        org     BASIC_ORG

%define BASIC_TEST
%include "include/hardware.inc"

DSEG_S02        equ     7F00h           ; donnees du BIOS de Solution-02
RTC_DATE        equ     0C60h           ; (DSEG) annee (mot), mois, jour ; 0 = jamais reglee

entree:
        push    ax                      ; etat des fichiers et du clavier (FS_SEG) a zero :
        push    ds                      ; rien d'ouvert, disquette a relire
        mov     ax, FS_SEG
        mov     ds, ax
        mov     byte [fv_monte], 0
        mov     byte [ff_ouvert], 0
        mov     byte [fk_n], 0
        pop     ds
        pop     ax
        jmp     basic_run

; ---- console ---------------------------------------------------------------------
uart_tx_byte:
        push    ax
        push    bx
        mov     ah, 0Eh
        xor     bx, bx
        int     10h
        pop     bx
        pop     ax
        ret

; Touches etendues (AL = 0 : fleches, Debut, Fin, Suppr...) -> sequences ANSI, comme
; celles du terminal de Solution-01 que le BASIC comprend (ESC [ A : rappel de la
; derniere commande) : les octets en attente sont gardes en FS_SEG (fk_n, fk_buf).
touches_ansi:
        db      48h, 'A', 50h, 'B', 4Dh, 'C', 4Bh, 'D', 47h, 'H', 4Fh, 'F', 0

; touche_ansi : AH = code XT d'une touche etendue -> AL = lettre de sa sequence, CF = 0 ;
; CF = 1 : sans sequence. Detruit AL.
touche_ansi:
        push    si
        mov     si, touches_ansi
.l:     mov     al, [cs:si]
        or      al, al
        jz      .non
        cmp     al, ah
        je      .oui
        add     si, 2
        jmp     .l
.oui:   mov     al, [cs:si + 1]
        pop     si
        clc
        ret
.non:   pop     si
        stc
        ret

; uart_rx_available : CF = 0 et AL = 1 si une touche attend ; CF = 1 et AL = 0 sinon.
uart_rx_available:
        push    bx
        push    ds
        mov     bx, FS_SEG
        mov     ds, bx
        cmp     byte [fk_n], 0          ; reste d'une sequence
        pop     ds
        jne     .oui
        mov     bl, ah
        mov     ah, 01h
        int     16h
        jz      .rien
        or      al, al
        jnz     .oui_ah
        push    ax                      ; touche etendue : gardee si elle a une sequence,
        call    touche_ansi             ; sinon retiree et ignoree
        pop     ax
        jnc     .oui_ah
        mov     ah, 00h
        int     16h
.rien:  mov     ah, bl
        pop     bx
        mov     al, 0
        stc
        ret
.oui_ah:
        mov     ah, bl
.oui:   pop     bx
        mov     al, 1
        clc
        ret

; uart_rx_byte : AL = caractere (attend une touche ; touche etendue -> ESC [ x, x livre ensuite).
uart_rx_byte:
        push    bx
        push    ds
        mov     bx, FS_SEG
        mov     ds, bx
        mov     bl, ah
        cmp     byte [fk_n], 0
        je      .t
        mov     al, [fk_buf]            ; octet suivant de la sequence
        mov     ah, [fk_buf + 1]
        mov     [fk_buf], ah
        dec     byte [fk_n]
        jmp     .fin
.t:     mov     ah, 00h
        int     16h
        or      al, al
        jnz     .fin
        call    touche_ansi
        jc      .t                      ; sans sequence : ignoree
        mov     byte [fk_buf], '['
        mov     [fk_buf + 1], al
        mov     byte [fk_n], 2
        mov     al, 1Bh
.fin:   mov     ah, bl
        pop     ds
        pop     bx
        ret

; ---- horloge ------------------------------------------------------------------------
; rtc_get : 8 octets en ES:DI : annee (mot), mois, jour, heures, minutes, secondes,
; centiemes. Heure = tops du BDA (18,2065 par seconde). CF = 0. Preserve tout.
rtc_get:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        mov     ax, DSEG_S02
        mov     ds, ax
        mov     ax, [RTC_DATE]
        or      ax, ax
        jnz     .date
        mov     ax, 1980                ; jamais reglee
        mov     word [RTC_DATE], ax
        mov     word [RTC_DATE + 2], 0101h
.date:  cld
        stosw                           ; annee
        mov     ax, [RTC_DATE + 2]
        stosw                           ; mois, jour
        pop     ds
        mov     ah, 00h
        int     1Ah                     ; CX:DX = tops depuis minuit
        mov     ax, dx
        mov     dx, cx
        mov     bx, 10                  ; secondes x 10 = tops x 10 / 18,2 (= tops x 100 / 182)
        call    mul32_16                ; DX:AX x 10
        mov     bx, 182
        call    div32_16                ; DX:AX = dixiemes... (tops x 10 / 182 = secondes)
        push    bx                      ; reste (en 182e de seconde)
        mov     bx, 3600
        div     bx                      ; AX = heures, DX = secondes de l'heure
        stosb
        mov     ax, dx
        xor     dx, dx
        mov     bx, 60
        div     bx
        stosb                           ; minutes
        mov     al, dl
        stosb                           ; secondes
        pop     ax                      ; centiemes = reste x 100 / 182
        mov     bl, 100
        mul     bl
        mov     bl, 182
        div     bl
        stosb
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        ret

; rtc_set : 7 octets en DS:SI (annee mot, mois, jour, heures, minutes, secondes) :
; date en RAM, heure -> compteur de tops (INT 1Ah AH=01h). Preserve tout.
rtc_set:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    es
        mov     ax, DSEG_S02
        mov     es, ax
        lodsw
        mov     [es:RTC_DATE], ax
        lodsw
        mov     [es:RTC_DATE + 2], ax
        lodsb                           ; heures
        mov     bl, 60
        mul     bl                      ; AX = heures x 60
        mov     bl, [si]                ; + minutes
        xor     bh, bh
        add     ax, bx
        mov     bx, 60
        mul     bx                      ; DX:AX = minutes x 60
        mov     bl, [si + 1]            ; + secondes
        xor     bh, bh
        add     ax, bx
        adc     dx, 0
        mov     bx, 182                 ; tops = secondes x 182 / 10
        call    mul32_16
        mov     bx, 10
        call    div32_16
        mov     cx, dx
        mov     dx, ax
        mov     ah, 01h
        int     1Ah
        pop     es
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; mul32_16 : DX:AX = DX:AX x BX (le resultat doit tenir sur 32 bits). Detruit CX.
mul32_16:
        push    ax
        mov     ax, dx
        mul     bx                      ; poids fort x BX
        mov     cx, ax
        pop     ax
        mul     bx                      ; poids faible x BX
        add     dx, cx
        ret

; div32_16 : DX:AX = DX:AX / BX, BX = reste. Detruit CX.
div32_16:
        push    ax
        mov     ax, dx
        xor     dx, dx
        div     bx
        mov     cx, ax                  ; quotient fort
        pop     ax
        div     bx
        mov     bx, dx                  ; reste
        mov     dx, cx
        ret

; ---- disque : la disquette A: (fs_s02.inc, FAT12 sur INT 13h) ------------------------
%include "fs_s02.inc"

%include "lib/basic.asm"
