Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:comparisonStage='[Sources] Git'
$script:gitSequence=0

function Invoke-ComparisonStage([string]$Stage,[scriptblock]$Action,[string]$LogPath) {
    $previous=$script:comparisonStage
    $script:comparisonStage=$Stage
    $clock=[Diagnostics.Stopwatch]::StartNew()
    Write-Host "$Stage ..."
    try {
        $value=& $Action
        Write-Host ("{0} ... OK ({1:n1}s)" -f $Stage,$clock.Elapsed.TotalSeconds)
        if ($null -ne $value) { return $value }
    } catch {
        Write-Host "$Stage ... FAILED. Log: $LogPath"
        throw
    } finally { $script:comparisonStage=$previous }
}

function Write-ComparisonHeartbeat([string]$Stage,[string]$LogPath,[double]$Elapsed,$State) {
    if ($Elapsed -lt $State.next) { return }
    Write-Host ("{0}: still running ({1:n0}s). Log: {2}" -f $Stage,$Elapsed,$LogPath)
    $State.next=$Elapsed+120
}

function Write-ComparisonJson($Value,[string]$Path) {
    ConvertTo-Json -InputObject $Value -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Read-ComparisonConfig([string]$Path,[string]$WorkParent,[string]$CacheRoot,
        [ValidateSet('https','ssh')][string]$SourceTransport='https') {
    $selections=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -NoEnumerate
    if ($selections -isnot [array] -or $selections.Count -lt 1 -or $selections.Count -gt 8) {
        throw 'comparison.json must be a JSON array containing one to eight source-selection objects.'
    }
    $required=@('opencv-repo','opencv-branch','opencv-commit','ci-gha-repo','ci-gha-branch','ci-gha-commit')
    $labels=@{}
    for ($index=0; $index -lt $selections.Count; $index++) {
        $entry=$selections[$index]
        if ($entry -isnot [pscustomobject] -or
            @($required | Where-Object {$_ -cnotin $entry.PSObject.Properties.Name}).Count -or
            @($entry.PSObject.Properties.Name | Where-Object {$_ -cnotin ($required+@('label'))}).Count) {
            throw 'Each case requires opencv-repo/branch/commit and ci-gha-repo/branch/commit; only label is optional.'
        }
        foreach ($prefix in @('opencv','ci-gha')) {
            $repository=$entry."$prefix-repo"
            $branch=$entry."$prefix-branch"
            $commit=$entry."$prefix-commit"
            if ($repository -isnot [string] -or $repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
                throw "$prefix-repo must be an owner/name repository, not a URL or credential."
            }
            if ($branch -isnot [string] -or $branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
                throw "$prefix-branch must be an explicit Git branch name."
            }
            & git check-ref-format "refs/heads/$branch"
            if ($LASTEXITCODE) { throw "Invalid Git branch: $branch" }
            if ($commit -isnot [string] -or $commit -cnotmatch '^[0-9a-f]{40}$') {
                throw "$prefix-commit must be a full lowercase 40-character commit SHA."
            }
        }
        if (-not $entry.PSObject.Properties['label']) {
            $entry | Add-Member -NotePropertyName label -NotePropertyValue "case-$($index+1)"
        }
        if ($entry.label -isnot [string] -or $entry.label -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or
            $labels.ContainsKey($entry.label)) {
            throw 'Each case label must be unique and contain only letters, digits, underscores or hyphens.'
        }
        $labels[$entry.label]=$true
    }
    foreach ($pathValue in @($WorkParent,$CacheRoot)) {
        if ($pathValue -and $pathValue -notmatch '^[A-Za-z]:\\') {
            throw 'WorkParent and CacheRoot must be absolute local drive paths.'
        }
    }
    return [pscustomobject]@{
        cases=$selections;work_parent=$WorkParent;cache_root=$CacheRoot;source_transport=$SourceTransport
    }
}

function Resolve-ComparisonWorkParent($Config,[string]$SourceRoot) {
    $path=if ($Config.work_parent) {
        $Config.work_parent
    } else {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; pass -WorkParent with an explicit local directory.'
        }
        Join-Path $env:LOCALAPPDATA 'opencv-build-test\runs'
    }
    return Assert-LocalStudyPath $path $SourceRoot
}

