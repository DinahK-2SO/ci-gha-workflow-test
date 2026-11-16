#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath=(Join-Path $PSScriptRoot 'comparison.json'),
    [switch]$Check,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ('OpenCvBoundedProcess' -as [type]) {
    $childArguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-ConfigPath',$ConfigPath)
    if ($Check) { $childArguments+='-Check' }
    if ($PrepareOnly) { $childArguments+='-PrepareOnly' }
    Write-Host 'Starting a fresh PowerShell process to avoid reusing an already loaded runtime helper.'
    & ([Environment]::ProcessPath) @childArguments
    if ($LASTEXITCODE -ne 0) { throw "Comparison child process failed (exit $LASTEXITCODE). See the reported receipt/log paths." }
    return
}
$payload=Join-Path $PSScriptRoot 'payload'
if (-not (Test-Path -LiteralPath $payload)) {
    foreach ($name in @('HandoffSupport.psm1','ComparisonSupport.psm1','BootstrapSupport.psm1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
            throw "Missing runtime payload and source bootstrap file: $name. Restore the complete handoff source folder or a complete assembled comparison folder."
        }
        Import-Module (Join-Path $PSScriptRoot $name) -Force
    }
    Assert-ComparisonSourceTree $PSScriptRoot
    $config=Read-ComparisonConfig $ConfigPath
    $parent=Resolve-ComparisonWorkParent $config $PSScriptRoot
    $null=Resolve-ComparisonOpenCvRepository $config
    $tools=Find-HandoffToolchain
    if ($Check) {
        $cacheRoot=Resolve-ComparisonCacheRoot $config $PSScriptRoot
        Write-Output "Validated source inputs/config/toolchain only for native $($tools.architecture) (PowerShell process: $($tools.process_architecture)). Payload is absent; normal invocation will verify/reuse cached dependencies, download missing archives and retrieve exact sources. Cache: $cacheRoot. Cache contents/network access are not checked; no downloads or builds started."
        return
    }
    $folder=New-ComparisonBootstrap $PSScriptRoot $ConfigPath $parent
    $arguments=@()
    if ($PrepareOnly) { $arguments+='-PrepareOnly' }
    Invoke-ComparisonScript (Join-Path $folder 'Run-Comparison.ps1') $arguments
    return
}
foreach ($name in @('HandoffSupport.psm1','package-manifest.json','comparison-launchers.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $name) -PathType Leaf)) {
        throw "Incomplete runtime payload: $name. Preserve this failed folder; use a clean checkout or a complete assembled folder. Automatic replacement is disabled."
    }
}
Import-Module (Join-Path $payload 'HandoffSupport.psm1') -Force
$manifest=Assert-HandoffPackage $payload
$launchers=Get-Content -LiteralPath (Join-Path $payload 'comparison-launchers.json') -Raw | ConvertFrom-Json
foreach ($file in $launchers) {
    if ($file.name -cnotin @('Run-Comparison.ps1','ComparisonSupport.psm1') -or
        (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $file.name)).Hash -cne $file.sha256) {
        throw 'Comparison launcher differs from the frozen payload.'
    }
}
Import-Module (Join-Path $PSScriptRoot 'ComparisonSupport.psm1') -Force
$config=Read-ComparisonConfig $ConfigPath
$parent=Resolve-ComparisonWorkParent $config $PSScriptRoot
$profile=Get-Content -LiteralPath (Join-Path $payload 'profile.json') -Raw | ConvertFrom-Json
Assert-HandoffProfile $profile $manifest
if ($config.PSObject.Properties['opencv_repository'] -and
    $config.opencv_repository -cne $profile.opencv.repository) {
    throw 'The OpenCV repository differs from the frozen payload. Use the source folder to prepare a new payload; it is not retargeted in place.'
}
$tools=Find-HandoffToolchain -Architecture $profile.architecture
if ($Check) {
    Write-Output "Validated config/payload/toolchain. $($config.commits.Count) selected commits; no work started."
    return
}
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$root=Join-Path $parent ('run-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$lock=[IO.File]::Open((Join-Path $parent 'comparison.lock'),
    [IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$record=[ordered]@{
    started_at=(Get-Date).ToString('o'); status='preparing'; work_root=$root
    architecture=$profile.architecture;installed_tools=$tools
    config_sha256=$null
    seed_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $payload 'package-manifest.json')).Hash
    build_budget_seconds=1800*$config.commits.Count; consumed_outer_build_seconds=0
    performance_eligible=$false; timing_use='diagnostic_only'; automatic_retries=$false
    detailed_interference_capture='Not enabled; the earlier ABC observer gaps are not repaired by this launcher.'
    cases=@($config.commits | ForEach-Object {
        [ordered]@{label=$_.label;commit=$_.commit;condition='baseline';protocol=$null;export=$null;status='not_started'}
    })
}
$summary=Join-Path $root 'summary.json'
$oldPrompt=$env:GIT_TERMINAL_PROMPT
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $frozenConfig=Join-Path $root 'comparison.json'
    Write-ComparisonJson $config $frozenConfig
    $record.config_sha256=(Get-FileHash -LiteralPath $frozenConfig).Hash
    Write-ComparisonJson $record $summary
    Write-Output "Comparison run: $root"
    $env:GIT_TERMINAL_PROMPT='0'
    $package=Join-Path $root 'package'
    Copy-Item -LiteralPath $payload -Destination $package -Recurse
    $null=Assert-HandoffPackage $package
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $package 'scripts\msbuild\BoundedProcess.cs') -Raw)
    $entries=@(New-ComparisonSources $config $package $root)
    $study=Join-Path $root 'study'
    Invoke-ComparisonScript (Join-Path $package 'Start-Study.ps1') @(
        '-Action','Prepare','-WorkRoot',$study,'-ConfirmLocalExecution')
    $prepared=Get-Content -LiteralPath (Join-Path $study 'preparation.json') -Raw | ConvertFrom-Json
    $scripts=Join-Path $prepared.local_package 'scripts\msbuild'
    $baseConfig=Get-Content -LiteralPath $prepared.configuration -Raw | ConvertFrom-Json
    $baseProtocol=Get-Content -LiteralPath $prepared.protocol -Raw | ConvertFrom-Json
    $results=Join-Path $root 'results'
    New-Item -ItemType Directory -Path $results | Out-Null
    for ($index=0; $index -lt $entries.Count; $index++) {
        $entry=$entries[$index]
        $label=$config.commits[$index].label
        $caseRoot=Join-Path $results ("{0:d2}-{1}" -f ($index+1),$label)
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $checkout=if($index -eq 0){Join-Path $study 'ci-baseline'}elseif($index -eq 1){
            Join-Path $study 'ci-dev'}else{Join-Path $study "ci-$($index+1)"}
        if ($index -gt 1) {
            & git -c core.autocrlf=false clone --quiet --no-checkout --single-branch `
                --branch $entry.bundle_ref.Substring(11) (Join-Path $package 'sources\ci.bundle') $checkout
            if ($LASTEXITCODE) { throw 'Additional commit restoration failed.' }
            & git -C $checkout -c core.autocrlf=false checkout --quiet --detach $entry.commit
            if ($LASTEXITCODE) { throw 'Additional exact checkout failed.' }
        }
        $configuration=$baseConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $configuration.repositories[1]=[pscustomobject]@{
            path=$checkout; repository=$entry.repository; branch_name=$entry.branch_name
            target_commit_sha=$entry.commit; actual_commit_sha=$entry.commit
        }
        $configurationPath=Join-Path $caseRoot 'configuration.json'
        Write-ComparisonJson $configuration $configurationPath
        $contract=Join-Path $caseRoot 'build-contract.json'
        $capture=[OpenCvBoundedProcess]::Run($baseProtocol.preparer_python,@(
            '-B',(Join-Path $scripts 'build_contract.py'),'--ci-root',$checkout,'--ci-commit',$entry.commit,
            '--workdir',$study,'--builddir',$configuration.build_directory,'--bash',$baseProtocol.bash,
            '--capture-root',(Join-Path $caseRoot 'capture'),'--output',$contract),
            $study,(Join-Path $caseRoot 'capture-controller.log'),60)
        if ($capture.TimedOut -or $capture.ExitCode) { throw "Command capture failed: $label; see $caseRoot" }
        $protocolPath=Join-Path $caseRoot 'protocol.json'
        Invoke-ComparisonScript (Join-Path $scripts 'Invoke-CiPilot.ps1') @(
            '-Action','Freeze','-ProtocolPath',$protocolPath,'-ConfigurationReceipt',$configurationPath,
            '-ReferenceHost',$baseProtocol.reference_host,'-ToolsFile',(Join-Path $study 'preparation\tools.json'),
            '-OutputRoot',(Join-Path $caseRoot 'trials'),'-BuildContract',$contract,
            '-SharedCompilerJobs',[string]$prepared.expected_shared_compiler_jobs)
        $record.cases[$index].protocol=$protocolPath
        $record.cases[$index].export=Join-Path $caseRoot 'export'
        Write-ComparisonJson $record $summary
    }
    $casesFile=Join-Path $results 'cases.json'
    Write-ComparisonJson ([ordered]@{cases=$record.cases;build_budget_seconds=$record.build_budget_seconds}) $casesFile
    if ($PrepareOnly) {
        $record.status='prepared_only_no_native_builds'
    } else {
        $record.status='running'
        Invoke-ComparisonCases $record.cases $scripts $record $summary
        Invoke-ComparisonScript (Join-Path $scripts 'Test-CiFunctionalPair.ps1') @(
            '-CasesFile',$casesFile,'-OutputPath',(Join-Path $results 'functional-summary.json'))
        $record.status='configured_comparison_passed'
    }
} catch {
    $record.status='failed'
    $record.error=$_.Exception.Message
    throw
} finally {
    $env:GIT_TERMINAL_PROMPT=$oldPrompt
    $lock.Dispose()
    if (Test-Path -LiteralPath $root) {
        if ($record.status -in @('preparing','running')) {
            $record.status='interrupted'
            $record.error='Comparison interrupted before completion.'
        }
        $record.finished_at=(Get-Date).ToString('o')
        Write-ComparisonJson $record $summary
        Write-Host "Run status: $($record.status). Summary: $summary"
    }
}
