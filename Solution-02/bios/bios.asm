; =============================================================================
; Solution-02 - BIOS 0.5 (VE2CUY, 2026)
; Ordinateur 8088 / NEC V20 autonome : horloge 82C84 (16 MHz / 3 = 5,33 MHz),
; ROM 29C020 (256 Ko), RAM 512 Ko, LCD 20x4 (HD44780 / ST7066U) en ecriture seule.
;
; Carte memoire (schema Solution02.kicad_sch) :
;   00000h-7FFFFh  RAM 512 Ko   (CE# = NAND(/A19, M))
;   80000h-FFFFFh  ROM 256 Ko   (CE# = NAND(A19, M)) - A18 non relie a la ROM :
;                  l'image apparait deux fois (80000h-BFFFFh et C0000h-FFFFFh).
;   Ce BIOS occupe les 64 derniers Ko de la ROM (decalage 30000h) : F000:0000.
;   Reset du 8088 : FFFF:0000 = FFFF0h = F000:FFF0 (decalage 3FFF0h de la ROM).
;
; Ports d'E/S (74LS138 U8 : IO/M = 1, A7 = 0, A6-A4 = bloc) :
;   O0 : 00h-0Fh = LCD. RS = A0 -> port 00h = commande, port 01h = donnee. R/W du
;        LCD a la masse : le drapeau "occupe" ne peut pas etre lu, chaque ecriture
;        est suivie d'un delai.
;   O1 : 10h-13h = 8255 (U7, uPD71055C) : 10h = PA, 11h = PB, 12h = PC, 13h = controle.
;        Mode 0, les 3 ports en sortie (mot de controle 80h) : 24 DEL sur J1-J3.
;   O3 : 30h-33h = 2e 8255 (U12) : mot 82h (PA, PC en sortie, PB en entree).
;        Clavier PS/2 (J4, prise USB-A) : PB0 = horloge, PB1 = donnees.
;        UART logiciel 9600 8N1 (J5) : PA7 = TX, PB2 = RX.
;
; Deroulement :
;   1) ecran d'ouverture (~2 s) ;
;   2) test COMPLET de la RAM (512 Ko), SANS pile ni variables (macros seulement) :
;      a) motifs : chaque bloc de 1 Ko est rempli puis relu avec 55AAh, AA55h,
;         0000h et FFFFh (chaque octet voit AAh, 55h, 00h et FFh, comme le test de
;         Solution-01) ; progression et nombre de Ko defectueux en ligne 2, detail
;         du PREMIER defaut en ligne 4 ("ERR aaaaa ee/ll" : adresse, attendu, lu) ;
;      b) lignes d'adresse A0-A18 (methode de Solution-01) : 5Ah a l'adresse de
;         base B = 35555h, puis k+1 a B xor 2^k ; une ligne coupee ou en court-
;         circuit fait tomber deux adresses sur la meme case (ligne 3) ;
;   3) RAM bonne : effacement a 0, PILE en 7000:0000 (premier PUSH en 7FFFEh, haut
;      de la RAM), verifiee par PUSH/POP ; la boucle finale utilise CALL/RET
;      (ligne 4 : "PILE 7000:0000  OK").
;      RAM defectueuse : pas de pile, ligne 1 "RAM DEFAUT  CPT nnnn".
;   4) RAM bonne : 9 animations en boucle sur les 24 DEL du 8255, disposees de
;      gauche a droite PC7..PC0, PA7..PA0, PB7..PB0 ; ligne 2 = nom de
;      l'animation + nombre de cycles.
;   5) Pendant les attentes des animations, scrutation du clavier PS/2 et de l'UART :
;      touche -> LCD ligne 3 + UART ; octet recu de l'UART -> LCD ligne 4 + echo.
;
; Construire : nasm -f bin -o build/solution-02-bios.bin bios.asm  (image 256 Ko)
; =============================================================================

        bits    16
        cpu     8086

LCD_CMD         equ     00h             ; RS = 0
LCD_DATA        equ     01h             ; RS = 1
LCD_COLS        equ     20
; adresses DDRAM du debut de chaque ligne d'un 20x4
LIGNE1          equ     00h
LIGNE2          equ     40h
LIGNE3          equ     14h
LIGNE4          equ     54h

PILE_SEG        equ     7000h           ; pile en haut de la RAM : 7000:0000,
PILE_SP         equ     0000h           ; premier PUSH en 7000:FFFE = 7FFFEh

TA_BASE         equ     35555h          ; base du test des lignes d'adresse

PPI_PA          equ     10h             ; 8255 (U7) sur O1 du 74LS138
PPI_PB          equ     11h
PPI_PC          equ     12h
PPI_CTRL        equ     13h
PPI_MODE0_SORTIES equ   80h             ; mode 0, PA, PB et PC en sortie

; 2e 8255 (U12) sur O3 du 74LS138 : clavier PS/2 et UART logiciel (bit-bang)
PPI2_PA         equ     30h             ; PA7 = UART TX (sortie)
PPI2_PB         equ     31h             ; PB0 = horloge clavier, PB1 = donnees, PB2 = UART RX
PPI2_PC         equ     32h
PPI2_CTRL       equ     33h
PPI2_MODE       equ     82h             ; mode 0 : PA et PC en sortie, PB en entree
KBD_CLK         equ     01h             ; PB0
KBD_DATA        equ     02h             ; PB1
UART_RX         equ     04h             ; PB2
UART_TX         equ     80h             ; PA7

