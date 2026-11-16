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
        push    bx                      ; reception rapide : 8 bits deroules par octet
        push    dx                      ; (OUT DX = 1 octet de code : le 8088 est limite
        mov     dx, PPI2_PC             ;  par la lecture des instructions)
        mov     bl, SD_REPOS            ; SCK = 0, MOSI = 1
        mov     bh, SD_REPOS | SD_SCK   ; SCK = 1
.d:
%rep 8
        mov     al, bl
        out     dx, al
        mov     al, bh
        out     dx, al
        in      al, PPI2_PB
        and     al, SD_MISO
        add     al, 0F8h                ; CF = MISO
        rcl     ah, 1
%endrep
        mov     al, ah
        stosb
        loop    .d
        mov     al, bl
        out     dx, al                  ; SCK = 0
        pop     dx
        pop     bx
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

; -----------------------------------------------------------------------------
; sd_ecrire : ecrit le secteur DX:AX (512 o) depuis DS:SI. CF = 1 en cas d'erreur.
; Detruit AX, BX, CX, DX, SI.
; -----------------------------------------------------------------------------
sd_ecrire:
        push    ds
        mov     bx, DSEG
        mov     ds, bx
        cmp     byte [V_SD_TYPE], 3
        pop     ds
        je      .bloc
        mov     dh, dl                  ; SDSC : adresse en octets
        mov     dl, ah
        mov     ah, al
        xor     al, al
        shl     ax, 1
        rcl     dx, 1
.bloc:  mov     bx, ax
        mov     al, 24                  ; CMD24 : WRITE_BLOCK
        mov     ah, 01h
        call    sd_cmd
        or      al, al
        jnz     .err
        call    spi_ff                  ; un octet d'ecart
        mov     al, 0FEh                ; jeton de debut
        call    spi_octet
        mov     cx, 512
.d:     lodsb
        call    spi_octet
        loop    .d
        call    spi_ff                  ; CRC (ignore par la carte en SPI)
        call    spi_ff
        call    spi_ff                  ; reponse : xxx00101 = acceptee
        and     al, 1Fh
        cmp     al, 05h
        jne     .err
        mov     cx, 0                   ; occupee (00h) jusqu'a FFh : ~6 s au plus
.occ:   call    spi_ff
        or      al, al
        jnz     .fin
        loop    .occ
        jmp     .err
.fin:   call    sd_libere
        clc
        ret
.err:   call    sd_libere
        stc
        ret

; -----------------------------------------------------------------------------
; Images de disquette (.IMG) de la racine : table, choix au Load DOS, lecteur A:
; -----------------------------------------------------------------------------
T_IMG           equ     0B00h           ; table : IMG_MAX x 20 o (nom 11, taille dd, amas dd, 1 libre)
IMG_MAX         equ     16
IMG_T           equ     20
; un bloc de 12 octets par lecteur : +0 actif, +1 secteurs/piste, +2 tetes, +3 cylindres,
; +4 type (INT 13h AH=08h), +6 (dw) secteurs, +8 (dd) premier secteur sur la carte.
; int13_sd copie le bloc du lecteur demande dans le bloc courant (V_IMG_COUR).
IMG_BLOC        equ     12
IMG_A           equ     8E0h            ; A: (image choisie au Load DOS)
IMG_B           equ     0C40h           ; B: (image DOS 2.x de la carte, au demarrage depuis la ROM)
V_IMG_COUR      equ     0C50h           ; bloc courant
V_IMG_ACTIF     equ     IMG_A           ; 1 = A: est une image de la carte
V_IMGB_ACTIF    equ     IMG_B           ; 1 = B: est une image de la carte (sinon : disque en RAM)
V_IMG_SPT       equ     V_IMG_COUR + 1
V_IMG_TETES     equ     V_IMG_COUR + 2
V_IMG_CYL       equ     V_IMG_COUR + 3
V_IMG_TYPE      equ     V_IMG_COUR + 4
V_IMG_SECT      equ     V_IMG_COUR + 6
V_IMG_LBA       equ     V_IMG_COUR + 8
V_PROGRES       equ     0C5Ch           ; 1 = demarrage depuis la carte en cours (progression)
V_LUS           equ     0C5Eh           ; (dw) secteurs lus pendant le demarrage
V_IMG_NB        equ     8F2h            ; images dans la table
V_FAT_CACHE     equ     8ECh            ; (dd) secteur de FAT dans SD_TAMPON (FFFFFFFFh : aucun)
V_IMG_CHOIX     equ     8F0h            ; ligne choisie (0 = ROM)
V_IMG_HAUT      equ     8F1h            ; premiere ligne visible

