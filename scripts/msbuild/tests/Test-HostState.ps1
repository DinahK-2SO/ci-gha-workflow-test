#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$SourceRoot
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tokens=$null
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $SourceRoot 'scripts\msbuild\Invoke-CiPilot.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Cannot parse the host-state guard.' }
$guard=$ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-Host'
},$true)
if (-not $guard) { throw 'Host-state guard is missing.' }
. ([scriptblock]::Create($guard.Extent.Text))
$reference=[pscustomobject]@{
    status='success';boot_session_id='fixture/System/12'
    power_status=[pscustomobject]@{ACLineStatus=1;SystemStatusFlag=0}
    power_scheme='Balanced';user_power_modes=[pscustomobject]@{ac_guid='balanced-mode'}
    os=[pscustomobject]@{Version='10.0';LastBootUpTime='2026-11-10T12:23:14+08:00'}
}
$state=$reference | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$state.os.LastBootUpTime='2026-11-10T12:22:56+08:00'
Assert-Host $state
[ordered]@{test='same-boot-session-accepts-drifting-wmi-boot-time';passed=$true}
foreach ($change in @(
    @{field='boot_session_id';value='fixture/System/13';error='*boot session*'},
    @{field='power_scheme';value='Power saver';error='*power scheme*'},
    @{field='power_status.ACLineStatus';value=0;error='*AC power*'},
    @{field='power_status.SystemStatusFlag';value=1;error='*battery saver*'},
    @{field='user_power_modes.ac_guid';value='efficiency-mode';error='*AC power mode*'},
    @{field='os.Version';value='11.0';error='*OS version*'},
    @{field='status';value='failed';error='*snapshot status*'}
)) {
    $state=$reference | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $parts=$change.field.Split('.')
    if ($parts.Count -eq 1) { $state.($parts[0])=$change.value }
    else { $state.($parts[0]).($parts[1])=$change.value }
    $rejected=$false
    try { Assert-Host $state } catch {
        if ($_.Exception.Message -notlike $change.error) { throw }
        $rejected=$true
    }
    if (-not $rejected) { throw "Host-state change was accepted: $($change.field)" }
}
[ordered]@{test='host-guard-rejects-boot-power-and-os-changes-with-specific-errors';passed=$true}
foreach ($missing in @('reference','current')) {
    $state=$reference | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $saved=$reference
    if ($missing -eq 'reference') {
        $reference=$reference | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $reference.PSObject.Properties.Remove('boot_session_id')
    } else { $state.PSObject.Properties.Remove('boot_session_id') }
    $rejected=$false
    try { Assert-Host $state } catch {
        if ($_.Exception.Message -notlike '*Prepare a new study*') { throw }
        $rejected=$true
    } finally { $reference=$saved }
    if (-not $rejected) { throw "Missing $missing boot-session identity was accepted." }
}
[ordered]@{test='host-guard-rejects-old-snapshots-without-silent-fallback';passed=$true}
