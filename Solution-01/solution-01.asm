BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; solution-01.asm
; nasm -f bin solution-01.asm -o Z:\Partage\Alain\solution-01.bin
; (voir aussi le Makefile: "make rom" fait la meme chose et copie
; le resultat vers Z:\Partage\Alain\rom.bin)
; ------------------------------------------------------------
; VARIANTE DE ram_test_uart_7.asm: elimine completement le latch
; externe (et son decodage d'adresse) en deplacant le signal UART
; sur PA7 - le meme port que le LCD (Port A du 8255).
;
; PROBLEME: en mode 0, le 8255 n'adresse PAS les bits du port A
; individuellement - un OUT ecrit les 8 bits en meme temps. Le LCD
; (D4-D7, RS, E sur PA0-PA4/PA6) et l'UART (PA7) doivent donc
; cohabiter sur le MEME octet. Solution: une copie "fantome" de
; l'etat du port A est gardee en RAM (PORTA_SHADOW - impossible en
; ROM, qui est en lecture seule), et CHAQUE ecriture - LCD ou UART -
; passe par porta_write, qui ne modifie QUE les bits qui la
; concernent et preserve les autres via un lecture-modification-
; ecriture (voir lib/common.asm). La ligne UART reste donc a son
; dernier etat (idle ou en cours de bit) meme quand le LCD ecrit, et
; vice-versa.
;
; La copie fantome vit dans la zone deja reservee a la pile (voir
; test_ram plus bas) - donc AUCUN octet en plus n'est retire du
; test RAM.
;
; IMPORTANT - init_8255 sorti de la boucle principale: un mot de
; mode du 8255 (comme celui envoye par init_8255) remet TOUS les
; verrous de sortie a 0, y compris le port A au complet (LCD ET
; UART). Comme ce mot n'a besoin d'etre envoye qu'une seule fois
; (le mode ne change jamais ensuite), init_8255 est maintenant
; appele UNE SEULE FOIS avant la boucle .ici, pas a chaque cycle -
; sinon la ligne UART retomberait a 0 (condition de break) a
; chaque nouveau cycle, le temps que le LCD la remette par hasard
; au bon etat via un premier appel a lcd_strobe.
;
; Cablage LCD (Port A du 8255, PA0-PA7): identique a lcd_hello_6.asm
;   PA0-PA3 -> D4-D7, PA4 -> RS, PA6 -> E, R/W du LCD a la masse.
;   PA7 -> UART (remplace le latch/74LS373 externe).
;
; LCD 4x20 (remplace le 2x16 d'origine). Adressage DDRAM utilise
; pour les lignes 3/4 (convention standard des afficheurs 20x4 base
; sur le HD44780: la ligne 3 est en fait la suite de la ligne 1 en
; memoire interne, et la ligne 4 la suite de la ligne 2):
; ligne1=00h, ligne2=40h, ligne3=14h, ligne4=54h ("type A" - si le
; texte des lignes 3/4 apparait au mauvais endroit sur ton module,
; il existe une variante moins courante 00h/20h/40h/60h a essayer).
; Le Function Set (00101000b: 4 bits, N=1) ne change PAS: le HD44780
; ne connait que le mode "1 ligne" ou "2 lignes" en interne.
;
; ------------------------------------------------------------
; STRUCTURE DU PROJET (voir Directives.md):
;   solution-01.asm       - ce fichier: flux principal (start, test
;                            RAM, dump ROM, animation 8255) + toutes
;                            les donnees/textes.
;   include/hardware.inc  - constantes materielles partagees (8255,
;                            adresses RAM des variables partagees).
;   include/delay.inc     - macro delay_ms.
;   lib/common.asm        - porta_write + hex_table (partages LCD/UART).
;   lib/lcd.asm           - toutes les procedures d'affichage LCD.
;   lib/uart.asm          - toutes les procedures de transmission UART.
;   lib/utils.asm         - delay_ms_proc (routine derriere la macro).
;
; Tous les %include de ce fichier (et de ceux de ./lib) sont ecrits
; comme des chemins relatifs a CETTE racine (Solution-01/) - voir
; la note dans include/hardware.inc. Le Makefile lance toujours nasm
; depuis cette racine, meme pour assembler un module seul.
; ------------------------------------------------------------
STACK_SEG       equ     1000h

SECONDE         equ     1000            ; 1 seconde = 1000 ms

; ------------------------------------------------------------
; TEST_PS2 (decommenter la ligne %define ci-dessous pour activer):
; diagnostic du clavier PS/2 decode par l'Arduino (voir lib/ps2.asm,
; PS2_RX_BUF_OFF/irq1_arduino_handler - depuis la version Arduino, le
; 8088 ne decode plus le protocole CLOCK/DATA lui-meme) - REMPLACE le
; menu interactif par une boucle infinie qui affiche sur l'UART le
; scan code BRUT (Set 2, sans traduction) de chaque octet recu. Utile
; pour verifier la chaine Arduino->IRQ1->tampon independamment de la
; couche de traduction clavier->ASCII (ps2_get_char) utilisee par le
; menu. Desactive par defaut (le menu, qui utilise deja le clavier via
; ps2_get_char, est le comportement normal - voir Directives.md).
; %define TEST_PS2
; ------------------------------------------------------------

%macro cls 0
        print   CLS, UART       ; efface l'ecran du terminal (ANSI)
%endmacro

; --- ascii_or_dot: remplace AL par '.' s'il n'est pas imprimable
; --- (< 20h ou > 7Eh) - motif utilise par le dump ASCII UART
; --- (dump_line) ET le dump ASCII du LCD I2C (i2c_dump_hex_ascii8_line),
; --- auparavant duplique dans les 2 routines. ---
%macro ascii_or_dot 0
        cmp     al, 20h
        jb      %%not_printable
        cmp     al, 7Eh
        ja      %%not_printable
        jmp     %%print_char
%%not_printable:
        mov     al, '.'
%%print_char:
%endmacro

; --- lcd_text: definit un texte LCD complete a une largeur fixe par
; --- des espaces, puis termine par 0 - motif utilise ~15 fois dans
; --- la section donnees ci-dessous (textes des 4 lignes du LCD 4x20).
; --- %1=etiquette, %2='texte' (chaine, eventuellement vide ''),
; --- %3=largeur visible (SANS compter le terminateur 0 ajoute apres). ---
%macro lcd_text 3
%1:             db      %2
                times   %3-($-%1) db ' '
                db      0
%endmacro

; --- uart_flag_bit: affiche via l'UART le mnemonique DEBUG.COM (2
; --- lettres) correspondant a UN bit du registre FLAGS - utilise 8
; --- fois par registers_dump_action pour le decodage "ergonomique"
; --- des FLAGS (ordre classique OF DF IF SF ZF AF PF CF). Le
; --- mnemonique "actif" (bit=1) est colore en jaune pour ressortir a
; --- l'oeil; le mnemonique "inactif" (bit=0) reste en couleur par
; --- defaut du terminal - voir les paires txt_flag_*_set/clear plus
; --- bas dans la section donnees. Chaque etiquette inclut deja un
; --- espace de separation final (voir leur definition).
; --- %1=masque (mot), %2=etiquette si le bit est a 1, %3=etiquette
; --- si le bit est a 0. DX DOIT deja contenir le mot FLAGS a decoder
; --- (charge une seule fois par l'appelant, avant la 1ere invocation). ---
%macro uart_flag_bit 3
        test    dx, %1
        jz      %%is_clear
        print   %2, UART
        jmp     %%done
%%is_clear:
        print   %3, UART
%%done:
%endmacro

%include "include/hardware.inc"
%include "include/delay.inc"
%include "include/lcd_macros.inc"

start:
        cli                     ; pas d'interruption pendant l'init de SS:SP
        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM (128K)
        mov     sp, 0000h       ; SP = 0000h -> sommet de la pile, remis a zero
                                 ; a CHAQUE cycle
                                 ; PAS de STI ici: les interruptions restent coupees
                                 ; jusqu'au STI qui suit init_8259 (plus bas). Apres un
                                 ; redemarrage a chaud (Ctrl-\, lib/isr.asm) le 8259 est
                                 ; encore programme, IR1 demasquee: une frappe pendant
                                 ; l'effacement de la RAM ci-dessous (qui met l'IVT a 0)
                                 ; ferait sauter le 8088 en 0000:0000.

        ; --- Efface TOUTE la RAM (128K: segments 0000h et 1000h) a 0,
        ; AVANT quoi que ce soit d'autre - elimine le "garbage"
        ; residuel visible dans les dumps memoire (RAM statique sans
        ; valeur garantie a la mise sous tension). ECRIT EN LIGNE (pas
        ; de CALL): le segment 1000h contient la pile deja active
        ; (SS/SP ci-dessus) - un retour d'appel qui s'y trouverait
        ; serait efface par erreur. Sans risque ICI puisque rien n'a
        ; encore ete empile a ce stade. AX reste a 0 (valeur de
        ; remplissage de "rep stosw") tout du long - CX sert de
        ; registre de transfert pour le 2e segment. ---
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     cx, 8000h       ; 32768 mots = 65536 octets (segment 0000h)
        rep     stosw
        mov     cx, STACK_SEG   ; CX = transfert (AX doit rester a 0)
        mov     es, cx
        xor     di, di
        mov     cx, 8000h       ; segment 1000h (STACK_SEG/VAR_SEG)
        rep     stosw

        ; --- Valeur par defaut de CLOCK_FREQ_HZ_OFF (VAR_SEG), affichee au
        ; menu principal AVANT toute visite du sous-menu Configuration/Clock
        ; speed: correspond a la frequence PAR DEFAUT du pont a SON PROPRE
        ; demarrage (clockSetup(), voir arduino/8088_bridge_stm32/src/main.cpp)
        ; - mise a jour ensuite a la VRAIE valeur des que clock_show
        ; interroge le pont. ES = VAR_SEG ici (mov es,cx juste au-dessus). ---
        mov     word [es:CLOCK_FREQ_HZ_OFF], 0C8D0h    ; 4 770 000 Hz, poids faible
        mov     word [es:CLOCK_FREQ_HZ_OFF+2], 0048h   ;               poids fort

        mov     ax, cs
        mov     ds, ax          ; DS = CS en PERMANENCE: tous les messages et
                                 ; la table hexadecimale vivent dans la ROM.
                                 ; La RAM sous test est accedee EXCLUSIVEMENT
                                 ; via ES (jamais DS), pour ne jamais avoir a
                                 ; changer DS pendant le test.

        call    init_8255       ; UNE SEULE FOIS (voir la note en en-tete) -
                                 ; Port A en MODE 2 (bus bidirectionnel avec
                                 ; l'Arduino), Port B en sortie, INTE2 actif -
                                 ; voir MASQUE_PIO (hardware.inc). AUCUNE copie
                                 ; fantome a initialiser: le segment VAR_SEG
                                 ; vient d'etre efface au complet (ARD_TX_STATE_OFF
                                 ; = ARD_UNKNOWN = 0).

        call    init_ivt_not_implemented  ; peuple les 256 entrees de l'IVT
                                            ; avec un gestionnaire generique
                                            ; ("non implementee" - voir plus
                                            ; bas), AVANT nos propres vecteurs
        call    setup_bios_interrupts  ; installe ENSUITE INT 10h/16h
                                         ; ("esprit BIOS" - voir plus bas),
                                         ; par-dessus les 2 entrees concernees

        call    init_8259               ; programme le 8259 (ICW/OCW) et
                                         ; installe irq0_test_handler sur IR0
                                         ; - voir plus bas. N'active PAS IF.
        in      al, PORTA               ; vide un octet de l'Arduino arrive AVANT
                                         ; que le 8259 soit pret: INTR reste a 1
                                         ; tant que le Port A n'est pas lu, et
                                         ; le 8259 est declenche par FRONT - sans
                                         ; cette lecture, plus aucun front ne
                                         ; viendrait jamais (voir Directives.md)
        sti                             ; active les interruptions MATERIELLES
                                         ; - premiere fois que IF compte
                                         ; reellement pour ce projet (8259
                                         ; maintenant configure ET le vecteur
                                         ; IR0 installe - voir Directives.md)

%ifdef TEST_PS2
        ; --- Test PS/2 (TEST_PS2): boucle infinie qui affiche sur
        ; l'UART le scan code (Set 2, brut) de chaque octet recu du
        ; TAMPON PS2_RX_BUF_OFF (rempli par irq1_arduino_handler - voir
        ; lib/ps2.asm/ps2_read_byte), donc de bout en bout via
        ; l'Arduino/IRQ1 depuis la version Arduino (plus un polling
        ; direct du Port B, retire - voir Directives.md). REMPLACE le
        ; reste du POST - voir la note pres de %define TEST_PS2 en
        ; haut du fichier. Ne retourne JAMAIS. ---
        print   txt_ps2_attente, UART
.ps2_loop:
        call    ps2_read_byte    ; bloque - AL=scan code recu, CF=1 si trame invalide
        pushf                    ; CF doit survivre aux appels UART qui suivent
                                  ; (AL, lui, est deja preserve par uart_tx_string)
        mov     si, txt_ps2_recu
        call    uart_tx_string
        call    uart_tx_hex_byte ; affiche le scan code en hexa (AL toujours valide)
        popf
        jnc     .ps2_ok
        print   txt_ps2_erreur, UART
        jmp     .ps2_next
.ps2_ok:
        print   txt_crlf, UART
.ps2_next:
        jmp     .ps2_loop
%endif

        ; --- Ecran de demarrage: affiche une seule fois (pas a chaque
        ; cycle de .ici, contrairement au reste de l'affichage LCD),
        ; pendant 1 seconde, avant d'entrer dans la boucle principale.
        ; Affiche via INT 10h (gotoxy/print, voir include/lcd_macros.inc)
        ; plutot que i2c_lcd_goto/i2c_lcd_print directement - premier usage
        ; reel de l'interface "esprit BIOS" (voir int10h_handler,
        ; README.md) ---
        call    i2c_lcd_init
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_splash_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_splash_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_splash_l3, LCDI2C
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_splash_l4, LCDI2C
        delay_ms (1*SECONDE)

        ; --- Bandeau d'identification: affiche une seule fois, avant
        ; d'entrer dans le menu (remplace l'ancienne boucle POST
        ; automatique .ici:/.temp: - voir Directives.md: le menu
        ; interactif, pilote par le clavier PS/2, est maintenant le
        ; comportement normal) ---
        cls                     ; efface l'ecran du terminal (ANSI)
        print   txt_auteur, UART

; ============================================================
; Menu principal / sous-menus
; Chaque option est declenchee par l'utilisateur (clavier PS/2 -
; voir lib/ps2.asm, ps2_get_char) au lieu de s'enchainer
; automatiquement comme avant. Le menu courant est redessine
; (UART+LCD) apres chaque action, ou immediatement si la touche
; pressee n'est pas une des options listees. Le menu principal ne
; fait plus qu'aiguiller vers 4 SOUS-MENUS (Basic, Memory functions,
; USB Disk, Configuration) - chacun revient au menu principal sur
; Echap, jamais directement d'une action imbriquee (meme motif que
; Memory functions/dos_menu depuis toujours).
; ============================================================
.main_menu:
        call    i2c_lcd_init                ; ecran propre pour le menu
        print   txt_menu_main_head, UART    ; jusqu'a "1) Basic" inclus, SANS CRLF -
                                             ; la frequence d'horloge continue la
                                             ; meme ligne, voir clock_main_speed_print
        mov     bp, 1                       ; UART seul (le LCD n'est pas encore dessine)
        call    clock_main_speed_print      ; "   N.NN MHz" + CRLF
        print   txt_menu_main_rest, UART    ; options 2-4 + ligne vide
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_menu_main_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_menu_main_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_menu_main_l3, LCDI2C
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_menu_main_l4, LCDI2C
        mov     bp, 2                       ; LCD seul, APRES lcd_txt_menu_main_l1 (sinon
        call    clock_main_speed_print      ; ecrase par son padding pleine largeur)

        call    ps2_get_char            ; bloque jusqu'a une touche reconnue

        cmp     al, '1'
        jne     .main_2
        jmp     .basic_menu
.main_2:
        cmp     al, '2'
        jne     .main_3
        jmp     .dump_menu
.main_3:
        cmp     al, '3'
        jne     .main_4
        jmp     .usb_menu
.main_4:
        cmp     al, '4'
        jne     .main_menu              ; touche non reconnue - redessine le menu
        jmp     .config_menu

; --- Sous-menu Basic: 2 options, tiennent sur le LCD sans pagination
; (les lignes 3/4 restent vides - i2c_lcd_init les a deja effacees). ---
.basic_menu:
        call    i2c_lcd_init
        print   txt_menu_basic, UART
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_menu_basic_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_menu_basic_l2, LCDI2C

        call    ps2_get_char

        cmp     al, '1'
        jne     .basic_2
        call    i2c_lcd_init
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_tb_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_tb_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_tb_l3, LCDI2C
        call    tiny_basic              ; lib/tiny_basic.asm - interagit par le terminal UART;
                                         ; retourne ici par BYE ou Ctrl-X (DS=CS restaure)
        jmp     .basic_menu
.basic_2:
        cmp     al, '2'
        jne     .basic_esc
        call    i2c_lcd_init
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_bas_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_bas_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_bas_l3, LCDI2C
        call    basic_run               ; lib/basic.asm - BASIC "GW-BASIC-like", terminal UART;
                                         ; retourne ici par SYSTEM, BYE ou Ctrl-X (DS=CS restaure)
        jmp     .basic_menu
.basic_esc:
        cmp     al, 27
        jne     .basic_menu
        jmp     .main_menu

; --- Menu Memory functions: 6 options, mais le LCD (4 lignes) ne peut
; en montrer que 4 a la fois - PAGINE sur 2 ecrans (Gauche/Droite pour
; basculer, comme registers_dump_action - reutilise directement ses
; etiquettes txt_lcd_page1/page2, generiques). L'UART, lui, montre
; TOUJOURS les 6 options d'un coup (pas de contrainte de largeur/
; hauteur) - imprime UNE SEULE FOIS a l'entree, pas a chaque bascule
; de page LCD. SI = page LCD courante (0/1), meme motif que
; registers_dump_action - JAMAIS touche par gotoxy/print/ps2_get_char
; (tous le preservent), et par convention chaque action appelee
; ci-dessous (dump_memory_action etc.) restaure SI a sa valeur
; d'entree - mais la page est de toute facon remise a 0 a CHAQUE
; retour dans .dump_menu (voir "xor si,si" ci-dessous): plus simple et
; plus previsible qu'un etat qui "survivrait" a une action. "6) Test
; RAM" (ex-option 1 du menu principal) tient sur la page 2, avec
; l'option 5 (2 lignes utilisees sur 4, le reste vide). ---
.dump_menu:
        print   txt_menu_dump, UART      ; liste complete (1-6), une seule fois
        xor     si, si                   ; page LCD = 0 (page 1)
.dump_redraw:
        call    i2c_lcd_init
        cmp     si, 0
        je      .dump_page1
        jmp     .dump_page2
.dump_page1:
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_menu_dump_l1, LCDI2C
        gotoxy  0, 17, LCDI2C
        print   txt_lcd_page1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_menu_dump_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_menu_dump_l3, LCDI2C
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_menu_dump_l4, LCDI2C
        jmp     .dump_wait_key
.dump_page2:
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_menu_dump_l5, LCDI2C
        gotoxy  0, 17, LCDI2C
        print   txt_lcd_page2, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_menu_dump_l6, LCDI2C

.dump_wait_key:
        call    ps2_get_char

        cmp     al, PS2_KEY_LEFT
        je      .dump_toggle_page
        cmp     al, PS2_KEY_RIGHT
        je      .dump_toggle_page

        cmp     al, '1'
        jne     .dump_2
        call    dump_memory_action      ; demande adresses depart/fin, dump - voir plus bas
        jmp     .dump_menu
.dump_2:
        cmp     al, '2'
        jne     .dump_3
        call    edit_ram_action
        jmp     .dump_menu
.dump_3:
        cmp     al, '3'
        jne     .dump_4
        call    registers_dump_action   ; affiche les registres du 8088 (LCD+UART) - voir plus bas
        jmp     .dump_menu
.dump_4:
        cmp     al, '4'
        jne     .dump_5
        call    edit_run_action         ; edite/execute a 1000:0000 - voir plus bas
        jmp     .dump_menu
.dump_5:
        cmp     al, '5'
        jne     .dump_6
        call    ivt_dump_action         ; affiche la table des vecteurs (LCD+UART) - voir plus bas
        jmp     .dump_menu
.dump_6:
        cmp     al, '6'
        jne     .dump_esc
        call    i2c_lcd_init
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_run_ram_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_run_ram_l2, LCDI2C
        call    test_ram                ; teste toute la RAM (128K), rapporte via UART+LCD
        jmp     .dump_menu
