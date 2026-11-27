; SETTIME.ASM - date et heure du DOS d'apres la RTC de la Black Pill
; (pont de Solution-01, lue par INT 1Ah AH=04h et 02h du BIOS de la ROM)
;   MASM SETTIME;   LINK SETTIME;   SETTIME
; Tout DOS: INT 21h 2Bh/2Dh/09h (DOS 1.0+); fin par
; RET lointain vers PSP:0000 (INT 20h), ou 4Ch (DOS 2+)
; pour ERRORLEVEL: 0 = regle, 1 = pas de RTC.
CODE    SEGMENT
        ASSUME  CS:CODE,DS:CODE
START   PROC    FAR
        PUSH    DS              ; PSP:0000 = INT 20h
        XOR     AX,AX
        PUSH    AX
        PUSH    CS
        POP     DS
        XOR     CX,CX
        XOR     DX,DX
        MOV     AH,4            ; date: CX siecle/annee,
        INT     1AH             ; DH mois, DL jour (BCD)
        JC      NORTC1
        OR      CX,CX
        JNZ     OK1
NORTC1: JMP     NORTC           ; (saut conditionnel: 127 octets)
OK1:
        MOV     DATE,DX
        MOV     YEAR,CX
        MOV     AH,2            ; heure: CH h, CL min,
        INT     1AH             ; DH s (BCD)
        JC      NORTC1
        MOV     HMIN,CX
        MOV     SEC,DH
        MOV     AL,BYTE PTR YEAR+1
        CALL    BIN
        MOV     BL,100
        MUL     BL
        MOV     CX,AX
        MOV     AL,BYTE PTR YEAR
        CALL    BIN
        ADD     CX,AX           ; CX = annee
        MOV     AL,BYTE PTR DATE+1
        CALL    BIN
        MOV     DH,AL           ; mois
        MOV     AL,BYTE PTR DATE
        CALL    BIN
        MOV     DL,AL           ; jour
        MOV     AH,2BH
        INT     21H
        OR      AL,AL
        JNZ     NORTC
        MOV     AL,BYTE PTR HMIN+1
        CALL    BIN
        MOV     CH,AL
        MOV     AL,BYTE PTR HMIN
        CALL    BIN
        MOV     CL,AL
        MOV     AL,SEC
        CALL    BIN
        MOV     DH,AL
        XOR     DL,DL
        MOV     AH,2DH
        INT     21H
        OR      AL,AL
        JNZ     NORTC
        MOV     DX,OFFSET MSG
        MOV     AH,9
        INT     21H
        MOV     AL,BYTE PTR DATE
        CALL    BCD
        MOV     AL,'-'
        CALL    PUTC
        MOV     AL,BYTE PTR DATE+1
        CALL    BCD
        MOV     AL,'-'
        CALL    PUTC
        MOV     AL,BYTE PTR YEAR+1
        CALL    BCD
        MOV     AL,BYTE PTR YEAR
        CALL    BCD
        MOV     AL,' '
        CALL    PUTC
        MOV     AL,BYTE PTR HMIN+1
        CALL    BCD
        MOV     AL,':'
        CALL    PUTC
        MOV     AL,BYTE PTR HMIN
        CALL    BCD
        MOV     AL,':'
        CALL    PUTC
        MOV     AL,SEC
        CALL    BCD
        MOV     DX,OFFSET CRLF
        XOR     BL,BL
        JMP     SHORT FIN
NORTC:  MOV     DX,OFFSET ERR
        MOV     BL,1
FIN:    MOV     AH,9
        INT     21H
        MOV     AH,30H          ; DOS 1: AL = 0
        INT     21H
        OR      AL,AL
        JZ      FIN1
        MOV     AL,BL
        MOV     AH,4CH
        INT     21H
FIN1:   RET
START   ENDP
; BIN: AL (BCD) -> AX (binaire)
BIN     PROC    NEAR
        PUSH    CX
        MOV     AH,AL
        AND     AL,0FH
        MOV     CL,4
        SHR     AH,CL
        AAD
        POP     CX
        RET
BIN     ENDP
; BCD: affiche AL (BCD), deux chiffres
BCD     PROC    NEAR
        PUSH    AX
        MOV     CL,4
        SHR     AL,CL
        CALL    DIG
        POP     AX
        AND     AL,0FH
DIG:    ADD     AL,'0'
PUTC:   MOV     DL,AL
        MOV     AH,2
        INT     21H
        RET
BCD     ENDP
DATE    DW      0
YEAR    DW      0
HMIN    DW      0
SEC     DB      0
MSG     DB      'SETTIME: $'
CRLF    DB      ' (RTC)',13,10,'$'
ERR     DB      'SETTIME: pas de RTC / no RTC',13,10,'$'
CODE    ENDS
STACK   SEGMENT STACK
        DW      64 DUP (?)
STACK   ENDS
        END     START
