param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path $projectRoot ('artifacts\windows\runtime-check\' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$probe = Join-Path $work 'DynamicPhotoWall.exe'
$previous = Join-Path $work 'DynamicPhotoWall.previous.exe'
$report = Join-Path $work 'runtime.json'
$gate = Join-Path $work 'continue'
$extract = Join-Path $work 'extracted'
$priorExtract = $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR
$process = $null
try {
    Copy-Item -LiteralPath $Executable -Destination $probe
    $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = $extract
    $process = Start-Process -FilePath $probe -ArgumentList @('--check-runtime', '--output', ('"{0}"' -f $report), '--wait-for', ('"{0}"' -f $gate)) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $work 'stdout.txt') -RedirectStandardError (Join-Path $work 'stderr.txt')
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    while (-not (Test-Path -LiteralPath ($report + '.ready'))) {
        if ($process.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw "Runtime check did not reach gate: $report" }
        Start-Sleep -Milliseconds 100
    }
    # Model an update while popup dependencies have not yet been loaded.
    # Only this isolated copy is renamed; the user's running application is untouched.
    Move-Item -LiteralPath $probe -Destination $previous
    Set-Content -LiteralPath $probe -Value 'Replacement placeholder for delayed dependency loading check.' -Encoding ASCII
    Set-Content -LiteralPath $gate -Value 'continue' -Encoding ASCII
    if (-not $process.WaitForExit(30000)) { throw "Runtime check timed out: $report" }
    $process.Refresh()
    if (-not (Test-Path -LiteralPath $report)) { throw "Runtime check exited with $($process.ExitCode) before reporting. See $work\stderr.txt" }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or -not $result.Success) { throw "Published runtime dependency check failed: $report`n$($result.Error)" }
    foreach ($assembly in $result.Assemblies) {
        if (-not $assembly.Location -or -not (Test-Path -LiteralPath $assembly.Location)) { throw "Runtime assembly was not extracted: $($assembly.FullName)" }
    }
    Write-Output "PASS: published EXE loads Accessibility and compiles the WPF popup bridge after its host is replaced (no GUI). Report: $report"
} finally {
    $env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = $priorExtract
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    foreach ($path in @($probe, $previous)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
