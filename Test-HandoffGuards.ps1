#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HandoffSupport.psm1') -Force
if ((Test-Path -LiteralPath $WorkRoot) -or (Test-Path -LiteralPath $OutputPath)) {
    throw 'Guard-test paths already exist.'
}
$root=Assert-LocalStudyPath $WorkRoot $PSScriptRoot
New-Item -ItemType Directory -Path $root,(Split-Path $OutputPath) -Force | Out-Null
$checks=@()
foreach ($path in @('\\not-a-real-server\not-a-share\work','.\relative-work',[IO.Path]::GetPathRoot($root),(Join-Path $root 'work'))) {
    $rejected=$false
    try { $null=Assert-LocalStudyPath $path $root } catch { $rejected=$true; $message=$_.Exception.Message }
    if (-not $rejected) { throw "Unsafe work path was accepted: $path" }
    $checks += [ordered]@{test='unsafe-output-path';input=$path;rejected=$true;error=$message}
}
$payload=Join-Path $root 'payload.txt'
'known payload' | Set-Content -LiteralPath $payload -Encoding utf8
$manifest=[ordered]@{schema_version=1;package_kind='local-functional-handoff';files=@(Get-PackageInventory $root)}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'package-manifest.json') -Encoding utf8
$null=Assert-HandoffPackage $root
$checks += [ordered]@{test='untampered-package';passed=$true}
'changed payload' | Set-Content -LiteralPath $payload -Encoding utf8
$rejected=$false
try { $null=Assert-HandoffPackage $root } catch { $rejected=$true; $message=$_.Exception.Message }
if (-not $rejected) { throw 'A modified package payload was accepted.' }
$checks += [ordered]@{test='modified-payload';rejected=$true;error=$message}
'known payload' | Set-Content -LiteralPath $payload -Encoding utf8
'unexpected' | Set-Content -LiteralPath (Join-Path $root 'extra.txt') -Encoding utf8
$rejected=$false
try { $null=Assert-HandoffPackage $root } catch { $rejected=$true; $message=$_.Exception.Message }
if (-not $rejected) { throw 'An unexpected package file was accepted.' }
$checks += [ordered]@{test='unexpected-file';rejected=$true;error=$message}
$profile=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profile.json') -Raw | ConvertFrom-Json
$identity=[ordered]@{
    profile_id=$profile.profile_id
    comparison_axis=$profile.comparison_axis
    review_commit=$profile.ci_dev.commit
    opencv_commit=$profile.opencv.commit
}
Assert-HandoffProfile $profile $identity
$checks += [ordered]@{test='matching-fixed-profile';passed=$true}
if ($profile.PSObject.Properties['compiler_budget_policy']) {
    $probe=@(& pwsh -NoLogo -NoProfile -NonInteractive -Command '[Environment]::ProcessPath; [Environment]::ProcessorCount')
    if ($LASTEXITCODE -ne 0 -or $probe.Count -ne 2 -or $probe[1] -notmatch '^[1-9][0-9]*$') {
        throw 'PowerShell runtime identity/processor-count discovery failed.'
    }
    $hash=(Get-FileHash -LiteralPath $probe[0]).Hash
    $checks += [ordered]@{test='hashable-powershell-runtime-not-alias-list';passed=$true;path=$probe[0];sha256=$hash;count=[int]$probe[1]}
}
$legacy=$profile | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$legacy.conditions=@('baseline','shared')
$floating=$profile | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$floating.ci_dev.commit='main'
$identical=$profile | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$identical.ci_dev.commit=$profile.ci_baseline.commit
$mismatch=$identity | ConvertTo-Json | ConvertFrom-Json
$mismatch.review_commit='f'*40
foreach ($case in @(
    @{name='legacy-profile';profile=$legacy;manifest=$identity;error='*baseline/fixed*'},
    @{name='floating-commit';profile=$floating;manifest=$identity;error='*full fixed commit SHA*'},
    @{name='identical-commits';profile=$identical;manifest=$identity;error='*commits must differ*'},
    @{name='manifest-profile-mismatch';profile=$profile;manifest=$mismatch;error='*identities differ*'}
)) {
    $rejected=$false
    try { Assert-HandoffProfile $case.profile $case.manifest } catch {
        if ($_.Exception.Message -notlike $case.error) { throw }
        $rejected=$true
        $message=$_.Exception.Message
    }
    if (-not $rejected) { throw "Invalid package identity was accepted: $($case.name)" }
    $checks += [ordered]@{test=$case.name;rejected=$true;error=$message}
}
[ordered]@{checked_at=(Get-Date).ToString('o');status='passed';checks=$checks;actual_lab_accessed=$false} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output 'Handoff path and integrity guards passed; no actual network/share path was accessed.'
