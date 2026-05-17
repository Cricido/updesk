# UptimeDesk - Script di rilascio
# Uso: .\release.ps1 -Version "1.0.2" [-Notes "Descrizione aggiornamento"] [-Force] [-Channel stable|recommended|beta]

param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Notes = "",
    [switch]$Force,
    [ValidateSet("stable", "recommended", "beta")][string]$Channel = "stable"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$flutter = "C:\Users\cri\Desktop\flutter\flutter\bin\flutter.bat"
$iscc = "C:\Users\cri\AppData\Local\Programs\Inno Setup 6\ISCC.exe"
$env:VCPKG_ROOT = "C:\vcpkg"
$manifestSigner = "$root\tools\update_manifest_sign.py"
$manifestPrivateKey = "$root\.secrets\updesk-update-sign-private.key"
$manifestPublicKey = "$root\res\update_manifest_public_key.txt"

Write-Host "`n=== UptimeDesk Release $Version [$Channel] ===" -ForegroundColor Cyan

function Test-VersionString {
    param([Parameter(Mandatory)][string]$InputVersion)
    return $InputVersion -match '^\d+\.\d+\.\d+$'
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$Path
    )
    $json = $Data | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Write-UpdateManifest {
    param(
        [Parameter(Mandatory)][string]$ManifestChannel,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ManifestVersion,
        [Parameter(Mandatory)][string]$ManifestSha256,
        [Parameter(Mandatory)][bool]$Mandatory,
        [Parameter(Mandatory)][string]$Changelog
    )
    Write-JsonFile -Path $ManifestPath -Data @{
      channel = $ManifestChannel
      version = $ManifestVersion
      url = "https://updesk.uptimeservice.it/releases/windows/updesk-$ManifestVersion.exe"
      sha256 = $ManifestSha256
      mandatory = $Mandatory
      min_supported = "1.0.0"
      changelog = $(if ([string]::IsNullOrWhiteSpace($Changelog)) { "Maintenance release" } else { $Changelog })
    }
}

if (-not (Test-VersionString -InputVersion $Version)) {
    throw "Formato versione non valido: usare X.Y.Z"
}
if (-not (Test-Path $manifestSigner)) {
    throw "Tool firma manifest non trovato: $manifestSigner"
}
if (-not (Test-Path $manifestPrivateKey)) {
    throw "Chiave privata firma manifest non trovata: $manifestPrivateKey"
}
if (-not (Test-Path $manifestPublicKey)) {
    throw "Chiave pubblica manifest non trovata: $manifestPublicKey"
}

# 1. Aggiorna versione in Cargo.toml, src/version.rs e flutter/pubspec.yaml
Write-Host "`n[1/6] Aggiorno versione in Cargo.toml, src/version.rs e pubspec.yaml..." -ForegroundColor Yellow
$cargoToml = "$root\Cargo.toml"
$cargoContent = Get-Content $cargoToml -Raw
$cargoContent = $cargoContent -replace '(?m)^version = "\d+\.\d+\.\d+"', "version = `"$Version`""
Set-Content $cargoToml $cargoContent -NoNewline

$versionRs = "$root\src\version.rs"
if (Test-Path $versionRs) {
    $versionRsContent = Get-Content $versionRs -Raw
    $versionRsContent = $versionRsContent -replace '(?m)^pub const VERSION: &str = "\d+\.\d+\.\d+";', "pub const VERSION: &str = `"$Version`";"
    Set-Content $versionRs $versionRsContent -NoNewline
}

$pubspec = "$root\flutter\pubspec.yaml"
$content = Get-Content $pubspec -Raw
$content = $content -replace 'version: \d+\.\d+\.\d+\+\d+', "version: $Version+1"
Set-Content $pubspec $content -NoNewline

# 2. Build Rust relay/client library + updater
Write-Host "[2/6] Build Rust relay/client library + updater..." -ForegroundColor Yellow
Set-Location $root
cargo build --features flutter --lib --release
if ($LASTEXITCODE -ne 0) { Write-Error "Build Rust libreria fallita"; exit 1 }
cargo build --features flutter --release --bin updesk_updater
if ($LASTEXITCODE -ne 0) { Write-Error "Build updater fallita"; exit 1 }

# 3. Build Flutter
Write-Host "[3/6] Build Flutter release..." -ForegroundColor Yellow
Set-Location "$root\flutter"
& $flutter build windows --release
if ($LASTEXITCODE -ne 0) { Write-Error "Build Flutter fallita"; exit 1 }

$updaterExe = "$root\target\release\updesk_updater.exe"
$flutterReleaseDir = "$root\flutter\build\windows\x64\runner\Release"
if (Test-Path $updaterExe) {
    Copy-Item $updaterExe (Join-Path $flutterReleaseDir "updesk_updater.exe") -Force
}

