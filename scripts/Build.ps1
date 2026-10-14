param([switch]$Test, [switch]$DesktopTest)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$sdk = Join-Path $projectRoot '.tools\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'dotnet' }
if (Test-Path -LiteralPath '.tools\packages') { $env:NUGET_PACKAGES = Join-Path $projectRoot '.tools\packages' }
& $sdk publish 'src\DynamicPhotoWall\DynamicPhotoWall.csproj' -c Release -r win-x64 --self-contained true -o 'artifacts\win-x64' --nologo
if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
$release = Join-Path $projectRoot 'artifacts\win-x64'
Copy-Item -LiteralPath 'README.md', 'THIRD-PARTY-NOTICES.md' -Destination $release -Force
New-Item -ItemType Directory -Path (Join-Path $release 'docs') -Force | Out-Null
Copy-Item -LiteralPath 'docs\ARCHITECTURE.md', 'docs\TEST-RESULTS.md' -Destination (Join-Path $release 'docs') -Force
New-Item -ItemType Directory -Path (Join-Path $release 'photos') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $release 'photos\README.txt') -Value 'Place your JPEG, PNG and WebP photos here, or add another folder in Photos settings.' -Encoding UTF8
$sdkRoot = Split-Path -Parent (Get-Command $sdk).Source
foreach ($notice in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
    $source = Join-Path $sdkRoot $notice
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $release $notice) -Force }
}
$packagesRoot = $env:NUGET_PACKAGES
if (-not $packagesRoot) { $packagesRoot = Join-Path $env:USERPROFILE '.nuget\packages' }
$skiaRoot = Join-Path $packagesRoot 'skiasharp.nativeassets.win32\3.119.4'
Copy-Item -LiteralPath (Join-Path $skiaRoot 'LICENSE.txt') -Destination (Join-Path $release 'SkiaSharp-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $skiaRoot 'THIRD-PARTY-NOTICES.txt') -Destination (Join-Path $release 'SkiaSharp-THIRD-PARTY-NOTICES.txt') -Force
if ($Test -or $DesktopTest) {
    & $sdk build 'tests\DynamicPhotoWall.Tests\DynamicPhotoWall.Tests.csproj' -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Test build failed.' }
    $testArguments = @('tests\DynamicPhotoWall.Tests\bin\Release\net10.0-windows10.0.19041.0\DynamicPhotoWall.Tests.dll', 'artifacts\smoke-data')
    if ($DesktopTest) { $testArguments += '--desktop' }
    & $sdk @testArguments
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
}
& (Join-Path $PSScriptRoot 'Create-Shortcut.ps1')
Write-Output "Ready: $projectRoot\artifacts\win-x64\DynamicPhotoWall.exe"