function Resolve-ComparisonCacheRoot($Config,[string]$SourceRoot) {
    $path=if ($Config.PSObject.Properties['cache_root'] -and $Config.cache_root) {
        $Config.cache_root
    } else {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; pass -CacheRoot with an explicit local directory.'
        }
        Join-Path $env:LOCALAPPDATA 'opencv-build-test\cache'
    }
    return Assert-LocalStudyPath $path $SourceRoot
}

function Invoke-ComparisonScript([string]$Path,[string[]]$Arguments,[string]$Stage,[string]$LogPath) {
    if (-not $Stage -and -not $LogPath) {
        & ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -File $Path @Arguments
        if ($LASTEXITCODE) { throw "Script failed ($LASTEXITCODE): $Path" }
        return
    }
    if (-not $Stage -or -not $LogPath) { throw 'Observed scripts require both a stage name and a log path.' }
    Invoke-ComparisonStage $Stage {
        $state=@{next=60}
        $progress=[Action[double]]{
            param($Elapsed)
            Write-ComparisonHeartbeat $Stage $LogPath $Elapsed $state
        }
        $result=[OpenCvBoundedProcess]::RunObserved([Environment]::ProcessPath,
            (@('-NoLogo','-NoProfile','-NonInteractive','-File',$Path)+$Arguments),
            (Get-Location).Path,$LogPath,$progress)
        Write-ComparisonJson $result ($LogPath+'.json')
        if ($result.ExitCode -ne 0) { throw "Script failed (exit $($result.ExitCode)): $Stage. Log: $LogPath" }
    } $LogPath
}