# 4. Compila installer full
Write-Host "[4/6] Compilo installer full..." -ForegroundColor Yellow
Set-Location $root
$issContent = Get-Content "$root\uptimedesk_full_setup.iss" -Raw
$issContent = $issContent -replace '#define MyAppVersion "\d+\.\d+\.\d+"', "#define MyAppVersion `"$Version`""
$issContent = $issContent -replace 'OutputBaseFilename=UptimeDesk-[\d.]+-x86_64-Setup', "OutputBaseFilename=UptimeDesk-$Version-x86_64-Setup"
Set-Content "$root\uptimedesk_full_setup.iss" $issContent -NoNewline
& $iscc "$root\uptimedesk_full_setup.iss"
if ($LASTEXITCODE -ne 0) { Write-Error "Compilazione installer full fallita"; exit 1 }

# 5. Compila installer assistenza
Write-Host "[5/6] Compilo installer assistenza..." -ForegroundColor Yellow
$assistIssContent = Get-Content "$root\uptimedesk_setup.iss" -Raw
$assistIssContent = $assistIssContent -replace '#define MyAppVersion "\d+\.\d+\.\d+"', "#define MyAppVersion `"$Version`""
Set-Content "$root\uptimedesk_setup.iss" $assistIssContent -NoNewline
& $iscc "$root\uptimedesk_setup.iss"
if ($LASTEXITCODE -ne 0) { Write-Error "Compilazione installer assistenza fallita"; exit 1 }

# 6. Calcola SHA256 e aggiorna JSON
Write-Host "[6/6] Aggiorno manifest update..." -ForegroundColor Yellow

$fullExe = "$root\UptimeDesk-$Version-x86_64-Setup.exe"
$assistExe = "$root\UptimeDesk-Assistenza-Setup.exe"

if (-not (Test-Path $fullExe)) { throw "Installer full non trovato: $fullExe" }
if (-not (Test-Path $assistExe)) { throw "Installer assistenza non trovato: $assistExe" }

$hashFull = (Get-FileHash $fullExe -Algorithm SHA256).Hash.ToLower()
$hashAssist = (Get-FileHash $assistExe -Algorithm SHA256).Hash.ToLower()

$forceBool = $Force.IsPresent

Write-JsonFile -Path "$root\version.json" -Data @{
  version = $Version
  url = "https://updesk.uptimeservice.it/download/UptimeDesk-$Version-x86_64-Setup.exe"
  sha256 = $hashFull
  force = $forceBool
  notes_it = $Notes
}

Write-JsonFile -Path "$root\version-assistenza.json" -Data @{
  version = $Version
  url = "https://updesk.uptimeservice.it/download/UptimeDesk-Assistenza-Setup.exe"
  sha256 = $hashAssist
  force = $forceBool
  notes_it = $Notes
}

Write-UpdateManifest -ManifestChannel "stable" -ManifestPath "$root\stable.json" -ManifestVersion $Version -ManifestSha256 $hashFull -Mandatory $forceBool -Changelog $Notes

$channelManifestPath = "$root\$Channel.json"
if ($Channel -ne "stable") {
    Write-UpdateManifest -ManifestChannel $Channel -ManifestPath $channelManifestPath -ManifestVersion $Version -ManifestSha256 $hashFull -Mandatory $forceBool -Changelog $Notes
}

& python $manifestSigner sign --private $manifestPrivateKey --manifest "$root\stable.json"
if ($LASTEXITCODE -ne 0) { Write-Error "Firma stable.json fallita"; exit 1 }
& python $manifestSigner verify --public $manifestPublicKey --manifest "$root\stable.json"
if ($LASTEXITCODE -ne 0) { Write-Error "Verifica stable.json fallita"; exit 1 }

if ($Channel -ne "stable") {
    & python $manifestSigner sign --private $manifestPrivateKey --manifest $channelManifestPath
    if ($LASTEXITCODE -ne 0) { Write-Error "Firma $Channel.json fallita"; exit 1 }
    & python $manifestSigner verify --public $manifestPublicKey --manifest $channelManifestPath
    if ($LASTEXITCODE -ne 0) { Write-Error "Verifica $Channel.json fallita"; exit 1 }
}

Write-Host "`n=== Release $Version completata! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Manifest generati:" -ForegroundColor Cyan
Write-Host "  stable.json"
if ($Channel -ne "stable") {
    Write-Host "  $Channel.json"
}
Write-Host ""
Write-Host "File da caricare su uptimeservice.it:" -ForegroundColor Cyan
Write-Host "  /api/v1/update/stable.json"
if ($Channel -ne "stable") {
    Write-Host "  /api/v1/update/$Channel.json"
}
Write-Host "  /releases/windows/updesk-$Version.exe"
Write-Host ""
Write-Host "SHA256 full:      $hashFull"
Write-Host "SHA256 assistenza: $hashAssist"
