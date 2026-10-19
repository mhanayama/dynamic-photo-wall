param(
    [ValidateRange(2, 60)][double]$Seconds = 4,
    [ValidateRange(1, 10)][int]$Repetitions = 3,
    [ValidateSet('static', 'replacement', 'horizontal-pan', 'vertical-pan', 'zoom', 'scroll', 'paused', 'multi-display', 'ambient-off')]
    [string[]]$Scenarios = @('static', 'replacement', 'horizontal-pan', 'vertical-pan', 'zoom', 'scroll', 'paused', 'multi-display', 'ambient-off'),
    [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sdk = Join-Path $projectRoot '.tools\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'dotnet' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
if (Test-Path -LiteralPath (Join-Path $projectRoot '.tools\packages')) { $env:NUGET_PACKAGES = Join-Path $projectRoot '.tools\packages' }
$output = Join-Path $projectRoot ('artifacts\windows\issue-2\measurements\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (-not $NoBuild) {
    & $sdk build (Join-Path $projectRoot 'windows\tests\DynamicPhotoWall.Tests\DynamicPhotoWall.Tests.csproj') -c Release --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Benchmark build failed' }
}
$dll = Join-Path $projectRoot 'windows\tests\DynamicPhotoWall.Tests\bin\Release\net10.0-windows10.0.19041.0\DynamicPhotoWall.Tests.dll'
if (-not (Test-Path -LiteralPath $dll)) { throw 'Build the test project before using -NoBuild' }
function Read-Hardware([string]$Class, [string[]]$Properties) {
    try { @(Get-CimInstance -ClassName $Class -ErrorAction Stop | Select-Object -Property $Properties) }
    catch { [pscustomobject]@{ Unavailable = $_.Exception.Message } }
}
$metadata = [ordered]@{
    Revision = (& git -C $projectRoot rev-parse HEAD)
    SourceState = @(& git -C $projectRoot status --porcelain)
    Sdk = (& $sdk --version)
    Assemblies = @($dll, (Join-Path (Split-Path -Parent $dll) 'DynamicPhotoWall.dll')) | ForEach-Object {
        [pscustomobject]@{ Name = [IO.Path]::GetFileName($_); SHA256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    }
    ProcessorIdentifier = $env:PROCESSOR_IDENTIFIER
    Cpu = @(Read-Hardware 'Win32_Processor' @('Name', 'NumberOfLogicalProcessors'))
    Gpu = @(Read-Hardware 'Win32_VideoController' @('Name', 'DriverVersion'))
    Seconds = $Seconds
    Repetitions = $Repetitions
    Scope = 'Offscreen synthetic WPF fixture. No desktop or user application operations. GPU/power/presentation frame time are not measured.'
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'environment.json') -Encoding UTF8
$results = @()
foreach ($scenario in $Scenarios) {
    for ($iteration = 1; $iteration -le $Repetitions; $iteration++) {
        # Fresh process per measurement; alternate AB -> BA -> AB.
        $modes = if ($scenario -eq 'ambient-off') { @('disabled') } elseif ($iteration % 2) { @('continuous-reference', 'event-driven') } else { @('event-driven', 'continuous-reference') }
        foreach ($mode in $modes) {
            $run = Join-Path $output "$scenario-$iteration-$mode"
            New-Item -ItemType Directory -Path $run -Force | Out-Null
            $arguments = @($dll, $run, '--scan-only', "--ambient-benchmark=$scenario", ('--measure-seconds=' + $Seconds.ToString([Globalization.CultureInfo]::InvariantCulture)))
            if ($mode -eq 'continuous-reference') { $arguments += '--ambient-reference' }
            & $sdk @arguments *> (Join-Path $run 'run.log')
            if ($LASTEXITCODE -ne 0) { throw "Benchmark failed: $run" }
            $result = Get-Content -LiteralPath (Join-Path $run 'ambient-benchmark.json') -Raw | ConvertFrom-Json
            $result | Add-Member -NotePropertyName Repetition -NotePropertyValue $iteration
            $results += $result
            Write-Output "$scenario / $mode / $iteration : captures=$($result.Captures), CPU(one core)=$([Math]::Round($result.CpuPercentOfOneCore, 3))%"
        }
    }
}
$results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'results.json') -Encoding UTF8
$summary = $results | Group-Object Scenario, Mode | ForEach-Object {
    [pscustomobject]@{
        Scenario = $_.Group[0].Scenario; Mode = $_.Group[0].Mode; Runs = $_.Count
        AverageCaptures = ($_.Group.Captures | Measure-Object -Average).Average
        AverageCpuPercentOfOneCore = ($_.Group.CpuPercentOfOneCore | Measure-Object -Average).Average
        AverageCaptureMilliseconds = ($_.Group.CaptureMilliseconds | Measure-Object -Average).Average
        AverageProcessMilliseconds = ($_.Group.ProcessMilliseconds | Measure-Object -Average).Average
        AverageAllocatedBytes = ($_.Group.AllocatedBytes | Measure-Object -Average).Average
        PeakWorkingSetBytes = ($_.Group.PeakWorkingSetBytes | Measure-Object -Maximum).Maximum
    }
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'summary.json') -Encoding UTF8
Write-Output "Measurements: $output"
