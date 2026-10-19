param([switch]$Test, [switch]$DesktopTest)
$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $windowsRoot
Push-Location -LiteralPath $windowsRoot
try {
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$sdk = Join-Path $projectRoot '.tools\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'dotnet' }
if (Test-Path -LiteralPath (Join-Path $projectRoot '.tools\packages')) { $env:NUGET_PACKAGES = Join-Path $projectRoot '.tools\packages' }
$release = Join-Path $projectRoot 'release\windows\win-x64'
$sourceRevision = & git -C $projectRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine source revision.' }
& $sdk publish 'src\DynamicPhotoWall\DynamicPhotoWall.csproj' -c Release -r win-x64 --self-contained true -o $release --nologo `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:IncludeAllContentForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=embedded -p:PublishTrimmed=false "-p:SourceRevisionId=$sourceRevision"
if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
$nativeSymbols = Join-Path $release 'libSkiaSharp.pdb'
if (Test-Path -LiteralPath $nativeSymbols) { Remove-Item -LiteralPath $nativeSymbols -Force }
Copy-Item -LiteralPath 'DISTRIBUTION.md' -Destination (Join-Path $release 'README.md') -Force
Copy-Item -LiteralPath 'THIRD-PARTY-NOTICES.md', (Join-Path $projectRoot 'LICENSE') -Destination $release -Force
New-Item -ItemType Directory -Path (Join-Path $release 'docs') -Force | Out-Null
Copy-Item -LiteralPath 'docs\ARCHITECTURE.md', 'docs\TEST-RESULTS.md' -Destination (Join-Path $release 'docs') -Force
New-Item -ItemType Directory -Path (Join-Path $release 'photos') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $release 'photos\README.txt') -Value 'Place your JPEG, PNG and WebP photos here, or add another folder in Photos settings.' -Encoding UTF8
# Use licenses from the actual restored runtime packages, not the build SDK.
$assets = Get-Content -LiteralPath 'src\DynamicPhotoWall\obj\project.assets.json' -Raw | ConvertFrom-Json
$framework = $assets.project.frameworks.PSObject.Properties.Value | Select-Object -First 1
$componentVersions = [System.Collections.Generic.List[string]]::new()
function Get-PackageDirectory([string]$Name) {
    $library = $assets.libraries.PSObject.Properties | Where-Object { $_.Name -like "$Name/*" } | Select-Object -First 1
    if ($library) { $version = $library.Name.Split('/')[1] }
    else {
        $download = $framework.downloadDependencies | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if (-not $download) { throw "Restored package not found: $Name" }
        $version = $download.version.Trim('[', ']').Split(',')[0].Trim()
    }
    $componentVersions.Add("${Name}: $version")
    foreach ($folder in $assets.packageFolders.PSObject.Properties.Name) {
        $path = Join-Path $folder ($Name.ToLowerInvariant() + '\' + $version)
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw "Package directory not found: $Name/$version"
}
$runtimeRoot = Get-PackageDirectory 'Microsoft.NETCore.App.Runtime.win-x64'
$desktopRoot = Get-PackageDirectory 'Microsoft.WindowsDesktop.App.Runtime.win-x64'
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'LICENSE.TXT') -Destination (Join-Path $release 'DotNet-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $release 'DotNet-THIRD-PARTY-NOTICES.txt') -Force
Copy-Item -LiteralPath (Join-Path $desktopRoot 'LICENSE') -Destination (Join-Path $release 'WindowsDesktop-LICENSE.txt') -Force
$skiaManagedRoot = Get-PackageDirectory 'SkiaSharp'
$skiaRoot = Get-PackageDirectory 'SkiaSharp.NativeAssets.Win32'
Copy-Item -LiteralPath (Join-Path $skiaManagedRoot 'LICENSE.txt') -Destination (Join-Path $release 'SkiaSharp-Managed-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $skiaRoot 'LICENSE.txt') -Destination (Join-Path $release 'SkiaSharp-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $skiaRoot 'THIRD-PARTY-NOTICES.txt') -Destination (Join-Path $release 'SkiaSharp-THIRD-PARTY-NOTICES.txt') -Force
# Retire the SDK notices emitted by older versions of this build script.
foreach ($obsolete in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
    $obsoletePath = Join-Path $release $obsolete
    if (Test-Path -LiteralPath $obsoletePath) { Remove-Item -LiteralPath $obsoletePath -Force }
}
$sourceState = & git -C $projectRoot status --porcelain --untracked-files=normal
$buildInfo = @(
    'Dynamic Photo Wall - Windows x64'
    "Source: https://github.com/mhanayama/dynamic-photo-wall/commit/$sourceRevision"
    "Source state: $(if ($sourceState) { 'modified working tree' } else { 'clean' })"
    "Built UTC: $([DateTime]::UtcNow.ToString('o'))"
    "SDK: $(& $sdk --version)"
) + $componentVersions.ToArray()
Set-Content -LiteralPath (Join-Path $release 'BUILD-INFO.txt') -Value $buildInfo -Encoding UTF8
if ($Test -or $DesktopTest) {
    $parityProject = Join-Path $projectRoot 'tests\ParityVerifier\ParityVerifier.csproj'
    & $sdk run --project $parityProject -c Release -- --zoom-framing
    if ($LASTEXITCODE -ne 0) { throw 'Zoom framing tests failed.' }
    & $sdk run --project (Join-Path $projectRoot 'tests\NetworkCore.Tests\NetworkCore.Tests.csproj') -c Release -- (Join-Path $projectRoot 'artifacts\windows\network-core')
    if ($LASTEXITCODE -ne 0) { throw 'Network core tests failed.' }
    & $sdk build 'tests\DynamicPhotoWall.Tests\DynamicPhotoWall.Tests.csproj' -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Test build failed.' }
    $testArguments = @('tests\DynamicPhotoWall.Tests\bin\Release\net10.0-windows10.0.19041.0\DynamicPhotoWall.Tests.dll', (Join-Path $projectRoot 'artifacts\windows\smoke-data'))
    if ($DesktopTest) { $testArguments += '--desktop' }
    & $sdk @testArguments
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
}
& (Join-Path $PSScriptRoot 'Create-Shortcut.ps1')
Write-Output "Ready: $release\DynamicPhotoWall.exe (self-contained single-file Windows x64)"
} finally {
    Pop-Location
}
