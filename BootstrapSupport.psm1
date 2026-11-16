Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-ComparisonSourceFiles {
    @(
        'BoundedProcess.cs','NativeArchitecture.psm1','Test-BoundedProcess.ps1','Prepare-PythonDevelopment.ps1',
        'Configure-CiPilot.ps1','Invoke-CiPilot.ps1','Export-CiFunctionalResults.ps1',
        'Test-CiFunctionalPair.ps1','Watch-BuildResources.ps1','ci_action_trial.py',
        'cmake_probe.py','prepare_ci_action.py','build_contract.py',
        'tests\bounded_fixture.py','tests\numpy-headers\CMakeLists.txt','tests\numpy-headers\main.cpp'
    )
}

function Assert-ComparisonRuntimeSources([string]$SourceRoot) {
    $scriptPaths=@('Get-HostSnapshot.ps1') + @(Get-ComparisonSourceFiles | ForEach-Object {"msbuild\$_"})
    $sources=Get-Content -LiteralPath (Join-Path $SourceRoot 'source-manifest.json') -Raw | ConvertFrom-Json
    if ($sources.schema_version -ne 1 -or
        (@($sources.files.path | Sort-Object) -join '|') -cne (@($scriptPaths | Sort-Object) -join '|')) {
        throw 'Bundled runtime source inventory differs from the required closure.'
    }
    foreach ($file in $sources.files) {
        $path=Join-Path $SourceRoot "scripts\$($file.path)"
        if ((Get-Item -LiteralPath $path).Length -ne $file.bytes -or
            (Get-FileHash -LiteralPath $path).Hash -cne $file.sha256) {
            throw "Bundled runtime source integrity check failed: $($file.path). Restore the matching handoff source snapshot."
        }
    }
}

function Get-ComparisonDependencyLock($Lock,[string]$Architecture) {
    $platform=Get-NativeBuildPlatform $Architecture
    if ($Lock.schema_version -ne 2) { throw 'Unsupported bootstrap dependency lock.' }
    $selected=$Lock.platforms.($platform.architecture)
    [pscustomobject]@{
        schema_version=1;architecture=$platform.architecture
        cmake=$selected.cmake;python=$selected.python;numpy=$Lock.numpy;yaml=$Lock.yaml
    }
}

function Assert-ComparisonSourceTree([string]$SourceRoot) {
    $files=@('Run-Comparison.ps1','ComparisonSupport.psm1','HandoffSupport.psm1',
        'Start-Study.ps1','profile.json','COMPARISON.md','bootstrap-lock.json','expected-workload.json',
        'expected-workload-x64.json','source-manifest.json','scripts\Get-HostSnapshot.ps1') +
        @(Get-ComparisonSourceFiles | ForEach-Object {"scripts\msbuild\$_"})
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot $file) -PathType Leaf)) {
            throw "Incomplete comparison source folder: $file. Restore the complete handoff folder, including scripts and source-manifest.json; no parent-directory helpers are required."
        }
    }
    Assert-ComparisonRuntimeSources $SourceRoot
    $lock=Get-Content -LiteralPath (Join-Path $SourceRoot 'bootstrap-lock.json') -Raw | ConvertFrom-Json
    foreach ($architecture in @('ARM64','x64')) {
        $selected=Get-ComparisonDependencyLock $lock $architecture
        foreach ($name in @('cmake','python','numpy','yaml')) {
            $entry=$selected.$name
            $hash=if ($entry.algorithm -eq 'SHA512') {
                [Convert]::ToHexString([Convert]::FromBase64String($entry.hash_base64))
            } else { $entry.hash }
            if ($entry.filename -cnotmatch '^[A-Za-z0-9_.-]+$' -or
                ($entry.algorithm -ceq 'SHA256' -and $hash -notmatch '^[a-f0-9]{64}$') -or
                ($entry.algorithm -ceq 'SHA512' -and $hash -notmatch '^[a-f0-9]{128}$') -or
                $entry.algorithm -cnotin @('SHA256','SHA512')) {
                throw "Invalid pinned dependency: $name"
            }
            if ($name -in @('numpy','yaml')) {
                $null=Get-ComparisonWheelSpec $entry
            } elseif (-not $entry.PSObject.Properties['url'] -or $entry.url -cnotmatch '^https://') {
                throw "Invalid pinned dependency URL: $name"
            }
        }
    }
    $profile=Get-Content -LiteralPath (Join-Path $SourceRoot 'profile.json') -Raw | ConvertFrom-Json
    Assert-HandoffProfile $profile
    foreach ($name in @('expected-workload.json','expected-workload-x64.json')) {
        $expected=Get-Content -LiteralPath (Join-Path $SourceRoot $name) -Raw | ConvertFrom-Json
        if ($expected.source_commit -cne $profile.opencv.commit) { throw 'Bootstrap workload/source identities differ.' }
    }
}

