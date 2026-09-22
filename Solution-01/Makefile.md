# Comment fonctionne le Makefile

## Variables

- `NASM` / `NASMFLAGS` : l'assembleur et ses options (`-f bin` = sortie binaire brute, sans format d'exécutable)
- `ROM_BIN`, `LCD_BIN`, `UART_BIN`, `UTILS_BIN` : les chemins des `.bin` produits
- `ROM_OUT` : destination finale de la ROM sur le partage réseau (`Z:\Partage\Alain\rom.bin`)
- `CHECK_DIR` : dossier local `build/check` pour les `.bin` jetables de `check-modules` (évite `/tmp`, peu fiable quand make natif Windows invoque le shell MSYS de Git)

## Les cibles (targets)

### `all`

Cible par défaut si on tape juste `make`. Dépend de `rom` et `lib` — construit tout.

### `rom`

1. `$(ROM_BIN)` est une règle avec ses propres dépendances (`solution-01.asm` + tous les `.inc`/`.asm` inclus) → si l'un d'eux est plus récent que `solution-01.bin`, make relance `nasm` pour le régénérer.
2. Une fois `solution-01.bin` prêt, la cible `rom` elle-même crée le dossier `Z:\Partage\Alain\` si besoin (`mkdir -p`) et copie le binaire là-bas (`cp`).

C'est le principe de base de make : chaque cible peut avoir des **prérequis** (fichiers listés après `:`), et sa recette (les lignes indentées en dessous) ne s'exécute que si la cible n'existe pas encore ou est plus vieille qu'un de ses prérequis. Ça évite de tout réassembler à chaque fois.

### `lib`

Construit les modules individuels (`lcd.bin`, `uart.bin`, `utils.bin`, `lcd_i2c.bin`, `ps2.bin`, `tiny_basic.bin`, `basic.bin`), chacun avec ses propres dépendances. Le `| lib/bin` après les deux-points est un **prérequis "order-only"** : ça garantit que le dossier `lib/bin` existe avant d'écrire dedans, mais sans forcer un réassemblage si le dossier est juste "plus récent" que le `.bin`.

### `check-modules`

Assemble chaque module de la lib **séparément** (pas juste via `solution-01.asm` qui les inclut tous) pour vérifier qu'ils compilent chacun de façon autonome. Utilise le même mécanisme `| $(CHECK_DIR)` pour créer `build/check` au besoin.

### `check`

Dépend de `$(ROM_BIN)` (donc réassemble si besoin), puis appelle `check_rom.py` pour valider la structure du binaire (taille, vecteur de reset, signature).

### `test`

Lance les bancs d'essai sous émulateur (Unicorn, `pip install unicorn numpy`) : `tests/tb_test.py` (Tiny BASIC), `tests/fl_test.py` (bibliothèque flottante du BASIC) et `tests/basic_test.py` (BASIC « GW-BASIC-like », environ 2 minutes ; sources listées dans `BAS_SRC`). Le premier assemble `tests/tb_test.asm` (avec `lib/tiny_basic.asm`, en mode « stubs » puis avec les vraies routines `uart_*`) dans `build/` et vérifie les sorties BASIC, le retour au menu et les zones de RAM écrites. Non lancée par `all`/`check` (dépendance Python facultative).

### `clean`

Supprime tous les `.bin` générés et le dossier `build/check`.

## Utilisation typique

```sh
make                 # = make all : construit tout
make rom             # juste la ROM + copie vers Z:
make lib             # juste les modules
make check           # assemble la ROM puis la valide
make check-modules   # teste que chaque module s'assemble seul
make map             # plan (MAP) de la ROM : zones, tailles, espace libre (rom_map.py)
make clean           # nettoie
```

## Point important

Il faut toujours lancer `make` **depuis le dossier `Solution-01/`**, jamais depuis un sous-dossier, car tous les chemins (relatifs) et les `%include` dans les `.asm` en dépendent.