; formats reconnus (taille en octets) : secteurs/piste, tetes, cylindres, type de lecteur
img_formats:
        dd      163840
        db      8, 1, 40, 1             ; 160 Ko
        dd      184320
        db      9, 1, 40, 1             ; 180 Ko
        dd      327680
        db      8, 2, 40, 1             ; 320 Ko
        dd      368640
        db      9, 2, 40, 1             ; 360 Ko
        dd      737280
        db      9, 2, 80, 3             ; 720 Ko
        dd      1228800
        db      15, 2, 80, 2            ; 1,2 Mo
        dd      1474560
        db      18, 2, 80, 4            ; 1,44 Mo
img_formats_fin:

; img_liste : remplit T_IMG avec les .IMG de la racine (FAT16 : toute ; FAT32 : 1er amas).
; V_IMG_NB. Detruit AX, BX, CX, DX, SI, DI.
img_liste:
        mov     byte [es:V_IMG_NB], 0
        mov     ax, [es:V_FAT_RACINE]
        mov     dx, [es:V_FAT_RACINE + 2]
        mov     cx, [es:V_FAT_RACN]
.secteur:
        push    cx
        push    ax
        push    dx
        call    sd_tampon
        jc      .fin
        xor     si, si
.entree:
        push    ds
        mov     bx, SD_TAMPON
        mov     ds, bx
        mov     al, [si]
        mov     ah, [si + 0Bh]
        or      al, al
        jz      .fin_ds
        cmp     al, 0E5h
        je      .suiv_ds
        test    ah, 18h
        jnz     .suiv_ds
        cmp     word [si + 8], 'IM'
        jne     .suiv_ds
        cmp     byte [si + 10], 'G'
        jne     .suiv_ds
        mov     al, [es:V_IMG_NB]
        cmp     al, IMG_MAX
        jae     .suiv_ds
        mov     bl, IMG_T
        mul     bl
        add     ax, T_IMG
        mov     di, ax
        push    si
        mov     cx, 11                  ; nom
        rep     movsb
        pop     si
        mov     ax, [si + 1Ch]          ; taille
        stosw
        mov     ax, [si + 1Eh]
        stosw
        mov     ax, [si + 1Ah]          ; premier amas (poids faible, puis fort)
        stosw
        mov     ax, [si + 14h]
        stosw
        inc     byte [es:V_IMG_NB]
.suiv_ds:
        pop     ds
        add     si, 32
        cmp     si, 512
        jb      .entree
        pop     dx
        pop     ax
        pop     cx
        add     ax, 1
        adc     dx, 0
        loop    .secteur
        ret
.fin_ds:
        pop     ds
.fin:   pop     dx
        pop     ax
        pop     cx
        ret

; fat_entree : DX:AX = amas -> DX:AX = amas suivant (FAT16 : FFF8h et plus = fin -> rendu
; 0FFFFFFFh). CF = 1 si erreur de lecture. Detruit BX, CX, SI.
fat_entree:
        mov     si, ax
        cmp     byte [es:V_FAT_TYPE], 32
        je      .f32
        mov     cl, 8                   ; FAT16 : secteur = amas / 256, decalage = (amas % 256) x 2
        mov     bx, ax
        shr     ax, cl
        xor     dx, dx
        and     si, 0FFh
        shl     si, 1
        jmp     .lit
.f32:   mov     cx, 7                   ; FAT32 : secteur = amas / 128, decalage = (amas % 128) x 4
.d:     shr     dx, 1
        rcr     ax, 1
        loop    .d
        and     si, 7Fh
        shl     si, 1
        shl     si, 1
