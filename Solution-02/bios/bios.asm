; =============================================================================
; Solution-02 - BIOS 0.7 (VE2CUY, 2026)
; Ordinateur 8088 / NEC V20 autonome : horloge 82C84 (16 MHz / 3 = 5,33 MHz),
; ROM 29C020 (256 Ko), RAM 512 Ko, LCD 20x4 (HD44780 / ST7066U) en ecriture seule.
;
; Carte memoire (schema Solution02.kicad_sch) :
;   00000h-7FFFFh  RAM 512 Ko   (CE# = NAND(/A19, M))
;   80000h-FFFFFh  ROM 256 Ko   (CE# = NAND(A19, M)) - A18 non relie a la ROM :
;                  l'image apparait deux fois (80000h-BFFFFh et C0000h-FFFFFh).
;   Ce BIOS occupe les 64 derniers Ko de la ROM (decalage 30000h) : F000:0000.
;   Les 192 premiers Ko contiennent la disquette de PC-DOS 2.1 (180 Ko, decalage 0 :
;   C000:0000), lecteur A: en lecture seule (INT 13h).
;   Haut de la RAM (7F000h-7FFFFh, DSEG) : donnees du BIOS (ecran 24x80, variables,
;   pile du menu) ; le DOS voit RAM_KO = 508 Ko (INT 12h).
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
;   1) ecran d'ouverture (~2 s), verification rapide des 4 Ko de DSEG (sinon : test
;      complet de la RAM), banniere sur l'UART ;
;   MENU (touches 1-4 du clavier PS/2) :
;      1) Load DOS    : vecteurs d'interruption, BDA, ecran 24x80, amorce A: (INT 19h)
;      2) Test memory : le test complet ci-dessous, puis retour au menu
;      3) LED Show    : animations des DEL + terminal clavier/UART (Echap = menu)
;      4) SysInfo     : processeur (8088 ou V20), memoire, disque
;   Ctrl + Alt + Suppr (sous DOS) : retour au demarrage.
;
;   Test de la RAM : test COMPLET (512 Ko), SANS pile ni variables (macros seulement) :
;      a) motifs : chaque bloc de 1 Ko est rempli puis relu avec 55AAh, AA55h,
;         0000h et FFFFh (chaque octet voit AAh, 55h, 00h et FFh, comme le test de
;         Solution-01) ; progression et nombre de Ko defectueux en ligne 2, detail
;         du PREMIER defaut en ligne 4 ("ERR aaaaa ee/ll" : adresse, attendu, lu) ;
;      b) lignes d'adresse A0-A18 (methode de Solution-01) : 5Ah a l'adresse de
;         base B = 35555h, puis k+1 a B xor 2^k ; une ligne coupee ou en court-
;         circuit fait tomber deux adresses sur la meme case (ligne 3) ;
;      RAM bonne : effacement a 0, PILE en DSEG:1000h verifiee par PUSH/POP,
;      "PILE OK  Touche=menu" ; RAM defectueuse : pas de pile, "RAM DEFAUT  CPT nnnn".
;   LED Show : 9 animations en boucle sur les 24 DEL du 8255, disposees de gauche a
;      droite PC7..PC0, PA7..PA0, PB7..PB0 ; ligne 2 = nom de l'animation + nombre
;      de cycles. Pendant les attentes, scrutation du clavier PS/2 et de l'UART :
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

; donnees du BIOS en haut de la RAM (4 Ko) : 7F000h-7FFFFh
DSEG            equ     7F00h
DSEG_SP         equ     1000h           ; pile du menu : DSEG:1000h (premier PUSH en 7FFFEh)
RAM_KO          equ     508             ; memoire annoncee au DOS (INT 12h)
ECRAN           equ     0               ; tampon d'ecran 24 x 80 en DSEG:0000
LIGNES          equ     24
COLS            equ     80
V_CLAVIER       equ     780h            ; etat du clavier (CLV_*)
V_COL3          equ     781h            ; LED Show : colonne de la ligne 3 (clavier)
V_COL4          equ     782h            ; LED Show : colonne de la ligne 4 (UART)
V_DOS           equ     783h            ; 1 = ecran du DOS sur le LCD (Maj + fleches)
V_CUR           equ     784h            ; curseur (mot : colonne, ligne)
V_VUE           equ     786h            ; coin haut gauche de la fenetre LCD (mot : colonne, ligne)
V_REDESS        equ     788h            ; 1 = LCD a redessiner
V_LCDC          equ     789h            ; 1 = curseur du LCD visible
V_FILE_T        equ     78Ah            ; file du clavier : tete
V_FILE_Q        equ     78Bh            ;                   queue
V_DSTAT         equ     78Ch            ; INT 13h : etat de la derniere operation
V_SORTIE        equ     78Dh            ; 1 = INT 10h appele depuis le dernier INT 16h AH=01h
V_SUIT          equ     78Eh            ; 1 = INT 10h appele : la fenetre doit montrer le curseur
                                        ;     a la prochaine attente du clavier
