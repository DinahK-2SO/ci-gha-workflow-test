#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HandoffSupport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ComparisonSupport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BootstrapSupport.psm1') -Force
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
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'comparison.json') -Raw | ConvertFrom-Json
$savedLocalAppData=$env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA=Join-Path $root 'current-user-data'
    $config.work_parent=$null
    $config.cache_root=$null
    $work=Resolve-ComparisonWorkParent $config $PSScriptRoot
    $cache=Resolve-ComparisonCacheRoot $config $PSScriptRoot
    if ($work -cne (Join-Path $env:LOCALAPPDATA 'opencv-build-test\runs') -or
        $cache -cne (Join-Path $env:LOCALAPPDATA 'opencv-build-test\cache') -or
        (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
        throw 'Portable default path resolution is incorrect or wrote state.'
    }
    $env:LOCALAPPDATA=$null
    $rejected=$false
    try { $null=Resolve-ComparisonWorkParent $config $PSScriptRoot } catch {
        if ($_.Exception.Message -notlike 'LOCALAPPDATA is unavailable*') { throw }
        $rejected=$true
    }
    if (-not $rejected) { throw 'Missing user-data directory silently selected another path.' }
    $config.work_parent=Join-Path $root 'explicit-work'
    if ((Resolve-ComparisonWorkParent $config $PSScriptRoot) -cne $config.work_parent) {
        throw 'Explicit work-parent override was ignored.'
    }
} finally { $env:LOCALAPPDATA=$savedLocalAppData }
$config.opencv_repository='fixture/alternative-source'
$configPath=Join-Path $root 'config-fixture.json'
Write-ComparisonJson $config $configPath
$parsed=Read-ComparisonConfig $configPath
if ((Resolve-ComparisonOpenCvRepository $parsed) -cne 'fixture/alternative-source') {
    throw 'The configured OpenCV repository was not selected.'
}
$config.opencv_repository='https://invalid.example/source.git'
Write-ComparisonJson $config $configPath
$rejected=$false
try { $null=Read-ComparisonConfig $configPath } catch {
    if ($_.Exception.Message -notlike 'opencv_repository must be*') { throw }
    $rejected=$true
}
if (-not $rejected) { throw 'A repository URL was accepted instead of an explicit owner/name identity.' }
$config.PSObject.Properties.Remove('opencv_repository')
$rejected=$false
try { $null=Resolve-ComparisonOpenCvRepository $config } catch {
    if ($_.Exception.Message -notlike '*no account-specific repository fallback*') { throw }
    $rejected=$true
}
if (-not $rejected) { throw 'Missing OpenCV repository fell back to an author account.' }
$checks += [ordered]@{test='portable-path-and-explicit-source-selection';passed=$true}

$freeze=Join-Path $PSScriptRoot 'scripts\msbuild\Invoke-CiPilot.ps1'
$protocolPath=Join-Path $root 'freeze\protocol.json'
$rejected=$false
try {
    & $freeze -Action Freeze -ProtocolPath $protocolPath -ConfigurationReceipt 'not-read.json' `
        -ReferenceHost 'not-read.json' -OutputRoot (Join-Path $root 'trials')
} catch {
    if ($_.Exception.Message -notlike 'Freeze requires *explicit tool-selection*') { throw }
    $rejected=$true
}
if (-not $rejected -or (Test-Path -LiteralPath $protocolPath)) { throw 'Freeze did not reject missing tools before writing state.' }
$pythonRoot=Join-Path $root 'fixture-python'
New-Item -ItemType Directory -Path (Join-Path $pythonRoot 'include') | Out-Null
$python=Join-Path $pythonRoot 'python.exe'
'fixture; never executed' | Set-Content -LiteralPath $python
'fixture' | Set-Content -LiteralPath (Join-Path $pythonRoot 'include\Python.h')
$configurationPath=Join-Path $root 'configuration.json'
Write-ComparisonJson @{
    status='configured_full_base_workload_pending_pilots';architecture='ARM64'
    dependency_files=@(@{path=$python;sha256=(Get-FileHash $python).Hash})
} $configurationPath
$hostPath=Join-Path $root 'host.json'
Write-ComparisonJson @{} $hostPath
$toolsPath=Join-Path $root 'tools.json'
$executable=[Environment]::ProcessPath
Write-ComparisonJson @{
    architecture='ARM64';cmake=$executable;measurement_python=$python;preparer_python=$python
    bash=$executable;msbuild=$executable;compiler=$executable;linker=$executable
} $toolsPath
& $freeze -Action Freeze -ProtocolPath $protocolPath -ConfigurationReceipt $configurationPath `
    -ReferenceHost $hostPath -ToolsFile $toolsPath -OutputRoot (Join-Path $root 'trials')
$frozen=Get-Content -LiteralPath $protocolPath -Raw | ConvertFrom-Json
if ($frozen.cmake -cne $executable -or $frozen.measurement_python -cne $python -or
    @($frozen.frozen_files | Where-Object path -CEQ $toolsPath).Count -ne 1) {
    throw 'Freeze did not preserve the explicitly selected tools.'
}
$checks += [ordered]@{test='explicit-tools-required-and-frozen-without-execution';passed=$true}

$seedRoot=Join-Path $root 'minimal-seed'
New-Item -ItemType Directory -Path $seedRoot | Out-Null
'Inventory-only fixture; not a runnable OpenCV payload.' |
    Set-Content -LiteralPath (Join-Path $seedRoot 'fixture.txt')
Write-ComparisonJson @{
    schema_version=1;package_kind='local-functional-handoff';created_at=(Get-Date).ToString('o')
    files=@(Get-PackageInventory $seedRoot)
} (Join-Path $seedRoot 'package-manifest.json')
$assembled=Join-Path $root 'assembled'
& (Join-Path $PSScriptRoot 'New-ComparisonFolder.ps1') -SeedPackage $seedRoot `
    -Destination $assembled -ReceiptPath (Join-Path $root 'assembly.json')
$runtime=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-manifest.json') -Raw | ConvertFrom-Json
foreach ($file in $runtime.files) {
    if ((Get-FileHash -LiteralPath (Join-Path $assembled "payload\scripts\$($file.path)")).Hash -cne $file.sha256) {
        throw 'Seed assembly did not copy the complete local runtime closure.'
    }
}
$checks += [ordered]@{test='seed-assembly-uses-local-runtime-not-parent-checkout';passed=$true}
[ordered]@{checked_at=(Get-Date).ToString('o');status='passed';checks=$checks;actual_lab_accessed=$false;full_builds_executed=0} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output 'Handoff identity, portable configuration, explicit-tool and local seed-assembly guards passed; no network or native build was used.'
