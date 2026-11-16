#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Check','Prepare','RunFunctional')][string]$Action = 'Check',
    [string]$WorkRoot,
    [switch]$ConfirmLocalExecution
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HandoffSupport.psm1') -Force
$manifest=Assert-HandoffPackage $PSScriptRoot
$profile=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profile.json') -Raw | ConvertFrom-Json
Assert-HandoffProfile $profile $manifest
$tools=Find-HandoffToolchain -Architecture $profile.architecture
$platform=Get-NativeBuildPlatform $profile.architecture
Import-Module (Join-Path $PSScriptRoot 'scripts\msbuild\NativeArchitecture.psm1')
if ($Action -eq 'Check') {
    [ordered]@{
        status='package_and_installed_toolchain_checked'
        profile=$profile.profile_id
        architecture=$platform.architecture
        review_commit=$profile.ci_dev.commit
        baseline_commit=$profile.ci_baseline.commit
        opencv_commit=$profile.opencv.commit
        comparison_axis=$profile.comparison_axis
        conditions=$profile.conditions
        package_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'package-manifest.json')).Hash
        installed_tools=$tools
        workload_started=$false
        lab_permission_granted=$false
        platform_rpc_lifecycle_validated=$false
    } | ConvertTo-Json -Depth 5
    return
}
if (-not $WorkRoot -or -not $ConfirmLocalExecution) {
    throw 'Prepare/run requires an explicit local WorkRoot and -ConfirmLocalExecution. This switch is not lab-resource permission.'
}
$work=Assert-LocalStudyPath $WorkRoot $PSScriptRoot
$ownerPath=Join-Path $work 'preparation.json'
$manifestHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'package-manifest.json')).Hash
if ($Action -eq 'Prepare') {
    if (Test-Path -LiteralPath $work) { throw 'Preparation requires a fresh local directory; old attempts will not be overwritten.' }
    if ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory -lt $profile.minimum_free_memory_gib*1MB -or
        [IO.DriveInfo]::new([IO.Path]::GetPathRoot($work)).AvailableFreeSpace -lt $profile.minimum_free_disk_gib*1GB) {
        throw 'Insufficient memory/disk headroom for preparation.'
    }
    if (@(Get-Process | Where-Object ProcessName -In @('MSBuild','cl','c1xx','c1','link','cmake','ninja')).Count) {
        throw 'Another build is active; no process will be stopped.'
    }
    New-Item -ItemType Directory -Path $work | Out-Null
    $lock=[IO.File]::Open((Join-Path (Split-Path $work) 'experiment.lock'),
        [IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $record=[ordered]@{
        started_at=(Get-Date).ToString('o')
        status='preparing'
        package_manifest_sha256=$manifestHash
        profile_id=$profile.profile_id
        architecture=$platform.architecture
        comparison_axis=$profile.comparison_axis
        root=$work
        lab_permission_granted=$false
        performance_eligible=$false
        timing_use='diagnostic_only'
        source_transport='Self-contained Git bundles of verified public refs; no development checkout is used.'
        repositories=@()
    }
    try {
        $localPackage=Join-Path $work 'package'
        Copy-Item -LiteralPath $PSScriptRoot -Destination $localPackage -Recurse
        $null=Assert-HandoffPackage $localPackage
        $scripts=Join-Path $localPackage 'scripts\msbuild'
        $prep=Join-Path $work 'preparation'
        New-Item -ItemType Directory -Path $prep,(Join-Path $work 'tools'),(Join-Path $work 'download-cache'),
            (Join-Path $work 'results') -Force | Out-Null
        foreach ($selection in @(
            @{name='opencv'; entry=$profile.opencv},
            @{name='ci-baseline'; entry=$profile.ci_baseline},
            @{name='ci-dev'; entry=$profile.ci_dev}
        )) {
            $entry=$selection.entry
            $bundle=Join-Path $localPackage $entry.bundle.Replace('/','\')
            $destination=Join-Path $work $selection.name
            & $tools.git -c core.autocrlf=false clone --quiet --no-checkout --single-branch --branch $entry.bundle_ref.Substring(11) $bundle $destination
            if ($LASTEXITCODE -ne 0) { throw "Git bundle restoration failed: $($selection.name)" }
            & $tools.git -C $destination -c core.autocrlf=false checkout --quiet --detach $entry.commit
            if ($LASTEXITCODE -ne 0) { throw 'Exact source checkout failed.' }
            $actual=(& $tools.git -C $destination rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or $actual -cne $entry.commit) { throw 'Restored source identity differs from the frozen commit.' }
            & $tools.git -C $destination remote set-url origin "https://github.com/$($entry.repository).git"
            if ($LASTEXITCODE -ne 0) { throw 'Cannot record the public repository origin.' }
            $record.repositories += [ordered]@{
                repository=$entry.repository; branch_name=$entry.branch_name
                target_commit_sha=$entry.commit; actual_commit_sha=$actual
                bundle_sha256=(Get-FileHash -LiteralPath $bundle).Hash
                checkout_line_endings='Process-local core.autocrlf=false; no global Git setting changed.'
            }
        }
        $developmentReceipt=Join-Path $prep 'python-development.json'
        & (Join-Path $scripts 'Prepare-PythonDevelopment.ps1') `
            -Package (Join-Path $localPackage "inputs\$($platform.python_package).3.13.14.nupkg") `
            -Destination (Join-Path $work 'tools\python-dev') -Dumpbin $tools.dumpbin `
            -Architecture $platform.architecture -OutputPath $developmentReceipt
        $development=Get-Content -LiteralPath $developmentReceipt -Raw | ConvertFrom-Json
        $python=$development.identity.executable
        $pythonRoot=Split-Path $python
        $site=Join-Path $pythonRoot 'Lib\site-packages'
        New-Item -ItemType Directory -Path $site -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $localPackage 'inputs\yaml\yaml') -Destination (Join-Path $site 'yaml') -Recurse
        $yaml=& $python -I -B -c 'import yaml; print(yaml.__version__)'
        if ($LASTEXITCODE -ne 0 -or ($yaml -join '').Trim() -ne $profile.yaml_version) {
            throw 'The packaged pure-Python YAML input cannot run in the native interpreter.'
        }
        $cmake=Join-Path $localPackage 'runtime\cmake\bin\cmake.exe'
        $null=Get-NativeArtifact $cmake $platform.architecture
        $include=Join-Path $localPackage 'inputs\numpy\include'
        $env:PATH="$pythonRoot;$(Split-Path $cmake);$(Split-Path $tools.git);$env:PATH"
        $env:PYTHONDONTWRITEBYTECODE='1'
        $env:PYTHONNOUSERSITE='1'
        & (Join-Path $scripts 'Test-BoundedProcess.ps1') -Python $python -OutputDirectory (Join-Path $prep 'process-boundary')
        $probe=Join-Path $prep 'numpy-probe'
        New-Item -ItemType Directory -Path $probe | Out-Null
        $configure=[OpenCvBoundedProcess]::Run($cmake,@(
            '-S',(Join-Path $scripts 'tests\numpy-headers'),'-B','build',
            '-G',$profile.generator,'-A',$profile.architecture,
            "-DCMAKE_GENERATOR_INSTANCE:PATH=$($tools.visual_studio)",
            "-DPYTHON_DEVELOPMENT_ROOT:PATH=$pythonRoot","-DNUMPY_INCLUDE_DIR:PATH=$include"),
            $probe,(Join-Path $probe 'configure.log'),120)
        if ($configure.ExitCode -ne 0 -or $configure.TimedOut) { throw 'Packaged native header probe configuration failed.' }
        $compile=[OpenCvBoundedProcess]::Run($cmake,@('--build','build','--config','Release','--parallel','1','--','/nr:false'),
            $probe,(Join-Path $probe 'build.log'),120)
        if ($compile.ExitCode -ne 0 -or $compile.TimedOut) { throw 'Packaged NumPy header ABI/native Python link check failed.' }
        $null=Get-NativeArtifact (Join-Path $probe 'build\Release\numpy_header_abi_probe.exe') $platform.architecture
        $smoke=[OpenCvBoundedProcess]::Run((Join-Path $probe 'build\Release\numpy_header_abi_probe.exe'),@(),
            $probe,(Join-Path $probe 'execute.log'),30)
        if ($smoke.ExitCode -ne 0 -or $smoke.TimedOut) { throw 'The packaged native ABI probe cannot run.' }
        $origin=Get-Content -LiteralPath (Join-Path $localPackage 'inputs\numpy\origin.json') -Raw | ConvertFrom-Json
        $headerReceipt=Join-Path $prep 'numpy-headers.json'
        [ordered]@{
            status='compile_input_abi_passed_native_numpy_runtime_unverified'
            architecture=$platform.architecture
            numpy_version=$origin.version; include=$include; origin=$origin
            python_development_receipt_sha256=(Get-FileHash -LiteralPath $developmentReceipt).Hash
            python_runtime_dll_sha256=(Get-FileHash -LiteralPath (Join-Path $pythonRoot 'python313.dll')).Hash
            configure=$configure; build=$compile; execute=$smoke
            native_numpy_runtime_verified=$false
        } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $headerReceipt -Encoding utf8
        $recipe=Join-Path $prep 'recipe.json'
        [ordered]@{
            root=$work; cmake=$cmake; measurement_python=$python
            configure_arguments=@('-S','opencv','-B','build','-G',$profile.generator,'-A',$profile.architecture) +
                @($profile.configure_options) + @("-DCMAKE_GENERATOR_INSTANCE:PATH=$($tools.visual_studio)")
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recipe -Encoding utf8
        $configurationReceipt=Join-Path $prep 'configuration.json'
        & (Join-Path $scripts 'Configure-CiPilot.ps1') -OriginalStudyReceipt $recipe `
            -HeaderReceipt $headerReceipt -DevelopmentReceipt $developmentReceipt `
            -DevRoot (Join-Path $work 'ci-dev') -DevCommit $profile.ci_dev.commit `
            -BuildDirectory $profile.build_directory -ExpectedWorkload (Join-Path $localPackage 'expected-workload.json') `
            -RepositoryProfile (Join-Path $localPackage 'profile.json') `
            -OutputPath $configurationReceipt
        $tools['cmake']=$cmake
        $tools['measurement_python']=$python
        $tools['preparer_python']=$python
        $sharedCompilerJobs=8
        if ($profile.PSObject.Properties['compiler_budget_policy']) {
            $detected=@(& pwsh -NoLogo -NoProfile -NonInteractive -Command '[Environment]::ProcessPath; [Environment]::ProcessorCount')
            if ($LASTEXITCODE -ne 0 -or $detected.Count -ne 2 -or $detected[1] -notmatch '^[1-9][0-9]*$') {
                throw 'Cannot freeze the processor-count diagnostic; fallback behavior requires a separately identified run.'
            }
            $tools['processor_count_powershell']=$detected[0]
            $sharedCompilerJobs=[int]$detected[1]
        }
        $toolsPath=Join-Path $prep 'tools.json'
        $tools | ConvertTo-Json | Set-Content -LiteralPath $toolsPath -Encoding utf8
        $hostPath=Join-Path $prep 'host.json'
        & (Join-Path $localPackage 'scripts\Get-HostSnapshot.ps1') -OutputPath $hostPath
        $protocolPath=Join-Path $work 'results\protocol.json'
        & (Join-Path $scripts 'Invoke-CiPilot.ps1') -Action Freeze -ProtocolPath $protocolPath `
            -ConfigurationReceipt $configurationReceipt -ReferenceHost $hostPath `
            -OutputRoot (Join-Path $work 'trials') -ToolsFile $toolsPath -SharedCompilerJobs $sharedCompilerJobs
        $record.status='prepared_for_functional_pair'
        $record.configuration=$configurationReceipt
        $record.protocol=$protocolPath
        $record.local_package=$localPackage
        $record.expected_shared_compiler_jobs=$sharedCompilerJobs
    } catch {
        $record.status='failed'
        $record.error=$_.Exception.Message
        throw
    } finally {
        $lock.Dispose()
        $record.finished_at=(Get-Date).ToString('o')
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ownerPath -Encoding utf8
    }
    Write-Output "Prepared local functional study: $work"
    return
}

$prepared=Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
if ($prepared.status -ne 'prepared_for_functional_pair' -or
    $prepared.package_manifest_sha256 -cne $manifestHash -or $prepared.root -cne $work) {
    throw 'The prepared work root does not match this immutable package.'
}
$null=Assert-HandoffPackage $prepared.local_package
$scripts=Join-Path $prepared.local_package 'scripts\msbuild'
$protocol=Get-Content -LiteralPath $prepared.protocol -Raw | ConvertFrom-Json
if ($protocol.comparison_axis -cne $profile.comparison_axis -or
    (@($protocol.order) -join '|') -cne (@($profile.conditions) -join '|')) {
    throw 'The frozen protocol does not select the packaged baseline/fixed comparison.'
}
foreach ($condition in $profile.conditions) {
    if (Test-Path -LiteralPath (Join-Path $work "results\$condition")) {
        throw 'Functional results already exist; no automatic repeat or overwrite is allowed.'
    }
}
foreach ($condition in $profile.conditions) {
    & (Join-Path $scripts 'Invoke-CiPilot.ps1') -Action Run -ProtocolPath $prepared.protocol -Condition $condition
    & (Join-Path $scripts 'Export-CiFunctionalResults.ps1') -ProtocolPath $prepared.protocol `
        -Condition $condition -Destination (Join-Path $work "results\$condition")
}
& (Join-Path $scripts 'Test-CiFunctionalPair.ps1') -ProtocolPath $prepared.protocol `
    -OutputPath (Join-Path $work 'results\summary.json')
Write-Output "Functional pair complete. Results: $(Join-Path $work 'results'). Timings are diagnostic only."
