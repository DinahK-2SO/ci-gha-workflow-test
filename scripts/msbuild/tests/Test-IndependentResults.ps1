#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$WorkRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $WorkRoot) { throw 'Preserve prior result fixtures.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$policy=@{msbuild_node_reuse=$false}
$cases=@()
foreach ($number in 1..2) {
    $directory=Join-Path $WorkRoot "case-$number"
    New-Item -ItemType Directory -Path $directory | Out-Null
    $source=@{repository="fixture/source-$number";branch_name="branch-$number";target_commit_sha=([string]$number*40);actual_commit_sha=([string]$number*40)}
    $ci=@{repository='fixture/ci';branch_name='main';target_commit_sha=('a'*40);actual_commit_sha=('a'*40)}
    $configuration=Join-Path $directory 'configuration.json'
    $cache=([string]$number*64)
    Write-ComparisonJson @{
        architecture='ARM64';build_directory='build-portable';repositories=@($source,$ci)
        cache_sha256=$cache;workload_check=@{modules=@('fixture-module')}
    } $configuration
    $arguments=@('--build','build-portable','--config','Release')
    $contract=Join-Path $directory 'contract.json'
    Write-ComparisonJson @{
        ci_commit=$ci.target_commit_sha;action_sha256=('b'*64);script_sha256=('c'*64);arguments=$arguments
    } $contract
    $protocol=Join-Path $directory 'protocol.json'
    Write-ComparisonJson @{
        order=@('baseline');comparison_axis='independent_sources';architecture='ARM64'
        configuration=$configuration;build_contract=$contract;test_build_policy=$policy
        role='functional_qualification';performance_eligible=$false;timing_use='diagnostic_only'
        smoke_cases=@(@{tests=@('Fixture.pass')});build_timeout_seconds=1800
        frozen_files=@(@{path=$contract;sha256=(Get-FileHash $contract).Hash})
    } $protocol
    Write-ComparisonJson @{
        status='functional_build_passed';protocol_sha256=(Get-FileHash $protocol).Hash
        role='functional_qualification';performance_eligible=$false;timing_use='diagnostic_only'
        test_build_policy=$policy
        clean_arguments=@('--build','build-portable','--target','clean','--config','Release','--','/nr:false')
        clean=@{ExitCode=0;TimedOut=$false};smoke=@(@{tests=@('Fixture.pass')})
        binding_dll_load=@{ExitCode=0;TimedOut=$false};artifacts=@(@{machine='0xaa64'})
        build=@{ExitCode=0;TimedOut=$false;OuterWallSeconds=1.1;ProcessTreeCpuSeconds=1}
    } (Join-Path $directory 'execution.json')
    Write-ComparisonJson @{
        comparison_axis='independent_sources';condition='baseline';inputs=@{builddir='build-portable'}
        role='functional_qualification';performance_eligible=$false;timing_use='diagnostic_only'
        test_build_policy=$policy;repositories=@($ci,$source);cache_sha256=$cache;build_seconds=1.0
        runner_sha256=('d'*64);cmake_probe_sha256=('e'*64);cmake_sha256=('f'*64);bash_sha256=('a'*64)
        build_contract_sha256=(Get-FileHash $contract).Hash.ToLowerInvariant()
        action_sha256=('b'*64);extracted_build_step_sha256=('c'*64)
        native_build=@{
            arguments=$arguments;effective_arguments=($arguments+@('--','/nr:false'))
            status='success';test_build_policy=$policy
        }
    } (Join-Path $directory 'trial.json')
    Write-ComparisonJson @{
        status='exported';role='functional_qualification';performance_eligible=$false;timing_use='diagnostic_only'
        binaries=@(@{relative_path="fixture-output-$number.dll"})
        evidence=@('execution.json','trial.json' | ForEach-Object {
            @{name=$_;sha256=(Get-FileHash (Join-Path $directory $_)).Hash}
        })
    } (Join-Path $directory 'archive-manifest.json')
    $cases+=@{
        label="case-$number";condition='baseline';protocol=$protocol;export=$directory
        selection=@{
            'opencv-repo'=$source.repository;'opencv-branch'=$source.branch_name;'opencv-commit'=$source.target_commit_sha
            'ci-gha-repo'=$ci.repository;'ci-gha-branch'=$ci.branch_name;'ci-gha-commit'=$ci.target_commit_sha
        }
    }
}
$casesFile=Join-Path $WorkRoot 'cases.json'
$validator=Join-Path $SourceRoot 'scripts\msbuild\Test-CiFunctionalPair.ps1'
Write-ComparisonJson @{cases=$cases;build_budget_seconds=3600} $casesFile
$summary=Join-Path $WorkRoot 'valid.json'
& $validator -CasesFile $casesFile -OutputPath $summary | Out-Null
$result=Get-Content $summary -Raw | ConvertFrom-Json
if ($result.conditions.Count -ne 2 -or $result.same_common_helpers_tools_cache_and_output_inventory -or
    -not $result.case_specific_configurations -or $null -ne $result.cache_sha256) {
    throw 'Independent output/cache differences were misreported as a shared configuration.'
}
[ordered]@{test='independent-result-caches-and-output-inventories';passed=$true}
$cases[1].selection.'opencv-commit'='f'*40
Write-ComparisonJson @{cases=$cases;build_budget_seconds=3600} $casesFile
$rejected=$false
try { & $validator -CasesFile $casesFile -OutputPath (Join-Path $WorkRoot 'wrong-source.json') | Out-Null } catch {
    if ($_.Exception.Message -notlike 'Case source selection differs*') { throw }
    $rejected=$true
}
if (-not $rejected) { throw 'Another case source was accepted by aggregate validation.' }
[ordered]@{test='result-source-selection-mismatch-rejected';passed=$true}
Write-ComparisonJson @{cases=@($cases[0]);build_budget_seconds=1800} $casesFile
$single=Join-Path $WorkRoot 'single.json'
& $validator -CasesFile $casesFile -OutputPath $single | Out-Null
if ((Get-Content $single -Raw | ConvertFrom-Json).conditions.Count -ne 1) { throw 'Single-case result was lost.' }
[ordered]@{test='single-case-aggregate-result';passed=$true}
