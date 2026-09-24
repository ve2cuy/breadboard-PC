; HELLO.ASM
; 8088 / MASM
; Affichage uniquement via le BIOS vidéo
; MASM HELLO.ASM;
; LINK HELLO.OBJ;
; EXE2BIN HELLO.EXE HELLO.COM

TITLE   HELLO

CODE SEGMENT
ASSUME CS:CODE,DS:CODE

    ORG     100H

START:
    MOV SI,OFFSET MESSAGE

PRINT:
    LODSB
    OR AL,AL
    JZ DONE

    MOV     AH,0EH
    MOV     BH,0
    INT     10H

    JMP     PRINT


DONE:
    mov ah,4Ch  ; Return to DOS
    mov al,0    ; Exit code 0
    int 21h     ; DOS interrupt

MESSAGE DB 'Hello, world!',13,10,0

CODE ENDS

; Pas supporté pour un .com
;STACK SEGMENT STACK
;DW 64 DUP (?)
;STACK ENDS

    END     START