; UART 9600 8N1 : iterations de LOOP par bit, A CALIBRER a l'oscilloscope (bit = 104,2 us).
; Estimation pour un 8088 a 5,33 MHz : ~70 cycles fixes + 17 par iteration = 555 cycles.
; Bit trop long -> diminuer ; trop court -> augmenter (1 unite = 3,2 us = 3 % d'un bit).
%ifndef UART_N
UART_N          equ     29
%endif
PS2_DELAI       equ     150             ; attentes PS/2 : ~1 ms (boucle de ~36 cycles)

; codes produits par les fleches (hors ASCII, ne pas confondre avec Ctrl+lettre)
TOUCHE_HAUT     equ     80h             ; ordre = ESC [ A, B, C, D
TOUCHE_BAS      equ     81h
TOUCHE_DROITE   equ     82h
TOUCHE_GAUCHE   equ     83h

; variables en RAM, au bas du segment de pile (SS = 7000h ; la pile descend de 7000:FFFE)
V_CLAVIER       equ     0               ; etat du clavier (CLV_*)
V_COL3          equ     1               ; colonne de la ligne 3 (clavier)
V_COL4          equ     2               ; colonne de la ligne 4 (UART)
CLV_RELACHE     equ     01h             ; F0 recu
CLV_ETENDU      equ     02h             ; E0 recu
CLV_MAJ         equ     04h
CLV_CTRL        equ     08h
CLV_VERR_MAJ    equ     10h

; vitesse des animations : tours de la boucle de scrutation de del_aff par pas
; (~45 cycles = ~8,4 us chacun sur un 8088 a 5,33 MHz)
VIT_RAPIDE      equ     4600            ; ~40 ms
VIT_NORMAL      equ     7700            ; ~65 ms
VIT_LENTE       equ     19000           ; ~160 ms

; -----------------------------------------------------------------------------
; DELAY n : boucle de n iterations de LOOP (n = 0 -> 65536). Une iteration dure
; 17 cycles sur un 8088 et ~13 sur un V20 : >= 0,8 us jusqu'a 16 MHz. Les delais
; ci-dessous comptent 1 us par iteration (marge >= 2x a 5,33 MHz). Detruit CX.
; -----------------------------------------------------------------------------
%macro DELAY 1
        mov     cx, %1
%%b:    loop    %%b
%endmacro

; PAUSE n : n x DELAY 0 (~0,2 s chacun sur un 8088 a 5,33 MHz). Detruit CX, DX.
%macro PAUSE 1
        mov     dx, %1
%%p:    DELAY   0
        dec     dx
        jnz     %%p
%endmacro

; commande au LCD (37 us pour les commandes ordinaires -> 60 iterations)
%macro LCD_COMMANDE 1
        mov     al, %1
        out     LCD_CMD, al
        DELAY   60
%endmacro

; caractere AL au LCD (37 us + 4 us)
%macro LCD_CAR 0
        out     LCD_DATA, al
        DELAY   60
%endmacro

; caractere immediat
%macro LCD_CHR 1
        mov     al, %1
        LCD_CAR
%endmacro

; chiffre hexadecimal du quartet bas de AL -> LCD (detruit AL, CX)
%macro LCD_HEXQ 0
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     %%ok
        add     al, 'A' - '9' - 1
%%ok:   LCD_CAR
%endmacro

; octet %1 (registre 8 bits, ni AL ni CL/CH) en 2 chiffres hexadecimaux
%macro LCD_HEX8 1
        mov     al, %1
        mov     cl, 4
        shr     al, cl
        LCD_HEXQ
        mov     al, %1
        LCD_HEXQ
%endmacro

; octet %1 (0-99, ni AH ni BL/BH ni CX) en 2 chiffres decimaux (detruit AX, BX, CX)
%macro LCD_DEC2 1
        mov     al, %1
        xor     ah, ah
        mov     bl, 10
        div     bl
        mov     bh, ah
        add     al, '0'
        LCD_CAR
        mov     al, bh
        add     al, '0'
        LCD_CAR
%endmacro

; mot %1 (0-999, ni AX ni BX ni CX) en 3 chiffres decimaux (detruit AX, BX, CX)
%macro LCD_DEC3 1
        mov     ax, %1
        mov     bl, 100
        div     bl
        mov     bh, ah
        add     al, '0'
        LCD_CAR
        LCD_DEC2 bh
%endmacro

; %2 caracteres du texte %1 (en ROM, DS = CS) a la position courante
; (detruit AL, BX, CX, SI)
%macro LCD_TEXTE 2
        mov     si, %1
        mov     bx, %2
%%c:    lodsb
        LCD_CAR
        dec     bx
        jnz     %%c
%endmacro

; ligne complete : %1 = adresse DDRAM, %2 = texte de 20 caracteres en ROM
; (detruit AL, BX, CX, SI)
%macro LCD_LIGNE 2
        LCD_COMMANDE (80h | %1)
        LCD_TEXTE %2, LCD_COLS
%endmacro

; =============================================================================
; Image de 256 Ko : 192 Ko vides (FFh) puis le segment F000h
; =============================================================================
        section vide start=0
        times   30000h db 0FFh

        section bios start=30000h vstart=0

debut:
        cli
        cld
        mov     ax, cs
        mov     ds, ax                  ; textes en ROM (DS = CS = F000h)

; ---- 2e 8255 (U12) en premier : TX de l'UART au repos (1) le plus tot possible ----
        mov     al, PPI2_MODE           ; PA et PC en sortie, PB en entree
        out     PPI2_CTRL, al
        mov     al, UART_TX             ; PA7 = 1 (repos)
        out     PPI2_PA, al

; ---- initialisation du LCD (mode 8 bits, sequence "par instructions") -------
        DELAY   0                       ; > 40 ms apres la mise sous tension
        DELAY   0
        LCD_COMMANDE 38h                ; function set : 8 bits
        DELAY   5000                    ; > 4,1 ms
        LCD_COMMANDE 38h
        DELAY   200                     ; > 100 us
        LCD_COMMANDE 38h
        LCD_COMMANDE 38h                ; 8 bits, 2 lignes logiques (= 4 lignes), 5x8
        LCD_COMMANDE 08h                ; afficheur eteint
        LCD_COMMANDE 01h                ; effacer
        DELAY   3000                    ; > 1,52 ms
        LCD_COMMANDE 06h                ; increment, sans decalage
        LCD_COMMANDE 0Ch                ; afficheur allume, sans curseur

; ---- 8255 : les 3 ports en sortie, DEL eteintes (sans effet si U7 est absent) ----
        mov     al, PPI_MODE0_SORTIES
        out     PPI_CTRL, al
        xor     al, al
        out     PPI_PA, al
        out     PPI_PB, al
        out     PPI_PC, al

%ifdef DIAG_8255
; ---- ROM de diagnostic du 8255 (make diag) : ecritures en RAFALE continue -------
; CS# (U7 broche 6 = U8 broche 14) et WR# (U7 broche 36) pulsent sans arret (des
; centaines de kHz), faciles a voir a l'oscilloscope ou a la sonde logique. Le motif
; s'inverse ~ toutes les 0,3 s (DEL qui clignotent) : PA = n, PB = NOT n, PC = n.
; Le mot de controle est renvoye a chaque inversion. Sans RAM ni pile.
        LCD_LIGNE LIGNE1, txt_diag1
        LCD_LIGNE LIGNE2, txt_diag2
        LCD_LIGNE LIGNE3, txt_diag3
        mov     bl, 55h
diag_motif:
        mov     bh, bl
        not     bh
        LCD_COMMANDE (80h | LIGNE4)     ; "PA=55 PB=AA PC=55"
        LCD_CHR 'P'
        LCD_CHR 'A'
        LCD_CHR '='
        LCD_HEX8 bl
        LCD_CHR ' '
        LCD_CHR 'P'
        LCD_CHR 'B'
        LCD_CHR '='
        LCD_HEX8 bh
        LCD_CHR ' '
        LCD_CHR 'P'
        LCD_CHR 'C'
        LCD_CHR '='
        LCD_HEX8 bl
        mov     al, PPI_MODE0_SORTIES
        out     PPI_CTRL, al
        mov     dx, 20000
diag_rafale:
        mov     al, bl
        out     PPI_PA, al
        mov     al, bh
        out     PPI_PB, al
        mov     al, bl
        out     PPI_PC, al
        dec     dx
        jnz     diag_rafale
        not     bl
        jmp     diag_motif
%endif

; ---- 1) ecran d'ouverture ------------------------------------------------------
        LCD_LIGNE LIGNE1, txt_ouv1
        LCD_LIGNE LIGNE2, txt_ouv2
        LCD_LIGNE LIGNE3, txt_ouv3
        LCD_LIGNE LIGNE4, txt_ouv4
        PAUSE   10                      ; ~2 s

