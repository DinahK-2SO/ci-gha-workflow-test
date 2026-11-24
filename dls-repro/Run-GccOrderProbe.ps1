#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CompilerBin,
    [string]$Python = 'python',
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ("dls-order-" + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\tools\DlsTools.psm1" -Force
$bin = (Resolve-Path -LiteralPath $CompilerBin).Path
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw "Refusing to overwrite: $out" }
$pythonExe = (Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$lock = [Threading.Mutex]::new($false,'Local\OpenCV-Dls-Paired-Comparison')
$held = $false
try {
    try { $held = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { throw 'Another DLS comparison is active in this session.' }
    Assert-DlsAvailableHost
    if (Get-Process | Where-Object ProcessName -in 'gcc','g++','cc1plus','as','ld','ld.lld','collect2') {
        throw 'Another GNU compiler, assembler or linker is active.'
    }
    Write-Host "GCC runtime order probe; results: $out"
    & $pythonExe -B "$PSScriptRoot\order-probe\run.py" --bin $bin --out $out
    if ($LASTEXITCODE -ne 0) { throw "GCC order probe failed (exit $LASTEXITCODE); no completed result. Inspect $out if created." }
} finally {
    if ($held) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
