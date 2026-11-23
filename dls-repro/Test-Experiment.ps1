#Requires -Version 7.0
[CmdletBinding()]
param([string]$ResultDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\tools\Experiment.psm1" -Force
$cfg = Read-DlsConfig "$PSScriptRoot\config.json"
$plan = @(Get-DlsSchedule 1 3)
if ($plan.Count -ne 4 -or !$plan[0].warmup -or ($plan[2].order -join ',') -cne 'cached,original') { throw 'Unbalanced schedule' }
$rows = @(foreach ($p in $plan) {
    foreach ($v in $p.order) {
        $x = if ($p.warmup) { 10000 } elseif ($v -eq 'original') { 2*$p.pair } else { $p.pair }
        [pscustomobject]@{phase='run'; warmup=$p.warmup; pair=$p.pair; variant=$v
            ns_per_fill=$x; wall_s=$x; cpu_s=$x; peak_job_MiB=$x}
    }
})
$stats = @(Get-DlsSummary $rows run 3)[-1]
if ($stats.original.median -ne 4 -or $stats.cached.mean -ne 2 -or $stats.original.sample_sd -ne 2 -or
    $stats.cached_minus_original.mean -ne -2 -or $stats.cached_minus_original.sample_sd -ne 1) { throw 'Incorrect paired statistics' }
$refused = $false
try { $null=Get-DlsSummary $rows[0..6] run 3 } catch { if ($_.Exception.Message -notlike 'Incomplete*') { throw }; $refused=$true }
if (!$refused) { throw 'Accepted unmatched trials' }
$tmp = [IO.Path]::GetTempFileName()
try {
    $cfg.compile_pairs = 1.5
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $tmp
    $refused=$false
    try { $null=Read-DlsConfig $tmp } catch { if ($_.Exception.Message -notlike 'compile_pairs must*') { throw }; $refused=$true }
    if (!$refused) { throw 'Accepted fractional trial count' }
} finally { Remove-Item -LiteralPath $tmp }
if ($ResultDirectory) {
    $r = Get-Content -LiteralPath "$ResultDirectory\result.json" -Raw | ConvertFrom-Json
    $lines = @(Get-Content -LiteralPath "$ResultDirectory\report.txt")
    if ($r.status -cne 'passed' -or $r.summary.Count -ne 7) { throw 'Incomplete result' }
    foreach ($phase in 'compile','run') {
        $n = if ($phase -eq 'compile') { $r.config.compile_pairs } else { $r.config.runtime_pairs }
        $schedule = @(Get-DlsSchedule $r.config.warmup_pairs_per_phase $n)
        $phaseRows = @($r.trials | Where-Object phase -eq $phase)
        if ($phaseRows.Count -ne 2*$schedule.Count) { throw "Wrong $phase record count" }
        for ($i=0; $i -lt $schedule.Count; $i++) {
            for ($slot=0; $slot -lt 2; $slot++) {
                $row=$phaseRows[2*$i+$slot]
                if ($row.variant -cne $schedule[$i].order[$slot] -or $row.warmup -ne $schedule[$i].warmup -or
                    $row.pair -ne $schedule[$i].pair -or $row.command.process.ExitCode -ne 0 -or
                    $row.wall_s -le 0 -or $row.peak_job_MiB -le 0) { throw 'Invalid trial record' }
                if ($phase -eq 'run' -and ($row.ns_per_fill -le 0 -or $row.fill_calls -ne (40*$r.config.sweeps_per_runtime_trial) -or
                    $row.correctness -notlike 'PASS *')) { throw 'Kernel interval or correctness record missing' }
                if ($phase -eq 'compile' -and ($row.object_bytes -le 0 -or $row.object_sha256 -notmatch '^[A-Fa-f0-9]{64}$')) { throw 'Missing compiler artifact' }
            }
        }
    }
    if (@($lines -like 'PAIR *').Count*2 -ne $r.trials.Count -or @($lines -like 'TRIAL *').Count -ne $r.trials.Count -or
        @($lines -like 'SUMMARY *').Count -ne 7) { throw 'Text report does not match receipt' }
}
'PASS: configuration, ordering, paired statistics and completeness checks.'
