param([switch]$Test, [switch]$PortraitAlpha, [string]$SceneManifest)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$work = Join-Path $projectRoot 'artifacts/windows/spatial-photo'
$destination = Join-Path $projectRoot 'release/windows/win-x64/spatial-photo-test'
$assembly = 'SpatialPhotoTest'
if ($PortraitAlpha) {
    $destination = Join-Path $projectRoot 'release/windows/win-x64/portrait-alpha'
    $assembly = 'PortraitAlpha'
}
$stage = Join-Path $work ('package/staging.' + [Guid]::NewGuid().ToString('N'))
$modelDirectory = Join-Path $projectRoot '.tools/models/depth-anything-v2-small'
if (-not $PortraitAlpha) {
    if (-not (Test-Path -LiteralPath (Join-Path $modelDirectory 'model.onnx'))) { & (Join-Path $PSScriptRoot 'Get-Model.ps1') }
    if ((Get-FileHash -LiteralPath (Join-Path $modelDirectory 'model.onnx') -Algorithm SHA256).Hash -ne 'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c') { throw 'Model SHA256 mismatch.' }
} elseif (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.tools/portrait-alpha/runtime.json'))) {
    throw 'Run Setup-PortraitAlpha.ps1 before packaging the local alpha.'
}
& (Join-Path $PSScriptRoot 'Build.ps1')
$sdk = Join-Path $projectRoot '.tools/dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'dotnet' }
$native = Join-Path $work 'native/Release/DpwSpatialNative.dll'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'Visual C++ redistributable files not found.' }
$crtVersion = (Get-Content -LiteralPath (Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt') -Raw).Trim()
$crt = Join-Path $vs "VC/Redist/MSVC/$crtVersion/x64/Microsoft.VC143.CRT"
if (-not (Test-Path -LiteralPath $crt)) { throw 'Visual C++ x64 CRT directory not found.' }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
& $sdk publish (Join-Path $PSScriptRoot 'SpatialPhoto.csproj') -c Release -r win-x64 --self-contained true -o $stage --nologo `
    "-p:AssemblyName=$assembly" -p:OutputType=WinExe -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:IncludeAllContentForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:DebugType=embedded -p:PublishTrimmed=false "-p:SpatialNativePath=$native" "-p:SpatialCrtDirectory=$crt"
if ($LASTEXITCODE -ne 0) { throw 'Portable publish failed.' }
Get-ChildItem -LiteralPath $stage -File -Filter '*.pdb' | Remove-Item -Force
New-Item -ItemType Directory -Path (Join-Path $stage 'licenses') -Force | Out-Null
if ($PortraitAlpha) {
    $workerStage = Join-Path $stage 'PortraitWorker'
    New-Item -ItemType Directory -Path $workerStage -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'PortraitWorker/worker.py'), (Join-Path $PSScriptRoot 'PortraitWorker/models.json'), (Join-Path $PSScriptRoot 'PortraitWorker/requirements.txt') -Destination $workerStage
    Get-ChildItem -LiteralPath (Join-Path $projectRoot '.tools/portrait-alpha/licenses') -File | Copy-Item -Destination (Join-Path $stage 'licenses')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'PORTRAIT-ALPHA.md') -Destination (Join-Path $stage 'README.md')
} else {
    New-Item -ItemType Directory -Path (Join-Path $stage 'models') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $modelDirectory 'model.onnx'), (Join-Path $modelDirectory 'preprocessor_config.json') -Destination (Join-Path $stage 'models') -Force
    Copy-Item -LiteralPath (Join-Path $modelDirectory 'LICENSE-Depth-Anything-V2.txt') -Destination (Join-Path $stage 'licenses') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'DISTRIBUTION.md') -Destination (Join-Path $stage 'README.md') -Force
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $stage -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'VC-Runtime-NOTICE.md') -Destination (Join-Path $stage 'licenses') -Force
function Copy-License([string]$Package, [string]$Version, [string]$Name, [string]$OutputName) {
    $source = Join-Path $projectRoot ".tools/packages/$Package/$Version/$Name"
    Copy-Item -LiteralPath $source -Destination (Join-Path $stage "licenses/$OutputName") -Force
}
$assets = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'obj/project.assets.json') -Raw | ConvertFrom-Json
function Runtime-Version([string]$Name) {
    $framework = $assets.project.frameworks.PSObject.Properties.Value | Select-Object -First 1
    $dependency = $framework.downloadDependencies | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $dependency) { throw "Missing restored runtime: $Name" }
    return $dependency.version.Trim('[', ']').Split(',')[0].Trim()
}
$runtimeVersion = Runtime-Version 'Microsoft.NETCore.App.Runtime.win-x64'
$desktopVersion = Runtime-Version 'Microsoft.WindowsDesktop.App.Runtime.win-x64'
Copy-License 'microsoft.netcore.app.runtime.win-x64' $runtimeVersion 'LICENSE.TXT' 'DotNet-LICENSE.txt'
Copy-License 'microsoft.netcore.app.runtime.win-x64' $runtimeVersion 'THIRD-PARTY-NOTICES.TXT' 'DotNet-THIRD-PARTY-NOTICES.txt'
Copy-License 'microsoft.windowsdesktop.app.runtime.win-x64' $desktopVersion 'LICENSE' 'WindowsDesktop-LICENSE.txt'
Copy-License 'microsoft.ml.onnxruntime.directml' '1.24.4' 'LICENSE' 'ONNXRuntime-LICENSE.txt'
Copy-License 'microsoft.ml.onnxruntime.directml' '1.24.4' 'ThirdPartyNotices.txt' 'ONNXRuntime-ThirdPartyNotices.txt'
Copy-License 'microsoft.ai.directml' '1.15.4' 'LICENSE.txt' 'DirectML-LICENSE.txt'
Copy-License 'microsoft.ai.directml' '1.15.4' 'LICENSE-CODE.txt' 'DirectML-LICENSE-CODE.txt'
Copy-License 'microsoft.ai.directml' '1.15.4' 'ThirdPartyNotices.txt' 'DirectML-ThirdPartyNotices.txt'
Copy-License 'skiasharp' '3.119.4' 'LICENSE.txt' 'SkiaSharp-LICENSE.txt'
Copy-License 'skiasharp.nativeassets.win32' '3.119.4' 'LICENSE.txt' 'Skia-Native-LICENSE.txt'
Copy-License 'skiasharp.nativeassets.win32' '3.119.4' 'THIRD-PARTY-NOTICES.txt' 'Skia-THIRD-PARTY-NOTICES.txt'
$revision = & git -C $projectRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot read source revision.' }
$modelInfo = 'Model: onnx-community/depth-anything-v2-small@64fe43eba7f8a384b02fe3fadaa26cbba35548d8'
if ($PortraitAlpha) { $modelInfo = 'Models: PortraitWorker/models.json; CPU runtime: workspace .tools/portrait-alpha (installed separately)' }
@("$assembly - Windows x64", "Base commit: $revision", 'Source state: working tree (experimental)', "Built UTC: $([DateTime]::UtcNow.ToString('o'))", $modelInfo) | Set-Content -LiteralPath (Join-Path $stage 'BUILD-INFO.txt') -Encoding UTF8
if ($Test) {
    $testOutput = Join-Path $work 'package-verification'
    $testArgs = @('--test', '--output', ('"{0}"' -f $testOutput))
    if ($PortraitAlpha) {
        $testOutput = Join-Path $projectRoot 'artifacts/windows/portrait-alpha/package-verification'
        $testArgs = @('--portrait-test', '--output', ('"{0}"' -f $testOutput))
        if ($SceneManifest) { $testArgs += @('--scene', ('"{0}"' -f (Resolve-Path -LiteralPath $SceneManifest).Path)) }
    }
    New-Item -ItemType Directory -Path $testOutput -Force | Out-Null
    $testProcess = Start-Process -FilePath (Join-Path $stage "$assembly.exe") `
        -ArgumentList $testArgs -WorkingDirectory $env:TEMP -WindowStyle Hidden -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $testOutput 'stdout.txt') -RedirectStandardError (Join-Path $testOutput 'stderr.txt')
    Get-Content -LiteralPath (Join-Path $testOutput 'stdout.txt')
    if ($testProcess.ExitCode -ne 0) { Get-Content -LiteralPath (Join-Path $testOutput 'stderr.txt'); throw 'Packaged EXE CLI tests failed.' }
    if ($PortraitAlpha) {
        $result = Get-Content -LiteralPath (Join-Path $testOutput 'portrait-results.json') -Raw | ConvertFrom-Json
        if ($result.failures -ne 0 -or ($SceneManifest -and -not $result.generatedSceneTested)) { throw 'Packaged portrait scene was not tested.' }
    } elseif (-not (Get-Content -LiteralPath (Join-Path $testOutput 'results.json') -Raw | ConvertFrom-Json).modelTested) { throw 'Packaged model was not tested.' }
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Get-ChildItem -LiteralPath $stage | Copy-Item -Destination $destination -Recurse -Force
$hashLines = foreach ($file in Get-ChildItem -LiteralPath $destination -File -Recurse | Where-Object Name -ne 'SHA256SUMS.txt' | Sort-Object FullName) {
    $relative = [System.IO.Path]::GetRelativePath($destination, $file.FullName).Replace('\', '/')
    "$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $relative"
}
$hashLines | Set-Content -LiteralPath (Join-Path $destination 'SHA256SUMS.txt') -Encoding UTF8
Write-Output "Ready: $(Join-Path $destination "$assembly.exe")"
