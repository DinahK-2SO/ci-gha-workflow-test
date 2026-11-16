#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$WorkRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $WorkRoot) { throw 'Preserve prior selection fixtures.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$path=Join-Path $WorkRoot 'comparison.json'
$selection=[ordered]@{
    'opencv-repo'='fixture/opencv-a';'opencv-branch'='main';'opencv-commit'=('a'*40)
    'ci-gha-repo'='fixture/ci-a';'ci-gha-branch'='main';'ci-gha-commit'=('b'*40)
}
Write-ComparisonJson @($selection) $path
$single=Read-ComparisonConfig $path
if ($single.cases.Count -ne 1 -or $single.cases[0].label -cne 'case-1') { throw 'Single-case array or automatic label was lost.' }
Write-ComparisonJson $single.cases $path
if ((Get-Content $path -Raw | ConvertFrom-Json -NoEnumerate) -isnot [array]) { throw 'A single frozen case was serialized as an object.' }
[ordered]@{test='single-case-array-and-optional-label';passed=$true}
foreach ($invalid in @(
    @{value=$selection;error='*JSON array*'},
    @{value=@();error='*JSON array*'},
    @{value=@($selection)*9;error='*JSON array*'},
    @{value=@($null);error='*Each case requires*'},
    @{value=@([ordered]@{'opencv-repo'='fixture/opencv-a'});error='*Each case requires*'}
)) {
    Write-ComparisonJson $invalid.value $path
    $rejected=$false
    try { $null=Read-ComparisonConfig $path } catch {
        if ($_.Exception.Message -notlike $invalid.error) { throw }
        $rejected=$true
    }
    if (-not $rejected) { throw 'Invalid configuration shape was accepted.' }
}
foreach ($change in @(
    @{key='opencv-repo';value='https://invalid.example/repo.git';error='*owner/name*'},
    @{key='ci-gha-repo';value=17;error='*owner/name*'},
    @{key='opencv-commit';value='main';error='*40-character*'},
    @{key='ci-gha-commit';value=('A'*40);error='*40-character*'},
    @{key='opencv-branch';value='bad..branch';error='*Invalid Git branch*'},
    @{key='ci-gha-branch';value='-unsafe';error='*explicit Git branch*'}
)) {
    $invalid=$selection | ConvertTo-Json | ConvertFrom-Json
    $invalid.($change.key)=$change.value
    Write-ComparisonJson @($invalid) $path
    $rejected=$false
    try { $null=Read-ComparisonConfig $path } catch {
        if ($_.Exception.Message -notlike $change.error) { throw }
        $rejected=$true
    }
    if (-not $rejected) { throw "Invalid source field was accepted: $($change.key)" }
}
$duplicate=$single.cases[0]
Write-ComparisonJson @($duplicate,$duplicate) $path
$rejected=$false
try { $null=Read-ComparisonConfig $path } catch {
    if ($_.Exception.Message -notlike '*label must be unique*') { throw }
    $rejected=$true
}
if (-not $rejected) { throw 'Duplicate case labels were accepted.' }
[ordered]@{test='invalid-shapes-source-identities-and-labels-rejected';passed=$true}