V_INACTIF       equ     78Fh            ; INT 16h AH=01h de suite sans affichage entre eux
V_FILE          equ     790h            ; file : FILE_N mots
FILE_N          equ     16

; disquette A: en ROM (image de 180 Ko au decalage 0 de la ROM = C0000h)
DISQUE_SEG      equ     0C000h
DISQUE_SPT      equ     9
DISQUE_CYL      equ     40
DISQUE_SECT     equ     360
EQUIPEMENT      equ     0021h           ; 1 lecteur de disquette, video 80x25
%ifndef DISQUE_IMG
%define DISQUE_IMG "../../PC-DOS/pcdos2_1.img"
%endif

LCD_D           equ     40              ; delai apres une ecriture au LCD (ecran du DOS)
KBD_FENETRE     equ     150             ; INT 16h AH=01h : ~1 ms d'ecoute du clavier
KBD_FENETRE_L   equ     1000            ; ~8 ms si rien n'a ete affiche depuis l'appel precedent
; INACTIF_N : appels INT 16h AH=01h de suite sans affichage (~10 ms chacun) avant de
; considerer que le DOS attend une touche (pendant DIR, il en fait 2 par caractere)
INACTIF_N       equ     10
NAV_C           equ     10              ; Maj + gauche/droite : pas de la fenetre

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
; Blocage du clavier (comme le PC/AT) : diode Schottky de KBD_CLK (anode) vers PC0 de
; U12 (cathode). PC0 = 0 tient l'horloge basse : le clavier garde ses touches et
; interrompt (puis renvoie) une trame commencee. Commande par mise a 0/1 d'un bit
; (BSR) : PA7 (TX) n'est pas touche. Sans la diode, sans effet.
KBD_BLOQUE      equ     00h             ; BSR : PC0 = 0
KBD_LIBRE       equ     01h             ; BSR : PC0 = 1

