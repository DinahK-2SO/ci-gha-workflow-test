Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

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

function Invoke-ComparisonScript([string]$Path,[string[]]$Arguments) {
    & ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -File $Path @Arguments
    if ($LASTEXITCODE) { throw "Script failed ($LASTEXITCODE): $Path" }
}

function Invoke-ComparisonGit([string]$Directory,[string]$LogRoot,[string[]]$Arguments,[int]$TimeoutSeconds=300) {
    $script:gitSequence++
    $log=Join-Path $LogRoot ("git-{0:d3}.log" -f $script:gitSequence)
    Write-Host "Git operation started (deadline: $TimeoutSeconds seconds). Log: $log"
    $progress=[Action[double]]{
        param($Elapsed)
        Write-Host ("Git still running: {0:n0}/{1} seconds. Log: {2}" -f $Elapsed,$TimeoutSeconds,$log)
    }
    $result=[OpenCvBoundedProcess]::RunWithProgress((Get-Command git -CommandType Application | Select-Object -First 1).Source,
        $Arguments,$Directory,$log,$TimeoutSeconds,$progress)
    Write-ComparisonJson $result ($log+'.json')
    if ($result.TimedOut) { throw "Git operation timed out after $TimeoutSeconds seconds (exit $($result.ExitCode)). Log: $log" }
    if ($result.ExitCode -ne 0) { throw "Git operation failed (exit $($result.ExitCode)). Log: $log" }
    return [IO.File]::ReadAllText($log).Trim()
}

function New-ComparisonSources($Config,[string]$Package,[string]$RunRoot,[switch]$WithoutSeed) {
    $script:gitSequence=0
    $logs=Join-Path $RunRoot 'source-logs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    $entries=@($Config.cases | ForEach-Object { [ordered]@{label=$_.label;opencv=$null;ci=$null} })
    foreach ($kind in @('opencv','ci')) {
        $prefix=if ($kind -eq 'ci') {'ci-gha'} else {'opencv'}
        $timeout=if ($kind -eq 'opencv') {1800} else {300}
        $bare=Join-Path $RunRoot "$kind-cache.git"
        $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$bare)
        $bundle=Join-Path $Package "sources\$kind.bundle"
        if ($WithoutSeed) {
            if (Test-Path -LiteralPath $bundle) { throw 'Seed-free bootstrap must not replace an existing source bundle.' }
        } else {
            $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'fetch','--quiet',$bundle,
                'refs/heads/*:refs/remotes/seed/*') $timeout
        }
        $refs=@()
        $branches=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $fetched=[Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
        for ($index=0; $index -lt $Config.cases.Count; $index++) {
            $selection=$Config.cases[$index]
            $repository=$selection."$prefix-repo"
            $branchName=$selection."$prefix-branch"
            $commit=$selection."$prefix-commit"
            $url=if($Config.source_transport -eq 'ssh'){"git@github.com:$repository.git"}else{"https://github.com/$repository.git"}
            $branchKey="$repository|$branchName"
            if (-not $branches.ContainsKey($branchKey)) {
                $branch=Invoke-ComparisonGit $RunRoot $logs @('ls-remote','--exit-code',$url,"refs/heads/$branchName")
                if ($branch -cnotmatch ('^([0-9a-f]{40})\s+'+[regex]::Escape("refs/heads/$branchName")+'$')) {
                    throw 'Unexpected remote branch response.'
                }
                $branches[$branchKey]=$Matches[1]
            }
            $fetchKey="$repository|$commit"
            if (-not $fetched.ContainsKey($fetchKey)) {
                $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'fetch','--progress','--no-tags',$url,$commit) $timeout
                $type=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'cat-file','-t',$commit)
                if ($type -cne 'commit') { throw 'The selected SHA does not identify a commit.' }
                $fetched[$fetchKey]=$true
            }
            $ref="refs/heads/comparison-$($index+1)"
            $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'update-ref',$ref,$commit)
            $refs+=$ref
            $entries[$index][$kind]=[ordered]@{
                repository=$repository;branch_name=$branchName;commit=$commit
                bundle="sources/$kind.bundle";bundle_ref=$ref
                branch_head_at_check=$branches[$branchKey]
            }
        }
        $newBundle=Join-Path $RunRoot "selected-$kind.bundle"
        $null=Invoke-ComparisonGit $RunRoot $logs (@("--git-dir=$bare",'bundle','create','--version=2',$newBundle)+$refs) $timeout
        $empty=Join-Path $RunRoot "$kind-bundle-verify.git"
        $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$empty)
        $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$empty",'bundle','verify',$newBundle) $timeout
        Copy-Item -LiteralPath $newBundle -Destination $bundle
    }
    Write-ComparisonJson ([ordered]@{
        selected=$entries
        branch_is_provenance_not_a_floating_execution_target=$true
    }) (Join-Path $Package 'sources\provenance.json')
    Set-ComparisonCaseProfile $Package $entries[0]
    return $entries
}

function Set-ComparisonCaseProfile([string]$Package,$Selection) {
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
    $null=Assert-HandoffPackage $Package
    Assert-HandoffProfile $profile $manifest
}

function New-ComparisonCasePackage([string]$Package,$Selection,[string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { throw 'Preserve the existing case package.' }
    Copy-Item -LiteralPath $Package -Destination $Destination -Recurse
    $null=Assert-HandoffPackage $Destination
    Set-ComparisonCaseProfile $Destination $Selection
}

function Invoke-ComparisonCases($Cases,[string]$Scripts,$Record,[string]$SummaryPath) {
    $consumed=[double]$Record.consumed_outer_build_seconds
    foreach ($case in $Cases) {
        if ($consumed+1800 -gt $Record.build_budget_seconds) { throw 'Insufficient reserved native-build budget.' }
        $case.status='running'
        Write-ComparisonJson $Record $SummaryPath
        $failure=$null
        try {
            Invoke-ComparisonScript (Join-Path $Scripts 'Invoke-CiPilot.ps1') @(
                '-Action','Run','-ProtocolPath',$case.protocol,'-Condition',$case.condition)
        } catch { $failure=$_.Exception.Message }
        $protocol=Get-Content -LiteralPath $case.protocol -Raw | ConvertFrom-Json
        $executionPath=Join-Path $protocol.output_root "$($case.condition)\execution.json"
        if (Test-Path -LiteralPath $executionPath) {
            $execution=Get-Content -LiteralPath $executionPath -Raw | ConvertFrom-Json
            $case.execution_status=$execution.status
            if ($execution.PSObject.Properties['build']) { $consumed+=$execution.build.OuterWallSeconds }
            try {
                Invoke-ComparisonScript (Join-Path $Scripts 'Export-CiFunctionalResults.ps1') @(
                    '-ProtocolPath',$case.protocol,'-Condition',$case.condition,'-Destination',$case.export)
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
    New-ComparisonSources,New-ComparisonCasePackage,Invoke-ComparisonCases,Resolve-ComparisonWorkParent
