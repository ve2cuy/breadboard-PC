; =============================================================================
; Solution-02 - BIOS 0.1 (VE2CUY, 2026)
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
; Le code n'utilise PAS la RAM (ni pile, ni variables) : l'affichage fonctionne
; meme si la RAM est absente ou mal cablee ; la ligne 3 donne le resultat du test.
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

; -----------------------------------------------------------------------------
; DELAY n : boucle de n iterations de LOOP (n = 0 -> 65536). Une iteration dure
; 17 cycles sur un 8088 et ~13 sur un V20 : >= 0,8 us jusqu'a 16 MHz. Les delais
; ci-dessous comptent 1 us par iteration (marge >= 2x a 5,33 MHz). Detruit CX.
; -----------------------------------------------------------------------------
%macro DELAY 1
        mov     cx, %1
%%b:    loop    %%b
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

; ligne complete : %1 = adresse DDRAM, %2 = texte de 20 caracteres en ROM
; (detruit AL, BX, CX, SI)
%macro LCD_LIGNE 2
        LCD_COMMANDE (80h | %1)
        mov     si, %2
        mov     bx, LCD_COLS
%%c:    lodsb
        LCD_CAR
        dec     bx
        jnz     %%c
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

        LCD_LIGNE LIGNE1, txt_l1
        LCD_LIGNE LIGNE2, txt_l2

; ---- test rapide de la RAM (sans pile) ---------------------------------------
; A) cellules : premier et dernier octet de chaque bloc de 1 Ko, motifs 55h, AAh,
;    00h, FFh. B) lignes d'adresse A0-A18 : une valeur distincte a 0 et a chaque
;    adresse 2^n, puis relecture (detecte RAM absente, lignes coupees ou en court-
;    circuit). En cas d'erreur : ES:DI = adresse, BH = attendu, AL = lu.
        xor     ax, ax
        mov     es, ax
ram_bloc:
        xor     di, di
ram_cellule:
        mov     si, motifs
ram_motif:
        mov     bh, [si]
        mov     [es:di], bh
        mov     al, [es:di]
        cmp     al, bh
        jne     ram_erreur
        inc     si
        cmp     si, motifs + 4
        jb      ram_motif
        cmp     di, 3FFh
        je      ram_suivant
        mov     di, 3FFh
        jmp     ram_cellule
ram_suivant:
        mov     ax, es
        add     ax, 40h                 ; bloc suivant (1 Ko)
        mov     es, ax
        cmp     ax, 8000h               ; 512 Ko testes ?
        jb      ram_bloc

        ; B) lignes d'adresse : [0] = 0, [2^n] = n + 1
        xor     ax, ax
        mov     es, ax
        mov     byte [es:0], 0
        mov     si, adresses
        mov     bl, 1
ram_ecrit:
        mov     di, [si]
        mov     es, [si + 2]
        mov     [es:di], bl
        inc     bl
        add     si, 4
        cmp     si, adresses_fin
        jb      ram_ecrit

        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     bh, 0
        mov     al, [es:0]
        cmp     al, bh
        jne     ram_erreur
        mov     si, adresses
        mov     bh, 1
ram_relit:
        mov     di, [si]
        mov     es, [si + 2]
        mov     al, [es:di]
        cmp     al, bh
        jne     ram_erreur
        inc     bh
        add     si, 4
        cmp     si, adresses_fin
        jb      ram_relit

        LCD_LIGNE LIGNE3, txt_ram_ok
        jmp     ligne4

; erreur : "RAM ERR aaaaa ee/ll " (adresse physique, attendu, lu)
ram_erreur:
        mov     bl, al                  ; BL = lu, BH = attendu
        mov     ax, es
        mov     cl, 4
        mov     dx, ax
        shl     dx, cl                  ; bits 15-0 de ES * 16
        add     dx, di                  ; DX = 16 bits bas de l'adresse (sans retenue :
                                        ; ES multiple de 40h et DI <= 3FFh)
        mov     cl, 12
        shr     ax, cl                  ; AX = bits 19-16
        mov     bp, ax                  ; BP = quartet haut
        LCD_COMMANDE (80h | LIGNE3)
        mov     si, txt_ram_err
        mov     di, 8
ram_err_txt:
        lodsb
        LCD_CAR
        dec     di
        jnz     ram_err_txt
        mov     ax, bp
        LCD_HEXQ                        ; aaaaa
        LCD_HEX8 dh
        LCD_HEX8 dl
        mov     al, ' '
        LCD_CAR
        LCD_HEX8 bh                     ; attendu
        mov     al, '/'
        LCD_CAR
        LCD_HEX8 bl                     ; lu
        mov     al, ' '
        LCD_CAR

; ---- ligne 4 et compteur (montre que le processeur tourne) -------------------
ligne4:
        LCD_LIGNE LIGNE4, txt_l4
        xor     dx, dx
boucle:
        LCD_COMMANDE (80h | (LIGNE4 + 16))
        LCD_HEX8 dh
        LCD_HEX8 dl
        inc     dx
        DELAY   0                       ; ~0,4 s par increment a 5,33 MHz (8088)
        DELAY   0
        jmp     boucle

; =============================================================================
; Donnees (en ROM, DS = CS)
; =============================================================================
;                12345678901234567890
txt_l1:     db  'SOLUTION-02 BIOS 0.1'
txt_l2:     db  'CPU 8088/V20 5.33MHz'
txt_ram_ok: db  'RAM 512 Ko : OK     '
txt_ram_err:db  'RAM ERR '
txt_l4:     db  'VE2CUY-2026 CPT 0000'

motifs:     db  55h, 0AAh, 00h, 0FFh

; adresses physiques 2^n (n = 0..18) en (deplacement, segment)
adresses:
%assign n 0
%rep 19
  %if n < 16
            dw  (1 << n), 0
  %else
            dw  0, (1 << (n - 4))
  %endif
  %assign n n + 1
%endrep
adresses_fin:

; =============================================================================
; Vecteur de reset en F000:FFF0
; =============================================================================
        times   0FFF0h - ($ - $$) db 0FFh
reset:
        jmp     0F000h:debut
        db      '11/11/26'              ; F000:FFF5 date
        db      0FFh
        db      0FEh                    ; F000:FFFE modele (PC/XT)
        db      0FFh
