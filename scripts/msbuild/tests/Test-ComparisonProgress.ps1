#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$WorkRoot,
    [string]$Python
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $WorkRoot) { throw 'Preserve prior progress fixtures.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
Import-Module (Join-Path $SourceRoot 'ComparisonSupport.psm1') -Force
Add-Type -TypeDefinition (Get-Content (Join-Path $SourceRoot 'scripts\msbuild\BoundedProcess.cs') -Raw)
$stage='[A 1/3] Fixture build'
$success=Join-Path $WorkRoot 'success.ps1'
"Write-Output 'private success detail'; exit 0" | Set-Content $success
$terminal=Join-Path $WorkRoot 'success-terminal.txt'
$log=Join-Path $WorkRoot 'success.log'
Invoke-ComparisonScript $success @() $stage $log 6> $terminal
$text=Get-Content $terminal -Raw
$result=Get-Content ($log+'.json') -Raw | ConvertFrom-Json
if ($text -notmatch '\[A 1/3\] Fixture build \.\.\. OK' -or
    $text.Contains($log) -or $text.Contains('private success detail') -or
    (Get-Content $log -Raw) -notmatch 'private success detail' -or $result.ExitCode -ne 0) {
    throw 'Successful stage output is noisy, incomplete or lost its detailed log.'
}
[ordered]@{test='successful-stage-is-brief-with-durable-detail';passed=$true}
$failure=Join-Path $WorkRoot 'failure.ps1'
"[Console]::Error.WriteLine('private failure detail'); exit 7" | Set-Content $failure
$terminal=Join-Path $WorkRoot 'failure-terminal.txt'
$log=Join-Path $WorkRoot 'failure.log'
$rejected=$false
try { Invoke-ComparisonScript $failure @() $stage $log 6> $terminal } catch {
    if ($_.Exception.Message -notlike 'Script failed (exit 7)*Log:*') { throw }
    $rejected=$true
}
$text=Get-Content $terminal -Raw
if (-not $rejected -or $text -notmatch 'FAILED' -or $text -match '\.\.\. OK' -or
    -not $text.Contains($log) -or (Get-Content $log -Raw) -notmatch 'private failure detail') {
    throw 'Failure was hidden, reported as success or lost its diagnostic path.'
}
[ordered]@{test='failed-stage-identifies-log-and-preserves-native-exit';passed=$true}
& (Get-Module ComparisonSupport) {
    param($Root)
    $terminal=Join-Path $Root 'heartbeat-terminal.txt'
    $log=Join-Path $Root 'slow.log'
    $state=@{next=60}
    & {
        foreach ($elapsed in @(0,30,59,60,90,120,179,180)) {
            Write-ComparisonHeartbeat '[Sources] Verify A' $log $elapsed $state
        }
    } 6> $terminal
    $lines=@(Get-Content $terminal)
    if ($lines.Count -ne 2 -or $lines[0] -notmatch 'still running \(60s\)' -or
        $lines[1] -notmatch 'still running \(180s\)' -or -not $lines[1].Contains($log)) {
        throw 'Heartbeat threshold, rate limiting or diagnostic path is incorrect.'
    }
} $WorkRoot
[ordered]@{test='slow-stage-log-hint-is-delayed-and-rate-limited';passed=$true}
$terminal=Join-Path $WorkRoot 'value-terminal.txt'
$callerValue='fixture'
$value=Invoke-ComparisonStage '[Sources] Value fixture' { [pscustomobject]@{commit=$callerValue} } $log 6> $terminal
if ($value.commit -cne 'fixture') { throw 'Stage reporting changed its data result.' }
$scripts=Join-Path $WorkRoot 'controller-fixtures'
New-Item -ItemType Directory -Path $scripts | Out-Null
@'
param($Action,$ProtocolPath,$Condition)
$protocol=Get-Content $ProtocolPath -Raw | ConvertFrom-Json
$output=Join-Path $protocol.output_root $Condition
New-Item -ItemType Directory -Path $output -Force | Out-Null
@{
    status=$(if($protocol.should_fail){'failed'}else{'functional_build_passed'})
    build=@{OuterWallSeconds=1}
} | ConvertTo-Json | Set-Content (Join-Path $output 'execution.json')
Write-Output 'private build fixture detail'
if ($protocol.should_fail) { exit 7 }
'@ | Set-Content (Join-Path $scripts 'Invoke-CiPilot.ps1')
@'
param($ProtocolPath,$Condition,$Destination)
New-Item -ItemType Directory -Path $Destination | Out-Null
Write-Output 'private export fixture detail'
'@ | Set-Content (Join-Path $scripts 'Export-CiFunctionalResults.ps1')
$cases=@()
foreach ($label in @('A','B','C')) {
    $directory=Join-Path $WorkRoot $label
    New-Item -ItemType Directory -Path $directory | Out-Null
    $protocol=Join-Path $directory 'protocol.json'
    Write-ComparisonJson @{output_root=(Join-Path $directory 'trials');should_fail=($label -eq 'B')} $protocol
    $cases+=[ordered]@{
        label=$label;condition='baseline';protocol=$protocol
        export=(Join-Path $directory 'export');status='not_started'
    }
}
$record=[ordered]@{cases=$cases;build_budget_seconds=5400;consumed_outer_build_seconds=0}
$terminal=Join-Path $WorkRoot 'cases-terminal.txt'
$rejected=$false
try { Invoke-ComparisonCases $cases $scripts $record (Join-Path $WorkRoot 'summary.json') 6> $terminal } catch {
    if ($_.Exception.Message -notlike 'Script failed (exit 7)*Log:*') { throw }
    $rejected=$true
}
$text=Get-Content $terminal -Raw
if (-not $rejected -or $cases[0].status -cne 'passed' -or $cases[1].status -cne 'failed' -or
    $cases[2].status -cne 'not_started' -or $record.consumed_outer_build_seconds -ne 2 -or
    $text -notmatch '\[A 1/3\] Build and check correctness \.\.\. OK' -or
    $text -notmatch '\[B 2/3\] Build and check correctness \.\.\. FAILED' -or
    $text -match '\[C 3/3\]|private .* fixture detail') {
    throw 'Case labels, accounting, failure export or stop-on-failure changed during progress reporting.'
}
[ordered]@{test='numbered-case-progress-preserves-failure-export-and-stop';passed=$true}
if ($Python) {
    $nested=Join-Path $WorkRoot 'nested'
    Invoke-ComparisonScript (Join-Path $SourceRoot 'scripts\msbuild\Test-BoundedProcess.ps1') @(
        '-OutputDirectory',$nested,'-Python',$Python,'-TestProgress') `
        '[Fixture] Nested process ownership' (Join-Path $WorkRoot 'nested.log')
    $record=Get-Content (Join-Path $nested 'validation.json') -Raw | ConvertFrom-Json
    if ($record.status -cne 'success' -or $record.results.Count -ne 4) {
        throw 'Observed controller changed native deadlines or owned descendant cleanup.'
    }
    [ordered]@{test='observed-controller-preserves-nested-native-deadlines-and-cleanup';passed=$true}
    $updates=[Collections.Generic.List[double]]::new()
    $progress=[Action[double]]{
        param($Elapsed)
        $updates.Add($Elapsed)
        throw 'Intentional observed-controller interruption.'
    }
    $log=Join-Path $WorkRoot 'observed-interruption.log'
    $rejected=$false
    try {
        $null=[OpenCvBoundedProcess]::RunObserved($Python,@(
            (Join-Path $SourceRoot 'scripts\msbuild\tests\bounded_fixture.py'),'parent'),$WorkRoot,$log,$progress)
    } catch {
        if ($_.Exception.Message -notlike '*Intentional observed-controller interruption*') { throw }
        $rejected=$true
    }
    $text=Get-Content $log -Raw
    if (-not $rejected -or $updates.Count -ne 1 -or $text -notmatch 'child_pid=(\d+)') {
        throw 'Observed-controller callback did not run.'
    }
    $child=Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
    if ($child -and -not $child.WaitForExit(5000)) { throw 'Observed-controller interruption leaked its owned child.' }
    [ordered]@{test='observed-controller-interruption-releases-owned-descendants';passed=$true}
}
