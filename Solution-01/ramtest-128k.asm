; ============================================================
; ramtest-128k.asm - ROM de TEST de la RAM de 128 Ko (HM628128, JP2 2-3)
; qui n'utilise AUCUNE RAM: ni pile, ni variable.
;
;   nasm -f bin ramtest-128k.asm -o solution-01-ramtest-128k.bin   (make ramtest)
;
; Une RAM morte ou mal cablee ne peut donc pas l'empecher de tourner ni
; d'afficher son diagnostic. Seuls servent le 8088, la ROM, le 8255 et le
; pont STM32 (LCD I2C) - le pont tient le 8088 en reset jusqu'a ce qu'il soit
; pret, le LCD est donc disponible des le premier octet.
;
; Regles d'ecriture (a respecter si on modifie ce fichier):
;   - AUCUN push/pop/call/ret/int/pushf: rien ne doit toucher SS:SP.
;   - les envois au pont sont en ligne (macro TX); les quelques sous-programmes
;     (lcd_str, lcd_hex8, lcd_dec4) sont appeles par CALLR: adresse de retour
;     dans BP, retour par "jmp bp" - un seul niveau, jamais imbriques.
;   - IF = 0 tout du long (CLI): aucune interruption (elle empilerait).
;   - etat global dans des registres, faute de RAM:
;       DS = numero de la passe (1-9999)
;       SS = carte CUMULEE des blocs de 8 Ko fautifs (bit b = bloc b, toutes passes)
;       SP = bits de donnees fautifs CUMULES (octet bas), toutes passes
;     pendant une passe: DX = carte des blocs fautifs de la passe, BH = bits
;     fautifs de la passe (tests des blocs), BP = masque du bloc courant.
;   Les chaines sont lues dans la ROM par CS: (DS n'est pas un segment de donnees).
;
; Chaque passe (en boucle, sans fin):
;   1. bus de donnees: 1 bit a 1 puis 1 bit a 0 (8 positions) en 0000:0000, avec
;      une ecriture "leurre" du complement en 0000:5555 entre l'ecriture et la
;      relecture (sans RAM, le bus flottant garde la derniere valeur: le leurre
;      empeche de relire ce qu'on vient d'ecrire). -> masque des bits fautifs.
;   2. lignes d'adresse A0-A16: 55h en 0 et en chaque 2^k; AAh en 0 -> chaque
;      2^k doit rester 55h (ligne k collee a 0 ou confondue avec 0); puis AAh
;      en chaque 2^j a tour de role -> 0 et les autres 2^k doivent rester 55h
;      (ligne j collee a 1, lignes j et k en court-circuit). -> masque A16-A0.
;   3. 16 blocs de 8 Ko (00000h-1FFFFh): chaque bloc rempli puis verifie avec
;      55h, AAh, 00h; puis TOUTE la RAM remplie avec un motif qui depend de
;      l'adresse (octet bas ^ octet haut de l'offset ^ 37 x bloc) et verifiee
;      ensuite - detecte un bloc qui en recouvre un autre.
;
; Affichage (LCD 20x4):
;   ligne 1  "Test RAM 128K P:0001"   numero de la passe
;   ligne 2  "Donnees : OK"           ou "Donnees : KO 5A" (bits fautifs, cette passe)
;   ligne 3  "Adresses: OK"           ou "Adresses: KO 00104" (A16..A0 fautives)
;   ligne 4  "................ OK"    carte des 16 blocs de 8 Ko (00000h a gauche):
;              '.' bon, 'X' fautif a cette passe, '!' fautif a une passe precedente,
;              '>' en cours, '*' fait (1re phase); a droite: OK, ou les bits de
;              donnees fautifs cumules (hex).
; ============================================================
BITS    16
CPU     8086
ORG     0000h                   ; = physique C0000h (debut de la ROM de 256 Ko)

%include "include/hardware.inc"

