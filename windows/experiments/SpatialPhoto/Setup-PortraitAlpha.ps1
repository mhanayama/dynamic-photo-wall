$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$runtime = Join-Path $projectRoot '.tools/portrait-alpha'
$models = Join-Path $runtime 'models'
$downloads = Join-Path $projectRoot 'artifacts/windows/portrait-alpha/setup'
New-Item -ItemType Directory -Path $runtime, $models, $downloads -Force | Out-Null
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PortraitWorker/models.json') -Raw | ConvertFrom-Json
foreach ($entry in $lock.files) {
    $destination = Join-Path $models $entry.path
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ((Test-Path -LiteralPath $destination) -and (-not $entry.sha256 -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $entry.sha256)) { continue }
    $part = "$destination.download"
    Invoke-WebRequest -Uri $entry.url -OutFile $part
    if ($entry.sha256 -and (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Model hash mismatch: $($entry.path)" }
    Move-Item -LiteralPath $part -Destination $destination -Force
    Write-Output "Downloaded: $($entry.path)"
}
$vendor = Join-Path $runtime 'vendor'
$source = Join-Path $vendor "TripoSR-$($lock.triposr_source)"
if (-not (Test-Path -LiteralPath (Join-Path $source 'tsr/system.py'))) {
    $archive = Join-Path $downloads 'triposr.zip'
    Invoke-WebRequest -Uri "https://codeload.github.com/VAST-AI-Research/TripoSR/zip/$($lock.triposr_source)" -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $vendor -Force
}
$pythonDirectory = Join-Path $runtime 'python'
$python = Join-Path $pythonDirectory 'python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    $archive = Join-Path $downloads 'python-3.11.9-embed-amd64.zip'
    Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip' -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $pythonDirectory -Force
}
@('python311.zip', '.', 'Lib/site-packages', 'import site') | Set-Content -LiteralPath (Join-Path $pythonDirectory 'python311._pth') -Encoding ASCII
$site = Join-Path $pythonDirectory 'Lib/site-packages'
$env:PYTHONPYCACHEPREFIX = Join-Path $downloads 'pycache'
$env:PIP_CACHE_DIR = Join-Path $downloads 'pip-cache'
if (-not (Test-Path -LiteralPath (Join-Path $site 'pip'))) {
    $bootstrap = Join-Path $downloads 'get-pip.py'
    Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $bootstrap
    & $python $bootstrap --target $site --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { throw 'pip bootstrap failed.' }
}
& $python -m pip install --target $site --upgrade --no-deps --no-warn-script-location 'torch==2.5.1' 'torchvision==0.20.1' --index-url https://download.pytorch.org/whl/cpu
if ($LASTEXITCODE -ne 0) { throw 'CPU PyTorch installation failed.' }
& $python -m pip install --target $site --upgrade --no-warn-script-location -r (Join-Path $PSScriptRoot 'PortraitWorker/requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Portrait worker dependencies failed.' }
New-Item -ItemType Directory -Path (Join-Path $runtime 'licenses') -Force | Out-Null
$licenseUrls = @{
    'TripoSR-LICENSE' = "https://raw.githubusercontent.com/VAST-AI-Research/TripoSR/$($lock.triposr_source)/LICENSE"
    'BiRefNet-LICENSE' = 'https://raw.githubusercontent.com/ZhengPeng7/BiRefNet/main/LICENSE'
    'LaMa-LICENSE' = 'https://raw.githubusercontent.com/advimman/lama/main/LICENSE'
    'LaMa-ONNX-MODEL-CARD.md' = 'https://huggingface.co/Carve/LaMa-ONNX/resolve/c3c0c9e468934d62e79c329e35d82dd09ff8c444/README.md'
}
foreach ($name in $licenseUrls.Keys) { Invoke-WebRequest -Uri $licenseUrls[$name] -OutFile (Join-Path $runtime "licenses/$name") }
# Download only DINO's architecture configuration; TripoSR's checkpoint contains its weights.
Invoke-WebRequest -Uri 'https://huggingface.co/facebook/dino-vitb16/resolve/main/config.json' -OutFile (Join-Path $models 'triposr/dino-config.json')
@{ runtime = $runtime; source = $source; python = $python; models = $models } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'runtime.json') -Encoding UTF8
& $python -m pip freeze --path $site | Set-Content -LiteralPath (Join-Path $downloads 'installed-requirements.txt') -Encoding UTF8
Write-Output "Portrait alpha runtime ready: $runtime"
