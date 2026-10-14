$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$executable = Join-Path $projectRoot 'artifacts\win-x64\DynamicPhotoWall.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Run windows\scripts\Build.ps1 first.' }
Start-Process -FilePath $executable -WorkingDirectory $projectRoot -WindowStyle Hidden
