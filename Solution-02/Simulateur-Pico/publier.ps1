# Publie les deux simulateurs sur GitHub Pages (branche gh-pages du depot) :
#   https://ve2cuy.github.io/breadboard-PC/        simulateur de Solution-02 (Simulateur/)
#   https://ve2cuy.github.io/breadboard-PC/pico/   simulateur avec le Pico W (Simulateur-Pico/)
#   .\publier.ps1            : prepare le site et pousse la branche gh-pages
#   .\publier.ps1 -Essai     : prepare seulement (dossier affiche), sans pousser
# Images publiees : disquettes suivies par git (PC-DOS/) et images libres (FreeDOS, FreeDOS + mTCP,
# ELKS). Les images MS-DOS 6.22 C: (hors de git) ne sont pas publiees.
param([switch]$Essai)
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$depot = (git rev-parse --show-toplevel).Trim()
$site = Join-Path ([IO.Path]::GetTempPath()) ('s02-pages-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $site | Out-Null

$disquettes = @(
  @{ src = 'pcdos2_1.img'; name = 'PCDOS21.IMG'; desc = 'PC-DOS 2.1'; desc_en = 'PC-DOS 2.1'; def = $true },
  @{ src = 'Dos33-d1.IMG'; name = 'DOS33.IMG'; desc = 'PC-DOS 3.3, disquette 1'; desc_en = 'PC-DOS 3.3, disk 1'; def = $true },
  @{ src = 'Dos50-d1-nokeyb.img'; name = 'DOS50.IMG'; desc = 'MS-DOS 5.0, disquette 1 (sans KEYB)'; desc_en = 'MS-DOS 5.0, disk 1 (no KEYB)'; def = $false },
  @{ src = 'Dos62-d1-nokeyb.IMG'; name = 'DOS622.IMG'; desc = 'MS-DOS 6.22, disquette 1 (sans KEYB)'; desc_en = 'MS-DOS 6.22, disk 1 (no KEYB)'; def = $false },
  @{ src = 'FREEDOS_C.IMG'; name = 'FREEDOS.IMG'; desc = 'FreeDOS 1.4, disque dur C: (32 Mo)'; desc_en = 'FreeDOS 1.4, C: hard disk (32 MB)'; def = $false }
)
$reseau = @(
  @{ src = 'FDNET_C.IMG'; name = 'FDNET.IMG'; desc = 'FreeDOS 1.4 + mTCP (reseau par le Pico), disque dur C:'; desc_en = 'FreeDOS 1.4 + mTCP (network through the Pico), C: hard disk'; def = $true },
  @{ src = 'ELKS-0.9.2\hd32-minix-s02-reseau.img'; name = 'ELKSNET.IMG'; desc = 'ELKS 0.9.2 (Minix, reseau), disque dur C:'; desc_en = 'ELKS 0.9.2 (Minix, network), C: hard disk'; def = $false }
)

function Copier-Site($www, $dest, $images) {
  New-Item -ItemType Directory -Force $dest | Out-Null
  Copy-Item (Join-Path $www '*') $dest -Recurse -Exclude images
  $dimg = Join-Path $dest 'images'
  New-Item -ItemType Directory -Force $dimg | Out-Null
  $index = @()
  foreach ($i in $images) {
    $f = Join-Path $depot ('PC-DOS\' + $i.src)
    if (-not (Test-Path $f)) { Write-Warning "absente : $($i.src)"; continue }
    $nom = Split-Path $f -Leaf
    Copy-Item $f $dimg
    $index += [ordered]@{ file = $nom; name = $i.name; desc = $i.desc; desc_en = $i.desc_en; size = (Get-Item $f).Length; def = $i.def }
  }
  [IO.File]::WriteAllText((Join-Path $dimg 'index.json'), (ConvertTo-Json @($index)), (New-Object Text.UTF8Encoding $false))
}

# 1. simulateur de Solution-02 a la racine, 2. simulateur avec le Pico W dans /pico
Copier-Site (Join-Path $PSScriptRoot '..\Simulateur\www') $site $disquettes
Copier-Site (Join-Path $PSScriptRoot 'www') (Join-Path $site 'pico') ($disquettes + $reseau)
New-Item -ItemType File (Join-Path $site '.nojekyll') | Out-Null
Write-Host "Site prepare : $site"
if ($Essai) { return }

# branche gh-pages (historique propre au site, un commit par publication)
$url = (git remote get-url origin).Trim()
Push-Location $site
git init -q
git checkout -q -b gh-pages
git add -A
$rev = (git -C $depot rev-parse --short HEAD).Trim()
git -c user.name="$(git -C $depot config user.name)" -c user.email="$(git -C $depot config user.email)" commit -q -m "Simulateurs de Solution-02 et Solution-02 + Pico W (publies depuis $rev)"
git push -f $url gh-pages
$ok = $LASTEXITCODE
Pop-Location
if ($ok -ne 0) { throw 'echec du push de gh-pages' }

$env:MSYS_NO_PATHCONV = '1'
wsl gh api repos/ve2cuy/breadboard-PC/pages 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  wsl gh api -X POST repos/ve2cuy/breadboard-PC/pages -f 'source[branch]=gh-pages' -f 'source[path]=/' | Out-Null
}
Write-Host 'Publie : https://ve2cuy.github.io/breadboard-PC/ et https://ve2cuy.github.io/breadboard-PC/pico/'