.dump_esc:
        cmp     al, 27                  ; Echap: retour au menu principal (remplace
        jne     .dump_redraw            ; l'ancienne option "9) Home menu", non
        jmp     .main_menu              ; affichee - touche non reconnue: reste sur
                                         ; la meme page LCD (pas de reinitialisation)
.dump_toggle_page:
        xor     si, 1                   ; bascule 0<->1 (page 1 <-> page 2)
        jmp     .dump_redraw

; --- Sous-menu USB Disk: 3 options, tiennent sur le LCD sans
; pagination. "1) USB ON/OFF" BASCULE (un seul etat memorise, voir
; BIOS_USB_STATE/hardware.inc - 0 = OFF par defaut, comme au demarrage
; puisque toute la RAM est effacee a 0): usb_toggle_action envoie la
; commande opposee a l'etat courant et l'affiche. L'option 1 elle-meme
; montre cet etat ("1) USB: OFF"/"1) USB: ON" - usb_state_print, voir
; plus bas), redessinee a chaque passage dans ce sous-menu (donc mise
; a jour tout de suite apres une bascule). ---
.usb_menu:
        call    i2c_lcd_init
        print   txt_menu_usb_head, UART
        call    usb_state_print         ; "1) USB: OFF"/"1) USB: ON" - UART (+ CRLF) et LCD ligne 0
        print   txt_menu_usb_rest, UART
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_menu_usb_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_menu_usb_l3, LCDI2C

        call    ps2_get_char

        cmp     al, '1'
        jne     .usb_2
        call    usb_toggle_action       ; bascule USB ON/OFF - voir plus bas
        jmp     .usb_menu
.usb_2:
        cmp     al, '2'
        jne     .usb_3
        call    list_files_action       ; liste les fichiers de la flash - voir plus bas
        jmp     .usb_menu
.usb_3:
        cmp     al, '3'
        jne     .usb_esc
        call    dos_menu                ; lib/bios.asm: image .IMG -> disquette A: -> amorce le DOS
                                         ; (ne revient que si on annule ou en cas d'echec)
        jmp     .usb_menu
.usb_esc:
        cmp     al, 27
        jne     .usb_menu
        jmp     .main_menu

; --- Sous-menu Configuration: 1 seule option pour l'instant (vitesse
; d'horloge - a venir, non implementee: config_clock_action affiche
; seulement un message). ---
.config_menu:
        call    i2c_lcd_init
        print   txt_menu_config, UART
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_menu_config_l1, LCDI2C
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_menu_config_l2, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_menu_config_l3, LCDI2C
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_menu_config_l4, LCDI2C

        call    ps2_get_char

        cmp     al, '1'
        jne     .config_2
        call    clock_speed_action      ; affiche/regle la frequence du 8088 - voir plus bas
        jmp     .config_menu
.config_2:
        cmp     al, '2'
        jne     .config_3
        call    cpu_speed_test_action   ; banc d'essai de vitesse CPU - voir plus bas
        jmp     .config_menu
.config_3:
        cmp     al, '3'
        jne     .config_4
        call    clock_datetime_action   ; regle la date/heure de la RTC du pont - voir plus bas
        jmp     .config_menu
.config_4:
        cmp     al, '4'
        jne     .config_esc
        call    information_action      ; ecran recapitulatif (date/heure, versions, RAM, disque, CPU) - voir plus bas
        jmp     .config_menu
.config_esc:
        cmp     al, 27
        jne     .config_menu
        jmp     .main_menu

; ============================================================
; test_ram
; Teste la totalite de la RAM statique de 128K (00000h-1FFFFh),
; par blocs de 64K (2 segments: 0000h et 1000h), moins les 2 derniers
; Ko du segment 1000h reserves a la pile active, a la copie fantome
; du port A, au tampon d'edition de edit_ram_action et aux autres
; variables partagees (PORTA_SHADOW_OFF = tout debut de cette zone,
; voir en en-tete).
; Resultat: 129024 octets testes sur 131072 (126 blocs de 1 Ko).
; ============================================================
test_ram:
        pushf                   ; sauvegarde IF: sans ce PUSHF/POPF, le CLI ci-dessous
                                 ; laissait IF=0 pour de bon apres le test - plus
                                 ; aucune IRQ1 (clavier) servie dans le code appelant,
                                 ; donc menu bloque des le premier "Test RAM"
        cli                     ; pas d'interruption pendant tout le test
                                 ; (encore plus important ici: protege aussi
                                 ; le timing bit a bit de l'UART)
        xor     bh, bh          ; BH = drapeau d'erreur GLOBAL (0 = RAM valide)
        xor     bp, bp          ; BP = drapeau d'erreur du BLOC courant

        ; --- remet a zero les compteurs de progression du LCD (ligne
        ; 4, etape 2) - vivent en RAM juste apres PORTA_SHADOW, voir
        ; en en-tete. ES/DI seront de toute facon rechargEs juste
        ; apres pour le premier segment: pas besoin de les sauver ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BLOCK_COUNTER_OFF
        mov     byte [es:di], 0
        mov     di, DEFECT_COUNTER_OFF
        mov     byte [es:di], 0
        mov     di, RAM_DEFECT_BYTES
        mov     word [es:di], 0

        call    msg_banniere

        ; --- Segment 0000h: physique 00000h-0FFFFh, teste en entier (64K) ---
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     cx, 0           ; CX=0 -> 65536 iterations (astuce classique)
        call    test_segment

        ; --- Segment 1000h: physique 10000h-1FFFFh, moins les 2       ---
        ; --- derniers Ko reserves a la pile -> 63488 octets testes    ---
        mov     ax, STACK_SEG
        mov     es, ax
        xor     di, di
        mov     cx, 63488       ; 65536 - 2048 (zone reservee a la pile, au
                                 ; tampon d'edition et aux autres variables
                                 ; partagees - voir en en-tete de hardware.inc)
        call    test_segment

        ; --- Bilan final ---
        cmp     bh, 0
        je      .ram_ok

        call    msg_ram_defectueuse
        call    msg_ram_total_defauts   ; quantite totale de RAM defectueuse (0 si .ram_ok)
        popf                    ; restaure IF (voir le PUSHF en tete)
        ret                     ; retourne au menu (voir start:)

.ram_ok:
        call    msg_ram_ok
        call    msg_ram_total_defauts
        popf                    ; restaure IF (voir le PUSHF en tete)
        ret

; ============================================================
; test_segment
; Teste CX octets a partir de ES:DI (destructif mais restaure
; chaque octet aussitot apres verification). Quatre motifs de test
; par octet: 10101010b puis 01010101b (complementaires, pour
; detecter les bits colles a 0 ou a 1), puis 00h et FFh (les ecritures
; de zeros: un defaut materiel n'apparaissait que pour 00h a une adresse
; finissant par FFh, invisible avec AAh/55h seuls).
;
; Entree:  ES:DI = adresse de depart, CX = nombre d'octets
; Modifie: BH (drapeau global), BP (drapeau du bloc courant, se
;          reinitialise a chaque bloc de 1024 octets rapporte)
; ============================================================
test_segment:
.byte_loop:
        mov     bl, [es:di]     ; sauvegarde l'octet original

        mov     al, 10101010b   ; motif de test #1
        mov     [es:di], al
        mov     al, [es:di]     ; relecture (verifie vraiment la RAM)
        mov     dl, al          ; DL = valeur relue (pour le rapport eventuel)
        cmp     al, 10101010b
        jne     .fault_1

        mov     al, 01010101b   ; motif de test #2 (complement du #1)
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        cmp     al, 01010101b
        jne     .fault_2

        mov     al, 00h         ; motif #3: 00h (un DOS ecrit surtout des zeros; ce motif a revele un
        mov     [es:di], al     ; defaut materiel: l'ecriture de 00h a une adresse finissant par FFh)
        mov     al, [es:di]
        mov     dl, al
        or      al, al
        jne     .fault_3

        mov     al, 0FFh        ; motif #4: FFh
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        cmp     al, 0FFh
        jne     .fault_4

        jmp     .restore

.fault_1:
        mov     dh, 10101010b   ; DH = valeur attendue
        jmp     .fault_common
.fault_2:
        mov     dh, 01010101b
        jmp     .fault_common
.fault_3:
        mov     dh, 00h
        jmp     .fault_common
.fault_4:
        mov     dh, 0FFh
.fault_common:
        mov     bh, 1           ; leve le drapeau global (RAM defectueuse)
        mov     bp, 1           ; leve le drapeau du bloc courant
        call    msg_defaut_detail      ; rapport immediat: adresse ES:DI,
                                        ; attendu=DH, lu=DL (en rouge)
.restore:
        mov     [es:di], bl     ; restaure la valeur d'origine de l'octet

        inc     di
        test    di, 03FFh       ; DI multiple de 1024 ? (1 bloc complet teste)
        jnz     .no_checkpoint

        call    msg_bloc_progression    ; affiche ES:debut-ES:fin + OK/DEFAUT
                                         ; (UART) + adresse+OK/ERR (LCD ligne 2),
                                         ; et reinitialise BP a 0

.no_checkpoint:
        loop    .byte_loop
        ret

; ============================================================
; mem_calc_physical
; Calcule l'adresse physique 20 bits (SEGMENT*16 + OFFSET) d'un
; couple segment:offset, en 32 bits (DX:AX) - un registre complet
; est utilise (plutot que 20 bits precis) pour que la comparaison et
; la soustraction faites par dump_memory_action restent simples,
; meme si DX vaut toujours 0 en pratique sur ce materiel (bus
; d'adresse 8088 a 20 lignes seulement).
;
; Entree:  AX = segment, BX = offset
; Sortie:  DX:AX = adresse physique (DX = poids fort, AX = poids
;          faible)
; Detruit: CX
; ============================================================
mem_calc_physical:
        xor     dx, dx
        mov     cx, 4
.shl4:
        shl     ax, 1
        rcl     dx, 1
        loop    .shl4
        add     ax, bx
        adc     dx, 0
        ret

; ============================================================
; dump_memory_action
; Consolide les anciennes options "Dump ROM" et "Dump first 4k RAM"
; du menu Memory functions sous une seule action: demande une adresse de
; DEPART puis une adresse de FIN, chacune saisie au clavier sous la
; forme SEGMENT:OFFSET (4+4 chiffres hexa, retour arriere pour
; corriger - voir ps2_read_hex_editable), puis affiche en
; hexadecimal+ASCII (UART) et hexadecimal condense (LCD I2C) tous les
; octets de cette plage physique, 16 octets par ligne, via dump_line
; (inchangee).
;
; Fonctionne indifferemment pour la ROM (ex: C000:0000 a F000:FFFF
; pour toute la ROM, 256 Ko), la RAM (ex: 0000:0000 a 1000:FFFF pour
; toute la RAM, 128 Ko), TOUT l'espace d'adressage materiel en une
; seule fois (0000:0000 a F000:FFFF, jusqu'a l'adresse physique
; FFFFFh - 20 lignes d'adresse, voir le piege FFFF:FFFx dans
; README.md) ou n'importe quelle plage intermediaire - plus besoin de
; deux procedures separees.
;
; La plage peut traverser une frontiere de segment (ex: 0000:FFF0 a
; 1000:0010, ou meme plusieurs dizaines de segments d'affilee):
; l'offset (DI) est avance de 16 a chaque ligne comme avant; en cas de
; debordement (DI redevient <= sa valeur d'avant l'ajout), le segment
; (ES) est avance de 1000h pour rester a la bonne adresse physique
; (1 paragraphe = 16 octets = 1000h en unites de segment) - SAUF si
; cet ajout deborde LUI-MEME 16 bits (ES etait deja F000h-FFFFh): la
; plage maximale de ce materiel vient alors d'etre entierement
; couverte, le dump s'arrete plutot que de continuer sur un segment
; errone (qui reviendrait a 0000h).
;
; L'arret normal (hors ce cas limite) compare l'adresse physique
; COURANTE (32 bits) a l'adresse physique de fin a CHAQUE ligne,
; plutot que de precalculer un nombre total de lignes: pour la plage
; maximale ci-dessus, ce total vaudrait exactement 65536, qui NE TIENT
; PAS dans un mot de 16 bits (deborderait silencieusement a 0).
;
; Validation: si l'adresse de fin (physique) est STRICTEMENT
; INFERIEURE a celle de depart, la plage est invalide - un message
; d'erreur est affiche (UART, en rouge) et la fonction retourne sans
; rien dumper.
;
; Interruption au clavier: la touche Echap, verifiee de facon NON
; BLOQUANTE avant chaque ligne (CLOCK/PB0 est HAUT au repos - un
; "IN AL,PORTB" suffit a detecter qu'une trame est en cours, sans
; ralentir le dump quand aucune touche n'est pressee), interrompt le
; dump et retourne au menu. Best-effort: une touche pressee et
; relachee tres brievement PENDANT l'impression d'une ligne (qui peut
; prendre plusieurs dizaines de ms sur l'UART logiciel a 9600 bauds)
; peut echapper a la verification suivante si elle est deja terminee
; a ce moment-la - appuyer de nouveau sur Echap si le dump ne s'arrete
; pas immediatement.
;
; Limitation connue (affichage seulement): la ligne 4 du LCD affiche
; desormais "Ligne: NNN" (numero de la ligne courante, SANS total -
; contrairement a l'ancien "NNN/257" fixe, devenu incorrect des que
; la taille de la plage varie). i2c_lcd_tx_dec3 n'affiche que 3 chiffres
; (0-999): au-dela de 999 lignes (15984 octets) ce numero redevient
; incorrect (cosmetique seulement, voir Directives.md) - le dump
; UART, lui, reste toujours exact quelle que soit la taille de la
; plage.
; ============================================================
dump_memory_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        call    i2c_lcd_init

        ; --- adresse de depart (ligne 1 du LCD) ---
        mov     si, txt_dump_start_prefix       ; "Start: 0x"
        call    uart_tx_string
        mov     si, txt_dump_start_prefix
        i2c_lcd_show LCD_LINE1
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 9      ; 9 = long. de "Start: 0x"
        call    ps2_read_hex_editable           ; BX = segment de depart
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     [es:di], bx

        mov     si, txt_dump_seg_off_sep        ; ":0x"
        call    uart_tx_string
        mov     si, txt_dump_seg_off_sep
        call    i2c_lcd_print
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 16     ; 16 = long. de "Start: 0xSSSS:0x"
        call    ps2_read_hex_editable           ; BX = offset de depart
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_OFF_OFF
        mov     [es:di], bx

        ; --- adresse de fin (ligne 2 du LCD) ---
        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
        mov     si, txt_dump_end_prefix         ; "End:   0x"
        call    uart_tx_string
        mov     si, txt_dump_end_prefix
        i2c_lcd_show LCD_LINE2
        mov     cl, 4
        mov     ah, (LCD_LINE2 & 07Fh) + 9      ; 9 = long. de "End:   0x"
        call    ps2_read_hex_editable           ; BX = segment de fin
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_SEG_OFF
        mov     [es:di], bx

        mov     si, txt_dump_seg_off_sep
        call    uart_tx_string
        mov     si, txt_dump_seg_off_sep
        call    i2c_lcd_print
        mov     cl, 4
        mov     ah, (LCD_LINE2 & 07Fh) + 16     ; 16 = long. de "End:   0xSSSS:0x"
        call    ps2_read_hex_editable           ; BX = offset de fin
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_OFF_OFF
        mov     [es:di], bx

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        ; --- bandeau UART: rappelle les deux adresses saisies ---
        mov     si, txt_dump_banniere1
        call    uart_tx_string
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_OFF_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     si, txt_dump_banniere2
        call    uart_tx_string
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_SEG_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_OFF_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     si, txt_dump_banniere3
        call    uart_tx_string

        ; --- calcule les adresses physiques (32 bits: DX:AX) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     ax, [es:di]                     ; AX = segment de depart
        mov     di, DUMP_START_OFF_OFF
        mov     bx, [es:di]                     ; BX = offset de depart
        call    mem_calc_physical               ; DX:AX = adresse physique de depart
        push    dx
        push    ax                              ; empile start_phys (hi puis lo)

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_SEG_OFF
        mov     ax, [es:di]                     ; AX = segment de fin
        mov     di, DUMP_END_OFF_OFF
        mov     bx, [es:di]                     ; BX = offset de fin
        call    mem_calc_physical               ; DX:AX = adresse physique de fin

        ; --- memorise end_phys (32 bits) - compare a l'adresse
        ; physique COURANTE a chaque ligne (voir .line_loop plus bas)
        ; plutot que de precalculer un nombre total de lignes: pour la
        ; plage maximale de ce materiel (0000:0000 a F000:FFFF), ce
        ; total vaudrait exactement 65536, qui NE TIENT PAS dans un
        ; mot de 16 bits (deborderait a 0) ---
        mov     bx, VAR_SEG
        mov     es, bx
        mov     di, DUMP_END_PHYS_LO_OFF
        mov     [es:di], ax
        mov     di, DUMP_END_PHYS_HI_OFF
        mov     [es:di], dx

        pop     cx                              ; CX = start_phys (poids faible)
        pop     bp                              ; BP = start_phys (poids fort)

        cmp     dx, bp
        jb      .invalid_range
        ja      .range_ok
        cmp     ax, cx
        jb      .invalid_range
.range_ok:
        ; --- ES:DI = adresse de depart (telle que saisie - pas
        ; --- renormalisee - pour que la premiere ligne affichee
        ; --- corresponde exactement a ce qui a ete tape) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     ax, [es:di]                     ; AX = segment de depart
        mov     di, DUMP_START_OFF_OFF
        mov     bx, [es:di]                     ; BX = offset de depart
        mov     es, ax                          ; ES = segment de depart (bascule enfin
                                                  ; sur le segment de la plage a dumper)
        mov     di, bx                          ; DI = offset de depart

        mov     bx, 1                            ; BX = numero de ligne courant (1-based,
                                                  ; pour "Ligne: NNN" sur le LCD)
.line_loop:
        ; --- interruption au clavier (Echap): verification NON
        ; BLOQUANTE avant chaque ligne via ps2_poll_char (lib/ps2.asm):
        ; lit une touche reconnue si elle attend, consomme les
        ; relachements/touches ignorees SANS attendre (l'ancien
        ; "ps2_key_available puis ps2_get_char" bloquait sur un simple
        ; relachement - voir ps2_poll_char). ---
        push    bx                              ; ps2_poll_char detruit BX (numero de
        call    ps2_poll_char                   ; ligne courant, doit survivre) - clavier
        pop     bx                              ; PS/2 OU terminal UART, jamais bloquant
        jc      .no_key                         ; rien de reconnu (POP ne touche pas CF)
        cmp     al, 27                          ; Echap ?
        je      .interrupted
.no_key:
        push    di
        call    dump_line                       ; affiche ES:DI (UART+LCD), avance DI de 16
        pop     dx                               ; DX = DI D'AVANT l'appel
        cmp     di, dx
        ja      .no_wrap                         ; DI a augmente normalement
        ; --- debordement 16 bits de DI: avance le segment d'un
        ; --- paragraphe (1000h). SI CET AJOUT DEBORDE AUSSI (CF=1,
        ; --- ES etait deja F000h-FFFFh), la plage maximale de ce
        ; --- materiel (jusqu'a l'adresse physique FFFFFh) vient
        ; --- d'etre entierement couverte: on s'arrete plutot que de
        ; --- continuer sur un segment errone (revenu a 0000h) ---
        mov     ax, es
        add     ax, 1000h
        jc      .dump_complete
        mov     es, ax
.no_wrap:
        inc     bx

        ; --- adresse physique COURANTE (ES:DI, apres cette ligne) -
        ; --- comparee a end_phys (32 bits, en RAM): continue tant que
        ; --- current <= end_phys. BX (numero de ligne) sauvegarde
        ; --- autour de l'appel a mem_calc_physical (qui utilise BX
        ; --- pour l'offset en entree) ---
        push    bx
        mov     ax, es
        mov     bx, di
        call    mem_calc_physical               ; DX:AX = adresse physique courante
        pop     bx

        ; --- BP adresse VAR_SEG directement via SS (= VAR_SEG en
        ; --- PERMANENCE depuis l'init de la pile, voir start:) - pas
        ; --- besoin de sauvegarder/restaurer ES (segment du dump) ---
        push    bp
        mov     bp, DUMP_END_PHYS_HI_OFF
        cmp     dx, [bp]
        ja      .dump_complete_popbp
        jb      .continue_popbp
        mov     bp, DUMP_END_PHYS_LO_OFF
        cmp     ax, [bp]
        ja      .dump_complete_popbp
.continue_popbp:
        pop     bp
        jmp     .line_loop
.dump_complete_popbp:
        pop     bp
.dump_complete:
        call    msg_dump_fin
        jmp     .done

.interrupted:
        print   txt_dump_interrupted, UART
        jmp     .done

.invalid_range:
        print   txt_dump_invalid_range, UART

.done:
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

EDIT_COLS               equ     5               ; octets par ligne de la grille d'edition - 5
                                                  ; (pas 6): laisse exactement la place pour
                                                  ; l'etiquette d'adresse "SSSS:" (5 caracteres,
                                                  ; EDIT_ADDR_LABEL_WIDTH) en tete de chaque
                                                  ; ligne LCD sans depasser les 20 caracteres
                                                  ; disponibles (5 + 5*3 = 20 exactement) - voir
                                                  ; edit_ram_draw_grid/cell_ddram.
EDIT_ADDR_LABEL_WIDTH   equ     5               ; largeur de l'etiquette d'adresse LCD ("SSSS:")
EDIT_ROWS               equ     4               ; lignes VISIBLES a la fois (4 lignes du LCD)
EDIT_MAX_SIZE           equ     0400h           ; taille maximale d'une plage editable (1024)
EDIT_MIN_START          equ     0400h           ; adresse de depart minimale (juste apres
                                                  ; l'IVT, 256*4=1024 octets - voir
                                                  ; "Interruptions logicielles type BIOS",
                                                  ; README.md)
; --- vue TERMINAL (ANSI) de la grille d'edition: ecran efface une fois, puis
; --- chaque ligne repositionnee en absolu et le curseur du terminal place sur la
; --- case courante (voir edit_ram_draw_terminal). Tient dans 24 lignes: titre (1),
; --- grille (3-10), aide (12), registres de edit_run_action (14-24). ---
TERM_ROWS               equ     8               ; lignes de la grille (une "page")
TERM_GRID_ROW           equ     3               ; 1re ligne ecran de la grille
TERM_GRID_COL           equ     7               ; 1re colonne ecran d'une case ("SSSS: " = 6)
TERM_HELP_ROW           equ     TERM_GRID_ROW + TERM_ROWS + 1
TERM_REGS_ROW           equ     TERM_HELP_ROW + 2   ; registres apres 'r' (edit_run_action)
EDIT_RUN_SIZE           equ     0FFh            ; taille FIXE (255 octets) de la plage
                                                  ; editable/executable a 1000:0000 (voir
                                                  ; edit_run_action) - pas de saisie, valeur
                                                  ; imposee (demande explicite)

; ============================================================
; edit_ram_action
; Editeur de RAM interactif, PAR PLAGE et AVEC TAMPON (annulation
; possible) - remplace la version a adresse unique du premier jalon
; (voir Directives.md).
;
; Demande, avec retour arriere possible sur chaque saisie (voir
; ps2_read_hex_editable):
;   1) une adresse de DEPART complete, SEGMENT:OFFSET (4+4 chiffres
;      hexa, meme saisie a 2 champs que dump_memory_action - avant,
;      seul un offset etait demande, le segment restant TOUJOURS
;      0000h) - memorises dans EDIT_BASE_SEG_OFF/EDIT_BASE_OFF. SI LE
;      SEGMENT SAISI EST 0000h, l'offset DOIT etre >= EDIT_MIN_START
;      (0400h, juste apres l'IVT): une adresse dans l'IVT est REJETEE
;      (message d'erreur, retour immediat au menu) pour ne jamais
;      pouvoir corrompre les gestionnaires d'interruption. Cette
;      protection ne s'applique qu'au segment 0000h - l'IVT n'existe
;      qu'a 0000:0000-0000:03FF.
;   2) une TAILLE en octets (4 chiffres hexa) - DOIT etre entre 1 et
;      EDIT_MAX_SIZE (400h = 1024) inclusivement, ET la plage
;      resultante (depart+taille-1) ne doit pas depasser 0FFFFh
;      (rester dans le segment saisi) - sinon, meme rejet.
;
; Contrairement au premier jalon, RIEN N'EST ECRIT DANS LA VRAIE RAM
; PENDANT L'EDITION: tous les octets de la plage sont copies dans un
; TAMPON de travail (EDIT_BUFFER_OFF, VAR_SEG - voir
; edit_ram_load_buffer) des le depart, et l'edition ne modifie QUE ce
; tampon:
;   Echap - ANNULE toute l'edition: le tampon est abandonne, la RAM
;           reelle n'est PAS modifiee, retour immediat au menu.
;   Q/q   - VALIDE: le tampon (taille octets) est recopie dans la RAM
;           reelle (voir edit_ram_commit_buffer), puis retour au menu.
;
; La grille affiche EDIT_ROWS x EDIT_COLS (4x5 = 20) octets a la fois,
; mais la plage peut en contenir jusqu'a 1024 (soit jusqu'a 205 lignes
; logiques): les fleches HAUT/BAS FONT DEFILER la fenetre visible d'une
; ligne des que le curseur en sortirait (voir edit_ram_move_up/down et
; edit_ram_scroll_to_cursor) - contrairement au premier jalon, limite
; a la grille initialement affichee.
;
;   Fleches G/D  - deplacent la case courante DANS SA LIGNE (fixees
;                  aux bords de colonne, comme avant).
;   Fleches H/B  - deplacent la case courante d'UNE LIGNE LOGIQUE
;                  (fixees aux bords de la plage), avec defilement de
;                  la fenetre visible si necessaire.
;   chiffre hexa - compose une nouvelle valeur pour la case courante
;                  (1 ou 2 chiffres, retour arriere - voir
;                  ps2_edit_byte_value), ecrite DANS LE TAMPON.
;   Entree       - valide la saisie dans le tampon (ignoree si aucun
;                  chiffre tape), avance a la case suivante (voir
;                  edit_ram_advance).
; ============================================================
edit_ram_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    i2c_lcd_init                ; ecran propre pour la saisie

        ; --- adresse de depart: SEGMENT:OFFSET complets (20 bits), meme
        ; saisie a 2 champs que dump_memory_action (Start:/End:) - avant,
        ; seul un offset (16 bits) etait demande, le segment restant
        ; TOUJOURS 0000h: impossible d'editer la RAM haute (1000h,
        ; VAR_SEG) depuis ce menu. ---
        mov     si, txt_edit_address_prefix
        call    uart_tx_string
        mov     si, txt_edit_address_prefix
        i2c_lcd_show LCD_LINE1
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 11     ; 11 = longueur de "Address: 0x"
        call    ps2_read_hex_editable           ; BX = segment saisi
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_SEG_OFF
        mov     [es:di], bx                     ; memorise le segment de depart

        mov     si, txt_dump_seg_off_sep        ; ":0x" - reutilise dump_memory_action
        call    uart_tx_string
        mov     si, txt_dump_seg_off_sep
        call    i2c_lcd_print
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 18      ; 18 = long. de "Address: 0xSSSS:0x"
        call    ps2_read_hex_editable           ; BX = offset saisi

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        ; --- IVT protegee (< EDIT_MIN_START) seulement dans le segment
        ; 0000h - un offset < 0400h dans un AUTRE segment n'a rien a voir
        ; avec l'IVT (elle ne vit qu'en 0000:0000-0000:03FF) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_SEG_OFF
        cmp     word [es:di], 0
        jne     .start_ok               ; autre segment que 0000h: pas de protection IVT
        cmp     bx, EDIT_MIN_START
        jae     .start_ok
        print   txt_edit_ivt_reject, UART
        jmp     .done
.start_ok:
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     [es:di], bx                     ; memorise l'offset de depart

        ; --- taille de la plage (en octets) ---
        mov     si, txt_edit_size_prefix
        call    uart_tx_string
        mov     si, txt_edit_size_prefix
        i2c_lcd_show LCD_LINE2
        mov     cl, 4
        mov     ah, (LCD_LINE2 & 07Fh) + 11     ; 11 = longueur de "Size:    0x"
        call    ps2_read_hex_editable           ; BX = taille saisie

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        cmp     bx, 0
        je      .size_reject
        cmp     bx, EDIT_MAX_SIZE
        ja      .size_reject

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     ax, [es:di]                     ; AX = adresse de depart
        mov     cx, bx                          ; CX = taille
        dec     cx                              ; CX = taille-1
        add     ax, cx                          ; AX = dernier octet de la plage
        jc      .size_reject                    ; deborde 0FFFFh - invalide
        jmp     .size_ok
.size_reject:
        print   txt_edit_size_invalid, UART
        jmp     .done
.size_ok:
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_SIZE_OFF
        mov     [es:di], bx

        print   txt_edit_help, UART

        call    edit_ram_load_buffer            ; copie la plage reelle -> tampon

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_CURSOR_OFF
        mov     word [es:di], 0
        mov     di, EDIT_WINDOW_ROW_OFF
        mov     word [es:di], 0

        mov     di, EDIT_TERM_TITLE_OFF
        mov     word [es:di], txt_term_title_edit
        mov     di, EDIT_TERM_HELP_OFF
        mov     word [es:di], txt_term_help_edit
        mov     si, txt_ansi_cls                ; terminal: efface l'ecran (une fois)
        call    uart_tx_string

.redraw:
        call    edit_ram_draw_grid

.wait_key:
        call    ps2_get_char

        cmp     al, 27                          ; Echap: annule (rien recopie)
        je      .cancel

        cmp     al, 'q'
        je      .commit
        cmp     al, 'Q'
        je      .commit

        cmp     al, PS2_KEY_LEFT
        jne     .not_left
        call    edit_ram_move_left
        jmp     .redraw
.not_left:
        cmp     al, PS2_KEY_RIGHT
        jne     .not_right
        call    edit_ram_move_right
        jmp     .redraw
.not_right:
        cmp     al, PS2_KEY_UP
        jne     .not_up
        call    edit_ram_move_up
        jmp     .redraw
.not_up:
        cmp     al, PS2_KEY_DOWN
        jne     .not_down
        call    edit_ram_move_down
        jmp     .redraw
.not_down:
        ; --- toute autre touche: tente de composer une nouvelle
        ; valeur pour la case courante - ps2_edit_byte_value ignore
        ; lui-meme les touches non pertinentes (voir son en-tete) ---
        mov     dl, al                   ; DL = touche deja lue (sauvegardee -
                                          ; edit_ram_cell_ddram detruit AX)
        call    edit_ram_cell_ddram      ; AH = adresse DDRAM de la case courante
        mov     al, dl                   ; restaure AL = touche (AH inchange)
        call    ps2_edit_byte_value      ; AL(entree)=touche deja lue, CF=1 si rien tape
        jc      .redraw                  ; Entree sans saisie - rien a ecrire
        mov     dl, bl                   ; DL = valeur a ecrire (survit a l'appel)
        call    edit_ram_write_current   ; ecrit DANS LE TAMPON
        call    edit_ram_advance         ; passe a la case suivante (ordre de lecture)
        jmp     .redraw

.commit:
        call    edit_ram_commit_buffer          ; recopie le tampon -> RAM reelle

.cancel:
        mov     si, txt_ansi_cls                ; terminal: ecran propre pour le menu
        call    uart_tx_string

.done:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_load_buffer
; Copie EDIT_SIZE_OFF octets de la RAM reelle (segment EDIT_BASE_SEG_OFF,
; a partir de EDIT_BASE_OFF - saisis par edit_ram_action, n'importe quel
; segment desormais, pas seulement 0000h) dans le tampon de travail
; (EDIT_BUFFER_OFF, VAR_SEG) - appelee une fois au debut de l'edition. BP
; adresse VAR_SEG directement via SS (= VAR_SEG en PERMANENCE depuis
; l'init de la pile, voir start:) - [BP] utilise SS par defaut sur le
; 8086, pas besoin de changer ES pour lire les constantes ni de toucher
; a DS.
; ============================================================
edit_ram_load_buffer:
        push    ax
        push    cx
        push    dx
        push    si
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (RAM reelle)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille (nombre d'octets a copier)

        mov     bp, EDIT_BASE_SEG_OFF
        mov     ax, [bp]
        mov     es, ax                  ; ES = segment saisi (RAM reelle, source)
        mov     si, dx                  ; SI = adresse source courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur destination (tampon, via SS)
.copy_loop:
        mov     al, [es:si]
        mov     [bp], al
        inc     si
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_ram_commit_buffer
; Recopie EDIT_SIZE_OFF octets du tampon de travail (EDIT_BUFFER_OFF)
; vers la RAM reelle (segment EDIT_BASE_SEG_OFF, a partir de
; EDIT_BASE_OFF) - appelee UNIQUEMENT sur validation (Q/q), jamais sur
; Echap. Symetrique de edit_ram_load_buffer (voir son en-tete).
; ============================================================
edit_ram_commit_buffer:
        push    ax
        push    cx
        push    dx
        push    di
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (RAM reelle)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille

        mov     bp, EDIT_BASE_SEG_OFF
        mov     ax, [bp]
        mov     es, ax                  ; ES = segment saisi (RAM reelle, destination)
        mov     di, dx                  ; DI = adresse destination courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur source (tampon, via SS)
.copy_loop:
        mov     al, [bp]
        mov     [es:di], al
        inc     di
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_run_load_buffer / edit_run_commit_buffer
; Copies STRICTEMENT IDENTIQUES a edit_ram_load_buffer/commit_buffer
; (voir ci-dessus), sauf que le cote "RAM reelle" vise le SEGMENT
; 1000h (VAR_SEG/STACK_SEG) au lieu de 0000h - utilisees par
; edit_run_action (voir plus bas, apres registers_dump_action) pour
; editer/executer du code place a 1000:0000 (deuxieme bloc de 64K de
; RAM). EDIT_BASE_OFF est TOUJOURS 0000h pour ces deux routines
; (adresse fixe, imposee par edit_run_action - pas de saisie
; d'adresse comme dans edit_ram_action).
; ============================================================
edit_run_load_buffer:
        push    ax
        push    cx
        push    dx
        push    si
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (toujours 0000h ici)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille (nombre d'octets a copier)

        mov     ax, VAR_SEG
        mov     es, ax                  ; ES = 1000h (RAM reelle, source)
        mov     si, dx                  ; SI = adresse source courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur destination (tampon, via SS)
.copy_loop:
        mov     al, [es:si]
        mov     [bp], al
        inc     si
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

edit_run_commit_buffer:
        push    ax
        push    cx
        push    dx
        push    di
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (toujours 0000h ici)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille

        mov     ax, VAR_SEG
        mov     es, ax                  ; ES = 1000h (RAM reelle, destination)
        mov     di, dx                  ; DI = adresse destination courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur source (tampon, via SS)
.copy_loop:
        mov     al, [bp]
        mov     [es:di], al
        inc     di
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_ram_draw_grid
; (Re)affiche les EDIT_ROWS (4) lignes VISIBLES a partir de
; EDIT_WINDOW_ROW_OFF (ligne logique du haut), en lisant les valeurs
; dans le TAMPON (EDIT_BUFFER_OFF) - PAS la RAM reelle. L'adresse
; affichee au debut de chaque ligne reste la vraie adresse RAM
; (EDIT_BASE_OFF + decalage), pour que l'utilisateur s'y retrouve. Les
; lignes au-dela de la taille de la plage restent vides. Termine en
; positionnant le curseur materiel du LCD (edit_ram_place_cursor).
;
; IMPORTANT: EDIT_SIZE_OFF et EDIT_WINDOW_ROW_OFF sont RELUS a chaque
; ligne (pas gardes dans BX/CX d'une iteration a l'autre): un bug a
; ete trouve et corrige AVANT deploiement ou BX (fenetre) etait
; ecrase par le nombre de colonnes valides de la ligne precedente,
; corrompant le calcul de la ligne suivante.
; ============================================================
edit_ram_draw_grid:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        call    edit_ram_draw_terminal  ; vue terminal (ANSI), independante de la
                                         ; fenetre de 4 lignes du LCD ci-dessous

        call    i2c_lcd_init

        xor     si, si                  ; SI = ligne VISIBLE courante (0-3)
.row_loop:
        mov     bp, EDIT_WINDOW_ROW_OFF
        mov     ax, [bp]                ; AX = ligne logique du haut de la fenetre
        add     ax, si                  ; AX = ligne logique de CETTE ligne visible
        mov     dx, EDIT_COLS
        mul     dx                      ; AX = ligne logique * EDIT_COLS (tient dans
                                          ; AX, max 204*5=1020)
        mov     di, ax                  ; DI = decalage (octets) du 1er octet de
                                          ; cette ligne dans la plage/le tampon

        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille totale (relue a chaque ligne)
        cmp     di, cx
        jae     .row_blank              ; au-dela de la plage - ligne vide

        ; --- selectionne la ligne LCD (0-3 -> LCD_LINE1-4) ---
        cmp     si, 0
        jne     .row_not0
        i2c_lcd_goto LCD_LINE1
        jmp     .row_go
.row_not0:
        cmp     si, 1
        jne     .row_not1
        i2c_lcd_goto LCD_LINE2
        jmp     .row_go
.row_not1:
        cmp     si, 2
        jne     .row_not2
        i2c_lcd_goto LCD_LINE3
        jmp     .row_go
.row_not2:
        i2c_lcd_goto LCD_LINE4
.row_go:
        ; --- adresse REELLE de cette ligne (EDIT_BASE_OFF + DI), sur le
        ; LCD ET l'UART. Sur le LCD: "SSSS:" (EDIT_ADDR_LABEL_WIDTH = 5
        ; caracteres, SANS espace apres les deux-points - contrairement
        ; a l'UART qui, lui, n'est pas contraint en largeur) + EDIT_COLS
        ; (5) cases "XX " (15 caracteres) = EXACTEMENT 20 caracteres,
        ; la largeur du LCD - AUCUN debordement. EDIT_COLS a ete reduit
        ; de 6 a 5 PRECISEMENT pour degager cette place: avec 6 cases
        ; (18 caracteres), ajouter la moindre etiquette d'adresse
        ; depasserait 20 et deborderait dans la ligne PAIREE (LCD_LINE1
        ; <->LCD_LINE3, LCD_LINE2<->LCD_LINE4 partagent le meme bloc de
        ; 40 octets de DDRAM) - bug deja trouve et corrige sur le
        ; materiel reel avec l'ancien format 6 cases + etiquette (voir
        ; Directives.md); NE PAS reaugmenter EDIT_COLS sans retirer
        ; l'etiquette, ou l'inverse. AX necessaire deux fois (LCD PUIS
        ; UART, chacun le detruit - voir leurs contrats) - preserve via
        ; push/pop plutot que de relire EDIT_BASE_OFF+DI deux fois. ---
        mov     bp, EDIT_BASE_OFF
        mov     ax, [bp]
        add     ax, di                  ; AX = adresse reelle de cette ligne
        call    i2c_lcd_tx_hex_word
        mov     al, ':'
        call    i2c_lcd_data

        ; --- nombre de colonnes valides pour cette ligne (EDIT_COLS,
        ; sauf la derniere ligne logique si la taille n'est pas
        ; multiple de EDIT_COLS) ---
        mov     ax, cx
        sub     ax, di                  ; AX = octets restants a partir d'ici
        cmp     ax, EDIT_COLS
        jbe     .cols_ok
        mov     ax, EDIT_COLS
.cols_ok:
        mov     bl, al                  ; BL = nombre de colonnes valides (1-5)

        mov     bp, EDIT_BUFFER_OFF
        add     bp, di                  ; BP = pointeur tampon, debut de cette ligne
        xor     dh, dh                  ; DH = colonne courante (0-4)
.col_loop:
        cmp     dh, bl
        jae     .col_pad
        mov     al, [bp]
        mov     ah, al                  ; AH = copie (survit a i2c_lcd_tx_hex_byte -
                                          ; jamais touche, voir def_tx_hex_*)
        call    i2c_lcd_tx_hex_byte
        mov     al, ' '
        call    i2c_lcd_data
        inc     bp
        jmp     .col_next
.col_pad:
        ; --- au-dela des octets valides de cette derniere ligne
        ; partielle: espaces sur le LCD seulement (garde la grille
        ; alignee) - rien sur l'UART ---
        mov     al, ' '
        call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data
.col_next:
        inc     dh
        cmp     dh, EDIT_COLS
        jb      .col_loop

.row_blank:
        inc     si
        cmp     si, EDIT_ROWS
        jb      .row_loop

        call    edit_ram_place_cursor

        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_term_geometry
; Position de la case COURANTE (EDIT_CURSOR_OFF) sur le TERMINAL: la grille
; est decoupee en PAGES de TERM_ROWS lignes logiques (EDIT_COLS octets
; chacune) - sans etat: la page se deduit de la ligne du curseur.
; Sortie: AX = ligne logique du haut de la page, DH = ligne ecran du
;         curseur, DL = colonne ecran (1-based). Preserve BX/CX/BP.
; ============================================================
edit_ram_term_geometry:
        push    bx
        push    cx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]                ; AX = position lineaire du curseur
        mov     cx, EDIT_COLS
        xor     dx, dx
        div     cx                      ; AX = ligne logique, DX = colonne (0-4)
        mov     bl, dl                  ; BL = colonne
        xor     dx, dx
        mov     cx, TERM_ROWS
        div     cx                      ; AX = page, DX = ligne DANS la page
        mov     bh, dl                  ; BH = ligne dans la page
        mul     cx                      ; AX = page * TERM_ROWS = ligne du haut

        mov     dh, TERM_GRID_ROW
        add     dh, bh                  ; DH = ligne ecran
        mov     dl, bl
        add     dl, bl
        add     dl, bl                  ; 3 caracteres par case ("XX ")
        add     dl, TERM_GRID_COL       ; DL = colonne ecran

        pop     bp
        pop     cx
        pop     bx
        ret

; ============================================================
; edit_ram_draw_terminal
; (Re)dessine la grille d'edition sur le TERMINAL avec des sequences ANSI:
; titre, TERM_ROWS lignes "SSSS: XX XX XX XX XX" (adresse reelle + tampon),
; ligne d'aide, puis place le curseur du terminal SUR LA CASE COURANTE. Chaque
; ligne est repositionnee en absolu (ESC[l;cH) et terminee par ESC[K: le
; dessin se fait EN PLACE, sans effacer l'ecran (l'ecran est efface une seule
; fois par l'action d'edition) - ce qui laisse intacts les registres affiches
; sous la grille par edit_run_action. Les chiffres tapes sont echoes par
; ps2_edit_byte_value/edit_run_byte_value (uart_tx_hex_nibble) exactement
; sur la case, le curseur y etant.
; Preserve tous les registres.
; ============================================================
edit_ram_draw_terminal:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp

        call    edit_ram_term_geometry  ; AX = ligne du haut, DX = position du curseur
        push    dx                      ; (place le curseur en dernier)
        mov     bx, ax                  ; BX = ligne logique du haut de la page

        mov     dh, 1
        mov     dl, 1
        call    uart_ansi_goto
        mov     bp, EDIT_TERM_TITLE_OFF
        mov     si, [bp]
        call    uart_tx_string
        mov     si, txt_ansi_eol
        call    uart_tx_string

        xor     di, di                  ; DI = ligne de la page (0 a TERM_ROWS-1)
.row:
        mov     ax, bx
        add     ax, di                  ; ligne logique
        mov     cx, EDIT_COLS
        mul     cx                      ; AX = decalage (octets) de cette ligne
        push    ax
        mov     dx, di
        add     dl, TERM_GRID_ROW
        mov     dh, dl                  ; DH = ligne ecran
        mov     dl, 1
        call    uart_ansi_goto
        pop     ax                      ; AX = decalage

        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille totale
        cmp     ax, cx
        jae     .eol                    ; au-dela de la plage - ligne vide

        push    ax                      ; decalage
        push    cx                      ; taille
        mov     bp, EDIT_BASE_OFF
        add     ax, [bp]                ; AX = adresse REELLE de la ligne
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        pop     cx                      ; CX = taille
        pop     ax                      ; AX = decalage
        mov     bp, EDIT_BUFFER_OFF
        add     bp, ax                  ; BP = pointeur tampon (debut de ligne)
        sub     cx, ax                  ; CX = octets restants
        cmp     cx, EDIT_COLS
        jbe     .cell
        mov     cx, EDIT_COLS           ; CX = cases de cette ligne (1-5)
.cell:
        mov     al, [bp]
        call    uart_tx_hex_byte
        mov     al, ' '
        call    uart_tx_byte
        inc     bp
        loop    .cell
.eol:
        mov     si, txt_ansi_eol
        call    uart_tx_string
        inc     di
        cmp     di, TERM_ROWS
        jb      .row

        mov     dh, TERM_HELP_ROW
        mov     dl, 1
        call    uart_ansi_goto
        mov     bp, EDIT_TERM_HELP_OFF
        mov     si, [bp]
        call    uart_tx_string
        mov     si, txt_ansi_eol
        call    uart_tx_string

        pop     dx                      ; position de la case courante
        call    uart_ansi_goto

        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_cell_ddram
; Calcule l'adresse DDRAM (SANS le bit de commande) de la case
; COURANTE (EDIT_CURSOR_OFF, ramenee a sa position VISIBLE via
; EDIT_WINDOW_ROW_OFF) - "XX " = 3 caracteres par cellule sur le LCD,
; DECALEE de EDIT_ADDR_LABEL_WIDTH (5) pour laisser la place a
; l'etiquette d'adresse "SSSS:" en tete de chaque ligne (voir
; edit_ram_draw_grid - EDIT_COLS a ete reduit a 5 precisement pour
; que ce total (5 + 5*3 = 20) ne deborde jamais la largeur du LCD).
; Sortie: AH = adresse DDRAM (0-127).
; ============================================================
edit_ram_cell_ddram:
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]                ; AX = position lineaire du curseur
        mov     cx, EDIT_COLS
        xor     dx, dx
        div     cx                      ; AX = ligne logique, DX = colonne (0-4)
        mov     bl, dl                  ; BL = colonne

        mov     bp, EDIT_WINDOW_ROW_OFF
        sub     ax, [bp]                ; AX = ligne VISIBLE (logique - fenetre)
        mov     bh, al                  ; BH = ligne visible (0-3)

        mov     al, bl
        mov     cl, 3
        mul     cl                      ; AX = colonne*3
        mov     cl, al                  ; CL = decalage colonne DANS LA GRILLE (0,3,...,12)

        cmp     bh, 0
        je      .r0
        cmp     bh, 1
        je      .r1
        cmp     bh, 2
        je      .r2
        mov     al, LCD_LINE4 & 07Fh
        jmp     .go
.r0:    mov     al, LCD_LINE1 & 07Fh
        jmp     .go
.r1:    mov     al, LCD_LINE2 & 07Fh
        jmp     .go
.r2:    mov     al, LCD_LINE3 & 07Fh
.go:
        add     al, EDIT_ADDR_LABEL_WIDTH ; decale par l'etiquette d'adresse ("SSSS:",
                                          ; 5 caracteres) en tete de chaque ligne LCD -
                                          ; voir edit_ram_draw_grid
        add     al, cl
        mov     ah, al                  ; AH = adresse DDRAM (sortie)

        pop     bp
        pop     dx
        pop     cx
        pop     bx
        ret

; ============================================================
; edit_ram_place_cursor
; Positionne le curseur materiel du LCD (actif, clignotant) sur la
; cellule courante (voir edit_ram_cell_ddram).
; ============================================================
edit_ram_place_cursor:
        push    ax
        call    edit_ram_cell_ddram
        mov     al, ah
        or      al, 80h
        call    i2c_lcd_command
        mov     al, 00001111b    ; Display ON, curseur ON, clignotement ON
        call    i2c_lcd_command
        pop     ax
        ret

; ============================================================
; edit_ram_write_current
; Ecrit DL DANS LE TAMPON (EDIT_BUFFER_OFF + EDIT_CURSOR_OFF) - jamais
; directement en RAM reelle (voir edit_ram_action, edit_ram_commit_buffer).
; Entree: DL = valeur a ecrire.
; ============================================================
edit_ram_write_current:
        push    ax
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]                ; AX = position lineaire du curseur
        mov     bp, EDIT_BUFFER_OFF
        add     bp, ax                  ; BP = pointeur tampon pour cette case
        mov     [bp], dl

        pop     bp
        pop     ax
        ret

; ============================================================
; edit_ram_scroll_to_cursor
; Ajuste EDIT_WINDOW_ROW_OFF pour que la ligne logique du curseur
; (EDIT_CURSOR_OFF) reste visible (entre la fenetre et fenetre+3) -
; fait defiler d'exactement ce qu'il faut, dans un sens ou l'autre.
; Appelee apres tout deplacement du curseur qui change de ligne
; logique (move_up/move_down/advance).
; ============================================================
edit_ram_scroll_to_cursor:
        push    ax
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; AX = ligne logique du curseur

        mov     bp, EDIT_WINDOW_ROW_OFF
        cmp     ax, [bp]
        jae     .check_bottom
        mov     [bp], ax                ; au-dessus de la fenetre - remonte
        jmp     .done
.check_bottom:
        mov     cx, [bp]
        add     cx, EDIT_ROWS - 1       ; CX = derniere ligne visible actuellement
        cmp     ax, cx
        jbe     .done                   ; toujours visible
        sub     ax, EDIT_ROWS
        inc     ax                      ; nouvelle fenetre = ligne - (EDIT_ROWS-1)
        mov     [bp], ax
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_ram_move_left / _right
; Deplacent le curseur logique (EDIT_CURSOR_OFF) DANS SA LIGNE - fixe
; aux bords de colonne (pas de saut a la ligne suivante/precedente).
; ============================================================
edit_ram_move_left:
        push    ax
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; DX = colonne actuelle (0-5)
        cmp     dx, 0
        je      .done
        dec     word [bp]
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     ax
        ret

edit_ram_move_right:
        push    ax
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        mov     bx, ax                  ; BX = curseur actuel (preserve - AX va
                                          ; etre ecrase par la division)
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; DX = colonne actuelle (0-5)
        cmp     dx, EDIT_COLS-1
        jae     .done                   ; deja en derniere colonne

        inc     bx                      ; BX = candidat
        mov     bp, EDIT_SIZE_OFF
        cmp     bx, [bp]
        jae     .done                   ; deborderait la plage - ne bouge pas

        mov     bp, EDIT_CURSOR_OFF
        mov     [bp], bx
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_move_up / _down
; Deplacent le curseur logique (EDIT_CURSOR_OFF) d'UNE LIGNE LOGIQUE -
; fixes aux bords de la plage (premiere/derniere ligne). Font defiler
; la fenetre visible au besoin (edit_ram_scroll_to_cursor) - c'est ce
; qui permet a la grille de couvrir toute la plage (jusqu'a 1024
; octets = 205 lignes), pas seulement les 4 premieres lignes visibles.
; ============================================================
edit_ram_move_up:
        push    ax
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        cmp     ax, EDIT_COLS
        jb      .done                   ; deja sur la premiere ligne logique
        sub     ax, EDIT_COLS
        mov     [bp], ax
        call    edit_ram_scroll_to_cursor
.done:
        pop     bp
        pop     ax
        ret

edit_ram_move_down:
        push    ax
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     bx, [bp]                ; BX = curseur actuel (preserve)

        ; --- une ligne SUIVANTE existe-t-elle seulement (meme
        ; partielle)? Sans cette verification, un "+6" qui deborde la
        ; plage retomberait sur le dernier octet valide MEME s'il est
        ; sur LA MEME ligne logique (aucune ligne en dessous) - bug
        ; trouve et corrige AVANT deploiement par trace manuelle (voir
        ; Directives.md): taille=4 (une seule ligne partielle) faisait
        ; sauter du debut a la fin de CETTE ligne au lieu de ne rien
        ; faire. ---
        mov     ax, bx
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; AX = ligne logique courante (DX jete)
        inc     ax                      ; AX = ligne logique SUIVANTE
        mov     cx, 6
        mul     cx                      ; AX = 1er octet de cette ligne suivante
                                          ; (DX ecrase a 0 - le produit tient
                                          ; dans AX, max 171*6=1026)

        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille totale
        cmp     ax, cx
        jae     .done                   ; aucune ligne suivante - fixe (pas de
                                          ; deplacement)

        ; --- il y a une ligne suivante: nouvelle position = curseur+6,
        ; ou le dernier octet valide si cette ligne est partielle et
        ; que la colonne courante n'y existe pas ---
        mov     ax, bx
        add     ax, EDIT_COLS
        cmp     ax, cx
        jb      .have_candidate
        mov     ax, cx
        dec     ax                      ; AX = dernier octet valide (taille-1)
.have_candidate:
        cmp     ax, bx
        je      .done                   ; aucun changement reel

        mov     bp, EDIT_CURSOR_OFF
        mov     [bp], ax
        call    edit_ram_scroll_to_cursor
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_advance
; Deplace le curseur logique (EDIT_CURSOR_OFF) a la case SUIVANTE en
; ordre de lecture (gauche a droite, puis ligne suivante) - appelee
; apres Entree pour passer automatiquement a l'octet suivant. Fixe a
; la derniere case de la plage (pas de retour au debut). Fait defiler
; la fenetre visible au besoin.
; ============================================================
edit_ram_advance:
        push    ax
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        inc     ax
        mov     bp, EDIT_SIZE_OFF
        cmp     ax, [bp]
        jae     .done                   ; deja sur la derniere case - ne bouge pas

        mov     bp, EDIT_CURSOR_OFF
        mov     [bp], ax
        call    edit_ram_scroll_to_cursor
.done:
        pop     bp
        pop     ax
        ret

; ============================================================
; print_reg_hex_bin_uart
; Affiche AX en hexadecimal PUIS en binaire sur l'UART, separes par 2
; espaces ("HHHH  BBBBBBBBBBBBBBBB") - le libelle ("AX=" etc.) doit
; deja avoir ete affiche par l'appelant au prealable (voir
; registers_dump_action, qui utilise la macro "print" pour ca).
; Entree: AX = valeur a afficher.
; Detruit: AX, BX (voir uart_tx_hex_word/uart_tx_bin_word). Jamais
; CX/DX/SI/DI/ES/BP.
; ============================================================
print_reg_hex_bin_uart:
        push    ax                   ; uart_tx_hex_word DETRUIT AX - sauvegarde
                                      ; pour l'affichage binaire qui suit
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        pop     ax
        call    uart_tx_bin_word
        ret

; ============================================================
; registers_dump_action
; Option "3) Registres CPU" du sous-menu Memory functions (voir
; .dump_menu, start:): affiche l'etat courant des registres du 8088
; (AX,BX,CX,DX,SI,DI,BP,SP,CS,DS,ES,SS,IP,FLAGS) sur le LCD (pagine
; sur 2 ecrans - 14 valeurs, trop pour les 4x20 caracteres
; disponibles d'un coup) et sur l'UART (tout d'un coup, format
; "ergonomique" inspire de DEBUG.COM - le debogueur DOS classique -
; avec decodage complet des FLAGS, demande explicitement).
;
; CAPTURE: tout est fige des l'entree, AVANT le moindre usage de
; AX/BX/CX/DX/SI/DI comme registre de travail pour l'affichage -
; chaque registre est empile, puis relu ensuite via [bp+/-N] (SS par
; defaut sur le 8086 pour cette forme d'adressage - meme motif que
; int16h_handler/.set_flags, qui utilise deja "mov bp,sp" pour
; adresser la pile directement). Details de chaque valeur:
;
;   IP affiche = ADRESSE DE RETOUR, deja empilee par le CALL qui a
;   mene ici (voir [bp+2] ci-dessous) - la valeur exacte a laquelle
;   l'execution reprendra une fois cette action terminee, equivalent
;   exact de ce qu'un debogueur montrerait a un point d'arret place
;   juste apres ce CALL.
;
;   SP affiche = SP tel que vu par l'APPELANT, avant ce CALL (donc
;   avant que CALL n'empile IP et avant notre propre "push bp") -
;   simple calcul BP+4, jamais relu depuis la pile (rien n'est
;   empile "pour" cette valeur - c'est la position de BP elle-meme,
;   decalee, qui la represente).
;
;   CS/DS/ES/SS/FLAGS: empiles uniquement pour pouvoir les LIRE (le
;   8086 n'a pas de "MOV reg,FLAGS" ni de "MOV reg,CS" utilisable
;   pour ecrire ailleurs qu'empiler - PUSHF/PUSH CS etc. restent la
;   seule facon). Ces 5 mots ne sont PAS remis dans un registre au
;   retour (voir .done: "add sp,10") puisque cette routine ne les a
;   jamais reellement MODIFIES - seulement empiles comme donnee.
;
; Navigation (comme edit_ram_action): fleches Gauche/Droite pour
; changer de page LCD (1/2, avec retour a la page 1 depuis la page
; 2), Echap pour revenir au sous-menu Memory functions. Toute autre touche
; est ignoree (pas de redessin inutile - rien ne change tant que la
; page ne change pas). L'UART, lui, affiche tout en une seule fois
; des l'entree (un flux serie n'a pas de largeur limitee comme le
; LCD).
; ============================================================
registers_dump_action:
        push    bp
        mov     bp, sp                   ; [bp+0]=BP original, [bp+2]=IP de retour
                                          ; (empile par le CALL qui a mene ici)

        ; --- registres "segment/flags" - jamais modifies par cette
        ; routine, empiles seulement pour pouvoir les afficher (voir
        ; .done: liberes sans etre repop-es dans un registre) ---
        pushf                            ; [bp-2]  = FLAGS
        push    ss                       ; [bp-4]  = SS
        push    es                       ; [bp-6]  = ES
        push    ds                       ; [bp-8]  = DS
        push    cs                       ; [bp-10] = CS

        ; --- registres "generaux" - utilises comme scratch plus bas
        ; pour composer l'affichage, donc DOIVENT etre restaures
        ; avant le retour (voir .done) ---
        push    ax                       ; [bp-12] = AX
        push    bx                       ; [bp-14] = BX
        push    cx                       ; [bp-16] = CX
        push    dx                       ; [bp-18] = DX
        push    si                       ; [bp-20] = SI
        push    di                       ; [bp-22] = DI

        call    i2c_lcd_init                 ; ecran LCD propre pour cet affichage

        ; ---------------------------------------------------------
        ; UART: chaque registre affiche en HEXADECIMAL PUIS EN
        ; BINAIRE ("AX=HHHH  BBBBBBBBBBBBBBBB"), 2 registres par
        ; ligne (voir print_reg_hex_bin_uart). FLAGS a part, sur SA
        ; PROPRE ligne (hexa + binaire + mnemoniques), apres une ligne
        ; vide de separation - voir txt_reg_*/txt_flag_*_set/clear,
        ; section donnees.
        ; ---------------------------------------------------------
        print   txt_reg_banniere, UART

        print   txt_reg_ax, UART
        mov     ax, [bp-12]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bx, UART
        mov     ax, [bp-14]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_cx, UART
        mov     ax, [bp-16]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_dx, UART
        mov     ax, [bp-18]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_si, UART
        mov     ax, [bp-20]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_di, UART
        mov     ax, [bp-22]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_sp, UART
        mov     ax, bp
        add     ax, 4                    ; SP vu par l'appelant (voir en-tete)
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bp, UART
        mov     ax, [bp+0]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ds, UART
        mov     ax, [bp-8]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_es, UART
        mov     ax, [bp-6]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ss, UART
        mov     ax, [bp-4]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_cs, UART
        mov     ax, [bp-10]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ip, UART
        mov     ax, [bp+2]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART
        print   txt_crlf, UART          ; ligne vide avant FLAGS (voir en-tete)

        ; --- FLAGS SEUL sur sa ligne: hexa, binaire, PUIS mnemoniques
        ; (ordre DEBUG.COM: OF DF IF SF ZF AF PF CF) - DX charge UNE
        ; FOIS pour les 8 invocations de uart_flag_bit (voir sa
        ; definition, section macros) ---
        print   txt_reg_flags_prefix, UART
        mov     ax, [bp-2]
        call    print_reg_hex_bin_uart
        print   txt_reg_flags_sep, UART

        mov     dx, [bp-2]
        uart_flag_bit 0800h, txt_flag_of_set, txt_flag_of_clear
        uart_flag_bit 0400h, txt_flag_df_set, txt_flag_df_clear
        uart_flag_bit 0200h, txt_flag_if_set, txt_flag_if_clear
        uart_flag_bit 0080h, txt_flag_sf_set, txt_flag_sf_clear
        uart_flag_bit 0040h, txt_flag_zf_set, txt_flag_zf_clear
        uart_flag_bit 0010h, txt_flag_af_set, txt_flag_af_clear
        uart_flag_bit 0004h, txt_flag_pf_set, txt_flag_pf_clear
        uart_flag_bit 0001h, txt_flag_cf_set, txt_flag_cf_clear
        print   txt_crlf, UART
        print   txt_crlf, UART

        ; ---------------------------------------------------------
        ; LCD: pagine sur 2 ecrans (voir en-tete) - SI=0 -> page 1
        ; (AX/BX/CX/DX/SI/DI/SP/BP), SI=1 -> page 2 (CS/DS/ES/SS/IP/
        ; FLAGS, decodees en toutes lettres sur la ligne 4). Le
        ; numero de page vit dans SI plutot que DX: .draw_page2
        ; recharge DX avec la valeur de FLAGS pour son decodage en
        ; lettres (voir plus bas, "mov dx,[bp-2]"), ce qui ecraserait
        ; un numero de page qui y aurait ete range - SI, lui, n'est
        ; JAMAIS touche par gotoxy/print/i2c_lcd_tx_hex_word/i2c_lcd_data/
        ; ps2_get_char (tous le preservent - voir leurs en-tetes
        ; respectifs), donc stable sur tout ce sous-flux. La valeur
        ; ORIGINALE de SI (celle de l'appelant) a deja ete affichee
        ; plus haut (UART) et relue depuis [bp-20] - SI est donc
        ; libre ici pour servir de simple numero de page.
        ; ---------------------------------------------------------
        xor     si, si                   ; page courante = 0 (page 1)

.redraw:
        cmp     si, 0
        je      .draw_page1
        jmp     .draw_page2

.draw_page1:
        gotoxy  0, 0, LCDI2C
        print   txt_lcd_reg_ax, LCDI2C
        mov     ax, [bp-12]
        call    i2c_lcd_tx_hex_word
        gotoxy  0, 9, LCDI2C
        print   txt_lcd_reg_bx, LCDI2C
        mov     ax, [bp-14]
        call    i2c_lcd_tx_hex_word
        gotoxy  0, 17, LCDI2C
        print   txt_lcd_page1, LCDI2C

        gotoxy  1, 0, LCDI2C
        print   txt_lcd_reg_cx, LCDI2C
        mov     ax, [bp-16]
        call    i2c_lcd_tx_hex_word
        gotoxy  1, 9, LCDI2C
        print   txt_lcd_reg_dx, LCDI2C
        mov     ax, [bp-18]
        call    i2c_lcd_tx_hex_word

        gotoxy  2, 0, LCDI2C
        print   txt_lcd_reg_si, LCDI2C
        mov     ax, [bp-20]
        call    i2c_lcd_tx_hex_word
        gotoxy  2, 9, LCDI2C
        print   txt_lcd_reg_di, LCDI2C
        mov     ax, [bp-22]
        call    i2c_lcd_tx_hex_word

        gotoxy  3, 0, LCDI2C
        print   txt_lcd_reg_sp, LCDI2C
        mov     ax, bp
        add     ax, 4                    ; SP vu par l'appelant (voir en-tete)
        call    i2c_lcd_tx_hex_word
        gotoxy  3, 9, LCDI2C
        print   txt_lcd_reg_bp, LCDI2C
        mov     ax, [bp+0]
        call    i2c_lcd_tx_hex_word
        jmp     .wait_key

.draw_page2:
        gotoxy  0, 0, LCDI2C
        print   txt_lcd_reg_cs, LCDI2C
        mov     ax, [bp-10]
        call    i2c_lcd_tx_hex_word
        gotoxy  0, 9, LCDI2C
        print   txt_lcd_reg_ip, LCDI2C
        mov     ax, [bp+2]
        call    i2c_lcd_tx_hex_word
        gotoxy  0, 17, LCDI2C
        print   txt_lcd_page2, LCDI2C

        gotoxy  1, 0, LCDI2C
        print   txt_lcd_reg_ds, LCDI2C
        mov     ax, [bp-8]
        call    i2c_lcd_tx_hex_word
        gotoxy  1, 9, LCDI2C
        print   txt_lcd_reg_es, LCDI2C
        mov     ax, [bp-6]
        call    i2c_lcd_tx_hex_word

        gotoxy  2, 0, LCDI2C
        print   txt_lcd_reg_ss, LCDI2C
        mov     ax, [bp-4]
        call    i2c_lcd_tx_hex_word
        gotoxy  2, 9, LCDI2C
        print   txt_lcd_reg_fl, LCDI2C
        mov     ax, [bp-2]
        call    i2c_lcd_tx_hex_word

        ; --- ligne 4: FLAGS decodees en 8 lettres (meme ordre que
        ; l'UART: O D I S Z A P C = OF DF IF SF ZF AF PF CF) -
        ; MAJUSCULE si le bit est a 1, minuscule si a 0 (+20h, motif
        ; standard ASCII maj->min). "i2c_lcd_goto" (PAS "gotoxy"): ecrit
        ; directement au LCD sans passer par int10h (aucun "print" de
        ; chaine ici, seulement des i2c_lcd_data au fil de l'eau - voir
        ; l'en-tete de int10h_print_string: "gotoxy" seul, sans
        ; "print" a la suite, NE deplace PAS le curseur PHYSIQUE, donc
        ; ne convient pas ici). Complete a 20 caracteres (5 espaces de
        ; remplissage finaux) pour ecraser tout residu de la page 1
        ; (ligne 4 plus courte, "SP=xxxx  BP=xxxx" = 16 caracteres). ---
        i2c_lcd_goto LCD_LINE4
        mov     dx, [bp-2]               ; DX = FLAGS (relit depuis la pile - le "DX
                                          ; page" servait seulement a choisir cette
                                          ; branche, plus besoin maintenant)

        mov     al, 'O'
        test    dx, 0800h
        jnz     .p2_of
        add     al, 20h
.p2_of: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'D'
        test    dx, 0400h
        jnz     .p2_df
        add     al, 20h
.p2_df: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'I'
        test    dx, 0200h
        jnz     .p2_if
        add     al, 20h
.p2_if: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'S'
        test    dx, 0080h
        jnz     .p2_sf
        add     al, 20h
.p2_sf: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'Z'
        test    dx, 0040h
        jnz     .p2_zf
        add     al, 20h
.p2_zf: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'A'
        test    dx, 0010h
        jnz     .p2_af
        add     al, 20h
.p2_af: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'P'
        test    dx, 0004h
        jnz     .p2_pf
        add     al, 20h
.p2_pf: call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data

        mov     al, 'C'
        test    dx, 0001h
        jnz     .p2_cf
        add     al, 20h
.p2_cf: call    i2c_lcd_data

        mov     cx, 5                    ; 5 espaces de remplissage finaux (voir
.p2_pad:                                 ; commentaire ci-dessus - 15+5=20)
        mov     al, ' '
        call    i2c_lcd_data
        loop    .p2_pad

.wait_key:
        call    ps2_get_char

        cmp     al, 27                   ; Echap: retour au sous-menu Memory functions
        je      .done

        cmp     al, PS2_KEY_LEFT
        je      .toggle_page
        cmp     al, PS2_KEY_RIGHT
        je      .toggle_page
        jmp     .wait_key                ; touche non pertinente - ignoree, rien
                                          ; n'a change, pas besoin de redessiner

.toggle_page:
        xor     si, 1                    ; bascule 0<->1 (page 1 <-> page 2)
        jmp     .redraw

.done:
        ; --- IMPORTANT: restaurer AX/BX/CX/DX/SI/DI (empiles APRES
        ; FLAGS/SS/ES/DS/CS, donc au sommet de la pile en ce point -
        ; voir l'entree de cette routine) AVANT de liberer l'espace de
        ; FLAGS/SS/ES/DS/CS avec "add sp,10": faire l'inverse (add sp
        ; puis pop) depilerait les MAUVAISES valeurs dans AX..DI. ---
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        add     sp, 10                   ; libere FLAGS/SS/ES/DS/CS (5 mots, jamais
                                          ; modifies par cette routine - rien a
                                          ; restaurer, juste liberer la pile)
        pop     bp
        ret

; ============================================================
; edit_run_action
; Option "4) Edit+Run RAM" du sous-menu Memory functions (voir .dump_menu,
; start:): edite la RAM a une adresse FIXE, 1000:0000 (deuxieme bloc
; de 64K, oppose au segment 0000h de edit_ram_action), et permet
; d'EXECUTER le code qui y a ete saisi via la touche 'r'/'R'.
;
; Reutilise TOUT l'appareil de edit_ram_action (grille, defilement,
; tampon - edit_ram_draw_grid/cell_ddram/place_cursor/write_current/
; scroll_to_cursor/move_left/right/up/down/advance sont agnostiques du
; segment: ils ne touchent jamais a la "vraie" RAM, seulement au
; tampon EDIT_BUFFER_OFF - voir leurs en-tetes), sauf pour charger/
; valider le tampon vers la vraie RAM (edit_run_load_buffer/
; commit_buffer, segment 1000h) et pour la composition d'un octet
; (edit_run_byte_value au lieu de ps2_edit_byte_value - voir plus bas,
; necessaire pour reconnaitre 'r'/'R' PENDANT la saisie).
;
; AUCUNE SAISIE (demande explicite - accelere les tests): l'adresse de
; depart est TOUJOURS 0000h (donc 1000:0000) et la TAILLE est TOUJOURS
; EDIT_RUN_SIZE (255 octets, largement sous la zone reservee
; 0F800h-0FFFFh et sous la pile active SS=1000h) - toutes deux fixees
; directement dans EDIT_BASE_OFF/EDIT_SIZE_OFF, sans aucun prompt: la
; grille s'affiche immediatement.
;
; Touches (identiques a edit_ram_action, PLUS 'r'/'R'):
;   Echap - ANNULE toute l'edition (tampon abandonne), retour au menu.
;   Q/q   - VALIDE (tampon -> RAM reelle a 1000:0000), SANS executer,
;           retour au menu.
;   R/r   - VALIDE (comme Q/q), PUIS EXECUTE le code a 1000:0000 (voir
;           edit_run_execute_and_show) et affiche les registres sur
;           l'UART, PUIS REVIENT A LA FENETRE D'EDITION (PAS au menu -
;           permet de relancer 'r' sans ressaisir le code). RECONNUE A
;           TOUT MOMENT, meme AU MILIEU de la composition d'un octet
;           (voir edit_run_byte_value) - dans ce cas, le chiffre
;           partiel non encore valide est ABANDONNE (rien n'est ecrit
;           pour cette case).
;   Chiffre hexa - comme edit_ram_action, SAUF qu'Entree n'est PLUS
;           NECESSAIRE pour valider un octet COMPLET: le 2e chiffre
;           hexa valide et avance AUTOMATIQUEMENT (Entree reste
;           disponible pour valider un octet d'UN SEUL chiffre).
;   (fleches: voir edit_ram_action)
; ============================================================
edit_run_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    i2c_lcd_init

        ; --- initialise le DEBUT de la RAM reelle (1000:0000) avec un
        ; petit programme de test par defaut ("inc ax" / "inc cx" /
        ; "mul cx" / "add bx,2" / "retf") - UNIQUEMENT ICI, A L'ENTREE dans cette
        ; option depuis le menu (demande explicite): PAS a chaque
        ; retour de RETF (edit_run_execute_and_show revient directement
        ; a .redraw, qui ne repasse jamais ici) - sinon toute
        ; modification faite par l'utilisateur avant de tester 'r'
        ; serait perdue a chaque execution. DS=CS en PERMANENCE (voir
        ; start:), donc [SI] lit directement la ROM sans changer DS. ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, 0
        mov     si, edit_run_default_code
        mov     cx, edit_run_default_code_len
.init_default:
        mov     al, [si]
        mov     [es:di], al
        inc     si
        inc     di
        loop    .init_default

        ; --- adresse/taille FIXES (0000h/255) - aucune saisie (voir
        ; en-tete) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     word [es:di], 0
        mov     di, EDIT_SIZE_OFF
        mov     word [es:di], EDIT_RUN_SIZE

        ; --- remet a 0 les registres generaux PERSISTANTS (RUN_REG_*_
        ; OFF, voir include/hardware.inc et edit_run_execute_and_show)
        ; - UNE SEULE FOIS ICI, a l'entree dans une NOUVELLE session
        ; d'edition (pas a chaque execution - voir plus bas). ---
        mov     di, RUN_REG_AX_OFF
        mov     word [es:di], 0
        mov     di, RUN_REG_BX_OFF
        mov     word [es:di], 0
        mov     di, RUN_REG_CX_OFF
        mov     word [es:di], 0
        mov     di, RUN_REG_DX_OFF
        mov     word [es:di], 0
        mov     di, RUN_REG_SI_OFF
        mov     word [es:di], 0
        mov     di, RUN_REG_DI_OFF
        mov     word [es:di], 0

        print   txt_run_address, UART
        print   txt_run_help, UART

        call    edit_run_load_buffer            ; copie 1000:0000.. (RAM reelle, deja
                                                  ; initialisee ci-dessus) -> tampon

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_CURSOR_OFF
        mov     word [es:di], 0
        mov     di, EDIT_WINDOW_ROW_OFF
        mov     word [es:di], 0

        mov     di, EDIT_TERM_TITLE_OFF
        mov     word [es:di], txt_term_title_run
        mov     di, EDIT_TERM_HELP_OFF
        mov     word [es:di], txt_term_help_run
        mov     si, txt_ansi_cls                ; terminal: efface l'ecran (une fois)
        call    uart_tx_string

.redraw:
        call    edit_ram_draw_grid

.wait_key:
        call    ps2_get_char

        cmp     al, 27                          ; Echap: annule (rien recopie)
        je      .cancel

        cmp     al, 'q'
        je      .commit_only
        cmp     al, 'Q'
        je      .commit_only

        cmp     al, 'r'
        je      .commit_and_run
        cmp     al, 'R'
        je      .commit_and_run

        cmp     al, PS2_KEY_LEFT
        jne     .not_left
        call    edit_ram_move_left
        jmp     .redraw
.not_left:
        cmp     al, PS2_KEY_RIGHT
        jne     .not_right
        call    edit_ram_move_right
        jmp     .redraw
.not_right:
        cmp     al, PS2_KEY_UP
        jne     .not_up
        call    edit_ram_move_up
        jmp     .redraw
.not_up:
        cmp     al, PS2_KEY_DOWN
        jne     .not_down
        call    edit_ram_move_down
        jmp     .redraw
.not_down:
        mov     dl, al                   ; DL = touche deja lue (sauvegardee -
                                          ; edit_ram_cell_ddram detruit AX)
        call    edit_ram_cell_ddram      ; AH = adresse DDRAM de la case courante
        mov     al, dl                   ; restaure AL = touche (AH inchange)
        call    edit_run_byte_value      ; AL(entree)=touche deja lue; DL/CF = sortie (voir en-tete plus bas)
        jc      .redraw                  ; Entree sans saisie (DL=0 dans ce cas) - rien a ecrire.
                                          ; VERIFIE AVANT "cmp dl,1": ce dernier ECRASERAIT le CF
                                          ; de sortie d'edit_run_byte_value (0-1 = emprunt = CF=1
                                          ; meme quand DL=0 signifiait "valeur prete", CF=0) - bug
                                          ; trouve sur le materiel reel (2e chiffre "avale" une
                                          ; case qui restait a 00), corrige en testant jc EN PREMIER.
        cmp     dl, 1
        je      .commit_and_run          ; 'r'/'R' tapee PENDANT la saisie - execute immediatement
        mov     dl, bl                   ; DL = valeur a ecrire (survit a l'appel)
        call    edit_ram_write_current   ; ecrit DANS LE TAMPON
        call    edit_ram_advance         ; passe a la case suivante (ordre de lecture)
        jmp     .redraw

.commit_only:
        call    edit_run_commit_buffer          ; recopie le tampon -> RAM reelle (1000:0000)

.cancel:
        mov     si, txt_ansi_cls                ; terminal: ecran propre pour le menu
        call    uart_tx_string
        jmp     .done

.commit_and_run:
        call    edit_run_commit_buffer          ; recopie le tampon -> RAM reelle (1000:0000)
        call    edit_run_execute_and_show       ; execute et affiche les registres (UART)
        jmp     .redraw                          ; retour a la fenetre d'edition (PAS au menu) -
                                                  ; permet de relancer 'r' sans ressaisir le code

.done:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_run_byte_value
; Variante de ps2_edit_byte_value (lib/ps2.asm, INCHANGEE - reste
; utilisee par edit_ram_action) POUR edit_run_action uniquement: cette
; derniere BOUCLE INTERNEMENT sur ps2_get_char jusqu'a Entree (touche
; par touche, jamais rendue a l'appelant avant), ce qui AVALERAIT
; SILENCIEUSEMENT 'r'/'R' s'il etait tape APRES un premier chiffre (la
; boucle .wait_key exterieure d'edit_run_action, qui le reconnait,
; elle, ne serait jamais re-atteinte). Cette variante ajoute donc:
;   1) 'r'/'R' reconnue A CHAQUE touche lue (avant meme le premier
;      chiffre) - retour immediat, chiffre(s) partiel(s) ABANDONNES.
;   2) Validation AUTOMATIQUE apres le 2e chiffre hexa - Entree n'est
;      plus NECESSAIRE pour un octet complet (elle reste disponible
;      pour valider un octet d'UN SEUL chiffre, comme avant).
;
; Entree: AL = premier caractere deja lu par l'appelant (edit_ram_cell_
;         ddram y a ete appele juste avant - AH = adresse DDRAM de la
;         cellule, inchange par cette routine).
; Sortie: BX = valeur composee (uniquement si DL=0 et CF=0).
;         DL=0, CF=0: au moins un chiffre tape - valeur (BX) a ecrire.
;         DL=0, CF=1: Entree pressee sans aucune saisie - rien a
;                      ecrire (comme ps2_edit_byte_value).
;         DL=1: 'r'/'R' pressee (a tout moment) - BX indefini, rien a
;               ecrire, l'appelant doit executer immediatement (voir
;               edit_run_action, .commit_and_run).
; Detruit: AX, CX, DX (BX/DL = sortie). Jamais SI/DI/ES/BP.
; ============================================================
edit_run_byte_value:
        push    si              ; SI = accumulateur interne (voir
                                 ; ps2_edit_byte_value - meme raison)
        xor     si, si
        xor     dh, dh          ; DH = nombre de chiffres saisis (0-2)
        jmp     .have_key       ; traite d'abord le caractere deja lu

.next_key:
        call    ps2_get_char
.have_key:
        cmp     al, 'r'         ; 'r'/'R': interrompt A TOUT MOMENT (voir
        je      .interrupt_run  ; en-tete) - verifie AVANT toute autre
        cmp     al, 'R'         ; interpretation du caractere
        je      .interrupt_run

        cmp     al, 13          ; Entree ?
        je      .commit
        cmp     al, 8           ; retour arriere ?
        je      .backspace
        call    ps2_hex_digit_value
        jc      .next_key       ; touche non geree - ignore
        cmp     dh, 2
        jae     .next_key       ; deja 2 chiffres - ignore
        mov     dl, al
        mov     cl, 4
        shl     si, cl
        push    dx              ; DH(compteur)/DL(valeur) sauvegardes ensemble
        mov     dh, 0
        add     si, dx
        pop     dx
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    i2c_lcd_tx_hex_nibble
        inc     dh
        cmp     dh, 2
        jb      .next_key
        jmp     .commit          ; 2e chiffre: valide AUTOMATIQUEMENT (voir en-tete)

.backspace:
        cmp     dh, 0
        je      .next_key
        dec     dh
        mov     cl, 4
        shr     si, cl
        mov     al, 8
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        mov     al, 8
        call    uart_tx_byte
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    i2c_lcd_command
        mov     al, ' '
        call    i2c_lcd_data
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    i2c_lcd_command
        jmp     .next_key

.commit:
        cmp     dh, 0
        je      .empty
        mov     bx, si          ; BX = valeur finale (sortie documentee)
        mov     dl, 0
        pop     si
        clc
        ret
.empty:
        mov     dl, 0
        pop     si
        stc
        ret
.interrupt_run:
        mov     dl, 1
        pop     si
        clc
        ret

; ============================================================
; edit_run_execute_and_show
; Execute le code injecte par edit_run_action a l'adresse FIXE
; 1000:0000 via un CALL FAR IMMEDIAT (opcode 9A, encode directement
; par NASM pour "call seg:off" avec des constantes) - le code injecte
; DOIT se terminer par RETF (retour LOINTAIN, depile IP ET CS),
; JAMAIS un RET pres: un RET pres ne depilerait que IP et laisserait
; CS empile, corrompant la pile et faisant planter la carte au retour
; (voir README.md pour la regle destinee au programmeur du code
; injecte).
;
; CAPTURE: CALL/RETF ne modifient JAMAIS un registre general ni
; FLAGS - seulement CS:IP (et implicitement SP, via les push/pop
; internes de l'instruction elle-meme). Donc, immediatement apres le
; retour du CALL FAR, TOUT registre est EXACTEMENT ce que le code
; injecte a laisse - a condition de ne rien faire d'autre qu'empiler
; (jamais de MOV/ADD/etc. qui le detruirait) avant de les avoir tous
; sauvegardes. Meme motif que registers_dump_action (voir plus haut),
; mais SANS le decalage du "CALL qui a mene ici": ici, un seul mot
; ("push bp") est empile avant "mov bp,sp", donc:
;   [bp+0] = BP (tel que laisse par le code injecte)
;   bp+2   = SP (tel que laisse par le code injecte, PAS relu depuis
;            la pile - simple calcul, comme "bp+4" dans
;            registers_dump_action, mais avec un seul mot de decalage
;            ici au lieu de deux puisqu'il n'y a pas de "CALL" externe
;            a comptabiliser)
;
; ATTENTION: si le code injecte modifie SS sans le restaurer, les
; push/pop de CETTE routine (qui s'executent APRES son retour)
; cibleraient une pile invalide - risque inherent a l'execution de
; code arbitraire, comme la commande "G" de DEBUG.COM.
;
; Affiche UNIQUEMENT sur l'UART (demande explicite - pas de LCD pour
; cet affichage): AX/BX/CX/DX/SI/DI/SP/BP/DS/ES/SS/CS en hexadecimal
; et binaire (2 registres par ligne, voir print_reg_hex_bin_uart),
; puis FLAGS sur sa propre ligne (hexa + binaire + mnemoniques,
; reutilise txt_reg_*/txt_flag_*_set/clear/uart_flag_bit - voir
; registers_dump_action). IP non affiche (aucune signification utile
; ici, contrairement a registers_dump_action).
; ============================================================
edit_run_execute_and_show:
        ; --- restaure les registres generaux PERSISTANTS (RUN_REG_*_
        ; OFF, voir include/hardware.inc) - laisses par la PRECEDENTE
        ; execution (ou remis a 0 par edit_run_action si c'est la
        ; premiere depuis l'entree dans l'option). Sans cette
        ; restauration, AX/BX/CX/DX/SI/DI vaudraient ce que le code de
        ; menu/clavier qui s'execute ENTRE deux appuis sur 'r' (ps2_
        ; get_char, edit_ram_draw_grid, etc.) leur a laisse - rendant
        ; impossible tout test CUMULATIF (ex: "add ax,2" repete, cense
        ; incrementer AX a chaque execution). BP libre ICI (le "push
        ; bp/mov bp,sp" qui l'ancre a la trame de pile plus bas n'a pas
        ; encore eu lieu) - [bp] adresse SS (=VAR_SEG en permanence)
        ; par defaut. ---
        mov     bp, RUN_REG_AX_OFF
        mov     ax, [bp]
        mov     bp, RUN_REG_BX_OFF
        mov     bx, [bp]
        mov     bp, RUN_REG_CX_OFF
        mov     cx, [bp]
        mov     bp, RUN_REG_DX_OFF
        mov     dx, [bp]
        mov     bp, RUN_REG_SI_OFF
        mov     si, [bp]
        mov     bp, RUN_REG_DI_OFF
        mov     di, [bp]

        call    1000h:0000h              ; CALL FAR - le code injecte doit finir par RETF

        push    bp
        mov     bp, sp                   ; [bp+0] = BP (code injecte); bp+2 = SP (code injecte)

        pushf                            ; [bp-2]  = FLAGS
        push    ss                       ; [bp-4]  = SS
        push    es                       ; [bp-6]  = ES
        push    ds                       ; [bp-8]  = DS
        push    cs                       ; [bp-10] = CS
        push    ax                       ; [bp-12] = AX
        push    bx                       ; [bp-14] = BX
        push    cx                       ; [bp-16] = CX
        push    dx                       ; [bp-18] = DX
        push    si                       ; [bp-20] = SI
        push    di                       ; [bp-22] = DI

        ; --- re-persiste les 6 registres generaux (RUN_REG_*_OFF) pour
        ; la PROCHAINE execution - ICI, AVANT tout usage d'AX comme
        ; "registre de travail d'affichage" plus bas (qui rendrait leur
        ; valeur CAPTUREE illisible depuis un registre - seul [bp-N]
        ; resterait fiable). "[ss:bx]": BX seul adresse DS par defaut
        ; sur le 8086 (PAS SS comme BP) - le prefixe force SS (=VAR_SEG
        ; en permanence) SANS sacrifier BP, qui doit rester l'ancre de
        ; cette trame de pile pour tout le reste de la routine. BX
        ; lui-meme est relu depuis la pile ([bp-14]) plutot que depuis
        ; le registre, puisqu'il vient de servir de pointeur. ---
        mov     bx, RUN_REG_AX_OFF
        mov     [ss:bx], ax
        mov     bx, RUN_REG_CX_OFF
        mov     [ss:bx], cx
        mov     bx, RUN_REG_DX_OFF
        mov     [ss:bx], dx
        mov     bx, RUN_REG_SI_OFF
        mov     [ss:bx], si
        mov     bx, RUN_REG_DI_OFF
        mov     [ss:bx], di
        mov     ax, [bp-14]              ; AX = BX original (BX vient de servir de pointeur)
        mov     bx, RUN_REG_BX_OFF
        mov     [ss:bx], ax

        mov     dh, TERM_REGS_ROW               ; registres SOUS la grille (voir
        mov     dl, 1                            ; edit_ram_draw_terminal), sans la
        call    uart_ansi_goto                   ; deplacer ni la faire defiler
        mov     si, txt_ansi_eos                 ; efface l'ancien affichage dessous
        call    uart_tx_string
        print   txt_run_result_banner, UART

        print   txt_reg_ax, UART
        mov     ax, [bp-12]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bx, UART
        mov     ax, [bp-14]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_cx, UART
        mov     ax, [bp-16]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_dx, UART
        mov     ax, [bp-18]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_si, UART
        mov     ax, [bp-20]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_di, UART
        mov     ax, [bp-22]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_sp, UART
        mov     ax, bp
        add     ax, 2                    ; SP tel que laisse par le code injecte (voir en-tete)
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bp, UART
        mov     ax, [bp+0]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ds, UART
        mov     ax, [bp-8]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_es, UART
        mov     ax, [bp-6]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ss, UART
        mov     ax, [bp-4]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_cs, UART
        mov     ax, [bp-10]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART
        print   txt_crlf, UART           ; ligne vide avant FLAGS

        print   txt_reg_flags_prefix, UART
        mov     ax, [bp-2]
        call    print_reg_hex_bin_uart
        print   txt_reg_flags_sep, UART

        mov     dx, [bp-2]
        uart_flag_bit 0800h, txt_flag_of_set, txt_flag_of_clear
        uart_flag_bit 0400h, txt_flag_df_set, txt_flag_df_clear
        uart_flag_bit 0200h, txt_flag_if_set, txt_flag_if_clear
        uart_flag_bit 0080h, txt_flag_sf_set, txt_flag_sf_clear
        uart_flag_bit 0040h, txt_flag_zf_set, txt_flag_zf_clear
        uart_flag_bit 0010h, txt_flag_af_set, txt_flag_af_clear
        uart_flag_bit 0004h, txt_flag_pf_set, txt_flag_pf_clear
        uart_flag_bit 0001h, txt_flag_cf_set, txt_flag_cf_clear
        print   txt_crlf, UART
        print   txt_crlf, UART

        ; --- restaure AX/BX/CX/DX/SI/DI (registres "generaux" de
        ; CETTE routine - ils ne l'etaient plus depuis les push
        ; ci-dessus) AVANT de liberer FLAGS/SS/ES/DS/CS (5 mots,
        ; jamais modifies, juste empiles pour lecture) - meme ordre
        ; que registers_dump_action.done ---
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        add     sp, 10
        pop     bp
        ret

; ============================================================
; ivt_dump_action
; Option "5) IVT" du sous-menu Memory functions (voir .dump_menu) -
; affiche le contenu des IVT_DUMP_COUNT (40) PREMIERS vecteurs de
; l'IVT (INT 00h-27h) - limite volontaire (demande explicite): les
; vecteurs interessants de ce projet (00h-1Fh reserves Intel, 08h
; IR0/8259, 10h/16h "esprit BIOS") vivent tous sous 40, le reste de la
; table (jusqu'a FFh) n'etant que des repetitions de
; int_not_implemented sans interet a parcourir:
;   UART: TOUTE la plage (40 vecteurs) d'un coup ("INT xxh ->
;         SSSS:OOOO : nom -> description"), une seule fois a l'entree
;         - les vecteurs IMPLEMENTES (int10h_handler/int16h_handler/
;         irq0_test_handler/irq1_arduino_handler) en
;         VERT, les autres (en pratique toujours int_not_implemented)
;         sans couleur.
;   LCD I2C: grille DEFILANTE (40 vecteurs, 4 visibles a la fois),
;         "xxh  SSSS:OOOO" par ligne (14 caracteres, bien sous les 20
;         disponibles - pas de couleur possible sur le LCD) - fleches
;         HAUT/BAS pour defiler d'un vecteur, Echap pour revenir au
;         menu. Meme principe que edit_ram_draw_grid (fenetre
;         defilante, IVT_WINDOW_OFF - voir hardware.inc), mais UN SEUL
;         vecteur par ligne (pas de colonnes/cases editables - vue
;         seule, rien a saisir).
;
; Identification "implemente/pas implemente": compare l'OFFSET lu
; dans chaque entree de l'IVT aux adresses des 4 gestionnaires reels
; connus (int10h_handler/int16h_handler/irq0_test_handler/
; irq1_arduino_handler) - le SEGMENT n'est PAS verifie
; separement (tous les gestionnaires, meme
; les futurs, vivent dans la meme ROM = CS ecrit par
; setup_bios_interrupts/init_8259/init_ivt_not_implemented - jamais
; une autre valeur). Toute autre offset (en pratique, toujours celle
; de int_not_implemented) est consideree "non implementee".
; ============================================================
IVT_DUMP_COUNT   equ     40      ; nombre de vecteurs affiches (0 a 39)
IVT_WINDOW_MAX   equ     IVT_DUMP_COUNT - 4   ; derniere fenetre LCD valide (36)

ivt_dump_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        call    i2c_lcd_init
        gotoxy  1, 0, LCDI2C
        print   txt_lcd_ivt_loading, LCDI2C     ; "Chargement IVT..." - le LCD
                                                  ; resterait sinon vide pendant
                                                  ; le dump UART (40 lignes),
                                                  ; laissant croire que la carte
                                                  ; est figee - la grille reelle
                                                  ; (.redraw) l'efface aussitot
                                                  ; le dump UART termine

        ; --- UART: plage complete (0 a IVT_DUMP_COUNT-1), une seule fois ---
        print   txt_ivt_banniere, UART
        xor     bx, bx                   ; BX = vecteur courant (0 a IVT_DUMP_COUNT-1)
.uart_loop:
        xor     ax, ax
        mov     es, ax
        mov     di, bx
        shl     di, 1
        shl     di, 1                    ; DI = vecteur*4
        mov     cx, [es:di+2]            ; CX = segment du gestionnaire
        mov     dx, [es:di]              ; DX = offset du gestionnaire

        print   txt_ivt_int_prefix, UART        ; "INT "
        mov     al, bl
        call    uart_tx_hex_byte
        print   txt_ivt_h_arrow, UART            ; "h -> "
        mov     ax, cx
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, dx
        call    uart_tx_hex_word
        print   txt_ivt_sep, UART                ; " : "

        cmp     dx, int10h_handler
        jne     .u_not10h
        print   txt_ivt_10h, UART
        jmp     .u_line_done
.u_not10h:
        cmp     dx, int16h_handler
        jne     .u_not16h
        print   txt_ivt_16h, UART
        jmp     .u_line_done
.u_not16h:
        cmp     dx, irq0_test_handler
        jne     .u_not_irq0
        print   txt_ivt_irq0, UART
        jmp     .u_line_done
.u_not_irq0:
        cmp     dx, irq1_arduino_handler
        jne     .u_not_irq1
        print   txt_ivt_irq1, UART
        jmp     .u_line_done
.u_not_irq1:
        cmp     dx, int_stubs
        jb      .u_bios
        cmp     dx, int_stubs_end
        jae     .u_bios
        print   txt_ivt_not_impl, UART           ; l'un des petits gestionnaires "non implemente"
        jmp     .u_line_done
.u_bios:
        print   txt_ivt_bios, UART               ; un gestionnaire du BIOS / du DOS
.u_line_done:
        print   txt_crlf, UART

        inc     bx
        cmp     bx, IVT_DUMP_COUNT
        jb      .uart_loop

        ; --- LCD I2C: grille defilante ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, IVT_WINDOW_OFF
        mov     word [es:di], 0

.redraw:
        call    i2c_lcd_init
        mov     bp, IVT_WINDOW_OFF
        mov     si, [bp]                 ; SI = vecteur du haut de la fenetre
        xor     bx, bx                   ; BX = ligne visible (0-3)
.row_loop:
        mov     ax, si
        add     ax, bx                   ; AX = numero de vecteur de cette ligne -
                                          ; survit a tout le reste de l'iteration
                                          ; (jamais ecrase ci-dessous)
        mov     di, ax
        shl     di, 1
        shl     di, 1                    ; DI = vecteur*4
        xor     dx, dx
        mov     es, dx                   ; ES = 0000h (segment de l'IVT)
        mov     cx, [es:di+2]            ; CX = segment du gestionnaire (survit -
                                          ; jamais touche par i2c_lcd_*, voir leurs
                                          ; en-tetes/i2c_lcd_send_byte)
        mov     dx, [es:di]              ; DX = offset du gestionnaire (survit)

        cmp     bx, 0
        jne     .row_not0
        i2c_lcd_goto LCD_LINE1
        jmp     .row_go
.row_not0:
        cmp     bx, 1
        jne     .row_not1
        i2c_lcd_goto LCD_LINE2
        jmp     .row_go
.row_not1:
        cmp     bx, 2
        jne     .row_not2
        i2c_lcd_goto LCD_LINE3
        jmp     .row_go
.row_not2:
        i2c_lcd_goto LCD_LINE4
.row_go:
        call    i2c_lcd_tx_hex_byte      ; AL = vecteur (AX intact - voir plus haut)
        mov     al, 'h'
        call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data
        mov     al, ' '
        call    i2c_lcd_data
        mov     ax, cx                   ; AX = segment du gestionnaire
        call    i2c_lcd_tx_hex_word
        mov     al, ':'
        call    i2c_lcd_data
        mov     ax, dx                   ; AX = offset du gestionnaire
        call    i2c_lcd_tx_hex_word

        inc     bx
        cmp     bx, 4
        jb      .row_loop

.wait_key:
        call    ps2_get_char

        cmp     al, 27                   ; Echap: retour au menu
        je      .done

        cmp     al, PS2_KEY_UP
        jne     .not_up
        mov     bp, IVT_WINDOW_OFF
        mov     ax, [bp]
        cmp     ax, 0
        je      .wait_key                ; deja au sommet - ignore
        dec     ax
        mov     [bp], ax
        jmp     .redraw
.not_up:
        cmp     al, PS2_KEY_DOWN
        jne     .wait_key                ; touche non pertinente - ignoree
        mov     bp, IVT_WINDOW_OFF
        mov     ax, [bp]
        cmp     ax, IVT_WINDOW_MAX       ; derniere fenetre valide
        jae     .wait_key                ; deja au fond - ignore
        inc     ax
        mov     [bp], ax
        jmp     .redraw

.done:
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; usb_state_print
; Affiche l'option 1 du sous-menu USB Disk avec l'etat COURANT de
; BIOS_USB_STATE (hardware.inc): "1) USB: OFF" ou "1) USB: ON", sur
; l'UART (+ CRLF) et sur le LCD I2C (ligne 0, colonne 0 -
; i2c_lcd_init l'a deja effacee: pas besoin de completer la ligne).
; DS = CS tout du long (jamais touche); preserve tout.
; ============================================================
usb_state_print:
        push    ax
        push    si
        push    es
        mov     ax, VAR_SEG
        mov     es, ax
        mov     si, usb_opt1_off
        cmp     byte [es:BIOS_USB_STATE], 0
        je      .p
        mov     si, usb_opt1_on
.p:
        print   si, UART
        print   txt_crlf, UART
        gotoxy  0, 0, LCDI2C
        print   si, LCDI2C
        pop     es
        pop     si
        pop     ax
        ret

; ============================================================
; clock_speed_action
; Option "1) Clock speed" du sous-menu Configuration: affiche la frequence
; COURANTE de l'horloge du 8088 (pont STM32, PWM materiel sur PA3 - voir
; arduino/8088_bridge_stm32) et permet de la regler, entre 1 et 10 MHz:
;   1) +0,1 MHz   2) -0,1 MHz   3) +1 MHz   4) -1 MHz
;   5) 4,77 MHz (vitesse du PC IBM d'origine, ET valeur PAR DEFAUT au
;      demarrage du pont)   6) 8 MHz
;   Echap - retour au sous-menu Configuration
; Chaque touche envoie IMMEDIATEMENT la nouvelle frequence au pont (pas de
; "valider" separe - comme le potentiometre d'origine, projets/Clock-8088):
; changer la frequence du CPU en direct est sans risque (contrairement a
; une ecriture en RAM), donc pas besoin d'un tampon/annulation comme Edit
; RAM. Sans reponse du pont (delai - ancien firmware qui ne connait pas
; encore cette commande, ou pont muet): message d'erreur, retour immediat
; au sous-menu.
; Les options (1-6 + Echap) sont affichees UNE SEULE FOIS a l'entree, sur
; l'UART ET le LCD (texte fixe - contrairement a la frequence courante, qui
; change et est redessinee par clock_show a chaque touche). Bug rapporte et
; corrige (voir Directives.md): auparavant, ce texte n'etait envoye QU'AU
; LCD, jamais a l'UART (seule la ligne "Frequence: ..." l'etait) - un
; utilisateur au clavier PS/2 via un terminal serie ne voyait donc aucune
; des touches disponibles, seulement le resultat.
; ============================================================
clock_speed_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        call    i2c_lcd_init

        print   txt_menu_clock_head, UART
        print   txt_menu_clock_opts, UART

        gotoxy  1, 0, LCDI2C
        print   lcd_txt_clock_opts_l1, LCDI2C
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_clock_opts_l2, LCDI2C
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_clock_opts_l3, LCDI2C

        xor     dl, dl                   ; action 0 = lire seulement
        call    fs_clock_cmd
        jc      .tmo
        call    clock_show
