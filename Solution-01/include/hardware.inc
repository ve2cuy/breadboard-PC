; ============================================================
; hardware.inc
; Constantes materielles partagees (8255 PIO + adressage RAM des
; variables partagees). Inclus par solution-01.asm ET par chaque
; module de ./lib qui en a besoin (assemblage standalone via le
; Makefile) - d'ou la garde ci-dessous.
;
; IMPORTANT: tous les %include de ce projet sont ecrits comme des
; chemins relatifs a la RACINE du dossier Solution-01 (ex:
; "include/hardware.inc", "lib/common.asm") - PAS relatifs au
; fichier qui fait le %include. NASM resout les %include par
; rapport au repertoire courant (cwd) au moment de l'assemblage,
; jamais par rapport a l'emplacement du fichier. Le Makefile lance
; donc TOUJOURS nasm depuis la racine de Solution-01, meme pour
; assembler un module de ./lib tout seul.
; ============================================================
%ifndef HARDWARE_INC
%define HARDWARE_INC

;*****************
; CONST. PIO 1   *
;*****************
PORTA       EQU    10000000B   ;8255 ACTIVE PAR A7
PORTB       EQU    10000001B
PORTC       EQU    10000010B
PIO         EQU    10000011B

; MASQUE_PIO: mot de mode du 8255 - MODE 2 (bus bidirectionnel) sur le
; Port A depuis la version Arduino "18 broches" (voir Directives.md). Le
; clavier PS/2, l'UART (RX/TX) ET le LCD I2C sont geres par un Arduino
; externe (decodage PS/2, UART materiel reel independant de l'horloge du
; 8088, bus I2C materiel vers le LCD). Le 8088 ne parle a l'Arduino que
; par ce 8255:
;   Port A = BUS BIDIRECTIONNEL de 8 bits (mode 2), avec poignee de main
;            MATERIELLE sur le Port C (PC3-PC7, voir ci-dessous):
;              8088 -> Arduino: OUT PORTA (OBF# passe a 0); l'Arduino
;                               abaisse ACK# pour lire l'octet (le 8255
;                               ne pilote le bus QUE pendant ACK# bas -
;                               aucun conflit possible avec l'Arduino).
;              Arduino -> 8088: l'Arduino pose l'octet et pulse STB#;
;                               INTR (PC3, cable sur IR1 du 8259)
;                               declenche irq1_arduino_handler, qui lit
;                               le Port A (efface IBF/INTR).
;   Port B = SORTIE (mode 0): CANAL de l'octet sortant (PB_CHAN_*), pose
;            AVANT chaque ecriture du Port A - l'Arduino le lit quand il
;            voit OBF# bas. Bits 2-7 libres.
;   Port C = poignee de main du mode 2 (PC3 INTR, PC4 STB#, PC5 IBF,
;            PC6 ACK#, PC7 OBF#) + PC0-PC2 en ENTREE: PC0 = "etiquette"
;            de l'octet entrant (0 = scan code clavier, 1 = octet UART
;            recu), posee par l'Arduino AVANT le pulse STB#. PC1/PC2
;            libres.
; Mot de mode = 11000001b: D7=1 (mode), D6-D5=11 (groupe A mode 2),
; D4/D3 ignores en mode 2, D2=0 (groupe B mode 0), D1=0 (Port B sortie),
; D0=1 (PC0-PC2 entrees).
MASQUE_PIO  EQU    11000001B   ;PORT A MODE 2, PORT B SORTIE, PC0-PC2 ENTREES

; --- mots "bit set/reset" du Port C (mode 2: INTE1=PC6, INTE2=PC4). Un
; --- mot de mode remet les deux a 0; seul INTE2 (interruption sur octet
; --- RECU de l'Arduino) est active - INTE1 (fin d'emission) reste a 0:
; --- le 8088 interroge OBF# lui-meme (arduino_send). ---
PIO_INTE2_SET    EQU   00001001B   ;PC4 = 1 (INTE2: INTR sur octet recu)
PIO_INTE1_RESET  EQU   00001100B   ;PC6 = 0 (INTE1: pas d'INTR a l'emission)

; --- bits du mot d'etat lu sur le Port C en mode 2 ---
PC_OBF_N      equ     10000000b     ; PC7: 1 = tampon de sortie LIBRE (l'Arduino
                                     ; a lu le dernier octet), 0 = octet en attente
PC_IBF        equ     00100000b     ; PC5: 1 = octet de l'Arduino recu, pas encore lu
PC_TAG_UART   equ     00000001b     ; PC0 (entree, pilotee par l'Arduino): 1 = l'octet
                                     ; du Port A est un octet UART recu, 0 = scan code
PC_TAG_REPLY  equ     00000010b     ; PC1 (entree, pilotee par le pont): 1 = l'octet du
                                     ; Port A est un octet de REPONSE a une commande du
                                     ; canal PB_CHAN_CMD (horloge RTC...). PC1 doit etre
                                     ; reliee a la sortie TAG1 du pont STM32 (tiree a 0
                                     ; par 10 kohm). Elle n'est prise en compte que
                                     ; PENDANT une commande (BRIDGE_EXPECT_OFF): non
                                     ; cablee/flottante, elle ne perturbe donc pas le
                                     ; clavier ni l'UART hors de ces courts intervalles.

; --- Port B: canal de l'octet ECRIT sur le Port A (voir arduino_send) ---
PB_CHAN_UART      equ 0             ; octet a emettre par l'UART materiel
PB_CHAN_LCD_CMD   equ 1             ; commande HD44780 (RS=0) a relayer au LCD I2C
PB_CHAN_LCD_DATA  equ 2             ; donnee HD44780 (RS=1, caractere)
PB_CHAN_CMD       equ 3             ; commande pour le pont (RTC...): voir lib/bridge.asm

; --- etat de l'Arduino vu par arduino_send (ARD_TX_STATE_OFF) ---
ARD_UNKNOWN   equ     0             ; jamais vu consommer un octet (apres reset)
ARD_ALIVE     equ     1             ; a deja consomme au moins un octet
ARD_ABSENT    equ     2             ; delai depasse: on n'attend plus (voir
                                     ; arduino_send)

;*****************
; CONST. 8259   *
;*****************
; CS# du 8259 decode via IO.A6./A7 (NAND 3 entrees) - memes ports que
; le PC/XT reel (20h/21h). A0 du 8259 (commande/ICW1/OCW2/OCW3 vs
; donnees/ICW2/ICW4/OCW1=IMR) correspond a l'ecart d'un octet entre
; PIC_CMD et PIC_DATA, comme PORTA/PORTB/PORTC/PIO ci-dessus pour le
; 8255 (voir Directives.md pour la discussion du decodage).
PIC_CMD     EQU    00100000B   ;8259 - registre de commande (ICW1/OCW2/OCW3)
PIC_DATA    EQU    00100001B   ;8259 - registre de donnees (ICW2/ICW4/OCW1=IMR)

; --- copie fantome du port A + compteurs de progression du test RAM
; --- + etat de l'editeur RAM + tampon d'edition (edit_ram_action,
; --- solution-01.asm) + etat de dump_memory_action + curseurs
; --- "esprit BIOS": vivent dans une zone de 2 Ko reservee a la fin du
; --- segment VAR_SEG (agrandie de 1 a 2 Ko pour loger le tampon
; --- d'edition de 1024 octets - voir test_ram, solution-01.asm, pour
; --- le nombre d'octets reellement testes en consequence). ---
VAR_SEG             equ     1000h

; --- tampon de travail de edit_ram_action (1024 octets max) - toute
; --- l'edition se fait ICI, jamais directement en RAM reelle: Echap
; --- abandonne ce tampon (rien n'est ecrit), Q/q le recopie dans la
; --- RAM reelle (voir edit_ram_load_buffer/edit_ram_commit_buffer).
; --- Occupe a lui seul la moitie de la zone reservee. ---
EDIT_BUFFER_OFF     equ     0F800h  ; 1024 octets: 0F800h-0FBFFh

PORTA_SHADOW_OFF    equ     0FC00h
BLOCK_COUNTER_OFF   equ     0FC01h  ; numero du bloc courant (1-127)
DEFECT_COUNTER_OFF  equ     0FC02h  ; nombre de blocs ayant eu >=1 defaut

; --- etat de edit_ram_action: adresse/taille de la plage saisie, et
; --- position courante dans le tampon (curseur logique + fenetre
; --- visible, pour le defilement quand la plage depasse les 4
; --- lignes du LCD) ---
EDIT_BASE_SEG_OFF   equ     0FCF0h  ; segment de depart de la plage saisie par edit_ram_action (mot; le
                                     ; slot libere par l'ancien BIOS_DATESTR - voir Directives.md)
EDIT_BASE_OFF       equ     0FC03h  ; offset de depart de la plage (mot)
EDIT_SIZE_OFF       equ     0FC05h  ; taille de la plage en octets, 1-400h (mot)
EDIT_CURSOR_OFF     equ     0FC07h  ; position lineaire du curseur dans le
                                     ; tampon, 0 a (taille-1) (mot)
EDIT_WINDOW_ROW_OFF equ     0FC09h  ; ligne LOGIQUE (0-based, pas de deplacement
                                     ; en colonnes) affichee en haut de l'ecran (mot)

; --- adresses saisies par dump_memory_action (solution-01.asm), le
; --- temps de calculer les adresses physiques de depart/fin - voir
; --- son en-tete ---
DUMP_START_SEG_OFF   equ    0FC0Bh  ; segment de depart saisi (mot)
DUMP_START_OFF_OFF   equ    0FC0Dh  ; offset de depart saisi (mot)
DUMP_END_SEG_OFF     equ    0FC0Fh  ; segment de fin saisi (mot)
DUMP_END_OFF_OFF     equ    0FC11h  ; offset de fin saisi (mot)
; --- adresse physique de fin (32 bits), memorisee une fois calculee -
; --- comparee a l'adresse physique COURANTE a chaque ligne plutot que
; --- de precalculer un nombre total de lignes (qui pourrait deborder
; --- 16 bits: exactement 65536 lignes pour la plage maximale de ce
; --- materiel, 0000:0000 a F000:FFFF - voir dump_memory_action) ---
DUMP_END_PHYS_LO_OFF equ    0FC13h  ; poids faible (mot)
DUMP_END_PHYS_HI_OFF equ    0FC15h  ; poids fort (mot)

; --- curseurs logiques de int10h_handler (solution-01.asm), AH=02h/
; --- 09h "esprit BIOS" - UN JEU PAR DEVICE (LCD parallele / LCD I2C)
; --- depuis l'ajout des macros gotoxy/print (voir
; --- include/lcd_macros.inc et l'en-tete de int10h_handler). UART
; --- n'a pas de curseur (flux serie, AH=02h y est un no-op). ---
BIOS_CURSOR_LCD_ROW_OFF    equ 0FC17h  ; LCD parallele: ligne courante (0-3)
BIOS_CURSOR_LCD_COL_OFF    equ 0FC18h  ; LCD parallele: colonne courante (0-19)
BIOS_CURSOR_LCDI2C_ROW_OFF equ 0FC19h  ; LCD I2C: ligne courante (0-3)
BIOS_CURSOR_LCDI2C_COL_OFF equ 0FC1Ah  ; LCD I2C: colonne courante (0-19)

; --- registres GENERAUX persistants d'edit_run_action (solution-01.asm):
; --- restaures juste AVANT chaque "call 1000h:0000h" et resauvegardes
; --- juste APRES son retour (RETF) - sans cette persistance, AX/BX/CX/
; --- DX/SI/DI seraient ecrases entre deux appuis sur 'r' par le code de
; --- menu/clavier qui s'execute entre-temps (edit_ram_draw_grid,
; --- ps2_get_char, etc.), rendant impossible tout test CUMULATIF (ex:
; --- "add ax,2" repete, cense incrementer AX a chaque execution).
; --- Remis a 0 UNE SEULE FOIS, a l'entree dans edit_run_action (nouvelle
; --- session d'edition) - voir edit_run_action/edit_run_execute_and_show. ---
RUN_REG_AX_OFF      equ 0FC1Bh  ; (mot)
RUN_REG_BX_OFF      equ 0FC1Dh  ; (mot)
RUN_REG_CX_OFF      equ 0FC1Fh  ; (mot)
RUN_REG_DX_OFF      equ 0FC21h  ; (mot)
RUN_REG_SI_OFF      equ 0FC23h  ; (mot)
RUN_REG_DI_OFF      equ 0FC25h  ; (mot)

; --- fenetre visible de ivt_dump_action (solution-01.asm): numero du
; --- PREMIER vecteur affiche sur la ligne 1 du LCD I2C, parmi les
; --- IVT_DUMP_COUNT (40) premiers vecteurs affiches (0-36, voir
; --- IVT_WINDOW_MAX) - memes principe que EDIT_WINDOW_ROW_OFF, mais
; --- un seul vecteur par ligne (pas de colonnes). Remise a 0 a chaque
; --- entree dans l'action. ---
IVT_WINDOW_OFF      equ 0FC27h  ; (mot)

; --- etat de l'Arduino vu par arduino_send (lib/common.asm): ARD_UNKNOWN/
; --- ARD_ALIVE/ARD_ABSENT ci-dessus. Remis a 0 par l'effacement complet du
; --- segment au demarrage (voir start:). ---
ARD_TX_STATE_OFF    equ 0FC29h  ; (octet)

; --- tampons circulaires (16 octets, tete=queue -> vide, 15 octets
; --- utiles) remplis de facon ASYNCHRONE par
; --- irq1_arduino_handler (solution-01.asm) - lus par ps2_rx_pop
; --- (lib/ps2.asm, remplace l'ancien ps2_read_byte bit-bangue) et
; --- uart_rx_pop (lib/uart.asm, NOUVELLE capacite - rien ne la
; --- consomme encore dans le menu). Producteur (ISR)/consommateur
; --- (boucle principale) uniques chacun - sans danger sans desactiver
; --- les interruptions (indices tete/queue d'un seul octet, lus/ecrits
; --- de façon atomique par rapport a une IRQ). ---
PS2_RX_HEAD_OFF     equ 0FC2Ah  ; (octet)
PS2_RX_TAIL_OFF     equ 0FC2Bh  ; (octet)
PS2_RX_BUF_OFF      equ 0FC2Ch  ; (16 octets: 0FC2Ch-0FC3Bh)

UART_RX_HEAD_OFF    equ 0FC3Ch  ; (octet)
UART_RX_TAIL_OFF    equ 0FC3Dh  ; (octet)
UART_RX_BUF_OFF     equ 0FD00h  ; (256 octets: 0FD00h-0FDFFh, 255 utiles; indices d'un octet:
                                ; l'enroulement est celui de l'octet. Ex-tampon de 16 octets: un collage
                                ; de code BASIC le saturait pendant la tokenisation d'une ligne)

; --- vue TERMINAL de l'editeur RAM (edit_ram_draw_terminal, solution-01.asm):
; --- pointeurs vers le titre et la ligne d'aide, fixes par chaque action
; --- d'edition (edit_ram_action/edit_run_action) - partagent la meme grille.
EDIT_TERM_TITLE_OFF equ 0FC4Eh  ; (mot)
EDIT_TERM_HELP_OFF  equ 0FC50h  ; (mot)

; --- tampon circulaire (64 octets, meme principe que ci-dessus) des REPONSES du
; --- pont aux commandes du canal PB_CHAN_CMD: rempli par irq1_arduino_handler
; --- (etiquette PC1 = 1), lu par bridge_rx_get_t (lib/bridge.asm). Le plus long
; --- bloc de reponse est de 33 octets (FS_READ) ---
BRIDGE_RX_HEAD_OFF  equ 0FC52h  ; (octet)
BRIDGE_RX_TAIL_OFF  equ 0FC53h  ; (octet)
BRIDGE_RX_BUF_OFF   equ 0FC70h  ; (64 octets: 0FC70h-0FCAFh)
BRIDGE_EXPECT_OFF   equ 0FC64h  ; (octet) 1 = une reponse est attendue (mis par rtc_get)

; --- frequence COURANTE de l'horloge du 8088, mise en cache cote 8088 (Hz) -
; --- evite un aller-retour au pont (fs_clock_cmd, lib/bridge.asm) a chaque
; --- redessin du menu principal: clock_show (solution-01.asm) la met a jour
; --- a chaque lecture/reglage reussi depuis le sous-menu Configuration/Clock
; --- speed; clock_main_speed_print l'utilise pour l'afficher au menu
; --- principal. Initialisee a 4 770 000 (valeur par defaut du pont a SON
; --- propre demarrage) juste apres l'effacement de VAR_SEG - voir start:. ---
CLOCK_FREQ_HZ_OFF   equ 0FC65h  ; (double mot) frequence courante en Hz

; --- heure de DEPART (secondes depuis minuit, RTC du pont - horloge
; --- INDEPENDANTE de celle du 8088) du banc d'essai "2) Test CPU speed"
; --- (cpu_speed_test_action, solution-01.asm) - voir aussi
; --- cpu_test_rtc_to_seconds/cpu_test_elapsed_seconds. Local a cette seule
; --- action (pas de persistance requise entre 2 lancements du test). ---
CPU_TEST_START_SEC_OFF equ 0FC69h  ; (double mot)

; --- etat du BIOS (lib/bios.asm) dans VAR_SEG: pile du programme appelant memorisee pendant qu'un
; --- service BIOS travaille sur sa pile privee (1000:FE00-FEFF), touche en attente, etc. ---
BIOS_SP_OFF         equ 0FCB0h  ; (mot) SP du programme appelant (pointe sur son DS sauve)
BIOS_SS_OFF         equ 0FCB2h  ; (mot) SS du programme appelant
BIOS_KEY_OFF        equ 0FCB4h  ; (mot) touche en attente (AH = scan code, AL = ASCII)
BIOS_KEYF_OFF       equ 0FCB6h  ; (octet) 1 = BIOS_KEY_OFF est valide
BIOS_STAT_OFF       equ 0FCB7h  ; (octet) dernier etat de INT 13h
BIOS_RETF_OFF       equ 0FCB8h  ; (octet) indicateurs a renvoyer: bit 0 = CF, bit 6 = ZF
BIOS_OP_OFF         equ 0FCBAh  ; (octet) 0 lecture, 1 ecriture, 2 verification
BIOS_DONE_OFF       equ 0FCBBh  ; (mot) secteurs transferes
BIOS_NSEC_OFF       equ 0FCBDh  ; (double mot) nombre de secteurs du disque (0 = inconnu)
BIOS_LBA_OFF        equ 0FCC1h  ; (double mot) numero de secteur courant
BIOS_RTC_OFF        equ 0FCC5h  ; (8 octets) heure lue au pont: FCC5h-FCCCh
; --- image de disquette montee (lecteur A: = fichier .IMG de la flash), lib/bios.asm ---
BIOS_FLOP_OFF       equ 0FCCDh  ; (octet) 1 = une image est montee
BIOS_FCYL_OFF       equ 0FCCEh  ; (mot) cylindres de l'image
BIOS_FHEADS_OFF     equ 0FCD0h  ; (octet) tetes
BIOS_FSPT_OFF       equ 0FCD1h  ; (octet) secteurs par piste
BIOS_FTYPE_OFF      equ 0FCD2h  ; (octet) type de lecteur (INT 13h AH=08h, BL)
BIOS_DRV_OFF        equ 0FCD3h  ; (octet) lecteur de l'appel INT 13h en cours: 0 disque dur, 1 disquette
BIOS_GH_OFF         equ 0FCD4h  ; (mot) tetes de la geometrie courante (disque dur: 255)
BIOS_GS_OFF         equ 0FCD6h  ; (mot) secteurs par piste de la geometrie courante (disque dur: 63)
BIOS_NAME_OFF       equ 0FCD8h  ; (16 octets) nom de l'image a monter (copie du nom de l'appelant)
BIOS_LASTTICK       equ 0FCECh  ; (double mot) dernier compteur de ticks rendu par INT 1Ah AH=00h
BIOS_USB_STATE      equ 0FCE8h  ; (octet) sous-menu USB Disk: 0 = OFF (par defaut, comme au demarrage), 1 = ON
BIOS_TRY            equ 0FBF0h  ; (octet) tentatives de lecture du secteur courant (INT 13h; fin du tampon d'edition du moniteur)
BIOS_BADSUM         equ 0FBF2h  ; (mot) lectures de secteur recommencees a cause d'une somme de controle fausse
BIOS_TRC2           equ 0FBF8h  ; (mot) nombre d'appels INT 1Ah AH=00 de la signature BX=0306 CX=0006 DX=0000 (BIOS_TRACE: carte memoire au 5e)
BIOS_TRC            equ 0FBF6h  ; (octet) 1 = l'appel INT 13h/1Ah en cours est trace (BIOS_TRACE)
BIOS_NPATCH         equ 0FBF4h  ; (mot) instructions OUT neutralisees dans les secteurs lus (bios_patch_sector)
RAM_DEFECT_BYTES    equ 0FBFAh  ; (mot) test_ram: nombre total d'octets defectueux (tous blocs confondus)

%endif ; HARDWARE_INC
