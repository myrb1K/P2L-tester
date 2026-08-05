# Sestaví portable distribuci P2L Testeru — Windows EXE + přiložený Node
# server, aby appka umožnila práci s databází jednotek bez ruční instalace
# Node.js a bez `npm start`.
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
#
# Co se do server\ NEKOPÍRUJE a proč:
#   .env      — obsahuje JWT secret a admin heslo; portable režim si secret
#               generuje sám (SharedPreferences) a předává procesu jako env
#   data\     — databáze; portable ji drží v %APPDATA%\P2L-Tester\server-data,
#               aby rozbalení nové verze nepřepsalo units.db
#   test\     — testy nejsou k běhu potřeba

param(
    # Kam se distribuce sestaví. Default dist\ v repu (je v .gitignore).
    [string]$OutRoot,
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$serverSrc = Join-Path $repoRoot 'server'
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
if (-not (Test-Path (Join-Path $serverSrc 'node_modules'))) {
    throw "Chybí server\node_modules. Spusť: cd server; npm install"
}

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) {
    throw "Node.js nenalezen v PATH — je potřeba pro přiložení runtime do distribuce."
}
$nodeVer = (& $nodeExe -v)
Write-Host "Node runtime: $nodeExe ($nodeVer)" -ForegroundColor Cyan
Write-Host "  POZOR: node_modules obsahuje native moduly (better-sqlite3, bcrypt)" -ForegroundColor DarkGray
Write-Host "  zkompilované pro tuto major verzi Node — přikládá se proto tento runtime." -ForegroundColor DarkGray

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

# ── server ─────────────────────────────────────────────────────────────
Write-Host "Kopíruji server + Node runtime…"
$serverDst = Join-Path $outDir 'server'
New-Item -ItemType Directory -Force -Path $serverDst | Out-Null

foreach ($item in @('server.js', 'package.json')) {
    Copy-Item -Path (Join-Path $serverSrc $item) -Destination $serverDst -Force
}
foreach ($dir in @('db', 'routes', 'node_modules')) {
    Copy-Item -Path (Join-Path $serverSrc $dir) -Destination $serverDst -Recurse -Force
}
Copy-Item -Path $nodeExe -Destination (Join-Path $serverDst 'node.exe') -Force

# Pojistka: kdyby se do node_modules nebo db\ někdy dostal .env / DB soubor.
Get-ChildItem -Path $serverDst -Recurse -Force -Include '.env', '*.db', '*.db-shm', '*.db-wal' |
    ForEach-Object {
        Write-Host "  vyřazuji $($_.FullName.Substring($outDir.Length + 1))" -ForegroundColor Yellow
        Remove-Item -Force $_.FullName
    }

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
