; ============================================================
; isr.asm - irq1_arduino_handler
; Gestionnaire REEL de IR1 (INT 09h): INTR du 8255 (PC3, mode 2) se
; declenche a chaque octet que l'Arduino a pousse sur le Port A. Lit
; d'abord le mot d'etat (Port C): PC5 (IBF) confirme qu'un octet est
; bien la (sinon interruption parasite: rien a lire), PC0 (etiquette
; posee par l'Arduino AVANT son impulsion STB#) dit d'ou vient l'octet -
; 0 = scan code clavier (ps2_rx_push, lib/ps2.asm), 1 = octet recu par
; l'UART materiel (uart_rx_push, lib/uart.asm); PC1 = 1 (prioritaire) = octet
; de REPONSE a une commande du pont (bridge_rx_push, lib/bridge.asm). Lit ensuite le Port A
; (ce qui efface IBF et INTR - plus de PB_RX_ACK: c'est la poignee de
; main materielle du 8255), envoie l'EOI NON SPECIFIQUE (obligatoire en
; mode EOI MANUEL, voir init_8259) et fait IRET.
;
; REDEMARRAGE A CHAUD: l'octet UART WARM_RESET_KEY (Ctrl-\, 1Ch) n'est PAS range dans le tampon: l'ISR envoie l'EOI
; puis saute au vecteur de reset de la ROM (0C000h:0000h = start:), comme un reset materiel - cela fonctionne
; quoi qu'execute le 8088 (menu, BASIC, DOS, programme DOS bloque...) et ramene au menu principal sans toucher
; au bouton RESET. Les octets du clavier PS/2 ne sont pas concernes.
;
; INDEPENDANTE DE LA PILE ET DE DS du programme interrompu (un DOS, par exemple, a sa
; propre pile et ses propres segments): l'ISR sauve DS, le charge avec VAR_SEG, et les
; routines *_rx_push adressent les tampons par DS.
;
; Aucune ecriture de port autre que l'EOI ici: cette ISR ne touche jamais
; au Port B ni au Port A en ecriture, donc ne peut pas perturber un
; arduino_send interrompu (voir lib/common.asm). Seuls AX et DS sont modifies
; (et restaures).
;
; Inclus par solution-01.asm et tests/bios_test.asm - garde requise.
; ============================================================
%ifndef ISR_ASM
%define ISR_ASM

WARM_RESET_KEY equ    1Ch                     ; Ctrl-\ envoye par le terminal

irq1_arduino_handler:
        push    ax
        push    ds
        mov     ax, VAR_SEG
        mov     ds, ax                  ; les tampons vivent dans VAR_SEG

        in      al, PORTC               ; mot d'etat + etiquette (PC0/PC1)
        test    al, PC_IBF
        jz      .fin                    ; rien a lire: interruption parasite
        test    al, PC_TAG_REPLY
        jz      .notreply
        cmp     byte [BRIDGE_EXPECT_OFF], 0     ; PC1 = 1 ne compte que pendant une commande
        jne     .reply                  ; (rtc_get, fs_*): hors de ces intervalles, une PC1 non
                                        ; cablee/flottante ne perturbe pas le clavier ni l'UART
.notreply:
        test    al, PC_TAG_UART
        jnz     .uart
        in      al, PORTA               ; scan code clavier brut
        call    ps2_rx_push
        jmp     .fin
.uart:
        in      al, PORTA               ; octet recu par l'UART materiel
        cmp     al, WARM_RESET_KEY
        je      .warm
        call    uart_rx_push
        jmp     .fin
.warm:
        mov     al, 20h                 ; EOI (start: reinitialise de toute facon le 8259)
        out     PIC_CMD, al
        jmp     0C000h:0000h            ; le meme saut que le vecteur de reset (FFFF0h)
.reply:
        in      al, PORTA               ; reponse du pont (horloge RTC, disque...)
        call    bridge_rx_push
.fin:
        mov     al, 20h                 ; OCW2: EOI non specifique
        out     PIC_CMD, al

        pop     ds
        pop     ax
        iret

%endif ; ISR_ASM
