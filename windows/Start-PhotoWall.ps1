$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$release = Join-Path $projectRoot 'release\windows\win-x64'
$executable = Join-Path $release 'DynamicPhotoWall.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Run windows\scripts\Build.ps1 first.' }
Start-Process -FilePath $executable -WorkingDirectory $release -WindowStyle Hidden