.lit:   add     ax, [es:V_FAT_LBA]
        adc     dx, [es:V_FAT_LBA + 2]
        cmp     ax, [es:V_FAT_CACHE]
        jne     .charge
        cmp     dx, [es:V_FAT_CACHE + 2]
        je      .en_cache
.charge:
        mov     [es:V_FAT_CACHE], ax
        mov     [es:V_FAT_CACHE + 2], dx
        push    si
        call    sd_tampon
        pop     si
        jnc     .en_cache
        mov     word [es:V_FAT_CACHE], 0FFFFh
        mov     word [es:V_FAT_CACHE + 2], 0FFFFh
        ret
.en_cache:
        push    ds
        mov     ax, SD_TAMPON
        mov     ds, ax
        mov     ax, [si]
        mov     dx, [si + 2]
        pop     ds
        cmp     byte [es:V_FAT_TYPE], 32
        je      .m32
        xor     dx, dx
        cmp     ax, 0FFF8h
        jb      .ok
        mov     dx, 0FFFh
        mov     ax, 0FFFFh
.ok:    clc
        ret
.m32:   and     dx, 0FFFh
        clc
        ret

; img_ouvre : image n AL (0-based) de T_IMG -> lecteur A:. CF = 1 et AL = 1 taille inconnue,
; 2 fichier fragmente, 3 erreur de lecture. Detruit AX, BX, CX, DX, SI, DI.
img_ouvre:
        mov     bl, IMG_T
        mul     bl
        add     ax, T_IMG
        mov     di, ax                  ; ES:DI = entree
        mov     si, img_formats         ; taille connue ?
.f:     mov     ax, [cs:si]
        cmp     ax, [es:di + 11]
        jne     .fs
        mov     ax, [cs:si + 2]
        cmp     ax, [es:di + 13]
        je      .format
.fs:    add     si, 8
        cmp     si, img_formats_fin
        jb      .f
        mov     al, 1
        stc
        ret
.format:
        mov     al, [cs:si + 4]
        mov     [es:V_IMG_SPT], al
        mov     al, [cs:si + 5]
        mov     [es:V_IMG_TETES], al
        mov     al, [cs:si + 6]
        mov     [es:V_IMG_CYL], al
        mov     al, [cs:si + 7]
        mov     [es:V_IMG_TYPE], al
        mov     ax, [es:di + 11]        ; secteurs = taille / 512
        mov     dx, [es:di + 13]
        mov     cx, 9
.s:     shr     dx, 1
        rcr     ax, 1
        loop    .s
        mov     [es:V_IMG_SECT], ax
        mov     cl, [es:V_FAT_SPC]      ; amas necessaires = secteurs / SPC (arrondi)
        xor     ch, ch
        dec     cx
        add     ax, cx
        inc     cx
.a:     shr     cx, 1
        jz      .a_fin
        shr     ax, 1
        jmp     .a
.a_fin: mov     bx, ax                  ; BX = amas
        mov     word [es:V_FAT_CACHE], 0FFFFh
        mov     word [es:V_FAT_CACHE + 2], 0FFFFh
        mov     ax, [es:di + 15]        ; premier amas
        mov     dx, [es:di + 17]
        push    ax
        push    dx
.chaine:                                ; chaque amas doit etre suivi du suivant
        dec     bx
        jz      .contigu
        push    bx
        push    ax
        push    dx
        call    fat_entree
        pop     cx                      ; CX:BX = amas courant
        pop     bx
        jc      .err_lecture
        add     bx, 1
        adc     cx, 0
        cmp     ax, bx
        jne     .fragmente
        cmp     dx, cx
        jne     .fragmente
        pop     bx
        jmp     .chaine
.fragmente:
        pop     bx
        pop     dx
        pop     ax
        mov     al, 2
        stc
        ret
.err_lecture:
        pop     bx
        pop     dx
        pop     ax
        mov     al, 3
        stc
        ret