function Get-ComparisonGitDiagnostics([string]$LogPath) {
    Get-Content -LiteralPath $LogPath -Tail 8 | ForEach-Object {
        $_ -split "`r"
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 6 | ForEach-Object {
        if ($_.Length -gt 500) { $_.Substring(0,500)+'...' } else { $_ }
    }
}

function Invoke-ComparisonGit([string]$Directory,[string]$LogRoot,[string[]]$Arguments,[int]$TimeoutSeconds=300,
        [int[]]$AllowedExitCodes=@(0)) {
    $script:gitSequence++
    $log=Join-Path $LogRoot ("git-{0:d3}.log" -f $script:gitSequence)
    $stage=$script:comparisonStage
    $state=@{next=60}
    $progress=[Action[double]]{
        param($Elapsed)
        Write-ComparisonHeartbeat $stage $log $Elapsed $state
    }
    $result=[OpenCvBoundedProcess]::RunWithProgress((Get-Command git -CommandType Application | Select-Object -First 1).Source,
        $Arguments,$Directory,$log,$TimeoutSeconds,$progress)
    Write-ComparisonJson $result ($log+'.json')
    if ($result.TimedOut -or $result.ExitCode -notin $AllowedExitCodes) {
        $tail=@(Get-ComparisonGitDiagnostics $log)
        if ($tail.Count) {
            Write-Host "Git diagnostics (last lines; full log: $log):"
            foreach ($line in $tail) { Write-Host "  $line" }
        }
        $failure=if ($result.TimedOut) {
            "Git operation timed out after $TimeoutSeconds seconds (exit $($result.ExitCode))."
        } else { "Git operation failed (exit $($result.ExitCode))." }
        $detail=if ($tail.Count) { "`n"+($tail -join "`n") } else { '' }
        throw "$failure Log: $log$detail"
    }
    return [IO.File]::ReadAllText($log).Trim()
}

function Get-ComparisonGitRevision([string]$Bare,[string]$Revision,[string]$Directory,[string]$LogRoot) {
    $value=Invoke-ComparisonGit $Directory $LogRoot @("--git-dir=$Bare",'rev-parse','--verify','--quiet',"$Revision~0") `
        -AllowedExitCodes @(0,1)
    if ($value -and $value -cnotmatch '^[0-9a-f]{40}$') {
        throw "Unexpected cached Git revision response: $value"
    }
    return $value
}

function Get-ComparisonCachedGitSource(
        [string]$Repository,[string]$BranchName,[string]$Commit,[string]$CacheRoot,
        [ValidateSet('https','ssh')][string]$SourceTransport='https',
        [string]$Destination,[string]$Reference,[string]$LogRoot,[int]$TimeoutSeconds=1800,
        [switch]$SkipIntegrityChecks) {
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        @($Repository.Split('/') | Where-Object { $_ -in @('.','..') }).Count) {
        throw 'A Git source cache requires an owner/name repository.'
    }
    if ($BranchName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
        ($Commit -and $Commit -cnotmatch '^[0-9a-f]{40}$')) {
        throw 'A Git source cache requires an explicit branch and an optional full lowercase commit SHA.'
    }
    $cache=Assert-LocalStudyPath $CacheRoot $PSScriptRoot
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Repository.ToLowerInvariant()))).ToLowerInvariant()
    $bare=Assert-LocalStudyPath (Join-Path $cache "git\$key.git") $PSScriptRoot
    $lockPath=Assert-LocalStudyPath ($bare+'.lock') $PSScriptRoot
    New-Item -ItemType Directory -Path (Split-Path $bare) -Force | Out-Null
    try {
        $guard=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -notin @(32,33)) { throw }
        throw "Git source cache is in use: $bare. Retry after its current owner finishes."
    }
    try {
        $directory=Split-Path $Destination
        $null=Invoke-ComparisonGit $directory $LogRoot @('check-ref-format',"refs/heads/$BranchName")
        $null=Invoke-ComparisonGit $directory $LogRoot @('check-ref-format',$Reference)
        $https="https://github.com/$Repository.git"
        $ssh="git@github.com:$Repository.git"
        $url=if ($SourceTransport -eq 'ssh') { $ssh } else { $https }
        if (-not (Test-Path -LiteralPath $bare)) {
            $partial=$bare+'.partial-'+[guid]::NewGuid().ToString('N')
            $null=Invoke-ComparisonGit $directory $LogRoot @('init','--bare','--quiet',$partial)
            $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$partial",'remote','add','origin',$url)
            Move-Item -LiteralPath $partial -Destination $bare
        }
        $origin=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'config','--get','remote.origin.url')
        if ($origin -notin @($https,$ssh)) { throw "Git source cache origin differs: $bare. Expected $Repository." }
        $isBare=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'rev-parse','--is-bare-repository')
        $isShallow=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'rev-parse','--is-shallow-repository')
        if ($isBare -cne 'true' -or $isShallow -cne 'false' -or
            (Test-Path -LiteralPath (Join-Path $bare 'objects\info\alternates'))) {
            throw "Git source cache must be a complete independent bare repository: $bare"
        }
        if (-not $SkipIntegrityChecks) {
            $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'fsck','--full','--no-dangling') $TimeoutSeconds
        }
        # Encode branch names so Windows filename rules and case folding cannot alias refs.
        $branchKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($BranchName))).ToLowerInvariant()
        $branchRef="refs/cache/branches/$branchKey"
        $head=Get-ComparisonGitRevision $bare $branchRef $directory $LogRoot
        $selected=if ($Commit) { Get-ComparisonGitRevision $bare $Commit $directory $LogRoot } else { $head }
        $status='hit'
        if (-not $head -or -not $selected) {
            $status='fetched'
            Write-Host "[Sources] Cache miss: $Repository ($BranchName); fetching missing source."
            $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'fetch','--progress',
                '--atomic','--no-tags','--no-auto-maintenance',$url,"+refs/heads/$($BranchName):$branchRef") $TimeoutSeconds
            $head=Get-ComparisonGitRevision $bare $branchRef $directory $LogRoot
            if (-not $head) { throw "Fetched branch is absent from the source cache: $Repository/$BranchName" }
            $selected=if ($Commit) { Get-ComparisonGitRevision $bare $Commit $directory $LogRoot } else { $head }
            if (-not $selected -and $Commit) {
                $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'fetch','--progress',
                    '--no-tags','--no-auto-maintenance',$url,$Commit) $TimeoutSeconds
                $selected=Get-ComparisonGitRevision $bare $Commit $directory $LogRoot
            }
        } else {
            Write-Host "[Sources] Cache hit: $Repository@$($selected.Substring(0,8)); no network fetch."
        }
        if (-not $selected -or ($Commit -and $selected -cne $Commit)) {
            throw "The selected SHA does not identify the requested commit: $Repository@$Commit"
        }
        $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'update-ref',"refs/cache/commits/$selected",$selected)
        if ($status -eq 'fetched' -and -not $SkipIntegrityChecks) {
            $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$bare",'fsck','--full','--no-dangling',$selected) $TimeoutSeconds
        }
        $fsckObjects=([bool](-not $SkipIntegrityChecks)).ToString().ToLowerInvariant()
        $null=Invoke-ComparisonGit $directory $LogRoot @("--git-dir=$Destination",'-c',"fetch.fsckObjects=$fsckObjects",
            'fetch','--quiet','--no-tags','--no-auto-maintenance',$bare,"+$($selected):$Reference") $TimeoutSeconds
        return [pscustomobject]@{
            repository=$Repository;branch_name=$BranchName;commit=$selected
            branch_head_at_check=$head;cache_path=$bare;cache_status=$status
        }
    } finally { $guard.Dispose() }
}

function New-ComparisonSources($Config,[string]$Package,[string]$RunRoot,[switch]$WithoutSeed,
        [switch]$SkipIntegrityChecks) {
    $script:gitSequence=0
    $logs=Join-Path $RunRoot 'source-logs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    $cacheRoot=Resolve-ComparisonCacheRoot $Config $PSScriptRoot
    $cacheRecords=[Collections.Generic.List[object]]::new()
    $entries=@($Config.cases | ForEach-Object { [ordered]@{label=$_.label;opencv=$null;ci=$null} })
    foreach ($kind in @('opencv','ci')) {
        $prefix=if ($kind -eq 'ci') {'ci-gha'} else {'opencv'}
        $timeout=if ($kind -eq 'opencv') {1800} else {300}
        $name=if ($kind -eq 'ci') {'CI'} else {'OpenCV'}
        $bare=Join-Path $RunRoot "$kind-cache.git"
        $bundle=Join-Path $Package "sources\$kind.bundle"
        Invoke-ComparisonStage "[Sources] Prepare $name source cache" {
            $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$bare)
            if ($WithoutSeed) {
                if (Test-Path -LiteralPath $bundle) { throw 'Seed-free bootstrap must not replace an existing source bundle.' }
            } else {
                $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'fetch','--quiet',$bundle,
                    'refs/heads/*:refs/remotes/seed/*') $timeout
            }
        } $logs
        $refs=@()
        $resolved=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        for ($index=0; $index -lt $Config.cases.Count; $index++) {
            $selection=$Config.cases[$index]
            $repository=$selection."$prefix-repo"
            $branchName=$selection."$prefix-branch"
            $commit=$selection."$prefix-commit"
            $ref="refs/heads/comparison-$($index+1)"
            $stage="[Sources] $($selection.label): fetch and verify $name $repository@$($commit.Substring(0,8))"
            $entries[$index][$kind]=Invoke-ComparisonStage $stage {
                $key="$repository|$branchName|$commit"
                if (-not $resolved.ContainsKey($key)) {
                    $source=Get-ComparisonCachedGitSource -Repository $repository -BranchName $branchName `
                        -Commit $commit -CacheRoot $cacheRoot -SourceTransport $Config.source_transport `
                        -Destination $bare -Reference $ref -LogRoot $logs -TimeoutSeconds $timeout `
                        -SkipIntegrityChecks:$SkipIntegrityChecks
                    $resolved[$key]=$source
                    $cacheRecords.Add($source)
                    Write-ComparisonJson @($cacheRecords.ToArray()) (Join-Path $RunRoot 'source-cache.json')
                }
                $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'update-ref',$ref,$commit)
                [ordered]@{
                    repository=$repository;branch_name=$branchName;commit=$commit
                    bundle="sources/$kind.bundle";bundle_ref=$ref
                    branch_head_at_check=$resolved[$key].branch_head_at_check
                }
            } $logs
            $refs+=$ref
        }
        $newBundle=Join-Path $RunRoot "selected-$kind.bundle"
        $bundleAction=if ($SkipIntegrityChecks) { 'Bundle' } else { 'Bundle and verify' }
        Invoke-ComparisonStage "[Sources] $bundleAction $name for $($Config.cases.label -join '/')" {
            $null=Invoke-ComparisonGit $RunRoot $logs (@("--git-dir=$bare",'bundle','create','--version=2',$newBundle)+$refs) $timeout
            if (-not $SkipIntegrityChecks) {
                $empty=Join-Path $RunRoot "$kind-bundle-verify.git"
                $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$empty)
                $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$empty",'bundle','verify',$newBundle) $timeout
            }
            Copy-Item -LiteralPath $newBundle -Destination $bundle
        } $logs
    }
    Write-ComparisonJson ([ordered]@{
        selected=$entries
        branch_is_provenance_not_a_floating_execution_target=$true
        branch_heads_are_cached_snapshots_not_live_checks=$true
    }) (Join-Path $Package 'sources\provenance.json')
    $packageAction=if ($SkipIntegrityChecks) { 'Record selected source package' } else { 'Verify selected source package' }
    Invoke-ComparisonStage "[Sources] $packageAction" {
        Set-ComparisonCaseProfile $Package $entries[0] -SkipIntegrityChecks:$SkipIntegrityChecks
    } $logs
    return $entries
}

