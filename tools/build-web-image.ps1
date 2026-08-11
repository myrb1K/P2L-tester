# Sestaví Docker image webové varianty P2L Testeru a volitelně ji pushne
# do registry (odkud si ji stáhne Portainer na serveru).
#
# Build běží celý uvnitř Dockeru (Dockerfile.web): stage s Flutter SDK udělá
# `flutter build web`, výsledek převezme nginx. Lokální Flutter se nepoužívá,
# takže je jedno, co je na stroji nainstalované.
#
# Použití:
#   powershell -ExecutionPolicy Bypass -File tools\build-web-image.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build-web-image.ps1 -Registry registry.firma.cz -Push
#   powershell -ExecutionPolicy Bypass -File tools\build-web-image.ps1 -ApiBase https://jiny-server/api
#
# Výsledek: image <registry/>p2l-tester-web:<VER> a :latest

param(
    # Prefix registry (bez lomítka na konci). Bez něj vznikne jen lokální image.
    [string]$Registry,

    # Kam appka posílá požadavky na backend. Default `/api` = stejný origin
    # (nginx v image proxyuje /api/ na kontejner s API) — měnit jen když web
    # a API poběží na různých adresách. Zabudovává se do buildu natvrdo.
    [string]$ApiBase = '/api',

    # Podcesta, ze které se web servíruje. Musí začínat i končit lomítkem.
    [string]$BaseHref = '/',

    # Po úspěšném buildu rovnou `docker push` (vyžaduje `docker login`).
    [switch]$Push,

    # Build bez použití cache — pro případ, že se změnil base image.
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# -- verze z main.dart (jediny zdroj pravdy, stejne jako pack-portable) ---
$mainDart = Join-Path $repoRoot 'lib\main.dart'
$versionLine = Select-String -Path $mainDart -Pattern "appVersion\s*=\s*'([^']+)'"
if (-not $versionLine) { throw "Nepodařilo se přečíst appVersion z $mainDart" }
$ver = $versionLine.Matches[0].Groups[1].Value

if ($Registry) { $name = "$($Registry.TrimEnd('/'))/p2l-tester-web" } else { $name = 'p2l-tester-web' }
$tagVer = "${name}:$ver"
$tagLatest = "${name}:latest"

Write-Host "Verze:     $ver"      -ForegroundColor Cyan
Write-Host "Image:     $tagVer"   -ForegroundColor Cyan
Write-Host "API base:  $ApiBase"  -ForegroundColor Cyan
Write-Host "Base href: $BaseHref" -ForegroundColor Cyan

# Cross-origin nasazení (web a API na jiné adrese) potřebuje ještě jednu věc,
# kterou build zařídit nemůže — povolený origin na straně API. Bez něj request
# odejde, odpověď dorazí a prohlížeč ji zahodí, což vypadá jako rozbitá appka.
if ($ApiBase -match '^https?://') {
    $apiOrigin = ([uri]$ApiBase).GetLeftPart([System.UriPartial]::Authority)
    Write-Host ''
    Write-Host "POZOR: API je na jiném originu ($apiOrigin)." -ForegroundColor Yellow
    Write-Host '       Na serveru musí být v .env.docker vyplněné CORS_ORIGIN s adresou webu' -ForegroundColor Yellow
    Write-Host '       (např. CORS_ORIGIN=https://p2lweb.domena.cz) a `api` restartovaný.' -ForegroundColor Yellow
    Write-Host '       Do CSP se origin propíše sám. Viz server/README.md.' -ForegroundColor Yellow
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker nenalezen v PATH. Build image potřebuje Docker (Desktop nebo engine)."
}

# -- build ---------------------------------------------------------------
# Kontext je root repa — Dockerfile.web potřebuje Dart zdroje, web\ a assety.
# Co se do kontextu nemá dostat, řeší .dockerignore.
$dockerArgs = @(
    'build',
    '-f', (Join-Path $repoRoot 'Dockerfile.web'),
    '--build-arg', "AUTH_API_BASE=$ApiBase",
    '--build-arg', "BASE_HREF=$BaseHref",
    '-t', $tagVer,
    '-t', $tagLatest
)
if ($NoCache) { $dockerArgs += '--no-cache' }
$dockerArgs += $repoRoot

Write-Host ''
Write-Host "docker $($dockerArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ''
& docker @dockerArgs
if ($LASTEXITCODE -ne 0) { throw "docker build selhal (kód $LASTEXITCODE)." }

$size = (& docker image inspect $tagVer --format '{{.Size}}')
if ($LASTEXITCODE -eq 0 -and $size) {
    $sizeMb = [math]::Round([int64]$size / 1MB, 1)
    Write-Host "Hotovo: $tagVer ($sizeMb MB)" -ForegroundColor Green
} else {
    Write-Host "Hotovo: $tagVer" -ForegroundColor Green
}

# -- push ----------------------------------------------------------------
if ($Push) {
    if (-not $Registry) { throw "-Push bez -Registry nemá kam pushovat." }
    foreach ($t in @($tagVer, $tagLatest)) {
        Write-Host "Pushuji $t ..."
        & docker push $t
        if ($LASTEXITCODE -ne 0) { throw "docker push $t selhal (kód $LASTEXITCODE). Přihlášen? Zkus: docker login $Registry" }
    }
    Write-Host 'Pushnuto. Na serveru: docker compose --env-file .env.docker pull web; docker compose --env-file .env.docker up -d web' -ForegroundColor Green
}
