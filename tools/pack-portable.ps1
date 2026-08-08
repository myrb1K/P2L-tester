# Sestaví portable distribuci P2L Testeru — Windows EXE (+ APK vedle něj).
#
# Od R6 (odstranění lokálního Node serveru) je to jen přejmenování exe a zip:
# appka nosí evidenci ve vlastní SQLite a na server chodí přes HTTPS, takže
# se nic dalšího nepřikládá. Dřív se sem kopírovala složka server\ s Node
# runtime (~100 MB) — proto ten propad velikosti zipu ze 128 na ~30 MB.
#
# Předpoklad: hotové buildy
#   flutter build windows --release
#   flutter build apk --release --split-per-abi   (volitelné, kvůli APK v zipu)
#
# Použití:
#   powershell -ExecutionPolicy Bypass -File tools\pack-portable.ps1
#   powershell -ExecutionPolicy Bypass -File tools\pack-portable.ps1 -SkipZip
#
# Výsledek: dist\P2L-Tester-v<VER>\ + dist\P2L-Tester-v<VER>.zip

param(
    # Kam se distribuce sestaví. Default dist\ v repu (je v .gitignore).
    [string]$OutRoot,
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if ($OutRoot) { $distRoot = $OutRoot } else { $distRoot = Join-Path $repoRoot 'dist' }
New-Item -ItemType Directory -Force -Path $distRoot | Out-Null

# ── verze z main.dart (jediný zdroj pravdy) ─────────────────────────────
$mainDart = Join-Path $repoRoot 'lib\main.dart'
$versionLine = Select-String -Path $mainDart -Pattern "appVersion\s*=\s*'([^']+)'"
if (-not $versionLine) { throw "Nepodařilo se přečíst appVersion z $mainDart" }
$ver = $versionLine.Matches[0].Groups[1].Value
Write-Host "Verze: $ver" -ForegroundColor Cyan

# ── kontroly vstupů ────────────────────────────────────────────────────
if (-not (Test-Path (Join-Path $releaseDir 'p2l_tester.exe'))) {
    throw "Chybí Windows release build. Spusť: flutter build windows --release"
}

# ── cílová složka ──────────────────────────────────────────────────────
$outDir = Join-Path $distRoot "P2L-Tester-v$ver"
if (Test-Path $outDir) {
    Write-Host "Mažu předchozí $outDir" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ── Flutter Release (DLL + data\ jsou nutné, exe samo se nespustí) ──────
Write-Host "Kopíruji Windows Release…"
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $outDir -Recurse -Force
$exeSrc = Join-Path $outDir 'p2l_tester.exe'
$exeDst = Join-Path $outDir "p2l_tester v$ver.exe"
Move-Item -Path $exeSrc -Destination $exeDst -Force

# ── APK vedle Windows složky (arm64-v8a, viz CLAUDE.md) ────────────────
$apkSrc = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
$apkDst = Join-Path $distRoot "P2L-Tester-v$ver.apk"
if (Test-Path $apkSrc) {
    Copy-Item -Path $apkSrc -Destination $apkDst -Force
    Write-Host "APK: $apkDst" -ForegroundColor Cyan
} else {
    Write-Host "APK nenalezeno (build\app\outputs\flutter-apk) — zip bude jen s Windows." -ForegroundColor Yellow
}

# ── zip ────────────────────────────────────────────────────────────────
if (-not $SkipZip) {
    $zipPath = Join-Path $distRoot "P2L-Tester-v$ver.zip"
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

    # Zip obsahuje složku P2L-Tester-v<VER>\ a (pokud existuje) APK vedle ní.
    $staging = Join-Path $distRoot "_zip-staging-v$ver"
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Copy-Item -Path $outDir -Destination $staging -Recurse -Force
    if (Test-Path $apkDst) { Copy-Item -Path $apkDst -Destination $staging -Force }

    Write-Host "Komprimuji do $zipPath…"
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Remove-Item -Recurse -Force $staging

    $zipMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host "Hotovo: $zipPath ($zipMb MB)" -ForegroundColor Green
}

$outMb = [math]::Round(((Get-ChildItem -Recurse -Force $outDir | Measure-Object -Property Length -Sum).Sum / 1MB), 1)
Write-Host "Složka: $outDir ($outMb MB rozbaleno)" -ForegroundColor Green
