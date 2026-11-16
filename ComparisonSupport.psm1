Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-ComparisonJson($Value,[string]$Path) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Read-ComparisonConfig([string]$Path) {
    $config=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $keys=@('schema_version','repository','branch_name','source_transport','work_parent','commits')
    if (@($config.PSObject.Properties.Name | Where-Object {$_ -notin ($keys+@('cache_root','opencv_repository'))}).Count -or
        @($keys | Where-Object {$_ -notin $config.PSObject.Properties.Name}).Count) {
        throw 'Comparison config has missing or unknown fields.'
    }
    if ($config.schema_version -ne 1 -or
        $config.repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $config.branch_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
        $config.source_transport -cnotin @('https','ssh')) {
        throw 'Invalid schema, repository, branch or source transport.'
    }
    if ($config.PSObject.Properties['opencv_repository'] -and
        ($config.opencv_repository -isnot [string] -or $config.opencv_repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')) {
        throw 'opencv_repository must be an owner/name repository containing the pinned OpenCV commit, not a URL or credential.'
    }
    if ($null -ne $config.work_parent -and
        ($config.work_parent -isnot [string] -or $config.work_parent -notmatch '^[A-Za-z]:\\')) {
        throw 'work_parent must be null (the LOCALAPPDATA default) or a fully qualified local drive path.'
    }
    if ($config.PSObject.Properties['cache_root'] -and $null -ne $config.cache_root -and
        ($config.cache_root -isnot [string] -or $config.cache_root -notmatch '^[A-Za-z]:\\')) {
        throw 'cache_root must be null (the LOCALAPPDATA default) or a fully qualified local drive path.'
    }
    & git check-ref-format "refs/heads/$($config.branch_name)"
    if ($LASTEXITCODE) { throw 'Invalid Git branch name.' }
    $commits=@($config.commits)
    if ($commits.Count -lt 2 -or $commits.Count -gt 8) { throw 'Select two to eight distinct commits.' }
    $labels=@{}
    $ids=@{}
    foreach ($entry in $commits) {
        if ((@($entry.PSObject.Properties.Name | Sort-Object) -join '|') -cne 'commit|label' -or
            $entry.label -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or
            $entry.commit -cnotmatch '^[0-9a-f]{40}$' -or
            $labels.ContainsKey($entry.label) -or $ids.ContainsKey($entry.commit)) {
            throw 'Each selection requires a unique label and a distinct full lowercase commit SHA.'
        }
        $labels[$entry.label]=$true
        $ids[$entry.commit]=$true
    }
    return $config
}

function Resolve-ComparisonWorkParent($Config,[string]$SourceRoot) {
    $path=if ($null -ne $Config.work_parent) {
        $Config.work_parent
    } else {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable; set work_parent to an explicit local directory.'
        }
        Join-Path $env:LOCALAPPDATA 'opencv-build-test\runs'
    }
    return Assert-LocalStudyPath $path $SourceRoot
}

function Resolve-ComparisonOpenCvRepository($Config) {
    if (-not $Config.PSObject.Properties['opencv_repository'] -or
        $Config.opencv_repository -isnot [string] -or
        $Config.opencv_repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Source bootstrap requires opencv_repository in comparison.json; no account-specific repository fallback is used.'
    }
    return $Config.opencv_repository
}

function Invoke-ComparisonScript([string]$Path,[string[]]$Arguments) {
    & ([Environment]::ProcessPath) -NoLogo -NoProfile -NonInteractive -File $Path @Arguments
    if ($LASTEXITCODE) { throw "Script failed ($LASTEXITCODE): $Path" }
}

function Invoke-ComparisonGit([string]$Directory,[string]$LogRoot,[string[]]$Arguments) {
    $script:gitSequence++
    $log=Join-Path $LogRoot ("git-{0:d3}.log" -f $script:gitSequence)
    $result=[OpenCvBoundedProcess]::Run((Get-Command git -CommandType Application | Select-Object -First 1).Source,
        $Arguments,$Directory,$log,300)
    if ($result.TimedOut -or $result.ExitCode -ne 0) { throw "Git operation failed or timed out; see $log" }
    return [IO.File]::ReadAllText($log).Trim()
}