function Resolve-ComparisonCacheRoot($Config,[string]$SourceRoot) {
    $path=if ($Config.PSObject.Properties['cache_root'] -and $null -ne $Config.cache_root) {
        $Config.cache_root
    } else {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; set cache_root to an explicit local directory.'
        }
        Join-Path $env:LOCALAPPDATA 'opencv-build-test\cache'
    }
    return Assert-LocalStudyPath $path $SourceRoot
}

function Get-ComparisonWheelSpec($Entry) {
    if (-not $Entry.PSObject.Properties['source'] -or $Entry.source -cne 'pip' -or
        $Entry.algorithm -cne 'SHA256' -or
        $Entry.filename -cnotmatch '^(?<package>[A-Za-z0-9_]+)-(?<version>[0-9][A-Za-z0-9_.]*)-cp(?<python>[0-9]+)-(?<abi>[A-Za-z0-9_]+)-(?<platform>[A-Za-z0-9_]+)\.whl$') {
        throw 'Expected a pinned CPython wheel with source=pip and a SHA256 digest.'
    }
    [pscustomobject]@{
        requirement="$($Matches.package)==$($Matches.version)"
        python=$Matches.python;abi=$Matches.abi;platform=$Matches.platform
    }
}

function Receive-ComparisonWheel($Entry,[string]$Partial,[string]$Python) {
    $spec=Get-ComparisonWheelSpec $Entry
    if ($env:VIRTUAL_ENV) {
        $Python=Join-Path $env:VIRTUAL_ENV 'Scripts\python.exe'
    }
    if (-not $Python -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw 'Wheel acquisition requires the prepared portable Python, or a valid active virtual environment with pip. No alternate downloader was attempted.'
    }
    $work=Join-Path (Split-Path $Partial) ('pip-'+[guid]::NewGuid().ToString('N').Substring(0,12))
    $wheels=Join-Path $work 'wheels'
    New-Item -ItemType Directory -Path $wheels | Out-Null
    $requirements=Join-Path $work 'requirements.txt'
    "$($spec.requirement) --hash=sha256:$($Entry.hash)" |
        Set-Content -LiteralPath $requirements -Encoding utf8NoBOM
    $log=Join-Path $work 'pip.log'
    $arguments=@('-m','pip','download','--disable-pip-version-check','--no-input',
        '--no-deps','--only-binary=:all:','--require-hashes','--no-cache-dir','--retries','0',
        '--implementation','cp','--python-version',$spec.python,'--abi',$spec.abi,
        '--platform',$spec.platform,'--dest',$wheels,'--requirement',$requirements)
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scripts\msbuild\BoundedProcess.cs') -Raw)
    Write-Host 'Using pip package-source configuration; PyPI is only the unconfigured pip default.'
    $result=[OpenCvBoundedProcess]::Run($Python,$arguments,$work,$log,600)
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        throw "Configured pip download failed (exit $($result.ExitCode), timed out: $($result.TimedOut)). No alternate source was attempted. Private diagnostics: $log"
    }
    $download=Join-Path $wheels $Entry.filename
    if (-not (Test-Path -LiteralPath $download -PathType Leaf) -or
        @(Get-ChildItem -LiteralPath $wheels -File).Count -ne 1) {
        throw "pip did not produce the exact locked wheel: $($Entry.filename). Preserve diagnostics at $work; no substitute was accepted."
    }
    [IO.File]::Move($download,$Partial)
}

