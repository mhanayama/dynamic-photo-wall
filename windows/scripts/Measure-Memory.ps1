param(
    [Parameter(Mandatory = $true)][int]$TargetProcessId,
    [ValidateRange(1, 86400)][int]$Samples = 60,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 1
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = Join-Path $workspace ('artifacts\windows\memory-audit\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-passive')
New-Item -ItemType Directory -Path $output -Force | Out-Null
$target = Get-Process -Id $TargetProcessId
$started = $target.StartTime.ToUniversalTime()
[ordered]@{
    ProcessId = $TargetProcessId; StartedUtc = $started.ToString('o')
    DiskImageProductVersion = (Get-Item -LiteralPath $target.Path).VersionInfo.ProductVersion
    Samples = $Samples; IntervalSeconds = $IntervalSeconds
    Scope = 'Passive observation of the existing process; no launch, stop, settings changes, forced GC or dump. Working set and private bytes overlap and must not be summed. GC heap, image ownership, GPU memory and scene are not inferred from these counters.'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
$rows = for ($i = 0; $i -lt $Samples; $i++) {
    $target.Refresh()
    if ($target.HasExited) { throw 'Target process exited while monitoring' }
    [pscustomobject]@{
        AtUtc = [DateTime]::UtcNow.ToString('o')
        UptimeSeconds = ([DateTime]::UtcNow - $started).TotalSeconds
        WorkingSetMiB = $target.WorkingSet64 / 1MB
        PrivateBytesMiB = $target.PrivateMemorySize64 / 1MB
    }
    if ($i + 1 -lt $Samples) { Start-Sleep -Seconds $IntervalSeconds }
}
$rows | Export-Csv -LiteralPath (Join-Path $output 'samples.csv') -NoTypeInformation -Encoding UTF8
$summary = [ordered]@{ ProcessId = $TargetProcessId; Samples = @($rows).Count }
foreach ($metric in @('WorkingSetMiB', 'PrivateBytesMiB')) {
    $values = $rows | Measure-Object -Property $metric -Average -Minimum -Maximum
    $summary[$metric] = [ordered]@{ Average = $values.Average; Minimum = $values.Minimum; Maximum = $values.Maximum }
}
$summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $output 'summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 3
Write-Output "Memory report: $output"
