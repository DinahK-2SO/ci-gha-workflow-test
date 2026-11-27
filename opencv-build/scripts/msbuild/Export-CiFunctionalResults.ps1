#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProtocolPath,
    [Parameter(Mandatory)][ValidateSet('baseline','shared','fixed')][string]$Condition,
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $Destination) { throw 'Evidence destination already exists.' }
$protocol = Get-Content -LiteralPath $ProtocolPath -Raw | ConvertFrom-Json
$configuration = Get-Content -LiteralPath $protocol.configuration -Raw | ConvertFrom-Json
$trialRoot = Join-Path $protocol.output_root $Condition
$execution = Get-Content -LiteralPath (Join-Path $trialRoot 'execution.json') -Raw | ConvertFrom-Json
if ($execution.role -ne 'functional_qualification' -or $execution.performance_eligible -ne $false -or
    $execution.timing_use -ne 'diagnostic_only' -or
    $execution.protocol_sha256 -cne (Get-FileHash -LiteralPath $ProtocolPath).Hash) {
    throw 'The execution does not match the non-performance functional protocol.'
}
$archive = Join-Path $trialRoot 'artifacts'
if (Test-Path -LiteralPath $archive) { throw 'Artifact archive already exists; preserve the original bytes.' }
$record = [ordered]@{
    started_at=(Get-Date).ToString('o')
    status='exporting'
    condition=$Condition
    execution_status=$execution.status
    role='functional_qualification'
    performance_eligible=$false
    timing_use='diagnostic_only'
    local_binary_archive=$archive
    binaries_published=$false
    evidence=@()
    binaries=@()
}
New-Item -ItemType Directory -Path $Destination | Out-Null
try {
    foreach ($file in Get-ChildItem -LiteralPath $trialRoot -File) {
        if ($file.Extension -notin @('.json','.jsonl','.log','.xml')) { continue }
        $target = Join-Path $Destination $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
        if ($hash -cne (Get-FileHash -LiteralPath $target).Hash) { throw 'Evidence bytes changed while copying.' }
        $record.evidence += [ordered]@{name=$file.Name; bytes=$file.Length; sha256=$hash}
    }
    if ($execution.status -eq 'functional_build_passed') {
        foreach ($artifact in $execution.artifacts) {
            if ((Get-FileHash -LiteralPath $artifact.path).Hash -cne $artifact.sha256) {
                throw 'A checked output changed before archiving; do not associate it with the original result.'
            }
        }
        $build = Join-Path $configuration.root $configuration.build_directory
        foreach ($relative in @('bin\Release','lib\Release','lib\python3\Release')) {
            $source = Join-Path $build $relative
            $target = Join-Path $archive $relative
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            foreach ($file in Get-ChildItem -LiteralPath $source -File) {
                $copy = Join-Path $target $file.Name
                Copy-Item -LiteralPath $file.FullName -Destination $copy
                $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
                if ($hash -cne (Get-FileHash -LiteralPath $copy).Hash) { throw 'Archived output differs from the original.' }
                $record.binaries += [ordered]@{
                    relative_path=(Join-Path $relative $file.Name)
                    bytes=$file.Length
                    sha256=$hash
                }
            }
        }
    }
    $record.status='exported'
} catch {
    $record.status='failed'
    $record.error=$_.Exception.Message
    throw
} finally {
    $record.finished_at=(Get-Date).ToString('o')
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Destination 'archive-manifest.json') -Encoding utf8
}
Write-Output "Archived $Condition evidence and preserved local outputs; no binaries published and no performance statistics generated."
