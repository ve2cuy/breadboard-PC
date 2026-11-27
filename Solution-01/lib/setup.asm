; ============================================================
; setup.asm - BIOS de REGLAGES (ROM 1.7, pont 2.2)
;
; Les reglages (16 octets) sont gardes par le pont STM32, dans la flash interne de la Black Pill (une
; "EEPROM" emulee: voir REGLAGES dans arduino/8088_bridge_stm32/src/main.cpp), lus au demarrage
; (commande 2Eh) dans VAR_SEG:CFG_OFF et reecrits par l'ecran de reglages (2Fh). Valeur 0 = defaut
; partout: une RAM effacee (bancs d'essai) ou un pont plus ancien (sans reponse) donnent le comportement
; d'avant la ROM 1.7.
;   CFG_OFF+0   version (1)
;   CFG_FLAGS   CFG_F_NO_LCD_BASIC (pas de console au LCD dans les BASIC), CFG_F_NO_LCD_DOS (dans le DOS),
;               CFG_F_NO_RAMB (pas de disque B: en RAM pour le DOS de la ROM), CFG_F_NO_DISKLED (temoin
;               d'acces au disque du pont eteint)
;   CFG_BOOT    0 menu, 1 GW-BASIC, 2 DOS 2.1 de la ROM, 3 disque C: (flash du pont)
;   CFG_SPLASH  duree de l'ecran d'accueil, 1-5 s (0 = 5 s, le defaut)
;   CFG_CLOCK   horloge du 8088 au demarrage du PONT (Hz, double mot; 0 = 4,77 MHz), appliquee par le pont
;   CFG_OK      (octet 15, propre au 8088, jamais envoye) 1 = le pont garde les reglages (pont 2.2+)
;
; Echap au demarrage (clavier PS/2 ou terminal; une touche tenue se repete) pendant l'ecran d'accueil:
; ecran de reglages, puis menu principal. Aussi: sous-menu Configuration, 5) BIOS.
; Contexte: celui du moniteur (DS = CS, SS = VAR_SEG).
; ============================================================

CFG_SETUP_N     equ     8               ; nombre de lignes de l'ecran de reglages

; ------------------------------------------------------------
; cfg_defaults: reglages par defaut (tout a 0 sauf la version et l'horloge). CFG_OK n'est pas touche.
; Preserve tout.
; ------------------------------------------------------------
cfg_defaults:
        push    ax
        push    bp
        mov     bp, CFG_OFF
        mov     word [bp], 0001h        ; version 1, drapeaux 0
        mov     word [bp+2], 0500h      ; demarrage: menu, accueil 5 s
        mov     word [bp+4], 0C8D0h     ; 4 770 000 Hz
        mov     word [bp+6], 0048h
        xor     ax, ax
        mov     [bp+8], ax
        mov     [bp+10], ax
        mov     [bp+12], ax
        mov     [bp+14], al
        pop     bp
        pop     ax
        ret

; ------------------------------------------------------------
; cfg_load: reglages du pont (2Eh) -> CFG_OFF; sans reponse (pont < 2.2) ou version inconnue: defauts,
; CFG_OK = 0. Preserve tout.
; ------------------------------------------------------------
cfg_load:
        push    ax
        call    cfg_bridge_get
        jc      .def
        cmp     byte [ss:CFG_OFF], 1
        jne     .def
        mov     byte [ss:CFG_OK], 1
        pop     ax
        ret
.def:
        call    cfg_defaults
        mov     byte [ss:CFG_OK], 0
        pop     ax
        ret

; ------------------------------------------------------------
; cfg_save: CFG_OFF -> pont (2Fh). CF = 1: pas enregistre (pont < 2.2 ou erreur). Preserve tout sauf F.
; ------------------------------------------------------------
cfg_save:
        push    ax
        cmp     byte [ss:CFG_OK], 1
        jne     .non
        call    cfg_bridge_put
        jc      .non
        or      al, al
        jnz     .non
        pop     ax
        clc
        ret
.non:
        pop     ax
        stc
        ret

; ------------------------------------------------------------
; boot_wait: ecran d'accueil (deja dessine): attend CFG_SPLASH secondes; CF = 1 si Echap a ete pressee
; (ecran de reglages demande). Les autres touches sont avalees. Preserve tout sauf F.
; ------------------------------------------------------------
boot_wait:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        print   txt_setup_hint, UART
        mov     al, [ss:CFG_SPLASH]
        or      al, al
        jnz     .s
        mov     al, 5
.s:
        mov     ah, 10                  ; pas de 100 ms
        mul     ah
        mov     si, ax
.t:
        delay_ms 100
        call    ps2_poll_char           ; (detruit AX-DX, jamais SI)
        jc      .n
        cmp     al, 27
        je      .esc
.n:
        dec     si
        jnz     .t
        clc
        jmp     .out
.esc:
        stc
.out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ------------------------------------------------------------
; lcd_console_basic: avant un BASIC (le menu l'appelle): CF = 0 et la console au LCD demandee au pont
; (2Dh) si elle est active dans les reglages; CF = 1 sinon (le menu dessine alors son ecran LCD).
; Preserve tout sauf F.
; ------------------------------------------------------------
lcd_console_basic:
        test    byte [ss:CFG_FLAGS], CFG_F_NO_LCD_BASIC
        jnz     .non
        push    ax
        mov     al, FS_LCD_CON
        call    bridge_tx
        pop     ax
        clc
        ret
.non:
        stc
        ret

; ------------------------------------------------------------
; boot_auto: demarrage choisi dans les reglages (CFG_BOOT). Revient pour "menu", a la sortie du BASIC
; ou si l'amorcage echoue (le menu principal suit). Preserve tout.
; ------------------------------------------------------------
boot_auto:
        push    ax
        mov     al, [ss:CFG_BOOT]
        cmp     al, 1
        jne     .b2
        call    run_gwbasic
        jmp     .r
.b2:
        cmp     al, 2
        jne     .b3
        call    dos_rom_boot            ; lib/bios.asm: ne revient qu'en cas d'echec
        jmp     .r
.b3:
        cmp     al, 3
        jne     .r
        print   txt_setup_bootc, UART
        push    ds
        mov     ax, VAR_SEG
        mov     ds, ax
        int     19h                     ; disque C: (aucune image montee au demarrage) - revient si echec
        pop     ds
.r:
        pop     ax
        ret

; ------------------------------------------------------------
; bios_setup: ecran de reglages. Terminal: toute la liste, redessinee a chaque touche; LCD: une ligne a la
; fois (fleches haut/bas pour la choisir). Touches: 1-8 changent la ligne (la suivante des valeurs),
; D = defauts, Entree = enregistrer et quitter, Echap = quitter sans rien changer. Preserve tout.
; ------------------------------------------------------------
bios_setup:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        mov     bp, CFG_OFF + 14        ; copie des 16 octets sur la pile (Echap les remet)
        mov     cx, 8
.sv:
        push    word [bp]
        sub     bp, 2
        loop    .sv
        mov     di, 1                   ; ligne montree au LCD
.redraw:
        call    setup_draw
.key:
        call    ps2_get_char
        cmp     al, 27
        je      .cancel
        cmp     al, 13
        je      .save
        cmp     al, 'D'
        jne     .k1
        call    cfg_defaults
        jmp     .redraw
.k1:
        cmp     al, PS2_KEY_UP
        jne     .k2
        dec     di
        jnz     .lcd
        mov     di, CFG_SETUP_N
        jmp     .lcd
.k2:
        cmp     al, PS2_KEY_DOWN
        jne     .k3
        inc     di
        cmp     di, CFG_SETUP_N
        jbe     .lcd
        mov     di, 1
.lcd:
        call    setup_lcd
        jmp     .key
.k3:
        cmp     al, '1'
        jb      .key
        cmp     al, '0' + CFG_SETUP_N
        ja      .key
        sub     al, '0'
        xor     ah, ah
        mov     di, ax
        call    setup_change
        jmp     .redraw
.save:
        call    cfg_save
        jnc     .saved
        print   txt_setup_nosave, UART
        call    i2c_lcd_init
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_setup_nosave, LCDI2C
        delay_ms (2*SECONDE)
        jmp     .keep
.saved:
        print   txt_setup_saved, UART
.keep:
        add     sp, 16                  ; les nouveaux reglages restent
        jmp     .out
.cancel:
        mov     bp, CFG_OFF
        mov     cx, 8
.rs:
        pop     word [bp]
        add     bp, 2
        loop    .rs
.out:
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; setup_change: DI = ligne (1-8): valeur suivante. Detruit AX, BX, SI.
setup_change:
        mov     bx, di
        cmp     bx, 4
        jne     .c5
        mov     al, [ss:CFG_BOOT]       ; demarrage: menu, GW-BASIC, DOS (ROM), C:
        inc     al
        and     al, 3
        mov     [ss:CFG_BOOT], al
        ret
.c5:
        cmp     bx, 5
        jne     .c6
        call    setup_clock_idx         ; horloge: la suivante de la table
        inc     bx
        cmp     bx, CLK_N
        jb      .c5b
        xor     bx, bx
.c5b:
        shl     bx, 1
        shl     bx, 1
        mov     ax, [cs:setup_clk_hz + bx]
        mov     [ss:CFG_CLOCK], ax
        mov     ax, [cs:setup_clk_hz + bx + 2]
        mov     [ss:CFG_CLOCK + 2], ax
        ret
.c6:
        cmp     bx, 6
        jne     .c8
        mov     al, [ss:CFG_SPLASH]     ; accueil: 1-5 s
        inc     al
        cmp     al, 5
        jbe     .c6b
        mov     al, 1
.c6b:
        mov     [ss:CFG_SPLASH], al
        ret
.c8:
        cmp     bx, 8
        jne     .flag
        jmp     clock_datetime_action   ; date et heure (ecran existant du sous-menu Configuration)
.flag:
        mov     al, [cs:setup_flag_bit + bx - 1]   ; 1, 2, 3, 7: drapeaux
        xor     [ss:CFG_FLAGS], al
        ret

; setup_clock_idx: BX = rang de CFG_CLOCK dans setup_clk_hz (4,77 MHz si absente). Detruit AX.
setup_clock_idx:
        xor     bx, bx
.l:
        mov     ax, [cs:setup_clk_hz + bx]
        cmp     ax, [ss:CFG_CLOCK]
        jne     .n
        mov     ax, [cs:setup_clk_hz + bx + 2]
        cmp     ax, [ss:CFG_CLOCK + 2]
        je      .f
.n:
        add     bx, 4
        cmp     bx, CLK_N * 4
        jb      .l
        mov     bx, CLK_DEF * 4
.f:
        shr     bx, 1
        shr     bx, 1
        ret

; setup_value: DI = ligne (1-8) -> SI = texte de sa valeur. Detruit AX, BX.
setup_value:
        mov     bx, di
        cmp     bx, 4
        jne     .v5
        mov     bl, [ss:CFG_BOOT]
        and     bx, 3
        shl     bx, 1
        mov     si, [cs:setup_boot_txt + bx]
        ret
.v5:
        cmp     bx, 5
        jne     .v6
        call    setup_clock_idx
        shl     bx, 1
        mov     si, [cs:setup_clk_txt + bx]
        ret
.v6:
        cmp     bx, 6
        jne     .v8
        mov     bl, [ss:CFG_SPLASH]
        or      bl, bl
        jnz     .v6b
        mov     bl, 5
.v6b:
        dec     bl
        and     bx, 7
        shl     bx, 1
        mov     si, [cs:setup_sec_txt + bx]
        ret
.v8:
        cmp     bx, 8
        jne     .vf
        mov     si, txt_setup_empty
        ret
.vf:
        mov     al, [cs:setup_flag_bit + bx - 1]
        mov     si, txt_setup_yes
        test    [ss:CFG_FLAGS], al
        jz      .r
        mov     si, txt_setup_no
.r:
        ret

; setup_draw: tout l'ecran (terminal) puis la ligne DI au LCD. Preserve DI.
setup_draw:
        push    di
        cls
        print   txt_setup_title, UART
        mov     di, 1
.l:
        mov     bx, di
        shl     bx, 1
        mov     si, [cs:setup_names + bx - 2]
        print   si, UART
        call    setup_value
        print   si, UART
        print   txt_setup_crlf, UART
        inc     di
        cmp     di, CFG_SETUP_N
        jbe     .l
        print   txt_setup_keys, UART
        cmp     byte [ss:CFG_OK], 1
        je      .ok
        print   txt_setup_old, UART
.ok:
        pop     di
        ; (suite: le LCD)
; setup_lcd: la ligne DI au LCD (titre, nom, valeur, touches). Preserve DI.
setup_lcd:
        call    i2c_lcd_init
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_setup_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        mov     bx, di
        shl     bx, 1
        mov     si, [cs:setup_lcd_names + bx - 2]
        print   si, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_setup_arrow, LCDI2C
        call    setup_value
        print   si, LCDI2C
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_setup_l4, LCDI2C
        ret

; ------------------------------------------------------------
; Tables et textes
; ------------------------------------------------------------
setup_flag_bit: db      CFG_F_NO_LCD_BASIC, CFG_F_NO_LCD_DOS, CFG_F_NO_RAMB, 0, 0, 0, CFG_F_NO_DISKLED
CLK_N           equ     8
CLK_DEF         equ     3               ; 4,77 MHz
setup_clk_hz:   dd      1000000, 2000000, 2340000, 4770000, 5000000, 7200000, 8000000, 10000000
setup_clk_txt:  dw      txt_clk_1, txt_clk_2, txt_clk_235, txt_clk_477, txt_clk_5, txt_clk_72, txt_clk_8, txt_clk_10
setup_sec_txt:  dw      txt_sec_1, txt_sec_2, txt_sec_3, txt_sec_4, txt_sec_5
setup_boot_txt: dw      txt_boot_menu, txt_boot_basic, txt_boot_dos, txt_boot_c
setup_names:    dw      txt_sn_1, txt_sn_2, txt_sn_3, txt_sn_4, txt_sn_5, txt_sn_6, txt_sn_7, txt_sn_8
setup_lcd_names: dw     lcd_txt_sn_1, lcd_txt_sn_2, lcd_txt_sn_3, lcd_txt_sn_4, lcd_txt_sn_5, lcd_txt_sn_6, lcd_txt_sn_7, lcd_txt_sn_8

txt_setup_crlf: db      13, 10, 0
txt_setup_empty: db     0
txt_sec_1:      db      '1 s', 0
txt_sec_2:      db      '2 s', 0
txt_sec_3:      db      '3 s', 0
txt_sec_4:      db      '4 s', 0
txt_sec_5:      db      '5 s', 0
txt_boot_basic: db      'GW-BASIC', 0
txt_boot_dos:   db      'DOS 2.1 (ROM)', 0
txt_clk_1:      db      '1 MHz', 0
txt_clk_2:      db      '2 MHz', 0
txt_clk_5:      db      '5 MHz', 0
txt_clk_8:      db      '8 MHz', 0
txt_clk_10:     db      '10 MHz', 0
lcd_txt_setup_arrow: db '> ', 0

%ifdef LANG_EN
txt_setup_hint: db      13, 10, 'Press ESC to enter the BIOS setup', 13, 10, 0
txt_setup_title: db     27, '[36m', '=== BIOS setup (kept by the bridge, flash of the Black Pill) ===', 27, '[0m', 13, 10, 13, 10, 0
txt_sn_1:       db      '  1) LCD console in BASIC ........... ', 0
txt_sn_2:       db      '  2) LCD console in DOS ............. ', 0
txt_sn_3:       db      '  3) RAM disk B: (DOS in ROM) ....... ', 0
txt_sn_4:       db      '  4) Boot ........................... ', 0
txt_sn_5:       db      '  5) 8088 clock at power-on ......... ', 0
txt_sn_6:       db      '  6) Splash screen .................. ', 0
txt_sn_7:       db      '  7) Disk activity LED (bridge) ..... ', 0
txt_sn_8:       db      '  8) Date and time', 0
txt_setup_keys: db      13, 10, '1-8: change   Up/Down: LCD line   D: defaults', 13, 10
                db      'Enter: save and exit   Esc: exit without saving', 13, 10, 0
txt_setup_old:  db      27, '[33m', 'The bridge does not keep the settings (bridge 2.2 needed): this session only.', 27, '[0m', 13, 10, 0
txt_setup_saved: db     13, 10, 'Settings saved.', 13, 10, 0
txt_setup_nosave: db    13, 10, 27, '[33m', 'Settings NOT saved (bridge 2.2 needed or write error): this session only.', 27, '[0m', 13, 10, 0
txt_setup_bootc: db     13, 10, 'Boot: disk C: (BIOS setup)', 13, 10, 0
txt_setup_yes:  db      'Yes', 0
txt_setup_no:   db      'No', 0
txt_boot_menu:  db      'Menu', 0
txt_boot_c:     db      'Disk C:', 0
txt_clk_235:    db      '2.34 MHz', 0
txt_clk_477:    db      '4.77 MHz', 0
txt_clk_72:     db      '7.2 MHz', 0
lcd_text lcd_txt_setup_l1, 'BIOS setup', 20
lcd_text lcd_txt_setup_hint, 'ESC: enter the BIOS', 20
lcd_text lcd_txt_setup_l4, 'Ent=save Esc=cancel', 20
lcd_text lcd_txt_setup_nosave, 'Not saved (bridge)', 20
lcd_text lcd_txt_sn_1, '1 LCD console BASIC', 20
lcd_text lcd_txt_sn_2, '2 LCD console DOS', 20
lcd_text lcd_txt_sn_3, '3 RAM disk B:', 20
lcd_text lcd_txt_sn_4, '4 Boot', 20
lcd_text lcd_txt_sn_5, '5 Clock at power-on', 20
lcd_text lcd_txt_sn_6, '6 Splash screen', 20
lcd_text lcd_txt_sn_7, '7 Disk LED', 20
lcd_text lcd_txt_sn_8, '8 Date and time', 20
%else
txt_setup_hint: db      13, 10, 'Appuyer sur ESC pour lancer le BIOS', 13, 10, 0
txt_setup_title: db     27, '[36m', '=== BIOS : reglages (gardes par le pont, flash de la Black Pill) ===', 27, '[0m', 13, 10, 13, 10, 0
txt_sn_1:       db      '  1) Console LCD dans le BASIC ...... ', 0
txt_sn_2:       db      '  2) Console LCD dans le DOS ........ ', 0
txt_sn_3:       db      '  3) Disque B: en RAM (DOS en ROM) .. ', 0
txt_sn_4:       db      '  4) Demarrage ...................... ', 0
txt_sn_5:       db      '  5) Horloge du 8088 au demarrage ... ', 0
txt_sn_6:       db      '  6) Ecran d', 27h, 'accueil ................ ', 0
txt_sn_7:       db      '  7) Temoin du disque (pont) ........ ', 0
txt_sn_8:       db      '  8) Date et heure', 0
txt_setup_keys: db      13, 10, '1-8 : changer   Haut/Bas : ligne du LCD   D : valeurs par defaut', 13, 10
                db      'Entree : enregistrer et quitter   Echap : quitter sans enregistrer', 13, 10, 0
txt_setup_old:  db      27, '[33m', 'Le pont ne garde pas les reglages (pont 2.2 requis) : pour cette session seulement.', 27, '[0m', 13, 10, 0
txt_setup_saved: db     13, 10, 'Reglages enregistres.', 13, 10, 0
txt_setup_nosave: db    13, 10, 27, '[33m', 'Reglages NON enregistres (pont 2.2 requis ou erreur d', 27h, 'ecriture) : pour cette session seulement.', 27, '[0m', 13, 10, 0
txt_setup_bootc: db     13, 10, 'Amorce : disque C: (reglages du BIOS)', 13, 10, 0
txt_setup_yes:  db      'Oui', 0
txt_setup_no:   db      'Non', 0
txt_boot_menu:  db      'Menu', 0
txt_boot_c:     db      'Disque C:', 0
txt_clk_235:    db      '2,34 MHz', 0
txt_clk_477:    db      '4,77 MHz', 0
txt_clk_72:     db      '7,2 MHz', 0
lcd_text lcd_txt_setup_l1, 'BIOS : reglages', 20
lcd_text lcd_txt_setup_hint, 'ESC: lancer le BIOS', 20
lcd_text lcd_txt_setup_l4, 'Ent=OK Echap=annul.', 20
lcd_text lcd_txt_setup_nosave, 'Non enregistre', 20
lcd_text lcd_txt_sn_1, '1 Console LCD BASIC', 20
lcd_text lcd_txt_sn_2, '2 Console LCD DOS', 20
lcd_text lcd_txt_sn_3, '3 Disque B: en RAM', 20
lcd_text lcd_txt_sn_4, '4 Demarrage', 20
lcd_text lcd_txt_sn_5, '5 Horloge au demar.', 20
lcd_text lcd_txt_sn_6, '6 Ecran accueil', 20
lcd_text lcd_txt_sn_7, '7 Temoin du disque', 20
lcd_text lcd_txt_sn_8, '8 Date et heure', 20
%endif