; ---- 2) ecran du test de la RAM --------------------------------------------------
        LCD_COMMANDE 01h                ; effacer
        DELAY   3000
        LCD_LIGNE LIGNE1, txt_test1
        LCD_LIGNE LIGNE2, txt_test2

; ---- 2a) motifs, bloc par bloc (1 Ko = 512 mots) ---------------------------------
; ES = segment du bloc (pas de 40h), BP = Ko testes, DX = Ko defectueux.
        xor     ax, ax
        mov     es, ax
        xor     bp, bp
        xor     dx, dx
ram_bloc:
        mov     si, motifs
ram_motif:
        mov     ax, [si]
        xor     di, di
        mov     cx, 512
        rep     stosw                   ; remplit le bloc
        xor     di, di
        mov     cx, 512
        repe    scasw                   ; relit et compare
        je      ram_motif_ok
        jmp     ram_defaut
ram_motif_ok:
        add     si, 2
        cmp     si, motifs + 8
        jb      ram_motif
ram_bloc_suivant:
        inc     bp
        LCD_COMMANDE (80h | (LIGNE2 + 4))
        LCD_DEC3 bp                     ; Ko testes
        LCD_COMMANDE (80h | (LIGNE2 + 17))
        LCD_DEC3 dx                     ; Ko defectueux
        mov     ax, es
        add     ax, 40h                 ; bloc suivant
        mov     es, ax
        cmp     ax, 8000h               ; 512 Ko testes ?
        jae     ram_adresses
        jmp     ram_bloc

; defaut dans le bloc : le mot fautif est en ES:DI-2, AX = motif attendu.
; Seul le PREMIER defaut est detaille (ligne 4) ; les suivants sont comptes.
ram_defaut:
        or      dx, dx
        jnz     ram_defaut_compte
        sub     di, 2
        mov     bx, [es:di]             ; mot lu
        cmp     bl, al
        jne     .octet                  ; octet bas fautif
        inc     di                      ; sinon octet haut
        mov     bl, bh
        mov     al, ah
.octet: mov     bh, al                  ; BH = attendu, BL = lu
        mov     ax, es
        mov     cl, 4
        mov     si, ax
        shl     si, cl
        add     si, di                  ; SI = 16 bits bas de l'adresse (sans retenue :
                                        ; ES multiple de 40h et DI <= 3FFh)
        mov     cl, 12
        shr     ax, cl
        mov     di, ax                  ; DI = bits 19-16
        LCD_COMMANDE (80h | LIGNE4)
        LCD_CHR 'E'
        LCD_CHR 'R'
        LCD_CHR 'R'
        LCD_CHR ' '
        mov     ax, di
        LCD_HEXQ                        ; aaaaa
        mov     ax, si
        LCD_HEX8 ah
        mov     ax, si
        mov     ah, al
        LCD_HEX8 ah
        LCD_CHR ' '
        LCD_HEX8 bh                     ; attendu
        LCD_CHR '/'
        LCD_HEX8 bl                     ; lu
ram_defaut_compte:
        inc     dx
        jmp     ram_bloc_suivant

; ---- 2b) lignes d'adresse A0-A18 ---------------------------------------------
; Ecrit 5Ah a la base, puis k+1 a base xor 2^k (k = 0..18), et relit. BP = 0 si OK.
ram_adresses:
        mov     si, ta_table
        xor     bl, bl                  ; BL = indice (0 = base)
ta_ecrit:
        mov     di, [si]
        mov     es, [si + 2]
        mov     al, bl
        or      al, al
        jnz     .valeur
        mov     al, 5Ah
.valeur:
        mov     [es:di], al
        inc     bl
        add     si, 4
        cmp     si, ta_fin
        jb      ta_ecrit

        LCD_COMMANDE (80h | LIGNE3)
        xor     bp, bp
        mov     si, ta_table
        mov     di, [si]
        mov     es, [si + 2]
        mov     al, [es:di]
        cmp     al, 5Ah
        je      ta_lignes
        ; la base a ete ecrasee : la valeur lue (k+1) nomme la ligne k
        dec     al
        cmp     al, 19
        jb      ta_err_ligne
        LCD_TEXTE txt_adr_base, LCD_COLS
        inc     bp
        jmp     ram_bilan
