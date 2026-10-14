$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$executable = Join-Path $PSScriptRoot 'artifacts\win-x64\DynamicPhotoWall.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Run scripts\Build.ps1 first.' }
Start-Process -FilePath $executable -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
