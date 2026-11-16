#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'results\2026-1104\host.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $OutputPath) {
    throw "Evidence already exists: $OutputPath"
}
New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force | Out-Null
$result = [ordered]@{
    captured_at = (Get-Date).ToString('o')
    status = 'running'
}
try {
    if (-not ('OpenCvInvestigation.Power' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace OpenCvInvestigation {
    [StructLayout(LayoutKind.Sequential)]
    public struct PowerStatus {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }
    public static class Power {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetSystemPowerStatus(out PowerStatus status);
        [DllImport("powrprof.dll")]
        public static extern uint PowerGetUserConfiguredACPowerMode(out Guid mode);
        [DllImport("powrprof.dll")]
        public static extern uint PowerGetUserConfiguredDCPowerMode(out Guid mode);
    }
}
'@
    }
    $result.cpu = @(Get-CimInstance Win32_Processor |
        Select-Object Name, Manufacturer, Architecture, NumberOfCores,
            NumberOfLogicalProcessors, MaxClockSpeed)
    $result.system = Get-CimInstance Win32_ComputerSystem |
        Select-Object Manufacturer, Model, SystemType, TotalPhysicalMemory,
            NumberOfLogicalProcessors, HypervisorPresent
    $result.os = Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime
    $result.os_architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $result.process_architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    $result.powershell_version = $PSVersionTable.PSVersion.ToString()
    $result.powershell_path = (Get-Process -Id $PID).Path
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $result.elevated = [Security.Principal.WindowsPrincipal]::new($identity).
            IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }

    $power = [OpenCvInvestigation.PowerStatus]::new()
    if (-not [OpenCvInvestigation.Power]::GetSystemPowerStatus([ref]$power)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    $result.power_status = $power
    $scheme = & powercfg.exe /getactivescheme
    if ($LASTEXITCODE -ne 0) { throw "powercfg failed: $LASTEXITCODE" }
    $result.power_scheme = ($scheme | Out-String).Trim()
    $ac = [guid]::Empty
    $dc = [guid]::Empty
    $acResult = [OpenCvInvestigation.Power]::PowerGetUserConfiguredACPowerMode([ref]$ac)
    $dcResult = [OpenCvInvestigation.Power]::PowerGetUserConfiguredDCPowerMode([ref]$dc)
    if ($acResult -ne 0 -or $dcResult -ne 0) {
        throw "Power-mode queries failed: AC=$acResult, DC=$dcResult"
    }
    $modes = @{
        '00000000-0000-0000-0000-000000000000' = 'Balanced'
        '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best Power Efficiency'
        'ded574b5-45a0-4f42-8737-46345c09c238' = 'Best Performance'
    }
    $result.user_power_modes = [ordered]@{
        ac_guid = $ac.ToString()
        ac_name = $modes[$ac.ToString()]
        dc_guid = $dc.ToString()
        dc_name = $modes[$dc.ToString()]
        interpretation = 'User-configured modes; not a measurement of frequency, temperature, or firmware limits.'
    }
    $result.status = 'success'
} catch {
    $result.status = 'failed'
    $result.error = $_.Exception.Message
    throw
} finally {
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output "Host snapshot: $OutputPath"
}
