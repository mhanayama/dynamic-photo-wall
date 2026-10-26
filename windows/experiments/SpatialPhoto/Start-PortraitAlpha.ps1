param([string]$Photo)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$exe = Join-Path $projectRoot 'release/windows/win-x64/portrait-alpha/PortraitAlpha.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Run Package.ps1 -PortraitAlpha first.' }
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.tools/portrait-alpha/runtime.json'))) { throw 'Run Setup-PortraitAlpha.ps1 first.' }
$arguments = @('--portrait-alpha')
if ($Photo) { $arguments += @('--photo', ('"{0}"' -f (Resolve-Path -LiteralPath $Photo).Path)) }
Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $exe)
