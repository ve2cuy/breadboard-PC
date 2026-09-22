; ============================================================
; common.asm
; Code et donnees partages entre lcd.asm et uart.asm: porta_write
; (le seul point d'acces en ecriture au Port A du 8255, pour que le
; LCD et l'UART puissent cohabiter sur le meme octet sans se marcher
; sur les pieds - voir l'en-tete de solution-01.asm) et hex_table
; (utilisee par lcd_tx_hex_* ET uart_tx_hex_*).
;
; Inclus par lib/lcd.asm, lib/uart.asm ET solution-01.asm - garde
; requise pour eviter les symboles dupliques. Voir hardware.inc
; pour la regle des chemins d'%include (toujours relatifs a la
; racine de Solution-01).
; ============================================================
%ifndef COMMON_ASM
%define COMMON_ASM

%include "include/hardware.inc"

; ============================================================
; porta_write
; Ecrit sur le port A du 8255 en preservant tous les bits SAUF
; ceux indiques par le masque BL (lecture-modification-ecriture
; via une copie fantome en RAM, puisque le 8255 en mode 0 ne
; permet pas d'adresser un seul bit du port A - contrairement au
; port C, voir solution-02.asm). La copie fantome vit dans la zone
; deja reservee a la pile (PORTA_SHADOW_OFF, segment VAR_SEG) -
; largement hors de portee d'une pile qui, avec ce programme,
; n'utilise jamais plus de quelques dizaines d'octets.
;
; Entree: AL = nouveaux bits (seuls ceux couverts par BL comptent,
;         le reste de AL est ignore), BL = masque (1 = ce bit vient
;         de AL, 0 = ce bit est preserve depuis le dernier appel)
; Sortie: AL et BL inchanges (utile pour lcd_strobe, qui rappelle
;         porta_write plusieurs fois de suite avec le meme masque)
; ============================================================
porta_write:
        push    ax
        push    cx
        push    dx
        push    es
        push    di

        mov     cl, al          ; CL = nouveaux bits (bruts, non masques)

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, PORTA_SHADOW_OFF
        mov     dl, [es:di]     ; DL = copie fantome actuelle

        mov     ah, bl          ; AH = masque
        not     ah              ; AH = ~masque (bits a preserver)
        and     dl, ah          ; DL = etat precedent, bits du masque effaces

        mov     al, cl          ; AL = nouveaux bits (bruts)
        and     al, bl          ; AL = seulement les bits couverts par le masque
        or      al, dl          ; AL = combinaison finale

        mov     [es:di], al     ; met a jour la copie fantome
        out     PORTA, al       ; ecrit sur le port physique

        pop     di
        pop     es
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; arduino_send
; Envoie UN octet du 8088 vers l'Arduino (UART a emettre OU octet
; LCD a relayer en I2C) par le Port A du 8255 en MODE 2 (voir
; MASQUE_PIO, hardware.inc): pose d'abord le CANAL sur le Port B (l'Arduino
; le lit des qu'il voit OBF# bas), puis ecrit l'octet sur le Port A, ce qui
; met OBF# a 0 (PC7). L'Arduino lit l'octet en abaissant ACK#, ce qui
; remet OBF# a 1.
;
; CONTROLE DE FLUX (nouveau, le mode 2 le donne gratuitement): avant
; d'ecrire, on attend que OBF# soit a 1 (l'octet precedent a ete lu). Pour
; ne jamais bloquer le boot quand l'Arduino est absent/pas encore demarre:
;   - ARD_UNKNOWN (jamais vu consommer): attend jusqu'a ~3 s (l'Arduino
;     UNO met 1 a 2 s a demarrer apres un reset commun) - sinon les
;     premiers ecrans/lignes UART seraient perdus;
;   - ARD_ALIVE: attend ~0,5 s puis declare l'Arduino absent;
;   - ARD_ABSENT: n'attend plus du tout (l'octet ecrase le precedent,
;     perdu) jusqu'a ce qu'on revoie OBF# a 1.
; Le tour d'attente (CX=0 -> 65536 iterations de IN/TEST/LOOP, ~36 cycles
; chacune) dure ~0,5 s a 4,77 MHz.
;
; PUSHF/CLI/.../POPF autour des 2 ecritures (canal puis octet): arduino_send
; est aussi appelee depuis irq0_test_handler/int_not_implemented (via
; uart_tx_string) - sans cette protection, une telle IRQ pourrait
; s'intercaler entre les 2 OUT et changer le canal sous les pieds de
; l'appelant interrompu (un octet LCD partirait vers l'UART). POPF (pas STI):
; restaure IF a son etat exact d'avant l'appel.
;
; Entree: AL = octet, BL = canal (PB_CHAN_*)
; Sortie: tous les registres preserves (flags exceptes)
; ============================================================
arduino_send:
        push    ax
        push    cx
        push    dx
        push    di
        push    es

        mov     ah, al                  ; AH = octet a envoyer
        mov     cx, VAR_SEG
        mov     es, cx
        mov     di, ARD_TX_STATE_OFF

        in      al, PORTC
        test    al, PC_OBF_N
        jnz     .libre_entree           ; tampon de sortie libre: pas d'attente

        mov     al, [es:di]
        cmp     al, ARD_ABSENT
        je      .ecrire                 ; deja declare absent: on n'attend plus
        mov     dx, 1                   ; 1 tour (~0,5 s) si deja vu vivant
        cmp     al, ARD_UNKNOWN
        jne     .tour
        mov     dx, 6                   ; ~3 s: premier octet apres un reset
