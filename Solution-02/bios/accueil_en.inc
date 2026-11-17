; accueil.inc - GENERE par tests/gen_accueil.py (ne pas modifier a la main).
; Ecran d'accueil de la console UART (ANSI, couleurs), termine par 0.
txt_accueil:
            db  1Bh, 5Bh, 32h, 4Ah, 1Bh, 5Bh, 48h, 1Bh, 5Bh, 30h, 3Bh, 39h, 37h, 6Dh, 53h, 6Fh, 6Ch, 75h, 74h, 69h, 6Fh, 6Eh, 2Dh, 30h, 32h, 3Ah, 20h, 61h, 6Eh, 20h, 38h, 30h, 38h, 38h, 20h, 50h, 43h, 20h, 6Fh, 6Eh, 20h, 61h, 20h, 62h, 72h, 65h, 61h, 64h, 62h, 6Fh, 61h, 72h, 64h, 0Dh, 0Ah
            db  0Dh, 0Ah
            db  0Dh, 0Ah
            db  0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 31h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 68h, 74h, 74h, 70h, 73h, 3Ah, 2Fh, 2Fh, 67h, 69h, 74h, 68h, 75h, 62h, 2Eh, 63h, 6Fh, 6Dh, 2Fh, 76h, 65h, 32h, 63h, 75h, 79h, 2Fh, 62h, 72h, 65h, 61h, 64h, 62h, 6Fh, 61h, 72h, 64h, 2Dh, 50h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 31h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 68h, 74h, 74h, 70h, 73h, 3Ah, 2Fh, 2Fh, 67h, 69h, 74h, 68h, 75h, 62h, 2Eh, 63h, 6Fh, 6Dh, 2Fh, 76h, 65h, 32h, 63h, 75h, 79h, 2Fh, 62h, 72h, 65h, 61h, 64h, 62h, 6Fh, 61h, 72h, 64h, 2Dh, 50h, 43h, 2Fh, 74h, 72h, 65h, 65h, 2Fh, 6Dh, 61h, 73h, 74h, 65h, 72h, 2Fh, 53h, 6Fh, 6Ch, 75h, 74h, 69h, 6Fh, 6Eh, 2Dh, 30h, 32h, 0Dh, 0Ah
            db  0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 50h, 50h, 50h, 50h, 50h, 20h, 20h, 20h, 20h, 43h, 43h, 43h, 43h, 43h, 43h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 20h, 20h, 20h, 20h, 50h, 50h, 20h, 20h, 43h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 38h, 38h, 38h, 38h, 38h, 38h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 20h, 20h, 20h, 20h, 50h, 50h, 20h, 20h, 43h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 38h, 38h, 20h, 20h, 38h, 38h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 50h, 50h, 50h, 50h, 50h, 20h, 20h, 20h, 43h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 38h, 38h, 38h, 38h, 38h, 38h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 43h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 38h, 38h, 20h, 20h, 38h, 38h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 43h, 43h, 0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 38h, 38h, 38h, 38h, 38h, 38h, 20h, 20h, 2Fh, 2Fh, 20h, 20h, 50h, 50h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 43h, 43h, 43h, 43h, 43h, 43h, 43h, 0Dh, 0Ah
            db  0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 32h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 38h, 30h, 38h, 38h, 20h, 2Fh, 20h, 4Eh, 45h, 43h, 20h, 56h, 32h, 30h, 20h, 61h, 74h, 20h, 35h, 2Eh, 33h, 33h, 20h, 4Dh, 48h, 7Ah, 2Ch, 20h, 35h, 31h, 32h, 20h, 4Bh, 42h, 20h, 6Fh, 66h, 20h, 52h, 41h, 4Dh, 0Dh, 0Ah
            db  0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 3Bh, 39h, 31h, 6Dh, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 20h, 50h, 43h, 2Dh, 44h, 4Fh, 53h, 20h, 32h, 2Eh, 31h, 20h, 72h, 75h, 6Eh, 73h, 20h, 6Fh, 6Eh, 20h, 74h, 68h, 65h, 20h, 62h, 72h, 65h, 61h, 64h, 62h, 6Fh, 61h, 72h, 64h, 0Dh, 0Ah
            db  0Dh, 0Ah
            db  1Bh, 5Bh, 30h, 6Dh, 0
