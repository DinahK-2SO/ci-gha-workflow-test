#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config.json",
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ("dls-" + [guid]::NewGuid().ToString('N'))),
    [string]$VisualStudio
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\tools\Experiment.psm1" -Force
Import-Module "$PSScriptRoot\tools\DlsTools.psm1" -Force
$config = Read-DlsConfig $ConfigPath
$out = [IO.Path]::GetFullPath($OutputDirectory)
Assert-DlsSafePath $out
if (Test-Path -LiteralPath $out) { throw "Refusing to overwrite: $out" }
$null = New-Item -ItemType Directory -Path $out
$text = Join-Path $out 'report.txt'
$seed = Join-Path $PSScriptRoot 'seed'
$result = [ordered]@{schema=1; status='running'; started=[DateTimeOffset]::UtcNow.ToString('o')
    config=$config; trials=@(); setup=@(); summary=@()}

function Emit([string]$line) {
    Add-Content -LiteralPath $text -Value $line -Encoding utf8
    Write-Host $line
}
function Save-Result {
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$out\result.tmp" -Encoding utf8
    [IO.File]::Move("$out\result.tmp","$out\result.json",$true)
}
function Record-Command([string]$stage,[string]$exe,[string[]]$arguments,[string]$log) {
    $run = Invoke-DlsEnvironment $environment {
        [DlsMeasuredProcess]::Run($exe,$arguments,$out,$log,180)
    }
    [ordered]@{stage=$stage; executable=$exe; arguments=$arguments; log=$log; process=$run}
}
function Assert-Success($command) {
    $p = $command.process
    if ($p.ExitCode -ne 0 -or $p.TimedOut) {
        throw "$($command.stage) failed: exit=$($p.ExitCode), timeout=$($p.TimedOut), active=$($p.ActiveAtCommandExit); see $($command.log)"
    }
}
function Invoke-Trial([string]$phase,$pair,[string]$variant,[int]$slot) {
    Assert-DlsAvailableHost
    $prefix = '{0}-{1}-{2:D2}-{3}' -f $phase,$(if ($pair.warmup) {'warmup'} else {'sample'}),$pair.pair,$variant
    $log = "$out\$prefix.log"
    $before = Get-DlsHostSample
    $sweeps = $config.sweeps_per_runtime_trial
    if ($phase -ceq 'compile') {
        # Use the same object name, flags and working directory for both sources.
        $exe = $tools.Compiler
        $argv = $flags + @('/c',"$seed\$variant.cpp","/Fo$out\unit.obj")
    } else {
        $exe = "$out\check.exe"
        $argv = @($variant,"$sweeps")
    }
    $cmd = Record-Command $prefix $exe $argv $log
    $p = $cmd.process
    $row = [ordered]@{phase=$phase; warmup=$pair.warmup; pair=$pair.pair; slot=$slot; variant=$variant
        before=$before; after=(Get-DlsHostSample); command=$cmd; wall_s=$p.OuterWallSeconds
        cpu_s=$p.ProcessTreeCpuSeconds; peak_job_MiB=$p.PeakJobMemoryBytes/1MB; ns_per_fill=$null}
    $result.trials += $row
    try {
        Assert-Success $cmd
        if ($phase -ceq 'compile') {
            $obj = "$out\unit.obj"
            $row.machine = Get-DlsNativeMachine $obj $tools.Platform -Coff
            $row.object_bytes = (Get-Item -LiteralPath $obj).Length
            $row.object_sha256 = (Get-FileHash -LiteralPath $obj).Hash
            if (!$pair.warmup -and $pair.pair -eq $config.compile_pairs) {
                Copy-Item -LiteralPath $obj -Destination "$out\$variant.obj"
            }
            Remove-Item -LiteralPath $obj
        } else {
            $line = (Get-Content -LiteralPath $log -Raw).Trim()
            if ($line -cnotmatch "^PASS $variant $sweeps 40 ([1-9][0-9]*)$") { throw "Invalid checker output: $line" }
            $row.kernel_ns = [long]$Matches[1]
            $row.fill_calls = 40*$sweeps
            $row.ns_per_fill = $row.kernel_ns/[double]$row.fill_calls
            $row.correctness = $line
        }
    } finally {
        Emit ("TRIAL " + ($row | ConvertTo-Json -Depth 8 -Compress))
        Save-Result
    }
    $row
}

