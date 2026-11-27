#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SeedPackage,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ReceiptPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HandoffSupport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BootstrapSupport.psm1') -Force
Assert-ComparisonSourceTree $PSScriptRoot
$seed=Assert-HandoffPackage $SeedPackage
$destinationPath=Assert-LocalStudyPath $Destination $PSScriptRoot
$null=Assert-LocalStudyPath $destinationPath $SeedPackage
$ReceiptPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReceiptPath)
$null=Assert-LocalStudyPath $ReceiptPath $SeedPackage
if ((Test-Path -LiteralPath $destinationPath) -or (Test-Path -LiteralPath $ReceiptPath)) {
    throw 'Preserve existing folders and assembly receipts.'
}
$record=[ordered]@{
    started_at=(Get-Date).ToString('o');status='assembling';destination=$destinationPath
    seed_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $SeedPackage 'package-manifest.json')).Hash
    workloads_executed=$false;product_checkouts_modified=$false
}
New-Item -ItemType Directory -Path $destinationPath,(Split-Path $ReceiptPath) -Force | Out-Null
try {
    foreach ($name in @('Run-Comparison.ps1','ComparisonSupport.psm1','comparison.json')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destinationPath $name)
    }
    foreach ($name in @('README.md','COMPARISON.md')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destinationPath $name)
    }
    $payload=Join-Path $destinationPath 'payload'
    Copy-Item -LiteralPath $SeedPackage -Destination $payload -Recurse
    $null=Assert-HandoffPackage $payload
    foreach ($name in @('Start-Study.ps1','HandoffSupport.psm1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $payload $name)
    }
    $sources=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-manifest.json') -Raw | ConvertFrom-Json
    foreach ($file in $sources.files) {
        $relative="scripts\$($file.path)"
        $target=Join-Path $payload $relative
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $target
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'source-manifest.json') -Destination $payload
    @('Run-Comparison.ps1','ComparisonSupport.psm1') | ForEach-Object {
        [ordered]@{name=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $destinationPath $_)).Hash}
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'comparison-launchers.json') -Encoding utf8
    $seed.created_at=(Get-Date).ToString('o')
    $seed.files=@(Get-PackageInventory $payload)
    $seed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $payload 'package-manifest.json') -Encoding utf8
    $null=Assert-HandoffPackage $payload
    $record.payload_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $payload 'package-manifest.json')).Hash
    $record.status='assembled_pending_validation'
} catch {
    $record.status='failed'
    $record.error=$_.Exception.Message
    throw
} finally {
    $record.finished_at=(Get-Date).ToString('o')
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
}
Write-Output "Standalone comparison folder: $destinationPath"
