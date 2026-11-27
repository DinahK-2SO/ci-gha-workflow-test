#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory,ParameterSetName='Pair')][string]$ProtocolPath,
    [Parameter(Mandatory,ParameterSetName='Configured')][string]$CasesFile,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NativeArchitecture.psm1')
if (Test-Path -LiteralPath $OutputPath) { throw 'Functional-pair summary already exists.' }
$configured=$PSCmdlet.ParameterSetName -eq 'Configured'
if ($configured) {
    $configuredSelection=Get-Content -LiteralPath $CasesFile -Raw | ConvertFrom-Json
    $cases=@($configuredSelection.cases)
    if ($cases.Count -lt 1) { throw 'At least one configured result is required.' }
} else {
    $pair=Get-Content -LiteralPath $ProtocolPath -Raw | ConvertFrom-Json
    $cases=@($pair.order | ForEach-Object {
        [pscustomobject]@{label=$_;condition=$_;protocol=$ProtocolPath;export=(Join-Path (Split-Path $ProtocolPath) $_)}
    })
}
$conditions = @()
$referenceTrial = $null
$referenceOutputs = $null
$referenceArchitecture = $null
$sameCacheAndOutputs = $true
$consumed = 0.0
foreach ($case in $cases) {
    $ProtocolPath=$case.protocol
    $condition=$case.condition
    $protocol = Get-Content -LiteralPath $ProtocolPath -Raw | ConvertFrom-Json
    $order = @($protocol.order) -join '|'
    if ($order -cnotin @('baseline','baseline|fixed','fixed|baseline','baseline|shared')) {
        throw 'The protocol does not identify a supported baseline/candidate pair.'
    }
    $commitComparison = $order -cne 'baseline|shared'
    if ($configured -and ($order -cne 'baseline' -or $protocol.comparison_axis -cne 'independent_sources')) {
        throw 'Configured cases require independent source protocols.'
    }
    $configuration = Get-Content -LiteralPath $protocol.configuration -Raw | ConvertFrom-Json
    $platform=Get-RecordedBuildPlatform $configuration $protocol
    if ($referenceArchitecture -and $referenceArchitecture -cne $platform.architecture) {
        throw 'Conditions from different architectures cannot form one comparison.'
    }
    $referenceArchitecture=$platform.architecture
    $protocolHash = (Get-FileHash -LiteralPath $ProtocolPath).Hash
    $expectedTests = @($protocol.smoke_cases | ForEach-Object {$_.tests} | Sort-Object)
    if ($condition -notin $protocol.order) { throw 'Result condition is absent from its protocol.' }
    $directory = $case.export
    $execution = Get-Content -LiteralPath (Join-Path $directory 'execution.json') -Raw | ConvertFrom-Json
    $trial = Get-Content -LiteralPath (Join-Path $directory 'trial.json') -Raw | ConvertFrom-Json
    foreach ($record in @($protocol,$execution,$trial,$trial.native_build)) {
        if (-not $record.PSObject.Properties['test_build_policy'] -or
            -not $record.test_build_policy.PSObject.Properties['msbuild_node_reuse'] -or
            $record.test_build_policy.msbuild_node_reuse -isnot [bool] -or
            $record.test_build_policy.msbuild_node_reuse) {
            throw 'Missing or inconsistent local /nr:false policy; do not mix these results with earlier runs.'
        }
    }
    $expectedClean=@('--build',$configuration.build_directory,'--target','clean','--config','Release','--','/nr:false')
    if (-not $execution.PSObject.Properties['clean_arguments'] -or
        ($execution.clean_arguments -join '|') -cne ($expectedClean -join '|') -or
        $execution.clean.ExitCode -ne 0 -or $execution.clean.TimedOut) {
        throw 'Pre-build clean did not pass under the frozen /nr:false policy.'
    }
    if ($commitComparison -and (
            $trial.comparison_axis -cne $protocol.comparison_axis -or
            $trial.condition -cne $condition -or
            @($trial.inputs.PSObject.Properties.Name | Where-Object {$_ -in @('msbuild_shared_cap','msbuild_compiler_jobs')}).Count)) {
        throw 'The primary comparison contains a public experiment control or mismatched condition.'
    }
    $archive = Get-Content -LiteralPath (Join-Path $directory 'archive-manifest.json') -Raw | ConvertFrom-Json
    if ($execution.status -ne 'functional_build_passed' -or
        $execution.protocol_sha256 -cne $protocolHash -or $archive.status -ne 'exported') {
        throw "The $condition functional result or archive is incomplete."
    }
    foreach ($record in @($protocol,$execution,$trial,$archive)) {
        if ($record.role -ne 'functional_qualification' -or $record.performance_eligible -ne $false -or
            $record.timing_use -ne 'diagnostic_only') { throw 'A record lost the required non-performance classification.' }
    }
    foreach ($file in $archive.evidence) {
        if ((Get-FileHash -LiteralPath (Join-Path $directory $file.name)).Hash -cne $file.sha256) {
            throw 'Archived evidence bytes changed.'
        }
    }
    $ci = $configuration.repositories[$(if($condition -eq 'baseline'){1}else{2})]
    if ($configured) {
        foreach ($selected in @(
            @{prefix='opencv';actual=$configuration.repositories[0]},
            @{prefix='ci-gha';actual=$ci}
        )) {
            $prefix=$selected.prefix
            if ($selected.actual.repository -cne $case.selection."$prefix-repo" -or
                $selected.actual.branch_name -cne $case.selection."$prefix-branch" -or
                $selected.actual.target_commit_sha -cne $case.selection."$prefix-commit") {
                throw 'Case source selection differs from its configured checkout.'
            }
        }
    }
    foreach ($selection in @(@{actual=$trial.repositories[0]; expected=$ci},
            @{actual=$trial.repositories[1]; expected=$configuration.repositories[0]})) {
        if ($selection.actual.repository -ne $selection.expected.repository -or
            $selection.actual.branch_name -ne $selection.expected.branch_name -or
            $selection.actual.target_commit_sha -cne $selection.expected.target_commit_sha -or
            $selection.actual.actual_commit_sha -cne $selection.expected.target_commit_sha) {
            throw 'Repository/branch/target/actual identity does not match the frozen condition.'
        }
    }
    $expectedArgs = @('--build',$configuration.build_directory,'--config','Release')
    if ($condition -ne 'baseline') {
        $expectedArgs += @('--parallel','8','--','/p:MultiProcCL=true',"/p:MultiProcMaxCount=$($protocol.shared_compiler_jobs)",
            '/p:EnforceProcessCountAcrossBuilds=true')
        if ($condition -eq 'fixed') { $expectedArgs += '/p:EnableClServerMode=true' }
    }
    if ($protocol.PSObject.Properties['build_contract'] -and $protocol.build_contract) {
        $contract=Get-Content -LiteralPath $protocol.build_contract -Raw | ConvertFrom-Json
        $hash=(Get-FileHash -LiteralPath $protocol.build_contract).Hash
        $frozen=@($protocol.frozen_files | Where-Object path -CEQ $protocol.build_contract)
        if ($frozen.Count -ne 1 -or $frozen[0].sha256 -cne $hash -or
            $trial.build_contract_sha256 -cne $hash.ToLowerInvariant() -or
            $contract.ci_commit -cne $ci.target_commit_sha -or
            $contract.action_sha256 -cne $trial.action_sha256 -or
            $contract.script_sha256 -cne $trial.extracted_build_step_sha256) {
            throw 'Captured command identity or frozen evidence changed.'
        }
        $expectedArgs=@($contract.arguments)
    }
    if (($trial.native_build.arguments -join '|') -cne ($expectedArgs -join '|') -or
        $trial.native_build.status -ne 'success' -or
        $trial.cache_sha256 -cne $configuration.cache_sha256.ToLowerInvariant()) {
        throw 'The full native build command, outcome or cache identity differs.'
    }
    $separator=[Array]::IndexOf($expectedArgs,'--')
    $effectiveArgs=if ($separator -lt 0) { @($expectedArgs)+@('--') } else { @($expectedArgs[0..$separator]) }
    if ($separator -ge 0) {
        foreach ($argument in $expectedArgs | Select-Object -Skip ($separator+1)) {
            if ($argument -match '^[/\-]+(?:nr|nodereuse)(?::(.*))?$') {
                if ($Matches[1] -ine 'false') { throw 'Captured action conflicts with the local node-reuse policy.' }
            } else { $effectiveArgs+=@($argument) }
        }
    }
    $effectiveArgs+=@('/nr:false')
    if (-not $trial.native_build.PSObject.Properties['effective_arguments'] -or
        ($trial.native_build.effective_arguments -join '|') -cne ($effectiveArgs -join '|')) {
        throw 'The effective native command did not apply exactly the frozen local /nr:false policy.'
    }
    $tests = @($execution.smoke | ForEach-Object {$_.tests} | Sort-Object)
    if (($tests -join '|') -cne ($expectedTests -join '|') -or
        $execution.binding_dll_load.ExitCode -ne 0 -or $execution.binding_dll_load.TimedOut -or
        -not @($execution.artifacts).Count -or
        @($execution.artifacts | Where-Object machine -ne $platform.machine).Count) {
        throw 'Functional correctness or native artifact checks are incomplete.'
    }
    if ($execution.build.TimedOut -or $execution.build.ExitCode -ne 0 -or
        $execution.build.OuterWallSeconds -gt $protocol.build_timeout_seconds -or
        -not [double]::IsFinite($trial.build_seconds) -or $trial.build_seconds -le 0) {
        throw 'Build outcome or duration violates the functional bounds.'
    }
    $consumed += $(if($configured){$execution.build.OuterWallSeconds}else{$trial.build_seconds})
    $outputs = @($archive.binaries.relative_path | Sort-Object)
    if ($referenceTrial) {
        foreach ($key in @('runner_sha256','cmake_probe_sha256','cmake_sha256','bash_sha256')) {
            if ($trial.$key -cne $referenceTrial.$key) { throw "A common input changed between conditions: $key" }
        }
        if ($trial.cache_sha256 -cne $referenceTrial.cache_sha256 -or
            ($outputs -join '|') -cne ($referenceOutputs -join '|')) {
            $sameCacheAndOutputs=$false
            if (-not $configured -and $order -cne 'baseline') {
                throw 'Shared configured cache or output-file inventory differs between paired conditions.'
            }
        }
    } else {
        $referenceTrial=$trial
        $referenceOutputs=$outputs
    }
    $conditions += [ordered]@{
        label=$case.label
        protocol_sha256=$protocolHash
        condition=$condition
        status=$execution.status
        test_build_policy=$protocol.test_build_policy
        cache_sha256=$configuration.cache_sha256
        workload=$configuration.workload_check
        repositories=$trial.repositories
        selected_cpp_checks_passed=$tests.Count
        architecture=$platform.architecture
        checked_artifact_machine=$platform.machine
        raw_binding_dll_load_passed=$true
        archived_output_count=$outputs.Count
        native_wall_seconds=$trial.build_seconds
        outer_wall_seconds=$execution.build.OuterWallSeconds
        owned_cpu_seconds=$execution.build.ProcessTreeCpuSeconds
    }
}
$budget=if($configured){$configuredSelection.build_budget_seconds}else{$protocol.total_study_build_budget_seconds}
if ($consumed -gt $budget) { throw 'The build-budget boundary was exceeded.' }
[ordered]@{
    verified_at=(Get-Date).ToString('o')
    status=$(if($configured){'configured_comparison_passed'}else{'functional_pair_passed'})
    comparison_axis=$(if($configured){'independent_sources'}else{$protocol.comparison_axis})
    role='functional_qualification'
    performance_eligible=$false
    timing_use='diagnostic_only'
    formal_performance_samples=0
    speedup_claimed=$false
    protocol_sha256=$(if($configured){$null}else{$protocolHash})
    cases_file_sha256=$(if($configured){(Get-FileHash -LiteralPath $CasesFile).Hash}else{$null})
    cache_sha256=$(if($configured){$null}else{$configuration.cache_sha256})
    architecture=$referenceArchitecture
    same_common_helpers_and_tools=$true
    same_common_helpers_tools_cache_and_output_inventory=$sameCacheAndOutputs
    case_specific_configurations=$configured
    test_build_policy=@{msbuild_node_reuse=$false}
    conditions=$conditions
    consumed_build_budget_seconds=$consumed
    budget_within_limit=$true
    native_numpy_runtime_verified=$false
    full_ci_qualified=$false
    compiler_peak_limit_proved=$false
    lab_handoff_ready=$false
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output "$($conditions.Count) functional builds passed with frozen identities; zero formal performance samples and no benefit claim."
