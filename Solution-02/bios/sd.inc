; =============================================================================
; sd.inc - lecteur de carte microSD (J9) sur U12 (8255, mode 0), SPI fait par le 8088.
;   PC4 = CS, PC5 = SCK, PC6 = MOSI (sorties de U12), PB3 = MISO (entree).
;   Mode SPI 0 : MOSI pose avec SCK bas, la carte lit au front montant ; MISO lu avec
;   SCK haut (la carte le change au front descendant). PC0 reste a 1 (clavier libre).
; Cartes SD v1 (SDSC, adresse en octets), SD v2 SDSC et SDHC/SDXC (adresse en blocs).
; FAT16 ou FAT32 (avec ou sans table de partitions) : images de disquette .IMG a la racine.
; Conventions : ES = DSEG pour les variables (V_SD_*, V_FAT_*), DS = CS ; les secteurs lus
; vont dans le tampon SD_TAMPON:0000 (512 o en 00500h, libre tant que le DOS n'est pas la)
; ou en ES:DI pour sd_lire.
; =============================================================================

SD_REPOS        equ     41h             ; PC0 = 1, CS = 0, SCK = 0, MOSI = 1
SD_CS           equ     10h             ; PC4
SD_SCK          equ     20h             ; PC5
SD_MOSI         equ     40h             ; PC6
SD_MISO         equ     08h             ; PB3
SD_TAMPON       equ     0050h           ; segment du tampon d'un secteur (00500h-006FFh)

V_SD_TYPE       equ     850h            ; 0 = aucune, 1 = SD v1, 2 = SD v2 SDSC, 3 = SDHC/SDXC
V_SD_R0         equ     851h            ; R1 de CMD0, CMD8, ACMD41 (diagnostic)
V_SD_R8         equ     852h
V_SD_R41        equ     853h
V_SD_ETAPE      equ     854h            ; etape de l'echec (1 CMD0, 2 CMD8, 3 ACMD41, 4 CMD58, 5 CMD16)
V_SD_OCR        equ     856h            ; (4 octets) OCR, octet de poids fort en premier
V_SD_CSD        equ     860h            ; (16 octets) registre CSD
V_LIGNE         equ     870h            ; (20 octets) ligne de texte en preparation
V_FAT_TYPE      equ     884h            ; 16 ou 32
V_FAT_SPC       equ     885h            ; secteurs par amas
V_FAT_PART      equ     888h            ; (dd) premier secteur de la partition
V_FAT_LBA       equ     88Ch            ; (dd) premier secteur de la 1re FAT
V_FAT_RACINE    equ     890h            ; (dd) premier secteur du repertoire racine
V_FAT_DONNEES   equ     894h            ; (dd) premier secteur de l'amas 2
V_FAT_RACN      equ     898h            ; (dw) secteurs de la racine a lire (FAT16 ; FAT32 : 1 amas)
V_FAT_NIMG      equ     89Ah            ; images .IMG trouvees
V_FAT_TAILLE    equ     89Ch            ; (dd) secteurs par FAT
V_FAT_RCLUS     equ     8A0h            ; (dd) amas de la racine (FAT32)
V_NOM1          equ     8C0h            ; (13 o) nom de la 1re image trouvee (diagnostic)
V_NOMT          equ     8D0h            ; (13 o) nom en clair de l'image en cours

; -----------------------------------------------------------------------------
; SPI
; -----------------------------------------------------------------------------
; sd_horloges : CX impulsions de SCK avec CS = 1 et MOSI = 1 (carte desselectionnee).
; Detruit AL, CX.
sd_horloges:
.c:     mov     al, SD_REPOS | SD_CS
        out     PPI2_PC, al
        or      al, SD_SCK
        out     PPI2_PC, al
        loop    .c
        mov     al, SD_REPOS | SD_CS
        out     PPI2_PC, al
        ret

; sd_libere : CS = 1 puis 8 impulsions (la carte relache MISO). Preserve tout sauf AL.
sd_libere:
        push    cx
        mov     cx, 8
        call    sd_horloges
        pop     cx
        ret

; spi_octet : envoie AL, rend l'octet recu dans AL (CS doit etre a 0). Preserve le reste.
spi_octet:
        push    bx
        push    cx
        mov     bl, al
        mov     cx, 8
.b:     mov     al, SD_REPOS            ; MOSI = 1
        shl     bl, 1
        jc      .un
        mov     al, SD_REPOS & ~SD_MOSI ; MOSI = 0
.un:    out     PPI2_PC, al             ; SCK = 0, MOSI pose
        or      al, SD_SCK
        out     PPI2_PC, al             ; SCK = 1 : la carte lit MOSI
        in      al, PPI2_PB
        and     al, SD_MISO
        add     al, 0F8h                ; CF = MISO
        rcl     bh, 1
        loop    .b
        mov     al, SD_REPOS
        out     PPI2_PC, al             ; SCK = 0
        mov     al, bh
        pop     cx
        pop     bx
        ret

; spi_ff : recoit un octet (envoie FFh). AL = octet recu.
spi_ff:
        mov     al, 0FFh
        jmp     spi_octet

; sd_cmd : commande AL (0-63), argument DX:BX (DX = poids fort), CRC AH. CS = 0.
; AL = R1 (bit 7 a 1 : pas de reponse). Preserve le reste.
sd_cmd:
        push    cx
        push    ax
        mov     al, SD_REPOS
        out     PPI2_PC, al             ; CS = 0
        call    spi_ff
        pop     ax
        push    ax
        or      al, 40h
        call    spi_octet
        mov     al, dh
        call    spi_octet
        mov     al, dl
        call    spi_octet
        mov     al, bh
        call    spi_octet
        mov     al, bl
        call    spi_octet
        pop     ax
        mov     al, ah
        call    spi_octet
        mov     cx, 10                  ; R1 : jusqu'a 8 octets d'attente
.r:     call    spi_ff
        test    al, 80h
        jz      .fin
        loop    .r
.fin:   pop     cx
        ret

; sd_cmd0a : commande AL sans argument, CRC 01h (sauf CMD0). Detruit BX, DX.
sd_cmd0a:
        xor     dx, dx
        xor     bx, bx
        mov     ah, 01h
        jmp     sd_cmd

; -----------------------------------------------------------------------------
; sd_init : initialise la carte. CF = 0 et V_SD_TYPE = 1-3, ou CF = 1 (V_SD_ETAPE).
; Detruit AX, BX, CX, DX, SI, DI.
; -----------------------------------------------------------------------------
sd_init:
        mov     byte [es:V_SD_TYPE], 0
        mov     word [es:V_SD_R0], 0FFFFh
        mov     byte [es:V_SD_R41], 0FFh
        mov     cx, 80                  ; >= 74 impulsions, CS = 1
        call    sd_horloges
        mov     byte [es:V_SD_ETAPE], 1
        mov     di, 10
.c0:    mov     al, 0                   ; CMD0 : GO_IDLE_STATE
        xor     dx, dx
        xor     bx, bx
        mov     ah, 95h
        call    sd_cmd
        mov     [es:V_SD_R0], al
        cmp     al, 01h
        je      .c8
        call    sd_libere
        dec     di
        jnz     .c0
        jmp     .echec
.c8:    call    sd_libere
        mov     byte [es:V_SD_ETAPE], 2
        mov     al, 8                   ; CMD8 : SEND_IF_COND, 2,7-3,6 V, motif AAh
        xor     dx, dx
        mov     bx, 01AAh
        mov     ah, 87h
        call    sd_cmd
        mov     [es:V_SD_R8], al
        xor     si, si                  ; SI = argument de ACMD41 (poids fort)
        cmp     al, 01h
        jne     .v1                     ; 05h : commande illegale -> carte v1
        call    spi_ff
        call    spi_ff
        call    spi_ff
        and     al, 0Fh
        cmp     al, 01h
        jne     .echec
        call    spi_ff
        cmp     al, 0AAh
        jne     .echec
        mov     si, 4000h               ; HCS : on sait adresser les SDHC
.v1:    mov     byte [es:V_SD_ETAPE], 3
        mov     di, 2000                ; ~3 s au plus
.a41:   call    sd_libere
        mov     al, 55                  ; CMD55 : APP_CMD
        call    sd_cmd0a
        call    sd_libere
        mov     al, 41                  ; ACMD41 : SD_SEND_OP_COND
        mov     dx, si
        xor     bx, bx
        mov     ah, 01h
        call    sd_cmd
        mov     [es:V_SD_R41], al
        or      al, al
        jz      .prete
        dec     di
        jnz     .a41
        jmp     .echec
.prete: call    sd_libere
        mov     byte [es:V_SD_TYPE], 1
        or      si, si
        jz      .c16
        mov     byte [es:V_SD_TYPE], 2
        mov     byte [es:V_SD_ETAPE], 4
        mov     al, 58                  ; CMD58 : READ_OCR
        call    sd_cmd0a
        or      al, al
        jnz     .echec
        mov     di, V_SD_OCR
        mov     cx, 4
.ocr:   call    spi_ff
        stosb
        loop    .ocr
        call    sd_libere
        test    byte [es:V_SD_OCR], 40h ; CCS : carte a capacite etendue
        jz      .c16
        mov     byte [es:V_SD_TYPE], 3
        clc
        ret
.c16:   mov     byte [es:V_SD_ETAPE], 5
        mov     al, 16                  ; CMD16 : SET_BLOCKLEN 512
        xor     dx, dx
        mov     bx, 512
        mov     ah, 01h
        call    sd_cmd
        or      al, al
        jnz     .echec
        call    sd_libere
        clc
        ret
.echec: call    sd_libere
        mov     byte [es:V_SD_TYPE], 0
        stc
        ret

; sd_bloc : lit un bloc de donnees de CX octets (jeton FEh, donnees, CRC) en ES:DI,
; apres une commande acceptee. CF = 1 si le jeton ne vient pas. Detruit AX, CX, DI.
sd_bloc:
        push    cx
        mov     cx, 0                   ; 65536 essais
.t:     call    spi_ff
        cmp     al, 0FEh
        je      .donnees
        cmp     al, 0FFh
        jne     .err
        loop    .t
.err:   pop     cx
        call    sd_libere
        stc
        ret
.donnees:
        pop     cx
.d:     call    spi_ff
        stosb
        loop    .d
        call    spi_ff                  ; CRC (ignore)
        call    spi_ff
        call    sd_libere
        clc
        ret

; sd_lire : lit le secteur DX:AX (512 o) en ES:DI. CF = 1 en cas d'erreur.
; Detruit AX, BX, CX, DX, DI.
sd_lire:
        push    ds
        mov     bx, DSEG
        mov     ds, bx
        cmp     byte [V_SD_TYPE], 3
        pop     ds
        je      .bloc
        mov     dh, dl                  ; SDSC : adresse en octets = secteur x 512
        mov     dl, ah
        mov     ah, al
        xor     al, al
        shl     ax, 1
        rcl     dx, 1
.bloc:  mov     bx, ax
        mov     al, 17                  ; CMD17 : READ_SINGLE_BLOCK
        mov     ah, 01h
        call    sd_cmd
        or      al, al
        jnz     .err
        mov     cx, 512
        jmp     sd_bloc
.err:   call    sd_libere
        stc
        ret

; sd_tampon : lit le secteur DX:AX dans SD_TAMPON:0000. Preserve ES. CF.
sd_tampon:
        push    es
        push    di
        mov     di, SD_TAMPON
        mov     es, di
        xor     di, di
        call    sd_lire
        pop     di
        pop     es
        ret

; sd_capacite : lit le CSD (CMD9). DX:AX = capacite en Mo. CF = 1 si erreur.
sd_capacite:
        mov     al, 9                   ; CMD9 : SEND_CSD
        call    sd_cmd0a
        or      al, al
        jnz     .err
        mov     di, V_SD_CSD
        mov     cx, 16
        call    sd_bloc
        jc      .r
        mov     al, [es:V_SD_CSD]
        and     al, 0C0h
        jz      .v1
        mov     dl, [es:V_SD_CSD + 7]   ; CSD 2.0 : C_SIZE (22 bits) ; Mo = (C_SIZE + 1) / 2
        and     dl, 3Fh
        xor     dh, dh
        mov     ah, [es:V_SD_CSD + 8]
        mov     al, [es:V_SD_CSD + 9]
        add     ax, 1
        adc     dx, 0
        shr     dx, 1
        rcr     ax, 1
        clc
        ret
.v1:    mov     ah, [es:V_SD_CSD + 6]   ; CSD 1.0 : (C_SIZE + 1) << (MULT + 2 + READ_BL_LEN) octets
        and     ah, 03h
        mov     al, [es:V_SD_CSD + 7]
        mov     cl, 2
        shl     ax, cl
        mov     bl, [es:V_SD_CSD + 8]
        mov     cl, 6
        shr     bl, cl
        or      al, bl
        inc     ax                      ; AX = C_SIZE + 1 (<= 4096)
        mov     bl, [es:V_SD_CSD + 9]
        and     bl, 03h
        shl     bl, 1
        mov     bh, [es:V_SD_CSD + 10]
        rol     bh, 1
        and     bh, 01h
        or      bl, bh                  ; BL = C_SIZE_MULT
        mov     bh, [es:V_SD_CSD + 5]
        and     bh, 0Fh                 ; BH = READ_BL_LEN
        add     bl, bh
        add     bl, 2                   ; BL = puissance de 2 (octets)
        xor     dx, dx
        mov     cl, bl
        xor     ch, ch
.s:     shl     ax, 1                   ; DX:AX <<= BL (au plus 2^32)
        rcl     dx, 1
        loop    .s
        mov     cx, 20                  ; en Mo
.m:     shr     dx, 1
        rcr     ax, 1
        loop    .m
        clc
        ret
.err:   call    sd_libere
        stc
.r:     ret

; -----------------------------------------------------------------------------
; FAT
; -----------------------------------------------------------------------------
; fat_ouvre : lit la table de partitions (ou l'amorce d'un volume sans partitions) et
; le secteur d'amorce du volume ; calcule V_FAT_*. CF = 1 et AL = code : 1 lecture,
; 2 pas de 55AAh, 3 secteurs de taille <> 512, 4 pas de FAT16/FAT32.
; Detruit AX, BX, CX, DX, SI, DI.
fat_ouvre:
        xor     ax, ax
        xor     dx, dx
        mov     [es:V_FAT_PART], ax
        mov     [es:V_FAT_PART + 2], ax
        call    sd_tampon
        mov     al, 1
        jc      .err
        push    ds
        mov     ax, SD_TAMPON
        mov     ds, ax
        mov     cl, 2
        cmp     word [510], 0AA55h
        jne     .err_ds
        cmp     byte [0], 0EBh          ; secteur 0 = amorce d'un volume (pas de partitions) ?
        je      .volume
        cmp     byte [0], 0E9h
        je      .volume
        mov     ax, [1C6h]              ; 1re partition : premier secteur
        mov     dx, [1C8h]
        pop     ds
        mov     [es:V_FAT_PART], ax
        mov     [es:V_FAT_PART + 2], dx
        call    sd_tampon
        mov     al, 1
        jc      .err
        push    ds
        mov     ax, SD_TAMPON
        mov     ds, ax
        mov     cl, 2
        cmp     word [510], 0AA55h
        jne     .err_ds
.volume:
        mov     cl, 3
        cmp     word [0Bh], 512
        jne     .err_ds
        mov     al, [0Dh]
        mov     [es:V_FAT_SPC], al
        mov     ax, [0Eh]               ; secteurs reserves
        add     ax, [es:V_FAT_PART]
        mov     dx, [es:V_FAT_PART + 2]
        adc     dx, 0
        mov     [es:V_FAT_LBA], ax
        mov     [es:V_FAT_LBA + 2], dx
        mov     bl, [10h]               ; nombre de FAT
        mov     cx, [11h]               ; entrees de la racine (0 en FAT32)
        mov     si, [16h]               ; secteurs par FAT (FAT16)
        or      si, si
        jz      .fat32
        or      cx, cx
        jz      .fat32
        mov     byte [es:V_FAT_TYPE], 16
        mov     [es:V_FAT_TAILLE], si
        mov     word [es:V_FAT_TAILLE + 2], 0
        pop     ds
.f16:   add     ax, si                  ; racine = FAT + nombre x taille
        adc     dx, 0
        dec     bl
        jnz     .f16
        mov     [es:V_FAT_RACINE], ax
        mov     [es:V_FAT_RACINE + 2], dx
        add     cx, 15                  ; secteurs de la racine = entrees / 16
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        mov     [es:V_FAT_RACN], cx
        add     ax, cx
        adc     dx, 0
        mov     [es:V_FAT_DONNEES], ax
        mov     [es:V_FAT_DONNEES + 2], dx
        clc
        ret
.fat32: mov     cl, 4
        cmp     word [24h], 0
        jne     .f32ok
        cmp     word [26h], 0
        je      .err_ds
.f32ok: mov     byte [es:V_FAT_TYPE], 32
        mov     si, [24h]
        mov     di, [26h]
        mov     [es:V_FAT_TAILLE], si
        mov     [es:V_FAT_TAILLE + 2], di
        mov     cx, [2Ch]
        mov     [es:V_FAT_RCLUS], cx
        mov     cx, [2Eh]
        mov     [es:V_FAT_RCLUS + 2], cx
        pop     ds
.f32:   add     ax, si                  ; donnees = FAT + nombre x taille
        adc     dx, di
        dec     bl
        jnz     .f32
        mov     [es:V_FAT_DONNEES], ax
        mov     [es:V_FAT_DONNEES + 2], dx
        mov     ax, [es:V_FAT_RCLUS]
        mov     dx, [es:V_FAT_RCLUS + 2]
        call    fat_amas_lba
        mov     [es:V_FAT_RACINE], ax
        mov     [es:V_FAT_RACINE + 2], dx
        mov     al, [es:V_FAT_SPC]
        xor     ah, ah
        mov     [es:V_FAT_RACN], ax     ; FAT32 : le 1er amas de la racine
        clc
        ret
.err_ds:
        pop     ds
        mov     al, cl
.err:   stc
        ret

; fat_amas_lba : DX:AX = amas (>= 2) -> DX:AX = premier secteur. Detruit BX, CX.
fat_amas_lba:
        sub     ax, 2
        sbb     dx, 0
        mov     cl, [es:V_FAT_SPC]
.m:     shr     cl, 1                   ; SPC est une puissance de 2
        jz      .add
        shl     ax, 1
        rcl     dx, 1
        jmp     .m
.add:   add     ax, [es:V_FAT_DONNEES]
        adc     dx, [es:V_FAT_DONNEES + 2]
        ret

; -----------------------------------------------------------------------------
; Texte : ligne de 20 caracteres en ES:V_LIGNE (DI = position), puis LCD et UART
; -----------------------------------------------------------------------------
tx_init:
        push    ax
        push    cx
        mov     di, V_LIGNE
        mov     cx, LCD_COLS
        mov     al, ' '
        rep     stosb
        mov     di, V_LIGNE
        pop     cx
        pop     ax
        ret

; tx_chaine : CS:SI (termine par 0) en ES:DI (sans depasser la ligne). Detruit AL, SI.
tx_chaine:
        lodsb
        or      al, al
        jz      .fin
        cmp     di, V_LIGNE + LCD_COLS
        jae     tx_chaine
        stosb
        jmp     tx_chaine
.fin:   ret

tx_car:
        cmp     di, V_LIGNE + LCD_COLS
        jae     .fin
        stosb
.fin:   ret

; tx_hex8 : AL en 2 chiffres hexadecimaux. Detruit AX.
tx_hex8:
        push    ax
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        call    .q
        pop     ax
.q:     and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     tx_car
        add     al, 'A' - '9' - 1
        jmp     tx_car

; tx_dec32 : DX:AX en decimal. Detruit AX, BX, CX, DX, SI.
tx_dec32:
        xor     cx, cx                  ; CX = chiffres empiles
        mov     bx, 10
.d:     push    ax
        mov     ax, dx
        xor     dx, dx
        div     bx                      ; poids fort / 10
        mov     si, ax
        pop     ax
        div     bx                      ; (reste:poids faible) / 10
        push    dx                      ; chiffre
        inc     cx
        mov     dx, si
        or      si, ax
        jnz     .d
.p:     pop     ax
        add     al, '0'
        call    tx_car
        loop    .p
        ret

; tx_sortie : la ligne en LCD (DDRAM AL) et sur l'UART (sans les espaces de fin, CR LF).
; Detruit AX, BX, CX, SI.
tx_sortie:
        or      al, 80h
        call    lcd_cmd
        push    ds
        mov     ax, DSEG
        mov     ds, ax
        mov     si, V_LIGNE
        call    lcd_texte20
        mov     bx, LCD_COLS            ; UART : sans les espaces de fin
.l:     cmp     byte [V_LIGNE + bx - 1], ' '
        jne     .u
        dec     bx
        jnz     .l
.u:     mov     si, V_LIGNE
.c:     or      bx, bx
        jz      .cr
        lodsb
        call    uart_tx
        dec     bx
        jmp     .c
.cr:    pop     ds
        mov     al, 13
        call    uart_tx
        mov     al, 10
        jmp     uart_tx

%ifdef DIAG_SD
; =============================================================================
; ROM de diagnostic du lecteur SD (make diagsd) : toutes les ~3 s, initialise la carte
; et affiche (LCD et UART) : R1 de CMD0/CMD8/ACMD41, type et capacite, systeme de
; fichiers, images .IMG de la racine (toutes sur l'UART, la 1re et leur nombre au LCD).
; =============================================================================
diag_sd:
        mov     si, txt_dsd_uart
        call    uart_texte
        call    sd_init
        pushf
        call    tx_init                 ; ligne 1 : "DIAG SD 01 01 00"
        mov     si, txt_dsd1
        call    tx_chaine
        mov     al, [es:V_SD_R0]
        call    tx_hex8
        inc     di
        mov     al, [es:V_SD_R8]
        call    tx_hex8
        inc     di
        mov     al, [es:V_SD_R41]
        call    tx_hex8
        mov     al, LIGNE1
        call    tx_sortie
        popf
        jnc     .carte
        call    tx_init                 ; pas de carte, ou carte muette
        mov     si, txt_dsd_echec
        call    tx_chaine
        mov     al, [es:V_SD_ETAPE]
        add     al, '0'
        call    tx_car
        mov     al, ')'
        call    tx_car
        mov     al, LIGNE2
        call    tx_sortie
        call    tx_init
        mov     al, LIGNE3
        call    tx_sortie
        call    tx_init
        mov     al, LIGNE4
        call    tx_sortie
        jmp     .attente
.carte: call    sd_capacite             ; ligne 2 : "SDHC 7580 Mo" (CSD lu avant :
        pushf                           ;  sd_capacite se sert de DI)
        push    ax
        push    dx
        call    tx_init
        mov     bl, [es:V_SD_TYPE]
        xor     bh, bh
        shl     bx, 1
        mov     si, [cs:bx + txt_dsd_types - 2]
        call    tx_chaine
        pop     dx
        pop     ax
        popf
        jc      .l2
        call    tx_dec32
        mov     si, txt_dsd_mo
        call    tx_chaine
.l2:    mov     al, LIGNE2
        call    tx_sortie
        call    fat_ouvre               ; ligne 3 : "FAT32 part. 8192"
        jnc     .fat
        push    ax
        call    tx_init
        mov     si, txt_dsd_pasfat
        call    tx_chaine
        pop     ax
        add     al, '0'
        call    tx_car
        mov     al, LIGNE3
        call    tx_sortie
        call    tx_init
        mov     al, LIGNE4
        call    tx_sortie
        jmp     .attente
.fat:   call    tx_init
        mov     si, txt_dsd_fat
        call    tx_chaine
        mov     al, [es:V_FAT_TYPE]
        xor     ah, ah
        xor     dx, dx
        call    tx_dec32
        mov     si, txt_dsd_part
        call    tx_chaine
        mov     ax, [es:V_FAT_PART]
        mov     dx, [es:V_FAT_PART + 2]
        call    tx_dec32
        mov     al, LIGNE3
        call    tx_sortie
        call    diag_liste              ; ligne 4 : "3 IMG PCDOS21.IMG"
.attente:
        mov     cx, 15                  ; ~3 s
.a:     push    cx
        DELAY   0
        pop     cx
        loop    .a
        jmp     diag_sd

; diag_liste : parcourt la racine (FAT16 : toute ; FAT32 : 1er amas), envoie chaque image
; .IMG sur l'UART ("  NOM.IMG  taille Ko"), puis ligne 4 : nombre et 1re image.
diag_liste:
        mov     byte [es:V_FAT_NIMG], 0
        mov     word [es:V_NOM1], 0
        mov     ax, [es:V_FAT_RACINE]
        mov     dx, [es:V_FAT_RACINE + 2]
        mov     cx, [es:V_FAT_RACN]
.secteur:
        push    cx
        push    ax
        push    dx
        call    sd_tampon
        jc      .fin_pop
        xor     si, si                  ; 16 entrees de 32 octets
.entree:
        push    ds
        mov     bx, SD_TAMPON
        mov     ds, bx
        mov     al, [si]
        mov     ah, [si + 0Bh]
        cmp     al, 0
        je      .fin_ds                 ; fin du repertoire
        cmp     al, 0E5h
        je      .suiv_ds                ; entree effacee
        test    ah, 18h                 ; repertoire ou etiquette (et noms longs, 0Fh)
        jnz     .suiv_ds
        cmp     word [si + 8], 'IM'
        jne     .suiv_ds
        cmp     byte [si + 10], 'G'
        jne     .suiv_ds
        pop     ds
        call    diag_image
        jmp     .suiv
.suiv_ds:
        pop     ds
.suiv:  add     si, 32
        cmp     si, 512
        jb      .entree
        pop     dx
        pop     ax
        pop     cx
        add     ax, 1
        adc     dx, 0
        loop    .secteur
        jmp     .ligne4
.fin_ds:
        pop     ds
.fin_pop:
        pop     dx
        pop     ax
        pop     cx
.ligne4:
        call    tx_init
        mov     al, [es:V_FAT_NIMG]
        xor     ah, ah
        xor     dx, dx
        call    tx_dec32
        mov     si, txt_dsd_img
        call    tx_chaine
        cmp     byte [es:V_FAT_NIMG], 0
        je      .l4
        push    ds                      ; nom de la 1re image (V_NOM1)
        push    es
        pop     ds
        mov     si, V_NOM1
        mov     cx, 12
.n:     lodsb
        or      al, al
        jz      .n_fin
        call    tx_car
        loop    .n
.n_fin: pop     ds
.l4:    mov     al, LIGNE4
        jmp     tx_sortie

; diag_image : entree SD_TAMPON:SI = image : sur l'UART "  NOM.IMG  nnn Ko" ; garde le nom
; de la premiere en V_NOM1. Preserve SI.
diag_image:
        push    si
        inc     byte [es:V_FAT_NIMG]
        mov     di, V_NOMT              ; nom 8.3 en clair (13 o)
        push    di
        push    ds
        mov     ax, SD_TAMPON
        mov     ds, ax
        mov     cx, 8
.nom:   lodsb
        cmp     al, ' '
        je      .s1
        stosb
.s1:    loop    .nom
        mov     al, '.'
        stosb
        movsb
        movsb
        movsb
        mov     al, 0
        stosb
        mov     ax, [si + 1Ch - 11]     ; taille en octets (dd)
        mov     dx, [si + 1Eh - 11]
        pop     ds
        pop     si                      ; SI = nom en clair (ES)
        push    ax
        push    dx
        cmp     byte [es:V_FAT_NIMG], 1
        jne     .uart
        push    si                      ; 1re image : copie du nom
        mov     di, V_NOM1
        mov     cx, 13
        push    ds
        push    es
        pop     ds
        rep     movsb
        pop     ds
        pop     si
.uart:  mov     al, ' '
        call    uart_tx
        call    uart_tx
        push    ds
        push    es
        pop     ds
        call    uart_texte
        pop     ds
        mov     al, ' '
        call    uart_tx
        call    uart_tx
        pop     dx
        pop     ax
        mov     cx, 10                  ; Ko
.k:     shr     dx, 1
        rcr     ax, 1
        loop    .k
        call    tx_dec32_uart
        mov     si, txt_dsd_ko
        call    uart_texte
        pop     si
        ret

; tx_dec32_uart : DX:AX en decimal sur l'UART. Detruit AX, BX, CX, DX, SI.
tx_dec32_uart:
        xor     cx, cx
        mov     bx, 10
.d:     push    ax
        mov     ax, dx
        xor     dx, dx
        div     bx
        mov     si, ax
        pop     ax
        div     bx
        push    dx
        inc     cx
        mov     dx, si
        or      si, ax
        jnz     .d
.p:     pop     ax
        add     al, '0'
        call    uart_tx
        loop    .p
        ret

txt_dsd_uart:   db  13, 10, '--- Diagnostic du lecteur SD (U12 : PC4 CS, PC5 SCK, PC6 MOSI, PB3 MISO) ---', 13, 10, 0
txt_dsd1:       db  'DIAG SD ', 0
txt_dsd_echec:  db  'Pas de carte (et. ', 0
txt_dsd_types:  dw  txt_dsd_v1, txt_dsd_v2, txt_dsd_hc
txt_dsd_v1:     db  'SD v1 ', 0
txt_dsd_v2:     db  'SD v2 ', 0
txt_dsd_hc:     db  'SDHC ', 0
txt_dsd_mo:     db  ' Mo', 0
txt_dsd_pasfat: db  'Pas de FAT, code ', 0
txt_dsd_fat:    db  'FAT', 0
txt_dsd_part:   db  ' part. ', 0
txt_dsd_img:    db  ' IMG ', 0
txt_dsd_ko:     db  ' Ko', 13, 10, 0
%endif
