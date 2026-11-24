#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\runtime-matrix.jsonc",
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ("dls-matrix-" + [guid]::NewGuid().ToString('N'))),
    [string]$Python = 'python',
    [switch]$List
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\matrix\MatrixConfig.psm1" -Force
$cases = @(Read-RuntimeMatrix $ConfigPath)
$selected = @($cases | Where-Object { $_.enabled })
if ($List) {
    $cases | ForEach-Object { [pscustomobject]@{id=$_.id; enabled=$_.enabled; command=$_.command -join ' ';
        launches=$_.launches; blocks=$_.blocks; slots_per_variant=4*$_.launches*$_.blocks; sweeps=$_.sweeps} } | Format-Table -AutoSize
    return
}
if (!$selected.Count) { throw 'No environments selected. Enable an entry in the config.' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw "Refusing to overwrite: $out" }
$worker = "$PSScriptRoot\matrix\worker.py"
Import-Module "$PSScriptRoot\tools\DlsTools.psm1" -Force

function Invoke-Worker([string]$exe, [array]$argv, [string]$log) {
    & $exe @argv *> $log
    if ($LASTEXITCODE -ne 0) { throw "Worker exited $LASTEXITCODE. $(Get-Content -LiteralPath $log -Tail 3 | Out-String)" }
}
function Guest-Path([string]$distro,[string]$path) {
    $value = & wsl.exe --distribution $distro --exec wslpath -a $path
    if ($LASTEXITCODE -or !$value) { throw "WSL cannot translate $path in $distro" }
    ($value -join '').Trim()
}
function Save-Matrix {
    $rows | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath "$out\matrix.json" -Encoding utf8
}
function Get-MatrixHost {
    $os = Get-CimInstance Win32_OperatingSystem
    $scheme = & powercfg.exe /getactivescheme
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read host power scheme' }
    [ordered]@{
        utc=[DateTimeOffset]::UtcNow.ToString('o'); os=$os.Version; boot=$os.LastBootUpTime.ToString('o')
        cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,CurrentClockSpeed)
        available_MiB=$os.FreePhysicalMemory/1024; power_scheme=($scheme -join ' ').Trim()
    }
}

