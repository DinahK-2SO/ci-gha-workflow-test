#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Freeze','Run')][string]$Action,
    [Parameter(Mandatory)][string]$ProtocolPath,
    [string]$ConfigurationReceipt,
    [string]$ReferenceHost,
    [string]$OutputRoot,
    [string]$ToolsFile,
    [ValidateSet('baseline','shared','fixed')][string]$Condition,
    [switch]$LegacyOptIn,
    [switch]$CandidateFirst,
    [switch]$SampleResources,
    [string]$BuildContract,
    [ValidateRange(1,2147483647)][int]$SharedCompilerJobs = 8
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NativeArchitecture.psm1')
if ($Condition) { $Condition = $Condition.ToLowerInvariant() }
$helperNames = @('Invoke-CiPilot.ps1','ci_action_trial.py','cmake_probe.py',
    'prepare_ci_action.py','BoundedProcess.cs','NativeArchitecture.psm1','..\Get-HostSnapshot.ps1')
if ($Action -eq 'Freeze') {
    if ($BuildContract -and $LegacyOptIn) { throw 'Captured contracts require a commit comparison.' }
    if ($BuildContract) { $helperNames += 'build_contract.py' }
    if ($CandidateFirst -and $LegacyOptIn) {
        throw 'Candidate-first execution requires the baseline/fixed commit comparison.'
    }
    if ($LegacyOptIn -and $SharedCompilerJobs -ne 8) { throw 'Historical opt-in replay requires eight compiler slots.' }
    if ($SampleResources) { $helperNames += 'Watch-BuildResources.ps1' }
    if (-not $ConfigurationReceipt -or -not $ReferenceHost -or -not $OutputRoot -or -not $ToolsFile) {
        throw 'Freeze requires configuration, reference-host, explicit tool-selection and new output-root paths.'
    }
    if ((Test-Path -LiteralPath $ProtocolPath) -or (Test-Path -LiteralPath $OutputRoot)) {
        throw 'Pilot protocol/output paths already exist; do not overwrite or automatically repeat.'
    }
    $configuration = Get-Content -LiteralPath $ConfigurationReceipt -Raw | ConvertFrom-Json
    $platform=Get-RecordedBuildPlatform $configuration
    if ($configuration.status -ne 'configured_full_base_workload_pending_pilots') {
        throw 'The full base-build configuration has not passed its preparation guards.'
    }
    $selection = Get-Content -LiteralPath $ToolsFile -Raw | ConvertFrom-Json
    if ($selection.PSObject.Properties['architecture'] -and $selection.architecture -cne $platform.architecture) {
        throw 'Tool selection and configured architecture differ.'
    }
    $tools = @($selection.cmake,$selection.measurement_python,$selection.bash,
        $selection.msbuild,$selection.compiler,$selection.linker)
    $preparerPython = $selection.preparer_python
    $processorCountPowerShell = $null
    if ($selection.PSObject.Properties['processor_count_powershell']) {
        $processorCountPowerShell = $selection.processor_count_powershell
    }
    $files = @(
        [ordered]@{path=$ConfigurationReceipt; sha256=(Get-FileHash -LiteralPath $ConfigurationReceipt).Hash},
        [ordered]@{path=$ReferenceHost; sha256=(Get-FileHash -LiteralPath $ReferenceHost).Hash}
    ) + @($configuration.dependency_files)
    if ($BuildContract) {
        $files += [ordered]@{path=$BuildContract; sha256=(Get-FileHash -LiteralPath $BuildContract).Hash}
    }
    if ($ToolsFile) {
        $files += [ordered]@{path=$ToolsFile; sha256=(Get-FileHash -LiteralPath $ToolsFile).Hash}
    }
    if ($processorCountPowerShell) {
        $files += [ordered]@{path=$processorCountPowerShell; sha256=(Get-FileHash -LiteralPath $processorCountPowerShell).Hash}
    }
    foreach ($path in @($tools) + @($preparerPython) + @($helperNames | ForEach-Object {Join-Path $PSScriptRoot $_})) {
        $files += [ordered]@{path=$path; sha256=(Get-FileHash -LiteralPath $path).Hash}
    }
    $pythonRoot = Split-Path $configuration.dependency_files[0].path
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $pythonRoot 'include') -Recurse -File) {
        if ($file.Name -ne 'Python.h') {
            $files += [ordered]@{path=$file.FullName; sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
        }
    }
    New-Item -ItemType Directory -Path (Split-Path $ProtocolPath) -Force | Out-Null
    [ordered]@{
        frozen_at=(Get-Date).ToString('o')
        role='functional_qualification'
        performance_eligible=$false
        timing_use='diagnostic_only'
        configuration=$ConfigurationReceipt
        architecture=$platform.architecture
        reference_host=$ReferenceHost
        output_root=$OutputRoot
        order=$(if($LegacyOptIn){@('baseline','shared')}elseif($CandidateFirst){@('fixed','baseline')}else{@('baseline','fixed')})
        comparison_axis=$(if($LegacyOptIn){'historical_optin'}else{'baseline_vs_fixed_commit'})
        build_contract=$BuildContract
        test_build_policy=@{msbuild_node_reuse=$false}
        resource_sampling=[bool]$SampleResources
        resource_sample_interval_seconds=5
        project_jobs=8
        shared_compiler_jobs=$SharedCompilerJobs
        processor_count_powershell=$processorCountPowerShell
        build_timeout_seconds=1800
        total_study_build_budget_seconds=5400
        rest_seconds=30
        minimum_free_memory_gib=24
        minimum_free_disk_gib=30
        cpu_background_is_observation_only=$true
        formal_measurement_cpu_limit_percent=10
        metric='Diagnostic wall seconds around the real native CMake build; not a performance sample or benefit claim.'
        cache_policy='Same configured tree; MSBuild clean before each build. No OS cache flush or system-setting changes.'
        acceptance='Successful full build, unchanged source/cache/dependencies, native artifacts/version, ten selected non-skipped C++ checks and raw binding DLL load. Not full CI or native NumPy/Python module qualification.'
        cmake=$tools[0]
        measurement_python=$tools[1]
        preparer_python=$preparerPython
        bash=$tools[2]
        tools=@($tools | ForEach-Object {
            [ordered]@{path=$_; file_version=(Get-Item -LiteralPath $_).VersionInfo.FileVersion}
        })
        frozen_files=$files
        smoke_cases=@(
            [ordered]@{
                binary='opencv_test_core.exe'
                tests=@('Core_Mat.reshape_ndims_4','Core_Mat.reinterpret_Mat_8UC3_8SC3',
                    'Core_Mat.copyToConvertTo_Empty','Core_Mat.zeros','Core_Mat.extractChannel_inplace_29568')
            },
            [ordered]@{
                binary='opencv_test_imgproc.exe'
                tests=@('Imgproc_Threshold.threshold_dryrun','Imgproc_Threshold.regression_THRESH_TOZERO_IPP_16085',
                    'Imgproc_Threshold.regression_THRESH_TOZERO_IPP_21258',
                    'Imgproc_Threshold.regression_THRESH_TOZERO_IPP_21258_Min',
                    'Imgproc_Threshold.regression_THRESH_TOZERO_IPP_21258_Max')
            }
        )
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $ProtocolPath -Encoding utf8
    Write-Output 'Frozen one baseline and one candidate functional build; timings are diagnostic only. No build started.'
    return
}

if (-not $Condition) { throw 'Run requires a selected pilot condition.' }
$protocol = Get-Content -LiteralPath $ProtocolPath -Raw | ConvertFrom-Json
if (-not $protocol.PSObject.Properties['test_build_policy'] -or
    -not $protocol.test_build_policy.PSObject.Properties['msbuild_node_reuse'] -or
    $protocol.test_build_policy.msbuild_node_reuse -isnot [bool] -or
    $protocol.test_build_policy.msbuild_node_reuse) {
    throw 'This harness requires a newly frozen local /nr:false test policy; prior results are not retargeted.'
}
$order = @($protocol.order) -join '|'
if ($order -cnotin @('baseline|fixed','fixed|baseline','baseline|shared') -or $Condition -notin $protocol.order) {
    throw 'The selected condition is not part of a supported frozen comparison.'
}
$isCommitComparison = $order -cne 'baseline|shared'
if ($protocol.role -ne 'functional_qualification' -or $protocol.performance_eligible -ne $false -or
    $protocol.cpu_background_is_observation_only -ne $true) {
    throw 'This runner requires the separately frozen, non-performance functional protocol.'
}
$configuration = Get-Content -LiteralPath $protocol.configuration -Raw | ConvertFrom-Json
$platform=Get-RecordedBuildPlatform $configuration $protocol
$reference = Get-Content -LiteralPath $protocol.reference_host -Raw | ConvertFrom-Json
$output = Join-Path $protocol.output_root $Condition
if (Test-Path -LiteralPath $output) { throw 'Pilot attempt already exists; preserve it rather than repeating automatically.' }
if ($Condition -ne $protocol.order[0]) {
    $previousPath = Join-Path $protocol.output_root "$($protocol.order[0])\execution.json"
    if (-not (Test-Path -LiteralPath $previousPath)) {
        throw 'The preceding condition has no execution record; follow the frozen order.'
    }
    $previous = Get-Content -LiteralPath $previousPath -Raw | ConvertFrom-Json
    if ($previous.status -ne 'functional_build_passed' -or
        $previous.protocol_sha256 -cne (Get-FileHash -LiteralPath $ProtocolPath).Hash) {
        throw 'The preceding condition has not passed under this frozen protocol.'
    }
}
$result = [ordered]@{
    started_at=(Get-Date).ToString('o')
    status='preparing'
    role='functional_qualification'
    performance_eligible=$false
    timing_use='diagnostic_only'
    condition=$Condition
    architecture=$platform.architecture
    comparison_axis=$(if($isCommitComparison){'baseline_vs_fixed_commit'}else{'historical_optin'})
    protocol_sha256=(Get-FileHash -LiteralPath $ProtocolPath).Hash
    test_build_policy=$protocol.test_build_policy
    native_numpy_runtime_verified=$false
    full_ci_qualified=$false
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$lock = $null

function Assert-FrozenInputs {
    foreach ($file in $protocol.frozen_files) {
        if ((Get-FileHash -LiteralPath $file.path).Hash -cne $file.sha256) {
            throw "A frozen input changed: $($file.path)"
        }
    }
}

function Assert-Host($State) {
    if ($State.status -ne 'success' -or $State.power_status.ACLineStatus -ne 1 -or
        $State.power_status.SystemStatusFlag -ne 0 -or
        $State.power_scheme -ne $reference.power_scheme -or
        $State.user_power_modes.ac_guid -ne $reference.user_power_modes.ac_guid -or
        $State.os.Version -ne $reference.os.Version -or
        $State.os.LastBootUpTime -ne $reference.os.LastBootUpTime) {
        throw 'The frozen host, boot or power state changed.'
    }
}

function Native-Artifact([string]$Path) {
    Get-NativeArtifact $Path $platform.architecture
}

try {
    Assert-FrozenInputs
    if ($protocol.PSObject.Properties['processor_count_powershell'] -and $protocol.processor_count_powershell) {
        $resolved=@(& pwsh -NoLogo -NoProfile -NonInteractive -Command '[Environment]::ProcessPath')
        if ($LASTEXITCODE -ne 0 -or $resolved.Count -ne 1 -or $resolved[0] -cne $protocol.processor_count_powershell) {
            throw 'PowerShell processor-count discovery resolves to a different executable.'
        }
    }
    $lock = [IO.File]::Open((Join-Path (Split-Path $configuration.root) 'experiment.lock'),
        [IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $busy = @(Get-Process | Where-Object ProcessName -In @('MSBuild','cl','c1xx','c1','link','cmake','ninja'))
    if ($busy.Count) { throw 'Another build is active; stop without touching it.' }
    foreach ($name in @('CL','_CL_')) {
        if ([Environment]::GetEnvironmentVariable($name)) { throw "Unfrozen compiler environment override: $name" }
    }
    New-Item -ItemType Directory -Path $protocol.output_root -Force | Out-Null
    $repository = if ($Condition -eq 'baseline') {$configuration.repositories[1]} else {$configuration.repositories[2]}
    $shared = if ($Condition -eq 'baseline') {'false'} else {'true'}
    $selectionArgs = if ($isCommitComparison) {@('--condition',$Condition)} else {@('--shared-cap',$shared)}
    & $protocol.preparer_python -B (Join-Path $PSScriptRoot 'prepare_ci_action.py') --ci-root $repository.path `
        --ci-commit $repository.target_commit_sha --workdir $configuration.root `
        --builddir $configuration.build_directory --output $output @selectionArgs
    if ($LASTEXITCODE -ne 0) { throw 'Exact action-step extraction failed.' }
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'BoundedProcess.cs') -Raw)
    $env:PATH = "$(Split-Path $protocol.measurement_python);$(Split-Path $protocol.cmake);$env:PATH"
    foreach ($property in $configuration.process_environment.PSObject.Properties) {
        Set-Item -LiteralPath "Env:$($property.Name)" -Value $property.Value
    }
    $result.clean_arguments=@('--build',$configuration.build_directory,'--target','clean','--config','Release','--','/nr:false')
    $result.clean = [OpenCvBoundedProcess]::Run($protocol.cmake,$result.clean_arguments,
        $configuration.root,(Join-Path $output 'clean.log'),300)
    if ($result.clean.TimedOut -or $result.clean.ExitCode -ne 0) {
        throw "Pre-build clean failed (exit $($result.clean.ExitCode), timed out: $($result.clean.TimedOut)). Log: $(Join-Path $output 'clean.log')"
    }
    Start-Sleep -Seconds $protocol.rest_seconds
    & (Join-Path $PSScriptRoot '..\Get-HostSnapshot.ps1') -OutputPath (Join-Path $output 'host-before.json')
    $before = Get-Content -LiteralPath (Join-Path $output 'host-before.json') -Raw | ConvertFrom-Json
    Assert-Host $before
    $cpu = @(1..5 | ForEach-Object {
        [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        Start-Sleep -Seconds 1
    })
    $result.preflight = [ordered]@{
        cpu_samples_percent=$cpu
        cpu_mean_percent=($cpu | Measure-Object -Average).Average
        free_memory_gib=(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB
        free_disk_gib=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($configuration.root)).AvailableFreeSpace/1GB
        known_build_processes=@(Get-Process | Where-Object ProcessName -In @('MSBuild','cl','c1xx','c1','link','cmake','ninja') | Select-Object Id,ProcessName)
    }
    if ($result.preflight.free_memory_gib -lt $protocol.minimum_free_memory_gib -or
        $result.preflight.free_disk_gib -lt $protocol.minimum_free_disk_gib -or
        $result.preflight.known_build_processes.Count) { throw 'Shared-host resource gate failed; do not start a build.' }
    $source = $configuration.repositories[0]
    $contractArgs = @()
    if ($protocol.PSObject.Properties['build_contract'] -and $protocol.build_contract) {
        $contractArgs = @('--build-contract',$protocol.build_contract)
    }
    $sampler = $null
    try {
        if ($protocol.PSObject.Properties['resource_sampling'] -and $protocol.resource_sampling) {
            $samplePath = Join-Path $output 'resources.jsonl'
            $sampler = Start-ThreadJob -FilePath (Join-Path $PSScriptRoot 'Watch-BuildResources.ps1') `
                -ArgumentList $samplePath,$protocol.resource_sample_interval_seconds
            $readyDeadline = (Get-Date).AddSeconds(30)
            while (-not (Test-Path -LiteralPath $samplePath) -and $sampler.State -in @('NotStarted','Running') -and
                (Get-Date) -lt $readyDeadline) { Start-Sleep -Milliseconds 100 }
            if (-not (Test-Path -LiteralPath $samplePath) -or $sampler.State -ne 'Running') {
                throw 'Resource sampler did not become ready; do not launch the build.'
            }
            $result.resource_sampling = [ordered]@{
                path=$samplePath
                interval_seconds=$protocol.resource_sample_interval_seconds
                scope='Whole-machine observations; compiler counts are sampled, not an exact peak or job membership.'
            }
        }
        $result.build = [OpenCvBoundedProcess]::Run($protocol.measurement_python,@(
        '-B',(Join-Path $PSScriptRoot 'ci_action_trial.py'),
        '--ci-root',$repository.path,'--ci-commit',$repository.target_commit_sha,
        '--ci-repository',$repository.repository,'--ci-branch',$repository.branch_name,
        '--source-root',$source.path,'--source-commit',$source.target_commit_sha,
        '--source-repository',$source.repository,'--source-branch',$source.branch_name,
        '--workdir',$configuration.root,'--builddir',$configuration.build_directory,
        '--architecture',$platform.architecture,
        '--cache-sha256',$configuration.cache_sha256,'--output',$output,
        '--cmake',$protocol.cmake,'--bash',$protocol.bash,$selectionArgs[0],$selectionArgs[1],
        '--compiler-jobs',[string]$protocol.shared_compiler_jobs,
        '--role','functional_qualification','--label',"native-base-$Condition-functional") + $contractArgs,
            $configuration.root,(Join-Path $output 'action.log'),$protocol.build_timeout_seconds)
    } finally {
        if ($sampler) {
            try {
                if ($sampler.State -eq 'Failed') {
                    Receive-Job -Job $sampler -ErrorAction Stop | Out-Null
                    throw 'Resource sampler failed.'
                }
                Stop-Job -Job $sampler
                Receive-Job -Job $sampler -ErrorAction Stop | Out-Null
            } finally { Remove-Job -Job $sampler -Force }
        }
    }
    if ($result.build.TimedOut -or $result.build.ExitCode -ne 0) {
        throw "Full build failed (exit $($result.build.ExitCode), timed out: $($result.build.TimedOut)). Preserve this attempt. Log: $(Join-Path $output 'action.log')"
    }
    $trial = Get-Content -LiteralPath (Join-Path $output 'trial.json') -Raw | ConvertFrom-Json
    if ($trial.status -ne 'build_succeeded_pending_correctness') { throw 'The exact full build did not pass its identity checks.' }
    $result.build_seconds = $trial.build_seconds
    $bin = Join-Path $configuration.root "$($configuration.build_directory)\bin\Release"
    $pyd = Join-Path $configuration.root "$($configuration.build_directory)\lib\python3\Release\cv2.cp313-$($platform.python_tag).pyd"
    $result.artifacts = @(
        Native-Artifact (Join-Path $bin 'opencv_version.exe')
        Native-Artifact (Join-Path $bin 'opencv_core520.dll')
        Native-Artifact (Join-Path $bin 'opencv_imgproc520.dll')
        Native-Artifact $pyd
    )
    $result.version = [OpenCvBoundedProcess]::Run((Join-Path $bin 'opencv_version.exe'),@(),
        $bin,(Join-Path $output 'version.log'),30)
    if ($result.version.ExitCode -ne 0 -or $result.version.TimedOut -or
        (Get-Content -LiteralPath (Join-Path $output 'version.log') -Raw).Trim() -ne '5.2.0-dev') {
        throw 'The output library version does not match the fixed source.'
    }
    $result.smoke = @()
    foreach ($test in $protocol.smoke_cases) {
        $xmlPath = Join-Path $output "$($test.binary).xml"
        $process = [OpenCvBoundedProcess]::Run((Join-Path $bin $test.binary),@(
            "--gtest_filter=$($test.tests -join ':')","--gtest_output=xml:$xmlPath"),
            $bin,(Join-Path $output "$($test.binary).log"),120)
        if ($process.ExitCode -ne 0 -or $process.TimedOut) { throw "Selected correctness checks failed: $($test.binary)" }
        [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw
        $cases = @($xml.SelectNodes('/testsuites/testsuite/testcase'))
        $names = @($cases | ForEach-Object {"$($_.GetAttribute('classname')).$($_.GetAttribute('name'))"} | Sort-Object)
        if ($xml.DocumentElement.GetAttribute('failures') -cne '0' -or
            ($names -join '|') -cne (($test.tests | Sort-Object) -join '|') -or
            @($cases | Where-Object {$_.GetAttribute('status') -ne 'run' -or $_.SelectNodes('failure|error|skipped').Count}).Count) {
            throw 'The correctness XML contains missing, skipped or failing selected cases.'
        }
        $result.smoke += [ordered]@{binary=$test.binary; tests=$names; process=$process}
    }
    $loadCode = "import ctypes, os, sys; search = os.add_dll_directory(sys.argv[2]); ctypes.WinDLL(sys.argv[1]); print('Native binding DLL loaded; Python module initialization NOT tested')"
    $result.binding_dll_load = [OpenCvBoundedProcess]::Run($configuration.dependency_files[0].path,
        @('-I','-B','-c',$loadCode,$pyd,$bin),$bin,(Join-Path $output 'binding-dll-load.log'),30)
    if ($result.binding_dll_load.ExitCode -ne 0 -or $result.binding_dll_load.TimedOut) {
        throw 'The native Python interpreter could not load the binding DLL.'
    }
    Assert-FrozenInputs
    & (Join-Path $PSScriptRoot '..\Get-HostSnapshot.ps1') -OutputPath (Join-Path $output 'host-after.json')
    Assert-Host (Get-Content -LiteralPath (Join-Path $output 'host-after.json') -Raw | ConvertFrom-Json)
    $result.status='functional_build_passed'
} catch {
    $result.status='failed'
    $result.error=$_.Exception.Message
    throw
} finally {
    if ($lock) { $lock.Dispose() }
    $clock.Stop()
    $result.total_occupancy_seconds=$clock.Elapsed.TotalSeconds
    $result.finished_at=(Get-Date).ToString('o')
    if (Test-Path -LiteralPath $output) {
        $result | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $output 'execution.json') -Encoding utf8
    }
}
Write-Output "Functional $Condition build passed; diagnostic_build_seconds=$($result.build_seconds); not performance-eligible."