ta_lignes:
        mov     bl, 1
ta_relit:
        add     si, 4
        mov     di, [si]
        mov     es, [si + 2]
        mov     al, [es:di]
        cmp     al, bl
        jne     ta_err_indice
        inc     bl
        cmp     bl, 20
        jb      ta_relit
        LCD_TEXTE txt_adr_ok, LCD_COLS
        jmp     ram_bilan
ta_err_indice:
        mov     al, bl
        dec     al                      ; indice k+1 -> ligne k
ta_err_ligne:                           ; AL = numero de la ligne (0-18)
        xor     ah, ah
        mov     di, ax                  ; DI = ligne (DX garde le nombre de Ko defectueux)
        LCD_TEXTE txt_adr_err, 15       ; "Adresses: ERR A"
        mov     ax, di
        LCD_DEC2 al                     ; numero de la ligne
        LCD_CHR ' '
        LCD_CHR ' '
        LCD_CHR ' '
        inc     bp

; ---- bilan ------------------------------------------------------------------------
ram_bilan:
        or      dx, dx
        jnz     echec
        or      bp, bp
        jnz     echec

; ---- 3) RAM bonne : effacement, pile, boucle avec CALL ---------------------------
        LCD_LIGNE LIGNE1, txt_ram_ok
        xor     bx, bx                  ; efface les 8 segments de 64 Ko
efface:
        mov     es, bx
        xor     di, di
        xor     ax, ax
        mov     cx, 8000h
        rep     stosw
        add     bx, 1000h
        cmp     bx, 8000h
        jb      efface

        mov     ax, PILE_SEG
        mov     ss, ax                  ; (MOV SS bloque les interruptions pour
        mov     sp, PILE_SP             ;  l'instruction suivante)
        mov     ax, 0A55Ah              ; verification de la pile
        mov     bx, 05AA5h
        push    ax
        push    bx
        pop     cx
        pop     dx
        cmp     cx, bx
        jne     pile_err
        cmp     dx, ax
        jne     pile_err

        ; a partir d'ici, les routines LCD sont des sous-programmes (CALL/RET)
        mov     al, 80h | LIGNE4
        call    lcd_cmd
        mov     si, txt_pile_ok
        call    lcd_texte20
        mov     si, txt_uart_banniere   ; banniere sur l'UART (9600 8N1)
        call    uart_texte
        PAUSE   15                      ; resultat du test visible ~3 s

; ---- 4) animations des DEL (8255 U7) + terminal clavier / UART (8255 U12) ---------
; Le clavier et l'UART sont scrutes pendant les attentes des animations (del_aff).
        mov     al, 01h                 ; effacer
        call    lcd_cmd
        DELAY   3000
        mov     al, 80h | LIGNE1
        call    lcd_cmd
        mov     si, txt_del1
        call    lcd_texte20
        mov     al, 80h | LIGNE3
        call    lcd_cmd
        mov     si, txt_term3
        call    lcd_texte20
        mov     al, 80h | LIGNE4
        call    lcd_cmd
        mov     si, txt_term4
        call    lcd_texte20
        mov     byte [ss:V_COL3], LCD_COLS   ; le premier caractere efface l'invite
        mov     byte [ss:V_COL4], LCD_COLS
        xor     bp, bp                  ; BP = cycles complets (aucune animation n'y touche)
anim_cycle:
        mov     si, anim_table
anim_suivante:
        push    si
        mov     al, 80h | LIGNE2        ; "<nom de l'animation>  nnnn"
        call    lcd_cmd
        mov     si, [si]
        mov     bx, 16
        call    lcd_texte
        mov     ax, bp
        mov     al, ah
        call    lcd_hex8
        mov     ax, bp
        call    lcd_hex8
        pop     si
        push    si
        call    [si + 2]                ; l'animation (detruit AX, BX, CX, DX, SI, DI)
        pop     si
        add     si, 4
        cmp     si, anim_fin
        jb      anim_suivante
        inc     bp
        jmp     anim_cycle

pile_err:
        LCD_LIGNE LIGNE4, txt_pile_err

; ---- RAM defectueuse : pas de pile, compteur en ligne 1 (sans CALL) -------------
echec:
        LCD_LIGNE LIGNE1, txt_echec
        xor     dx, dx
echec_boucle:
        LCD_COMMANDE (80h | (LIGNE1 + 16))
        LCD_HEX8 dh
        LCD_HEX8 dl
        inc     dx
        DELAY   0
        DELAY   0
        jmp     echec_boucle

; =============================================================================
; Sous-programmes LCD (utilisables seulement une fois la pile en place)
; =============================================================================
; lcd_cmd : commande AL. Detruit CX.
lcd_cmd:
        out     LCD_CMD, al
        DELAY   60
        ret

; lcd_car : caractere AL. Detruit CX.
lcd_car:
        out     LCD_DATA, al
        DELAY   60
        ret

; lcd_hex8 : AL en 2 chiffres hexadecimaux. Detruit AX, CX.
lcd_hex8:
        push    ax
        mov     cl, 4
        shr     al, cl
        call    lcd_hexq
        pop     ax
lcd_hexq:                               ; quartet bas de AL
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .ok
        add     al, 'A' - '9' - 1
.ok:    jmp     lcd_car

; lcd_texte20 : 20 caracteres en DS:SI ; lcd_texte : BX caracteres. Detruisent AX, BX, CX, SI.
lcd_texte20:
        mov     bx, LCD_COLS
lcd_texte:
.c:     lodsb
        call    lcd_car
        dec     bx
        jnz     .c
        ret

; =============================================================================
; Animations des 24 DEL. Disposition du montage, de gauche a droite :
;   PC7 ... PC0   PA7 ... PA0   PB7 ... PB0
; Rangee logique de 24 bits DL:BH:BL, bit 23 = DEL la plus a GAUCHE (PC7), bit 0 =
; DEL la plus a DROITE (PB0) : DL = PC, BH = PA, BL = PB. Decaler vers la droite =
; SHR DL / RCR BH / RCR BL.
; DI = duree d'un pas. Chaque animation peut detruire AX, BX, CX, DX, SI, DI,
; mais PAS BP (compteur de cycles).
; =============================================================================
; del_aff : sort DL sur PC, BH sur PA, BL sur PB, puis attend DI iterations. Detruit AL, CX.
del_aff:
        mov     al, dl
        out     PPI_PC, al
        mov     al, bh
        out     PPI_PA, al
        mov     al, bl
        out     PPI_PB, al
        mov     cx, di                  ; attente en scrutant le clavier et l'UART
.w:     in      al, PPI2_PB
        test    al, KBD_CLK
        jz      .clavier                ; CLK bas : debut d'une trame PS/2
        test    al, UART_RX
        jz      .uart                   ; RX bas : bit de depart
.suite: loop    .w
        ret
.clavier:
        call    clavier_entree
        jmp     .suite
.uart:  call    uart_entree
        jmp     .suite

; =============================================================================
; UART logiciel 9600 8N1 sur le 2e 8255 (U12) : TX = PA7, RX = PB2 (tirage R4).
; Duree d'un bit = 7 + 17 x UART_N cycles environ par tour de boucle (voir
; uart_tx) : a regler a l'oscilloscope (bit = 104,2 us a 9600 bauds ; 1 unite de
; UART_N = 17 cycles = 3,2 us a 5,33 MHz). Interruptions masquees pendant l'octet.
; =============================================================================
; uart_tx : envoie AL. Preserve tous les registres.
uart_tx:
        push    ax
        push    bx
        push    cx
        push    dx
        pushf
        cli
        xor     ah, ah
        shl     ax, 1                   ; bit 0 = depart (0)
        or      ah, 2                   ; bit 9 = arret (1)
        mov     dx, ax
        mov     bl, 10