function Receive-ComparisonDependency($Entry,[string]$Directory,[string]$CacheRoot,[string]$PipPython) {
    $expected=if ($Entry.algorithm -eq 'SHA512') {
        [Convert]::ToHexString([Convert]::FromBase64String($Entry.hash_base64))
    } else { $Entry.hash }
    $expected=$expected.ToLowerInvariant()
    $cacheDirectory=Join-Path $CacheRoot "$($Entry.algorithm.ToLowerInvariant())\$expected"
    $null=Assert-LocalStudyPath $cacheDirectory ''
    $cached=Join-Path $cacheDirectory $Entry.filename
    $lockPath=$cached+'.lock'
    $path=Join-Path $Directory $Entry.filename
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite dependency: $path" }
    $null=Assert-LocalStudyPath $lockPath ''
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    try {
        $guard=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -notin @(32,33)) { throw }
        throw "Dependency cache entry is in use: $cached. No download attempted; retry after the other operation finishes."
    }
    try {
        $status='hit'
        if (-not (Test-Path -LiteralPath $cached)) {
            $status='miss'
            $partial=Join-Path $cacheDirectory ($Entry.filename+'.partial-'+[guid]::NewGuid().ToString('N'))
            Write-Host "Downloading pinned dependency (cache miss): $($Entry.filename)"
            try {
                if ($Entry.PSObject.Properties['source'] -and $Entry.source -ceq 'pip') {
                    Receive-ComparisonWheel $Entry $partial $PipPython
                } else {
                    Invoke-WebRequest -Uri $Entry.url -OutFile $partial -TimeoutSec 600 -MaximumRetryCount 0
                }
            } catch {
                throw "Dependency download failed: $($Entry.filename). Partial download, if any, is preserved at $partial. $($_.Exception.Message)"
            }
            if ((Get-FileHash -LiteralPath $partial -Algorithm $Entry.algorithm).Hash -ine $expected) {
                throw "Dependency checksum mismatch: $($Entry.filename). Failed download preserved at $partial; cache entry was not published."
            }
            [IO.File]::Move($partial,$cached)
        }
        $null=Assert-LocalStudyPath $cached ''
        $archiveStream=[IO.File]::Open($cached,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ((Get-FileHash -InputStream $archiveStream -Algorithm $Entry.algorithm).Hash -ine $expected) {
                throw "Cached dependency checksum mismatch: $cached. No redownload or overwrite attempted; explicitly repair or remove this entry before retrying."
            }
            $archiveStream.Position=0
            $destinationStream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $archiveStream.CopyTo($destinationStream) } finally { $destinationStream.Dispose() }
        } finally { $archiveStream.Dispose() }
        Write-Host "Verified dependency cache $status`: $($Entry.filename)"
        return [pscustomobject]@{path=$path;cache_path=$cached;cache_status=$status;algorithm=$Entry.algorithm;expected_hash=$expected}
    } finally { $guard.Dispose() }
}

