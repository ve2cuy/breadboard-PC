; ============================================================
; ps2.asm
; Clavier PS/2 decode par un Arduino externe (version Arduino - voir
; Directives.md), qui gere lui-meme le protocole bit-a-bit (CLOCK/
; DATA, timing asynchrone impose par le clavier) et presente le scan
; code assemble (Set 2, brut) sur le Port A du 8255 (mode 2, etiquette
; PC0=0) - INTR du 8255, cable sur IR1 du 8259, declenche l'ISR. REMPLACE l'ancien decodage bit-bangue sur le Port B (voir git
; log pour l'historique du protocole CLOCK/DATA/parite, desormais
; gere par l'Arduino et non plus par le 8088).
;
; ps2_read_byte (ci-dessous) garde EXACTEMENT le meme contrat qu'avant
; (AL=octet recu, CF=erreur) pour que ps2_get_char et tout ce qui en
; depend (ps2_read_hex_editable, ps2_edit_byte_value, etc. - INCHANGES
; plus bas) n'aient RIEN a savoir du changement de transport - seul
; change CE QUI remplit le tampon (irq1_arduino_handler, solution-01.asm,
; au lieu d'un bit-bang direct). CF vaut maintenant TOUJOURS 0 (succes)
; puisque l'Arduino a deja valide la trame de son cote.
;
; Scan Code Set 2 (defaut du clavier a la mise sous tension, aucune
; commande d'initialisation requise, inchange cote Arduino): un
; "make" (touche pressee) envoie 1 octet (ou 2 pour les touches
; etendues, prefixees de 0E0h); un "break" (touche relachee) est
; prefixe de 0F0h. ps2_get_char gere ces prefixes (voir plus bas) et
; ne retourne que les caracteres reconnus issus d'un appui (jamais
; d'un relachement).
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef PS2_ASM
%define PS2_ASM

%include "include/hardware.inc"
%include "lib/lcd_i2c.asm"      ; reutilise i2c_lcd_tx_hex_nibble (echo saisie
                                  ; hexa) - LCD I2C, plus le LCD parallele
                                  ; (voir Directives.md: tout l'affichage LCD
                                  ; est passe au LCD I2C)
%include "lib/uart.asm"         ; reutilise uart_tx_hex_nibble (echo saisie hexa)

; Codes retournes par ps2_get_char pour les fleches (touches etendues,
; prefixe 0E0h) - valeurs choisies dans une plage inutilisee (aucun
; caractere ASCII imprimable, ni CR/BS/ESC deja utilises par ce projet).
PS2_KEY_UP      equ     11h
PS2_KEY_DOWN    equ     12h
PS2_KEY_LEFT    equ     13h
PS2_KEY_RIGHT   equ     14h

; ============================================================
; ps2_rx_push / ps2_read_byte
; Tampon circulaire (16 octets, PS2_RX_BUF_OFF - voir hardware.inc,
; tete=queue -> vide, 15 octets utiles) rempli de facon ASYNCHRONE par
; irq1_arduino_handler (solution-01.asm) a chaque scan code recu de
; l'Arduino. Producteur (ISR)/consommateur (boucle principale) uniques
; - sans danger sans desactiver les interruptions (indices tete/queue
; d'un seul octet, lus/ecrits de facon atomique par rapport a une
; IRQ). Aucune detection de debordement (ecrase le plus ancien octet
; si le tampon est plein - meme choix que uart_rx_push, lib/uart.asm).
;
; ps2_read_byte BLOQUE (attente active) jusqu'a ce qu'un octet soit
; disponible - MEME CONTRAT que l'ancienne version bit-bangue (voir
; en-tete du fichier): Sortie AL=octet recu, CF=0 TOUJOURS (l'Arduino
; a deja valide la trame). Detruit AX, BX, CX, DX (comme avant - CX/DX
; ne servent plus, mais gardes dans le contrat pour ne RIEN changer
; cote appelants). Jamais SI/DI/ES/BP.
; ============================================================
; ps2_rx_push: AL = scan code -> tampon. ISR seulement: DS = VAR_SEG (mis par l'ISR, jamais SS:
; le programme interrompu - un DOS - a sa propre pile). Preserve tout.
ps2_rx_push:
        push    bx
        xor     bh, bh                  ; BX = index (BH arbitraire dans une ISR)
        mov     bl, [PS2_RX_TAIL_OFF]   ; BL = queue actuelle
        mov     [PS2_RX_BUF_OFF + bx], al       ; ecrit l'octet a la position queue
        inc     bl
        and     bl, 0Fh                 ; enroulement (taille=16)
        mov     [PS2_RX_TAIL_OFF], bl
        pop     bx
        ret

ps2_read_byte:
        push    bp
        push    bx
        xor     bh, bh                  ; BX = index
.wait:
        call    ps2_rx_available
        jc      .wait                   ; tampon vide - attend
        mov     bp, PS2_RX_HEAD_OFF
        mov     al, [bp]                ; AL = tete actuelle
        mov     bl, al
        mov     bp, PS2_RX_BUF_OFF
        add     bp, bx
        mov     al, [bp]                ; AL = octet a retourner
        inc     bl
        and     bl, 0Fh
        mov     bp, PS2_RX_HEAD_OFF
        mov     [bp], bl
        pop     bx
        pop     bp
        clc                             ; succes TOUJOURS (voir en-tete)
        ret

; ps2_rx_available: CF=0 si au moins un scan code est disponible, CF=1
; si le tampon est vide - NE BLOQUE JAMAIS (contrairement a
; ps2_read_byte). Utilisee par dump_memory_action pour verifier Echap
; SANS bloquer avant chaque ligne (remplace l'ancien "IN AL,PORTB /
; TEST AL,PS2_CLOCK", le Port B n'etant plus le clavier direct depuis
; la version Arduino). Detruit AX. Jamais BX/CX/DX/SI/DI/ES/BP.
ps2_rx_available:
        push    bp
        mov     bp, PS2_RX_HEAD_OFF
        mov     al, [bp]
        mov     bp, PS2_RX_TAIL_OFF
        cmp     al, [bp]
        pop     bp
        je      .empty
        clc
        ret
.empty:
        stc
        ret

; ps2_key_available: CF=0 si une touche attend, clavier PS/2 (ps2_rx_available)
; OU terminal UART (uart_rx_available) - NE BLOQUE JAMAIS. Sert aux
; verifications non bloquantes (Echap pendant un dump, INT 16h AH=01h);
; ps2_read_byte, lui, n'attend que le tampon PS/2 (ps2_rx_available).
; Detruit AX. Jamais BX/CX/DX/SI/DI/ES/BP.
ps2_key_available:
        call    ps2_rx_available
        jnc     .dispo
        jmp     uart_rx_available       ; CF = resultat du second tampon
.dispo:
        ret

; ============================================================
; ps2_keymap / ps2_scancode_to_char
; Table (scan code Set 2, caractere ASCII) pour les touches utiles
; au menu/a la saisie hexadecimale: chiffres 0-9, lettres A-F (pour
; les valeurs hexa), Q (quitter l'editeur RAM), R (enregistrer+
; executer, edit_run_action), Entree (13), Retour arriere (8), Echap
; (27). Terminee par 0,0 (aucun scan code valide n'est 0). Les
; touches non listees ici (fleches - voir ps2_ext_keymap -, F1-F12,
; pave numerique, autres lettres, etc.) sont simplement ignorees par
; ps2_get_char - c'est CETTE liste blanche, pas seulement le code
; appelant, qu'il faut mettre a jour pour qu'une NOUVELLE touche soit
; un jour reconnue (bug trouve sur le materiel reel: 'R' verifiee
; partout dans edit_run_action ne faisait jamais rien, puisqu'elle
; etait absente d'ICI et donc silencieusement avalee par
; ps2_get_char avant meme d'atteindre ce code).
;
; Majuscule uniquement (pas de distinction Maj/minuscule: l'etat des
; touches Shift n'est pas suivi) - edit_ram_action/edit_run_action
; verifient donc 'Q'/'R' ET 'q'/'r' par prudence, mais seules 'Q'/'R'
; peuvent effectivement etre recues.
; ============================================================
ps2_keymap:
        db      016h, '1'
        db      01Eh, '2'
        db      026h, '3'
        db      025h, '4'
        db      02Eh, '5'
        db      036h, '6'
        db      03Dh, '7'
        db      03Eh, '8'
        db      046h, '9'
        db      045h, '0'
        db      01Ch, 'A'
        db      032h, 'B'
        db      021h, 'C'
        db      023h, 'D'
        db      024h, 'E'
        db      02Bh, 'F'
        db      015h, 'Q'       ; quitte l'editeur RAM (edit_ram_action)
        db      02Dh, 'R'       ; enregistre+execute (edit_run_action)
        db      05Ah, 13        ; Entree
        db      066h, 8         ; Retour arriere
        db      076h, 27        ; Echap
        db      0, 0            ; fin de table

; ============================================================
; ps2_ext_keymap / ps2_extended_to_char
; Meme principe que ps2_keymap/ps2_scancode_to_char, mais pour les
; scan codes ETENDUS (prefixe 0E0h - voir ps2_get_char): fleches
; uniquement pour ce projet.
; ============================================================
ps2_ext_keymap:
        db      075h, PS2_KEY_UP
        db      072h, PS2_KEY_DOWN
        db      06Bh, PS2_KEY_LEFT
        db      074h, PS2_KEY_RIGHT
        db      0, 0            ; fin de table

; ============================================================
; ps2_table_lookup
; Recherche AL dans une table (code,valeur) pointee par BX, terminee
; par 0,0 - factorise la logique commune a ps2_scancode_to_char et
; ps2_extended_to_char.
; Entree: AL = code a chercher, BX = adresse de la table.
; Sortie: AL = valeur trouvee, CF=0 si trouve, CF=1 sinon.
; ============================================================
ps2_table_lookup:
        push    dx
        mov     dl, al
.scan:
        mov     al, [bx]
        cmp     al, 0
        je      .not_found
        cmp     al, dl
        je      .found
        add     bx, 2
        jmp     .scan
.found:
        mov     al, [bx+1]
        clc
        jmp     .done
.not_found:
        stc
.done:
        pop     dx
        ret

; Entree: AL = scan code brut (make code) a chercher dans ps2_keymap.
; Sortie: AL = caractere ASCII correspondant, CF=0 si trouve, CF=1
; sinon (touche non geree par ce projet - AL indefini).
ps2_scancode_to_char:
        push    bx
        mov     bx, ps2_keymap
        call    ps2_table_lookup
        pop     bx
        ret

; Entree: AL = scan code brut ETENDU (apres le prefixe 0E0h) a
; chercher dans ps2_ext_keymap.
; Sortie: AL = code PS2_KEY_* correspondant, CF=0 si trouve, CF=1
; sinon (touche etendue non geree par ce projet - AL indefini).
ps2_extended_to_char:
        push    bx
        mov     bx, ps2_ext_keymap
        call    ps2_table_lookup
        pop     bx
        ret

; ============================================================
; ps2_get_char
; Bloque jusqu'a l'appui d'une touche RECONNUE (voir ps2_keymap pour
; les touches normales, ps2_ext_keymap pour les fleches) - ignore les
; relachements (prefixe 0F0h) en consommant correctement leur
; sequence, ainsi que les touches non reconnues (normales ou
; etendues).
; TERMINAL UART: les octets recus de l'Arduino (irq1_arduino_handler,
; etiquette UART) sont eux aussi consultes - meme resultat que la touche
; PS/2 equivalente (voir uart_get_key), BH = 0.
; Sortie: AL = caractere ASCII de la touche pressee, OU PS2_KEY_UP/
;         DOWN/LEFT/RIGHT pour une fleche. BH = scan code PS/2 Set 2
;         BRUT de cette touche (le second octet, pour une touche
;         etendue) - ajoute pour int16h_handler (solution-01.asm),
;         qui l'expose en AH ("esprit BIOS", voir sa doc). Aucun
;         appelant existant n'utilisait BH (deja "detruit" avant ce
;         changement) - ps2_scancode_to_char/ps2_extended_to_char
;         preservent BX (push/pop), donc le sauvegarder AVANT de les
;         appeler suffit.
; Detruit: AX, BX, CX, DX. Jamais SI/DI/ES/BP.
; ============================================================
ps2_get_char:
.loop:
        call    ps2_rx_available        ; clavier PS/2 d'abord...
        jnc     .from_ps2
        call    uart_rx_available       ; ...sinon le terminal UART (voir uart_get_key)
        jc      .loop                   ; rien nulle part: attend
        call    uart_get_key
        jc      .loop                   ; octet ignore (non reconnu): reboucle
        xor     bh, bh                  ; pas de scan code brut pour une touche UART
        ret
.from_ps2:
        call    ps2_read_byte
        cmp     al, 0E0h
        je      .got_e0
        cmp     al, 0F0h
        je      .got_f0
        ; --- scan code de pression (make code) normal ---
        mov     bh, al          ; BH = scan code brut (survit a l'appel
                                 ; suivant, qui preserve BX)
        call    ps2_scancode_to_char
        jc      .loop           ; touche non geree - ignore, reboucle
        ret                     ; AL = caractere reconnu, BH = scan code brut
.got_e0:
        ; --- touche etendue: le prochain octet est soit F0 (relachement
        ; etendu, encore a consommer) soit le scan code de la pression
        ; etendue elle-meme (fleche reconnue, ou ignoree sinon) ---
        call    ps2_read_byte
        cmp     al, 0F0h
        je      .got_e0_f0
        mov     bh, al          ; BH = scan code brut (etendu)
        call    ps2_extended_to_char
        jc      .loop           ; touche etendue non geree - ignore, reboucle
        ret                     ; AL = PS2_KEY_UP/DOWN/LEFT/RIGHT, BH = scan code brut
.got_e0_f0:
        call    ps2_read_byte   ; consomme le scan code du relachement etendu
        jmp     .loop
.got_f0:
        call    ps2_read_byte   ; consomme le scan code du relachement
        jmp     .loop

; ============================================================
; uart_get_key / uart_wait_byte
; Traduit un octet recu du terminal UART en le MEME resultat que
; ps2_get_char donnerait pour la touche PS/2 correspondante: memes
; caracteres (liste blanche = les valeurs de ps2_keymap: chiffres,
; A-F/Q/R, Entree, Retour arriere, Echap) - minuscules mises en
; majuscules, DEL (7Fh) traite comme Retour arriere; tout le reste
; (dont LF, pour un terminal qui envoie CR+LF) est ignore.
; FLECHES: sequences ANSI ESC [ A/B/C/D (ou ESC O A/B/C/D) -> PS2_KEY_UP/
; DOWN/RIGHT/LEFT; les autres sequences (ESC [ ... ~, etc.) sont
; consommees en entier et ignorees. Un ESC seul (aucun octet dans les
; ~50 ms qui suivent, UART_ESC_TIMEOUT) est la touche Echap.
;
; uart_get_key: appelee quand uart_rx_available a dit CF=0.
;   Sortie: CF=0, AL = caractere ou PS2_KEY_*; CF=1 si octet(s) ignore(s).
; uart_wait_byte: attend un octet UART au plus UART_ESC_TIMEOUT tours.
;   Sortie: CF=0, AL = octet; CF=1 si delai depasse.
; Detruisent AX (et BX/CX preserves ici). Jamais SI/DI/ES/BP.
; ============================================================
UART_ESC_TIMEOUT        equ     2000    ; ~50 ms a 4,77 MHz (~25 us par tour)

uart_wait_byte:
        push    cx
        mov     cx, UART_ESC_TIMEOUT
.w:
        call    uart_rx_available
        jnc     .got
        loop    .w
        pop     cx
        stc
        ret
.got:
        call    uart_rx_byte
        pop     cx
        clc
        ret

uart_get_key:
        call    uart_rx_byte
        cmp     al, 1Bh
        je      .esc
        cmp     al, 7Fh
        jne     .lower
        mov     al, 8                   ; DEL -> Retour arriere
.lower:
        cmp     al, 'a'
        jb      .lookup
        cmp     al, 'z'
        ja      .lookup
        sub     al, 20h                 ; minuscule -> majuscule
.lookup:
        push    bx
        mov     bx, ps2_keymap          ; liste blanche = valeurs de ps2_keymap
.scan:
        cmp     byte [bx], 0
        je      .not_listed
        cmp     [bx+1], al
        je      .listed
        add     bx, 2
        jmp     .scan
.listed:
        pop     bx
        clc
        ret
.not_listed:
        pop     bx
        stc
        ret

.esc:
        call    uart_wait_byte
        jc      .esc_alone
        cmp     al, '['
        je      .csi
        cmp     al, 'O'
        je      .ss3
        stc                             ; ESC + autre octet (Alt+touche...): ignore
        ret
.esc_alone:
        mov     al, 27                  ; Echap
        clc
        ret
.csi:
        call    uart_wait_byte          ; parametres/intermediaires: consommes
        jc      .ignore                 ; jusqu'a l'octet final (40h-7Eh)
        cmp     al, 40h
        jb      .csi
        jmp     .final
.ss3:
        call    uart_wait_byte
        jc      .ignore
.final:
        cmp     al, 'A'
        je      .k_up
        cmp     al, 'B'
        je      .k_down
        cmp     al, 'C'
        je      .k_right
        cmp     al, 'D'
        je      .k_left
.ignore:
        stc
        ret
.k_up:
        mov     al, PS2_KEY_UP
        clc
        ret
.k_down:
        mov     al, PS2_KEY_DOWN
        clc
        ret
.k_right:
        mov     al, PS2_KEY_RIGHT
        clc
        ret
.k_left:
        mov     al, PS2_KEY_LEFT
        clc
        ret

; ============================================================
; ps2_hex_digit_value
; Entree: AL = caractere ASCII. Sortie: AL = valeur 0-15, CF=0 si
; '0'-'9' ou 'A'-'F' (majuscule uniquement - ps2_keymap n'emet que
; des majuscules), CF=1 sinon (AL indefini).
; ============================================================
ps2_hex_digit_value:
        cmp     al, '0'
        jb      .invalid
        cmp     al, '9'
        jbe     .digit
        cmp     al, 'A'
        jb      .invalid
        cmp     al, 'F'
        ja      .invalid
        sub     al, 'A'
        add     al, 10
        clc
        ret
.digit:
        sub     al, '0'
        clc
        ret
.invalid:
        stc
        ret

; ============================================================
; ps2_read_hex_editable
; Lit CL chiffres hexadecimaux au clavier (0-9, A-F), avec echo sur
; l'UART ET le LCD parallele, et gestion du RETOUR ARRIERE: efface
; visuellement le dernier chiffre saisi (UART: BS/espace/BS: LCD:
; repositionne la case, ecrit un espace, repositionne de nouveau) et
; recule d'un chiffre. Termine des que CL chiffres valides sont
; accumules (largeur fixe - contrairement a ps2_edit_byte_value, qui
; termine sur Entree).
;
; IMPORTANT: l'appelant doit avoir positionne le curseur LCD (DDRAM)
; au DEBUT du champ juste avant l'appel (ex: via lcd_show), ET fournir
; cette meme adresse DDRAM dans AH (SANS le bit de commande 80h - ex:
; LCD_LINE1 & 07Fh, plus la longueur d'un prefixe deja affiche sur
; cette ligne), pour que le retour arriere puisse y repositionner
; precisement le curseur.
;
; Entree: CL = nombre de chiffres a lire (2 ou 4). AH = adresse DDRAM
;         de depart du champ (0-127, sans le bit de commande).
; Sortie: BX = valeur entree (chiffres accumules, MSB en premier).
; Detruit: AX, CX, DX (BX est la sortie). Jamais SI/DI/ES/BP.
;
; IMPORTANT: l'accumulateur interne vit dans SI, PAS BX - depuis que
; ps2_get_char expose le scan code brut en BH (voir son en-tete),
; BH est ecrase a CHAQUE appel, ce qui corromprait un accumulateur
; multi-chiffres loge dans BX. SI, lui, n'est jamais touche par
; ps2_get_char. Bug confirme sur le materiel reel avant ce correctif:
; saisir "0000" donnait "5000" (045h, le scan code Set 2 de '0',
; ecrasait BH -> BX=4500h apres le 1er chiffre -> shl bx,4 = 45000h,
; tronque a 16 bits = 5000h - voir Directives.md).
; ============================================================
ps2_read_hex_editable:
        push    si              ; SI = accumulateur interne - restaure la
                                 ; valeur d'origine de l'appelant avant le
                                 ; retour (BX reste la SORTIE documentee)
        xor     si, si
        mov     ch, cl          ; CH = nombre TOTAL de chiffres a lire (fixe)
        xor     dh, dh          ; DH = nombre de chiffres saisis jusqu'ici
.next_key:
        call    ps2_get_char
        cmp     al, 8           ; retour arriere ?
        je      .backspace
        call    ps2_hex_digit_value
        jc      .next_key       ; touche non geree (Entree, Echap...) - ignore
        cmp     dh, ch
        jae     .next_key       ; deja le nombre de chiffres voulu - ignore
        mov     dl, al          ; DL = valeur de ce chiffre (0-15), survit
                                 ; aux 2 echos ci-dessous
        mov     cl, 4
        shl     si, cl
        push    dx              ; DH(compteur)/DL(valeur) sauvegardes ensemble
        mov     dh, 0           ; DH=0 temporairement (les 4 bits bas de SI
        add     si, dx          ; sont a 0 apres le decalage - addition = OR)
        pop     dx              ; restaure DH(compteur)/DL(valeur)
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    i2c_lcd_tx_hex_nibble
        inc     dh
        cmp     dh, ch
        jb      .next_key
        mov     bx, si          ; BX = valeur finale (sortie documentee)
        pop     si              ; restaure le SI de l'appelant
        ret
.backspace:
        cmp     dh, 0
        je      .next_key       ; rien a effacer - ignore
        dec     dh
        mov     cl, 4           ; efface le dernier chiffre de la valeur
        shr     si, cl          ; accumulee (division par 16)
        mov     al, 8           ; efface visuellement sur l'UART (backspace,
        call    uart_tx_byte    ; espace, backspace)
        mov     al, ' '
        call    uart_tx_byte
        mov     al, 8
        call    uart_tx_byte
        mov     al, ah          ; --- efface visuellement sur le LCD:
        add     al, dh          ; repositionne sur la case effacee, ecrit
        or      al, 80h         ; un espace, repositionne de nouveau (le
        call    i2c_lcd_command     ; prochain chiffre tape doit ecraser cette
        mov     al, ' '         ; meme case, pas la suivante) ---
        call    i2c_lcd_data
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    i2c_lcd_command
        jmp     .next_key

; ============================================================
; ps2_edit_byte_value
; Compose une nouvelle valeur d'octet (0-2 chiffres hexa) au clavier,
; avec echo UART+LCD et retour arriere (meme mecanique que
; ps2_read_hex_editable), mais attend la touche ENTREE pour terminer
; plutot que de completer automatiquement a un nombre fixe de
; chiffres - permet de ne taper qu'1 chiffre (ex: 'F'+Entree = 0Fh).
;
; Le PREMIER caractere doit etre fourni par l'appelant en AL (deja lu
; via ps2_get_char - evite de le relire/perdre si l'appelant a du le
; lire pour decider d'appeler cette routine, voir edit_ram_action):
; s'il n'est ni Entree, ni Retour arriere, ni un chiffre hexa, il est
; simplement ignore (comme les touches suivantes) et la lecture
; continue normalement.
;
; Entree: AL = premier caractere deja lu par l'appelant. AH = adresse
;         DDRAM de la cellule (0-127, sans le bit de commande).
; Sortie: BX = valeur composee. CF=0 si au moins un chiffre a ete
;         tape (valeur a ecrire), CF=1 si Entree a ete pressee sans
;         aucune saisie (BX indefini - rien a ecrire).
; Detruit: AX, CX, DX (BX est la sortie). Jamais SI/DI/ES/BP.
;
; IMPORTANT: l'accumulateur interne vit dans SI, PAS BX - meme raison
; et meme correctif que ps2_read_hex_editable (voir son en-tete):
; ps2_get_char ecrase BH (scan code brut) a chaque appel, ce qui
; corromprait un accumulateur loge dans BX.
; ============================================================
ps2_edit_byte_value:
        push    si              ; SI = accumulateur interne - restaure la
                                 ; valeur d'origine de l'appelant avant
                                 ; chaque retour (BX reste la SORTIE
                                 ; documentee)
        xor     si, si
        xor     dh, dh          ; DH = nombre de chiffres saisis (0-2)
        jmp     .have_key       ; traite d'abord le caractere deja lu par
                                 ; l'appelant, avant de lire les suivants
.next_key:
        call    ps2_get_char
.have_key:
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
        mov     dh, 0           ; DH=0 temporairement (les 4 bits bas de SI
        add     si, dx          ; sont a 0 apres le decalage - addition = OR)
        pop     dx              ; restaure DH(compteur)/DL(valeur)
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    i2c_lcd_tx_hex_nibble
        inc     dh
        jmp     .next_key
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
        pop     si              ; restaure le SI de l'appelant
        clc
        ret
.empty:
        pop     si              ; restaure le SI de l'appelant (BX indefini,
                                 ; comme documente - rien a ecrire)
        stc
        ret

%endif ; PS2_ASM
