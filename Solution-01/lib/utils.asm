; ============================================================
; utils.asm
; delay_ms_proc: routine reelle derriere la macro delay_ms (voir
; include/delay.inc). Renommee "_proc" pour ne pas entrer en
; collision avec le nom de la macro (NASM les distingue, mais la
; separation macro/procedure est plus claire avec des noms
; differents).
; ============================================================
%ifndef UTILS_ASM
%define UTILS_ASM

INNER_MS        equ     265     ; ~1 ms a 4,77 MHz (approximatif)

; Entree: CX = nombre de millisecondes a attendre (place par la
; macro delay_ms). Detruit BX/CX (comme l'ancienne routine inline).
delay_ms_proc:
        push    bx
        push    cx
.outer:
        mov     bx, INNER_MS
.inner:
        dec     bx
        jnz     .inner
        loop    .outer
        pop     cx
        pop     bx
        ret

%endif ; UTILS_ASM