function Expand-ComparisonDependency([string]$Archive,[string]$Destination) {
    $prefix=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\'
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $relative=$entry.FullName.Replace('/','\')
            $resolved=[IO.Path]::GetFullPath((Join-Path $Destination $relative))
            if ([IO.Path]::IsPathRooted($relative) -or
                -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Unexpected dependency archive destination path.'
            }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
}

function New-ComparisonBootstrap([string]$SourceRoot,[string]$ConfigPath,[string]$WorkParent) {
    Assert-ComparisonSourceTree $SourceRoot
    $config=Read-ComparisonConfig $ConfigPath
    $opencvRepository=Resolve-ComparisonOpenCvRepository $config
    $parent=Assert-LocalStudyPath $WorkParent $SourceRoot
    $null=Resolve-ComparisonCacheRoot $config $SourceRoot
    $tools=Find-HandoffToolchain
    $platform=Get-NativeBuildPlatform $tools.architecture
    $profile=Get-Content -LiteralPath (Join-Path $SourceRoot 'profile.json') -Raw | ConvertFrom-Json
    $profile.opencv.repository=$opencvRepository
    $profile.architecture=$platform.architecture
    $profile.profile_id="opencv5x-windows-$($platform.architecture.ToLowerInvariant())-functional"
    if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($parent)).AvailableFreeSpace -lt $profile.minimum_free_disk_gib*1GB) {
        throw 'Insufficient disk headroom for clean-checkout bootstrap.'
    }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $guard=[IO.File]::Open((Join-Path $parent 'comparison.lock'),
        [IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $root=Join-Path $parent ('bootstrap-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $record=[ordered]@{
        started_at=(Get-Date).ToString('o');status='preparing';root=$root
        architecture=$platform.architecture;installed_tools=$tools
        source_root=$SourceRoot;config_sha256=$null;payload_manifest_sha256=$null;cache_root=$null
        downloads=@();current_operation='copy_sources';workloads_executed=$false;system_installation_changed=$false
    }
    $oldPrompt=$env:GIT_TERMINAL_PROMPT
    try {
        New-Item -ItemType Directory -Path $root | Out-Null
        Write-Host "Clean-checkout bootstrap: $root"
        $folder=Join-Path $root 'comparison'
        $payload=Join-Path $folder 'payload'
        $downloads=Join-Path $root 'downloads'
        foreach ($directory in @($folder,$payload,$downloads,(Join-Path $payload 'sources'),
                (Join-Path $payload 'runtime'),(Join-Path $payload 'inputs\numpy'),
                (Join-Path $payload 'inputs\yaml'),(Join-Path $payload 'licenses'))) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        foreach ($name in @('Run-Comparison.ps1','ComparisonSupport.psm1')) {
            Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination (Join-Path $folder $name)
        }
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $folder 'comparison.json')
        $config=Read-ComparisonConfig (Join-Path $folder 'comparison.json')
        $cacheRoot=Resolve-ComparisonCacheRoot $config $SourceRoot
        $record.cache_root=$cacheRoot
        $record.config_sha256=(Get-FileHash -LiteralPath (Join-Path $folder 'comparison.json')).Hash
        Copy-Item -LiteralPath (Join-Path $SourceRoot 'COMPARISON.md') -Destination (Join-Path $folder 'README.md')
        foreach ($name in @('Start-Study.ps1','HandoffSupport.psm1','source-manifest.json')) {
            Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination (Join-Path $payload $name)
        }
        Write-ComparisonJson $profile (Join-Path $payload 'profile.json')
        Copy-Item -LiteralPath (Join-Path $SourceRoot $platform.workload_file) -Destination (Join-Path $payload 'expected-workload.json')
        foreach ($name in Get-ComparisonSourceFiles) {
            $target=Join-Path $payload "scripts\msbuild\$name"
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $SourceRoot "scripts\msbuild\$name") -Destination $target
        }
        Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\Get-HostSnapshot.ps1') -Destination (Join-Path $payload 'scripts\Get-HostSnapshot.ps1')
        Assert-ComparisonRuntimeSources $payload
        $sourceLock=Get-Content -LiteralPath (Join-Path $SourceRoot 'bootstrap-lock.json') -Raw | ConvertFrom-Json
        $lock=Get-ComparisonDependencyLock $sourceLock $platform.architecture
        Write-ComparisonJson $lock (Join-Path $payload 'bootstrap-lock.json')
        $archives=@{}
        $unpacked=Join-Path $root 'unpacked'
        $pipPython=$null
        Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
        foreach ($name in @('cmake','python','numpy','yaml')) {
            $record.current_operation="acquire_$name"
            Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
            $dependency=Receive-ComparisonDependency $lock.$name $downloads $cacheRoot $pipPython
            $archives[$name]=$dependency.path
            $usesPip=$lock.$name.PSObject.Properties['source'] -and $lock.$name.source -ceq 'pip'
            $record.downloads+=@{
                name=$name;source=$(if ($usesPip) { 'pip-configuration' } else { 'locked-url' })
                url=$(if ($usesPip) { $null } else { $lock.$name.url })
                sha256=(Get-FileHash -LiteralPath $archives[$name]).Hash
                cache_status=$dependency.cache_status;cache_path=$dependency.cache_path
                algorithm=$dependency.algorithm;expected_hash=$dependency.expected_hash
            }
            Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
            if ($name -eq 'python') {
                $record.current_operation='prepare_pip'
                Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
                Expand-ComparisonDependency $archives.python (Join-Path $unpacked 'python')
                $pipPython=Join-Path $unpacked 'python\tools\python.exe'
            }
        }
        $record.current_operation='extract_dependencies'
        Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
        foreach ($name in @('cmake','numpy','yaml')) {
            Expand-ComparisonDependency $archives[$name] (Join-Path $unpacked $name)
        }
        Move-Item -LiteralPath (Join-Path $unpacked "cmake\$([IO.Path]::GetFileNameWithoutExtension($lock.cmake.filename))") -Destination (Join-Path $payload 'runtime\cmake')
        Copy-Item -LiteralPath $archives.python -Destination (Join-Path $payload "inputs\$($lock.python.filename)")
        Copy-Item -LiteralPath (Join-Path $unpacked 'python\tools\LICENSE.txt') -Destination (Join-Path $payload 'licenses\Python-LICENSE.txt')
        Copy-Item -LiteralPath (Join-Path $unpacked 'numpy\numpy\_core\include') -Destination (Join-Path $payload 'inputs\numpy\include') -Recurse
        Copy-Item -LiteralPath (Join-Path $unpacked 'numpy\numpy-2.4.2.dist-info\licenses\LICENSE.txt') -Destination (Join-Path $payload 'licenses\numpy-LICENSE.txt')
        $yamlRoot=Join-Path $payload 'inputs\yaml\yaml'
        New-Item -ItemType Directory -Path $yamlRoot | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $unpacked 'yaml\yaml') -Filter '*.py' -File |
            Copy-Item -Destination $yamlRoot
        Copy-Item -LiteralPath (Join-Path $unpacked 'yaml\pyyaml-6.0.3.dist-info\licenses\LICENSE') -Destination (Join-Path $payload 'licenses\PyYAML-LICENSE.txt')
        if (-not (Test-Path -LiteralPath (Join-Path $yamlRoot '__init__.py') -PathType Leaf)) {
            throw 'The downloaded pure-Python YAML input is incomplete.'
        }
        $include=Join-Path $payload 'inputs\numpy\include'
        $headers=@(Get-ChildItem -LiteralPath $include -Recurse -File | Sort-Object FullName | ForEach-Object {
            @{path=[IO.Path]::GetRelativePath($include,$_.FullName).Replace('\','/');bytes=$_.Length;
                sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
        })
        if (-not $headers.Count -or @(Get-ChildItem -LiteralPath $include -Recurse -File |
                Where-Object Extension -NotIn @('.h','.c','.txt')).Count) {
            throw 'Unexpected NumPy include-only input.'
        }
        Write-ComparisonJson @{
            version=$profile.numpy_header_version
            wheel_metadata=(Get-Content -LiteralPath (Join-Path $unpacked 'numpy\numpy-2.4.2.dist-info\WHEEL') -Raw).TrimEnd()
            files=$headers
        } (Join-Path $payload 'inputs\numpy\origin.json')
        Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $payload 'scripts\msbuild\BoundedProcess.cs') -Raw)
        $env:GIT_TERMINAL_PROMPT='0'
        $record.current_operation='fetch_opencv'
        Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
        New-ComparisonOpenCvSource $config $profile $payload $root
        @('Run-Comparison.ps1','ComparisonSupport.psm1') | ForEach-Object {
            @{name=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $folder $_)).Hash}
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'comparison-launchers.json') -Encoding utf8
        Write-ComparisonJson @{
            schema_version=1;package_kind='local-functional-handoff';created_at=(Get-Date).ToString('o')
            profile_id=$profile.profile_id;comparison_axis=$profile.comparison_axis
            architecture=$platform.architecture
            review_commit=$profile.ci_dev.commit;opencv_commit=$profile.opencv.commit
            lab_permission_granted=$false;lab_platform_integration_validated=$false;performance_eligible=$false
            files=@(Get-PackageInventory $payload)
        } (Join-Path $payload 'package-manifest.json')
        $record.current_operation='fetch_selected_commits'
        Write-ComparisonJson $record (Join-Path $root 'bootstrap.json')
        $null=New-ComparisonSources $config $payload $root -WithoutSeed
        $manifest=Assert-HandoffPackage $payload
        Assert-HandoffProfile (Get-Content -LiteralPath (Join-Path $payload 'profile.json') -Raw | ConvertFrom-Json) $manifest
        $record.payload_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $payload 'package-manifest.json')).Hash
        $record.status='bootstrap_ready'
        $record.current_operation='complete'
    } catch {
        $record.status='failed'
        $record.error=$_.Exception.Message
        throw
    } finally {
        $env:GIT_TERMINAL_PROMPT=$oldPrompt
        $guard.Dispose()
        if ($record.status -eq 'preparing') {
            $record.status='interrupted'
            $record.error="Bootstrap interrupted during $($record.current_operation); preparation did not complete."
        }
        $record.finished_at=(Get-Date).ToString('o')
        if (Test-Path -LiteralPath $root) {
            $receipt=Join-Path $root 'bootstrap.json'
            Write-ComparisonJson $record $receipt
            Write-Host "Bootstrap status: $($record.status). Operation: $($record.current_operation). Receipt: $receipt"
        }
    }
    return $folder
}

Export-ModuleMember -Function Assert-ComparisonSourceTree,Resolve-ComparisonCacheRoot,New-ComparisonBootstrap,Get-ComparisonDependencyLock
