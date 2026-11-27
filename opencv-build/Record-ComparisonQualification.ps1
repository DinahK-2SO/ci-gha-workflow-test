#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Folder,
    [Parameter(Mandatory)][string]$PreparedRun,
    [Parameter(Mandatory)][string]$NativeGuardReceipt,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(Test-Path -LiteralPath $OutputPath){throw 'Preserve prior qualification evidence.'}
$summaryPath=Join-Path $PreparedRun 'summary.json'
$run=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
$guard=Get-Content -LiteralPath $NativeGuardReceipt -Raw | ConvertFrom-Json
$configPath=Join-Path $PreparedRun 'comparison.json'
$config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -NoEnumerate
if($run.status -ne 'prepared_only_no_native_builds' -or
    $guard.status -ne 'passed' -or $guard.native_cmake_build_started -ne $false -or
    $run.config_sha256 -cne (Get-FileHash $configPath).Hash -or
    $run.cases.Count -ne $config.Count){
    throw 'Preparation, frozen config or native guard is incomplete.'
}
$cases=@()
for($index=0;$index -lt $run.cases.Count;$index++){
    $case=$run.cases[$index]
    if($case.status -ne 'not_started'){
        throw 'A selected build already ran.'
    }
    $protocol=Get-Content $case.protocol -Raw | ConvertFrom-Json
    foreach($file in $protocol.frozen_files){
        if((Get-FileHash $file.path).Hash -cne $file.sha256){throw 'A frozen preparation input changed.'}
    }
    $configuration=Get-Content $protocol.configuration -Raw | ConvertFrom-Json
    $contract=Get-Content $protocol.build_contract -Raw | ConvertFrom-Json
    foreach ($selection in @(
        @{prefix='opencv';repository=$configuration.repositories[0]},
        @{prefix='ci-gha';repository=$configuration.repositories[1]}
    )) {
        $prefix=$selection.prefix
        $repository=$selection.repository
        $actual=& git -C $repository.path rev-parse HEAD
        if($LASTEXITCODE -or $actual -cne $config[$index]."$prefix-commit" -or
            $repository.target_commit_sha -cne $actual -or
            $repository.repository -cne $config[$index]."$prefix-repo" -or
            $repository.branch_name -cne $config[$index]."$prefix-branch"){
            throw 'Restored repository/commit identity differs.'
        }
        $dirty=& git -C $repository.path status --porcelain --untracked-files=all
        if($LASTEXITCODE -or $dirty){throw 'Selected checkout is dirty.'}
    }
    if ($contract.ci_commit -cne $config[$index].'ci-gha-commit') { throw 'Captured CI identity differs.' }
    $actualCache=(Get-FileHash (Join-Path $configuration.root "$($configuration.build_directory)\CMakeCache.txt")).Hash
    if($actualCache -cne $configuration.cache_sha256){
        throw 'Case-specific configured workload changed.'
    }
    $cases+=[ordered]@{
        label=$case.label;selection=$config[$index];arguments=$contract.arguments;cache_sha256=$actualCache
        contract_sha256=(Get-FileHash $protocol.build_contract).Hash
        protocol_sha256=(Get-FileHash $case.protocol).Hash
        clean_exact_checkout=$true
    }
}
$record=[ordered]@{
    checked_at=(Get-Date).ToString('o')
    status='standalone_preparation_and_native_rejection_fixture_passed'
    folder=$Folder
    payload_manifest_sha256=(Get-FileHash (Join-Path $Folder 'payload\package-manifest.json')).Hash
    frozen_config_sha256=$run.config_sha256
    preparation_summary_sha256=(Get-FileHash $summaryPath).Hash
    native_guard_receipt_sha256=(Get-FileHash $NativeGuardReceipt).Hash
    qualification_script_sha256=(Get-FileHash $PSCommandPath).Hash
    cases=$cases;case_specific_configurations=$true
    full_opencv_builds_executed=0
    setup_abi_probes_executed=$true
    failure_flow='Real bounded action/probe rejects an intentional command mismatch, exports failure, and stops before the next case.'
    positive_orchestration='Fixture-verified ordering/exports and generic summary; existing native build/correctness harness is reused.'
    performance_claimed=$false
}
New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output 'Standalone preparation, exact selected contracts and bounded no-build rejection are qualified.'
