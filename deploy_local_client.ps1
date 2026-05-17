param(
    [string]$BuildRoot = "C:\Users\cri\Desktop\rustdesk-1.4.6",
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\UptimeDesk",
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

$candidateDlls = @(
    (Join-Path $BuildRoot "target\release\libuptimedesk.dll"),
    (Join-Path $BuildRoot "flutter\build\windows\x64\runner\Release\libuptimedesk.dll")
)
$candidateClientExes = @(
    (Join-Path $BuildRoot "flutter\build\windows\x64\runner\Release\uptimedesk.exe")
)
$candidateDataDirs = @(
    (Join-Path $BuildRoot "flutter\build\windows\x64\runner\Release\data")
)
$candidateUpdaterExes = @(
    (Join-Path $BuildRoot "target\release\updesk_updater.exe"),
    (Join-Path $BuildRoot "flutter\build\windows\x64\runner\Release\updesk_updater.exe")
)

$sourceDll = $candidateDlls | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sourceDll) {
    throw "libuptimedesk.dll non trovata nei path build attesi."
}
$sourceExe = $candidateClientExes | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sourceExe) {
    throw "uptimedesk.exe non trovato nel path build Flutter atteso."
}
$sourceDataDir = $candidateDataDirs | Where-Object { Test-Path $_ } | Select-Object -First 1
$sourceUpdaterExe = $candidateUpdaterExes | Where-Object { Test-Path $_ } | Select-Object -First 1

$targetDll = Join-Path $InstallDir "libuptimedesk.dll"
$targetExe = Join-Path $InstallDir "uptimedesk.exe"
$targetUpdaterExe = Join-Path $InstallDir "updesk_updater.exe"
$targetDataDir = Join-Path $InstallDir "data"

$proc = Get-Process uptimedesk -ErrorAction SilentlyContinue
if ($proc) {
    Stop-Process -Id $proc.Id -Force
    Start-Sleep -Seconds 2
}

Copy-Item $sourceDll $targetDll -Force
Write-Host "DLL aggiornata: $targetDll" -ForegroundColor Green

Copy-Item $sourceExe $targetExe -Force
Write-Host "Client aggiornato: $targetExe" -ForegroundColor Green

if ($sourceDataDir) {
    if (Test-Path $targetDataDir) {
        Remove-Item -LiteralPath $targetDataDir -Recurse -Force
    }
    Copy-Item $sourceDataDir $targetDataDir -Recurse -Force
    Write-Host "Assets Flutter aggiornati: $targetDataDir" -ForegroundColor Green
}

if ($sourceUpdaterExe) {
    Copy-Item $sourceUpdaterExe $targetUpdaterExe -Force
    Write-Host "Updater aggiornato: $targetUpdaterExe" -ForegroundColor Green
}

if (-not $NoRestart) {
    Start-Process $targetExe
    Write-Host "Client riavviato: $targetExe" -ForegroundColor Green
}
