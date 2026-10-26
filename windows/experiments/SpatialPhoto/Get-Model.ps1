param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot '.tools/models/depth-anything-v2-small' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$model = Join-Path $OutputDirectory 'model.onnx'
$expected = 'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c'
$revision = '64fe43eba7f8a384b02fe3fadaa26cbba35548d8'
if (-not (Test-Path -LiteralPath $model) -or (Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash -ne $expected) {
    $partial = "$model.download"
    try {
        Invoke-WebRequest -Uri "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/$revision/onnx/model.onnx" -OutFile $partial
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $expected) { throw 'Model SHA256 mismatch.' }
        Move-Item -LiteralPath $partial -Destination $model -Force
    } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
}
Invoke-WebRequest -Uri "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/$revision/preprocessor_config.json" -OutFile (Join-Path $OutputDirectory 'preprocessor_config.json')
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/DepthAnything/Depth-Anything-V2/main/LICENSE' -OutFile (Join-Path $OutputDirectory 'LICENSE-Depth-Anything-V2.txt')
Write-Output "Model ready: $model"