LCD_L1  equ     00h             ; adresses DDRAM du debut des lignes (20x4)
LCD_L2  equ     40h
LCD_L3  equ     14h
LCD_L4  equ     54h
NB_BLOCS equ    16              ; 16 blocs de 8 Ko = 128 Ko
BLOC_PARAS equ  0200h           ; 8 Ko en paragraphes
BLOC_OCTETS equ 2000h

; --- TX: envoie AL au pont sur le canal %1 (constante). Attend d'abord que le
; --- pont ait lu l'octet precedent (OBF# = 1, PC7), au plus 65536 tours (~0,5 s
; --- a 4,77 MHz: un pont absent ne bloque pas le test). Detruit AL, AH, CX. ---
%macro TX 1
        mov     ah, al
        xor     cx, cx
%%attente:
        in      al, PORTC
        test    al, PC_OBF_N
        jnz     %%libre
        loop    %%attente
%%libre:
        mov     al, %1
        out     PORTB, al               ; canal AVANT l'octet (le pont le lit sur OBF# bas)
        mov     al, ah
        out     PORTA, al
%endmacro

%macro LCD_CMD 1                        ; commande HD44780 (constante). Detruit AX, CX.
        mov     al, %1
        TX      PB_CHAN_LCD_CMD
%endmacro

%macro LCD_CHR 1                        ; caractere (constante ou registre 8 bits). Detruit AX, CX.
        mov     al, %1
        TX      PB_CHAN_LCD_DATA
%endmacro

%macro CALLR 1                          ; appel SANS pile: retour par "jmp bp"
        mov     bp, %%retour
        jmp     %1
%%retour:
%endmacro

%macro PRINT_AT 2                       ; %1 = adresse DDRAM, %2 = chaine (CS:). Detruit AX, CX, SI, BP.
        LCD_CMD (80h | (%1))
        mov     si, %2
        CALLR   lcd_str
%endmacro

; --- MARQUE_ADR: ligne d'adresse k fautive, k = (%1 - tab_adr) / 4.
; --- A0-A15 -> bit k de DX, A16 -> bit 0 de BH. Detruit AX, CL. ---
%macro MARQUE_ADR 1
        mov     ax, %1
        sub     ax, tab_adr
        mov     cl, 2
        shr     ax, cl
        cmp     al, 16
        jb      %%bas
        or      bh, 1
        jmp     %%fin
%%bas:
        mov     cl, al
        mov     ax, 1
        shl     ax, cl
        or      dx, ax
%%fin:
%endmacro

; --- ES:DI <- entree %1 de tab_adr (segment, offset). Detruit AX. ---
%macro ADR 1
        mov     ax, [cs:%1]
        mov     es, ax
        mov     di, [cs:%1+2]
%endmacro

; ============================================================
start:
        cli
        cld
        ; --- 8255: Port A mode 2 (bus avec le pont), Port B sortie (canal), comme init_8255
        ; --- (solution-01.asm), mais SANS INTE2: aucune interruption ici. ---
        mov     al, MASQUE_PIO
        out     PIO, al
        xor     al, al
        out     PORTB, al
        mov     al, PIO_INTE1_RESET
        out     PIO, al

        xor     ax, ax
        mov     ds, ax                  ; passe 0
        mov     ss, ax                  ; aucun bloc fautif
        mov     sp, ax                  ; aucun bit fautif

        ; --- LCD: Function Set (le pont se resynchronise sur 28h), affichage, mode, effacement ---
        LCD_CMD 28h
        LCD_CMD 0Ch
        LCD_CMD 06h
        LCD_CMD 01h
        PRINT_AT LCD_L1, txt_titre
        PRINT_AT LCD_L2, txt_donnees
        PRINT_AT LCD_L3, txt_adresses
        PRINT_AT LCD_L4, txt_carte_vide

; ============================================================
passe:
        mov     ax, ds
        cmp     ax, 9999
        jae     .compteur
        inc     ax
        mov     ds, ax
.compteur:
        LCD_CMD (80h | (LCD_L1 + 16))
        mov     ax, ds
        CALLR   lcd_dec4                ; detruit AX, BX, CX, DX, SI

