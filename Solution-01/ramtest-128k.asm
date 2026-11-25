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
;       SP = bits de donnees fautifs CUMULES (octet bas) et puces deja vues
;            fautives (octet haut: bit 0 = 8255, bit 1 = 8259), toutes passes
;     pendant une passe: DX = carte des blocs fautifs de la passe, BH = bits
;     fautifs de la passe (tests des blocs), BP = masque du bloc courant.
;   Les chaines sont lues dans la ROM par CS: (DS n'est pas un segment de donnees).
;
; Chaque passe (en boucle, sans fin):
;   0. puces (BL = defauts DEF_*):
;      8255: relecture du port B (verrou de sortie, motifs de tab_motifs) - le pont
;            ne lit le canal que si un octet attend (OBF# = 0): on attend OBF# = 1 et
;            on remet 0 ensuite; INTE1/INTE2 relus dans le mot d'etat du mode 2 (bits
;            6 et 4); INTR (bit 3) doit suivre INTE1 (OBF# = 1, ACK# au repos).
;      8259: programme en mode NIVEAU (ICW1 1Bh, ICW2 08h, ICW4 01h - aucune IRQ n'est
;            servie: IF = 0 et IMR = FFh), relecture de l'IMR (OCW1), ISR = 0.
;      liaison INTR du 8255 -> IR1 du 8259: bit 1 de l'IRR a 1 avec INTE1 = 1, a 0
;            avec INTE1 = INTE2 = 0 (mode niveau: l'IRR suit l'entree).
;      Avant chaque relecture d'un registre (port B, IMR): lecture "leurre" du
;      complement dans la ROM, pour qu'une puce absente (bus flottant) ne renvoie
;      pas la valeur qu'on vient d'ecrire. Le tampon d'entree du 8255 (frappes du
;      clavier, jamais lues ici) est vide a chaque passe.
;      1re passe: ecran de detail pendant ~3 s, puis l'ecran de la RAM.
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
; Affichage (LCD 20x4), 1re passe - detail des puces (~3 s):
;   "8255 port B : OK"      ou "KO 3C" (bits du port B relus faux)
;   "8255 INTE OK INTR OK"  bits INTE1/INTE2 relus, sortie INTR du 8255
;   "8259 IMR OK ISR OK"    IMR: OK ou les bits relus faux (hex); ISR: OK = 0
;   "IR1 8255>8259 : OK"    INTR du 8255 vu sur IR1 du 8259 (IRR)
; puis, a chaque passe:
;   ligne 1  "0001 8255:OK 8259:OK"   passe; puces: OK, KO (cette passe), !! (une
;                                      passe precedente seulement). IR1 compte pour le 8259.
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

; --- 8259 (mode niveau pour lire l'IRR tel quel), OCW3, bits du 8255 en mode 2 ---
ICW1_NIVEAU     equ     00011011b       ; ICW1, LTIM = 1 (niveau), seul, ICW4
ICW2_BASE       equ     08h
ICW4_8086       equ     01h
OCW3_IRR        equ     00001010b       ; lecture de l'IRR sur 20h
OCW3_ISR        equ     00001011b       ; lecture de l'ISR sur 20h
PIO_INTE1_SET   equ     00001101b       ; PC6 = 1
PIO_INTE2_RESET equ     00001000b       ; PC4 = 0
ST_INTE1        equ     40h             ; mot d'etat (Port C, mode 2)
ST_INTE2        equ     10h
ST_INTR         equ     08h
; --- defauts des puces (BL) ---
DEF_8255_B      equ     01h             ; port B relu faux
DEF_8255_INTE   equ     02h             ; INTE1/INTE2 relus faux
DEF_8255_INTR   equ     04h             ; INTR ne suit pas INTE1
DEF_8259_IMR    equ     08h             ; IMR relu faux
DEF_8259_ISR    equ     10h             ; ISR non nul
DEF_IR1         equ     20h             ; INTR du 8255 pas vu sur IR1 (ou colle)
DEF_8255        equ     DEF_8255_B | DEF_8255_INTE | DEF_8255_INTR
DEF_8259        equ     DEF_8259_IMR | DEF_8259_ISR | DEF_IR1

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

; --- OKKO: "OK" si (BL & %1) = 0, sinon "KO". Detruit AX, CX (preserve BX, DX). ---
%macro OKKO 1
        test    bl, %1
        jnz     %%ko
        LCD_CHR 'O'
        LCD_CHR 'K'
        jmp     %%fin
%%ko:
        LCD_CHR 'K'
        LCD_CHR 'O'
%%fin:
%endmacro

; --- CHAMP: etat d'une puce sur la ligne 1: "KO" (BL & %1, cette passe), sinon "!!" si
; --- deja vue fautive (bit %2 de l'octet haut de SP), sinon "OK". Detruit AX, CX. ---
%macro CHAMP 2
        test    bl, %1
        jnz     %%ko
        mov     ax, sp
        test    ah, %2
        jnz     %%avant
        LCD_CHR 'O'
        LCD_CHR 'K'
        jmp     %%fin
%%avant:
        LCD_CHR '!'
        LCD_CHR '!'
        jmp     %%fin
%%ko:
        LCD_CHR 'K'
        LCD_CHR 'O'
%%fin:
%endmacro

; --- RELIT: ecrit les motifs de tab_motifs sur le port %1 et OR dans %2 les bits relus
; --- faux. Avant chaque IN: lecture leurre du complement dans la ROM (bus flottant).
; --- Detruit AX, SI. ---
%macro RELIT 2
        mov     si, tab_motifs
%%motif:
        mov     al, [cs:si]
        out     %1, al
        mov     ah, al
        mov     al, [cs:si + (tab_inverses - tab_motifs)]       ; leurre
        in      al, %1
        xor     al, ah
        or      %2, al
        inc     si
        cmp     si, tab_motifs_fin
        jb      %%motif
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

; ============================================================
passe:
        mov     ax, ds
        cmp     ax, 9999
        jae     .puces
        inc     ax
        mov     ds, ax

; ------------------------------------------------------------
; 0. Puces: BL = defauts (DEF_*), BH = bits du port B relus faux, DL = bits de l'IMR relus faux
; ------------------------------------------------------------
.puces:
        in      al, PORTC               ; frappe du clavier en attente (IBF): lue et jetee
        test    al, PC_IBF
        jz      .p_obf_debut
        in      al, PORTA
.p_obf_debut:
        xor     cx, cx                  ; le pont a-t-il lu le dernier octet? (OBF# = 1)
.p_obf:
        in      al, PORTC
        test    al, PC_OBF_N
        jnz     .p_libre
        loop    .p_obf
.p_libre:
        xor     bx, bx
        xor     dl, dl

        ; --- 8255: port B (canal) relu ---
        RELIT   PORTB, bh
        xor     al, al
        out     PORTB, al               ; canal 0 au repos
        or      bh, bh
        jz      .p_8259
        or      bl, DEF_8255_B

        ; --- 8259: programmation (mode niveau), IMR relu, ISR = 0 ---
.p_8259:
        mov     al, ICW1_NIVEAU
        out     PIC_CMD, al
        mov     al, ICW2_BASE
        out     PIC_DATA, al
        mov     al, ICW4_8086
        out     PIC_DATA, al
        RELIT   PIC_DATA, dl
        mov     al, 0FFh
        out     PIC_DATA, al            ; tout masque
        or      dl, dl
        jz      .p_isr
        or      bl, DEF_8259_IMR
.p_isr:
        mov     al, OCW3_ISR
        out     PIC_CMD, al
        in      al, PIC_CMD
        or      al, al
        jz      .p_inte
        or      bl, DEF_8259_ISR

        ; --- 8255 INTE1 = 1, INTE2 = 0: etat 40h (INTE1), INTR = 1; IR1 du 8259 = 1 ---
.p_inte:
        mov     al, PIO_INTE2_RESET
        out     PIO, al
        mov     al, PIO_INTE1_SET
        out     PIO, al
        in      al, PORTC
        mov     ah, al
        and     al, ST_INTE1 | ST_INTE2
        cmp     al, ST_INTE1
        je      .p_intr1
        or      bl, DEF_8255_INTE
.p_intr1:
        test    ah, ST_INTR
        jnz     .p_irr1
        or      bl, DEF_8255_INTR
.p_irr1:
        mov     al, OCW3_IRR
        out     PIC_CMD, al
        in      al, PIC_CMD
        test    al, 02h
        jnz     .p_inte2
        or      bl, DEF_IR1

        ; --- INTE1 = 0, INTE2 = 1: etat 10h; INTR = 0 et IR1 = 0, sauf si une frappe vient
        ; --- d'arriver (IBF = 1: INTR = INTE2 et IBF) - verification sautee dans ce cas ---
.p_inte2:
        mov     al, PIO_INTE1_RESET
        out     PIO, al
        mov     al, PIO_INTE2_SET
        out     PIO, al
        in      al, PORTC
        mov     ah, al
        and     al, ST_INTE1 | ST_INTE2
        cmp     al, ST_INTE2
        je      .p_intr0
        or      bl, DEF_8255_INTE
.p_intr0:
        test    ah, PC_IBF
        jnz     .p_fin
        test    ah, ST_INTR
        jz      .p_irr0
        or      bl, DEF_8255_INTR
.p_irr0:
        mov     al, OCW3_IRR
        out     PIC_CMD, al
        in      al, PIC_CMD
        test    al, 02h
        jz      .p_fin
        or      bl, DEF_IR1
.p_fin:
        mov     al, PIO_INTE2_RESET     ; INTE1 = INTE2 = 0: plus d'INTR
        out     PIO, al

        ; --- 1re passe: ecran de detail des puces (~3 s), puis l'ecran de la RAM ---
        mov     ax, ds
        cmp     ax, 1
        jne     .ligne1
        LCD_CMD 01h
        PRINT_AT LCD_L1, txt_p_portb
        test    bl, DEF_8255_B
        jnz     .d_portb_ko
        OKKO    DEF_8255_B
        jmp     .d_l2
.d_portb_ko:
        LCD_CHR 'K'
        LCD_CHR 'O'
        LCD_CHR ' '
        mov     al, bh
        CALLR   lcd_hex8
.d_l2:
        PRINT_AT LCD_L2, txt_p_inte
        OKKO    DEF_8255_INTE
        PRINT_AT (LCD_L2 + 13), txt_p_intr
        OKKO    DEF_8255_INTR
        PRINT_AT LCD_L3, txt_p_imr
        test    bl, DEF_8259_IMR
        jz      .d_imr_ok
        mov     al, dl
        CALLR   lcd_hex8
        jmp     .d_isr
.d_imr_ok:
        OKKO    DEF_8259_IMR
.d_isr:
        PRINT_AT (LCD_L3 + 11), txt_p_isr
        OKKO    DEF_8259_ISR
        PRINT_AT LCD_L4, txt_p_ir1
        OKKO    DEF_IR1
        mov     si, 12                  ; ~3 s a 4,77 MHz (12 x 65536 tours de LOOP)
.d_attente:
        xor     cx, cx
.d_attente2:
        loop    .d_attente2
        dec     si
        jnz     .d_attente
        LCD_CMD 01h
        PRINT_AT LCD_L1, txt_ligne1
        PRINT_AT LCD_L2, txt_donnees
        PRINT_AT LCD_L3, txt_adresses
        PRINT_AT LCD_L4, txt_carte_vide

        ; --- ligne 1: etat des puces (avant le cumul), cumul dans l'octet haut de SP, passe ---
.ligne1:
        LCD_CMD (80h | (LCD_L1 + 10))
        CHAMP   DEF_8255, 1
        LCD_CMD (80h | (LCD_L1 + 18))
        CHAMP   DEF_8259, 2
        mov     ax, sp
        test    bl, DEF_8255
        jz      .cumul_8259
        or      ah, 1
.cumul_8259:
        test    bl, DEF_8259
        jz      .cumul_fin
        or      ah, 2
.cumul_fin:
        mov     sp, ax
        LCD_CMD (80h | LCD_L1)
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

; motifs relus sur le port B et l'IMR, et leurs complements (lectures leurres)
tab_motifs:     db      00h, 0FFh, 55h, 0AAh, 01h, 02h, 04h, 08h, 10h, 20h, 40h, 80h
tab_motifs_fin:
tab_inverses:   db      0FFh, 00h, 0AAh, 55h, 0FEh, 0FDh, 0FBh, 0F7h, 0EFh, 0DFh, 0BFh, 7Fh

txt_ligne1:     db      '0000 8255:-- 8259:--', 0
txt_p_portb:    db      '8255 port B : ', 0                     ; + OK ou KO xx
txt_p_inte:     db      '8255 INTE ', 0                         ; + OK, puis INTR en colonne 13
txt_p_intr:     db      'INTR ', 0
txt_p_imr:      db      '8259 IMR ', 0                          ; + OK ou bits (hex), puis ISR
txt_p_isr:      db      ' ISR ', 0
txt_p_ir1:      db      'IR1 8255>8259 : ', 0
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
