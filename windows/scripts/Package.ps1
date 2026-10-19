param([switch]$Test)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$rootFilesBefore = @(Get-ChildItem -LiteralPath $projectRoot -File -Force | Select-Object -ExpandProperty Name)
& (Join-Path $PSScriptRoot 'Build.ps1') -Test:$Test
$release = Join-Path $projectRoot 'release\windows\win-x64'
& (Join-Path $PSScriptRoot 'Verify-PublishedRuntime.ps1') -Executable (Join-Path $release 'DynamicPhotoWall.exe')
$work = Join-Path $projectRoot 'artifacts\windows\package'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$staging = Join-Path $work ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    # Explicit allowlist: never package local photos, profiles or absolute shortcuts.
    $files = @('DynamicPhotoWall.exe', 'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md',
        'DotNet-LICENSE.txt', 'DotNet-THIRD-PARTY-NOTICES.txt', 'WindowsDesktop-LICENSE.txt',
        'SkiaSharp-Managed-LICENSE.txt', 'SkiaSharp-LICENSE.txt', 'SkiaSharp-THIRD-PARTY-NOTICES.txt', 'BUILD-INFO.txt')
    foreach ($name in $files) {
        Copy-Item -LiteralPath (Join-Path $release $name) -Destination $staging
    }
    $zip = Join-Path $release 'DynamicPhotoWall-windows-x64.zip'
    $candidate = Join-Path $work 'DynamicPhotoWall-windows-x64.zip'
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $candidate -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($candidate)
    try {
        $actual = @($archive.Entries | ForEach-Object { $_.FullName })
        if (Compare-Object ($files | Sort-Object) ($actual | Sort-Object)) { throw 'Unexpected ZIP contents.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        $stream = $archive.GetEntry('DynamicPhotoWall.exe').Open()
        try { $embeddedHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($embeddedHash -ne (Get-FileHash -LiteralPath (Join-Path $release 'DynamicPhotoWall.exe') -Algorithm SHA256).Hash) {
            throw 'ZIP executable hash mismatch.'
        }
    } finally { $archive.Dispose() }
    Move-Item -LiteralPath $candidate -Destination $zip -Force
    $checksums = foreach ($name in @('DynamicPhotoWall.exe', 'DynamicPhotoWall-windows-x64.zip')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $release $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    Set-Content -LiteralPath (Join-Path $release 'SHA256SUMS.txt') -Value $checksums -Encoding ASCII
    $rootFilesAfter = @(Get-ChildItem -LiteralPath $projectRoot -File -Force | Select-Object -ExpandProperty Name)
    if (Compare-Object $rootFilesBefore $rootFilesAfter) { throw 'Project root file list changed during packaging.' }
    Write-Output "Package verified: $zip"
} finally {
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    $resolvedWork = [IO.Path]::GetFullPath($work).TrimEnd('\') + '\'
    if (-not $resolvedStaging.StartsWith($resolvedWork, [StringComparison]::OrdinalIgnoreCase)) { throw 'Staging is outside package workspace.' }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}