function Set-ComparisonCaseProfile([string]$Package,$Selection,[switch]$SkipIntegrityChecks) {
    $profile=Get-Content -LiteralPath (Join-Path $Package 'profile.json') -Raw | ConvertFrom-Json
    $profile.opencv=$Selection.opencv
    $profile.ci_baseline=$Selection.ci
    $profile.PSObject.Properties.Remove('ci_dev')
    $profile.profile_id='configured-source-case'
    $profile.comparison_axis='independent_sources'
    $profile.conditions=@('baseline')
    Write-ComparisonJson $profile (Join-Path $Package 'profile.json')
    $manifestPath=Join-Path $Package 'package-manifest.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.profile_id=$profile.profile_id
    $manifest.comparison_axis=$profile.comparison_axis
    $manifest.review_commit=$profile.ci_baseline.commit
    $manifest.opencv_commit=$profile.opencv.commit
    $manifest.created_at=(Get-Date).ToString('o')
    $manifest.files=@(Get-PackageInventory $Package)
    Write-ComparisonJson $manifest $manifestPath
    $null=Assert-HandoffPackage $Package -SkipIntegrityChecks:$SkipIntegrityChecks
    Assert-HandoffProfile $profile $manifest
}

function New-ComparisonCasePackage([string]$Package,$Selection,[string]$Destination,[switch]$SkipIntegrityChecks) {
    if (Test-Path -LiteralPath $Destination) { throw 'Preserve the existing case package.' }
    Copy-Item -LiteralPath $Package -Destination $Destination -Recurse
    $null=Assert-HandoffPackage $Destination -SkipIntegrityChecks:$SkipIntegrityChecks
    Set-ComparisonCaseProfile $Destination $Selection -SkipIntegrityChecks:$SkipIntegrityChecks
}