; ------------------------------------------------------------
; 1. Bus de donnees (0000:0000, leurre en 0000:5555) -> BL = bits fautifs
; ------------------------------------------------------------
        xor     ax, ax
        mov     es, ax
        xor     bl, bl
        mov     ah, 01h                 ; bit qui marche
.bit:
        mov     [es:0000h], ah          ; un seul bit a 1
        mov     al, ah
        not     al
        mov     [es:5555h], al          ; leurre: complement ailleurs
        mov     al, [es:0000h]
        xor     al, ah
        or      bl, al

        mov     al, ah
        not     al
        mov     [es:0000h], al          ; un seul bit a 0
        mov     [es:5555h], ah          ; leurre
        mov     bh, [es:0000h]
        xor     bh, al
        or      bl, bh

        shl     ah, 1
        jnz     .bit

        PRINT_AT (LCD_L2 + 10), txt_vide10
        LCD_CMD (80h | (LCD_L2 + 10))
        or      bl, bl
        jnz     .donnees_ko
        LCD_CHR 'O'
        LCD_CHR 'K'
        jmp     .adresses
.donnees_ko:
        LCD_CHR 'K'
        LCD_CHR 'O'
        LCD_CHR ' '
        mov     al, bl
        CALLR   lcd_hex8

; ------------------------------------------------------------
; 2. Lignes d'adresse A0-A16 -> DX (A0-A15), BH bit 0 (A16)
; ------------------------------------------------------------
.adresses:
        xor     dx, dx
        xor     bh, bh
        xor     ax, ax
        mov     es, ax
        mov     byte [es:0000h], 55h
        mov     si, tab_adr
.a_init:
        ADR     si
        mov     byte [es:di], 55h
        add     si, 4
        cmp     si, tab_adr_fin
        jb      .a_init

        xor     ax, ax                  ; AAh en 0: aucune 2^k ne doit bouger
        mov     es, ax
        mov     byte [es:0000h], 0AAh
        mov     si, tab_adr
.a_bas:
        ADR     si
        cmp     byte [es:di], 55h
        je      .a_bas_ok
        MARQUE_ADR si                   ; 2^k a suivi 0: ligne k collee a 0 (ou confondue)
.a_bas_ok:
        add     si, 4
        cmp     si, tab_adr_fin
        jb      .a_bas

        xor     ax, ax
        mov     es, ax
        mov     byte [es:0000h], 55h
        mov     bp, tab_adr             ; BP = j (pas de CALLR dans cette boucle)
.a_j:
        ADR     bp
        mov     byte [es:di], 0AAh      ; 2^j = AAh: 0 et les autres 2^k doivent rester 55h
        xor     ax, ax
        mov     es, ax
        cmp     byte [es:0000h], 55h
        je      .a_j_zero_ok
        MARQUE_ADR bp                   ; 0 a suivi 2^j: ligne j collee a 1
.a_j_zero_ok:
        mov     si, tab_adr
.a_k:
        cmp     si, bp
        je      .a_k_suivant
        ADR     si
        cmp     byte [es:di], 55h
        je      .a_k_suivant
        MARQUE_ADR si                   ; 2^k a suivi 2^j: lignes j et k en court-circuit
        MARQUE_ADR bp
.a_k_suivant:
        add     si, 4
        cmp     si, tab_adr_fin
        jb      .a_k
        ADR     bp
        mov     byte [es:di], 55h       ; remet 2^j
        add     bp, 4
        cmp     bp, tab_adr_fin
        jb      .a_j

        ; --- affichage: "OK" ou "KO " + A16 (1 chiffre) + A15-A0 (4 chiffres hex) ---
        mov     bl, bh                  ; BL = A16 (PRINT_AT detruit SI/BP, pas BX/DX)
        PRINT_AT (LCD_L3 + 10), txt_vide10
        LCD_CMD (80h | (LCD_L3 + 10))
        mov     ax, dx
        or      al, ah
        or      al, bl
        jnz     .adresses_ko
        LCD_CHR 'O'
        LCD_CHR 'K'
        jmp     .blocs