.contigu:
        pop     dx
        pop     ax
        call    fat_amas_lba
        mov     [es:V_IMG_LBA], ax
        mov     [es:V_IMG_LBA + 2], dx
        mov     byte [es:V_IMG_COUR], 1
        clc
        ret

; img_vers : copie le bloc courant vers le bloc DI (IMG_A ou IMG_B). Detruit AX, CX, SI, DI.
img_vers:
        mov     si, V_IMG_COUR
        mov     cx, IMG_BLOC / 2
.c:     mov     ax, [es:si]
        mov     [es:di], ax
        add     si, 2
        add     di, 2
        loop    .c
        ret

; img_dos2_b : (demarrage depuis la ROM, carte lue) la 1re image dont le secteur d'amorce
; porte l'OEM 'IBM  2.' (PC-DOS 2.x) devient B:. Detruit AX, BX, CX, DX, SI, DI.
img_dos2_b:
        xor     cx, cx                  ; CL = image
.i:     cmp     cl, [es:V_IMG_NB]
        jae     .fin
        push    cx
        mov     al, cl
        mov     bl, IMG_T
        mul     bl
        add     ax, T_IMG
        mov     di, ax
        mov     ax, [es:di + 15]        ; premier amas -> secteur d'amorce de l'image
        mov     dx, [es:di + 17]
        call    fat_amas_lba
        call    sd_tampon
        pop     cx
        jc      .suiv
        push    ds
        mov     ax, SD_TAMPON
        mov     ds, ax
        cmp     word [3], 'IB'
        jne     .non
        cmp     word [5], 'M '
        jne     .non
        cmp     word [7], ' 2'
.non:   pop     ds
        jne     .suiv
        push    cx
        mov     al, cl
        call    img_ouvre
        pop     cx
        jc      .suiv
        mov     di, IMG_B
        jmp     img_vers
.suiv:  inc     cl
        jmp     .i
.fin:   ret

; sd_choisir : (Load DOS) carte presente avec des images : choix sur le LCD (et le
; terminal) : ROM puis les images ; fleches haut/bas, Entree, Echap. CF = 1 : Echap.
; Sans carte ni image : A: = ROM, CF = 0. ES = DSEG, DS = CS.
sd_choisir:
        mov     byte [es:V_IMG_ACTIF], 0
        mov     byte [es:V_IMGB_ACTIF], 0
        mov     byte [es:V_PROGRES], 0
        mov     si, txt_sd_lecture
        call    lcd_ecran
        call    sd_init
        jc      .rom
        call    fat_ouvre
        jc      .rom
        call    img_liste
        cmp     byte [es:V_IMG_NB], 0
        je      .rom
        mov     byte [es:V_IMG_CHOIX], 0
        mov     byte [es:V_IMG_HAUT], 0
.dessine:
        call    img_ecran
        call    ecran_uart
.touche:
        call    kbd_attend
        cmp     al, 27
        je      .echap
        cmp     al, 13
        je      .entree
        or      al, al
        jnz     .touche
        mov     bl, [es:V_IMG_CHOIX]
        cmp     ah, 48h                 ; haut
        jne     .bas
        or      bl, bl
        jz      .touche
        dec     bl
        jmp     .bouge
.bas:   cmp     ah, 50h
        jne     .touche
        cmp     bl, [es:V_IMG_NB]
        jae     .touche
        inc     bl
.bouge: mov     [es:V_IMG_CHOIX], bl
        mov     al, [es:V_IMG_HAUT]     ; fenetre de 3 lignes
        cmp     bl, al
        jae     .b1
        mov     al, bl
.b1:    mov     ah, al
        add     ah, 2
        cmp     bl, ah
        jbe     .b2
        mov     al, bl
        sub     al, 2
.b2:    mov     [es:V_IMG_HAUT], al
        jmp     .dessine
.entree:
        mov     al, [es:V_IMG_CHOIX]
        or      al, al
        jz      .rom_carte
        dec     al
        call    img_ouvre
        jc      .refus
        mov     di, IMG_A               ; A: = l'image ; progression pendant le demarrage
        call    img_vers
        mov     byte [es:V_PROGRES], 1
        mov     word [es:V_LUS], 0
        jmp     .fin