function Write-ComparisonResults([string]$SummaryPath,$Cases) {
    $summary=Get-Content -LiteralPath $SummaryPath -Raw | ConvertFrom-Json
    if ($summary.status -cne 'configured_comparison_passed' -or
        $summary.conditions.Count -ne @($Cases).Count) {
        throw "Cannot print results before all cases are verified: $SummaryPath"
    }
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $rows=[Collections.Generic.List[string[]]]::new()
    $rows.Add(@('Case','OpenCV','Builder','Build (s)','Pre-build CPU samples (%)','PreBld CPU mean (%)','C++','Binding DLL'))
    foreach ($condition in $summary.conditions) {
        $case=@($Cases | Where-Object label -CEQ $condition.label)
        if ($case.Count -ne 1) { throw "Cannot locate unique results for case: $($condition.label)" }
        $executionPath=Join-Path $case[0].export 'execution.json'
        $execution=Get-Content -LiteralPath $executionPath -Raw | ConvertFrom-Json
        if ($execution.status -cne 'functional_build_passed' -or
            $execution.protocol_sha256 -cne $condition.protocol_sha256) {
            throw "Execution does not match verified results: $executionPath"
        }
        $samples=@($execution.preflight.cpu_samples_percent | ForEach-Object {
            ([double]$_).ToString('G',$culture)
        })
        $count=$condition.selected_cpp_checks_passed
        $rows.Add(@(
            $condition.label,
            $condition.repositories[1].actual_commit_sha.Substring(0,7),
            $condition.repositories[0].actual_commit_sha.Substring(0,7),
            ([double]$condition.native_wall_seconds).ToString('F2',$culture),
            ($samples -join ', '),
            ([double]$execution.preflight.cpu_mean_percent).ToString('F1',$culture),
            "$count/$count",
            $(if ($condition.raw_binding_dll_load_passed) {'PASS'} else {'FAIL'})
        ))
    }
    $widths=@(for ($column=0; $column -lt $rows[0].Count; $column++) {
        ($rows | ForEach-Object { $_[$column].Length } | Measure-Object -Maximum).Maximum
    })
    Write-Host ''
    foreach ($row in $rows) {
        $cells=for ($column=0; $column -lt $row.Count; $column++) {
            if ($column -in @(3,5,6)) { $row[$column].PadLeft($widths[$column]) }
            else { $row[$column].PadRight($widths[$column]) }
        }
        Write-Host (($cells -join '  ').TrimEnd())
    }
    Write-Host ''
    Write-Host 'Commits are abbreviated. Each case was built once; timings are diagnostic only.'
    Write-Host 'CPU samples and means describe whole-machine usage before each build, not during it.'
}

