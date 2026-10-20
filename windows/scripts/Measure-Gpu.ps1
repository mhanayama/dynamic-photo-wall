param(
    [Parameter(Mandatory = $true)][int]$TargetProcessId,
    [ValidateRange(5, 600)][int]$Seconds = 90
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = Join-Path $workspace ('artifacts\windows\gpu-audit\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
$target = Get-Process -Id $TargetProcessId
$dwm = Get-Process -Name dwm -ErrorAction SilentlyContinue | Where-Object SessionId -eq $target.SessionId | Select-Object -First 1
$dwmId = if ($dwm) { $dwm.Id } else { $null }
$processIds = @($TargetProcessId)
if ($dwm) { $processIds += $dwmId }
$paths = foreach ($id in $processIds) {
    "\GPU Engine(pid_${id}_*)\Utilization Percentage"
    "\GPU Process Memory(pid_${id}_*)\Dedicated Usage"
    "\GPU Process Memory(pid_${id}_*)\Shared Usage"
}
$settings = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'DynamicPhotoWall\settings.json') -Raw | ConvertFrom-Json
function Read-Hardware([string]$Class, [string[]]$Properties) {
    try { @(Get-CimInstance -ClassName $Class -ErrorAction Stop | Select-Object -Property $Properties) }
    catch { [pscustomobject]@{ Unavailable = $_.Exception.Message } }
}
$diskImage = Get-Item -LiteralPath $target.Path
$metadata = [ordered]@{
    At = [DateTimeOffset]::Now.ToString('o'); TargetProcessId = $TargetProcessId; DwmProcessId = $dwmId
    Started = $target.StartTime.ToString('o'); DiskImageProductVersion = $diskImage.VersionInfo.ProductVersion
    DiskImageNewerThanProcess = $diskImage.LastWriteTime -gt $target.StartTime
    Gpu = @(Read-Hardware 'Win32_VideoController' @('Name', 'DriverVersion'))
    Cpu = @(Read-Hardware 'Win32_Processor' @('Name', 'NumberOfLogicalProcessors')); LogicalProcessors = [Environment]::ProcessorCount
    SavedSettings = ($settings | Select-Object OnlineMode, GalleryEnabled, GalleryScrollEnabled, VerticalPanEnabled, HorizontalPanEnabled, ZoomEnabled, GlassBackground)
    ConfiguredDisplayDimensions = @($settings.Displays | Select-Object Width, Height)
    Scope = 'Read-only observation of existing mixed-mode playback. No controlled mode/scene, no UI operations, no frame-presentation or power measurements. GPU usage is the busiest engine per process; process GPU memory counters are observations, not proof of retained unique allocations.'
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
$raw = [Collections.Generic.List[object]]::new()
$metrics = [Collections.Generic.List[object]]::new()
$lastCpu = $target.TotalProcessorTime.TotalSeconds
$clock = [Diagnostics.Stopwatch]::StartNew(); $lastAt = 0d
Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples $Seconds -ErrorAction SilentlyContinue | ForEach-Object {
    $counterSet = $_; $target.Refresh(); $at = $clock.Elapsed.TotalSeconds
    if ($target.HasExited) { throw 'Target process exited while monitoring' }
    $cpu = $target.TotalProcessorTime.TotalSeconds; $delta = $cpu - $lastCpu
    if ($delta -lt 0) { throw 'Invalid process CPU delta' }
    $samples = @($counterSet.CounterSamples | ForEach-Object {
        [pscustomobject]@{ Instance = $_.InstanceName; Counter = ($_.Path -split '\\')[-1]; Value = $_.CookedValue; Status = $_.Status }
    })
    $raw.Add([pscustomobject]@{ At = $counterSet.Timestamp.ToString('o'); Counters = $samples })
    foreach ($id in $processIds) {
        $owned = @($samples | Where-Object { $_.Instance -match "^pid_${id}_" -and $_.Status -in @(0,1) })
        $engine = @($owned | Where-Object { $_.Counter -eq 'utilization percentage' })
        $memory = @($owned | Where-Object { $_.Counter -ne 'utilization percentage' })
        $metrics.Add([pscustomobject]@{
            At = $counterSet.Timestamp.ToString('o'); ProcessId = $id
            GpuBusiestEnginePercent = if ($engine.Count) { ($engine.Value | Measure-Object -Maximum).Maximum } else { $null }
            DedicatedCounterMiB = ($memory | Where-Object Counter -eq 'dedicated usage' | Measure-Object Value -Sum).Sum / 1MB
            SharedCounterMiB = ($memory | Where-Object Counter -eq 'shared usage' | Measure-Object Value -Sum).Sum / 1MB
            CpuPercentOfMachine = if ($id -eq $TargetProcessId) { 100 * $delta / ($at - $lastAt) / [Environment]::ProcessorCount } else { $null }
            WorkingSetMiB = if ($id -eq $TargetProcessId) { $target.WorkingSet64 / 1MB } else { $null }
            InvalidCounters = @($samples | Where-Object { $_.Instance -match "^pid_${id}_" -and $_.Status -notin @(0,1) }).Count
        })
    }
    $lastAt = $at; $lastCpu = $cpu
    if ($raw.Count % 30 -eq 0) { Write-Output "Collected $($raw.Count) GPU samples" }
}
if ($raw.Count -eq 0) { throw 'No GPU counter samples were available' }
$raw.ToArray() | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'samples.json') -Encoding UTF8
$metrics.ToArray() | Export-Csv -LiteralPath (Join-Path $output 'metrics.csv') -NoTypeInformation -Encoding UTF8
$summary = foreach ($id in $processIds) {
    $rows = @($metrics | Where-Object ProcessId -eq $id)
    $values = @($rows | Where-Object { $null -ne $_.GpuBusiestEnginePercent } | Select-Object -ExpandProperty GpuBusiestEnginePercent | Sort-Object)
    [pscustomobject]@{
        ProcessId = $id; Samples = $rows.Count; ValidGpuSamples = $values.Count
        GpuAverage = ($values | Measure-Object -Average).Average
        GpuP95 = if ($values.Count) { $values[[Math]::Max(0, [Math]::Ceiling($values.Count * .95)-1)] } else { $null }
        GpuMaximum = ($values | Measure-Object -Maximum).Maximum
        DedicatedCounterAverageMiB = ($rows.DedicatedCounterMiB | Measure-Object -Average).Average
        SharedCounterAverageMiB = ($rows.SharedCounterMiB | Measure-Object -Average).Average
        CpuMachineAverage = ($rows.CpuPercentOfMachine | Measure-Object -Average).Average
        WorkingSetAverageMiB = ($rows.WorkingSetMiB | Measure-Object -Average).Average
    }
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'summary.json') -Encoding UTF8
$engines = $raw | ForEach-Object { $_.Counters } | Where-Object { $_.Counter -eq 'utilization percentage' -and $_.Status -in @(0,1) } |
    Group-Object Instance | ForEach-Object { [pscustomobject]@{ Instance = $_.Name; Average = ($_.Group.Value | Measure-Object -Average).Average; Maximum = ($_.Group.Value | Measure-Object -Maximum).Maximum } }
$engines | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'engines.json') -Encoding UTF8
$summary | ConvertTo-Json
Write-Output "GPU report: $output"
