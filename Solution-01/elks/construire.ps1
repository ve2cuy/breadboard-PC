# Construit ELKS pour Solution-01 depuis Windows, dans un conteneur Docker (Docker Desktop), avec les
# sources d'ELKS de Solution-02 et la chaine croisee gardee dans le volume elks-s02-cache.
# Resultat : elks\sortie\elks-solution01-fd360.img (a copier sur la flash du pont, USB Disk -> ON).
#
#   powershell -ExecutionPolicy Bypass -File construire.ps1
$ErrorActionPreference = 'Stop'
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker ne repond pas : demarrer Docker Desktop.' }
$s02 = (Resolve-Path "$PSScriptRoot\..\..\Solution-02\elks\src").Path
docker run --rm -v "${PSScriptRoot}:/s01" -v "${s02}:/s02src" -v elks-s02-cache:/root/cache ubuntu:24.04 `
    bash /s01/construire.sh /s02src /s01/sortie
if ($LASTEXITCODE -ne 0) { throw "construction echouee ($LASTEXITCODE)" }