.rom_carte:
        call    img_dos2_b              ; ROM : B: = image DOS 2.x de la carte, s'il y en a une
        jmp     .fin
.refus:
        mov     bl, al                  ; message 1 s, puis la liste
        xor     bh, bh
        shl     bx, 1
        mov     si, [cs:bx + txt_img_err - 2]
        mov     al, 80h | LIGNE1
        call    lcd_cmd
        call    lcd_texte20
        mov     cx, 5
.p:     push    cx
        DELAY   0
        pop     cx
        loop    .p
        jmp     .dessine
.rom:   mov     byte [es:V_IMG_ACTIF], 0
.fin:   clc
        ret
.echap: stc
        ret

; img_ecran : titre et 3 lignes de la liste a partir de V_IMG_HAUT ('>' devant le choix).
img_ecran:
        mov     si, txt_img_titre
        mov     al, 80h | LIGNE1
        call    lcd_cmd
        call    lcd_texte20
        mov     cl, 0
.l:     push    cx
        mov     al, [es:V_IMG_HAUT]
        add     al, cl
        call    img_ligne
        pop     cx
        push    cx
        mov     bl, cl
        xor     bh, bh
        mov     al, [cs:bx + lignes_234]
        call    tx_sortie_lcd
        pop     cx
        inc     cl
        cmp     cl, 3
        jb      .l
        ret

lignes_234: db  LIGNE2, LIGNE3, LIGNE4

; img_ligne : V_LIGNE = ligne n AL de la liste (0 = ROM). Detruit AX, BX, CX, DX, SI, DI.
img_ligne:
        push    ax
        call    tx_init
        pop     ax
        mov     ah, ' '
        cmp     al, [es:V_IMG_CHOIX]
        jne     .marque
        mov     ah, '>'
.marque:
        push    ax
        mov     al, ah
        call    tx_car
        pop     ax
        or      al, al
        jnz     .image
        mov     si, txt_img_rom
        jmp     tx_chaine
.image: cmp     al, [es:V_IMG_NB]
        ja      .vide
        dec     al
        mov     bl, IMG_T
        mul     bl
        add     ax, T_IMG
        mov     si, ax
        mov     cx, 8                   ; nom en clair
.n:     mov     al, [es:si]
        inc     si
        cmp     al, ' '
        je      .n1
        call    tx_car
.n1:    loop    .n
        mov     al, '.'
        call    tx_car
        mov     cx, 3
.e:     mov     al, [es:si]
        inc     si
        call    tx_car
        loop    .e
        mov     di, V_LIGNE + 14        ; taille en Ko, alignee
        mov     ax, [es:si]
        mov     dx, [es:si + 2]
        mov     cx, 10
.k:     shr     dx, 1
        rcr     ax, 1
        loop    .k
        call    tx_dec32
        mov     al, 'K'
        jmp     tx_car
.vide:  ret

; tx_sortie_lcd : V_LIGNE sur la ligne DDRAM AL du LCD seulement. Detruit AX, BX, CX, SI.
tx_sortie_lcd:
        or      al, 80h
        call    lcd_cmd
        push    ds
        mov     ax, DSEG
        mov     ds, ax
        mov     si, V_LIGNE
        call    lcd_texte20
        pop     ds
        ret

txt_sd_lecture: db  'Carte SD...         '
                db  '                    '
                db  '                    '
                db  '                    '
txt_img_titre:  db  'Demarrer : Entree   '
txt_img_rom:    db  'ROM PC-DOS 2.1', 0
txt_img_err:    dw  txt_img_e1, txt_img_e2, txt_img_e3
txt_img_e1:     db  'Taille inconnue !   '
txt_img_e2:     db  'Image fragmentee !  '
txt_img_e3:     db  'Erreur de lecture ! '

; -----------------------------------------------------------------------------
; INT 13h, lecteur A: = image de la carte (V_IMG_ACTIF). Appele depuis int13h (cadre
; BIOS_ENTREE en place, ES = DSEG, DS = CS ; AH = fonction).
; -----------------------------------------------------------------------------
int13_sd:
        push    ax                      ; bloc du lecteur (A: ou B:) -> bloc courant
        push    cx
        push    si
        push    di
        mov     si, IMG_A
        or      dl, dl
        jz      .bloc
        mov     si, IMG_B
