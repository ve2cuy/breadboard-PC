; =============================================================================
; Solution-02 - BIOS 0.2 (VE2CUY, 2026)
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
; Ports d'E/S (74LS138 U8 : IO/M = 1, A7 = 0, A6-A4 = 000) : 00h-0Fh = LCD
;   RS = A0 -> port 00h = commande, port 01h = donnee. R/W du LCD a la masse :
;   le drapeau "occupe" ne peut pas etre lu, chaque ecriture est suivie d'un delai.
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
;      (ligne 4 : "PILE OK     CPT nnnn").
;      RAM defectueuse : pas de pile, ligne 1 "RAM DEFAUT  CPT nnnn".
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
        xor     dx, dx
boucle:
        mov     al, 80h | (LIGNE4 + 16)
        call    lcd_cmd
        mov     al, dh
        call    lcd_hex8
        mov     al, dl
        call    lcd_hex8
        inc     dx
        DELAY   0                       ; ~0,4 s par increment a 5,33 MHz (8088)
        DELAY   0
        jmp     boucle

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

; lcd_texte20 : 20 caracteres en DS:SI. Detruit AX, BX, CX, SI.
lcd_texte20:
        mov     bx, LCD_COLS
.c:     lodsb
        call    lcd_car
        dec     bx
        jnz     .c
        ret

; =============================================================================
; Donnees (en ROM, DS = CS)
; =============================================================================
;                12345678901234567890
txt_ouv1:   db  'SOLUTION-02 BIOS 0.2'
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
txt_pile_ok:db  'PILE OK     CPT 0000'
txt_pile_err:db 'PILE ERR            '

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
