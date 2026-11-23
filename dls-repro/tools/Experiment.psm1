Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DlsConfig([string]$Path) {
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $limits = @{compile_pairs=12; runtime_pairs=40; warmup_pairs_per_phase=4; sweeps_per_runtime_trial=100000}
    if ($c -isnot [System.Collections.IDictionary] -or $c.Count -ne $limits.Count) { throw 'Expected exactly four configuration fields.' }
    foreach ($key in $limits.Keys) {
        $n = $c[$key]
        if (($n -isnot [long] -and $n -isnot [int]) -or $n -lt 1 -or $n -gt $limits[$key]) {
            throw "$key must be an integer in 1..$($limits[$key])."
        }
    }
    $c
}

function Get-DlsSchedule([int]$Warmups,[int]$Pairs) {
    foreach ($warm in @($true,$false)) {
        $count = if ($warm) { $Warmups } else { $Pairs }
        for ($i=1; $i -le $count; $i++) {
            $order = if ($i % 2) { 'original','cached' } else { 'cached','original' }
            [pscustomobject]@{warmup=$warm; pair=$i; order=$order}
        }
    }
}

function Get-DlsStatistics([double[]]$Values) {
    if (!$Values.Count) { throw 'No observations to summarize.' }
    $sorted = @($Values | Sort-Object)
    $m = $sorted | Measure-Object -Minimum -Maximum -Average
    $n = $sorted.Count
    $mid = [int][Math]::Floor($n/2)
    $median = if ($n % 2) { $sorted[$mid] } else { ($sorted[$mid-1]+$sorted[$mid])/2 }
    $ss = 0.0
    foreach ($x in $sorted) { $ss += ($x-$m.Average)*($x-$m.Average) }
    [ordered]@{n=$n; mean=$m.Average; median=$median; min=$m.Minimum; max=$m.Maximum
        sample_sd=$(if ($n -gt 1) { [Math]::Sqrt($ss/($n-1)) } else { $null })}
}

function Get-DlsSummary($Rows,[string]$Phase,[int]$Count) {
    $measured = @($Rows | Where-Object { $_.phase -eq $Phase -and !$_.warmup })
    if ($measured.Count -ne 2*$Count) { throw "Incomplete $Phase pairs." }
    $metrics = @('wall_s','cpu_s','peak_job_MiB')
    if ($Phase -eq 'run') { $metrics += 'ns_per_fill' }
    foreach ($metric in $metrics) {
        $a = @(); $b = @(); $d = @()
        for ($i=1; $i -le $Count; $i++) {
            $pair = @($measured | Where-Object pair -eq $i)
            $x = @($pair | Where-Object variant -ceq original)
            $y = @($pair | Where-Object variant -ceq cached)
            if ($x.Count -ne 1 -or $y.Count -ne 1 -or $null -eq $x[0].$metric -or $null -eq $y[0].$metric) {
                throw "Incomplete $Phase pair $i for $metric."
            }
            $a += $x[0].$metric; $b += $y[0].$metric; $d += $y[0].$metric - $x[0].$metric
        }
        [ordered]@{phase=$Phase; metric=$metric; original=(Get-DlsStatistics $a)
            cached=(Get-DlsStatistics $b); cached_minus_original=(Get-DlsStatistics $d)}
    }
}

function Get-DlsHostSample {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpus = @(Get-CimInstance Win32_Processor)
    [ordered]@{utc=[DateTimeOffset]::UtcNow.ToString('o'); free_MiB=[double]$os.FreePhysicalMemory/1024
        clock_MHz=@($cpus.CurrentClockSpeed); processes=$os.NumberOfProcesses; boot=$os.LastBootUpTime.ToString('o')}
}

Export-ModuleMember -Function Read-DlsConfig,Get-DlsSchedule,Get-DlsStatistics,Get-DlsSummary,Get-DlsHostSample
