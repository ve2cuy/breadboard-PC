# Publie le simulateur sur GitHub Pages (branche gh-pages du depot) :
#   https://ve2cuy.github.io/breadboard-PC/
#   .\publier.ps1            : prepare le site (www/ + images publiques) et pousse la branche gh-pages
#   .\publier.ps1 -Essai     : prepare seulement (dossier affiche), sans pousser
# Images de disque publiees : celles deja suivies par git dans PC-DOS/ (disquettes) + FreeDOS (GPL).
# Les images MS-DOS 6.22 C: (non suivies par git) ne sont pas publiees.
param([switch]$Essai)
# Les deux simulateurs (celui-ci a la racine, Simulateur-Pico dans /pico) partagent la branche
# gh-pages : la publication passe par Simulateur-Pico/publier.ps1, qui les met tous les deux.
& (Join-Path $PSScriptRoot '..\Simulateur-Pico\publier.ps1') -Essai:$Essai
return
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot
$depot = (git rev-parse --show-toplevel).Trim()
$site = Join-Path ([IO.Path]::GetTempPath()) ('s02-pages-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $site | Out-Null

# 1. application (sans les images locales)
Copy-Item www\* $site -Recurse -Exclude images
New-Item -ItemType Directory -Force (Join-Path $site 'images') | Out-Null
$images = @(
  @{ src = 'pcdos2_1.img'; name = 'PCDOS21.IMG'; desc = 'PC-DOS 2.1'; desc_en = 'PC-DOS 2.1'; def = $true },
  @{ src = 'Dos33-d1.IMG'; name = 'DOS33.IMG'; desc = 'PC-DOS 3.3, disquette 1'; desc_en = 'PC-DOS 3.3, disk 1'; def = $true },
  @{ src = 'Dos50-d1-nokeyb.img'; name = 'DOS50.IMG'; desc = 'MS-DOS 5.0, disquette 1 (sans KEYB)'; desc_en = 'MS-DOS 5.0, disk 1 (no KEYB)'; def = $false },
  @{ src = 'Dos62-d1-nokeyb.IMG'; name = 'DOS622.IMG'; desc = 'MS-DOS 6.22, disquette 1 (sans KEYB)'; desc_en = 'MS-DOS 6.22, disk 1 (no KEYB)'; def = $false },
  @{ src = 'FREEDOS_C.IMG'; name = 'FREEDOS.IMG'; desc = 'FreeDOS 1.4, disque dur C: (32 Mo)'; desc_en = 'FreeDOS 1.4, C: hard disk (32 MB)'; def = $false }
)
$index = @()
foreach ($i in $images) {
  $f = Join-Path $depot ('PC-DOS\' + $i.src)
  if (-not (Test-Path $f)) { Write-Warning "absente : $($i.src)"; continue }
  Copy-Item $f (Join-Path $site 'images')
  $index += [ordered]@{ file = $i.src; name = $i.name; desc = $i.desc; desc_en = $i.desc_en; size = (Get-Item $f).Length; def = $i.def }
}
[IO.File]::WriteAllText((Join-Path $site 'images\index.json'), (ConvertTo-Json @($index)), (New-Object Text.UTF8Encoding $false))
New-Item -ItemType File (Join-Path $site '.nojekyll') | Out-Null
Write-Host "Site prepare : $site"
if ($Essai) { return }

# 2. branche gh-pages (historique propre au site, un commit par publication)
$url = (git remote get-url origin).Trim()
Push-Location $site
git init -q
git checkout -q -b gh-pages
git add -A
$rev = (git -C $depot rev-parse --short HEAD).Trim()
git -c user.name="$(git -C $depot config user.name)" -c user.email="$(git -C $depot config user.email)" commit -q -m "Simulateur de Solution-02 (publie depuis $rev)"
git push -f $url gh-pages
$ok = $LASTEXITCODE
Pop-Location
if ($ok -ne 0) { throw 'echec du push de gh-pages' }

# 3. GitHub Pages sur la branche gh-pages (une seule fois)
$env:MSYS_NO_PATHCONV = '1'
wsl gh api repos/ve2cuy/breadboard-PC/pages 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  wsl gh api -X POST repos/ve2cuy/breadboard-PC/pages -f 'source[branch]=gh-pages' -f 'source[path]=/' | Out-Null
}
Write-Host 'Publie : https://ve2cuy.github.io/breadboard-PC/'
