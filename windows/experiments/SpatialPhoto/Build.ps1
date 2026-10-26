param([switch]$Test, [switch]$DownloadModel)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$build = Join-Path $projectRoot 'artifacts/windows/spatial-photo'
$sdk = Join-Path $projectRoot '.tools/dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'dotnet' }
$env:NUGET_PACKAGES = Join-Path $projectRoot '.tools/packages'
if ($DownloadModel) { & (Join-Path $PSScriptRoot 'Get-Model.ps1') }
& cmake -S (Join-Path $PSScriptRoot 'Native') -B (Join-Path $build 'native') -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
& cmake --build (Join-Path $build 'native') --config Release
if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }
& $sdk publish (Join-Path $PSScriptRoot 'SpatialPhoto.csproj') -c Release -o (Join-Path $build 'app') --nologo
if ($LASTEXITCODE -ne 0) { throw 'Managed build failed.' }
Copy-Item -LiteralPath (Join-Path $build 'native/Release/DpwSpatialNative.dll') -Destination (Join-Path $build 'app') -Force
if ($Test) {
    $testArgs = @('--test', '--output', (Join-Path $build 'verification'))
    $model = Join-Path $projectRoot '.tools/models/depth-anything-v2-small/model.onnx'
    if (Test-Path -LiteralPath $model) { $testArgs += @('--model', $model) }
    & (Join-Path $build 'app/SpatialPhoto.exe') @testArgs
    if ($LASTEXITCODE -ne 0) { throw 'Spatial Photo CLI tests failed.' }
}
Write-Output "Ready: $(Join-Path $build 'app/SpatialPhoto.exe')"
