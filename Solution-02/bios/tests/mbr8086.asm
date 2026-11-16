; =============================================================================
; mbr8086.asm - code d'amorce d'un MBR pour le 8088 (Solution-02, images de disque dur
; de la carte SD). Charge le secteur d'amorce de la partition active (lecture CHS par
; INT 13h) en 0000:7C00 et y saute avec DL = lecteur et DS:SI = l'entree de la partition
; (convention du PC). Sans partition active ou en cas d'erreur : message, puis INT 18h.
;   nasm -f bin -o build/mbr8086.bin tests/mbr8086.asm   (446 octets au plus)
; =============================================================================
        bits    16
        cpu     8086
        org     0600h

debut:
        cli
        xor     ax, ax
        mov     ss, ax
        mov     sp, 7C00h
        mov     ds, ax
        mov     es, ax
        sti
        cld
        mov     si, 7C00h               ; se deplace en 0000:0600 (7C00 recevra l'amorce)
        mov     di, 0600h
        mov     cx, 256
        rep     movsw
        jmp     0000h:suite
suite:
        mov     [lecteur], dl
        mov     si, 07BEh               ; table des partitions
        mov     cx, 4
.p:     cmp     byte [si], 80h
        je      .active
        add     si, 16
        loop    .p
        mov     si, txt_aucune
        jmp     erreur
.active:
        mov     di, 3                   ; 3 essais
.lit:   mov     dl, [lecteur]
        mov     dh, [si + 1]            ; tete
        mov     cx, [si + 2]            ; cylindre et secteur
        mov     bx, 7C00h
        mov     ax, 0201h
        push    si
        int     13h
        pop     si
        jnc     .lu
        xor     ah, ah                  ; reinitialisation, puis nouvel essai
        int     13h
        dec     di
        jnz     .lit
        mov     si, txt_lecture
        jmp     erreur
.lu:    cmp     word [7DFEh], 0AA55h
        je      .saute
        mov     si, txt_amorce
        jmp     erreur
.saute: mov     dl, [lecteur]
        jmp     0000h:7C00h

erreur: lodsb
        or      al, al
        jz      .fin
        mov     ah, 0Eh
        mov     bx, 7
        int     10h
        jmp     erreur
.fin:   int     18h
        jmp     $

lecteur:        db      80h
txt_aucune:     db      'Pas de partition active', 13, 10, 0
txt_lecture:    db      'Erreur de lecture du disque', 13, 10, 0
txt_amorce:     db      'Partition sans systeme', 13, 10, 0
