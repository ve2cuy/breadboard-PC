; ============================================================
; uart.asm
; UART "relaye" via un Arduino externe (version Arduino - voir
; Directives.md), qui possede son propre UART MATERIEL (RX/TX reels,
; independants de l'horloge du 8088). REMPLACE l'ancienne
; transmission serie logicielle bit-bangue sur PA7 (voir git log pour
; l'historique de calibration UART_BIT_COUNT, desormais obsolete).
;
; TX (8088 -> Arduino -> UART materiel): uart_tx_byte passe l'octet a
; arduino_send (lib/common.asm) sur le canal PB_CHAN_UART - Port A du 8255
; en MODE 2, avec CONTROLE DE FLUX materiel (OBF#): plus de delai a
; calibrer, le 8088 attend simplement que l'Arduino ait lu l'octet
; precedent. Le meme canal transporte aussi les octets LCD (voir
; lib/lcd_i2c.asm), distingues par le canal.
;
; RX (Arduino -> 8088, via IRQ1): voir uart_rx_push/uart_rx_available/
; uart_rx_byte plus bas - rempli de facon ASYNCHRONE par
; irq1_arduino_handler (solution-01.asm) a chaque octet recu par
; l'UART materiel de l'Arduino (etiquette PC0=1 - un scan code clavier
; porte l'etiquette PC0=0 et va dans le tampon de lib/ps2.asm). Nouvelle
; capacite, pas encore consommee ailleurs dans ce projet.
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef UART_ASM
%define UART_ASM

%include "include/hardware.inc"
%include "lib/common.asm"

; ============================================================
; uart_tx_string / uart_tx_byte
; ============================================================
uart_tx_string:
        push    ax
        push    si
.next_char:
        mov     al, [si]
        cmp     al, 0
        je      .done
        call    uart_tx_byte
        inc     si
        jmp     .next_char
.done:
        pop     si
        pop     ax
        ret

; uart_tx_byte: envoie AL a l'Arduino (canal UART, voir arduino_send).
; Preserve tous les registres (BX y compris: test_segment y garde l'octet
; original pendant tout le cycle test-restauration).
uart_tx_byte:
        push    bx
        mov     bl, PB_CHAN_UART
        call    arduino_send
        pop     bx
        ret

; ============================================================
; uart_tx_hex_nibble / uart_tx_hex_byte / uart_tx_hex_word
; Affichent une valeur en hexadecimal (majuscules) via l'UART.
; Detruisent AX et BX (jamais CX/DX/SI/DI/ES/BP: sans danger a
; appeler depuis test_segment ou rom_dump au milieu d'une boucle).
; Generees par def_tx_hex_nibble/byte/word (lib/common.asm) - voir
; ce fichier pour la logique partagee avec lcd_tx_hex_* et
; i2c_lcd_tx_hex_*.
; ============================================================
def_tx_hex_nibble uart_tx_hex_nibble, uart_tx_byte
def_tx_hex_byte   uart_tx_hex_byte,   uart_tx_hex_nibble
def_tx_hex_word   uart_tx_hex_word,   uart_tx_hex_byte

; ============================================================
; uart_tx_bin_word
; Affiche AX en binaire (16 caracteres '0'/'1', MSB en premier) via
; l'UART - utilisee par registers_dump_action (solution-01.asm) pour
; completer l'affichage hexadecimal des registres.
; Entree: AX = mot a afficher.
; Detruit AX et BX (jamais CX/DX/SI/DI/ES/BP - meme discipline que
; uart_tx_hex_*, sauf que CX sert ici de compteur de boucle et doit
; donc etre explicitement sauvegarde/restaure).
; ============================================================
uart_tx_bin_word:
        push    cx
        mov     bx, ax          ; BX = copie du mot (AL/AH servent de scratch
                                 ; pour chaque caractere emis, un a la fois)
        mov     cx, 16          ; 16 bits a afficher
.bit_loop:
        mov     al, '0'
        test    bx, 8000h       ; teste le bit de poids fort courant
        jz      .bit_zero
        mov     al, '1'
.bit_zero:
        call    uart_tx_byte
        shl     bx, 1           ; le bit suivant devient le poids fort
        loop    .bit_loop
        pop     cx
        ret

; ============================================================
; uart_tx_bin20
; Affiche une adresse PHYSIQUE 20 bits en binaire (diagnostic
; materiel: le defaut d'adressage trouve sur VE2CUY touche
; specifiquement A16 - voir Directives.md - donc utile de voir ce
; bit d'un coup d'oeil): le nibble de poids fort (bits 19-16, depuis
; DX), un espace, puis les 16 bits de poids faible (bits 15-0, AX)
; via uart_tx_bin_word - 21 caracteres en tout, par ex.
; "0001 0001111011000000" pour 1000:EC00 (physique 11EC0h... - voir
; mem_calc_physical pour obtenir DX:AX a partir de SEGMENT:OFFSET).
; Entree: DX:AX = adresse physique (DX = bits 16-19 dans le nibble
; bas, le reste de DX est ignore).
; Detruit AX et BX (jamais CX/DX/SI/DI/ES/BP), meme discipline que
; uart_tx_hex_word/uart_tx_bin_word.
; ============================================================
uart_tx_bin20:
        push    ax              ; l'AX d'origine (bits 15-0) doit survivre au nibble
                                 ; de poids fort ci-dessous, qui utilise AL comme scratch
        push    cx
        mov     bx, dx
        mov     cx, 4
.nib:
        mov     al, '0'
        test    bx, 8h
        jz      .nib_zero
        mov     al, '1'
.nib_zero:
        call    uart_tx_byte
        shl     bx, 1
        loop    .nib
        mov     al, ' '
        call    uart_tx_byte
        pop     cx
        pop     ax
        call    uart_tx_bin_word        ; AX = bits 15-0 (intact depuis l'entree)
        ret

; ============================================================
; uart_tx_dec_word
; Affiche AX (0-65535) en decimal, SANS zeros de tete (meme esprit
; que uart_tx_dec8, mais sur 16 bits). Empile les chiffres au fur et
; a mesure de la division par 10 (poids faible d'abord), puis les
; depile: comme un POP rend le DERNIER chiffre empile (le plus
; significatif, puisque la division s'arrete des que le quotient
; est nul), l'affichage sort naturellement dans le bon ordre, sans
; avoir a compter les chiffres a l'avance ni a gerer les zeros de
; tete separement.
; Preserve tous les registres.
; ============================================================
uart_tx_dec_word:
        push    ax
        push    bx
        push    cx
        push    dx
        xor     cx, cx          ; CX = nombre de chiffres empiles (1-5)
.divloop:
        xor     dx, dx
        mov     bx, 10
        div     bx              ; AX = quotient, DX = reste (0-9)
        add     dl, '0'
        push    dx
        inc     cx
        or      ax, ax
        jnz     .divloop
.print_digit:
        pop     dx
        mov     al, dl
        call    uart_tx_byte
        loop    .print_digit
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; uart_tx_dec8 / uart_ansi_goto
; uart_tx_dec8: AL en decimal (0-255), SANS zeros de tete.
; uart_ansi_goto: positionne le curseur du terminal (sequence ANSI
; ESC [ ligne ; colonne H). Entree: DH = ligne, DL = colonne (1-based).
; Preservent tous les registres.
; ============================================================
uart_tx_dec8:
        push    ax
        push    bx
        push    cx
        xor     ah, ah
        mov     bl, 100
        div     bl              ; AL = centaines, AH = reste
        mov     cl, 0           ; CL = 1 des qu'un chiffre a ete emis
        mov     bh, ah          ; BH = reste (0-99)
        or      al, al
        jz      .tens
        add     al, '0'
        call    uart_tx_byte
        mov     cl, 1
.tens:
        mov     al, bh
        xor     ah, ah
        mov     bl, 10
        div     bl              ; AL = dizaines, AH = unites
        mov     bh, ah
        or      al, al
        jnz     .print_tens
        or      cl, cl
        jz      .units          ; pas de zero de tete
.print_tens:
        add     al, '0'
        call    uart_tx_byte
.units:
        mov     al, bh
        add     al, '0'
        call    uart_tx_byte
        pop     cx
        pop     bx
        pop     ax
        ret

uart_ansi_goto:
        push    ax
        mov     al, 27
        call    uart_tx_byte
        mov     al, '['
        call    uart_tx_byte
        mov     al, dh
        call    uart_tx_dec8
        mov     al, ';'
        call    uart_tx_byte
        mov     al, dl
        call    uart_tx_dec8
        mov     al, 'H'
        call    uart_tx_byte
        pop     ax
        ret

; ============================================================
; uart_rx_push / uart_rx_available / uart_rx_byte
; Tampon circulaire (256 octets, UART_RX_BUF_OFF - voir hardware.inc,
; tete=queue -> vide, 255 octets utiles) rempli de facon ASYNCHRONE par
; irq1_arduino_handler (solution-01.asm) a chaque octet UART recu
; de l'Arduino. Producteur (ISR)/consommateur (boucle
; principale) uniques - sans danger sans desactiver les interruptions
; (indices tete/queue d'un seul octet, lus/ecrits de facon atomique
; par rapport a une IRQ). Aucune detection de debordement (ecrase le
; plus ancien octet si le tampon est plein - acceptable pour ce genre
; de tampon, meme choix que ps2_rx_push, lib/ps2.asm).
;
; Consomme par ps2_get_char (lib/ps2.asm, uart_get_key): les touches
; tapees dans le terminal du PC valent celles du clavier PS/2.
; ============================================================
; uart_rx_push: AL = octet UART recu -> tampon. ISR seulement: DS = VAR_SEG (mis par l'ISR, jamais
; SS: le programme interrompu - un DOS - a sa propre pile). Preserve tout.
uart_rx_push:
        push    bx
        xor     bh, bh                  ; BX = index (BH arbitraire dans une ISR)
        mov     bl, [UART_RX_TAIL_OFF]  ; BL = queue actuelle
        mov     [UART_RX_BUF_OFF + bx], al      ; ecrit l'octet a la position queue
        inc     bl                      ; enroulement: BL est un octet (taille = 256)
        mov     [UART_RX_TAIL_OFF], bl
        pop     bx
        ret

; uart_rx_available: CF=0 si au moins un octet est disponible, CF=1
; si le tampon est vide - NE BLOQUE JAMAIS (contrairement a
; uart_rx_byte). Detruit AX. Jamais BX/CX/DX/SI/DI/ES/BP.
uart_rx_available:
        push    bp
        mov     bp, UART_RX_HEAD_OFF
        mov     al, [bp]
        mov     bp, UART_RX_TAIL_OFF
        cmp     al, [bp]
        pop     bp
        je      .empty
        clc
        ret
.empty:
        stc
        ret

; uart_rx_byte: BLOQUE (attente active) jusqu'a ce qu'un octet soit
; disponible, puis le retire et le retourne dans AL. Detruit AX
; seulement (BP preserve - ps2_get_char, qui l'appelle, ne doit jamais
; toucher BP).
uart_rx_byte:
        push    bp
        push    bx
        xor     bh, bh                  ; BX = index
.wait:
        call    uart_rx_available
        jc      .wait                   ; tampon vide - attend
        mov     bp, UART_RX_HEAD_OFF
        mov     al, [bp]                ; AL = tete actuelle
        mov     bl, al
        mov     bp, UART_RX_BUF_OFF
        add     bp, bx
        mov     al, [bp]                ; AL = octet a retourner
        inc     bl                      ; enroulement a 256 (octet)
        mov     bp, UART_RX_HEAD_OFF
        mov     [bp], bl
        pop     bx
        pop     bp
        ret

%endif ; UART_ASM