.bit:   shr     dx, 1                   ; CF = bit suivant
        sbb     al, al                  ; AL = FFh si 1, 00h si 0
        and     al, UART_TX
        out     PPI2_PA, al
        mov     cx, UART_N
.d:     loop    .d
        dec     bl
        jnz     .bit
        popf
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; uart_texte : envoie la chaine DS:SI terminee par 0. Detruit SI, AL.
uart_texte:
        lodsb
        or      al, al
        jz      .fin
        call    uart_tx
        jmp     uart_texte
.fin:   ret

; uart_rx : RX vient d'etre vu bas (bit de depart). Lit l'octet.
; Sortie : AL = octet, CF = 1 si trame invalide. Preserve les autres registres.
uart_rx:
        push    bx
        push    cx
        mov     cx, UART_N / 2          ; au milieu du bit de depart
.d0:    loop    .d0
        in      al, PPI2_PB
        test    al, UART_RX
        jnz     .err                    ; parasite : plus de bit de depart
        mov     bl, 8
.bit:   mov     cx, UART_N              ; (meme duree par bit que uart_tx)
.d:     loop    .d
        in      al, PPI2_PB
        shr     al, 1
        shr     al, 1
        shr     al, 1                   ; CF = PB2
        rcr     ah, 1
        dec     bl
        jnz     .bit
        mov     cx, UART_N
.d1:    loop    .d1
        in      al, PPI2_PB             ; bit d'arret (doit etre 1)
        test    al, UART_RX
        jz      .err
        mov     al, ah
        clc
        jmp     .fin
.err:   mov     cx, UART_N * 10         ; laisse passer le reste de la trame
.r:     loop    .r
        stc
.fin:   pop     cx
        pop     bx
        ret