.adresses_ko:
        LCD_CHR 'K'
        LCD_CHR 'O'
        LCD_CHR ' '
        mov     al, bl
        and     al, 1
        add     al, '0'
        TX      PB_CHAN_LCD_DATA
        mov     al, dh
        CALLR   lcd_hex8
        mov     al, dl
        CALLR   lcd_hex8

; ------------------------------------------------------------
; 3. Blocs de 8 Ko: DX = carte de la passe, BH = bits fautifs de la passe
; ------------------------------------------------------------
.blocs:
        xor     dx, dx
        xor     bh, bh
        xor     si, si                  ; SI = numero du bloc
.bloc:
        mov     ax, si                  ; progression: '>' sur la case du bloc
        add     al, 80h | LCD_L4
        TX      PB_CHAN_LCD_CMD
        LCD_CHR '>'

        mov     ax, si                  ; ES = bloc * 200h, BP = 1 << bloc
        mov     cl, 9
        shl     ax, cl
        mov     es, ax
        mov     cx, si
        mov     bp, 1
        shl     bp, cl

        mov     bl, 55h
.motif:
        mov     al, bl
        xor     di, di
        mov     cx, BLOC_OCTETS
        rep     stosb
        xor     di, di
        mov     cx, BLOC_OCTETS
.compare:
        repe    scasb
        je      .motif_fin              ; ZF = 1: tout concorde jusqu'au bout
        mov     ah, [es:di-1]           ; octet different (DI est deja passe dessus)
        xor     ah, al
        or      bh, ah
        or      dx, bp
        jcxz    .motif_fin
        jmp     .compare
.motif_fin:
        cmp     bl, 55h                 ; 55h -> AAh -> 00h -> fini
        jne     .motif_2
        mov     bl, 0AAh
        jmp     .motif
.motif_2:
        cmp     bl, 0AAh
        jne     .bloc_fait
        xor     bl, bl
        jmp     .motif
.bloc_fait:
        mov     ax, si                  ; '*' (ou 'X' si deja fautif)
        add     al, 80h | LCD_L4
        TX      PB_CHAN_LCD_CMD
        mov     al, '*'
        test    dx, bp
        jz      .etoile
        mov     al, 'X'
.etoile:
        TX      PB_CHAN_LCD_DATA
        inc     si
        cmp     si, NB_BLOCS
        jb      .bloc

        ; --- motif selon l'adresse, sur TOUTE la RAM: ecriture des 16 blocs, puis verification ---
        xor     si, si
.ecrit:
        mov     ax, si
        mov     cl, 9
        shl     ax, cl
        mov     es, ax
        mov     ax, si
        mov     bl, 37
        mul     bl                      ; AL = 37 x bloc (AH ignore)
        mov     bl, al
        xor     di, di
        mov     cx, BLOC_OCTETS
.ecrit_octet:
        mov     ax, di
        xor     al, ah
        xor     al, bl
        stosb
        loop    .ecrit_octet
        inc     si
        cmp     si, NB_BLOCS
        jb      .ecrit

        xor     si, si
.verifie:
        mov     ax, si
        mov     cl, 9
        shl     ax, cl
        mov     es, ax
        mov     cx, si
        mov     bp, 1
        shl     bp, cl
        mov     ax, si
        mov     bl, 37
        mul     bl
        mov     bl, al
        xor     di, di
        mov     cx, BLOC_OCTETS
.verifie_octet:
        mov     ax, di
        xor     al, ah
        xor     al, bl
        mov     ah, [es:di]
        xor     ah, al
        jz      .verifie_ok
        or      bh, ah
        or      dx, bp
.verifie_ok:
        inc     di
        loop    .verifie_octet
        inc     si
        cmp     si, NB_BLOCS
        jb      .verifie

        ; --- cumul: SS |= DX (blocs), SP |= BH (bits) ---
        mov     ax, ss
        or      ax, dx
        mov     ss, ax
        mov     ax, sp
        or      al, bh
        mov     sp, ax

        ; --- carte finale de la passe: '.' bon, 'X' fautif ici, '!' fautif avant ---
        LCD_CMD (80h | LCD_L4)
        xor     si, si
        mov     bp, 1
