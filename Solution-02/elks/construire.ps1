# Construit ELKS pour Solution-02 depuis Windows, dans un conteneur Docker (Docker Desktop).
# La chaine croisee ia16-elf-gcc est gardee dans le volume Docker elks-s02-cache : la premiere
# construction est longue (~20 min), les suivantes ne refont que ELKS (~5 min).
# Resultat : elks\sortie\elks-solution02-fd360.img (a copier sur la carte SD).
#
#   powershell -ExecutionPolicy Bypass -File construire.ps1
$ErrorActionPreference = 'Stop'
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker ne repond pas : demarrer Docker Desktop.' }
docker run --rm -v "${PSScriptRoot}:/s02" -v elks-s02-cache:/root/cache ubuntu:24.04 `
    bash /s02/construire.sh /s02/sortie
if ($LASTEXITCODE -ne 0) { throw "construction echouee ($LASTEXITCODE)" }