; =============================================================================
; Clavier PS/2 (bit-bang, comme Solution-01) sur le 2e 8255 : PB0 = horloge,
; PB1 = donnees (tirages R2/R3). Le clavier fournit l'horloge (10-16,7 kHz) ;
; une donnee est valide pendant que l'horloge est basse. Trame : depart (0),
; 8 donnees (bit 0 d'abord), parite impaire, arret (1).
; =============================================================================
; ps2_trame : CLK vient d'etre vu bas. Sortie : AL = octet, CF = 1 si trame
; invalide (et la ligne est resynchronisee). Preserve les autres registres.
ps2_trame:
        push    bx
        push    cx
        push    dx
        xor     dx, dx
        mov     bl, 11
.bit:   in      al, PPI2_PB             ; CLK bas : echantillonne DATA
        shr     al, 1
        shr     al, 1                   ; CF = PB1 (DATA)
        rcr     dx, 1
        dec     bl
        jz      .fin
        mov     cx, PS2_DELAI           ; attend CLK haut
.h:     in      al, PPI2_PB
        test    al, KBD_CLK
        jnz     .haut
        loop    .h
        jmp     .err
.haut:  mov     cx, PS2_DELAI           ; attend CLK bas (bit suivant)
.b:     in      al, PPI2_PB
        test    al, KBD_CLK
        jz      .bit
        loop    .b
        jmp     .err
.fin:   ; DX : bit 15 = arret, 14 = parite, 13-6 = donnees, 5 = depart
        test    dx, 0020h
        jnz     .err                    ; depart != 0
        test    dx, 8000h
        jz      .err                    ; arret != 1
        mov     cl, 6
        shr     dx, cl                  ; DL = donnees, DH bit 0 = parite
        mov     al, dl
        or      al, al                  ; PF = 1 si nombre PAIR de 1
        jpe     .pair
        test    dh, 1                   ; impair : parite attendue = 0
        jnz     .err
        jmp     .ok
.pair:  test    dh, 1                   ; pair : parite attendue = 1
        jz      .err
.ok:    mov     cx, PS2_DELAI           ; fin du bit d'arret : attend CLK haut
.fin_h: in      al, PPI2_PB             ; (sans plus : l'octet suivant d'un "F0 xx"
        test    al, KBD_CLK             ;  peut suivre de pres)
        jnz     .fin_ok
        loop    .fin_h
.fin_ok:
        mov     al, dl
        clc
        jmp     .sortie
.err:   call    ps2_attend_repos
        stc
.sortie:
        pop     dx
        pop     cx
        pop     bx
        ret

; ps2_attend_repos : apres une trame invalide, attend que CLK reste haut ~1 ms
; (resynchronisation sur le debut d'une trame). Detruit AL, CX.
ps2_attend_repos:
        mov     cx, PS2_DELAI
.r:     in      al, PPI2_PB
        test    al, KBD_CLK
        jz      ps2_attend_repos        ; encore bas : recommence l'attente
        loop    .r
        ret

; clavier_decode : AL = code de touche (jeu 2). Sortie : CF = 0 et AL = caractere
; (ASCII, ou TOUCHE_HAUT..TOUCHE_GAUCHE pour les fleches), CF = 1 si rien a produire
; (prefixe, relachement, Maj/Ctrl/Verr Maj). Etat dans [ss:V_CLAVIER]. Preserve BX.
clavier_decode:
        push    bx
        mov     bl, [ss:V_CLAVIER]
        cmp     al, 0F0h
        jne     .pas_f0
        or      bl, CLV_RELACHE
        jmp     .rien
.pas_f0:
        cmp     al, 0E0h
        jne     .pas_e0
        or      bl, CLV_ETENDU
        jmp     .rien
.pas_e0:
        test    bl, CLV_RELACHE
        jz      .appui
        ; relachement : seuls Maj et Ctrl nous interessent
        and     bl, ~(CLV_RELACHE | CLV_ETENDU)
        cmp     al, 12h                 ; Maj gauche
        je      .maj_off
        cmp     al, 59h                 ; Maj droite
        je      .maj_off
        cmp     al, 14h                 ; Ctrl (gauche ou droite, E0 14)
        jne     .rien
        and     bl, ~CLV_CTRL
        jmp     .rien
.maj_off:
        and     bl, ~CLV_MAJ
        jmp     .rien
.appui: test    bl, CLV_ETENDU
        jz      .normal
        and     bl, ~CLV_ETENDU         ; touches etendues (E0 xx)
        cmp     al, 14h
        je      .ctrl_on
        mov     ah, TOUCHE_HAUT
        cmp     al, 75h
        je      .car
        mov     ah, TOUCHE_BAS
        cmp     al, 72h
        je      .car
        mov     ah, TOUCHE_DROITE
        cmp     al, 74h
        je      .car
        mov     ah, TOUCHE_GAUCHE
        cmp     al, 6Bh
        je      .car
        mov     ah, 13
        cmp     al, 5Ah                 ; Entree du pave
        je      .car
        mov     ah, '/'
        cmp     al, 4Ah                 ; / du pave
        je      .car
        jmp     .rien
.normal:
        cmp     al, 12h
        je      .maj_on
        cmp     al, 59h
        je      .maj_on
        cmp     al, 14h
        je      .ctrl_on
        cmp     al, 58h                 ; Verr Maj : bascule
        jne     .table
        xor     bl, CLV_VERR_MAJ
        jmp     .rien
.maj_on:
        or      bl, CLV_MAJ
        jmp     .rien
.ctrl_on:
        or      bl, CLV_CTRL
        jmp     .rien
.table: cmp     al, CLAVIER_NB_CODES
        jae     .rien
        mov     [ss:V_CLAVIER], bl
        push    bx
        mov     bx, clavier_normal
        test    byte [ss:V_CLAVIER], CLV_MAJ
        jz      .lit
        mov     bx, clavier_maj
.lit:   xlat                            ; AL = [DS:BX + AL] (DS = CS)
        pop     bx
        or      al, al
        jz      .rien
        mov     ah, al                  ; lettres : Verr Maj inverse la casse,
        or      ah, 20h                 ;           Ctrl donne 01h-1Ah
        cmp     ah, 'a'
        jb      .pas_lettre
        cmp     ah, 'z'
        ja      .pas_lettre
        test    bl, CLV_CTRL
        jz      .verr
        and     al, 1Fh
        jmp     .produit
.verr:  test    bl, CLV_VERR_MAJ
        jz      .produit
        xor     al, 20h
.pas_lettre:
.produit:
        mov     [ss:V_CLAVIER], bl
        pop     bx
        clc
        ret
.car:   mov     al, ah
        jmp     .produit
.rien:  mov     [ss:V_CLAVIER], bl
        pop     bx
        stc
        ret

; =============================================================================
; Terminal : clavier -> LCD ligne 3 + UART ; UART -> LCD ligne 4 + echo sur l'UART.
; Appeles depuis del_aff (pendant les animations) : preservent tous les registres
; sauf AL.
; =============================================================================
clavier_entree:
        push    ax                      ; (AH sert de compteur aux animations)
        push    cx
        call    ps2_trame
        jc      .fin
        call    clavier_decode
        jc      .fin
        cmp     al, TOUCHE_HAUT         ; fleches : sequence ANSI ESC [ A..D sur l'UART
        jb      .car
        cmp     al, TOUCHE_GAUCHE
        ja      .car
        push    ax
        mov     al, 27
        call    uart_tx
        mov     al, '['
        call    uart_tx
        pop     ax
        add     al, 'A' - TOUCHE_HAUT
        call    uart_tx
        jmp     .fin
.car:   call    uart_envoie_car         ; vers le PC
        push    bx
        mov     bx, V_COL3
        mov     ah, LIGNE3
        call    ecran_car               ; et sur le LCD
        pop     bx
.fin:   pop     cx
        pop     ax
        ret

uart_entree:
        push    ax
        push    cx
        call    uart_rx
        jc      .fin
        call    uart_envoie_car         ; echo
        push    bx
        mov     bx, V_COL4
        mov     ah, LIGNE4
        call    ecran_car
        pop     bx
.fin:   pop     cx
        pop     ax
        ret

; uart_envoie_car : AL vers l'UART ; CR -> CR LF, retour arriere -> BS espace BS.
; Preserve tout.
uart_envoie_car:
        call    uart_tx
        cmp     al, 13
        jne     .bs
        push    ax
        mov     al, 10
        call    uart_tx
        pop     ax
        ret
.bs:    cmp     al, 8
        jne     .fin
        push    ax
        mov     al, ' '
        call    uart_tx
        mov     al, 8
        call    uart_tx
        pop     ax
.fin:   ret

; ecran_car : affiche AL sur la ligne de debut DDRAM AH, colonne dans [ss:BX].
; Imprimable : ecrit (ligne effacee quand elle est pleine) ; CR : efface la ligne ;
; retour arriere : recule d'une colonne. Autres codes ignores. Preserve tout sauf AL.
ecran_car:
        push    ax
        push    cx
        push    dx
        mov     dx, ax                  ; DL = caractere, DH = debut de ligne
        cmp     dl, 13
        je      .efface
        cmp     dl, 8
        je      .recule
        cmp     dl, ' '
        jb      .fin
        cmp     dl, 7Eh
        ja      .fin
        cmp     byte [ss:bx], LCD_COLS
        jb      .ecrit
        call    .vide                   ; ligne pleine : on repart a gauche
.ecrit: mov     al, [ss:bx]
        add     al, dh
        or      al, 80h
        call    lcd_cmd
        mov     al, dl
        call    lcd_car
        inc     byte [ss:bx]
        jmp     .fin
.recule:
        cmp     byte [ss:bx], 0
        je      .fin
        cmp     byte [ss:bx], LCD_COLS
        ja      .fin
        dec     byte [ss:bx]
        mov     al, [ss:bx]
        add     al, dh
        or      al, 80h
        call    lcd_cmd
        mov     al, ' '
        call    lcd_car
        jmp     .fin
.efface:
        call    .vide
.fin:   pop     dx
        pop     cx
        pop     ax
        ret
.vide:  push    dx                      ; 20 espaces, puis colonne 0
        mov     al, dh
        or      al, 80h
        call    lcd_cmd
        mov     dl, LCD_COLS
.v:     mov     al, ' '
        call    lcd_car
        dec     dl
        jnz     .v
        mov     byte [ss:bx], 0
        pop     dx
        ret

; bit24 : allume la DEL numero CL (0 = PB0 a droite ... 23 = PC7 a gauche). Detruit AL, CL.
bit24:
        mov     al, 1
        cmp     cl, 8
        jb      .pa
        cmp     cl, 16
        jb      .pb
        sub     cl, 16
        shl     al, cl
        or      dl, al
        ret
.pb:    sub     cl, 8
        shl     al, cl
        or      bh, al
        ret
.pa:    shl     al, cl
        or      bl, al
        ret

; alea : registre a decalage (LFSR de Galois, 16 bits, polynome B400h) dans SI,
; avance de 8 pas. Sortie : AX = SI. Preserve CX.
alea:
        push    cx
        mov     cx, 8
.b:     shr     si, 1
        jnc     .s
        xor     si, 0B400h
.s:     loop    .b
        mov     ax, si
        pop     cx
        ret

; 1) chenillard : une DEL parcourt la rangee de gauche a droite (2 tours)
anim_chenillard:
        mov     di, VIT_RAPIDE
        mov     ah, 2
.tour:  xor     bx, bx
        mov     dl, 80h                 ; PC7, a gauche
        mov     si, 24
.pas:   call    del_aff
        shr     dl, 1
        rcr     bh, 1
        rcr     bl, 1
        dec     si
        jnz     .pas
        dec     ah
        jnz     .tour
        ret

; 2) balayage : 3 DEL font l'aller-retour, de gauche a droite puis retour (3 fois)
anim_balayage:
        mov     di, VIT_RAPIDE
        mov     ah, 3
.tour:  xor     bx, bx
        mov     dl, 0E0h                ; PC7-PC5, a gauche
        mov     si, 21
.aller: call    del_aff
        shr     dl, 1
        rcr     bh, 1
        rcr     bl, 1
        dec     si
        jnz     .aller
        mov     si, 21
.retour:
        call    del_aff
        shl     bl, 1
        rcl     bh, 1
        rcl     dl, 1
        dec     si
        jnz     .retour
        dec     ah
        jnz     .tour
        ret

; 3) remplissage : la rangee se remplit de gauche a droite, puis se vide dans le meme sens (2 fois)
anim_remplissage:
        mov     di, VIT_NORMAL
        mov     ah, 2