; UART 9600 8N1 : iterations de LOOP par bit, A CALIBRER a l'oscilloscope (bit = 104,2 us).
; Estimation pour un 8088 a 5,33 MHz : ~70 cycles fixes + 17 par iteration = 555 cycles.
; Bit trop long -> diminuer ; trop court -> augmenter (1 unite = 3,2 us = 3 % d'un bit).
%ifndef UART_N
UART_N          equ     29
%endif
PS2_DELAI       equ     150             ; attentes PS/2 : ~1 ms (boucle de ~36 cycles)

CLV_RELACHE     equ     01h             ; F0 recu
CLV_ETENDU      equ     02h             ; E0 recu
CLV_MAJ         equ     04h             ; Maj gauche
CLV_CTRL        equ     08h
CLV_VERR_MAJ    equ     10h
CLV_ALT         equ     20h
CLV_MAJ_D       equ     40h             ; Maj droite
CLV_FAUX        equ     80h             ; E0 F0 12/59 recu : Maj tenue avec une fleche
CLV_MAJS        equ     CLV_MAJ | CLV_MAJ_D

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
; Image de 256 Ko : la disquette de PC-DOS 2.1 (180 Ko) et du vide (FFh), puis le
; segment F000h
; =============================================================================
        section disque start=0
        incbin  DISQUE_IMG
%if ($ - $$) != DISQUE_SECT * 512
%error "image de disquette : 184320 octets attendus"
%endif
        times   30000h - ($ - $$) db 0FFh

        section bios start=30000h vstart=0

debut:
        cli
        cld
        mov     ax, cs
        mov     ds, ax                  ; textes en ROM (DS = CS = F000h)

; ---- 2e 8255 (U12) en premier : TX de l'UART au repos (1) le plus tot possible ----
        mov     al, PPI2_MODE           ; PA et PC en sortie, PB en entree
        out     PPI2_CTRL, al
                                        ; (le mot de mode met PC0 a 0 : clavier bloque
                                        ;  tant que le BIOS ne l'ecoute pas)
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

%ifdef DIAG_U12
; ---- ROM de diagnostic du 2e 8255 U12 (make diag2) ------------------------------
; PC et PA de U12 clignotent (55h <-> AAh, ~0,3 s ; PC0 reste a 1) ; le mot de controle 82h est
; renvoye a chaque inversion. Ligne 3 : PB lu en direct (CLK = PB0, DATA = PB1).
; Ligne 4 : dernier octet PS/2 recu, nombre de trames bonnes / en erreur (hexa).
; La RAM ayant ete validee, la pile est mise en 7000:0000 sans test (pour ps2_trame).
        mov     ax, 7000h
        mov     ss, ax
        xor     sp, sp
        LCD_LIGNE LIGNE1, txt_du1
        LCD_LIGNE LIGNE2, txt_du2
        LCD_LIGNE LIGNE3, txt_du3
        LCD_LIGNE LIGNE4, txt_du4
        mov     bl, 55h                 ; BL = motif de PC et PA
        xor     bh, bh                  ; BH = trames bonnes
        xor     dx, dx                  ; DH = dernier octet, DL = trames en erreur
du_motif:
        mov     al, PPI2_MODE
        out     PPI2_CTRL, al
        mov     al, bl
        out     PPI2_PA, al
        or      al, KBD_LIBRE           ; PC0 = 1 : clavier libre (diode de blocage)
        out     PPI2_PC, al
        LCD_COMMANDE (80h | LIGNE2 + 3) ; "PC=55 PA=55"
        LCD_HEX8 bl
        LCD_COMMANDE (80h | LIGNE2 + 9)
        LCD_HEX8 bl
        in      al, PPI2_PB             ; "PB=FF CLK=1 DATA=1"
        mov     ah, al
        LCD_COMMANDE (80h | LIGNE3 + 3)
        LCD_HEX8 ah
        LCD_COMMANDE (80h | LIGNE3 + 10)
        mov     al, ah
        and     al, KBD_CLK
        add     al, '0'
        LCD_CAR
        LCD_COMMANDE (80h | LIGNE3 + 17)
        mov     al, ah
        shr     al, 1
        and     al, 1
        add     al, '0'
        LCD_CAR
        or      bh, bh                  ; "Code 1C OK 03 Err 00"
        jz      .sans_code
        LCD_COMMANDE (80h | LIGNE4 + 5)
        LCD_HEX8 dh
.sans_code:
        LCD_COMMANDE (80h | LIGNE4 + 11)
        LCD_HEX8 bh
        LCD_COMMANDE (80h | LIGNE4 + 18)
        LCD_HEX8 dl
        mov     cx, 45000               ; ~0,3 s en scrutant l'horloge du clavier
du_attente:
        in      al, PPI2_PB
        test    al, KBD_CLK
        jz      du_trame
du_suite:
        loop    du_attente
        not     bl
        jmp     du_motif
du_trame:
        call    ps2_trame               ; preserve BX, CX, DX
        jc      du_err
        mov     dh, al
        inc     bh
        jmp     du_suite
du_err: inc     dl
        jmp     du_suite
%endif

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

; ---- verification rapide de DSEG (4 Ko : donnees et pile du BIOS), sans pile -----
        mov     ax, DSEG
        mov     es, ax
        mov     si, motifs
dseg_motif:
        mov     ax, [si]
        xor     di, di
        mov     cx, 800h
        rep     stosw
        xor     di, di
        mov     cx, 800h
        repe    scasw
        jne     ram_test                ; DSEG defectueux : test complet (avec details)
        add     si, 2
        cmp     si, motifs + 8
        jb      dseg_motif
        mov     ax, DSEG
        mov     ss, ax
        mov     sp, DSEG_SP
        call    vars_init
        mov     si, txt_uart_banniere   ; banniere sur l'UART (9600 8N1)
        call    uart_texte
        jmp     menu

; ---- test complet de la RAM (menu 2), sans pile -------------------------------------
ram_test:
        cli
        cld
        mov     ax, cs
        mov     ds, ax
        LCD_COMMANDE 0Ch                ; sans curseur
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

        mov     ax, DSEG
        mov     ss, ax                  ; (MOV SS bloque les interruptions pour
        mov     sp, DSEG_SP             ;  l'instruction suivante)
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
        call    vars_init
        call    kbd_attend              ; une touche : retour au menu
        jmp     menu

; =============================================================================
; MENU (pile en DSEG:1000h, DS = CS, ES = DSEG)
; =============================================================================
menu:
        cli
        cld
        mov     ax, DSEG
        mov     ss, ax
        mov     sp, DSEG_SP
        mov     es, ax
        mov     ax, cs
        mov     ds, ax
        mov     byte [es:V_DOS], 0
        call    kbd_bloque              ; clavier bloque hors des attentes
        xor     al, al                  ; DEL eteintes
        out     PPI_PA, al
        out     PPI_PB, al
        out     PPI_PC, al
        mov     si, txt_menu
        call    lcd_ecran
.touche:
        call    kbd_attend
        cmp     al, '1'
        je      .dos
        cmp     al, '2'
        je      .ram
        cmp     al, '3'
        je      led_show
        cmp     al, '4'
        je      sysinfo
        jmp     .touche
.dos:   jmp     dos_charger
.ram:   jmp     ram_test

; lcd_ecran : efface le LCD et affiche 4 lignes de 20 caracteres (DS:SI). Detruit AX, BX, CX, SI.
lcd_ecran:
        mov     al, 0Ch                 ; sans curseur
        call    lcd_cmd
        mov     al, 01h
        call    lcd_cmd
        DELAY   3000
        mov     al, 80h | LIGNE1
        call    lcd_cmd
        call    lcd_texte20
        mov     al, 80h | LIGNE2
        call    lcd_cmd
        call    lcd_texte20
        mov     al, 80h | LIGNE3
        call    lcd_cmd
        call    lcd_texte20
        mov     al, 80h | LIGNE4
        call    lcd_cmd
        jmp     lcd_texte20

; vars_init : etat du clavier et file remis a zero, mode DOS inactif. ES = DSEG.
vars_init:
        mov     ax, DSEG
        mov     es, ax
        xor     ax, ax
        mov     [es:V_CLAVIER], al
        mov     [es:V_DOS], al
        mov     [es:V_SUIT], al
        mov     [es:V_INACTIF], al
        mov     [es:V_FILE_T], ax       ; tete et queue
        ret

; ---- 4) SysInfo ---------------------------------------------------------------------
sysinfo:
        mov     si, txt_sys
        call    lcd_ecran
        mov     ax, 0102h               ; AAD 16 : 8088 -> 1 x 16 + 2 = 12h ; le NEC V20
        db      0D5h, 10h               ; ignore l'operande (toujours base 10) -> 0Ch
        mov     si, txt_cpu_8088
        cmp     al, 12h
        je      .cpu
        mov     si, txt_cpu_v20
.cpu:   mov     al, 80h | LIGNE2
        call    lcd_cmd
        call    lcd_texte20
        call    kbd_attend
        jmp     menu

; ---- 3) LED Show : animations des DEL (8255 U7) + terminal clavier / UART (U12) ----
; Le clavier et l'UART sont scrutes pendant les attentes des animations (del_aff) ;
; Echap ramene au menu.
led_show:
        mov     si, txt_led
        call    lcd_ecran
        mov     byte [es:V_COL3], LCD_COLS   ; le premier caractere efface l'invite
        mov     byte [es:V_COL4], LCD_COLS
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
        call    kbd_libere              ; attente en scrutant le clavier et l'UART
        mov     cx, di
.w:     in      al, PPI2_PB
        test    al, KBD_CLK
        jz      .clavier                ; CLK bas : debut d'une trame PS/2
        test    al, UART_RX
        jz      .uart                   ; RX bas : bit de depart
.suite: loop    .w
        jmp     kbd_bloque
.clavier:
        call    clavier_entree          ; (bloque le clavier apres la trame)
        call    kbd_libere
        jmp     .suite
.uart:  call    kbd_bloque              ; clavier bloque pendant l'octet et l'echo
        call    uart_entree
        call    kbd_libere
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

; clavier_decode : AL = octet recu du clavier (jeu 2). Sortie : CF = 0 et AX = code
; de touche comme INT 16h (AH = code XT, AL = ASCII ou 0 pour les touches de fonction,
; fleches, etc.) ; CF = 1 si rien a produire (prefixe, relachement, Maj/Ctrl/Alt/
; Verr Maj). Etat dans [es:V_CLAVIER] (ES = DSEG), tables en DS = CS. Preserve le reste.
clavier_decode:
        push    bx
        mov     bl, [es:V_CLAVIER]
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
        mov     bh, bl                  ; BH = prefixes de cet octet
        and     bl, ~(CLV_RELACHE | CLV_ETENDU)
        test    bh, CLV_ETENDU          ; Maj "factices" (E0 F0 12 avant une fleche,
        jz      .modifs                 ; E0 12 apres, ou 59h pour Maj droite) : le
        cmp     al, 12h                 ; relachement factice prouve que Maj est tenue
        je      .faux                   ; (utile si son appui a ete perdu)
        cmp     al, 59h
        jne     .modifs
.faux:  and     bl, ~CLV_FAUX
        test    bh, CLV_RELACHE
        jz      .rien
        or      bl, CLV_FAUX
        jmp     .rien
.modifs:
        mov     ah, CLV_MAJ
        cmp     al, 12h                 ; Maj gauche
        je      .modif
        mov     ah, CLV_MAJ_D
        cmp     al, 59h                 ; Maj droite
        je      .modif
        mov     ah, CLV_CTRL
        cmp     al, 14h                 ; Ctrl (gauche, ou droite = E0 14)
        je      .modif
        mov     ah, CLV_ALT
        cmp     al, 11h                 ; Alt (gauche, ou droite = E0 11)
        je      .modif
        test    bh, CLV_RELACHE
        jnz     .rien                   ; autres relachements : ignores
        cmp     al, 58h                 ; Verr Maj : bascule
        jne     .touche
        xor     bl, CLV_VERR_MAJ
        jmp     .rien
.modif: test    bh, CLV_RELACHE
        jz      .modif_on
        test    ah, CLV_MAJS            ; Maj relachee : plus de Maj factice
        jz      .m1
        and     bl, ~CLV_FAUX
.m1:    not     ah
        and     bl, ah
        jmp     .rien
.modif_on:
        or      bl, ah
        jmp     .rien
.touche:
        push    si
        test    bh, CLV_ETENDU
        jz      .normale
        mov     si, clavier_etendu      ; E0 xx : (code, XT, ASCII)
.e:     cmp     byte [si], 0
        je      .n_rien
        cmp     al, [si]
        je      .e_ok
        add     si, 3
        jmp     .e
.e_ok:  mov     ah, [si + 1]
        mov     al, [si + 2]
        jmp     .alt
.normale:
        and     bl, ~CLV_FAUX           ; touche ordinaire : sequence de fleche finie
        cmp     al, CLAVIER_NB_CODES
        jae     .n_rien
        xor     ah, ah
        mov     si, ax
        mov     ah, [si + clavier_xt]
        or      ah, ah
        jz      .n_rien
        mov     al, [si + clavier_normal]
        test    bl, CLV_MAJS
        jz      .lettre
        mov     al, [si + clavier_maj]
.lettre:
        mov     bh, al                  ; lettres : Verr Maj inverse la casse,
        or      bh, 20h                 ;           Ctrl donne 01h-1Ah
        cmp     bh, 'a'
        jb      .alt
        cmp     bh, 'z'
        ja      .alt
        test    bl, CLV_VERR_MAJ
        jz      .ctrl
        xor     al, 20h
.ctrl:  test    bl, CLV_CTRL
        jz      .alt
        and     al, 1Fh
.alt:   test    bl, CLV_ALT             ; Alt + touche : ASCII 0
        jz      .produit
        xor     al, al
.produit:
        pop     si
        mov     [es:V_CLAVIER], bl
        pop     bx
        clc
        ret
.n_rien:
        pop     si
.rien:  mov     [es:V_CLAVIER], bl
        pop     bx
        stc
        ret

; touches etendues (E0 xx) : code jeu 2, code XT, ASCII
clavier_etendu:
        db      75h, 48h, 0             ; fleche haut
        db      72h, 50h, 0             ; bas
        db      6Bh, 4Bh, 0             ; gauche
        db      74h, 4Dh, 0             ; droite
        db      70h, 52h, 0             ; Inser
        db      71h, 53h, 0             ; Suppr
        db      6Ch, 47h, 0             ; Debut
        db      69h, 4Fh, 0             ; Fin
        db      7Dh, 49h, 0             ; Page prec.
        db      7Ah, 51h, 0             ; Page suiv.
        db      5Ah, 1Ch, 13            ; Entree du pave
        db      4Ah, 35h, '/'           ; / du pave
        db      0

; =============================================================================
; Terminal du LED Show : clavier -> LCD ligne 3 + UART ; UART -> LCD ligne 4 + echo
; sur l'UART. Appeles depuis del_aff (pendant les animations) : preservent tous les
; registres sauf AL. Echap : retour au menu.
; =============================================================================
clavier_entree:
        push    ax                      ; (AH sert de compteur aux animations)
        push    cx
        call    ps2_trame
        push    ax                      ; trame lue : clavier bloque pendant le
        call    kbd_bloque              ; traitement (LCD, UART), relache par del_aff
        pop     ax
        jc      .fin
        call    clavier_decode
        jc      .fin
        cmp     al, 27                  ; Echap : retour au menu (qui refait la pile)
        jne     .pas_echap
        jmp     menu
.pas_echap:
        or      al, al
        jnz     .car
        push    si                      ; fleches : sequence ANSI ESC [ A..D sur l'UART
        mov     si, fleches_ansi
.f:     cmp     byte [si], 0
        je      .f_fin
        cmp     ah, [si]
        je      .f_ok
        inc     si
        inc     si
        jmp     .f
.f_ok:  mov     al, 27
        call    uart_tx
        mov     al, '['
        call    uart_tx
        mov     al, [si + 1]
        call    uart_tx
.f_fin: pop     si
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

; ecran_car : affiche AL sur la ligne de debut DDRAM AH, colonne dans [es:BX].
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
        cmp     byte [es:bx], LCD_COLS
        jb      .ecrit
        call    .vide                   ; ligne pleine : on repart a gauche
.ecrit: mov     al, [es:bx]
        add     al, dh
        or      al, 80h
        call    lcd_cmd
        mov     al, dl
        call    lcd_car
        inc     byte [es:bx]
        jmp     .fin
.recule:
        cmp     byte [es:bx], 0
        je      .fin
        cmp     byte [es:bx], LCD_COLS
        ja      .fin
        dec     byte [es:bx]
        mov     al, [es:bx]
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
        mov     byte [es:bx], 0
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
txt_ouv1:   db  'SOLUTION-02 BIOS 0.7'
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
txt_pile_ok:db  'PILE OK  Touche=menu'
txt_pile_err:db 'PILE ERR            '
txt_menu:   db  '1) Load DOS         '
            db  '2) Test memory      '
            db  '3) LED Show         '
            db  '4) SysInfo          '
txt_led:    db  'LED SHOW  Echap=menu'
            db  '                    '
            db  'Clavier PS/2 >      '
            db  'UART 9600 8N1 >     '
txt_sys:    db  'SOLUTION-02 BIOS 0.7'
            db  'CPU 8088    5.33 MHz'
            db  'RAM 512Ko  ROM 256Ko'
            db  'A: PC-DOS 2.1  180Ko'
txt_cpu_8088:db 'CPU 8088    5.33 MHz'
txt_cpu_v20:db  'CPU NEC V20 5.33 MHz'
txt_uart_banniere:
            db  13, 10, 'Solution-02 BIOS 0.7 - VE2CUY 2026', 13, 10
            db  'Menu (clavier PS/2) : 1) Load DOS  2) Test memory  3) LED Show  4) SysInfo', 13, 10, 0
; fleches (code XT) -> lettre de la sequence ANSI ESC [ x
fleches_ansi:
            db  48h, 'A', 50h, 'B', 4Dh, 'C', 4Bh, 'D', 0
%ifdef DIAG_8255
txt_diag1:  db  'DIAG 8255  10h-13h  '
txt_diag2:  db  'Rafale: CS# et WR#  '
txt_diag3:  db  'U7 br. 6 et 36      '
%endif
%ifdef DIAG_U12
txt_du1:    db  'DIAG 8255 U12  30h  '
txt_du2:    db  'PC=55 PA=55 clignote'
txt_du3:    db  'PB=FF CLK=1 DATA=1  '
txt_du4:    db  'Code -- OK 00 Err 00'
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
%include "services.inc"

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
        db      '14/11/26'              ; F000:FFF5 date
        db      0FFh
        db      0FEh                    ; F000:FFFE modele (PC/XT)
        db      0FFh
