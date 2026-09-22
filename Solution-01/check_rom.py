#!/usr/bin/env python3
# ============================================================
# check_rom.py
# Verification structurelle rapide d'une ROM assemblee pour ce
# montage (VE2CUY, 8088/8086, ROM 256K a l'adresse physique
# C0000h-FFFFFh). Formalise les verifications manuelles faites au
# fil du projet:
#   - taille exacte: 262144 octets (256 Ko)
#   - vecteur de reset a l'offset 03FFF0h (= physique FFFF0h,
#     l'adresse ou le 8088 saute au demarrage): EA 00 00 00 C0
#     (jmp far 0C000h:0000h -> START)
#   - signature ' VE2CUY 26' juste apres, a l'offset 03FFF5h
#
# Usage: python3 check_rom.py chemin/vers/solution-01.bin
# Sortie: 0 = OK, 1 = au moins une verification a echoue.
# ============================================================
import sys

EXPECTED_SIZE = 0x40000            # 256 Ko
RESET_VECTOR_OFFSET = 0x3FFF0
RESET_VECTOR_BYTES = bytes([0xEA, 0x00, 0x00, 0x00, 0xC0])
SIGNATURE_OFFSET = RESET_VECTOR_OFFSET + len(RESET_VECTOR_BYTES)
SIGNATURE_BYTES = b' VE2CUY 26'


def check_rom(path):
    ok = True

    with open(path, 'rb') as f:
        data = f.read()

    size = len(data)
    if size == EXPECTED_SIZE:
        print(f"[OK]   Taille: {size} octets ({size // 1024} Ko)")
    else:
        print(f"[FAIL] Taille: {size} octets - attendu {EXPECTED_SIZE} "
              f"({EXPECTED_SIZE // 1024} Ko)")
        ok = False
        # Sans la bonne taille, les offsets ci-dessous n'ont plus de
        # sens - on arrete la verification ici.
        return ok

    actual_vector = data[RESET_VECTOR_OFFSET:RESET_VECTOR_OFFSET + len(RESET_VECTOR_BYTES)]
    if actual_vector == RESET_VECTOR_BYTES:
        print(f"[OK]   Vecteur de reset @ {RESET_VECTOR_OFFSET:06X}h: "
              f"{actual_vector.hex(' ').upper()} (jmp 0C000h:0000h)")
    else:
        print(f"[FAIL] Vecteur de reset @ {RESET_VECTOR_OFFSET:06X}h: "
              f"{actual_vector.hex(' ').upper()} - attendu "
              f"{RESET_VECTOR_BYTES.hex(' ').upper()}")
        ok = False

    actual_sig = data[SIGNATURE_OFFSET:SIGNATURE_OFFSET + len(SIGNATURE_BYTES)]
    if actual_sig == SIGNATURE_BYTES:
        print(f"[OK]   Signature  @ {SIGNATURE_OFFSET:06X}h: {actual_sig!r}")
    else:
        print(f"[FAIL] Signature  @ {SIGNATURE_OFFSET:06X}h: {actual_sig!r} - "
              f"attendu {SIGNATURE_BYTES!r}")
        ok = False

    return ok


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} chemin/vers/solution-01.bin")
        sys.exit(2)

    path = sys.argv[1]
    ok = check_rom(path)

    print()
    if ok:
        print("*** Toutes les verifications ont reussi ***")
        sys.exit(0)
    else:
        print("*** Au moins une verification a echoue ***")
        sys.exit(1)


if __name__ == '__main__':
    main()