function Invoke-ComparisonCases($Cases,[string]$Scripts,$Record,[string]$SummaryPath) {
    $consumed=[double]$Record.consumed_outer_build_seconds
    foreach ($case in $Cases) {
        if ($consumed+1800 -gt $Record.build_budget_seconds) { throw 'Insufficient reserved native-build budget.' }
        $case.status='running'
        Write-ComparisonJson $Record $SummaryPath
        $failure=$null
        $ordinal=[Array]::IndexOf(@($Record.cases.label),$case.label)+1
        $stage="[$($case.label) $ordinal/$($Record.cases.Count)]"
        $caseRoot=Split-Path $case.export
        try {
            Invoke-ComparisonScript (Join-Path $Scripts 'Invoke-CiPilot.ps1') @(
                '-Action','Run','-ProtocolPath',$case.protocol,'-Condition',$case.condition) `
                "$stage Build and check correctness" (Join-Path $caseRoot 'build.log')
        } catch { $failure=$_.Exception.Message }
        $protocol=Get-Content -LiteralPath $case.protocol -Raw | ConvertFrom-Json
        $executionPath=Join-Path $protocol.output_root "$($case.condition)\execution.json"
        if (Test-Path -LiteralPath $executionPath) {
            $execution=Get-Content -LiteralPath $executionPath -Raw | ConvertFrom-Json
            $case.execution_status=$execution.status
            if ($execution.PSObject.Properties['build']) { $consumed+=$execution.build.OuterWallSeconds }
            try {
                Invoke-ComparisonScript (Join-Path $Scripts 'Export-CiFunctionalResults.ps1') @(
                    '-ProtocolPath',$case.protocol,'-Condition',$case.condition,'-Destination',$case.export) `
                    "$stage Archive results" (Join-Path $caseRoot 'export.log')
            } catch {
                $case.export_error=$_.Exception.Message
                if (-not $failure) { $failure=$_.Exception.Message }
            }
            if ($execution.status -ne 'functional_build_passed' -and -not $failure) {
                $failure='Native execution did not pass.'
            }
        } elseif (-not $failure) { $failure='Execution receipt is absent.' }
        $case.status=if($failure){'failed'}else{'passed'}
        $Record.consumed_outer_build_seconds=$consumed
        Write-ComparisonJson $Record $SummaryPath
        if ($failure) { throw $failure }
    }
}

Export-ModuleMember -Function Read-ComparisonConfig,Write-ComparisonJson,Invoke-ComparisonScript,
    New-ComparisonSources,New-ComparisonCasePackage,Invoke-ComparisonCases,Resolve-ComparisonWorkParent,Invoke-ComparisonStage,
    Write-ComparisonResults,Resolve-ComparisonCacheRoot,Get-ComparisonCachedGitSource
