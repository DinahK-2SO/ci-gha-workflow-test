#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [string]$StudyRoot = 'C:\opencv-onboard\msbuild5x-20261110',
    [string]$CiRepository = 'C:\ado\ci-gha-workflow',
    [string]$CmakeRoot = 'C:\opencv-onboard\harness\.tools\cmake-4.1.1-windows-arm64',
    [ValidateSet('https','ssh')][string]$SourceTransport = 'https'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HandoffSupport.psm1') -Force
$destinationPath=Assert-LocalStudyPath $Destination $PSScriptRoot
if (Test-Path -LiteralPath $destinationPath) { throw 'Package destination already exists.' }
if (Test-Path -LiteralPath $ReceiptPath) { throw 'Package-build receipt already exists.' }
$stage=$destinationPath+'.staging'
if (Test-Path -LiteralPath $stage) { throw 'Package staging directory already exists.' }
$sourceRoot=Split-Path $PSScriptRoot
$resultsRoot=Join-Path $sourceRoot '..\results\2026-1111'
$developmentPath=Join-Path $resultsRoot 'dependency-preparation\python-development.json'
$headerPath=Join-Path $resultsRoot 'compile-dependency-validation\numpy-headers-02.json'
$configurationPath=Join-Path $resultsRoot 'native-base-configuration\configuration-02.json'
$profile=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profile.json') -Raw | ConvertFrom-Json
Assert-HandoffProfile $profile
$development=Get-Content -LiteralPath $developmentPath -Raw | ConvertFrom-Json
$headers=Get-Content -LiteralPath $headerPath -Raw | ConvertFrom-Json
$configuration=Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
$pythonPackage=Join-Path $StudyRoot 'tools\pythonarm64.3.13.14.nupkg'
if ((Get-FileHash -LiteralPath $pythonPackage -Algorithm SHA512).Hash -cne $development.package_sha512) {
    throw 'The verified Python development archive changed.'
}
$originalStudy=Get-Content -LiteralPath (Join-Path $sourceRoot '..\results\2026-1110\msbuild5x-preparation\study.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath (Join-Path $CmakeRoot 'bin\cmake.exe')).Hash -cne $originalStudy.cmake_sha256) {
    throw 'Portable CMake differs from the verified study tool.'
}
$record=[ordered]@{
    started_at=(Get-Date).ToString('o')
    status='building'
    package=$destinationPath
    staging=$stage
    profile_id=$profile.profile_id
    comparison_axis=$profile.comparison_axis
    source_transport=$SourceTransport
    no_lab_share_accessed=$true
    no_lab_resource_or_workitem_mutation=$true
    sources=@()
}
New-Item -ItemType Directory -Path $destinationPath,$stage,(Split-Path $ReceiptPath) -Force | Out-Null
try {
    foreach ($directory in @('sources','runtime','inputs\numpy\include','inputs\yaml\yaml',
            'licenses','scripts\msbuild\tests\numpy-headers')) {
        New-Item -ItemType Directory -Path (Join-Path $destinationPath $directory) -Force | Out-Null
    }
    foreach ($name in @('Start-Study.ps1','HandoffSupport.psm1','profile.json','README.md')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destinationPath $name)
    }
    foreach ($name in @('BoundedProcess.cs','NativeArchitecture.psm1','Test-BoundedProcess.ps1','Prepare-PythonDevelopment.ps1',
            'Configure-CiPilot.ps1','Invoke-CiPilot.ps1','Export-CiFunctionalResults.ps1',
            'Test-CiFunctionalPair.ps1','Watch-BuildResources.ps1','ci_action_trial.py','cmake_probe.py','prepare_ci_action.py','build_contract.py')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $destinationPath "scripts\msbuild\$name")
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot '..\Get-HostSnapshot.ps1') -Destination (Join-Path $destinationPath 'scripts\Get-HostSnapshot.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'tests\bounded_fixture.py') -Destination (Join-Path $destinationPath 'scripts\msbuild\tests\bounded_fixture.py')
    foreach ($name in @('CMakeLists.txt','main.cpp')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot "tests\numpy-headers\$name") -Destination (Join-Path $destinationPath "scripts\msbuild\tests\numpy-headers\$name")
    }
    Copy-Item -LiteralPath $CmakeRoot -Destination (Join-Path $destinationPath 'runtime\cmake') -Recurse
    Copy-Item -LiteralPath $pythonPackage -Destination (Join-Path $destinationPath 'inputs\pythonarm64.3.13.14.nupkg')
    Copy-Item -LiteralPath (Join-Path (Split-Path $development.identity.executable) 'LICENSE.txt') -Destination (Join-Path $destinationPath 'licenses\Python-LICENSE.txt')
    foreach ($file in $headers.origin.files) {
        $relative=$file.path.Replace('/','\')
        $source=Join-Path $headers.include $relative
        if ((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne $file.sha256) { throw 'NumPy include input changed.' }
        $target=Join-Path $destinationPath "inputs\numpy\include\$relative"
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target
    }
    [ordered]@{version=$headers.numpy_version;wheel_metadata=$headers.origin.wheel_metadata;files=$headers.origin.files} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destinationPath 'inputs\numpy\origin.json') -Encoding utf8
    $packageInputs=@'
import base64
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import sys
root = Path(sys.argv[1])
records = []
for name, expected in (("PyYAML", "6.0.3"), ("numpy", "2.4.2")):
    dist = importlib.metadata.distribution(name)
    if dist.version != expected:
        raise ValueError("Unexpected installed dependency version: " + name)
    for entry in dist.files:
        text = str(entry)
        destination = None
        if name == "PyYAML" and text.startswith("yaml/") and text.endswith(".py"):
            destination = root / "inputs" / "yaml" / text
        elif ".dist-info/licenses/" in text and entry.name in ("LICENSE", "LICENSE.txt"):
            destination = root / "licenses" / (name + "-LICENSE.txt")
        if destination is None:
            continue
        data = entry.locate().read_bytes()
        digest = hashlib.sha256(data).digest()
        encoded = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
        if entry.hash is None or entry.hash.mode != "sha256" or entry.hash.value != encoded:
            raise ValueError("Installed dependency input differs from RECORD: " + text)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(entry.locate(), destination)
        records.append({"package": name, "version": expected, "path": str(destination.relative_to(root)),
                        "sha256": digest.hex()})
if not (root / "inputs" / "yaml" / "yaml" / "__init__.py").is_file():
    raise ValueError("Pure Python YAML package is incomplete")
for name in ("PyYAML", "numpy"):
    if not (root / "licenses" / (name + "-LICENSE.txt")).is_file():
        raise ValueError("Required license missing: " + name)
print(json.dumps(records))
'@
    $raw=& python -B -c $packageInputs $destinationPath
    if ($LASTEXITCODE -ne 0) { throw 'Portable dependency source/license preparation failed.' }
    ($raw -join "`n") | Set-Content -LiteralPath (Join-Path $destinationPath 'inputs\source-dependency-provenance.json') -Encoding utf8
    $cache=Join-Path $configuration.root "$($configuration.build_directory)\CMakeCache.txt"
    if ((Get-FileHash -LiteralPath $cache).Hash -cne $configuration.cache_sha256) { throw 'The expected workload source cache changed.' }
    $features=[ordered]@{}
    foreach ($line in Get-Content -LiteralPath $cache) {
        if ($line -match '^((?:BUILD_|WITH_)[^:]+):[^=]+=(.*)$') { $features[$Matches[1]]=$Matches[2] }
    }
    [ordered]@{
        source_commit=$profile.opencv.commit
        feature_options=$features
        modules=$configuration.workload_check.modules
        projects=$configuration.workload_check.projects
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destinationPath 'expected-workload.json') -Encoding utf8

    foreach ($selection in @(
        @{name='opencv'; local=(Join-Path $StudyRoot 'opencv'); entries=@($profile.opencv)},
        @{name='ci'; local=$CiRepository; entries=@($profile.ci_baseline,$profile.ci_dev)}
    )) {
        $bare=Join-Path $stage "$($selection.name).git"
        git clone --quiet --bare --shared $selection.local $bare
        if ($LASTEXITCODE -ne 0) { throw 'Local object-cache preparation failed.' }
        $refs=@()
        foreach ($entry in $selection.entries) {
            $url="https://github.com/$($entry.repository).git"
            $publicMetadata=$null
            if ($SourceTransport -eq 'ssh') {
                $response=@(& gh api "repos/$($entry.repository)" --jq '{full_name: .full_name, private: .private}')
                if ($LASTEXITCODE -ne 0) { throw 'Cannot verify public repository visibility for SSH retrieval.' }
                $publicMetadata=($response -join "`n") | ConvertFrom-Json
                if ($publicMetadata.private -ne $false -or
                    $publicMetadata.full_name -cne $entry.repository) {
                    throw 'SSH retrieval requires the exact public repository.'
                }
                $url="git@github.com:$($entry.repository).git"
            }
            $remote=@(& git ls-remote $url "refs/heads/$($entry.branch_name)")
            if ($LASTEXITCODE -ne 0 -or $remote.Count -ne 1) { throw 'Cannot verify a selected public branch.' }
            $remoteHead=($remote[0] -split '\s+')[0]
            git --git-dir $bare fetch --quiet $url $entry.commit
            if ($LASTEXITCODE -ne 0) { throw 'The pinned commit could not be retrieved from its public repository.' }
            git --git-dir $bare update-ref $entry.bundle_ref $entry.commit
            if ($LASTEXITCODE -ne 0) { throw 'Cannot create an isolated bundle ref.' }
            $refs += $entry.bundle_ref
            $record.sources += [ordered]@{
                repository=$entry.repository; branch_name=$entry.branch_name
                public_branch_head_at_check=$remoteHead; target_commit_sha=$entry.commit
                bundle=$entry.bundle; bundle_ref=$entry.bundle_ref
                retrieval_url=$url; public_repository_metadata=$publicMetadata
            }
        }
        $bundle=Join-Path $destinationPath "sources\$($selection.name).bundle"
        & git --git-dir $bare bundle create --version=2 $bundle @refs
        if ($LASTEXITCODE -ne 0) { throw 'Self-contained Git bundle creation failed.' }
        $empty=Join-Path $stage "$($selection.name)-verify.git"
        git init --quiet --bare $empty
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create the empty verification repository.' }
        & git --git-dir $empty bundle verify $bundle *> (Join-Path $stage "$($selection.name)-bundle-verify.log")
        if ($LASTEXITCODE -ne 0) { throw 'The bundle depends on objects outside the package.' }
    }
    $record.sources | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destinationPath 'sources\provenance.json') -Encoding utf8
    $inventory=@(Get-PackageInventory $destinationPath)
    [ordered]@{
        schema_version=1
        package_kind='local-functional-handoff'
        created_at=(Get-Date).ToString('o')
        profile_id=$profile.profile_id
        comparison_axis=$profile.comparison_axis
        review_commit=$profile.ci_dev.commit
        opencv_commit=$profile.opencv.commit
        lab_permission_granted=$false
        lab_platform_integration_validated=$false
        performance_eligible=$false
        files=$inventory
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $destinationPath 'package-manifest.json') -Encoding utf8
    $manifest=Assert-HandoffPackage $destinationPath
    Assert-HandoffProfile $profile $manifest
    $record.file_count=$inventory.Count
    $record.payload_bytes=($inventory.bytes | Measure-Object -Sum).Sum
    $record.manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $destinationPath 'package-manifest.json')).Hash
    $record.status='assembled_pending_relocated_validation'
} catch {
    $record.status='failed'
    $record.error=$_.Exception.Message
    throw
} finally {
    $record.finished_at=(Get-Date).ToString('o')
    $record | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
}
Write-Output "Local handoff assembled: $destinationPath"
