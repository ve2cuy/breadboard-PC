# Construit le simulateur de Solution-02 (WebAssembly + donnees de l'interface).
#   .\construire.ps1            : compile, essais natifs exclus
#   .\construire.ps1 -Essais    : lance aussi les essais natifs (cargo test)
#   .\construire.ps1 -Lancer    : puis demarre le serveur local (http://localhost:8088/)
param([switch]$Essais, [switch]$Lancer)
$ErrorActionPreference = 'Continue'   # les outils natifs ecrivent sur stderr
Set-Location $PSScriptRoot

# 1. ROM du BIOS (copie de ../bios/build) et index des ROM
New-Item -ItemType Directory -Force www\roms | Out-Null
$roms = @(
  @{ file = 'solution-02-bios.bin'; name = 'BIOS 2.4 français'; name_en = 'BIOS 2.4 French'; lang = 'fr' },
  @{ file = 'solution-02-bios-en.bin'; name = 'BIOS 2.4 anglais'; name_en = 'BIOS 2.4 English'; lang = 'en' },
  @{ file = 'solution-02-diag-sd.bin'; name = 'Diagnostic de la carte SD'; name_en = 'SD card diagnostic' },
  @{ file = 'solution-02-diag-u12.bin'; name = 'Diagnostic du 8255 U12'; name_en = 'U12 8255 diagnostic' },
  @{ file = 'solution-02-diag-8255.bin'; name = 'Diagnostic du 8255 U7'; name_en = 'U7 8255 diagnostic' }
)
$liste = @()
foreach ($r in $roms) {
  $src = Join-Path '..\bios\build' $r.file
  if (Test-Path $src) { Copy-Item $src www\roms\ -Force }
  if (Test-Path (Join-Path 'www\roms' $r.file)) { $liste += $r }
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'www\roms\index.json'), ($liste | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

# 2. Netliste du schema KiCad
$kicad = Get-ChildItem 'C:\Program Files\KiCad\*\bin\kicad-cli.exe' -ErrorAction SilentlyContinue |
  Sort-Object { [version]($_.Directory.Parent.Name + '.0') } -Descending | Select-Object -First 1
if ($kicad) {
  & $kicad.FullName sch export netlist --format kicadxml -o outils\solution02.xml ..\Solution02.kicad_sch 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Warning "kicad-cli : netliste non regeneree (on garde outils\solution02.xml)" }
}
python outils\netlist.py

# 3. WebAssembly
wasm-pack build --target web --out-dir www/pkg --release --no-typescript
if ($LASTEXITCODE -ne 0) { throw 'wasm-pack a echoue' }
Remove-Item www\pkg\.gitignore, www\pkg\package.json, www\pkg\README.md -ErrorAction SilentlyContinue

# 4. Essais
if ($Essais) {
  cargo test --release
  if ($LASTEXITCODE -ne 0) { throw 'essais en echec' }
}

if ($Lancer) { python outils\serveur.py }
