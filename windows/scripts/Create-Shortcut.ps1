$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $windowsRoot
$executable = Join-Path $projectRoot 'DynamicPhotoWall.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Run windows\scripts\Build.ps1 first.' }
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcutPath = Join-Path $projectRoot 'Dynamic Photo Wall.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.WorkingDirectory = $projectRoot
    $shortcut.Description = 'Dynamic Photo Wall'
    $shortcut.IconLocation = $executable + ',0'
    $shortcut.Save()
    Write-Output $shortcutPath
}
finally {
    if ($shortcut) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