function Invoke-FixtureGit([string[]]$Arguments) {
    $output=& git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $output" }
    return ($output -join "`n").Trim()
}
$saved=@{}
foreach ($variable in Get-ChildItem Env: | Where-Object Name -Like 'GIT_CONFIG_*') {
    $saved[$variable.Name]=$variable.Value
    [Environment]::SetEnvironmentVariable($variable.Name,$null,'Process')
}
try {
    $ids=@{}
    $number=0
    foreach ($name in @('opencv-a','opencv-b','ci-a','ci-b')) {
        $repo=Join-Path $WorkRoot $name
        $null=Invoke-FixtureGit @('init','--quiet','--initial-branch=main',$repo)
        $name | Set-Content (Join-Path $repo 'marker.txt')
        $null=Invoke-FixtureGit @('-C',$repo,'add','marker.txt')
        $null=Invoke-FixtureGit @('-C',$repo,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
            '-c','commit.gpgsign=false','-c','core.hooksPath=NUL','commit','--quiet','-m','Fixture source')
        $ids[$name]=Invoke-FixtureGit @('-C',$repo,'rev-parse','HEAD')
        $null=Invoke-FixtureGit @('-C',$repo,'branch','alternate')
        $uri=([Uri]($repo+'\')).AbsoluteUri.TrimEnd('/')
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$number","url.$uri.insteadOf",'Process')
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$number","https://github.com/fixture/$name.git",'Process')
        $number++
    }
    $env:GIT_CONFIG_COUNT=[string]$number
    $cases=@(
        [ordered]@{label='first';'opencv-repo'='fixture/opencv-a';'opencv-branch'='main';'opencv-commit'=$ids['opencv-a'];
            'ci-gha-repo'='fixture/ci-a';'ci-gha-branch'='main';'ci-gha-commit'=$ids['ci-a']},
        [ordered]@{label='second';'opencv-repo'='fixture/opencv-b';'opencv-branch'='alternate';'opencv-commit'=$ids['opencv-b'];
            'ci-gha-repo'='fixture/ci-a';'ci-gha-branch'='alternate';'ci-gha-commit'=$ids['ci-a']},
        [ordered]@{label='third';'opencv-repo'='fixture/opencv-a';'opencv-branch'='alternate';'opencv-commit'=$ids['opencv-a'];
            'ci-gha-repo'='fixture/ci-b';'ci-gha-branch'='main';'ci-gha-commit'=$ids['ci-b']}
    )
    Write-ComparisonJson $cases $path
    $config=Read-ComparisonConfig $path
    $package=Join-Path $WorkRoot 'package'
    New-Item -ItemType Directory -Path (Join-Path $package 'sources') | Out-Null
    $profile=Get-Content (Join-Path $SourceRoot 'profile.json') -Raw | ConvertFrom-Json
    Write-ComparisonJson $profile (Join-Path $package 'profile.json')
    Write-ComparisonJson ([ordered]@{
        schema_version=1;package_kind='local-functional-handoff';profile_id=$profile.profile_id
        comparison_axis=$profile.comparison_axis;review_commit=$profile.ci_dev.commit
        opencv_commit=$profile.opencv.commit;created_at=(Get-Date).ToString('o');files=@(Get-PackageInventory $package)
    }) (Join-Path $package 'package-manifest.json')
    Add-Type -TypeDefinition (Get-Content (Join-Path $SourceRoot 'scripts\msbuild\BoundedProcess.cs') -Raw)
    $fetch=Join-Path $WorkRoot 'fetch'
    New-Item -ItemType Directory -Path $fetch | Out-Null
    $entries=@(New-ComparisonSources $config $package $fetch -WithoutSeed)
    for ($index=0; $index -lt $cases.Count; $index++) {
        $destination=Join-Path $WorkRoot "case-$index"
        New-ComparisonCasePackage $package $entries[$index] $destination
        $caseProfile=Get-Content (Join-Path $destination 'profile.json') -Raw | ConvertFrom-Json
        if ($caseProfile.PSObject.Properties['ci_dev'] -or ($caseProfile.conditions -join '|') -cne 'baseline') {
            throw 'An independent case retained an unrelated paired CI checkout.'
        }
        foreach ($kind in @('opencv','ci')) {
            $prefix=if($kind -eq 'ci'){'ci-gha'}else{'opencv'}
            $entry=if($kind -eq 'ci'){$caseProfile.ci_baseline}else{$caseProfile.opencv}
            if ($entry.repository -cne $cases[$index]["$prefix-repo"] -or
                $entry.branch_name -cne $cases[$index]["$prefix-branch"] -or
                $entry.commit -cne $cases[$index]["$prefix-commit"]) { throw 'Case source selections leaked across cases.' }
            $restored=Join-Path $WorkRoot "restored-$index-$kind"
            $null=Invoke-FixtureGit @('clone','--quiet','--single-branch','--branch',$entry.bundle_ref.Substring(11),
                (Join-Path $destination $entry.bundle.Replace('/','\')),$restored)
            if ((Invoke-FixtureGit @('-C',$restored,'rev-parse','HEAD')) -cne $entry.commit -or
                (Get-Content (Join-Path $restored 'marker.txt') -Raw).Trim() -cne $entry.repository.Split('/')[1]) {
                throw 'Restored bundle contains another case source.'
            }
        }
    }
    $seeded=Join-Path $WorkRoot 'seeded-fetch'
    New-Item -ItemType Directory -Path $seeded | Out-Null
    $seededEntries=@(New-ComparisonSources $config $package $seeded)
    if (($seededEntries | ConvertTo-Json -Depth 8 -Compress) -cne ($entries | ConvertTo-Json -Depth 8 -Compress)) {
        throw 'Seed reuse changed the selected identities.'
    }
    [ordered]@{test='independent-repositories-branches-commits-and-seeded-bundles';passed=$true}
} finally {
    foreach ($variable in Get-ChildItem Env: | Where-Object Name -Like 'GIT_CONFIG_*') {
        [Environment]::SetEnvironmentVariable($variable.Name,$null,'Process')
    }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') }
}