.bloc:  mov     di, V_IMG_COUR
        mov     cx, IMG_BLOC / 2
.cp:    mov     ax, [es:si]
        mov     [es:di], ax
        add     si, 2
        add     di, 2
        loop    .cp
        pop     di
        pop     si
        pop     cx
        pop     ax
        cmp     ah, 02h
        je      .lire
        cmp     ah, 03h
        je      .ecrire
        cmp     ah, 04h
        je      .verifier
        cmp     ah, 08h
        je      .params
        cmp     ah, 01h
        je      .etat
        cmp     ah, 15h
        je      .type
        cmp     ah, 00h                 ; 00h reinit., 05h formatage (les secteurs existent),
        je      .ok                     ; 16h changement, 17h/18h type de media : sans objet
        cmp     ah, 05h
        je      .ok
        cmp     ah, 16h
        je      .ok
        cmp     ah, 17h
        je      .ok
        cmp     ah, 18h
        je      .ok
        mov     ah, 01h
.err:   mov     [bp + R_AX + 1], ah
        mov     [es:V_DSTAT], ah
        jmp     bios_cf1
.ok:    mov     byte [bp + R_AX + 1], 0
        mov     byte [es:V_DSTAT], 0
        jmp     bios_cf0
.etat:  mov     al, [es:V_DSTAT]
        mov     [bp + R_AX], al
        jmp     .ok
.type:  mov     byte [bp + R_AX + 1], 01h
        jmp     bios_cf0
.params:
        mov     word [bp + R_AX], 0
        mov     al, [es:V_IMG_TYPE]
        xor     ah, ah
        mov     [bp + R_BX], ax
        mov     ah, [es:V_IMG_CYL]
        dec     ah
        mov     al, [es:V_IMG_SPT]
        mov     [bp + R_CX], ax
        mov     ah, [es:V_IMG_TETES]
        dec     ah
        mov     al, 2
        mov     [bp + R_DX], ax
        mov     word [bp + R_DI], dpt_180
        mov     [bp + R_ES], cs
        jmp     bios_cf0
.verifier:
        call    img_chs
        jc      .err
        jmp     .ok
.lire:  call    img_chs                 ; DX:AX = premier secteur sur la carte
        jc      .err
        mov     cx, [bp + R_BX]         ; destination ES:BX normalisee
        mov     di, cx
        and     di, 0Fh
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        add     cx, [bp + R_ES]
        mov     es, cx
        mov     cl, [bp + R_AX]
        xor     ch, ch
        call    sd_voyant
.l:     push    cx
        push    ax
        push    dx
        push    di
        call    sd_lire
        pop     di
        pop     dx
        pop     ax
        pop     cx
        jc      .err_es
        mov     bx, es
        add     bx, 32
        mov     es, bx
        add     ax, 1
        adc     dx, 0
        loop    .l
        mov     ax, DSEG
        mov     es, ax
        call    sd_voyant_eteint
        cmp     byte [es:V_PROGRES], 0  ; demarrage depuis la carte : progression
        je      .ok
        mov     al, [bp + R_AX]
        xor     ah, ah
        add     [es:V_LUS], ax
        call    progres_affiche
        jmp     .ok
.err_es:
        mov     ax, DSEG
        mov     es, ax
        call    sd_voyant_eteint
        mov     ah, 04h                 ; secteur introuvable
        jmp     .err
.ecrire:
        call    img_chs
        jc      .err
        mov     cx, [bp + R_BX]         ; source ES:BX normalisee -> DS:SI
        mov     si, cx
        and     si, 0Fh
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        shr     cx, 1
        add     cx, [bp + R_ES]
        mov     ds, cx
        mov     cl, [bp + R_AX]
        xor     ch, ch
        call    sd_voyant