.wait:
        call    ps2_get_char
        cmp     al, 27
        je      .out
        cmp     al, '1'
        jl      .wait                    ; touche non pertinente: reboucle sans rien envoyer
        cmp     al, '6'
        jg      .wait
        mov     dl, al
        sub     dl, '0'                  ; '1'-'6' -> 1-6: numerotation IDENTIQUE au code
                                          ; d'action attendu par fs_clock_cmd/clockExec
                                          ; (voir arduino/8088_bridge_stm32/src/main.cpp)
        call    fs_clock_cmd
        jc      .tmo
        call    clock_show
        jmp     .wait
.tmo:
        mov     si, dm_e_tmo             ; lib/bios.asm (dos_menu): "The bridge does not answer."
        call    bios_puts
.out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; clock_hz_to_wholefrac: DX:AX = frequence en Hz -> BL = partie entiere
; (1-10), BH = partie decimale (0-99), en centiemes de MHz (DX:AX / 10000 -
; division 32 bits / 16 bits classique, le quotient tient sur 16 bits:
; aucune frequence de ce projet ne depasse 10 000 000 Hz), puis
; centihz_to_wholefrac (partagee avec cpu_test_show_result, qui calcule
; directement des centiemes de MHz sans partir d'un Hz). Detruit AX/CX/DX
; (PAS BP/SI/ES). Utilisee par clock_show et clock_main_speed_print.
clock_hz_to_wholefrac:
        mov     cx, 10000
        mov     bx, ax                   ; BX = poids faible du Hz d'origine
        mov     ax, dx                   ; AX = poids fort
        xor     dx, dx
        div     cx                       ; AX = poids fort / 10000 (0 en pratique), DX = reste
        xchg    ax, bx                   ; BX = quotient (inutilise), AX = poids faible d'origine
        div     cx                       ; AX = centiemes de MHz (0-1000), DX = reste (ignore)
        jmp     centihz_to_wholefrac     ; AX -> BL/BH (le RET de centihz_to_wholefrac
                                          ; sert aussi de retour a NOTRE appelant - CX/DX
                                          ; ci-dessus n'ont plus besoin d'etre preserves)

; centihz_to_wholefrac: AX = centiemes de MHz -> BL = partie entiere, BH =
; partie decimale (0-99) - simple division par 100. Detruit AX/CX/DX (PAS
; BP/SI/ES). Utilisee par clock_hz_to_wholefrac ci-dessus ET directement
; par cpu_test_show_result (plus bas), qui calcule ses propres centiemes
; de MHz (477 * CPU_TEST_REF_SECONDS / temps_ecoule) sans jamais passer
; par un Hz.
centihz_to_wholefrac:
        mov     cx, 100
        xor     dx, dx
        div     cx                       ; AX = partie entiere (1-10...), DX = partie decimale (0-99)
        mov     bh, dl                   ; BH = partie decimale
        mov     bl, al                   ; BL = partie entiere
        ret

; clock_print_digits: BL = partie entiere (1-10), BH = partie decimale
; (0-99), BP = cible (bit0 = UART, bit1 = LCD I2C - le curseur LCD doit deja
; etre positionne par l'appelant) -> affiche "N.NN" (TOUJOURS 5 caracteres:
; 2 pour la partie entiere - espace de tete si < 10 - puis '.', puis 2 pour
; la partie decimale - largeur CONSTANTE, jamais de caractere perime a la
; fin d'une valeur plus courte que la precedente, ex. de "10.00" a "4,77").
; Detruit AX/CX. Preserve BX/BP.
clock_print_digits:
        push    ax
        push    cx

        cmp     bl, 10
        je      .tens
        mov     al, ' '
        call    .out
        mov     al, bl
        add     al, '0'
        jmp     .units
.tens:
        mov     al, '1'
        call    .out
        mov     al, '0'
.units:
        call    .out

        mov     al, '.'
        call    .out

        mov     al, bh
        xor     ah, ah
        mov     cl, 10
        div     cl                       ; AL = dizaines, AH = unites (du pourcentage decimal)
        add     al, '0'
        push    ax
        call    .out
        pop     ax
        mov     al, ah
        add     al, '0'
        call    .out

        pop     cx
        pop     ax
        ret
.out:                                    ; AL = caractere -> UART et/ou LCD selon BP
        test    bp, 1
        jz      .out_lcd
        call    uart_tx_byte
.out_lcd:
        test    bp, 2
        jz      .out_done
        call    i2c_lcd_data
.out_done:
        ret

; clock_print_str: CS:SI = texte termine par 0, BP = cible (bit0 UART,
; bit1 LCD I2C - meme convention que clock_print_digits) -> affiche chaque
; caractere sur la/les cible(s) demandee(s) (le curseur LCD doit deja etre
; positionne par l'appelant). Detruit AX/SI.
clock_print_str:
.l:
        mov     al, [cs:si]
        or      al, al
        jz      .r
        test    bp, 1
        jz      .no_u
        call    uart_tx_byte
.no_u:
        test    bp, 2
        jz      .no_l
        call    i2c_lcd_data
.no_l:
        inc     si
        jmp     .l
.r:
        ret

; print_dec_n: AX = valeur (0 a 10^CL-1), CL = nombre de chiffres a afficher
; (largeur FIXE, zeros de tete si besoin), BP = cible (bit0 UART, bit1 LCD
; I2C - meme convention que clock_print_digits/clock_print_str - le curseur
; LCD doit deja etre positionne par l'appelant). Utilisee pour la date/
; l'heure (information_action, plus bas: 2 chiffres jour/mois/heures/
; minutes/secondes, 4 chiffres annee) et les versions BIOS/firmware STM (1
; chiffre). Preserve tout SAUF le resultat des calculs internes (AX/BX/CX/
; DX/SI/DI tous restaures via la pile - seul BP, jamais modifie, sert de
; parametre en lecture seule).
print_dec_n:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     si, ax                   ; SI = valeur restante a afficher
        mov     di, 1                    ; DI = diviseur courant = 10^(CL-1)
        mov     ch, cl
        dec     ch
        jz      .have_divisor
.pow10:
        mov     ax, di
        mov     bx, 10
        mul     bx
        mov     di, ax
        dec     ch
        jnz     .pow10
.have_divisor:
        mov     ch, cl                   ; CH = nombre de chiffres restant a afficher
.digit_loop:
        mov     ax, si
        xor     dx, dx
        mov     bx, di
        div     bx                       ; AX = chiffre courant (quotient), DX = reste
        mov     si, dx                   ; SI = reste - valeur pour le prochain chiffre
        add     al, '0'
        test    bp, 1
        jz      .no_u
        call    uart_tx_byte
.no_u:
        test    bp, 2
        jz      .no_l
        call    i2c_lcd_data
.no_l:
        mov     ax, di                   ; DI = DI/10 pour le prochain chiffre
        xor     dx, dx
        mov     bx, 10
        div     bx
        mov     di, ax
        dec     ch
        jnz     .digit_loop

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; clock_show: affiche DX:AX (frequence en Hz) sous la forme "Current speed:
; N.NN MHz" sur l'UART, et "N.NN MHz" (sans le prefixe "Current speed: " -
; pas la place sur 20 colonnes) a la ligne 0 du LCD I2C (toujours la meme
; position, quel que soit l'endroit ou l'appelant a laisse le curseur - voir
; clock_speed_action). Met AUSSI a jour CLOCK_FREQ_HZ_OFF (VAR_SEG, voir
; hardware.inc): clock_main_speed_print l'utilise ensuite pour afficher la
; vitesse courante au menu principal SANS repasser par le pont a chaque
; redessin. Preserve tout.
clock_show:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    bp
        push    es

        mov     cx, VAR_SEG
        mov     es, cx
        mov     [es:CLOCK_FREQ_HZ_OFF], ax
        mov     [es:CLOCK_FREQ_HZ_OFF+2], dx

        i2c_lcd_goto_col LCD_LINE1, 0     ; toujours la meme ligne LCD (0 - le sous-menu
                                          ; n'a plus de titre statique separe, voir
                                          ; clock_speed_action), quel que soit l'endroit
                                          ; ou i2c_lcd_init/les lignes fixes ont laisse
                                          ; le curseur PHYSIQUE - "gotoxy" seul (AH=02h)
                                          ; ne positionne que le curseur LOGIQUE, en RAM:
                                          ; sans "print" a la suite (ici clock_print_digits/
                                          ; clock_print_str, des ecritures BRUTES), le
                                          ; curseur physique ne bougeait jamais reellement -
                                          ; bug trouve et corrige, voir Directives.md

        call    clock_hz_to_wholefrac    ; DX:AX -> BL/BH

        mov     si, txt_clock_freq_prefix        ; "Current speed: " - UART seul
        call    bios_puts                         ; (pas de place sur le LCD)

        mov     bp, 3                    ; UART + LCD I2C
        call    clock_print_digits

        mov     si, txt_clock_freq_suffix        ; " MHz" - UART ET LCD cette fois
        call    clock_print_str

        mov     si, txt_crlf
        call    bios_puts

        pop     es
        pop     bp
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; clock_main_speed_print
; Affiche, a droite de la ligne "1) Basic" du menu principal, la frequence
; COURANTE de l'horloge du 8088 - LUE DANS LE CACHE CLOCK_FREQ_HZ_OFF
; (VAR_SEG), sans aller-retour au pont a chaque redessin du menu principal
; (frequent: apres chaque action, comme tous les sous-menus). Le cache est
; mis a jour par clock_show a chaque visite du sous-menu Configuration/Clock
; speed; une valeur par defaut plausible (4,77 MHz - la valeur reelle PAR
; DEFAUT du pont a SON PROPRE demarrage) y est ecrite au demarrage du 8088
; (voir start:), pour un affichage correct meme avant toute visite du
; sous-menu.
; Appelee 2 FOIS par .main_menu (solution-01.asm), car "1) Basic" (UART) et
; la ligne 0 du LCD (lcd_txt_menu_main_l1) ne sont PAS dessines au meme
; moment:
;   BP=1 (UART seul), juste apres le texte "1) Basic" (avant le CRLF -
;        continue la meme ligne): "   N.NN MHz"
;   BP=2 (LCD I2C seul), APRES le dessin complet de la ligne 0 du LCD -
;        sinon lcd_txt_menu_main_l1 (largeur fixe, 20 colonnes) ecraserait
;        ces chiffres: gotoxy 0,15 ici, puis juste "N.NN" (5 caracteres,
;        colonnes 15-19 - pas de place pour "MHz" sur le LCD).
; Preserve AX/BX/CX/DX/SI/ES (BP est le parametre d'entree, ecrase).
; ============================================================
clock_main_speed_print:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    es

        test    bp, 1
        jz      .no_uart_sep
        mov     al, ' '
        call    uart_tx_byte
        call    uart_tx_byte
        call    uart_tx_byte
.no_uart_sep:
        test    bp, 2
        jz      .no_lcd_pos
        i2c_lcd_goto_col LCD_LINE1, 15    ; positionnement PHYSIQUE requis - voir
                                           ; clock_show ci-dessus (aucun "print" ne
                                           ; suit, clock_print_digits ecrit en brut)
.no_lcd_pos:

        mov     cx, VAR_SEG
        mov     es, cx
        mov     ax, [es:CLOCK_FREQ_HZ_OFF]
        mov     dx, [es:CLOCK_FREQ_HZ_OFF+2]
        call    clock_hz_to_wholefrac    ; DX:AX -> BL/BH (PAS BP/SI/ES)
        call    clock_print_digits

        test    bp, 1
        jz      .no_uart_suffix
        mov     si, txt_clock_freq_suffix        ; " MHz"
        call    bios_puts
        mov     si, txt_crlf
        call    bios_puts
.no_uart_suffix:

        pop     es
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; cpu_speed_test_action
; Option "2) Test CPU speed" du sous-menu Configuration: lance un banc
; d'essai a CHARGE FIXE (CPU_TEST_CHECKPOINTS x CPU_TEST_INNER_REPS x
; 65536 iterations d'une boucle "dec bx / loop" - voir les constantes
; ci-dessous), calibre pour durer AU MOINS 30 secondes a 4,77 MHz.
; La duree REELLE est mesuree via la RTC du pont (rtc_get, lib/bridge.asm)
; - INDEPENDANTE de l'horloge du 8088 (contrairement a un comptage de
; cycles logiciel, qui serait circulaire ici puisque c'est PRECISEMENT
; la vitesse du CPU que ce test cherche a mesurer) - et comparee a
; CPU_TEST_REF_SECONDS pour estimer la vitesse REELLE en pourcentage et
; en MHz, quelle que soit la frequence actuellement reglee (sous-menu
; Clock speed): le test peut se lancer a n'importe quelle vitesse, pas
; seulement 4,77 MHz.
; Pendant le test: la ligne "Ecoule: NNN s" se redessine a chaque
; "checkpoint" (CPU_TEST_CHECKPOINTS au total, environ 1 par seconde si
; la calibration est bonne) - permet de constater que le test avance.
; Echap (verification NON BLOQUANTE a chaque checkpoint via
; ps2_poll_char, meme technique que dump_memory_action) interrompt
; le test et retourne immediatement au sous-menu Configuration.
; A la fin (cpu_test_show_result): affiche le temps ecoule, le
; pourcentage par rapport a une execution a 4,77 MHz (ex: "20% plus
; vite"), et la vitesse ESTIMEE en MHz - PAS forcement egale au reglage
; actuel du sous-menu Clock speed: un ecart important pourrait reveler
; un probleme materiel (etats d'attente inattendus, horloge instable).
; Attend ensuite une touche (n'importe laquelle) avant de retourner au
; sous-menu Configuration, le temps de lire le resultat.
; ============================================================
CPU_TEST_CHECKPOINTS equ 30                    ; nombre de mises a jour de la ligne
                                                ; "Ecoule: ..." (granularite d'affichage,
                                                ; PAS forcement 1/seconde - depend de la
                                                ; calibration ci-dessous)
CPU_TEST_INNER_REPS  equ 4                     ; boucles CX=0 (65536 iterations "dec bx /
                                                ; loop") par checkpoint - reduit de 8 a 4
                                                ; (confirme sur le materiel reel: 8 donnait
                                                ; ~69 s a 4,77 MHz, plus que necessaire -
                                                ; demande explicite: se rapprocher du minimum
                                                ; de 30 s tout en le respectant AU MOINS -
                                                ; 4/8 de 69 s = ~34,5 s, projection LINEAIRE
                                                ; puisque chaque repetition represente un
                                                ; travail identique). A r'ajuster de nouveau
                                                ; si la table de cycles 8088 (dec/loop) ou la
                                                ; vitesse de l'UART/LCD change un jour, voir
                                                ; Directives.md
CPU_TEST_REF_SECONDS equ 34                    ; duree MESUREE (calibree sur le materiel
                                                ; reel, 8088 regle a 4,77 MHz - le reglage
                                                ; par defaut) a CPU_TEST_INNER_REPS=4: la
                                                ; projection lineaire initiale (34,5s, arrondie
                                                ; a 35) etait quasi exacte - retrouvee par
                                                ; calcul inverse a partir d'un resultat reel
                                                ; ("2% plus vite", "4,91 MHz") obtenu avec 35:
                                                ; (35-T)*100/T=2 ET 477*35/T=491 ne sont
                                                ; simultanement satisfaites, en entiers, que
                                                ; par T=34. A RECALIBRER de nouveau si la table
                                                ; de cycles 8088 (dec/loop) ou la vitesse de
                                                ; l'UART/LCD change un jour, voir Directives.md

cpu_speed_test_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        mov     ax, VAR_SEG
        mov     es, ax                   ; ES = VAR_SEG pour toute la duree du test
                                          ; (BIOS_RTC_OFF, CPU_TEST_START_SEC_OFF -
                                          ; gotoxy/print sauvegardent/restaurent leur
                                          ; propre ES en interne, sans danger)

        call    i2c_lcd_init
        print   txt_cpu_test_head, UART
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_cpu_test_elapsed, LCDI2C     ; "Ecoule: 000 s" - les chiffres
                                                      ; (colonne 8) seront redessines par
                                                      ; cpu_test_show_progress/show_result
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_cpu_test_title, LCDI2C       ; "Test CPU speed"
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_cpu_test_cancel, LCDI2C      ; "Echap: annuler"

        mov     di, BIOS_RTC_OFF
        call    rtc_get
        jc      .tmo
        call    cpu_test_rtc_to_seconds       ; BIOS_RTC_OFF (h/m/s) -> DX:AX (secondes
                                                ; depuis minuit)
        mov     [es:CPU_TEST_START_SEC_OFF], ax
        mov     [es:CPU_TEST_START_SEC_OFF+2], dx

        mov     si, CPU_TEST_CHECKPOINTS
.checkpoint:
        mov     di, CPU_TEST_INNER_REPS
.inner_reps:
        mov     cx, 0                    ; CX=0 -> LOOP fait 65536 passages (le
                                          ; "travail" du banc d'essai - seul le NOMBRE
                                          ; d'iterations compte, pas la valeur de BX)
.busy:
        dec     bx
        loop    .busy
        dec     di
        jnz     .inner_reps

        ; --- 1 checkpoint termine: verifie Echap (non bloquant, meme
        ; technique que dump_memory_action - voir son en-tete) et
        ; redessine la progression ---
        call    ps2_poll_char            ; jamais bloquant (un relachement seul, p. ex.
        jc      .no_key                  ; celui de '2', ne doit PAS attendre une touche)
        cmp     al, 27
        je      .aborted
.no_key:
        push    si                        ; SI = compteur de checkpoints (le NOTRE) -
        call    cpu_test_show_progress    ; cpu_test_show_progress detruit SI (pointeurs
        pop     si                        ; de texte internes) - a preserver ici sans quoi
                                           ; "dec si / jnz .checkpoint" ci-dessous n'a plus
                                           ; aucun rapport avec le nombre de checkpoints
                                           ; restants (bug trouve via un banc Unicorn: le
                                           ; test ne s'arretait jamais - voir Directives.md).
                                           ; "pop" ne modifie pas les indicateurs: CF (mis
                                           ; par cpu_test_show_progress) survit intact.
        jc      .tmo                      ; le pont a cesse de repondre EN COURS DE TEST -
                                           ; abandon immediat (meme sortie qu'un timeout a
                                           ; l'entree) plutot que de continuer les
                                           ; checkpoints restants sans aucun retour visible

        dec     si
        jnz     .checkpoint

        ; --- test termine: calcule et affiche le resultat final ---
        call    cpu_test_show_result
        jmp     .wait_key
.aborted:
        mov     si, txt_cpu_test_aborted
        call    bios_puts
        jmp     .out
.tmo:
        mov     si, txt_crlf              ; termine la ligne de points de progression en
        call    bios_puts                 ; cours (cpu_test_show_progress, UART) s'il y en
                                           ; avait une - inoffensif sinon (juste une ligne
                                           ; vide de plus)
        mov     si, dm_e_tmo             ; lib/bios.asm (dos_menu): "The bridge does not answer."
        call    bios_puts
        jmp     .out
.wait_key:
        call    ps2_get_char             ; laisse le temps de lire le resultat -
                                          ; n'importe quelle touche continue
.out:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; cpu_test_rtc_to_seconds: ES:BIOS_RTC_OFF (rempli par rtc_get: annee,
; mois, jour, heures, minutes, secondes, centiemes) -> DX:AX = secondes
; ecoulees depuis minuit (32 bits: h*3600 + m*60 + s, jusqu'a 86399 - MUL
; 16x16->32 necessaire pour h*3600 seul, qui depasse 65535 des que
; h >= 19). Detruit AX/BX/CX/DX.
cpu_test_rtc_to_seconds:
        mov     al, [es:BIOS_RTC_OFF+4]  ; heures (0-23)
        xor     ah, ah
        mov     cx, 3600
        mul     cx                        ; DX:AX = h*3600 (32 bits)
        push    ax
        push    dx

        mov     al, [es:BIOS_RTC_OFF+5]  ; minutes (0-59)
        xor     ah, ah
        mov     cx, 60
        mul     cx                        ; AX = m*60 (0-3540, tient sur 16 bits)
        mov     bl, [es:BIOS_RTC_OFF+6]  ; + secondes (0-59)
        xor     bh, bh
        add     ax, bx                    ; AX = m*60+s (0-3599)

        pop     dx                        ; DX = poids fort de h*3600
        pop     bx                        ; BX = poids faible de h*3600
        add     ax, bx
        adc     dx, 0                     ; DX:AX = total (h*3600 + m*60 + s)
        ret

; cpu_test_elapsed_seconds: DX:AX = "maintenant" (secondes depuis minuit,
; deja calcule par cpu_test_rtc_to_seconds), ES:CPU_TEST_START_SEC_OFF =
; depart (meme convention) -> DX:AX = secondes ECOULEES (32 bits). Corrige
; un passage de minuit (depart proche de 86399, "maintenant" ayant boucle
; a une petite valeur - improbable pour un test de quelques dizaines de
; secondes, mais gere quand meme): si la soustraction produit une
; retenue (CF=1), ajoute 86400 (1 jour, en secondes - 15180h). Detruit
; BX/CX.
cpu_test_elapsed_seconds:
        push    bx
        push    cx
        mov     bx, ax                    ; sauve "maintenant" poids faible
        mov     cx, dx                    ; sauve "maintenant" poids fort
        sub     bx, [es:CPU_TEST_START_SEC_OFF]
        sbb     cx, [es:CPU_TEST_START_SEC_OFF+2]
        jnc     .ok                       ; pas de retenue: pas de passage de minuit
        add     bx, 5180h                 ; 86400 (86 400 s/jour = 15180h), poids faible
        adc     cx, 1                     ;                                 poids fort
.ok:
        mov     ax, bx
        mov     dx, cx
        pop     cx
        pop     bx
        ret

; cpu_test_show_progress: ES = VAR_SEG (deja etabli par l'appelant),
; CPU_TEST_START_SEC_OFF deja rempli -> interroge la RTC du pont, calcule
; le temps ecoule, et affiche un SEUL "." sur l'UART (pas de CRLF - tous
; les points d'un meme test s'accumulent sur la MEME ligne, simple
; indicateur de progression compact - demande, voir Manifest.md; le
; nombre de secondes exact n'est plus repete a chaque checkpoint sur
; l'UART, seulement dans le resultat final, cpu_test_show_result), PUIS
; redessine les 3 chiffres (colonne 8, ligne 0 du LCD - INCHANGE, toujours
; numerique - meme convention que clock_show: largeur CONSTANTE,
; zero-remplie via i2c_lcd_tx_dec3, jamais de caractere perime). CF = 1
; si le pont ne repond pas (comme rtc_get): a la charge de l'APPELANT
; d'abandonner le banc d'essai dans ce cas (voir cpu_speed_test_action,
; ".tmo") - NE PAS ignorer silencieusement un timeout ici et laisser le
; test continuer: sans retour visible pendant potentiellement les ~30
; checkpoints restants, un pont devenu muet en cours de route serait
; indiscernable d'un test simplement bloque (rapporte sur le materiel
; reel - voir Directives.md). Detruit AX/BX/CX/DX/SI/DI.
cpu_test_show_progress:
        mov     di, BIOS_RTC_OFF
        call    rtc_get
        jc      .skip                     ; CF deja a 1 - propage tel quel a l'appelant
        call    cpu_test_rtc_to_seconds
        call    cpu_test_elapsed_seconds   ; DX:AX = T (secondes ecoulees)
        mov     bx, ax                     ; BX = T (poids faible) - sauve AVANT de detruire
                                            ; AL pour le "." ci-dessous (uart_tx_byte
                                            ; preserve tout, mais "mov al,'.'" ecraserait T)

        mov     al, '.'
        call    uart_tx_byte

        i2c_lcd_goto_col LCD_LINE1, 8    ; positionnement PHYSIQUE requis (i2c_lcd_tx_dec3
                                          ; ecrit en brut, "gotoxy" seul ne suffit pas -
                                          ; voir clock_show)
        mov     ax, bx                    ; AX = T (restaure pour le LCD)
        call    i2c_lcd_tx_dec3
        clc                               ; succes: CF=0 pour l'appelant
.skip:
        ret

; cpu_test_show_result
; Calcule et affiche (UART + LCD) le resultat FINAL du banc d'essai: temps
; ecoule REEL, pourcentage par rapport a une execution du MEME banc a
; 4,77 MHz EXACTEMENT (CPU_TEST_REF_SECONDS - duree ESTIMEE, voir sa
; definition pour la procedure de recalibration), et vitesse ESTIMEE en
; MHz (4,77 * CPU_TEST_REF_SECONDS / temps_ecoule). Suppose ES = VAR_SEG
; et CPU_TEST_START_SEC_OFF deja remplis (voir cpu_speed_test_action).
; N'attend PAS de touche (voir cpu_speed_test_action, apres l'appel).
; Detruit AX/BX/CX/DX/SI/BP.
cpu_test_show_result:
        mov     di, BIOS_RTC_OFF
        call    rtc_get
        jc      .tmo
        call    cpu_test_rtc_to_seconds     ; DX:AX = "maintenant"
        call    cpu_test_elapsed_seconds    ; DX:AX = T (secondes ecoulees)
        mov     bp, ax                       ; BP = T (16 bits - largement suffisant: le
                                              ; test dure au plus quelques minutes)
        or      bp, bp
        jnz     .t_ok
        mov     bp, 1                        ; protection division par 0 (cas jamais
                                              ; atteint en pratique)
.t_ok:
        ; --- termine la ligne de points de progression (cpu_test_show_progress,
        ; UART) AVANT le resultat - sans quoi "Ecoule: ..." suivrait les points
        ; sur la MEME ligne ---
        mov     si, txt_crlf
        call    bios_puts

        ; --- ligne "Ecoule: NNN s" (valeur FINALE - peut differer
        ; legerement du dernier checkpoint affiche) ---
        mov     si, txt_cpu_test_elapsed
        call    bios_puts
        mov     ax, bp
        call    uart_tx_dec_word
        mov     si, txt_cpu_test_seconds
        call    bios_puts
        mov     si, txt_crlf
        call    bios_puts
        i2c_lcd_goto_col LCD_LINE1, 8    ; positionnement PHYSIQUE requis - voir
                                          ; cpu_test_show_progress
        mov     ax, bp
        call    i2c_lcd_tx_dec3

        ; --- pourcentage: AX = |R-T|, BX = 1 si plus RAPIDE (T<=R), 0 si
        ; plus LENT (T>R) - BP reste T tout du long, jamais touche ---
        mov     ax, CPU_TEST_REF_SECONDS
        mov     cx, bp
        sub     ax, cx                       ; AX = R-T (signe: >=0 si T<=R)
        jns     .is_faster
        neg     ax                            ; T>R: AX = |R-T| = T-R
        mov     bx, 0
        jmp     .diff_ok
.is_faster:
        mov     bx, 1
.diff_ok:
        mov     cx, 100
        mul     cx                            ; DX:AX = |R-T|*100 (R,T petits: tient
                                                ; largement sur 32 bits)
        mov     cx, bp                        ; CX = T (diviseur)
        div     cx                            ; AX = pourcentage entier (DX = reste, ignore)

        push    ax                            ; le pourcentage sert 2 fois (UART, LCD)
        mov     si, txt_cpu_test_result_prefix   ; "Le 8088 roule "
        call    bios_puts
        pop     ax
        push    ax
        call    uart_tx_dec_word
        or      bx, bx
        jz      .slower_uart
        mov     si, txt_cpu_test_faster          ; "% plus vite qu'un 8088 a 4,77 MHz." + CRLF
        jmp     .uart_msg
.slower_uart:
        mov     si, txt_cpu_test_slower           ; "% plus lent qu'un 8088 a 4,77 MHz." + CRLF
.uart_msg:
        call    bios_puts

        gotoxy  1, 0, LCDI2C
        print   lcd_txt_cpu_test_vs, LCDI2C       ; "vs 4.77MHz: " (complete a 20 caracteres
                                                    ; par lcd_text - repositionnement PHYSIQUE
                                                    ; explicite juste apres: le curseur serait
                                                    ; sinon a la colonne 20 pour le signe qui
                                                    ; suit, et "gotoxy" seul ne suffirait pas -
                                                    ; voir clock_show)
        i2c_lcd_goto_col LCD_LINE2, 12
        mov     al, '+'
        or      bx, bx
        jnz     .lcd_sign_ok
        mov     al, '-'
.lcd_sign_ok:
        call    i2c_lcd_data
        pop     ax                                 ; AX = pourcentage (dernier usage)
        call    i2c_lcd_tx_dec3
        mov     al, '%'
        call    i2c_lcd_data

        ; --- vitesse estimee: centiemes de MHz = 477 * CPU_TEST_REF_SECONDS / T ---
        mov     ax, 477
        mov     cx, CPU_TEST_REF_SECONDS
        mul     cx                            ; DX:AX = 477*R (largement dans les 32 bits)
        mov     cx, bp                        ; CX = T (dernier usage de BP comme "T")
        div     cx                            ; AX = centiemes de MHz
        call    centihz_to_wholefrac          ; AX -> BL/BH (partie entiere/decimale)

        mov     si, txt_cpu_test_estimated       ; "Vitesse estimee: " - UART seul (pas
        call    bios_puts                         ; la place sur le LCD, voir ci-dessous)
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_cpu_test_est, LCDI2C      ; "Est: "
        i2c_lcd_goto_col LCD_LINE3, 5             ; positionnement PHYSIQUE requis (idem
                                                    ; ci-dessus - clock_print_digits ecrit
                                                    ; en brut)
        mov     bp, 3                              ; cible UART + LCD (BP n'est plus "T" a
                                                     ; partir d'ici - dernier calcul deja fait)
        call    clock_print_digits
        mov     si, txt_clock_freq_suffix          ; " MHz" - UART ET LCD
        call    clock_print_str
        mov     si, txt_crlf
        call    bios_puts

        gotoxy  3, 0, LCDI2C
        print   lcd_txt_cpu_test_done, LCDI2C      ; "Echap: retour"
        ret
.tmo:
        mov     si, txt_crlf              ; termine la ligne de points de progression
        call    bios_puts                 ; (cpu_test_show_progress, UART) avant le message
        mov     si, dm_e_tmo
        call    bios_puts
        ret

; --- constantes pour clock_datetime_action/information_action, plus bas ---
BIOS_VERSION_MAJOR equ 1                ; version du BIOS/ROM affichee par
BIOS_VERSION_MINOR equ 2                ; "4) Information" - correspond a
                                         ; "Version 1.2" du splash (lcd_txt_splash_l2,
                                         ; plus bas) - A MAINTENIR MANUELLEMENT en
                                         ; phase avec lui si l'un des 2 change
DISK_TOTAL_KB       equ 8192            ; capacite NOMINALE de la flash SPI du pont
                                         ; (W25Q64, 8 Mo - arduino/8088_bridge_stm32/
                                         ; README.md) - PAS interrogee dynamiquement
                                         ; (aucune commande de protocole pour la
                                         ; capacite TOTALE, seulement l'espace LIBRE -
                                         ; fs_free, lib/bridge.asm) - a ajuster si la
                                         ; puce flash change un jour
INFO_RTC_THROTTLE   equ 3000            ; information_action, .loop plus bas: nombre de
                                         ; passes "verifie juste une touche" entre deux
                                         ; rtc_get - PAS interroge le pont a chaque tour
                                         ; (bug materiel reel signale par l'utilisateur
                                         ; dans Manifest.md: Echap ignore sur cet ecran,
                                         ; heure LCD figee sauf a la frappe d'une touche).
                                         ; Cause: BRIDGE_EXPECT_OFF (lib/isr.asm) reste a
                                         ; 1 pendant tout l'aller-retour rtc_get (~10 ms,
                                         ; deja documente comme un risque pour une touche
                                         ; tapee PENDANT ce court intervalle - README.md,
                                         ; PC1); une boucle qui rappelle rtc_get EN
                                         ; CONTINU (sans repit) maintient ce drapeau actif
                                         ; une fraction du temps proche de 100%, au lieu
                                         ; d'un cas rare - d'ou Echap presque toujours
                                         ; avale. Valeur choisie prudemment (large marge
                                         ; de securite meme a 1 MHz, la borne basse du
                                         ; sous-menu Clock speed) pour laisser de longs
                                         ; intervalles surs entre deux commandes, tout en
                                         ; restant bien sous 1 seconde - donc toujours
                                         ; "rafraichie a toutes les secondes" (demande
                                         ; d'origine). A AJUSTER si le materiel reel montre
                                         ; que ce n'est pas encore suffisant (ou trop lent).

; ============================================================
; clock_datetime_action
; Option "3) Heure et date" du sous-menu Configuration: regle la date et
; l'heure de la RTC du pont (rtc_set, lib/bridge.asm) - saisie decimale
; (ps2_read_dec_editable, lib/ps2.asm - PAS ps2_read_hex_editable: une
; date/heure se saisit en decimal, pas en hexadecimal), format
; jour-mois-annee (assorti a l'affichage de "4) Information", plus bas):
; "Date: JJ-MM-AAAA" puis "Heure: HH:MM:SS". Envoyee TELLE QUELLE au pont,
; qui valide lui-meme les bornes (applyTime(),
; arduino/8088_bridge_stm32/src/main.cpp) et ignore silencieusement une
; valeur hors bornes - pas de validation cote 8088 (coherent avec le
; reste du projet: saisie simple, sans confirmation, comme Edit RAM).
; rtc_set n'attend AUCUNE reponse du pont (fire-and-forget) - rien a
; verifier apres l'envoi.
; ============================================================
clock_datetime_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    i2c_lcd_init

        mov     si, txt_datetime_date_prefix    ; "Date: "
        call    bios_puts
        mov     si, txt_datetime_date_prefix
        i2c_lcd_show LCD_LINE1

        mov     cl, 2
        mov     ah, (LCD_LINE1 & 07Fh) + 6      ; 6 = long. de "Date: "
        call    ps2_read_dec_editable            ; BX = jour
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_RTC_OFF + 3             ; jour (meme ordre que rtc_get/rtc_set:
        mov     [es:di], bl                       ; annee(2)/mois/jour/h/min/s/cs)

        mov     al, '-'
        call    uart_tx_byte
        call    i2c_lcd_data

        mov     cl, 2
        mov     ah, (LCD_LINE1 & 07Fh) + 9       ; 9 = long. de "Date: JJ-"
        call    ps2_read_dec_editable            ; BX = mois
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_RTC_OFF + 2             ; mois
        mov     [es:di], bl

        mov     al, '-'
        call    uart_tx_byte
        call    i2c_lcd_data

        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 12      ; 12 = long. de "Date: JJ-MM-"
        call    ps2_read_dec_editable            ; BX = annee complete (0-9999)
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_RTC_OFF                 ; annee (mot, poids faible d'abord)
        mov     [es:di], bx

        mov     si, txt_crlf
        call    bios_puts

        mov     si, txt_datetime_time_prefix     ; "Heure: "/"Time: "
        call    bios_puts
        mov     si, txt_datetime_time_prefix
        i2c_lcd_show LCD_LINE2

        mov     cl, 2
        mov     ah, (LCD_LINE2 & 07Fh) + 7       ; 7 = long. de "Heure: "
        call    ps2_read_dec_editable            ; BX = heures
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_RTC_OFF + 4              ; heures
        mov     [es:di], bl

        mov     al, ':'
        call    uart_tx_byte
        call    i2c_lcd_data

        mov     cl, 2
        mov     ah, (LCD_LINE2 & 07Fh) + 10      ; 10 = long. de "Heure: HH:"
        call    ps2_read_dec_editable            ; BX = minutes
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_RTC_OFF + 5              ; minutes
        mov     [es:di], bl

        mov     al, ':'
        call    uart_tx_byte
        call    i2c_lcd_data

        mov     cl, 2
        mov     ah, (LCD_LINE2 & 07Fh) + 13      ; 13 = long. de "Heure: HH:MM:"
        call    ps2_read_dec_editable            ; BX = secondes
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_RTC_OFF + 6              ; secondes
        mov     [es:di], bl

        mov     si, txt_crlf
        call    bios_puts

        ; --- envoie au pont: DS:SI = BIOS_RTC_OFF (7 premiers octets, meme
        ; ordre que rtc_get - annee(2)/mois/jour/h/min/s), DS bascule
        ; TEMPORAIREMENT sur VAR_SEG (rtc_set l'exige - voir son en-tete,
        ; lib/bridge.asm) puis revient a CS aussitot apres (invariant du
        ; reste du projet: DS = CS partout ailleurs - voir start:) ---
        push    ds
        mov     ax, VAR_SEG
        mov     ds, ax
        mov     si, BIOS_RTC_OFF
        call    rtc_set
        pop     ds

        mov     si, txt_datetime_saved
        call    bios_puts

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; information_action
; Option "4) Information" du sous-menu Configuration: ecran recapitulatif
; - date/heure (RTC du pont, REDESSINEE des que la seconde change: la
; SEULE partie "en direct" de cet ecran, demande explicite), version du
; BIOS/ROM (BIOS_VERSION_MAJOR/MINOR ci-dessus), version du firmware du
; pont (fs_version_cmd, lib/bridge.asm - commande 03h), taille de la RAM
; (BIOS_MEM_KB, lib/bios.asm - meme valeur que INT 12h), espace utilise/
; disponible sur la flash du pont (fs_free + DISK_TOTAL_KB ci-dessus), et
; frequence d'horloge courante (CLOCK_FREQ_HZ_OFF, cache - PAS
; d'aller-retour au pont, meme technique que clock_main_speed_print).
; Ces 4 dernieres valeurs sont interrogees UNE SEULE FOIS a l'entree (pas
; besoin de les rafraichir chaque seconde comme la date/heure, demande
; explicite): en cas d'echec INDIVIDUEL (pont trop ancien qui ne connait
; pas encore 03h, ou muet pour fs_version_cmd/fs_free), la valeur
; concernee affiche "?" a la place plutot que d'abandonner tout l'ecran -
; seule la date/heure exige imperativement un pont fonctionnel des
; l'entree (echec => .tmo, meme convention que les autres actions de ce
; sous-menu). Un echec PASSAGER de la RTC PENDANT la boucle (pont
; temporairement muet) ne fait PAS non plus abandonner l'ecran (juste
; cette mise a jour) - contrairement a cpu_test_show_progress: ici, ce
; n'est qu'un affichage, pas une mesure a interrompre proprement.
; Echap (verification non bloquante, meme technique que
; cpu_speed_test_action/dump_memory_action) revient au sous-menu
; Configuration, sans message particulier.
;
; BUGS SIGNALES SUR LE MATERIEL REEL (Manifest.md, ajoutes par l'utilisateur
; directement dans le fichier) ET CORRIGES ICI:
; 1) Echap ignore sur cet ecran. Cause: BRIDGE_EXPECT_OFF (mis a 1 par
;    rtc_get pendant tout l'aller-retour au pont, ~10 ms - deja documente
;    comme un risque pour une touche tapee PENDANT ce court intervalle,
;    voir README.md/PC1) restait a 1 une fraction du temps proche de 100%,
;    puisque la .loop d'origine rappelait rtc_get EN CONTINU, sans le
;    moindre repit entre deux commandes - transformant un risque rare en
;    quasi-certitude. Corrige par INFO_RTC_THROTTLE (ci-dessus): le pont
;    n'est plus interroge qu'une fois toutes les INFO_RTC_THROTTLE passes
;    de la boucle (le clavier, lui, est verifie a CHAQUE passe).
; 2) Heure du LCD figee, actualisee seulement a la frappe d'une touche.
;    Meme cause probable: la boucle non throttlee inondait le pont/UART de
;    commandes GET_TIME en rafale (aucun repit reel entre deux, alors que
;    le lien materiel physique EXIGE un delai - README.md), ce qui pouvait
;    desynchroniser/faire echouer la plupart des reponses (traitees comme
;    "muet", CF=1, .rearm plus bas) - une frappe de touche, en intercalant
;    un peu de temps de traitement, laissait par hasard une commande
;    aboutir. Le meme throttle regle aussi ce symptome.
; 3) L'heure UART defilait (nouvelle ligne a chaque seconde) plutot que de
;    se redessiner EN PLACE. Corrige: un CR (13, PAS CRLF) repositionne le
;    curseur en debut de la MEME ligne juste avant de reecrire l'heure
;    (symetrique du i2c_lcd_goto_col qui fait deja ce travail pour le LCD).
; ============================================================
information_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        mov     ax, VAR_SEG
        mov     es, ax                    ; ES = VAR_SEG pour toute la duree de l'ecran

        call    i2c_lcd_init
        print   txt_info_head, UART

        mov     di, BIOS_RTC_OFF
        call    rtc_get
        jc      .tmo
        mov     dl, 0FFh                  ; force un 1er affichage immediat dans .loop
                                           ; (une seconde reelle, 0-59, ne peut jamais
                                           ; valoir FFh)

        ; --- BIOS/STM (ligne 1) ---
        print   lcd_txt_info_bios, UART             ; "BIOS:" (bug corrige avant tout test:
        gotoxy  1, 0, LCDI2C                        ; oublie sur l'UART au 1er jet - voir
        print   lcd_txt_info_bios, LCDI2C           ; Directives.md)
        mov     bp, 3                               ; UART + LCD pour toute cette section
        mov     ax, BIOS_VERSION_MAJOR
        mov     cl, 1
        call    print_dec_n
        mov     al, '.'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     ax, BIOS_VERSION_MINOR
        mov     cl, 1
        call    print_dec_n
        mov     al, ' '
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     si, txt_info_stm_prefix             ; "STM:"
        call    bios_puts
        mov     si, txt_info_stm_prefix
        call    i2c_lcd_print

        call    fs_version_cmd                      ; BH=majeure, BL=mineure, CF=1 si echec
        jc      .stm_unknown
        mov     al, bh
        xor     ah, ah
        mov     cl, 1
        call    print_dec_n
        mov     al, '.'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     al, bl
        xor     ah, ah
        mov     cl, 1
        call    print_dec_n
        jmp     .stm_done
.stm_unknown:
        mov     al, '?'
        call    uart_tx_byte
        call    i2c_lcd_data
.stm_done:
        mov     si, txt_crlf
        call    bios_puts

        ; --- RAM/CPU (ligne 2) ---
        print   lcd_txt_info_ram, UART              ; "RAM:"
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_info_ram, LCDI2C
        mov     bp, 3
        mov     ax, BIOS_MEM_KB
        mov     cl, 3
        call    print_dec_n
        mov     si, txt_info_kb                     ; "K "
        call    bios_puts
        mov     si, txt_info_kb
        call    i2c_lcd_print
        mov     si, txt_info_cpu_prefix              ; "CPU: "
        call    bios_puts
        mov     si, txt_info_cpu_prefix
        call    i2c_lcd_print
        mov     ax, [es:CLOCK_FREQ_HZ_OFF]
        mov     dx, [es:CLOCK_FREQ_HZ_OFF+2]
        call    clock_hz_to_wholefrac                ; DX:AX -> BL/BH
        mov     bp, 3
        call    clock_print_digits
        mov     si, txt_clock_freq_suffix            ; " MHz" - UART SEULEMENT (pas la
        mov     bp, 1                                 ; place sur le LCD - ligne deja pleine)
        call    clock_print_str
        mov     si, txt_crlf
        mov     bp, 1
        call    clock_print_str

        ; --- Disque (ligne 3) ---
        print   lcd_txt_info_disk, UART             ; "Disque:"/"Disk:" (bilingue)
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_info_disk, LCDI2C
        call    fs_free                              ; DX:AX = octets libres, CF=1 si echec
        jc      .disk_unknown
        mov     cx, 10                                ; DX:AX / 1024 = octets -> Ko (division
.shr32:                                               ; par une puissance de 2 - decalage 32
        shr     dx, 1                                 ; bits plutot qu'un DIV)
        rcr     ax, 1
        loop    .shr32
        mov     bx, ax                                ; BX = disponible (Ko)
        mov     ax, DISK_TOTAL_KB
        sub     ax, bx                                ; AX = utilise (Ko)
        mov     cl, 4
        mov     bp, 3
        call    print_dec_n
        mov     al, '/'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     ax, bx                                ; AX = disponible (Ko)
        mov     cl, 4
        call    print_dec_n
        mov     si, txt_info_kb2                      ; "KB"
        call    bios_puts
        mov     si, txt_info_kb2
        call    i2c_lcd_print
        jmp     .disk_done
.disk_unknown:
        mov     al, '?'
        call    uart_tx_byte
        call    i2c_lcd_data
.disk_done:
        mov     si, txt_crlf
        call    bios_puts
        print   txt_info_return, UART                 ; "(Echap: retour au sous-menu Configuration)"

        ; --- boucle: date/heure en direct (ligne 0), redessinee des que
        ; la seconde change - voir l'en-tete. Le pont n'est interroge
        ; qu'une fois toutes les INFO_RTC_THROTTLE passes (voir plus haut,
        ; bug Echap/LCD fige signale sur le materiel reel, Manifest.md).
        ; SI = compteur de passes avant le prochain rtc_get, initialise
        ; ICI (PAS plus haut: tout l'affichage statique BIOS/RAM/Disque
        ; au-dessus ecrase SI a chaque "mov si, <chaine>" - bug trouve par
        ; le test Unicorn AVANT tout essai materiel: la 1re mise a jour ne
        ; s'affichait jamais, SI valant l'adresse de txt_info_return au
        ; lieu de 0 en entrant dans .loop) - 0 => interroge tout de suite
        ; (1er tour). Libre pour cet usage: ps2_poll_char
        ; preservent SI, et rtc_get ne le touche pas (voir bridge.asm) ---
        xor     si, si
.loop:
        call    ps2_poll_char               ; jamais bloquant (voir lib/ps2.asm)
        jc      .no_key
        cmp     al, 27
        je      .out
.no_key:
        or      si, si
        jz      .poll                       ; compteur epuise: interroge le pont ce tour-ci
        dec     si                          ; sinon: juste le clavier, pas de rtc_get
        jmp     .loop                       ; (garde BRIDGE_EXPECT_OFF a 0 le plus possible)
.poll:
        mov     di, BIOS_RTC_OFF
        call    rtc_get
        jc      .rearm                      ; pont temporairement muet: retente bientot
                                             ; quand meme (voir l'en-tete)
        mov     al, [es:BIOS_RTC_OFF + 6]   ; secondes courantes
        cmp     al, dl
        je      .rearm                      ; pas de changement depuis le dernier affichage
        mov     dl, al                      ; memorise la nouvelle seconde affichee

        mov     al, 13                      ; CR (PAS CRLF): redessine LA MEME ligne UART
        call    uart_tx_byte                ; au lieu d'en faire defiler une nouvelle a
                                             ; chaque seconde (bug signale, Manifest.md)
        i2c_lcd_goto_col LCD_LINE1, 0
        mov     bp, 3
        mov     al, [es:BIOS_RTC_OFF + 3]   ; jour
        xor     ah, ah
        mov     cl, 2
        call    print_dec_n
        mov     al, '-'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     al, [es:BIOS_RTC_OFF + 2]   ; mois
        xor     ah, ah
        mov     cl, 2
        call    print_dec_n
        mov     al, '-'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     ax, [es:BIOS_RTC_OFF]       ; annee (mot complet)
        mov     cl, 4
        call    print_dec_n
        mov     al, ' '
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     al, [es:BIOS_RTC_OFF + 4]   ; heures
        xor     ah, ah
        mov     cl, 2
        call    print_dec_n
        mov     al, ':'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     al, [es:BIOS_RTC_OFF + 5]   ; minutes
        xor     ah, ah
        mov     cl, 2
        call    print_dec_n
        mov     al, ':'
        call    uart_tx_byte
        call    i2c_lcd_data
        mov     al, [es:BIOS_RTC_OFF + 6]   ; secondes
        xor     ah, ah
        mov     cl, 2
        call    print_dec_n
.rearm:
        mov     si, INFO_RTC_THROTTLE
        jmp     .loop
.out:
        mov     al, 13                      ; laisse le curseur UART sur une ligne propre
        call    uart_tx_byte                ; (la derniere heure affichee reste lisible,
        mov     si, txt_crlf                ; pas de CR/LF partiel au milieu de la ligne)
        call    bios_puts
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
.tmo:
        mov     si, dm_e_tmo
        call    bios_puts
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; usb_toggle_action
; Option "1) USB ON/OFF" du sous-menu USB Disk: bascule le disque
; (la flash du pont) entre le 8088 et le PC, selon l'etat memorise
; dans BIOS_USB_STATE (0 = OFF par defaut - hardware.inc). Envoie
; FS_USB_ON ou FS_USB_OFF (lib/bridge.asm) au pont, et affiche le
; resultat (UART seulement - le sous-menu reste a l'ecran sur le
; LCD). DS = CS tout du long (jamais touche - le seul texte a
; afficher ici vit en ROM); preserve tout.
; ============================================================
usb_toggle_action:
        push    ax
        push    es
        mov     ax, VAR_SEG
        mov     es, ax
        cmp     byte [es:BIOS_USB_STATE], 0
        jne     .to_off
        mov     si, usb_msg_activating
        call    bios_puts
        mov     al, FS_USB_ON
        call    fs_cmd0
        jc      .tmo
        or      al, al
        jnz     .err
        mov     byte [es:BIOS_USB_STATE], 1
        mov     si, usb_msg_on
        jmp     .msg
.to_off:
        mov     si, usb_msg_deactivating
        call    bios_puts
        mov     al, FS_USB_OFF
        call    fs_cmd0
        jc      .tmo
        or      al, al
        jnz     .err
        mov     byte [es:BIOS_USB_STATE], 0
        mov     si, usb_msg_off
        jmp     .msg
.tmo:
        mov     si, dm_e_tmo            ; lib/bios.asm (dos_menu): "The bridge does not answer."
        jmp     .msg
.err:
        cmp     al, FSE_NOSUPPORT
        jne     .generr
        mov     si, usb_msg_nosupport
        jmp     .msg
.generr:
        mov     si, usb_msg_err
.msg:
        call    bios_puts
        pop     es
        pop     ax
        ret

; ============================================================
; list_files_action
; Option "2) List files" du sous-menu USB Disk: liste les fichiers de
; la racine de la flash (nom, taille) puis l'espace libre, sur l'UART
; seulement (comme FILES au BASIC - meme motif que dos_menu: DS/ES =
; VAR_SEG le temps de lire le repertoire, DS = CS restaure avant de
; rendre la main). Reutilise fs_dir_first/fs_dir_next/fs_free
; (lib/bridge.asm) et put_udec32 (lib/basic_disk.asm - simple
; conversion DX:AX -> decimal, sans dependance au BASIC) directement,
; sans passer par BASIC (bas_puts/ERROR y ajoutent un etat - colonne
; d'affichage, gestionnaire d'erreur - qui n'existe pas ici).
; DM_ENTRY (defini par dos_menu ci-dessus, dans le tampon d'edition du
; moniteur) sert de tampon pour un nom + sa taille; un second tampon,
; DM_ENTRY+20h (32 octets plus loin, largement assez de marge avant
; la fin du tampon d'edition a EDIT_BUFFER_OFF+400h), pour convertir
; une taille en decimal.
; ============================================================
LF_DECBUF       equ     DM_ENTRY + 20h

list_files_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        mov     ax, VAR_SEG
        mov     ds, ax
        mov     es, ax
        cld
        mov     si, lf_title
        call    bios_puts
        call    fs_dir_first
        jc      .tmo
        or      al, al
        jnz     .nodisk
.next:
        mov     di, DM_ENTRY
        call    fs_dir_next             ; ES:DI = nom (zero final) puis taille (4 octets); AL = long. du nom (0 = fin)
        jc      .tmo
        or      al, al
        jz      .done
        mov     bl, al                  ; BX = longueur du nom
        xor     bh, bh
        mov     si, DM_ENTRY
        call    bios_puts_ds            ; nom (zero-termine par fs_dir_next: bios_puts_ds s'arrete au bon endroit)
        mov     cx, 13
        sub     cx, bx
        jbe     .np
.pd:
        mov     al, ' '
        call    uart_tx_byte
        loop    .pd
.np:
        mov     si, DM_ENTRY
        add     si, bx
        inc     si                      ; saute le zero final du nom -> taille (4 octets, poids faible d'abord)
        mov     ax, [si]
        mov     dx, [si + 2]
        mov     di, LF_DECBUF
        call    put_udec32
        mov     byte [di], 0
        mov     si, LF_DECBUF           ; DS = VAR_SEG ici: bios_puts_ds pour ce tampon (en RAM)
        call    bios_puts_ds
        mov     si, lf_crlf             ; texte en ROM: bios_puts (lit par CS, quel que soit DS)
        call    bios_puts
        jmp     .next
.done:
        call    fs_free                 ; DX:AX = octets libres
        jc      .tmo
        mov     di, LF_DECBUF
        call    put_udec32
        mov     byte [di], 0
        mov     si, LF_DECBUF
        call    bios_puts_ds
        mov     si, lf_free_suffix
        call    bios_puts
        jmp     .out
.nodisk:
        mov     si, dm_e_disk           ; lib/bios.asm (dos_menu): "Disk not ready."
        call    bios_puts
        jmp     .out
.tmo:
        mov     si, dm_e_tmo
        call    bios_puts
.out:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; dump_line
; Affiche UNE ligne de 16 octets:
;   UART: format complet (adresse/hexa/ascii) - INCHANGE
;   LCD I2C (4x20): dump complet des 16 octets en hexadecimal, 4 par
;     ligne sur les 4 lignes - ASCII (8 caracteres/groupe de 8 octets)
;     affiche seulement sur les lignes 1 et 3 (voir
;     i2c_dump_hex_ascii8_line) - anciennement reserve au LCD I2C
;     SECONDAIRE derriere TEST_I2C_DUMP (voir Directives.md), devenu
;     l'AFFICHAGE PRIMAIRE (et seul) depuis le passage complet du LCD
;     parallele au LCD I2C.
;
; Entree:  ES:DI = adresse de depart de la ligne (16 octets)
;          BX = numero de cette ligne (1-based, prepare par
;               dump_memory_action)
; Sortie:  DI avance de 16 (adresse de la ligne suivante). BX et ES
;          inchanges - IMPORTANT: CX (et AX, DX, SI) sont en revanche
;          DETRUITS (loops internes de cette procedure) - tout
;          appelant qui boucle sur plusieurs lignes doit garder son
;          propre compteur ailleurs que dans CX (voir
;          dump_memory_action, qui le stocke en RAM plutot que
;          d'utiliser une instruction "loop").
; ============================================================
dump_line:
        push    di
        i2c_lcd_goto LCD_LINE1
        call    i2c_dump_hex_ascii8_line       ; hexa bytes[0:4] + ascii bytes[0:8]
        i2c_lcd_goto LCD_LINE2
        call    i2c_dump_hex_only_line         ; hexa bytes[4:8] seulement
        i2c_lcd_goto LCD_LINE3
        call    i2c_dump_hex_ascii8_line       ; hexa bytes[8:12] + ascii bytes[8:16]
        i2c_lcd_goto LCD_LINE4
        call    i2c_dump_hex_only_line         ; hexa bytes[12:16] seulement
        pop     di

        ; --- UART: adresse reelle ES:DI ---
        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte

        ; --- 16 octets en hexadecimal ---
        push    di
        mov     cx, 16
.hex_loop:
        mov     al, [es:di]
        call    uart_tx_hex_byte
        mov     al, ' '
        call    uart_tx_byte
        inc     di
        loop    .hex_loop
        pop     di

        mov     al, ':'
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte

        ; --- 16 caracteres ASCII (ou '.' si non imprimable) ---
        mov     cx, 16
.ascii_loop:
        mov     al, [es:di]
        ascii_or_dot
        call    uart_tx_byte
        inc     di
        loop    .ascii_loop

        mov     si, txt_crlf
        call    uart_tx_string
        ret

; --- i2c_dump_hex4: affiche les 4 octets ES:DI en hexadecimal
; --- (separes par un espace) sur le LCD I2C, avance DI de 4 -
; --- factorise entre i2c_dump_hex_only_line et
; --- i2c_dump_hex_ascii8_line ci-dessous, qui partageaient ce code. ---
%macro i2c_dump_hex4 0
        mov     cx, 4
%%loop:
        mov     al, [es:di]
        call    i2c_lcd_tx_hex_byte
        cmp     cx, 1
        je      %%last
        mov     al, ' '
        call    i2c_lcd_data
%%last:
        inc     di
        loop    %%loop
%endmacro

; ============================================================
; i2c_dump_hex_only_line
; Affiche 4 octets en hexadecimal (separes par un espace), SANS
; ASCII - utilisee pour les lignes 2 et 4 (voir dump_line;
; i2c_dump_hex_ascii8_line, pour les lignes 1 et 3, affiche deja
; l'ASCII de ces 4 octets en plus des siens). "XX XX XX XX" = 11
; caracteres, dans les 20 colonnes disponibles.
; Entree:  ES:DI = 4 octets a afficher.
; Sortie:  DI avance de 4.
; ============================================================
i2c_dump_hex_only_line:
        push    ax
        push    cx
        i2c_dump_hex4
        pop     cx
        pop     ax
        ret

; ============================================================
; i2c_dump_hex_ascii8_line
; Affiche 4 octets en hexadecimal (separes par un espace), un espace,
; puis les 8 caracteres ASCII correspondant a CE groupe de 4 octets
; ET AU SUIVANT (ou '.' si non imprimable, meme regle que le dump
; UART - voir plus bas) - utilisee pour les lignes 1 et 3 (voir
; dump_line), le groupe suivant (lignes 2/4) n'affichant alors plus
; d'ASCII du tout (voir i2c_dump_hex_only_line). "XX XX XX XX ASCIIII"
; = 11+1+8 = 20 caracteres EXACTEMENT (pleine largeur).
; Entree:  ES:DI = 4 octets a afficher en hexa - le debut de ce
;          groupe ET du suivant (8 octets au total pour l'ASCII),
;          donc AVANT que le groupe suivant soit lu par
;          i2c_dump_hex_only_line.
; Sortie:  DI avance de 4 (seul le groupe hexa affiche par CET appel
;          est "consomme" du point de vue de DI - le suivant reste a
;          lire par le prochain appel, comme d'habitude).
; ============================================================
i2c_dump_hex_ascii8_line:
        push    ax
        push    cx
        push    si
        mov     si, di          ; SI = debut de CE groupe de 4 (pour les 8
                                 ; octets ASCII: ce groupe + le suivant) -
                                 ; DI, lui, doit finir avance de 4 seulement
                                 ; (contrat de sortie, utilise par dump_line)
        i2c_dump_hex4

        mov     al, ' '                 ; separateur entre hexa et ascii
        call    i2c_lcd_data

        mov     cx, 8
.ascii_loop:
        mov     al, [es:si]
        ascii_or_dot
        call    i2c_lcd_data
        inc     si
        loop    .ascii_loop

        pop     si
        pop     cx
        pop     ax
        ret

; ============================================================
; msg_banniere
; Annonce le debut du test avec le plan des blocs a tester.
; ============================================================
msg_banniere:
        print   txt_banniere1, UART
        print   txt_banniere2, UART
        ret

; ============================================================
; msg_bloc_progression
; Affiche le bloc de 1024 octets qui vient d'etre teste:
;   UART: "SEG:debut-SEG:fin <vert>OK<blanc>"  (ou <rouge>DEFAUT)
;   LCD (4x20):
;     ligne 2 = plage complete du bloc "SSSS:OOOO-SSSS:OOOO"
;     ligne 3 = etat en toutes lettres "Etat: OK" / "Etat: DEFAUT"
;     ligne 4 = compteurs cumulatifs "Bloc:NNN/127 Def:NNN"
; Entree: ES = segment courant, DI = offset JUSTE APRES le bloc
;         (multiple de 400h), BP = drapeau du bloc (0=ok, sinon defaut)
; Reinitialise BP a 0 avant de retourner.
; ============================================================
msg_bloc_progression:
        ; --- incremente les compteurs cumulatifs (bloc courant, et
        ; blocs defectueux si BP != 0) - vivent en RAM juste apres
        ; PORTA_SHADOW (voir en en-tete). ES:DI appartiennent a
        ; l'appelant (test_segment, en plein test) - sauvegardes et
        ; restaures ici, meme prudence que porta_write. ---
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BLOCK_COUNTER_OFF
        inc     byte [es:di]

        cmp     bp, 0
        je      .no_defect_incr
        mov     di, DEFECT_COUNTER_OFF
        inc     byte [es:di]
.no_defect_incr:
        pop     di
        pop     es

        mov     si, ANSI_BLANC
        call    uart_tx_string

        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        sub     ax, 0400h       ; ax = debut du bloc (di - 1024)
        call    uart_tx_hex_word

        mov     al, '-'
        call    uart_tx_byte

        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        dec     ax              ; ax = fin du bloc (di - 1)
        call    uart_tx_hex_word

        mov     al, ' '
        call    uart_tx_byte

        ; --- adresse physique de DEBUT du bloc en binaire (diagnostic
        ; materiel: rend visible A16, en cause dans le defaut trouve sur
        ; VE2CUY - voir Directives.md). DEUX registres a proteger ici,
        ; que test_segment/test_ram utilisent comme etat VIVANT (pas de
        ; variable memoire) tout au long du test:
        ;   - CX: compteur du "loop .byte_loop" de test_segment (l'appelant
        ;     de l'appelant) - mem_calc_physical le DETRUIT (son en-tete);
        ;     sans le push/pop, le test rebouclait indefiniment sur le
        ;     segment 0000h (CX ecrase a 0 -> "loop" repart pour 65536
        ;     octets a chaque bloc, au lieu de decompter normalement).
        ;   - BX (son octet haut BH): drapeau GLOBAL "RAM defectueuse" de
        ;     test_ram (mis a 1 par test_segment sur le premier defaut,
        ;     verifie a la toute fin) - uart_tx_bin_word (via uart_tx_bin20)
        ;     le DETRUIT (mov bx,ax puis 16x shl bx,1: BX = 0 a la sortie,
        ;     TOUJOURS, quelle que soit son entree); sans le push/pop, un
        ;     defaut trouve n'importe ou disparaissait du bilan final des
        ;     que le DERNIER bloc du test s'affichait: "*** RAM OK ***"
        ;     malgre des dizaines de "DEFAUT" au-dessus et un TOTAL DEFAUT
        ;     non nul (ce dernier vient de RAM_DEFECT_BYTES, en memoire,
        ;     jamais touche par ce bogue - lui restait juste). ---
        push    bx
        push    cx
        mov     ax, es
        mov     bx, di
        sub     bx, 0400h       ; bx = debut du bloc (di - 1024)
        call    mem_calc_physical       ; DX:AX = adresse physique du debut du bloc
        pop     cx
        call    uart_tx_bin20
        mov     al, ' '
        call    uart_tx_byte
        pop     bx

        mov     si, ANSI_BLANC
        call    uart_tx_string

        cmp     bp, 0
        je      .ok
        mov     si, ANSI_ROUGE
        call    uart_tx_string
        mov     si, txt_defaut_court
        call    uart_tx_string
        jmp     .fin
.ok:
        mov     si, ANSI_VERT
        call    uart_tx_string
        mov     si, txt_ok_court
        call    uart_tx_string
.fin:
        ; --- Ligne 2 du LCD: plage complete du bloc "SSSS:OOOO-SSSS:OOOO",
        ; miroir exact de ce qui part sur l'UART (19 caracteres - avant,
        ; sur 16 colonnes, seule l'adresse de DEBUT tenait) ---
        i2c_lcd_goto LCD_LINE2

        mov     ax, es
        call    i2c_lcd_tx_hex_word
        mov     al, ':'
        call    i2c_lcd_data
        mov     ax, di
        sub     ax, 0400h       ; ax = debut du bloc (di - 1024)
        call    i2c_lcd_tx_hex_word

        mov     al, '-'
        call    i2c_lcd_data

        mov     ax, es
        call    i2c_lcd_tx_hex_word
        mov     al, ':'
        call    i2c_lcd_data
        mov     ax, di
        dec     ax              ; ax = fin du bloc (di - 1)
        call    i2c_lcd_tx_hex_word

        ; --- Ligne 3 du LCD: etat en toutes lettres ---
        cmp     bp, 0
        je      .lcd_ok
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_etat_defaut, LCDI2C
        jmp     .lcd_etat_fin
.lcd_ok:
        gotoxy  2, 0, LCDI2C
        print   lcd_txt_etat_ok, LCDI2C
.lcd_etat_fin:

        ; --- Ligne 4 du LCD: compteurs cumulatifs "Bloc:NNN/127 Def:NNN"
        ; (20 caracteres exactement) - relit les deux compteurs
        ; incrementes au debut de cette routine ---
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BLOCK_COUNTER_OFF
        mov     dl, [es:di]     ; DL = numero de bloc courant
        mov     di, DEFECT_COUNTER_OFF
        mov     dh, [es:di]     ; DH = nombre de blocs defectueux
        pop     di
        pop     es

        i2c_lcd_goto LCD_LINE4
        mov     si, lcd_txt_bloc_prefix
        call    i2c_lcd_print
        mov     al, dl
        xor     ah, ah
        call    i2c_lcd_tx_dec3
        mov     si, lcd_txt_bloc_mid
        call    i2c_lcd_print
        mov     al, dh
        xor     ah, ah
        call    i2c_lcd_tx_dec3

        mov     bp, 0           ; reinitialise le drapeau pour le prochain bloc
        ret

; ============================================================
; msg_defaut_detail
; Rapporte immediatement un octet defectueux (en rouge), avec
; son adresse exacte et les valeurs attendue/lue en hexadecimal.
; Entree: ES:DI = adresse de l'octet, DH = valeur attendue,
;         DL = valeur relue.
; ============================================================
msg_defaut_detail:
        push    ax
        push    dx

        ; --- compteur global d'octets defectueux (RAM_DEFECT_BYTES, vit dans
        ; la fin du tampon d'edition du moniteur - voir hardware.inc): un
        ; octet defectueux = un appel a cette routine, quel que soit le
        ; motif qui l'a revele. ES:DI appartiennent a l'appelant
        ; (test_segment, en plein test): sauvegardes et restaures ici. ---
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, RAM_DEFECT_BYTES
        inc     word [es:di]
        pop     di
        pop     es

        mov     si, ANSI_ROUGE
        call    uart_tx_string
        mov     si, txt_defaut_detail
        call    uart_tx_string

        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        call    uart_tx_hex_word

        mov     si, txt_attendu
        call    uart_tx_string
        mov     al, dh
        call    uart_tx_hex_byte

        mov     si, txt_lu
        call    uart_tx_string
        mov     al, dl
        call    uart_tx_hex_byte

        mov     si, ANSI_BLANC
        call    uart_tx_string
        mov     si, txt_crlf
        call    uart_tx_string

        pop     dx
        pop     ax
        ret

; ============================================================
; msg_ram_ok / msg_ram_defectueuse
; ============================================================
msg_ram_ok:
        print   txt_ram_ok, UART
        ret

msg_ram_defectueuse:
        print   txt_ram_defaut, UART
        ret

; ============================================================
; msg_ram_total_defauts
; Affiche la quantite totale de RAM defectueuse (RAM_DEFECT_BYTES,
; remis a zero au debut de test_ram, incremente une fois par octet
; defectueux dans msg_defaut_detail): "TOTAL DEFAUT: <hex>h, <dec>
; octet(s)". Toujours affiche (0 si la RAM est bonne).
; ============================================================
msg_ram_total_defauts:
        push    ax

        mov     si, txt_total_defaut
        call    uart_tx_string

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, RAM_DEFECT_BYTES
        mov     ax, [es:di]

        call    uart_tx_hex_word
        mov     al, 'h'
        call    uart_tx_byte
        mov     al, ','
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte

        mov     ax, [es:di]
        call    uart_tx_dec_word

        mov     si, txt_total_defaut_fin       ; uart_tx_string lit par DS (= CS en permanence
        call    uart_tx_string                  ; dans cette ROM): ES (VAR_SEG ci-dessus) n'a pas
                                                  ; besoin d'etre restaure pour cet appel
        pop     ax
        ret

; ============================================================
; msg_dump_fin
; ============================================================
msg_dump_fin:
        print   txt_dump_fin, UART
        ret


; -------------------------------------------------------------------------------------------------
; Section suivante: routines d'initialisation et de controle des 8255 (PIO)
; -------------------------------------------------------------------------------------------------

;****************************************
;* init 8255's			                *
;****************************************
init_8255:

        ;*********************
        ; INIT LA 8255 NO. 1 *
        ;*********************
        ; Port A = MODE 2 (bus bidirectionnel avec l'Arduino, poignee de main
        ; sur PC3-PC7), Port B = SORTIE (canal), PC0-PC2 = ENTREES (etiquette
        ; de l'octet recu) - voir MASQUE_PIO, hardware.inc. Le mot de mode
        ; remet a 0 tous les verrous ET les indicateurs (dont INTE1/INTE2).
        ; PAS d'ecriture sur le Port A ici (un "OUT PORTA" en mode 2 place un
        ; octet dans le tampon de sortie: OBF# passerait a 0 et l'Arduino
        ; lirait un octet parasite) - et rien a ecrire sur le Port C.
        MOV    AL,MASQUE_PIO
        OUT    PIO,AL         ; CMD LA 8255
        MOV    AL,0
        OUT    PORTB,AL       ; canal 0 (UART) au repos
        MOV    AL,PIO_INTE1_RESET
        OUT    PIO,AL         ; INTE1 = 0 (pas d'interruption a l'emission)
        MOV    AL,PIO_INTE2_SET
        OUT    PIO,AL         ; INTE2 = 1 (INTR sur octet recu de l'Arduino)

	ret
; ***************************************

; ============================================================
; init_ivt_not_implemented / int_not_implemented / int_stubs: voir lib/bios.asm (chaque vecteur non
; implemente a son PROPRE petit gestionnaire, qui affiche le numero de l'interruption).
; ============================================================

; ============================================================
; setup_bios_interrupts
; Peuple l'IVT (segment 0000h, RAM) pour INT 10h (affichage) et
; INT 16h (clavier) - chaque entree est un pointeur FAR (offset puis
; segment, 4 octets, a l'adresse INT_NUM*4) vers int10h_handler/
; int16h_handler ci-dessous. Initialise aussi les curseurs logiques
; "esprit BIOS" (un jeu par device LCD/LCD I2C - voir
; BIOS_CURSOR_LCD_*/BIOS_CURSOR_LCDI2C_*, hardware.inc) a (0,0).
; Appelee une seule fois au demarrage (voir start:), avant toute
; utilisation de INT 10h/16h.
; ============================================================
setup_bios_interrupts:
        push    ax
        push    es

        xor     ax, ax
        mov     es, ax                          ; ES = 0000h (segment de l'IVT)
        mov     word [es:10h*4], int10h_handler
        mov     word [es:10h*4+2], cs
        mov     word [es:16h*4], int16h_handler
        mov     word [es:16h*4+2], cs
        call    bios_init                       ; INT 11h-1Ah (DOS) + zone de donnees 0040:0000

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     byte [es:di], 0

        pop     es
        pop     ax
        ret

; ============================================================
; init_8259
; Initialise le controleur d'interruptions 8259A (CS# = IO.A6./A7,
; ports PIC_CMD/PIC_DATA = 20h/21h - memes adresses que le PC/XT reel,
; voir include/hardware.inc et Directives.md) en mode STANDARD PC/XT:
;   - Declenchement par FRONT (edge-triggered), pas par niveau.
;   - 8259 UNIQUE (pas de cascade): ICW3 OMISE (jamais envoyee - avec
;     SNGL=1 dans ICW1, le 8259 n'attend que ICW2 PUIS ICW4).
;   - Mode 8086/8088 (uPM=1).
;   - EOI MANUEL (pas d'auto-EOI): plus fiable si plusieurs IRQ sont
;     en attente - voir irq0_test_handler, qui doit donc envoyer
;     explicitement un EOI (OCW2) avant de retourner.
;   - Vecteurs: IR0-IR7 -> INT 08h-0Fh (ICW2 = 08h, meme convention
;     que le BIOS PC reel - les 3 bits de poids faible du vecteur
;     final sont fournis automatiquement par le 8259 selon la ligne
;     IRQ qui a interrompu, PAS calcules ici).
;
; IR0 (bouton-poussoir de test) et IR1 (INTR du 8255 = octet recu de
; l'Arduino, clavier OU UART - voir irq1_arduino_handler) sont
; DEMASQUEES (OCW1) - IR2 a IR7 restent masquees: non cablees,
; potentiellement flottantes et donc bruyantes si demasquees
; prematurement (IR4 n'est plus cablee depuis le passage au mode 2 du
; 8255: l'UART recu arrive lui aussi par IR1).
;
; Installe irq0_test_handler/irq1_arduino_handler aux vecteurs INT
; 08h/09h (IVT, segment 0000h) - meme motif que
; setup_bios_interrupts ci-dessus pour INT 10h/16h. N'active PAS les
; interruptions (IF) elle-meme - voir start:, qui le fait explicitement
; APRES le retour de cette routine, une fois le 8259 configure ET les
; vecteurs installes.
; ============================================================
ICW1_EDGE_SINGLE_ICW4  equ     00010011b       ; D4=1(ICW1) LTIM=0(front)
                                                 ; SNGL=1(seul, pas d'ICW3)
                                                 ; IC4=1(ICW4 suit)
ICW2_VECTOR_BASE       equ     08h             ; IR0-IR7 -> INT 08h-0Fh
ICW4_8086_MANUAL_EOI   equ     00000001b       ; uPM=1(8086/8088), AEOI=0(manuel)
PIC_MASK_TEST          equ     PIC_IMR_NORMAL  ; OCW1 (IMR): demasque IR0/IR1 (include/hardware.inc)

init_8259:
        push    ax
        push    es

        cli                     ; par precaution - aucune IRQ ne doit
                                 ; survenir pendant la sequence ICW

        mov     al, ICW1_EDGE_SINGLE_ICW4
        out     PIC_CMD, al
        mov     al, ICW2_VECTOR_BASE
        out     PIC_DATA, al
        mov     al, ICW4_8086_MANUAL_EOI
        out     PIC_DATA, al

        mov     al, PIC_MASK_TEST
        out     PIC_DATA, al    ; OCW1 (registre de masque IMR)

        xor     ax, ax
        mov     es, ax                          ; ES = 0000h (segment de l'IVT)
        mov     word [es:08h*4], irq0_test_handler
        mov     word [es:08h*4+2], cs
        mov     word [es:09h*4], irq1_arduino_handler
        mov     word [es:09h*4+2], cs

        pop     es
        pop     ax
        ret

; ============================================================
; irq0_test_handler
; Gestionnaire de test pour IR0 (8259, vecteur INT 08h) - PREMIERE
; INTERRUPTION MATERIELLE reelle du projet, declenchee par le
; bouton-poussoir cable directement sur IR0. Affiche un message sur
; l'UART via un appel DIRECT a uart_tx_string (pas la macro "print", qui
; passe par INT 10h) - meme prudence que int_not_implemented. Envoie
; ensuite un EOI NON SPECIFIQUE (OCW2 = 20h au port de commande -
; obligatoire en mode EOI MANUEL, voir init_8259, sinon le 8259 croit la
; ligne toujours "en service" et ne represente plus jamais cette ligne,
; ni aucune de priorite egale ou inferieure), puis IRET.
;
; PAS de anti-rebond volontairement: plusieurs interruptions par appui
; sont attendues (confirme meme que le mecanisme reagit a chaque front).
; ============================================================
irq0_test_handler:
        push    ax
        push    si
        push    ds
        push    cs
        pop     ds                      ; DS=CS: Tiny Basic (lib/tiny_basic.asm) tourne avec
                                         ; DS=1000h - le message est en ROM

        mov     si, txt_irq0_test
        call    uart_tx_string

        mov     al, 20h                 ; OCW2: EOI non specifique
        out     PIC_CMD, al

        pop     ds
        pop     si
        pop     ax
        iret

; (irq1_arduino_handler: voir lib/isr.asm)

; ============================================================
; bios_cursor_ddram
; Calcule l'adresse DDRAM (SANS le bit de commande) correspondant a
; DH=ligne (0-3) / DL=colonne (0-19) - meme convention 4x20 que
; LCD_LINE1..4 (include/lcd_macros.inc), utilisee par int10h_handler.
; Aucune verification de bornes (meme choix que edit_ram_action).
; Entree:  DH = ligne, DL = colonne
; Sortie:  AH = adresse DDRAM (0-127)
; Detruit: rien d'autre que AH
; ============================================================
bios_cursor_ddram:
        push    bx
        cmp     dh, 0
        je      .r0
        cmp     dh, 1
        je      .r1
        cmp     dh, 2
        je      .r2
        mov     bl, LCD_LINE4 & 07Fh
        jmp     .add_col
.r0:    mov     bl, LCD_LINE1 & 07Fh
        jmp     .add_col
.r1:    mov     bl, LCD_LINE2 & 07Fh
        jmp     .add_col
.r2:    mov     bl, LCD_LINE3 & 07Fh
.add_col:
        add     bl, dl
        mov     ah, bl
        pop     bx
        ret

; ============================================================
; int10h_handler
; Gestionnaire de INT 10h (affichage), sous-ensemble "esprit BIOS"
; adapte a ce materiel (2 LCD HD44780 4x20 + UART - pas de memoire
; video ni de VGA). Voir aussi les macros gotoxy/print
; (include/lcd_macros.inc), qui sont la facon normale d'utiliser cette
; interface plutot que de preparer les registres et faire "int 10h"
; a la main.
;
;   AH=02h - Positionne le curseur LOGIQUE du device BH (persiste en
;            RAM - voir BIOS_CURSOR_LCD_*/BIOS_CURSOR_LCDI2C_*,
;            hardware.inc): DH=ligne (0-3), DL=colonne (0-19). UN JEU
;            DE CURSEUR PAR DEVICE (LCD parallele et LCD I2C
;            n'interferent pas l'un avec l'autre). Aucune verification
;            de bornes. BH=UART (3, ou toute autre valeur que 1/2):
;            no-op (un flux serie n'a pas de position).
;
;   AH=09h - Ecrit AL au curseur logique courant DU DEVICE BH, CX fois
;            de suite (remplit CX cellules CONSECUTIVES a partir de
;            cette position pour LCD/LCD I2C - meme convention que le
;            vrai BIOS IBM PC, PAS "le meme caractere CX fois au meme
;            endroit"; pour UART, transmet simplement AL, CX fois de
;            suite, sans notion de position). Le debordement d'une
;            ligne LCD de 20 suit l'auto-increment materiel du HD44780
;            (adressage DDRAM entrelace des afficheurs 4 lignes
;            "type A" - LCD_LINE3/4 suivent directement LCD_LINE1/2 en
;            memoire interne) et peut deborder sur une AUTRE ligne
;            visible - pas d'ecretage logiciel. Registres:
;              BH = peripherique cible: 1 = LCD parallele,
;                   2 = LCD I2C (PCF8574), 3 = UART - toute autre
;                   valeur est ignoree (aucun affichage). Voir
;                   LCD/LCDI2C/UART (include/lcd_macros.inc).
;              BL = couleur - actuellement SANS EFFET (reservee pour
;                   une prochaine version: sortie couleur via codes
;                   ANSI sur l'UART - voir Directives.md).
;              CX = nombre de repetitions (0 = aucun effet).
;            Le curseur logique (LCD/LCD I2C) N'EST PAS deplace par
;            cet appel (meme comportement que le vrai BIOS AH=09h) -
;            un appel ulterieur a AH=02h est necessaire pour ecrire
;            ailleurs.
;
; Toute autre valeur de AH est ignoree (retour immediat).
; ============================================================
int10h_handler:
        sti                     ; L'instruction INT a mis IF a 0. Chaque octet envoye
                                 ; a l'Arduino (arduino_send) peut attendre OBF#
                                 ; ~1 ms; le 8255 ne retient qu'UN octet clavier et
                                 ; l'Arduino en envoie un toutes les 500 us - avec
                                 ; IF=0, un octet (typiquement le 0F0h d'un relachement
                                 ; de touche) serait ecrase avant que irq1_arduino_handler
                                 ; ne le lise, ce qui fait avaler/dupliquer la touche
                                 ; suivante. Sans danger: aucune ISR n'appelle INT 10h.
        ; --- fonctions STANDARD (DOS): teletype, mode, curseur... sur le terminal UART (lib/bios.asm).
        ; AH=02h / 09h avec BH = 0 (page 0) sont aussi standard; BH = 1/2/3 = interface LCD/UART du projet ---
        cmp     ah, 02h
        je      .std_bh
        cmp     ah, 09h
        je      .std_bh
        cmp     ah, 0Eh
        je      bios_int10_std
        cmp     ah, 0Fh
        je      bios_int10_std
        cmp     ah, 03h
        je      bios_int10_std
        cmp     ah, 06h
        je      bios_int10_std
        cmp     ah, 07h
        je      bios_int10_std
        cmp     ah, 08h
        je      bios_int10_std
        cmp     ah, 0Ah
        je      bios_int10_std
        jmp     .lcd_iface
.std_bh:
        or      bh, bh
        jz      bios_int10_std
.lcd_iface:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        cmp     ah, 02h
        je      .set_cursor
        cmp     ah, 09h
        je      .write_char
        jmp     .done

.set_cursor:
        mov     ax, VAR_SEG
        mov     es, ax
        cmp     bh, 1
        je      .cursor_lcd
        cmp     bh, 2
        je      .cursor_lcdi2c
        jmp     .done                            ; UART (ou non reconnu): pas de curseur
.cursor_lcd:
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     [es:di], dh
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     [es:di], dl
        jmp     .done
.cursor_lcdi2c:
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     [es:di], dh
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     [es:di], dl
        jmp     .done

.write_char:
        cmp     cx, 0
        je      .done                            ; rien a ecrire

        cmp     bh, 3
        je      .dev_uart                        ; UART: pas de curseur - transmet direct

        mov     bp, ax                           ; BP = caractere original (AL) -
                                                   ; AX va servir de scratch pour
                                                   ; acceder a VAR_SEG
        mov     ax, VAR_SEG
        mov     es, ax
        cmp     bh, 1
        je      .load_lcd
        cmp     bh, 2
        je      .load_lcdi2c
        jmp     .done                            ; peripherique non reconnu - ignore

.load_lcd:
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     dh, [es:di]                      ; DH = ligne
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     dl, [es:di]                      ; DL = colonne
        call    bios_cursor_ddram                ; AH = adresse DDRAM (DH/DL consommes)
        mov     al, ah
        or      al, 80h                          ; AL = commande "Set DDRAM Address"
        call    i2c_lcd_command                      ; positionne le curseur materiel
        mov     ax, bp                           ; restaure AL = caractere
.dev_lcd_loop:
        call    i2c_lcd_data
        loop    .dev_lcd_loop
        jmp     .done

.load_lcdi2c:
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     dh, [es:di]
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     dl, [es:di]
        call    bios_cursor_ddram                ; AH = adresse DDRAM (DH/DL consommes)
        mov     al, ah
        or      al, 80h
        call    i2c_lcd_command                  ; positionne le curseur materiel
        mov     ax, bp                           ; restaure AL = caractere
.dev_i2c_loop:
        call    i2c_lcd_data
        loop    .dev_i2c_loop
        jmp     .done

.dev_uart:
        ; AL est deja le caractere a transmettre (aucun acces a
        ; VAR_SEG necessaire - pas de curseur pour ce device)
.dev_uart_loop:
        call    uart_tx_byte
        loop    .dev_uart_loop

.done:
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

; ============================================================
; int16h_handler
; Gestionnaire de INT 16h (clavier), sous-ensemble "esprit BIOS":
;
;   AH=01h - Lecture NON BLOQUANTE d'une touche: verifie CLOCK (PB0),
;            HAUT au repos (voir lib/ps2.asm), avant de lire une
;            trame en cours - meme technique que l'interruption
;            Echap de dump_memory_action. Si une touche est
;            disponible, elle est CONSOMMEE (ce projet, en polling
;            pur, n'a pas de tampon clavier permettant un "peek" sans
;            consommer, contrairement au vrai BIOS IBM PC - seule
;            approximation raisonnable ici).
;              Sortie: AH = scan code PS/2 Set 2 BRUT (voir
;                ps2_get_char), AL = caractere ASCII (ou PS2_KEY_*),
;                ZF=0 si une touche a ete lue. Si aucune touche
;                n'est disponible: AX=0, ZF=1.
;            IMPORTANT: le registre FLAGS restitue par IRET est celui
;            EMPILE PAR L'INSTRUCTION INT (pas l'etat courant du CPU)
;            - ce gestionnaire doit donc ecraser directement ce mot
;            sur la pile pour que le ZF ci-dessus soit visible a
;            l'appelant apres IRET (technique standard, voir
;            .set_flags plus bas). AX N'EST PAS PRESERVE (c'est la
;            sortie voulue) - BX/CX/DX/SI/DI/BP/ES le sont.
;
; Toute autre valeur de AH est ignoree (IRET immediat, flags et
; registres inchanges).
; ============================================================
; (int16h_handler: voir lib/bios.asm - clavier standard: AH=00h/01h/02h)

; ============================================================
; int10h_print_string
; Affiche une chaine terminee par 0 (jusqu'a 20 caracteres pour les
; LCD) via INT 10h (AH=09h) - procedure appelee par la macro "print"
; (include/lcd_macros.inc), la facon normale d'utiliser cette
; interface.
;
; LCD (BH=1) / LCD I2C (BH=2): relit la position de depart courante
; DU DEVICE CONCERNE (deja fixee par un "gotoxy ligne, colonne,
; device" prealable - voir int10h_handler, AH=02h), puis positionne
; (AH=02h) et ecrit (AH=09h) CARACTERE PAR CARACTERE, en avancant la
; colonne a chaque fois: AH=09h ne deplace PAS le curseur logique
; (meme convention que le vrai BIOS), il faut donc repositionner
; explicitement avant CHAQUE caractere.
;
; UART (BH=3): un flux serie n'a pas de position - transmet
; directement chaque caractere (AH=09h seul, un "gotoxy" prealable y
; serait un no-op de toute facon - voir int10h_handler).
;
; Entree:  BH = device (LCD/LCDI2C/UART - voir include/lcd_macros.inc),
;          DS:SI = texte termine par 0
; Detruit: rien (AX/BX/CX/DX/SI/DI/ES tous preserves)
; ============================================================
int10h_print_string:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        mov     bl, 0                    ; BL = couleur, N/A pour l'instant

        cmp     bh, 3
        je      .uart_loop

        ; --- LCD / LCD I2C: relit la position de depart courante DE
        ; CE DEVICE (deja fixee par gotoxy) ---
        mov     ax, VAR_SEG
        mov     es, ax
        cmp     bh, 2
        je      .read_lcdi2c
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     dh, [es:di]
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     dl, [es:di]
        jmp     .next_char_lcd
.read_lcdi2c:
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     dh, [es:di]
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     dl, [es:di]

.next_char_lcd:
        mov     al, [si]
        cmp     al, 0
        je      .done
        mov     ah, 02h
        int     10h                      ; positionne (DH,DL) sur BH - AX/BX
                                          ; preserves par int10h_handler
        mov     ah, 09h
        mov     cx, 1                    ; un seul caractere
        int     10h                      ; ecrit AL a (DH,DL) sur BH
        inc     si
        inc     dl
        jmp     .next_char_lcd

.uart_loop:
        mov     al, [si]
        cmp     al, 0
        je      .done
        mov     ah, 09h
        mov     cx, 1
        int     10h                      ; BH=3 -> transmission directe, sans position
        inc     si
        jmp     .uart_loop

.done:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; -------------------------------------------------------------------------------------------------
; Modules partages (LCD, UART, delay_ms) - voir Directives.md. Ces
; %include viennent APRES tout le code ci-dessus (qui appelle leurs
; procedures par reference avant, ce qui est normal: NASM resout
; les references avant comme apres dans un meme flux assemble) pour
; que start: reste le tout premier octet emis dans la ROM (contrainte
; du vecteur de reset materiel, voir reset_vector plus bas).
; -------------------------------------------------------------------------------------------------
%include "lib/common.asm"
%include "lib/lcd.asm"
%include "lib/uart.asm"
%include "lib/utils.asm"
%include "lib/lcd_i2c.asm"
%include "lib/ps2.asm"
%include "lib/bridge.asm"
%include "lib/isr.asm"
%include "lib/bios.asm"
%include "lib/tiny_basic.asm"
%include "lib/basic.asm"

; -------------------------------------------------------------------------------------------------
; Section suivante: donnees et textes
; -------------------------------------------------------------------------------------------------

; ---- couleurs ANSI ---
ANSI_ROUGE:             db      27,'[31m',0
ANSI_VERT:              db      27,'[32m',0
ANSI_BLEU:              db      27,'[34m',0
ANSI_JAUNE:             db      27,'[33m',0
ANSI_BLANC:             db      27,'[0m',0      ; reset
CLS:                    db      27,'[2J',27,'[H',0

; --- messages ---------------------------------------------------
; ---- Bilinguisme FR/EN (Manifest.md): tous les textes UART/LCD du
; ---- moniteur sont desormais dupliques en francais (branche %else,
; ---- PAR DEFAUT) et en anglais (branche %ifdef LANG_EN) - MEME
; ---- etiquette dans les 2 branches (un seul jeu de labels est
; ---- reellement assemble a la fois, selon -dLANG_EN - voir Makefile,
; ---- cibles "rom-fr"/"rom-en"). Textes PUREMENT techniques
; ---- (mnemoniques de registres AX=/BX=/.., drapeaux DEBUG.COM
; ---- OV/NV/.., sequences ANSI, "OK", donnees binaires) restent
; ---- PARTAGES (une seule definition, hors %ifdef) - deja
; ---- "universels", rien a traduire. Piege verifie AVANT de traduire
; ---- (voir Directives.md): certains textes LCD sont suivis d'un
; ---- positionnement de colonne CODE EN DUR (i2c_lcd_goto_col) qui
; ---- suppose une largeur de PREFIXE precise (cpu_test_show_progress/
; ---- show_result, colonne 8 apres "Ecoule: ") - la traduction
; ---- anglaise ("Elapsed:", SANS espace) a ete choisie pour garder
; ---- EXACTEMENT 8 caracteres, sans avoir a rendre cette colonne elle
; ---- aussi conditionnelle.
%ifdef LANG_EN

%ifdef TEST_PS2
txt_ps2_attente:        db      27,'[36m','=== PS/2 test (TEST_PS2): waiting for key presses (raw Set 2) ===',27,'[0m',13,10,0
txt_ps2_recu:           db      'Scan code received: 0x',0
txt_ps2_erreur:         db      ' <<< ERROR (invalid parity or stop bit)',13,10,0
%endif

txt_defaut_court:       db      'FAULT',27,'[0m',13,10,0
txt_attendu:            db      '  expected=',0
txt_lu:                 db      '  read=',0
txt_defaut_detail:      db      '  >> MEMORY FAULT @ ',0

txt_banniere1:          db      27,'[0m','=== RAM Test 128K (VE2CUY, UART report 9600 8N1, PA7) ===',27,'[0m',13,10,0
txt_banniere2:          db      'Plan: seg 0000h (00000h-0FFFFh, 64 blocks) + seg 1000h (10000h-1F7FFh, 62 blocks)',13,10,'2 KB reserved for the stack + Edit RAM buffer + PA7 shadow copy: 1F800h-1FFFFh (not tested)',13,10,13,10,0

txt_ram_ok:             db      27,'[32m','*** RAM OK - 129024 bytes tested (126 blocks of 1 KB), no errors ***',27,'[0m',13,10,13,10,0
txt_ram_defaut:         db      27,'[31m','*** FAULTY RAM - see fault details above ***',27,'[0m',13,10,13,10,0
txt_total_defaut:       db      'TOTAL FAULTS: ',0
txt_total_defaut_fin:   db      ' byte(s)',13,10,13,10,0

txt_dump_banniere1:      db      27,'[34m','=== Memory dump: ',0
txt_dump_banniere2:      db      ' to ',0
txt_dump_banniere3:      db      ' ===',27,'[0m',13,10,0

txt_dump_fin:            db      27,'[32m','*** Dump complete ***',27,'[0m',13,10,13,10,0

txt_dump_invalid_range: db      27,'[31m','*** End address < start address - dump cancelled ***',27,'[0m',13,10,13,10,0

txt_dump_interrupted:   db      27,'[33m','*** Dump interrupted (Esc) ***',27,'[0m',13,10,13,10,0

txt_reg_banniere:       db      27,'[34m','=== CPU Registers (8088) ===',27,'[0m',13,10,0

txt_irq0_test:          db      27,'[35m','*** IRQ0 triggered (pushbutton, 8259) ***',27,'[0m',13,10,0

txt_ivt_banniere:       db      27,'[36m',"=== Interrupt Vector Table (IVT, INT 00h-27h) ===",27,'[0m',13,10,13,10,0
txt_ivt_10h:            db      27,'[32m',"int10h_handler -> Display handling (LCD I2C/UART)",27,'[0m',0
txt_ivt_16h:            db      27,'[32m','int16h_handler -> Keyboard read (non-blocking)',27,'[0m',0
txt_ivt_irq0:           db      27,'[32m','irq0_test_handler -> IRQ0 test (pushbutton, 8259)',27,'[0m',0
txt_ivt_irq1:           db      27,'[32m','irq1_arduino_handler -> Keyboard/UART received (Arduino, 8255 mode 2, IR1)',27,'[0m',0
txt_ivt_not_impl:       db      'int_not_implemented -> Not implemented',0
txt_ivt_bios:           db      27,'[32m','handler installed (BIOS / DOS)',27,'[0m',0

txt_auteur:             db      '8088 on breadboard, version 2026',13,10
                        db      'By Alain Boudreault, aka VE2CUY',13,10
                        db      '--------------------------------',13,10,13,10,0

txt_menu_main_head:     db      27,'[36m','=== VE2CUY PCx86 ===',27,'[0m',13,10
                        db      '1) Basic', 0
txt_menu_main_rest:     db      '2) Memory functions',13,10
                        db      '3) USB Disk',13,10
                        db      '4) Configuration',13,10,13,10,0

txt_menu_basic:         db      27,'[36m','--- Basic Submenu ---',27,'[0m',13,10
                        db      '1) Tiny Basic',13,10
                        db      '2) BASIC',13,10
                        db      '(Esc: back to main menu)',13,10,13,10,0

txt_menu_dump:          db      27,'[36m','--- Memory functions Menu ---',27,'[0m',13,10
                        db      '1) Dump memory',13,10
                        db      '2) Edit RAM',13,10
                        db      '3) CPU Registers',13,10
                        db      '4) Edit+Run RAM',13,10
                        db      '5) IVT',13,10
                        db      '6) Test RAM',13,10
                        db      '(Esc: back to main menu)',13,10,13,10,0

txt_menu_usb_head:      db      27,'[36m','--- USB Disk Submenu ---',27,'[0m',13,10,0
txt_menu_usb_rest:      db      '2) List files',13,10
                        db      '3) Boot disk image',13,10
                        db      '(Esc: back to main menu)',13,10,13,10,0

txt_menu_config:        db      27,'[36m','--- Configuration Submenu ---',27,'[0m',13,10
                        db      '1) Clock speed',13,10
                        db      '2) Test CPU speed',13,10
                        db      '3) Set date and time',13,10
                        db      '4) Information',13,10
                        db      '(Esc: back to main menu)',13,10,13,10,0

txt_menu_clock_head:    db      27,'[36m','--- Clock speed ---',27,'[0m',13,10,0
txt_menu_clock_opts:    db      '1) Up   : 0.1 MHz',13,10
                        db      '2) Down : 0.1 MHz',13,10
                        db      '3) Up   : 1 MHz',13,10
                        db      '4) Down : 1 MHz',13,10
                        db      '5) 4.77 MHz',13,10
                        db      '6) 8.0 MHz',13,10
                        db      '(Esc: back to Configuration submenu)',13,10,13,10,0

txt_cpu_test_head:        db      27,'[36m','--- Test CPU speed ---',27,'[0m',13,10
                          db      'Benchmark running, duration: about 30 seconds'
                          db      ' (Esc to cancel)...',13,10,0
txt_cpu_test_elapsed:     db      'Elapsed: ', 0
txt_cpu_test_aborted:     db      13,10,'*** Test interrupted (Esc) ***',13,10,13,10,0
txt_cpu_test_result_prefix: db    'The 8088 is running ', 0
txt_cpu_test_faster:      db      '% faster than an 8088 at 4.77 MHz.',13,10,0
txt_cpu_test_slower:      db      '% slower than an 8088 at 4.77 MHz.',13,10,0
txt_cpu_test_estimated:   db      'Estimated speed: ', 0

; ---- option "3) Set date and time" du sous-menu Configuration
; ---- (clock_datetime_action, plus haut) ----
txt_datetime_time_prefix: db      'Time: ', 0
txt_datetime_saved:       db      'Date and time sent to the bridge.', 13, 10, 0

; ---- option "4) Information" du sous-menu Configuration
; ---- (information_action, plus haut) - PAS "lcd_text" (pas de padding a
; ---- 20 caracteres): ces etiquettes sont TOUJOURS suivies d'autre chose
; ---- sur la MEME ligne (chiffres...) - un padding deplacerait le curseur
; ---- PHYSIQUE du LCD trop loin (meme piege que le "curseur TTY" du
; ---- chantier precedent, voir Directives.md) ----
lcd_txt_info_disk:        db      'Disk:', 0
txt_info_return:          db      '(Esc: back to Configuration submenu)', 13, 10, 0

usb_msg_activating:     db      13,10,'USB currently OFF - activating...',13,10,0
usb_msg_deactivating:   db      13,10,'USB currently ON - deactivating...',13,10,0
usb_msg_on:             db      27,'[32m','USB ON: the PC has the disk (eject the drive before OFF).',27,'[0m',13,10,13,10,0
usb_msg_off:            db      27,'[32m','USB OFF: the bridge has taken back the disk.',27,'[0m',13,10,13,10,0
usb_msg_nosupport:      db      27,'[31m',"*** This bridge has no USB mass storage ***",27,'[0m',13,10,13,10,0
usb_msg_err:            db      27,'[31m','*** USB Error ***',27,'[0m',13,10,13,10,0

lf_title:               db      13,10,27,'[36m','--- Files ---',27,'[0m',13,10,0
lf_free_suffix:         db      ' bytes free',13,10,13,10,0

txt_term_title_edit:    db      27,'[36m','=== RAM Editor ===',27,'[0m',0
txt_term_help_edit:     db      27,'[33m','Arrows:move 0-9/A-F:value Enter:confirm Q:save Esc:cancel',27,'[0m',0
txt_term_title_run:     db      27,'[36m','=== Edit+Run RAM (1000:0000, 255 bytes) ===',27,'[0m',0
txt_term_help_run:      db      27,'[33m','Arrows:move 0-9/A-F:value Q:save R:run Esc:cancel',27,'[0m',0
txt_edit_help:           db     27,'[36m','L/R arrows: column | U/D arrows: row (scroll) | hex digit: edit | Enter: confirm cell | Q: save all | Esc: cancel all',27,'[0m',13,10,13,10,0

txt_edit_ivt_reject:    db      27,'[31m',"*** Address in the IVT (< 0x0400) - edit cancelled ***",27,'[0m',13,10,13,10,0
txt_edit_size_invalid:  db      27,'[31m','*** Invalid size (1-1024 bytes, within segment bounds) - edit cancelled ***',27,'[0m',13,10,13,10,0

txt_run_address:        db      27,'[36m',"Fixed address: 1000:0000 (2nd 64K block, 255 bytes)",27,'[0m',13,10,0
txt_run_help:            db     27,'[36m','L/R arrows: column | U/D arrows: row (scroll) | hex digit: edit (2nd digit auto-confirms, Enter optional for a single digit) | Q: save (without running) | R: save and run (RETF expected at the end, recognized even while typing) | Esc: cancel all',27,'[0m',13,10,13,10,0
txt_run_result_banner:  db      27,'[34m','=== Execution complete (1000:0000, RETF) - Registers ===',27,'[0m',13,10,0

; ---- textes LCD (anglais, 20 caracteres - voir la remarque sur
; ---- "Elapsed:" en tete de bloc pour lcd_txt_cpu_test_elapsed) ----
lcd_text lcd_txt_menu_config_l3, '3) Set date/time', 20
lcd_text lcd_txt_menu_dump_l3, '3) CPU Registers', 20
lcd_text lcd_txt_tb_l3, 'BYE or Ctrl-X: menu', 20
lcd_text lcd_txt_bas_l1, 'BASIC (GW-type)', 20
lcd_text lcd_txt_clock_opts_l3, '5)4.77 6)8.0 ESC=End', 20
lcd_text lcd_txt_cpu_test_elapsed, 'Elapsed:000 s', 20
lcd_text lcd_txt_cpu_test_cancel,  'Esc: cancel', 20
lcd_text lcd_txt_cpu_test_done,    'Esc: back', 20
lcd_text txt_lcd_ivt_loading, 'Loading IVT...', 20
lcd_text lcd_txt_run_ram_l2, 'Running...', 20
lcd_text lcd_txt_etat_ok, 'Status: OK', 20
lcd_text lcd_txt_etat_defaut, 'Status: FAULT', 20
lcd_txt_bloc_prefix:    db      'Blk:', 0
lcd_txt_bloc_mid:       db      '/126 Flt:', 0

%else

%ifdef TEST_PS2
txt_ps2_attente:        db      27,'[36m','=== Test PS/2 (TEST_PS2): en attente de frappes clavier (Set 2, brut) ===',27,'[0m',13,10,0
txt_ps2_recu:           db      'Scan code recu: 0x',0
txt_ps2_erreur:         db      ' <<< ERREUR (parite ou bit stop invalide)',13,10,0
%endif

txt_defaut_court:       db      'DEFAUT',27,'[0m',13,10,0
txt_attendu:            db      '  attendu=',0
txt_lu:                 db      '  lu=',0
txt_defaut_detail:      db      '  >> DEFAUT memoire @ ',0

txt_banniere1:          db      27,'[0m','=== Test RAM 128K (VE2CUY, rapport UART 9600 8N1, PA7) ===',27,'[0m',13,10,0
txt_banniere2:          db      'Plan: seg 0000h (00000h-0FFFFh, 64 blocs) + seg 1000h (10000h-1F7FFh, 62 blocs)',13,10,'2 Ko reserves a la pile + tampon Edit RAM + copie fantome PA7: 1F800h-1FFFFh (non testes)',13,10,13,10,0

txt_ram_ok:             db      27,'[32m','*** RAM OK - 129024 octets testes (126 blocs de 1 Ko), aucune erreur ***',27,'[0m',13,10,13,10,0
txt_ram_defaut:         db      27,'[31m','*** RAM DEFECTUEUSE - voir le detail des defauts ci-dessus ***',27,'[0m',13,10,13,10,0
txt_total_defaut:       db      'TOTAL DEFAUT: ',0
txt_total_defaut_fin:   db      ' octet(s)',13,10,13,10,0

; ---- bandeau de dump_memory_action: "=== Dump memoire: SSSS:OOOO a
; ---- SSSS:OOOO ===" - les adresses (saisies au clavier) sont
; ---- inserees entre ces 3 fragments par le code lui-meme ----
txt_dump_banniere1:      db      27,'[34m','=== Dump memoire: ',0
txt_dump_banniere2:      db      ' a ',0
txt_dump_banniere3:      db      ' ===',27,'[0m',13,10,0

txt_dump_fin:            db      27,'[32m','*** Dump termine ***',27,'[0m',13,10,13,10,0

txt_dump_invalid_range: db      27,'[31m','*** Adresse de fin < adresse de depart - dump annule ***',27,'[0m',13,10,13,10,0

txt_dump_interrupted:   db      27,'[33m','*** Dump interrompu (Echap) ***',27,'[0m',13,10,13,10,0

txt_reg_banniere:       db      27,'[34m','=== Registres CPU (8088) ===',27,'[0m',13,10,0

txt_irq0_test:          db      27,'[35m','*** IRQ0 declenchee (bouton-poussoir, 8259) ***',27,'[0m',13,10,0

txt_ivt_banniere:       db      27,'[36m',"=== Table des vecteurs d'interruption (IVT, INT 00h-27h) ===",27,'[0m',13,10,13,10,0
txt_ivt_10h:            db      27,'[32m',"int10h_handler -> Gestion de l'affichage (LCD I2C/UART)",27,'[0m',0
txt_ivt_16h:            db      27,'[32m','int16h_handler -> Lecture clavier (non bloquante)',27,'[0m',0
txt_ivt_irq0:           db      27,'[32m','irq0_test_handler -> Test IRQ0 (bouton-poussoir, 8259)',27,'[0m',0
txt_ivt_irq1:           db      27,'[32m','irq1_arduino_handler -> Clavier/UART recus (Arduino, 8255 mode 2, IR1)',27,'[0m',0
txt_ivt_not_impl:       db      'int_not_implemented -> Non implementee',0
txt_ivt_bios:           db      27,'[32m','gestionnaire installe (BIOS / DOS)',27,'[0m',0

txt_auteur:             db      '8088 sur breadboard version 2026',13,10
                        db      'Par Alain Boudreault, aka VE2CUY',13,10
                        db      '--------------------------------',13,10,13,10,0

; ---- menu principal / sous-menus (voir start:) - textes UART,
; ---- affiches en plus des lignes LCD dediees ci-dessous. Le menu
; ---- principal n'a plus que 4 options, chacune un sous-menu: "1)
; ---- Test RAM" (ex-option 1) est maintenant "6) Test RAM" du
; ---- sous-menu Memory functions; "3) Tiny Basic"/"4) BASIC"
; ---- (ex-options du menu principal) forment le sous-menu Basic; "5)
; ---- DOS (boot a disk image)" (ex-option 5) est maintenant "3) Boot
; ---- disk image" du sous-menu USB Disk. "4) Edit RAM" retire du menu
; ---- principal de longue date: disponible en "2) Edit RAM" du
; ---- sous-menu Memory functions ----
; ---- menu principal (voir .main_menu): "1) Basic" n'a PAS de CRLF final -
; ---- clock_main_speed_print y ajoute la frequence courante de l'horloge,
; ---- AVANT de continuer avec txt_menu_main_rest ----
txt_menu_main_head:     db      27,'[36m','=== VE2CUY PCx86 ===',27,'[0m',13,10
                        db      '1) Basic', 0
txt_menu_main_rest:     db      '2) Memory functions',13,10
                        db      '3) USB Disk',13,10
                        db      '4) Configuration',13,10,13,10,0

txt_menu_basic:         db      27,'[36m','--- Sous-menu Basic ---',27,'[0m',13,10
                        db      '1) Tiny Basic',13,10
                        db      '2) BASIC',13,10
                        db      '(Echap: retour au menu principal)',13,10,13,10,0

txt_menu_dump:          db      27,'[36m','--- Menu Memory functions ---',27,'[0m',13,10
                        db      '1) Dump memory',13,10
                        db      '2) Edit RAM',13,10
                        db      '3) Registres CPU',13,10
                        db      '4) Edit+Run RAM',13,10
                        db      '5) IVT',13,10
                        db      '6) Test RAM',13,10
                        db      '(Echap: retour au menu principal)',13,10,13,10,0

; ---- sous-menu USB Disk (voir .usb_menu): l'option 1 ("1) USB:
; OFF"/"1) USB: ON") n'est PAS dans ce texte - elle est generee par
; usb_state_print, entre les deux moities ci-dessous, pour montrer
; l'etat courant de BIOS_USB_STATE ----
txt_menu_usb_head:      db      27,'[36m','--- Sous-menu USB Disk ---',27,'[0m',13,10,0
txt_menu_usb_rest:      db      '2) List files',13,10
                        db      '3) Boot disk image',13,10
                        db      '(Echap: retour au menu principal)',13,10,13,10,0

txt_menu_config:        db      27,'[36m','--- Sous-menu Configuration ---',27,'[0m',13,10
                        db      '1) Clock speed',13,10
                        db      '2) Test CPU speed',13,10
                        db      '3) Heure et date',13,10
                        db      '4) Information',13,10
                        db      '(Echap: retour au menu principal)',13,10,13,10,0

; ---- option "1) Clock speed" du sous-menu Configuration (clock_speed_action
; ---- / clock_show, plus bas): affiche et regle la frequence de l'horloge
; ---- du 8088, generee par le pont (fs_clock_cmd, lib/bridge.asm). Menu
; ---- affiche UNE SEULE FOIS a l'entree (texte fixe) - la ligne "Current
; ---- speed: ..." est SEPAREE (clock_show), redessinee a chaque touche ----
txt_menu_clock_head:    db      27,'[36m','--- Clock speed ---',27,'[0m',13,10,0
txt_menu_clock_opts:    db      '1) Up   : 0.1 MHz',13,10
                        db      '2) Down : 0.1 MHz',13,10
                        db      '3) Up   : 1 MHz',13,10
                        db      '4) Down : 1 MHz',13,10
                        db      '5) 4.77 MHz',13,10
                        db      '6) 8.0 MHz',13,10
                        db      '(Echap: retour au sous-menu Configuration)',13,10,13,10,0

; ---- option "2) Test CPU speed" du sous-menu Configuration
; ---- (cpu_speed_test_action / cpu_test_show_progress / cpu_test_show_result,
; ---- plus haut): banc d'essai a charge fixe, mesure la vitesse REELLE du
; ---- 8088 via la RTC du pont (independante de l'horloge du 8088) ----
txt_cpu_test_head:        db      27,'[36m','--- Test CPU speed ---',27,'[0m',13,10
                          db      'Banc d', 27h, 'essai en cours, duree: environ 30 secondes'
                          db      ' (Echap pour annuler)...',13,10,0
txt_cpu_test_elapsed:     db      'Ecoule: ', 0
txt_cpu_test_aborted:     db      13,10,'*** Test interrompu (Echap) ***',13,10,13,10,0
txt_cpu_test_result_prefix: db    'Le 8088 roule ', 0
txt_cpu_test_faster:      db      '% plus vite qu', 27h, 'un 8088 a 4,77 MHz.',13,10,0
txt_cpu_test_slower:      db      '% plus lent qu', 27h, 'un 8088 a 4,77 MHz.',13,10,0
txt_cpu_test_estimated:   db      'Vitesse estimee: ', 0

; ---- option "3) Heure et date" du sous-menu Configuration
; ---- (clock_datetime_action, plus haut) ----
txt_datetime_time_prefix: db      'Heure: ', 0
txt_datetime_saved:       db      'Heure et date envoyees au pont.', 13, 10, 0

; ---- option "4) Information" du sous-menu Configuration
; ---- (information_action, plus haut) - PAS "lcd_text", voir la remarque
; ---- equivalente dans la branche %ifdef LANG_EN ----
lcd_txt_info_disk:        db      'Disque:', 0
txt_info_return:          db      '(Echap: retour au sous-menu Configuration)', 13, 10, 0

; ---- option "1) USB ON/OFF" du sous-menu USB Disk (usb_toggle_action)
; ---- - bascule: le message "actuellement ..." part AVANT la
; ---- commande au pont, les autres selon le resultat ----
usb_msg_activating:     db      13,10,'USB actuellement OFF - activation...',13,10,0
usb_msg_deactivating:   db      13,10,'USB actuellement ON - desactivation...',13,10,0
usb_msg_on:             db      27,'[32m','USB ON: le PC a le disque (ejecter le lecteur avant OFF).',27,'[0m',13,10,13,10,0
usb_msg_off:            db      27,'[32m','USB OFF: le pont a repris le disque.',27,'[0m',13,10,13,10,0
usb_msg_nosupport:      db      27,'[31m',"*** Ce pont n'a pas de lecteur de masse USB ***",27,'[0m',13,10,13,10,0
usb_msg_err:            db      27,'[31m','*** Erreur USB ***',27,'[0m',13,10,13,10,0

; ---- option "2) List files" du sous-menu USB Disk (list_files_action)
; ---- - meme esprit que FILES au BASIC (nom, taille, puis espace
; ---- libre), mais sur l'UART seulement ----
lf_title:               db      13,10,27,'[36m','--- Files ---',27,'[0m',13,10,0
lf_free_suffix:         db      ' octets libres',13,10,13,10,0

; ---- invite "Edit RAM" (voir edit_ram_action) ----
; ---- vue terminal de l'editeur (voir edit_ram_draw_terminal) ----
txt_term_title_edit:    db      27,'[36m','=== Editeur RAM ===',27,'[0m',0
txt_term_help_edit:     db      27,'[33m','Fleches:deplacer 0-9/A-F:valeur Entree:valider Q:enregistrer Echap:annuler',27,'[0m',0
txt_term_title_run:     db      27,'[36m','=== Edit+Run RAM (1000:0000, 255 octets) ===',27,'[0m',0
txt_term_help_run:      db      27,'[33m','Fleches:deplacer 0-9/A-F:valeur Q:enregistrer R:executer Echap:annuler',27,'[0m',0
txt_edit_help:           db     27,'[36m','Fleches G/D: colonne | Fleches H/B: ligne (defilement) | chiffre hexa: editer | Entree: valider la case | Q: enregistrer tout | Echap: annuler tout',27,'[0m',13,10,13,10,0

txt_edit_ivt_reject:    db      27,'[31m',"*** Adresse dans l'IVT (< 0x0400) - edition annulee ***",27,'[0m',13,10,13,10,0
txt_edit_size_invalid:  db      27,'[31m','*** Taille invalide (1-1024 octets, dans les limites du segment) - edition annulee ***',27,'[0m',13,10,13,10,0

; ---- invites "Edit+Run RAM" (voir edit_run_action) ----
txt_run_address:        db      27,'[36m',"Adresse fixe: 1000:0000 (2e bloc de 64K, 255 octets)",27,'[0m',13,10,0
txt_run_help:            db     27,'[36m','Fleches G/D: colonne | Fleches H/B: ligne (defilement) | chiffre hexa: editer (2e chiffre valide automatiquement, Entree optionnelle pour 1 seul chiffre) | Q: enregistrer (sans executer) | R: enregistrer et executer (RETF attendu a la fin, reconnue meme pendant la saisie) | Echap: annuler tout',27,'[0m',13,10,13,10,0
txt_run_result_banner:  db      27,'[34m','=== Execution terminee (1000:0000, RETF) - Registres ===',27,'[0m',13,10,0

; ---- textes LCD (francais, 20 caracteres) ----
lcd_text lcd_txt_menu_config_l3, '3) Heure et date', 20
lcd_text lcd_txt_menu_dump_l3, '3) Registres CPU', 20
lcd_text lcd_txt_tb_l3, 'BYE ou Ctrl-X: menu', 20
lcd_text lcd_txt_bas_l1, 'BASIC (type GW)', 20
lcd_text lcd_txt_clock_opts_l3, '5)4.77 6)8.0 ESC=Fin', 20
lcd_text lcd_txt_cpu_test_elapsed, 'Ecoule: 000 s', 20
lcd_text lcd_txt_cpu_test_cancel,  'Echap: annuler', 20
lcd_text lcd_txt_cpu_test_done,    'Echap: retour', 20
lcd_text txt_lcd_ivt_loading, 'Chargement IVT...', 20
lcd_text lcd_txt_run_ram_l2, 'En cours...', 20
lcd_text lcd_txt_etat_ok, 'Etat: OK', 20
lcd_text lcd_txt_etat_defaut, 'Etat: DEFAUT', 20
lcd_txt_bloc_prefix:    db      'Bloc:', 0
lcd_txt_bloc_mid:       db      '/126 Def:', 0

%endif ; LANG_EN

; ---- textes PARTAGES (identiques FR/EN - mnemoniques, separateurs,
; ---- sequences ANSI, donnees binaires: rien a traduire) ----
txt_crlf:               db      13,10,0
txt_ok_court:           db      'OK',27,'[0m',13,10,0
txt_reg_ax:             db      'AX=', 0
txt_reg_bx:             db      'BX=', 0
txt_reg_cx:             db      'CX=', 0
txt_reg_dx:             db      'DX=', 0
txt_reg_sp:             db      'SP=', 0
txt_reg_bp:             db      'BP=', 0
txt_reg_si:             db      'SI=', 0
txt_reg_di:             db      'DI=', 0
txt_reg_ds:             db      'DS=', 0
txt_reg_es:             db      'ES=', 0
txt_reg_ss:             db      'SS=', 0
txt_reg_cs:             db      'CS=', 0
txt_reg_ip:             db      'IP=', 0
txt_reg_pair_sep:       db      '    ', 0       ; separateur entre 2 registres
                                                 ; sur la meme ligne UART
txt_reg_flags_prefix:   db      'FLAGS=', 0
txt_reg_flags_sep:      db      '  ', 0

; ---- mnemoniques FLAGS (convention DEBUG.COM: OV/NV=overflow,
; ---- DN/UP=direction, EI/DI=interruptions, NG/PL=signe, ZR/NZ=zero,
; ---- AC/NA=retenue auxiliaire, PE/PO=parite, CY/NC=retenue) -
; ---- l'etat "actif" (bit=1) est en jaune (voir uart_flag_bit,
; ---- section macros) pour ressortir a l'oeil sur le terminal ----
txt_flag_of_set:        db      27,'[33m','OV',27,'[0m',' ',0
txt_flag_of_clear:      db      'NV', ' ', 0
txt_flag_df_set:        db      27,'[33m','DN',27,'[0m',' ',0
txt_flag_df_clear:      db      'UP', ' ', 0
txt_flag_if_set:        db      27,'[33m','EI',27,'[0m',' ',0
txt_flag_if_clear:      db      'DI', ' ', 0
txt_flag_sf_set:        db      27,'[33m','NG',27,'[0m',' ',0
txt_flag_sf_clear:      db      'PL', ' ', 0
txt_flag_zf_set:        db      27,'[33m','ZR',27,'[0m',' ',0
txt_flag_zf_clear:      db      'NZ', ' ', 0
txt_flag_af_set:        db      27,'[33m','AC',27,'[0m',' ',0
txt_flag_af_clear:      db      'NA', ' ', 0
txt_flag_pf_set:        db      27,'[33m','PE',27,'[0m',' ',0
txt_flag_pf_clear:      db      'PO', ' ', 0
txt_flag_cf_set:        db      27,'[33m','CY',27,'[0m',' ',0
txt_flag_cf_clear:      db      'NC', ' ', 0

txt_ivt_int_prefix:     db      'INT ', 0
txt_ivt_h_arrow:        db      'h -> ', 0
txt_ivt_sep:            db      ' : ', 0

usb_opt1_off:           db      '1) USB: OFF', 0
usb_opt1_on:            db      '1) USB: ON', 0

txt_clock_freq_prefix:  db      'Current speed: ', 0
txt_clock_freq_suffix:  db      ' MHz', 0
txt_cpu_test_seconds:     db      ' s', 0

; ---- options "3) Heure et date"/"4) Information" du sous-menu
; ---- Configuration (clock_datetime_action/information_action, plus
; ---- haut) - PAS de padding "lcd_text" pour aucun de ces labels: tous
; ---- sont suivis d'autre chose sur la MEME ligne (chiffres, un autre
; ---- label...) - voir la remarque dans la branche %ifdef LANG_EN pour
; ---- lcd_txt_info_disk ----
txt_datetime_date_prefix: db      'Date: ', 0             ; identique FR/EN
txt_info_head:            db      27,'[36m','--- Information ---',27,'[0m',13,10,0  ; identique FR/EN
lcd_txt_info_bios:        db      'BIOS:', 0
txt_info_stm_prefix:      db      'STM:', 0
lcd_txt_info_ram:         db      'RAM:', 0
txt_info_kb:              db      'K ', 0
txt_info_cpu_prefix:      db      'CPU: ', 0
txt_info_kb2:             db      'KB', 0

lf_crlf:                db      13,10,0

txt_edit_address_prefix: db     'Address: 0x', 0
txt_edit_size_prefix:   db      'Size:    0x', 0
txt_ansi_cls:           db      27,'[2J',27,'[H',0
txt_ansi_eol:           db      27,'[K',0
txt_ansi_eos:           db      27,'[J',0

; ---- programme de test par defaut copie dans la RAM reelle a
; 1000:0000 a l'entree dans edit_run_action (40 41 F7 E1 83 C3 02 CB =
; "inc ax" / "inc cx" / "mul cx" / "add bx,2" / "retf") ----
edit_run_default_code:     db      040h, 041h, 0F7h, 0E1h, 083h, 0C3h, 002h, 0CBh
edit_run_default_code_len  equ     $ - edit_run_default_code

; ---- invites "Dump memory" (voir dump_memory_action) - "End:   0x"
; ---- a la meme longueur (9) que "Start: 0x" pour que les chiffres
; ---- de segment se retrouvent a la meme colonne DDRAM sur les
; ---- lignes 1/2 du LCD ----
txt_dump_start_prefix:  db      'Start: 0x', 0
txt_dump_end_prefix:    db      'End:   0x', 0
txt_dump_seg_off_sep:   db      ':0x', 0

; ---- textes LCD (20 caracteres, complete automatiquement par des
; ---- espaces via "times" - afficheur 4x20) - PARTAGES: deja en
; ---- anglais (splash, menus) ou purement numeriques/mnemoniques ----

; ---- ecran de demarrage (3 secondes, une seule fois - voir start:) ----
lcd_text lcd_txt_splash_l1, 'Breadboard 8088', 20
lcd_text lcd_txt_splash_l2, 'Version 1.2', 20
lcd_txt_splash_l3:      times   20 db '-'       ; remplissage '-' (pas ' ') - hors macro
                        db      0
lcd_text lcd_txt_splash_l4, '(c) VE2CUY 2026', 20

; ---- menu principal (voir start:) - 1 ligne LCD par option, 4
; ---- sous-menus (Basic, Memory functions, USB Disk, Configuration -
; ---- meme texte que le menu UART, txt_menu_main_head/rest). La frequence
; ---- d'horloge courante ecrase les colonnes 15-19 de la ligne 0 apres
; ---- coup (clock_main_speed_print) ----
lcd_text lcd_txt_menu_main_l1, '1) Basic', 20
lcd_text lcd_txt_menu_main_l2, '2) Memory functions', 20
lcd_text lcd_txt_menu_main_l3, '3) USB Disk', 20
lcd_text lcd_txt_menu_main_l4, '4) Configuration', 20

; ---- sous-menu Basic (voir .basic_menu, start:) - 2 options,
; ---- tiennent sur le LCD sans pagination ----
lcd_text lcd_txt_menu_basic_l1, '1) Tiny Basic', 20
lcd_text lcd_txt_menu_basic_l2, '2) BASIC', 20

; ---- ecran LCD pendant Tiny Basic (option 1 du sous-menu Basic) ----
lcd_text lcd_txt_tb_l1, 'Tiny Basic', 20
lcd_text lcd_txt_tb_l2, 'Terminal UART', 20

; ---- ecran LCD pendant BASIC (option 2 du sous-menu Basic) ----
lcd_text lcd_txt_bas_l2, 'Terminal UART', 20
lcd_text lcd_txt_bas_l3, 'SYSTEM/Ctrl-X: menu', 20

; ---- menu Memory functions (voir .dump_menu, start:) - PAGINE sur 2
; ---- ecrans LCD depuis l'ajout de "5) IVT" (Gauche/Droite pour
; ---- basculer, comme registers_dump_action - voir txt_lcd_page1/
; ---- page2): page 1 = options 1-4 (lignes 1-4, "1/2" en haut a
; ---- droite de la ligne 1), page 2 = options 5-6 (lignes 1-2, "2/2"
; ---- en haut a droite de la ligne 1 - "6) Test RAM", ex-option 1 du
; ---- menu principal). Echap (non affiche a l'ecran) fait office de
; ---- retour au menu principal, sur les 2 pages ----
lcd_text lcd_txt_menu_dump_l1, '1) Dump memory', 20
lcd_text lcd_txt_menu_dump_l2, '2) Edit RAM', 20
lcd_text lcd_txt_menu_dump_l4, '4) Edit+Run RAM', 20
lcd_text lcd_txt_menu_dump_l5, '5) IVT', 20
lcd_text lcd_txt_menu_dump_l6, '6) Test RAM', 20

; ---- sous-menu USB Disk (voir .usb_menu, start:) - 3 options,
; ---- tiennent sur le LCD sans pagination ("1) USB: OFF"/"1) USB: ON"
; ---- genere par usb_state_print, pas ici - voir solution-01.asm) ----
lcd_text lcd_txt_menu_usb_l2, '2) List files', 20
lcd_text lcd_txt_menu_usb_l3, '3) Boot disk image', 20

; ---- sous-menu Configuration (voir .config_menu, start:) - 4 options,
; ---- tiennent sur le LCD sans pagination (l3 - "3) Heure et date"/"3) Set
; ---- date/time" - est bilingue, voir plus haut) ----
lcd_text lcd_txt_menu_config_l1, '1) Clock speed', 20
lcd_text lcd_txt_menu_config_l2, '2) Test CPU speed', 20
lcd_text lcd_txt_menu_config_l4, '4) Information', 20

; ---- option "1) Clock speed" (voir clock_speed_action) - ligne 0 (index
; ---- 0, gotoxy) reste libre: clock_show y ecrit "N.NN MHz" (la frequence
; ---- courante), redessinee a chaque touche - PAS de titre statique separe
; ---- ici (contrairement a l'ancienne version - voir Directives.md), les
; ---- options 1-6 + Echap sont ci-dessous, sur les lignes 1-3 (option
; ---- "3" - "5)4.77 6)8.0 ESC=Fin/End" - traduite plus haut) ----
lcd_text lcd_txt_clock_opts_l1, '1)+0.1 2)-0.1', 20
lcd_text lcd_txt_clock_opts_l2, '3)+1MHz 4)-1MHz', 20

; ---- option "2) Test CPU speed" (voir cpu_speed_test_action et suite,
; ---- plus haut). Ligne 0: "Ecoule/Elapsed: 000 s" (traduite plus haut,
; ---- largeur de prefixe critique - voir la remarque en tete de bloc) -
; ---- dessinee UNE SEULE FOIS (par cpu_speed_test_action), seuls les 3
; ---- chiffres (colonne 8) sont redessines ensuite
; ---- (cpu_test_show_progress/cpu_test_show_result) - largeur CONSTANTE,
; ---- meme principe que clock_show. Lignes 1-2: titre/aide PENDANT le
; ---- test (traduites plus haut), REMPLACEES par le resultat a la fin
; ---- (cpu_test_show_result) - prefixes seulement, les valeurs
; ---- (pourcentage/vitesse) sont ajoutees juste apres. "vs 4.77MHz: "/
; ---- "Est: " deja identiques en anglais (abreviations universelles) -
; ---- PARTAGES, pas de position de colonne a rendre conditionnelle ----
lcd_text lcd_txt_cpu_test_title,   'Test CPU speed', 20
lcd_text lcd_txt_cpu_test_vs,      'vs 4.77MHz: ', 20
lcd_text lcd_txt_cpu_test_est,     'Est: ', 20

; ---- registres CPU (voir registers_dump_action) - prefixes courts
; ---- (LCD 4x20, contrairement aux prefixes UART txt_reg_* qui
; ---- incluent leur propre separation) et indicateur de page ----
txt_lcd_reg_ax:         db      'AX=', 0
txt_lcd_reg_bx:         db      'BX=', 0
txt_lcd_reg_cx:         db      'CX=', 0
txt_lcd_reg_dx:         db      'DX=', 0
txt_lcd_reg_si:         db      'SI=', 0
txt_lcd_reg_di:         db      'DI=', 0
txt_lcd_reg_sp:         db      'SP=', 0
txt_lcd_reg_bp:         db      'BP=', 0
txt_lcd_reg_cs:         db      'CS=', 0
txt_lcd_reg_ds:         db      'DS=', 0
txt_lcd_reg_es:         db      'ES=', 0
txt_lcd_reg_ss:         db      'SS=', 0
txt_lcd_reg_ip:         db      'IP=', 0
txt_lcd_reg_fl:         db      'FL=', 0
txt_lcd_page1:          db      '1/2', 0
txt_lcd_page2:          db      '2/2', 0

; ---- bandeau ligne1/ligne2 affiche avant chaque action lancee depuis
; ---- un menu (lignes 3/4 sont mises a jour en direct par l'action
; ---- elle-meme - voir start:) - ligne 2 ("En cours..."/"Running...")
; ---- traduite plus haut ----
lcd_text lcd_txt_run_ram_l1, 'Test RAM 128K', 20

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
