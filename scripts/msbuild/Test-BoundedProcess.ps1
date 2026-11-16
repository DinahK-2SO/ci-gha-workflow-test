#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Python = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Bounded-process test output already exists.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$root = (Get-Item -LiteralPath $OutputDirectory).FullName
if (-not $Python) {
    $Python = (& python -c 'import ctypes; p=ctypes.create_unicode_buffer(32768); n=ctypes.windll.kernel32.GetModuleFileNameW(None,p,len(p)); assert n; print(p.value)').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Python fixture prerequisite is unavailable.' }
}
Add-Type -Path (Join-Path $PSScriptRoot 'BoundedProcess.cs')
$fixture = Join-Path $PSScriptRoot 'tests\bounded_fixture.py'
$results = @()
foreach ($code in @(0,7)) {
    $result = [OpenCvBoundedProcess]::Run(
        $python, @($fixture,'exit',"$code"), $root, (Join-Path $root "exit-$code.log"), 30)
    if ($result.ExitCode -ne $code -or $result.TimedOut) { throw "Exit propagation failed: $code" }
    $results += [ordered]@{ test="exit-$code"; result=$result }
}
$timeoutLog = Join-Path $root 'timeout.log'
$timeout = [OpenCvBoundedProcess]::Run($python,@($fixture,'parent'),$root,$timeoutLog,2)
$timeout | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'timeout-process.json') -Encoding utf8
if (-not $timeout.TimedOut -or $timeout.ExitCode -ne 124) { throw 'Owned-process timeout was not enforced.' }
$text = Get-Content -LiteralPath $timeoutLog -Raw
if ($text -notmatch 'child_pid=(\d+)') { throw 'The child-process cleanup case did not start its child.' }
$childId = [int]$Matches[1]
$remaining = Get-Process -Id $childId -ErrorAction SilentlyContinue
if ($remaining -and -not $remaining.WaitForExit(5000)) { throw 'An owned child remained alive after timeout.' }
$results += [ordered]@{ test='owned-tree-timeout'; result=$timeout; child_released=$true }
[ordered]@{
    checked_at=(Get-Date).ToString('o')
    status='success'
    helper_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'BoundedProcess.cs')).Hash
    python_executable=$python
    results=$results
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'validation.json') -Encoding utf8
Write-Output 'Bounded process checks passed: success, native failure, and owned descendant cleanup on timeout.'