$lock = [Threading.Mutex]::new($false,'Local\OpenCV-Dls-Paired-Comparison')
$held = $false
try {
    try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { throw 'Another DLS comparison is active.' }
    Assert-DlsAvailableHost
    if (Get-Process | Where-Object ProcessName -in 'gcc','g++','cc1plus','as','ld','ld.lld','collect2') { throw 'A GNU toolchain is busy.' }
    $null = New-Item -ItemType Directory -Path $out
    $null = New-Item -ItemType Directory -Path "$out\cases","$out\environments","$out\logs"
    Copy-Item -LiteralPath $ConfigPath -Destination "$out\config.jsonc"
    $rows = @()
    foreach ($e in $selected) {
        $id = $e.id; $c = $e.command
        $caseOut = Join-Path "$out\cases" $id
        $log = Join-Path "$out\logs" "$id.log"
        $row = [ordered]@{id=$id; command=$c; status='running'; launches=$e.launches; blocks=$e.blocks;
            sweeps=$e.sweeps; version=$null; target=$null; slots=$null; original_ns=$null; cached_ns=$null;
            cached_pct=$null; interval95=$null; band_pct=$e.practical_band_pct; decision=$null; host_before=$null; host_after=$null; error=$null}
        $rows += $row; Save-Matrix
        Write-Host "Running $id ($($c -join ' ')) ..."
        try {
            $row.host_before=Get-MatrixHost
            $common = @('--launches',"$($e.launches)",'--blocks',"$($e.blocks)",'--sweeps',"$($e.sweeps)",'--seed',"$($e.seed)",'--cpu',"$($e.cpu)")
            if ($null -ne $e.practical_band_pct) {
                $common += @('--practical-band-pct', $e.practical_band_pct.ToString([Globalization.CultureInfo]::InvariantCulture))
            }
            if ($c[0] -ceq 'wsl') {
                $guestWorker = Guest-Path $c[1] $worker
                $guestOut = Guest-Path $c[1] $caseOut
                Invoke-Worker 'wsl.exe' (@('--distribution',$c[1],'--exec','python3','-B',$guestWorker,'--system','wsl',
                    '--family',$c[2],'--compiler',$c[3],'--out',$guestOut)+$common) $log
            } else {
                $py = (Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
                $argv = @('-B',$worker,'--system','windows','--out',$caseOut)+$common
                if ($c[0] -ceq 'msvc') {
                    $ranges = @{'2019'='[16.0,17.0)';'2022'='[17.0,18.0)';'2026'='[18.0,19.0)'}
                    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
                    $vs = & $vswhere -latest -products '*' -version $ranges[$c[1]] -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
                    if ($LASTEXITCODE -or !$vs) { throw "VS $($c[1]) native x64 C++ tools not found" }
                    $tools = Get-DlsToolset $vs
                    $envDir = Join-Path "$out\environments" $id
                    $native = New-DlsEnvironment -Tools $tools -Directory $envDir
                    $argv += @('--family','msvc','--year',$c[1],'--compiler',$tools.Compiler)
                    Invoke-DlsEnvironment $native { Invoke-Worker $py $argv $log }
                } else {
                    Invoke-Worker $py ($argv+@('--family',$c[1],'--compiler',$c[2])) $log
                }
            }
            $result = Get-Content -LiteralPath "$caseOut\summary.json" -Raw | ConvertFrom-Json
            if ($result.status -cne 'passed' -or $result.slots -ne (8*$e.launches*$e.blocks)) { throw 'Incomplete case result' }
            $row.host_after=Get-MatrixHost
            if ($row.host_after.power_scheme -cne $row.host_before.power_scheme -or $row.host_after.boot -cne $row.host_before.boot) {
                throw 'Host boot session or power scheme changed during the case.'
            }
            $row.status='passed'; $row.slots=$result.slots; $row.version=$result.version; $row.target=$result.target
            $row.original_ns=$result.median_ns_per_fill.A; $row.cached_ns=$result.median_ns_per_fill.B
            $row.cached_pct=$result.contrasts_pct.cached_vs_original.estimate
            $row.interval95=$result.contrasts_pct.cached_vs_original.bootstrap95
            $row.decision=$result.band_decision
            Get-Content -LiteralPath "$caseOut\report.txt" | Write-Host
        } catch {
            $row.status='failed'; $row.error=$_.Exception.Message.Trim()
            Write-Warning "$id failed: $($row.error)"
        }
        Save-Matrix
    }
    $table = @('environment | status | A ns/fill | B ns/fill | order-adjusted B vs A | approximate 95% interval | practical band: interpretation')
    foreach ($row in $rows) {
        if ($row.status -eq 'failed') { $table += "$($row.id) | FAILED | $($row.error)"; continue }
        $ci = if ($null -eq $row.interval95) {'n/a (smoke)'} else {'[{0:F2}%, {1:F2}%]' -f $row.interval95[0],$row.interval95[1]}
        $band = if ($null -eq $row.band_pct) {'none'} else {"+/-$($row.band_pct)%"}
        $table += '{0} | passed | {1:F2} | {2:F2} | {3:F2}% | {4} | {5}: {6}' -f $row.id,$row.original_ns,$row.cached_ns,$row.cached_pct,$ci,$band,$row.decision
    }
    $table | Set-Content -LiteralPath "$out\matrix.txt" -Encoding utf8
    $table | Write-Host
    Write-Host "Results: $out"
    if (@($rows | Where-Object { $_.status -ne 'passed' }).Count) { throw 'One or more selected environments failed; see matrix.json and case logs.' }
} finally {
    if ($held) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