.w:     push    cx
        push    ax
        push    dx
        push    si
        call    sd_ecrire
        pop     si
        pop     dx
        pop     ax
        pop     cx
        jc      .err_ds
        mov     bx, ds
        add     bx, 32
        mov     ds, bx
        add     ax, 1
        adc     dx, 0
        loop    .w
        mov     ax, cs
        mov     ds, ax
        call    sd_voyant_eteint
        jmp     .ok
.err_ds:
        mov     ax, cs
        mov     ds, ax
        call    sd_voyant_eteint
        mov     ah, 04h
        jmp     .err

; sd_voyant / sd_voyant_eteint : voyant d'acces a la carte = DEL PC7 de U7 (la plus a
; gauche), par mise a 1/0 d'un bit (BSR) : les autres DEL ne bougent pas. Preserve tout.
sd_voyant:
        push    ax
        mov     al, 0Fh                 ; BSR : PC7 = 1
        out     PPI_CTRL, al
        pop     ax
        ret
sd_voyant_eteint:
        push    ax
        mov     al, 0Eh                 ; BSR : PC7 = 0
        out     PPI_CTRL, al
        pop     ax
        ret

; progres_affiche : (demarrage depuis la carte) ligne 4 du LCD "Lecture A:  nnn Ko" et
; bargraphe : une DEL de plus tous les 8 Ko lus (24 DEL = 192 Ko, puis il recommence).
; Les animations sont suspendues pendant ce temps (V_PROGRES, voir irq_temps). ES = DSEG.
; Detruit AX, BX, CX, DX, SI, DI.
progres_affiche:
        call    tx_init
        mov     si, txt_lecture
        call    tx_chaine
        mov     ax, [es:V_LUS]
        shr     ax, 1                   ; Ko
        push    ax
        xor     dx, dx
        call    tx_dec32
        mov     si, txt_ko
        call    tx_chaine
        mov     al, LIGNE4
        call    tx_sortie_lcd
        pop     ax
        mov     cl, 3
        shr     ax, cl                  ; DEL = Ko / 8, modulo 25
        mov     bl, 25
        div     bl
        mov     al, ah
        xor     bx, bx                  ; DL:BH:BL = rangee, DEL allumees depuis la gauche
        xor     dl, dl
        or      al, al
        jz      .sort
.b:     stc
        rcr     dl, 1
        rcr     bh, 1
        rcr     bl, 1
        dec     al
        jnz     .b
.sort:  mov     al, dl
        out     PPI_PC, al
        mov     al, bh
        out     PPI_PA, al
        mov     al, bl
        out     PPI_PB, al
        ret

txt_lecture:    db  'Lecture A: ', 0
txt_ko:         db  ' Ko', 0

; img_chs : AL = nombre, CH = cylindre, CL = secteur, DH = tete -> DX:AX = premier secteur
; sur la carte ; CF = 1 et AH = 04h hors de l'image, 01h si nombre nul. Detruit BX, CX.
img_chs:
        mov     bl, al                  ; BL = nombre
        or      bl, bl
        jz      .inval
        cmp     dh, [es:V_IMG_TETES]
        jae     .hors
        cmp     ch, [es:V_IMG_CYL]
        jae     .hors
        and     cl, 3Fh
        jz      .hors
        cmp     cl, [es:V_IMG_SPT]
        ja      .hors
        mov     al, ch                  ; (cylindre x tetes + tete) x spt + secteur - 1
        mul     byte [es:V_IMG_TETES]
        add     al, dh
        adc     ah, 0
        mov     bh, cl
        mov     cl, [es:V_IMG_SPT]
        xor     ch, ch
        mul     cx
        dec     bh
        add     al, bh
        adc     ah, 0
        mov     cx, ax                  ; dernier secteur dans l'image ?
        add     cl, bl
        adc     ch, 0
        cmp     cx, [es:V_IMG_SECT]
        ja      .hors
        xor     dx, dx
        add     ax, [es:V_IMG_LBA]
        adc     dx, [es:V_IMG_LBA + 2]
        clc
        ret
.inval: mov     ah, 01h
        stc
        ret
.hors:  mov     ah, 04h
        stc
        ret

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
