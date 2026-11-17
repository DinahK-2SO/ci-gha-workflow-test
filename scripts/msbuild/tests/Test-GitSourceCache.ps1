#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$WorkRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $WorkRoot) { throw 'Preserve prior Git-cache fixtures.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
Import-Module (Join-Path $SourceRoot 'HandoffSupport.psm1') -Force
Import-Module (Join-Path $SourceRoot 'ComparisonSupport.psm1') -Force
Add-Type -TypeDefinition (Get-Content (Join-Path $SourceRoot 'scripts\msbuild\BoundedProcess.cs') -Raw)

function Invoke-FixtureGit([string[]]$Arguments) {
    $output=& git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $output" }
    return ($output -join "`n").Trim()
}
function Add-FixtureCommit([string]$Repository,[string]$Value) {
    $Value | Set-Content (Join-Path $Repository 'marker.txt')
    $null=Invoke-FixtureGit @('-C',$Repository,'add','marker.txt')
    $null=Invoke-FixtureGit @('-C',$Repository,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
        '-c','commit.gpgsign=false','-c','core.hooksPath=NUL','commit','--quiet','-m',$Value)
    Invoke-FixtureGit @('-C',$Repository,'rev-parse','HEAD')
}
function Get-FixtureSource([string]$Name,[string]$Branch,[string]$Commit,[string]$Repository='fixture/source') {
    $run=Join-Path $WorkRoot $Name
    New-Item -ItemType Directory -Path $run | Out-Null
    $destination=Join-Path $run 'source.git'
    $null=Invoke-FixtureGit @('init','--bare','--quiet',$destination)
    $source=Get-ComparisonCachedGitSource -Repository $Repository -BranchName $Branch -Commit $Commit `
        -CacheRoot (Join-Path $WorkRoot 'cache') -SourceTransport https `
        -Destination $destination -Reference 'refs/heads/selected' -LogRoot $run
    $actual=Invoke-FixtureGit @("--git-dir=$destination",'rev-parse','refs/heads/selected')
    if ($actual -cne $source.commit -or ($Commit -and $actual -cne $Commit) -or
        (Test-Path (Join-Path $destination 'objects\info\alternates'))) {
        throw 'Run source is not independent or lost its exact selected commit.'
    }
    return $source
}
$saved=@{}
foreach ($variable in Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_CONFIG_*' -or $_.Name -eq 'GIT_ALLOW_PROTOCOL' }) {
    $saved[$variable.Name]=$variable.Value
    Remove-Item -LiteralPath "Env:$($variable.Name)"
}
try {
    $remote=Join-Path $WorkRoot 'remote'
    $null=Invoke-FixtureGit @('init','--quiet','--initial-branch=main',$remote)
    $first=Add-FixtureCommit $remote 'first'
    $uri=([Uri]($remote+'\')).AbsoluteUri.TrimEnd('/')
    $env:GIT_CONFIG_COUNT='1'
    $env:GIT_CONFIG_KEY_0="url.$uri.insteadOf"
    $env:GIT_ALLOW_PROTOCOL='file'
    # Replace the whole source URL; no fixture may contact a real GitHub endpoint.
    $env:GIT_CONFIG_VALUE_0='https://github.com/fixture/source.git'
    $cold=Get-FixtureSource 'cold' 'main' $first
    if ((Invoke-FixtureGit @("--git-dir=$($cold.cache_path)",'rev-parse','--is-bare-repository')) -cne 'true' -or
        (Invoke-FixtureGit @("--git-dir=$($cold.cache_path)",'config','--get','remote.origin.url')) -cne
            'https://github.com/fixture/source.git') {
        throw 'Cold acquisition did not create an origin-bound bare cache.'
    }
    [ordered]@{test='git-cache-cold-fetch-retains-origin-and-exact-commit';passed=$true}

    $offline=([Uri]((Join-Path $WorkRoot 'unavailable')+'\')).AbsoluteUri.TrimEnd('/')
    $env:GIT_CONFIG_KEY_0="url.$offline.insteadOf"
    $warm=Get-FixtureSource 'offline-hit' 'main' $first
    $branchOnly=Get-FixtureSource 'offline-branch' 'main' ''
    if ($warm.cache_path -cne $cold.cache_path -or $branchOnly.commit -cne $first) {
        throw 'Cache reuse changed the repository or cached branch snapshot.'
    }
    $bundle=Join-Path $WorkRoot 'offline.bundle'
    $null=Invoke-FixtureGit @("--git-dir=$(Join-Path $WorkRoot 'offline-hit\source.git')",
        'bundle','create','--version=2',$bundle,'refs/heads/selected')
    $restored=Join-Path $WorkRoot 'restored'
    $null=Invoke-FixtureGit @('clone','--quiet','--branch','selected',$bundle,$restored)
    if ((Get-Content (Join-Path $restored 'marker.txt') -Raw).Trim() -cne 'first') {
        throw 'Offline cache selection did not produce a standalone source bundle.'
    }
    [ordered]@{test='git-cache-offline-commit-and-branch-hits-produce-independent-bundles';passed=$true}

    $env:GIT_CONFIG_KEY_0="url.$uri.insteadOf"
    $second=Add-FixtureCommit $remote 'second'
    $updated=Get-FixtureSource 'new-commit' 'main' $second
    if ($updated.branch_head_at_check -cne $second) { throw 'A missing commit did not refresh its branch.' }
    $null=Invoke-FixtureGit @('-C',$remote,'branch','additional')
    $newBranch=Get-FixtureSource 'new-branch' 'additional' $first
    if ($newBranch.branch_head_at_check -cne $second) { throw 'A missing branch was not fetched.' }
    $null=Invoke-FixtureGit @('-C',$remote,'checkout','--quiet','-b','other')
    $other=Add-FixtureCommit $remote 'other'
    $selected=Get-FixtureSource 'off-branch-commit' 'main' $other
    if ($selected.commit -cne $other -or $selected.branch_head_at_check -cne $second) {
        throw 'An exact off-branch commit was replaced with the branch head.'
    }
    $env:GIT_CONFIG_KEY_0="url.$offline.insteadOf"
    $null=Get-FixtureSource 'retained-old-commit' 'main' $first
    $null=Get-FixtureSource 'retained-new-commit' 'main' $second
    [ordered]@{test='git-cache-incremental-branches-and-exact-off-branch-commits';passed=$true}

    $handle=[IO.File]::Open(($cold.cache_path+'.lock'),[IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $rejected=$false
    try { $null=Get-FixtureSource 'locked' 'main' $first } catch {
        if ($_.Exception.Message -notlike 'Git source cache is in use:*') { throw }
        $rejected=$true
    } finally { $handle.Dispose() }
    if (-not $rejected) { throw 'Concurrent access ignored the repository cache lock.' }
    $null=Get-FixtureSource 'after-lock' 'main' $first
    [ordered]@{test='git-cache-exclusive-lock-and-release';passed=$true}

    $null=Invoke-FixtureGit @("--git-dir=$($cold.cache_path)",'config','remote.origin.url','https://github.com/fixture/wrong.git')
    $rejected=$false
    try { $null=Get-FixtureSource 'wrong-origin' 'main' $first } catch {
        if ($_.Exception.Message -notlike 'Git source cache origin differs:*') { throw }
        $rejected=$true
    } finally {
        $null=Invoke-FixtureGit @("--git-dir=$($cold.cache_path)",'config','remote.origin.url','https://github.com/fixture/source.git')
    }
    if (-not $rejected) { throw 'A cache belonging to a different repository was accepted.' }
    $env:GIT_CONFIG_VALUE_0='https://github.com/fixture/different.git'
    $rejected=$false
    try { $null=Get-FixtureSource 'different-repository' 'main' $first 'fixture/different' } catch {
        if ($_.Exception.Message -notlike 'Git operation failed*') { throw }
        $rejected=$true
    }
    if (-not $rejected) { throw 'Another repository reused a cached SHA without establishing its own source.' }
    $env:GIT_CONFIG_VALUE_0='https://github.com/fixture/source.git'
    $null=Get-FixtureSource 'after-failure' 'main' $first
    [ordered]@{test='git-cache-origin-isolation-and-failure-preserve-existing-entries';passed=$true}

    $objects=Join-Path $cold.cache_path 'objects'
    $savedObjects=Join-Path $cold.cache_path 'saved-objects'
    Move-Item -LiteralPath $objects -Destination $savedObjects
    New-Item -ItemType Directory -Path $objects | Out-Null
    $rejected=$false
    try { $null=Get-FixtureSource 'corrupt-cache' 'main' $first } catch {
        if ($_.Exception.Message -notlike 'Git operation failed*') { throw }
        $rejected=$true
    } finally {
        Remove-Item -LiteralPath $objects -Recurse -Force
        Move-Item -LiteralPath $savedObjects -Destination $objects
    }
    if (-not $rejected) { throw 'Corrupt cached objects were silently accepted or replaced.' }
    $null=Get-FixtureSource 'after-restore' 'main' $first
    [ordered]@{test='git-cache-corruption-fails-without-network-repair';passed=$true}
} finally {
    foreach ($variable in Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_CONFIG_*' -or $_.Name -eq 'GIT_ALLOW_PROTOCOL' }) {
        Remove-Item -LiteralPath "Env:$($variable.Name)"
    }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key],'Process') }
}