.carte:
        mov     al, '.'
        test    dx, bp
        jz      .carte_pas_ici
        mov     al, 'X'
        jmp     .carte_ecrit
.carte_pas_ici:
        mov     cx, ss
        test    cx, bp
        jz      .carte_ecrit
        mov     al, '!'
.carte_ecrit:
        TX      PB_CHAN_LCD_DATA
        shl     bp, 1
        inc     si
        cmp     si, NB_BLOCS
        jb      .carte

        ; --- a droite: " OK " si rien de fautif depuis le debut, sinon " xx " (bits cumules) ---
        LCD_CHR ' '
        mov     ax, sp
        or      al, al
        jnz     .bits_ko
        mov     ax, ss
        or      ax, ax
        jnz     .bits_ko
        LCD_CHR 'O'
        LCD_CHR 'K'
        jmp     .ligne4_fin
.bits_ko:
        mov     ax, sp
        CALLR   lcd_hex8
.ligne4_fin:
        LCD_CHR ' '
        jmp     passe

; ============================================================
; Sous-programmes SANS PILE (appel par CALLR, retour par "jmp bp")
; ============================================================

; lcd_str: affiche la chaine CS:SI terminee par 0. Detruit AX, CX, SI.
lcd_str:
        mov     al, [cs:si]
        or      al, al
        jz      .fin
        TX      PB_CHAN_LCD_DATA
        inc     si
        jmp     lcd_str
.fin:
        jmp     bp

; lcd_hex8: affiche AL en 2 chiffres hexadecimaux. Detruit AX, CX, SI.
lcd_hex8:
        mov     si, ax
        mov     cl, 4
        shr     al, cl
        add     al, '0'
        cmp     al, '9'
        jbe     .haut
        add     al, 7
.haut:
        TX      PB_CHAN_LCD_DATA
        mov     ax, si
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .bas
        add     al, 7
.bas:
        TX      PB_CHAN_LCD_DATA
        jmp     bp

; lcd_dec4: affiche AX (0-9999) en 4 chiffres decimaux. Detruit AX, BX, CX, DX, SI.
lcd_dec4:
        xor     dx, dx
        mov     bx, 1000
        div     bx                      ; AL = milliers, DX = reste
        mov     si, dx
        add     al, '0'
        TX      PB_CHAN_LCD_DATA
        mov     ax, si
        mov     bl, 100
        div     bl                      ; AL = centaines, AH = reste
        mov     bl, ah
        add     al, '0'
        TX      PB_CHAN_LCD_DATA
        mov     al, bl
        xor     ah, ah
        mov     bl, 10
        div     bl                      ; AL = dizaines, AH = unites
        mov     si, ax
        add     al, '0'
        TX      PB_CHAN_LCD_DATA
        mov     ax, si
        mov     al, ah
        add     al, '0'
        TX      PB_CHAN_LCD_DATA
        jmp     bp

; ============================================================
; Donnees (ROM)
; ============================================================
; adresses 2^k (k = 0..16) en segment:offset
tab_adr:
%assign k 0
%rep 16
                dw      0000h, (1 << k)
%assign k k+1
%endrep
                dw      1000h, 0000h    ; 2^16 = 10000h
tab_adr_fin:

txt_titre:      db      'Test RAM 128K P:', 0                   ; + 4 chiffres = 20
txt_donnees:    db      'Donnees : ', 0
txt_adresses:   db      'Adresses: ', 0
txt_carte_vide: db      '----------------    ', 0
txt_vide10:     db      '          ', 0
                db      'RAMTEST128 sans RAM - VE2CUY - Solution-01', 0

; ============================================================
; Vecteur de reset (FFFF0h) et remplissage a 256 Ko
; ============================================================
        times   03FFF0h - ($-$$) db 0FFh
reset_vector:
        jmp     0C000h:start
        times   040000h - ($-$$) db 0FFh
