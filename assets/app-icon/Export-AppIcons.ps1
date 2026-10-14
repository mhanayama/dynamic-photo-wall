[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$catalog = Join-Path $repoRoot 'macos/DynamicPhotoWall/Assets.xcassets'
$variants = @(
    @{ Name = 'light'; Set = 'AppIcon' },
    @{ Name = 'dark'; Set = 'AppIconDark' },
    @{ Name = 'liquid-glass'; Set = 'AppIconGlass' }
)

function Export-Png([System.Drawing.Image] $Source, [int] $Size, [string] $Path) {
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        # TileFlipXY prevents a transparent seam introduced by the resampling kernel.
        $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
        try {
            $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $rect = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
            $graphics.DrawImage($Source, $rect, 0, 0, $Source.Width, $Source.Height,
                [System.Drawing.GraphicsUnit]::Pixel, $attributes)
        } finally { $attributes.Dispose() }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

foreach ($variant in $variants) {
    $sourcePath = Join-Path $PSScriptRoot "PhotoWall-$($variant.Name)-source.png"
    $source = [System.Drawing.Image]::FromFile($sourcePath)
    try {
        if ($source.Width -ne $source.Height) { throw "Source must be square: $sourcePath" }
        $masterPath = Join-Path $PSScriptRoot "PhotoWall-$($variant.Name).png"
        Export-Png $source 1024 $masterPath
        $setPath = Join-Path $catalog "$($variant.Set).appiconset"
        New-Item -ItemType Directory -Force $setPath | Out-Null
        $images = @()
        foreach ($points in @(16, 32, 128, 256, 512)) {
            foreach ($scale in @(1, 2)) {
                $pixels = $points * $scale
                $filename = "icon_${points}x${points}@${scale}x.png"
                Export-Png $source $pixels (Join-Path $setPath $filename)
                $images += [ordered]@{
                    filename = $filename
                    idiom = 'mac'
                    scale = "${scale}x"
                    size = "${points}x${points}"
                }
            }
        }
        $contents = [ordered]@{ images = $images; info = @{ author = 'xcode'; version = 1 } }
        $json = $contents | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $setPath 'Contents.json'), $json + "`n")
        Write-Output "$($variant.Set): 10 macOS slots; 1024px master exported."
    } finally { $source.Dispose() }
}

# Ordinary image resources for SwiftUI views (separate from the Dock app icon).
$imageSets = @(
    @{ Name = 'PhotoWallIcon'; Images = @(
        @{ File = 'PhotoWall-light.png'; Appearance = $null },
        @{ File = 'PhotoWall-dark.png'; Appearance = 'dark' }
    ) },
    @{ Name = 'PhotoWallIconGlass'; Images = @(
        @{ File = 'PhotoWall-liquid-glass.png'; Appearance = $null }
    ) }
)
foreach ($set in $imageSets) {
    $setPath = Join-Path $catalog "$($set.Name).imageset"
    New-Item -ItemType Directory -Force $setPath | Out-Null
    $images = @()
    foreach ($entry in $set.Images) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $entry.File) -Destination $setPath
        $image = [ordered]@{ filename = $entry.File; idiom = 'universal' }
        if ($entry.Appearance) {
            $image.appearances = @(@{ appearance = 'luminosity'; value = $entry.Appearance })
        }
        $images += $image
    }
    $contents = [ordered]@{ images = $images; info = @{ author = 'xcode'; version = 1 } }
    [System.IO.File]::WriteAllText((Join-Path $setPath 'Contents.json'),
        (($contents | ConvertTo-Json -Depth 6) + "`n"))
}