.tour:
        xor     cx, cx                  ; 65536 iterations
.attente:
        in      al, PORTC
        test    al, PC_OBF_N
        jnz     .vivant
        loop    .attente
        dec     dx
        jnz     .tour
        mov     byte [es:di], ARD_ABSENT
        jmp     .ecrire
.vivant:
        mov     byte [es:di], ARD_ALIVE
        jmp     .ecrire

.libre_entree:
        cmp     byte [es:di], ARD_ABSENT
        jne     .ecrire
        mov     byte [es:di], ARD_ALIVE ; il s'est remis a lire: de nouveau vivant

.ecrire:
        pushf
        cli
        mov     al, bl
        out     PORTB, al               ; canal AVANT l'octet
        mov     al, ah
        out     PORTA, al               ; l'octet - OBF# passe a 0
        popf

        pop     es
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; --- table de conversion hexadecimale (partagee LCD/UART) -------------
hex_table:              db      '0123456789ABCDEF'

; ============================================================
; def_tx_hex_nibble / def_tx_hex_byte / def_tx_hex_word
; Generateurs de procedures d'affichage hexadecimal (majuscules, via
; hex_table ci-dessus). La MEME logique etait auparavant dupliquee 3
; fois (LCD parallele, UART, LCD I2C), ne differant que par la
; procedure appelee pour emettre une unite (caractere pour nibble,
; nibble-proc pour byte, byte-proc pour word). Chaque macro GENERE
; une procedure complete (label + code + ret).
;
; Usage (voir lib/lcd.asm, lib/uart.asm, lib/lcd_i2c.asm):
;   def_tx_hex_nibble lcd_tx_hex_nibble, lcd_data
;   def_tx_hex_byte   lcd_tx_hex_byte,   lcd_tx_hex_nibble
;   def_tx_hex_word   lcd_tx_hex_word,   lcd_tx_hex_byte
;
; %1 = nom de la procedure a definir. %2 = procedure a appeler pour
; chaque unite.
; ============================================================
%macro def_tx_hex_nibble 2
%1:
        ; Entree: AL (4 bits utiles) = valeur 0-15 a afficher
        push    bx
        and     al, 0Fh
        mov     bl, al
        xor     bh, bh
        mov     al, [hex_table + bx]
        call    %2
        pop     bx
        ret
%endmacro

%macro def_tx_hex_byte 2
%1:
        ; Entree: AL = octet a afficher (2 caracteres hex)
        push    bx
        mov     bl, al          ; BL = copie de l'octet
        mov     al, bl
        shr     al, 1           ; 4x SHR reg,1: seul decalage disponible
        shr     al, 1           ; sur un vrai 8086/8088 (immediat != 1
        shr     al, 1           ; interdit avant le 80186)
        shr     al, 1           ; AL = nibble de poids fort
        call    %2
        mov     al, bl          ; AL = octet original (nibble de poids
        call    %2              ; faible - le AND est fait dans nibble)
        pop     bx
        ret
%endmacro

%macro def_tx_hex_word 2
%1:
        ; Entree: AX = mot a afficher (4 caracteres hex, octet fort en 1er)
        push    bx
        mov     bx, ax
        mov     al, bh
        call    %2
        mov     al, bl
        call    %2
        pop     bx
        ret
%endmacro

; ============================================================
; def_busy_delay
; Generateur de boucle d'attente active (dec bx/jnz) - motif
; identique utilise par lcd_short_delai/lcd_delay/lcd_delay_long
; (lib/lcd.asm), i2c_delay (lib/lcd_i2c.asm) et uart_bit_delay
; (lib/uart.asm), avec seul le nombre d'iterations qui change.
; %1 = nom de la procedure a definir, %2 = nombre d'iterations (BX)
; ============================================================
%macro def_busy_delay 2
%1:
        push    bx
        mov     bx, %2
%%d:
        dec     bx
        jnz     %%d
        pop     bx
        ret
%endmacro

%endif ; COMMON_ASM