function New-ComparisonOpenCvSource($Config,$Profile,[string]$Package,[string]$RunRoot) {
    $script:gitSequence=0
    $logs=Join-Path $RunRoot 'opencv-source-logs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    $bare=Join-Path $RunRoot 'opencv-cache.git'
    $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$bare)
    $entry=$Profile.opencv
    $url=if($Config.source_transport -eq 'ssh'){"git@github.com:$($entry.repository).git"}else{
        "https://github.com/$($entry.repository).git"}
    $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'fetch','--quiet','--no-tags',$url,$entry.commit)
    $type=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'cat-file','-t',$entry.commit)
    if ($type -cne 'commit') { throw 'The pinned OpenCV SHA does not identify a commit.' }
    $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'update-ref',$entry.bundle_ref,$entry.commit)
    $bundle=Join-Path $Package 'sources\opencv.bundle'
    $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'bundle','create','--version=2',$bundle,$entry.bundle_ref)
    $empty=Join-Path $RunRoot 'opencv-bundle-verify.git'
    $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$empty)
    $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$empty",'bundle','verify',$bundle)
}

function New-ComparisonSources($Config,[string]$Package,[string]$RunRoot,[switch]$WithoutSeed) {
    $script:gitSequence=0
    $logs=Join-Path $RunRoot 'source-logs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    $bare=Join-Path $RunRoot 'ci-cache.git'
    $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$bare)
    $oldProfile=Get-Content -LiteralPath (Join-Path $Package 'profile.json') -Raw | ConvertFrom-Json
    $bundle=Join-Path $Package 'sources\ci.bundle'
    if ($WithoutSeed) {
        if (Test-Path -LiteralPath $bundle) { throw 'Seed-free bootstrap must not replace an existing source bundle.' }
    } else {
        $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'fetch','--quiet',$bundle,
            'refs/heads/*:refs/remotes/seed/*')
    }
    $url=if($Config.source_transport -eq 'ssh'){"git@github.com:$($Config.repository).git"}else{
        "https://github.com/$($Config.repository).git"}
    $branch=Invoke-ComparisonGit $RunRoot $logs @('ls-remote','--exit-code',$url,"refs/heads/$($Config.branch_name)")
    if ($branch -notmatch '^([0-9a-f]{40})\s+refs/heads/') { throw 'Unexpected remote branch response.' }
    $remoteHead=$Matches[1]
    $refs=@()
    $entries=@()
    for ($index=0; $index -lt $Config.commits.Count; $index++) {
        $entry=$Config.commits[$index]
        $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'fetch','--quiet','--no-tags',$url,$entry.commit)
        $type=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'cat-file','-t',$entry.commit)
        if ($type -cne 'commit') { throw 'The selected SHA does not identify a commit.' }
        $ref="refs/heads/comparison-$($index+1)"
        $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$bare",'update-ref',$ref,$entry.commit)
        $refs+=$ref
        $entries+=[ordered]@{
            repository=$Config.repository; branch_name=$Config.branch_name; commit=$entry.commit
            bundle='sources/ci.bundle'; bundle_ref=$ref
        }
    }
    $newBundle=Join-Path $RunRoot 'selected-ci.bundle'
    $null=Invoke-ComparisonGit $RunRoot $logs (@("--git-dir=$bare",'bundle','create','--version=2',$newBundle)+$refs)
    $empty=Join-Path $RunRoot 'bundle-verify.git'
    $null=Invoke-ComparisonGit $RunRoot $logs @('init','--quiet','--bare',$empty)
    $null=Invoke-ComparisonGit $RunRoot $logs @("--git-dir=$empty",'bundle','verify',$newBundle)
    Copy-Item -LiteralPath $newBundle -Destination $bundle
    $oldProfile.ci_baseline=$entries[0]
    $oldProfile.ci_dev=$entries[1]
    $oldProfile.profile_id='configured-commit-comparison'
    Write-ComparisonJson $oldProfile (Join-Path $Package 'profile.json')
    Write-ComparisonJson ([ordered]@{
        repository=$Config.repository; branch_name=$Config.branch_name
        branch_head_at_check=$remoteHead; selected=$entries
        branch_is_provenance_not_a_floating_execution_target=$true
    }) (Join-Path $Package 'sources\provenance.json')
    $manifestPath=Join-Path $Package 'package-manifest.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.profile_id=$oldProfile.profile_id
    $manifest.review_commit=$oldProfile.ci_dev.commit
    $manifest.created_at=(Get-Date).ToString('o')
    $manifest.files=@(Get-PackageInventory $Package)
    Write-ComparisonJson $manifest $manifestPath
    $null=Assert-HandoffPackage $Package
    return $entries
}

function Invoke-ComparisonCases($Cases,[string]$Scripts,$Record,[string]$SummaryPath) {
    $consumed=0.0
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
    New-ComparisonSources,New-ComparisonOpenCvSource,Invoke-ComparisonCases,
    Resolve-ComparisonWorkParent,Resolve-ComparisonOpenCvRepository