.tour:  xor     bx, bx
        xor     dl, dl
        mov     si, 24
.remplit:
        stc
        rcr     dl, 1
        rcr     bh, 1
        rcr     bl, 1
        call    del_aff
        dec     si
        jnz     .remplit
        mov     si, 24
.vide:  clc
        rcr     dl, 1
        rcr     bh, 1
        rcr     bl, 1
        call    del_aff
        dec     si
        jnz     .vide
        dec     ah
        jnz     .tour
        ret

; 4) explosion : 2 DEL partent du centre (11-12) vers les bouts, puis reviennent (2 fois)
anim_explosion:
        mov     di, VIT_NORMAL
        mov     ah, 2
.tour:  xor     si, si                  ; SI = distance au centre
.sort:  call    .paire
        inc     si
        cmp     si, 12
        jb      .sort
        mov     si, 10
.rentre:
        call    .paire
        dec     si
        jns     .rentre
        dec     ah
        jnz     .tour
        ret
.paire:                                 ; DEL 11-SI et 12+SI, puis un pas
        xor     bx, bx
        xor     dl, dl
        mov     cx, 11
        sub     cx, si
        call    bit24
        mov     cx, 12
        add     cx, si
        call    bit24
        jmp     del_aff

; 5) alternance : damier de DEL qui s'inverse (10 pas lents)
anim_alternance:
        mov     di, VIT_LENTE
        mov     ah, 10
        mov     bx, 55AAh
        mov     dl, 0AAh
.pas:   call    del_aff
        not     bx
        not     dl
        dec     ah
        jnz     .pas
        ret

; 6) compteur : PB (a droite) = binaire, PA (au centre) = code de Gray du meme
;    nombre, PC (a gauche) = binaire / 8 ; bit de poids faible a droite de chaque port
anim_compteur:
        mov     di, VIT_RAPIDE
        xor     si, si
.pas:   mov     ax, si
        mov     bl, al                  ; PA = n
        mov     bh, al
        shr     bh, 1
        xor     bh, al                  ; PB = n xor (n >> 1)
        mov     cl, 3
        shr     al, cl
        mov     dl, al                  ; PC = n / 8
        call    del_aff
        inc     si
        cmp     si, 128
        jb      .pas
        ret