$lock = $null
$held = $false
try {
    Emit "DLS paired comparison | $out"
    $lock = [Threading.Mutex]::new($false,'Local\OpenCV-Dls-Paired-Comparison')
    try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { throw 'Another DLS comparison is active in this session.' }
    foreach ($name in 'CL','_CL_','CFLAGS','CXXFLAGS','LINK','_LINK_') {
        if ([Environment]::GetEnvironmentVariable($name)) { throw "Uncontrolled tool override: $name" }
    }
    Assert-DlsAvailableHost
    if (!$VisualStudio) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $component = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {'ARM64'} else {'x86.x64'}
        $VisualStudio = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires "Microsoft.VisualStudio.Component.VC.Tools.$component" -property installationPath
        if ($LASTEXITCODE -ne 0 -or !$VisualStudio) { throw 'Native VS 2022 C++ tools not found; specify -VisualStudio.' }
    }
    $tools = Get-DlsToolset $VisualStudio
    $environment = New-DlsEnvironment -Tools $tools -Directory "$out\environment"
    $flags = @('/nologo','/std:c++14','/O2','/Ob2','/MD','/EHa','/fp:precise','/DNDEBUG','/W4','/WX')
    $hashes = $tools.FrozenHashes.Clone()
    foreach ($f in @((Get-ChildItem -LiteralPath $seed -File).FullName) + @($PSCommandPath,"$PSScriptRoot\tools\Experiment.psm1",$ConfigPath)) {
        $hashes[[IO.Path]::GetFullPath($f)] = (Get-FileHash -LiteralPath $f).Hash
    }
    $prov = Get-Content "$seed\provenance.json" -Raw | ConvertFrom-Json -AsHashtable
    foreach ($f in $prov.files_sha256.Keys) {
        if ($hashes["$seed\$f"] -ne $prov.files_sha256[$f]) { throw "Provenance mismatch: $f" }
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $power = & powercfg.exe /getactivescheme
    if ($LASTEXITCODE -ne 0) { throw 'Unable to identify active power scheme.' }
    $result.host = [ordered]@{os=$os.Caption; version=$os.Version; ram_MiB=$os.TotalVisibleMemorySize/1024
        cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
        architecture=$tools.Platform.architecture; power_scheme=($power -join ' '); initial=(Get-DlsHostSample)}
    $result.toolchain = [ordered]@{compiler=$tools.Compiler; version=$tools.CompilerVersion; pe=$tools.CompilerMachine
        flags=$flags; environment=$environment.Metadata}
    $result.sha256 = $hashes
    Emit ("CONFIG " + ($config | ConvertTo-Json -Compress))
    Emit ("HOST " + ($result.host | ConvertTo-Json -Depth 5 -Compress))
    Emit ("TOOLCHAIN " + ($result.toolchain | ConvertTo-Json -Depth 5 -Compress))
    foreach ($phase in 'compile','run') {
        if ($phase -ceq 'run') {
            $link = Record-Command 'build shared checker' $tools.Compiler ($flags + @("$seed\check.cpp","$out\original.obj","$out\cached.obj","/Fo$out\check.obj","/Fe$out\check.exe",'/link','/INCREMENTAL:NO')) "$out\link.log"
            $result.setup += $link
            Assert-Success $link
            $result.executable = [ordered]@{sha256=(Get-FileHash "$out\check.exe").Hash; machine=(Get-DlsNativeMachine "$out\check.exe" $tools.Platform)}
        }
        $count = if ($phase -ceq 'compile') { $config.compile_pairs } else { $config.runtime_pairs }
        foreach ($pair in (Get-DlsSchedule $config.warmup_pairs_per_phase $count)) {
            $both = @{}
            for ($slot=0; $slot -lt 2; $slot++) {
                $v = $pair.order[$slot]
                $both[$v] = Invoke-Trial $phase $pair $v ($slot+1)
            }
            $metric = if ($phase -ceq 'compile') {'wall_s'} else {'ns_per_fill'}
            Emit ('PAIR {0} #{1} warmup={2} order={3} | {4}: original={5:F6} cached={6:F6} delta(cached-original)={7:F6}' -f
                $phase,$pair.pair,$pair.warmup,($pair.order -join '/'),$metric,$both.original.$metric,$both.cached.$metric,($both.cached.$metric-$both.original.$metric))
        }
    }
    foreach ($f in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $f).Hash -ne $hashes[$f]) { throw "Input changed during experiment: $f" }
    }
    $powerAfter = & powercfg.exe /getactivescheme
    if ($LASTEXITCODE -ne 0 -or ($powerAfter -join ' ') -cne $result.host.power_scheme) { throw 'Power scheme changed during experiment.' }
    foreach ($s in @((Get-DlsSummary $result.trials 'compile' $config.compile_pairs)) + @((Get-DlsSummary $result.trials 'run' $config.runtime_pairs))) {
        $result.summary += $s
        Emit ("SUMMARY " + ($s | ConvertTo-Json -Compress -Depth 4))
    }
    $result.status = 'passed'
} catch {
    $result.status = 'failed'; $result.error = $_.Exception.Message
    Emit "FAILED: $($result.error)"
    throw
} finally {
    if ($held) { $lock.ReleaseMutex() }
    if ($null -ne $lock) { $lock.Dispose() }
    $result.finished = [DateTimeOffset]::UtcNow.ToString('o')
    Save-Result
    Emit "STATUS $($result.status) | $text | $out\result.json"
}
