; ============================================================
; lcd_i2c.asm
; Deuxieme afficheur LCD (HD44780 derriere un expandeur I2C
; PCF8574, adresse 0x27 - "backpack" standard le plus courant, ex.
; "LCM1602 IIC").
; Le 8088 NE PARLE PLUS I2C DU TOUT depuis la version Arduino (voir
; Directives.md): c'est l'Arduino qui possede le bus I2C materiel (broches
; A4/A5 d'un UNO, cablees directement au module LCD) et qui traduit en
; I2C reel les octets que le 8088 lui relaie par le Port A du 8255 (mode 2,
; voir MASQUE_PIO, hardware.inc), via arduino_send (lib/common.asm):
;   - octet = commande OU donnee HD44780 complete (meme encodage
;     standard qu'avant: 01h=clear, 28h=function set, etc.)
;   - canal (Port B) = PB_CHAN_LCD_CMD (RS=0) ou PB_CHAN_LCD_DATA (RS=1)
;
; Le Port A est PARTAGE avec l'UART (canal PB_CHAN_UART, lib/uart.asm):
; un octet a la fois, le canal dit a l'Arduino ou l'envoyer. Ordre
; preserve: tout passe par la meme file cote Arduino.
;
; L'Arduino possede TOUTE la logique auparavant ici: la sequence de
; demarrage 4 bits du HD44780 (0011b x3 puis 0010b), le decoupage d'un
; octet en 2 quartets + impulsions EN, le protocole I2C (START/adresse/
; ACK/STOP) et les delais d'execution du controleur (37-43us, 1,52ms
; pour Clear/Home): le 8088 n'a plus aucun delai a respecter ici - le
; controle de flux OBF# (arduino_send) l'arrete si l'Arduino prend du
; retard. Seul le codage standard des commandes/donnees HD44780 survit
; cote 8088, via i2c_lcd_command/i2c_lcd_data ci-dessous.
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef LCD_I2C_ASM
%define LCD_I2C_ASM

%include "include/hardware.inc"
%include "lib/common.asm"
%include "lib/lcd.asm"          ; plus utilise ici (delais desormais cote Arduino);
                                 ; garde pour les modules qui en dependent encore

I2C_LCD_RS      equ     1               ; flag LOGIQUE (pas un bit materiel du
                                         ; 8255): 0 = commande, 1 = donnee - voir
                                         ; i2c_lcd_send_byte pour la conversion
                                         ; vers le canal PB_CHAN_LCD_*

; ============================================================
; i2c_lcd_send_byte
; Envoie un octet complet (commande ou donnee) a l'Arduino via
; arduino_send, qui l'ecrit au LCD par son propre bus I2C. Jamais
; appele directement ailleurs que par i2c_lcd_command/i2c_lcd_data.
; Entree: AL = octet complet. BL bit0 = RS voulu (0 = commande,
; I2C_LCD_RS = donnee).
; Sortie: tous les registres preserves.
; ============================================================
i2c_lcd_send_byte:
        push    bx
        test    bl, I2C_LCD_RS
        mov     bl, PB_CHAN_LCD_CMD     ; MOV ne modifie pas les flags
        jz      .envoi
        mov     bl, PB_CHAN_LCD_DATA
.envoi:
        call    arduino_send
        pop     bx
        ret

; ============================================================
; i2c_lcd_command / i2c_lcd_data
; Envoient un octet complet au LCD I2C (voir i2c_lcd_send_byte). Aucun
; delai ici: l'Arduino respecte les temps d'execution du HD44780 (voir
; l'en-tete du fichier).
; Entree: AL = octet a envoyer. lcd_command: RS=0. lcd_data: RS=1.
; ============================================================
i2c_lcd_command:
        push    bx
        mov     bl, 0
        call    i2c_lcd_send_byte
        pop     bx
        ret

i2c_lcd_data:
        push    bx
        mov     bl, I2C_LCD_RS
        call    i2c_lcd_send_byte
        pop     bx
        ret

; ============================================================
; i2c_lcd_print
; Affiche une chaine terminee par 00h (pas de padding). Entree: DS:SI.
; ============================================================
i2c_lcd_print:
        push    ax
        push    si
.next_char:
        mov     al, [si]
        cmp     al, 0
        je      .done
        call    i2c_lcd_data
        inc     si
        jmp     .next_char
.done:
        pop     si
        pop     ax
        ret

; ============================================================
; i2c_lcd_tx_hex_nibble / i2c_lcd_tx_hex_byte
; Affiche une valeur en hexadecimal majuscule. Generees par
; def_tx_hex_nibble/byte (lib/common.asm) - voir ce fichier pour la
; logique partagee avec lcd_tx_hex_* et uart_tx_hex_*.
;
; Positionnement DDRAM (i2c_lcd_line1..4/i2c_lcd_show_line1..4
; d'origine): voir les macros i2c_lcd_goto/i2c_lcd_show dans
; include/lcd_macros.inc.
; ============================================================
def_tx_hex_nibble i2c_lcd_tx_hex_nibble, i2c_lcd_data
def_tx_hex_byte   i2c_lcd_tx_hex_byte,   i2c_lcd_tx_hex_nibble
def_tx_hex_word   i2c_lcd_tx_hex_word,   i2c_lcd_tx_hex_byte

; ============================================================
; i2c_lcd_tx_dec3
; Affiche AX (0-999) en decimal, TOUJOURS 3 chiffres avec des zeros
; de tete (ex: 7 -> "007") - copie exacte de lcd_tx_dec3 (lib/lcd.asm),
; seule la procedure d'emission d'un caractere change (i2c_lcd_data au
; lieu de lcd_data). Detruit AX/BX/CX/DX - jamais SI/DI/ES/BP (meme
; discipline que lcd_tx_dec3/les routines hex).
; ============================================================
i2c_lcd_tx_dec3:
        push    bx
        push    cx
        push    dx

        xor     dx, dx
        mov     bx, 100
        div     bx              ; AX = centaines, DX = reste (0-99)
        mov     cl, al          ; CL = chiffre des centaines

        mov     ax, dx
        xor     dx, dx
        mov     bx, 10
        div     bx              ; AX = dizaines, DX = unites
        mov     ch, dl          ; CH = chiffre des unites
        mov     bh, al          ; BH = chiffre des dizaines

        mov     al, cl
        add     al, '0'
        call    i2c_lcd_data    ; centaines
        mov     al, bh
        add     al, '0'
        call    i2c_lcd_data    ; dizaines
        mov     al, ch
        add     al, '0'
        call    i2c_lcd_data    ; unites

        pop     dx
        pop     cx
        pop     bx
        ret

; ============================================================
; i2c_lcd_init
; Ecran "propre" pour le menu/une action - N'INITIALISE PLUS le
; controleur HD44780 (la sequence de demarrage, y compris le mode 4 bits
; AVANT que le controleur comprenne un octet complet, vit dans le setup()
; de l'Arduino). Renvoie les commandes standard de remise en etat par le
; meme canal que i2c_lcd_command (Function Set/Display ON/Entry Mode/
; Clear) - inoffensif si superflu.
; ============================================================
i2c_lcd_init:
        push    ax

        mov     al, 00101000b          ; Function Set: 4 bits, 2 lignes, police 5x8
        call    i2c_lcd_command

        mov     al, 00001100b          ; Display ON, curseur off, blink off
        call    i2c_lcd_command

        mov     al, 00000110b          ; Entry Mode: incremente, pas de decalage
        call    i2c_lcd_command

        mov     al, 00000001b          ; Clear Display (l'Arduino attend les 1,52ms)
        call    i2c_lcd_command

        pop     ax
        ret

%endif ; LCD_I2C_ASM
