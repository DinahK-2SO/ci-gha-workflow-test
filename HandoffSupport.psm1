Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\msbuild\NativeArchitecture.psm1')

function Assert-LocalStudyPath([string]$Path, [string]$PackageRoot) {
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Work/output paths must be fully qualified local drive paths, not UNC or relative paths.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $drive = [IO.Path]::GetPathRoot($full)
    if ($full -eq $drive.TrimEnd('\') -or [IO.DriveInfo]::new($drive).DriveType -ne [IO.DriveType]::Fixed) {
        throw 'A non-root directory on a fixed local drive is required.'
    }
    if ($PackageRoot) {
        $package = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
        if ($full -eq $package -or $full.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'The work root must not be inside the immutable package.'
        }
    }
    $existing = $full
    while ($existing -and -not (Test-Path -LiteralPath $existing)) { $existing = Split-Path $existing }
    while ($existing) {
        if ((Get-Item -LiteralPath $existing -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'A work-root ancestor is a reparse point; its destination is not approved.'
        }
        $parent = Split-Path $existing
        if ($parent -eq $existing) { break }
        $existing = $parent
    }
    return $full
}

function Get-PackageInventory([string]$Root) {
    $entries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    if (@($entries | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {
        throw 'Package reparse points are not supported.'
    }
    @(foreach ($file in $entries | Where-Object {-not $_.PSIsContainer} | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($Root,$file.FullName)
        if ($relative -eq 'package-manifest.json') { continue }
        [ordered]@{path=$relative; bytes=$file.Length; sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
    })
}

function Assert-HandoffPackage([string]$Root,[switch]$SkipIntegrityChecks) {
    $manifestPath = Join-Path $Root 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.package_kind -ne 'local-functional-handoff') {
        throw 'Unsupported handoff package manifest.'
    }
    if ($SkipIntegrityChecks) { return $manifest }
    $actual = @(Get-PackageInventory $Root)
    $expectedPaths = @($manifest.files.path | Sort-Object)
    if ((@($actual.path | Sort-Object) -join '|') -cne ($expectedPaths -join '|')) {
        throw 'Package file inventory changed.'
    }
    $expected = @{}
    foreach ($file in $manifest.files) {
        if ([IO.Path]::IsPathRooted($file.path) -or $file.path -match '(^|[\\/])\.\.([\\/]|$)' -or
            $expected.ContainsKey($file.path)) { throw 'Invalid or duplicate package path.' }
        $expected[$file.path]=$file
    }
    foreach ($file in $actual) {
        $reference=$expected[$file.path]
        if ($reference.bytes -ne $file.bytes -or $reference.sha256 -cne $file.sha256) {
            throw "Package integrity check failed: $($file.path)"
        }
    }
    return $manifest
}

function Assert-HandoffProfile($Profile, $Manifest = $null) {
    $null=Get-NativeBuildPlatform $Profile.architecture
    $independent=$Profile.comparison_axis -ceq 'independent_sources'
    $expectedOrder=if ($independent) {'baseline'} else {'baseline|fixed'}
    if ($Profile.schema_version -ne 2 -or
        $Profile.comparison_axis -cnotin @('baseline_vs_fixed_commit','independent_sources') -or
        (@($Profile.conditions) -join '|') -cne $expectedOrder) {
        throw 'The package profile must select schema 2 and a baseline/fixed comparison or an independent source case.'
    }
    $entries=@($Profile.opencv,$Profile.ci_baseline)
    if (-not $independent) { $entries+=@($Profile.ci_dev) }
    foreach ($entry in $entries) {
        if ($entry.commit -cnotmatch '^[0-9a-f]{40}$') {
            throw 'A full fixed commit SHA is required for every bundled repository.'
        }
    }
    if (-not $independent -and $Profile.ci_baseline.commit -ceq $Profile.ci_dev.commit) {
        throw 'Baseline and fixed CI commits must differ.'
    }
    if ($Profile.PSObject.Properties['compiler_budget_policy'] -and
        $Profile.compiler_budget_policy -cne 'available_logical_processors') {
        throw 'Unsupported compiler-budget discovery policy.'
    }
    if ($Manifest -and ($Manifest.profile_id -cne $Profile.profile_id -or
        $Manifest.comparison_axis -cne $Profile.comparison_axis -or
        $Manifest.review_commit -cne $(if($independent){$Profile.ci_baseline.commit}else{$Profile.ci_dev.commit}) -or
        $Manifest.opencv_commit -cne $Profile.opencv.commit)) {
        throw 'Package manifest and profile identities differ.'
    }
    if ($Manifest -and $Manifest.PSObject.Properties['architecture'] -and
        $Manifest.architecture -cne $Profile.architecture) {
        throw 'Package manifest and profile architectures differ.'
    }
}

function Find-HandoffToolchain([string]$Architecture = (Get-NativeBuildPlatform).architecture) {
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        throw 'This comparison requires Windows.'
    }
    $platform=Get-NativeBuildPlatform $Architecture
    $native=Get-NativeBuildPlatform
    if ($platform.architecture -cne $native.architecture) {
        throw "Package architecture $Architecture differs from native Windows $($native.architecture). Use the source handoff folder to select matching dependencies automatically."
    }
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $prefix = Split-Path $git
    $bash = $null
    for ($i=0; $i -lt 4 -and $prefix; $i++) {
        $candidate = Join-Path $prefix 'bin\bash.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $bash=$candidate; break }
        $prefix=Split-Path $prefix
    }
    if (-not $bash) { throw 'Git Bash was not found beside Git; install/authorize the required toolchain separately.' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Visual Studio discovery tool is absent; no installer will be run.' }
    $raw = & $vswhere -latest -products '*' -version '[17.0,18.0)' -format json -utf8
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed.' }
    $instances = @(($raw -join "`n") | ConvertFrom-Json)
    if ($instances.Count -ne 1) { throw 'No unique Visual Studio 2022 installation was selected.' }
    $vs=$instances[0].installationPath
    $version=(Get-Content -LiteralPath (Join-Path $vs 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $bin=Join-Path $vs "VC\Tools\MSVC\$version\bin\$($platform.compiler_subdirectory)"
    $tools=[ordered]@{
        architecture=$platform.architecture
        os_architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        git=$git; bash=$bash; visual_studio=$vs; toolset=$version
        compiler=(Join-Path $bin 'cl.exe')
        linker=(Join-Path $bin 'link.exe')
        dumpbin=(Join-Path $bin 'dumpbin.exe')
        msbuild=(Join-Path $vs "MSBuild\Current\Bin\$($platform.msbuild_subdirectory)\MSBuild.exe")
    }
    foreach ($name in @('git','bash','compiler','linker','dumpbin','msbuild')) {
        if (-not (Test-Path -LiteralPath $tools[$name] -PathType Leaf)) {
            throw "Required installed $($platform.architecture) tool is missing: $name at $($tools[$name]). Install the matching VS2022 C++ tools/SDK separately."
        }
    }
    return $tools
}

Export-ModuleMember -Function Assert-LocalStudyPath,Get-PackageInventory,Assert-HandoffPackage,Assert-HandoffProfile,Find-HandoffToolchain,Get-NativeBuildPlatform
