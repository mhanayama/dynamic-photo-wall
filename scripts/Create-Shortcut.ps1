$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'artifacts\win-x64\DynamicPhotoWall.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Run scripts\Build.ps1 first.' }
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcutPath = Join-Path $projectRoot 'Dynamic Photo Wall.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.WorkingDirectory = $projectRoot
    $shortcut.Description = 'Dynamic Photo Wall'
    $shortcut.IconLocation = (Join-Path $projectRoot 'assets\PhotoWall.ico') + ',0'
    $shortcut.Save()
    Write-Output $shortcutPath
}
finally {
    if ($shortcut) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
