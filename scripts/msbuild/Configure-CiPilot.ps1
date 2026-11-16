#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OriginalStudyReceipt,
    [Parameter(Mandatory)][string]$HeaderReceipt,
    [Parameter(Mandatory)][string]$DevelopmentReceipt,
    [Parameter(Mandatory)][string]$DevRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$DevCommit,
    [Parameter(Mandatory)][ValidatePattern('^build-[a-z0-9-]+$')][string]$BuildDirectory,
    [string]$ExpectedWorkload,
    [string]$RepositoryProfile,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NativeArchitecture.psm1')
if (Test-Path -LiteralPath $OutputPath) { throw 'Configuration receipt already exists.' }
$original = Get-Content -LiteralPath $OriginalStudyReceipt -Raw | ConvertFrom-Json
$headers = Get-Content -LiteralPath $HeaderReceipt -Raw | ConvertFrom-Json
$development = Get-Content -LiteralPath $DevelopmentReceipt -Raw | ConvertFrom-Json
if ($headers.status -ne 'compile_input_abi_passed_native_numpy_runtime_unverified' -or
    (Get-FileHash -LiteralPath $DevelopmentReceipt).Hash -cne $headers.python_development_receipt_sha256) {
    throw 'The verified compile-input receipts do not match.'
}
$root = $original.root
$build = Join-Path $root $BuildDirectory
if (Test-Path -LiteralPath $build) { throw 'A fresh build directory is required; the old cache must remain unchanged.' }
$repositories = @(
    [ordered]@{
        path=(Join-Path $root 'opencv'); repository='DinahK-2SO/opencv'; branch_name='5.x'
        target_commit_sha='c261e6e4b4e4bf3c1bf4e7da23193943400579ca'
    },
    [ordered]@{
        path=(Join-Path $root 'ci-baseline'); repository='DinahK-2SO/ci-gha-workflow'; branch_name='main'
        target_commit_sha='26e5e9767c2278b18eec51763a1a85de7a44cfc3'
    },
    [ordered]@{
        path=$DevRoot; repository='DinahK-2SO/ci-gha-workflow'; branch_name='perf/windows-msbuild-shared-budget'
        target_commit_sha=$DevCommit
    }
)
if ($RepositoryProfile) {
    $profile = Get-Content -LiteralPath $RepositoryProfile -Raw | ConvertFrom-Json
    $entries = @($profile.opencv,$profile.ci_baseline,$profile.ci_dev)
    for ($index=0; $index -lt $entries.Count; $index++) {
        $entry=$entries[$index]
        if ($entry.commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Repository profile requires exact commits.' }
        $repositories[$index].repository=$entry.repository
        $repositories[$index].branch_name=$entry.branch_name
        $repositories[$index].target_commit_sha=$entry.commit
    }
}
foreach ($repository in $repositories) {
    $actual = (& git -C $repository.path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -cne $repository.target_commit_sha) { throw 'A fixed checkout identity changed.' }
    $dirty = @(& git -C $repository.path status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw 'A selected checkout is not clean.' }
    $repository.actual_commit_sha = $actual
}
$dependencyFiles = @(
    [ordered]@{ path=$development.identity.executable; sha256=$development.interpreter_sha256 },
    [ordered]@{ path=$development.import_library; sha256=$development.import_library_sha256 },
    [ordered]@{ path=(Join-Path (Split-Path $development.identity.executable) 'include\Python.h'); sha256=$development.python_header_sha256 },
    [ordered]@{ path=(Join-Path (Split-Path $development.identity.executable) 'python313.dll'); sha256=$headers.python_runtime_dll_sha256 }
)
foreach ($file in $headers.origin.files) {
    $dependencyFiles += [ordered]@{ path=(Join-Path $headers.include $file.path.Replace('/','\')); sha256=$file.sha256.ToUpperInvariant() }
}
foreach ($file in $dependencyFiles) {
    if ((Get-FileHash -LiteralPath $file.path).Hash -cne $file.sha256) { throw "A verified dependency changed: $($file.path)" }
}
$arguments = @($original.configure_arguments)
$architectureIndex=[Array]::IndexOf($arguments,'-A')
if ($architectureIndex -lt 0 -or $architectureIndex+1 -ge $arguments.Count) { throw 'The configure recipe must declare its native target architecture.' }
$platform=Get-NativeBuildPlatform $arguments[$architectureIndex+1]
if ($development.interpreter_machine -cne $platform.machine -or
    ($RepositoryProfile -and $profile.architecture -cne $platform.architecture)) {
    throw 'Python development/profile architecture differs from the configure recipe.'
}
$buildIndex = [Array]::IndexOf($arguments, '-B')
if ($buildIndex -lt 0 -or $arguments[$buildIndex+1] -ne 'build') { throw 'Unexpected original configure recipe.' }
$arguments[$buildIndex+1] = $BuildDirectory
$python = $development.identity.executable
$arguments += @(
    "-DPYTHON3_EXECUTABLE:FILEPATH=$python","-DPYTHON_DEFAULT_EXECUTABLE:FILEPATH=$python",
    "-DPYTHON3_INCLUDE_DIR:PATH=$(Join-Path (Split-Path $python) 'include')",
    "-DPYTHON3_LIBRARY:FILEPATH=$($development.import_library)",
    "-DPYTHON3_NUMPY_INCLUDE_DIRS:PATH=$($headers.include)"
)
New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
$result = [ordered]@{
    started_at=(Get-Date).ToString('o')
    status='configuring'
    preparer_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
    workload_guard_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'ci_action_trial.py')).Hash
    profile="opencv-5x-$($platform.architecture.ToLowerInvariant())-base-numpy-headers-v1"
    architecture=$platform.architecture
    root=$root
    build_directory=$BuildDirectory
    repositories=$repositories
    original_recipe_receipt_sha256=(Get-FileHash -LiteralPath $OriginalStudyReceipt).Hash
    header_receipt_sha256=(Get-FileHash -LiteralPath $HeaderReceipt).Hash
    configure_arguments=$arguments
    dependency_files=$dependencyFiles
    scope='Full selected base-build target set, including Python bindings; not contrib or native Python runtime qualification.'
    native_numpy_runtime_verified=$false
    preparation_is_outside_build_timing=$true
}
if ($ExpectedWorkload) {
    $result.expected_workload_sha256=(Get-FileHash -LiteralPath $ExpectedWorkload).Hash
}
$log = Join-Path $root "$BuildDirectory-configure.log"
$result.configure_log = $log
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'BoundedProcess.cs')
    $env:PATH = "$(Split-Path $python);$(Split-Path $original.cmake);$env:PATH"
    $env:CMAKE_BUILD_PARALLEL_LEVEL = '8'
    $env:OPENCV_DOWNLOAD_PATH = Join-Path $root 'download-cache'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:PYTHONNOUSERSITE = '1'
    $result.configure = [OpenCvBoundedProcess]::Run($original.cmake,$arguments,$root,$log,900)
    if ($result.configure.TimedOut -or $result.configure.ExitCode -ne 0) { throw 'Fresh native configuration failed.' }
    $inspect = @'
import json
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from ci_action_trial import check_native_python, check_configured_workload, read_cmake_cache
old, new = (Path(value) for value in sys.argv[2:4])
if len(sys.argv) > 5:
    expected = json.loads(Path(sys.argv[5]).read_text(encoding="utf-8-sig"))
else:
    a = read_cmake_cache(old)
    expected = {
        "feature_options": {key: val for key, val in a.items() if key.startswith(("BUILD_", "WITH_"))},
        "modules": a["OPENCV_MODULES_BUILD"].split(";"),
    }
result = check_configured_workload(new, expected, old)
result["native_python"] = check_native_python(new, sys.argv[4])
print(json.dumps(result))
'@
    $inspectionArguments = @('-B','-c',$inspect,$PSScriptRoot,(Join-Path $root 'build'),$build,$platform.architecture)
    if ($ExpectedWorkload) { $inspectionArguments += $ExpectedWorkload }
    $raw = & $original.measurement_python @inspectionArguments
    if ($LASTEXITCODE -ne 0) { throw 'Configured workload/dependency checks failed; do not time this tree.' }
    $result.workload_check = ($raw -join "`n") | ConvertFrom-Json
    $result.cache_sha256 = (Get-FileHash -LiteralPath (Join-Path $build 'CMakeCache.txt')).Hash
    $result.numpy_runtime_query_failed = [bool](Select-String -LiteralPath $log -SimpleMatch "No module named 'numpy'" -Quiet)
    $result.process_environment = [ordered]@{
        CMAKE_BUILD_PARALLEL_LEVEL='8'
        OPENCV_DOWNLOAD_PATH=$env:OPENCV_DOWNLOAD_PATH
        PYTHONDONTWRITEBYTECODE='1'
        PYTHONNOUSERSITE='1'
    }
    $result.status = 'configured_full_base_workload_pending_pilots'
} catch {
    $result.status='failed'
    $result.error=$_.Exception.Message
    throw
} finally {
    $result.finished_at=(Get-Date).ToString('o')
    $result.configure_log_written = Test-Path -LiteralPath $log
    if ($result.configure_log_written) {
        $result.configure_log_sha256 = (Get-FileHash -LiteralPath $log).Hash
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
Write-Output "Fresh $($platform.architecture) configuration passes the declared workload and freezes its features/modules/projects for all selected commits; native NumPy runtime remains unverified."
