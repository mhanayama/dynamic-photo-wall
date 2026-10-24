param(
    [Parameter(Mandatory = $true)][int]$TargetProcessId,
    [ValidateRange(5, 60)][int]$Seconds = 12
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'GPU ETW capture needs an administrator PowerShell. This script does not elevate itself or change profiling policy.'
}
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = Join-Path $workspace ('artifacts\windows\gpu-audit\trace-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
$target = Get-Process -Id $TargetProcessId
if ($target.ProcessName -ne 'DynamicPhotoWall') { throw 'Target must be an existing DynamicPhotoWall process' }
$sessionName = 'PhotoWallGpu-' + [Guid]::NewGuid().ToString('N')
$metadata = [ordered]@{
    ProcessId = $TargetProcessId; StartedUtc = $target.StartTime.ToUniversalTime().ToString('o')
    AtUtc = [DateTime]::UtcNow.ToString('o'); Seconds = $Seconds; SessionName = $sessionName
    DiskImageProductVersion = (Get-Item -LiteralPath $target.Path).VersionInfo.ProductVersion
    DiskImageNewerThanProcess = (Get-Item -LiteralPath $target.Path).LastWriteTime -gt $target.StartTime
    WorkingSetBefore = $target.WorkingSet64; PrivateBytesBefore = $target.PrivateMemorySize64
    Scope = 'Existing playback; no GUI operations, settings changes, process launch/stop, forced GC or heap dump. ETW is system-wide and may affect measured performance; keep locally. This script starts/stops only its uniquely named WPR session.'
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
$started = $false
try {
    & wpr.exe -start GPU.light -filemode -recordtempto $output -instancename $sessionName *> (Join-Path $output 'start.txt')
    if ($LASTEXITCODE -ne 0) { throw "WPR could not start. See $output\start.txt" }
    $started = $true
    Start-Sleep -Seconds $Seconds
}
finally {
    if ($started) {
        & wpr.exe -stop (Join-Path $output 'gpu.etl') 'PhotoWall existing playback GPU audit' -skipPdbGen -instancename $sessionName *> (Join-Path $output 'stop.txt')
        if ($LASTEXITCODE -ne 0) { throw "WPR could not stop. See $output\stop.txt; session $sessionName" }
    }
}
$target.Refresh()
[ordered]@{ Success = $true; AtUtc = [DateTime]::UtcNow.ToString('o'); ProcessId = $TargetProcessId
    WorkingSetAfter = $target.WorkingSet64; PrivateBytesAfter = $target.PrivateMemorySize64
    Trace = (Join-Path $output 'gpu.etl'); TraceBytes = (Get-Item -LiteralPath (Join-Path $output 'gpu.etl')).Length
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
Write-Output "GPU trace: $output"