; 7) ports : PC, PA puis PB (de gauche a droite) allumes a tour de role (3 fois),
;    puis tout clignote (4 fois)
anim_ports:
        mov     di, VIT_LENTE
        mov     ah, 3
.tour:  xor     bx, bx
        mov     dl, 0FFh                ; PC (gauche)
        call    del_aff
        mov     bx, 0FF00h              ; PA (centre)
        xor     dl, dl
        call    del_aff
        mov     bx, 00FFh               ; PB (droite)
        call    del_aff
        dec     ah
        jnz     .tour
        mov     ah, 4
.flash: mov     bx, 0FFFFh
        mov     dl, 0FFh
        call    del_aff
        xor     bx, bx
        xor     dl, dl
        call    del_aff
        dec     ah
        jnz     .flash
        ret

; 8) etincelles : DEL allumees au hasard (~1 sur 4), 60 pas
anim_etincelles:
        mov     di, VIT_RAPIDE
        mov     si, 0ACE1h              ; graine du LFSR
        mov     dh, 60
.pas:   call    alea
        mov     bx, ax
        call    alea
        and     bx, ax                  ; ET de deux tirages : ~25 % de DEL allumees
        call    alea
        mov     dl, al
        call    alea
        and     dl, ah
        call    del_aff
        dec     dh
        jnz     .pas
        ret

; 9) vu-metre : une barre partie de la gauche (0 a 24 DEL) monte ou descend d'une
;    DEL par pas vers un niveau cible aleatoire, puis vise un nouveau niveau (120 pas)
;    CL = niveau, CH = cible, AH = pas restants, SI = LFSR.
anim_vumetre:
        mov     di, VIT_RAPIDE
        mov     si, 1234h               ; graine du LFSR
        mov     ah, 120
        xor     cx, cx
.pas:   cmp     cl, ch
        jne     .bouge
        push    ax                      ; cible atteinte : nouvelle cible 0-24
        call    alea
        xor     ah, ah
        mov     bl, 25
        div     bl
        mov     ch, ah
        pop     ax
        jmp     .pas
.bouge: jb      .monte
        dec     cl
        jmp     .dessine
.monte: inc     cl
.dessine:
        xor     bx, bx                  ; barre de CL DEL depuis la gauche
        xor     dl, dl
        mov     al, cl
        or      al, al
        jz      .aff
.b:     stc
        rcr     dl, 1
        rcr     bh, 1
        rcr     bl, 1
        dec     al
        jnz     .b
.aff:   push    cx
        call    del_aff
        pop     cx
        dec     ah
        jnz     .pas
        ret

; =============================================================================
; Donnees (en ROM, DS = CS)
; =============================================================================
;                12345678901234567890
txt_ouv1:   db  'SOLUTION-02 BIOS 0.5'
txt_ouv2:   db  'CPU 8088/V20 5.33MHz'
txt_ouv3:   db  'RAM 512 Ko  LCD 20x4'
txt_ouv4:   db  'VE2CUY - 2026       '
txt_test1:  db  'TEST MEMOIRE 512 Ko '
txt_test2:  db  'Ko: 000  Defauts 000'
txt_adr_ok: db  'Adresses A0-A18: OK '
txt_adr_err:db  'Adresses: ERR A'
txt_adr_base:db 'Adresses: ERR base  '
txt_ram_ok: db  'MEMOIRE 512 Ko : OK '
txt_echec:  db  'RAM DEFAUT  CPT 0000'
txt_pile_ok:db  'PILE 7000:0000  OK  '
txt_pile_err:db 'PILE ERR            '
txt_del1:   db  'SOLUTION-02 BIOS 0.5'
txt_term3:  db  'Clavier PS/2 >      '
txt_term4:  db  'UART 9600 8N1 >     '
txt_uart_banniere:
            db  13, 10, 'Solution-02 BIOS 0.5 - VE2CUY 2026', 13, 10
            db  'RAM 512 Ko : OK, pile 7000:0000', 13, 10
            db  'Clavier PS/2 (LCD ligne 3) et UART 9600 8N1 (LCD ligne 4, echo)', 13, 10, 0
%ifdef DIAG_8255
txt_diag1:  db  'DIAG 8255  10h-13h  '
txt_diag2:  db  'Rafale: CS# et WR#  '
txt_diag3:  db  'U7 br. 6 et 36      '
%endif

; animations : (nom de 16 caracteres, routine)
anim_table:
            dw  txt_a1, anim_chenillard
            dw  txt_a2, anim_balayage
            dw  txt_a3, anim_remplissage
            dw  txt_a4, anim_explosion
            dw  txt_a5, anim_alternance
            dw  txt_a6, anim_compteur
            dw  txt_a7, anim_ports
            dw  txt_a8, anim_etincelles
            dw  txt_a9, anim_vumetre
anim_fin:
;                1234567890123456
txt_a1:     db  'Chenillard      '
txt_a2:     db  'Balayage        '
txt_a3:     db  'Remplissage     '
txt_a4:     db  'Explosion       '
txt_a5:     db  'Alternance      '
txt_a6:     db  'Compteur/Gray   '
txt_a7:     db  'Ports C A B     '
txt_a8:     db  'Etincelles      '
txt_a9:     db  'Vu-metre        '

%include "clavier_us.inc"

motifs:     dw  55AAh, 0AA55h, 0000h, 0FFFFh

; test des lignes d'adresse : base, puis base xor 2^k (k = 0..18), en (deplacement, segment)
ta_table:
            dw  TA_BASE & 0Fh, TA_BASE >> 4
%assign k 0
%rep 19
            dw  (TA_BASE ^ (1 << k)) & 0Fh, (TA_BASE ^ (1 << k)) >> 4
  %assign k k + 1
%endrep
ta_fin:

; =============================================================================
; Vecteur de reset en F000:FFF0
; =============================================================================
        times   0FFF0h - ($ - $$) db 0FFh
reset:
        jmp     0F000h:debut
        db      '13/11/26'              ; F000:FFF5 date
        db      0FFh
        db      0FEh                    ; F000:FFFE modele (PC/XT)
        db      0FFh
