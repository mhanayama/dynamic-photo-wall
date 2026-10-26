param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot '.tools/models/moge-2-vits-normal' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$model = Join-Path $OutputDirectory 'model.onnx'
$expected = '24eacb5dc7a2c54c7bc98f7de085ffbed79ad006ea5b664c2c2cdc02ff3a52f0'
$revision = 'e50ffda41565591092adea54c6ac83d6212e1e23'
if (-not (Test-Path -LiteralPath $model) -or (Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash -ne $expected) {
    $partial = "$model.download"
    try {
        Invoke-WebRequest -Uri "https://huggingface.co/Ruicheng/moge-2-vits-normal-onnx/resolve/$revision/model.onnx" -OutFile $partial
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $expected) { throw 'Geometry model SHA256 mismatch.' }
        Move-Item -LiteralPath $partial -Destination $model -Force
    } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
}
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/microsoft/MoGe/74fbce054ebed49800de42d0ad0e83495065719a/LICENSE' -OutFile (Join-Path $OutputDirectory 'MoGe-LICENSE.txt')
@('MoGe-2 ViT-S normal, official ONNX export.', "Revision: $revision", "SHA256: $expected", 'Upstream code: https://github.com/microsoft/MoGe', 'Original model (MIT): https://huggingface.co/Ruicheng/moge-2-vits-normal', 'ONNX export linked by upstream: https://github.com/microsoft/MoGe/blob/main/docs/onnx.md', 'DPW uses its own C# geometric calibration, mesh creation and Direct3D 12 rendering.') | Set-Content -LiteralPath (Join-Path $OutputDirectory 'MODEL-NOTICE.txt') -Encoding UTF8
Write-Output "Geometry model ready: $model"
