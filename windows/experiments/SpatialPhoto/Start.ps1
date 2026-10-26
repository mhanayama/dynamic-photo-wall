param([string]$Photo)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$packaged = Join-Path $projectRoot 'release/windows/win-x64/spatial-photo-test/SpatialPhotoTest.exe'
if (Test-Path -LiteralPath $packaged) {
    $exe = $packaged
    $model = Join-Path (Split-Path -Parent $packaged) 'models/model.onnx'
} else {
    $exe = Join-Path $projectRoot 'artifacts/windows/spatial-photo/app/SpatialPhoto.exe'
    $model = Join-Path $projectRoot '.tools/models/depth-anything-v2-small/model.onnx'
}
$cache = Join-Path $projectRoot 'artifacts/windows/spatial-photo/cache'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Run windows/experiments/SpatialPhoto/Build.ps1 first.' }
if (-not (Test-Path -LiteralPath $model)) { throw 'Run windows/experiments/SpatialPhoto/Get-Model.ps1 first.' }
$launchArgs = @('--model', ('"{0}"' -f $model), '--output', ('"{0}"' -f $cache))
if ($Photo) {
    $resolvedPhoto = (Resolve-Path -LiteralPath $Photo).Path
    $launchArgs += @('--photo', ('"{0}"' -f $resolvedPhoto))
}
# The console stays hidden; WPF opens the explicitly requested interactive trial.
Start-Process -FilePath $exe -ArgumentList $launchArgs -WorkingDirectory $projectRoot -WindowStyle Hidden
