#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1,60)][int]$IntervalSeconds = 5,
    [ValidateRange(0,10000)][int]$MaxSamples = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (Test-Path -LiteralPath $OutputPath) { throw 'Resource samples already exist; do not overwrite them.' }
$samples = 0
while ($MaxSamples -eq 0 -or $samples -lt $MaxSamples) {
    $start = Get-Date
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $os = Get-CimInstance Win32_OperatingSystem
    $processes = @(Get-Process | Where-Object ProcessName -In @('cl','MSBuild','link'))
    [ordered]@{
        sample_started_at=$start.ToString('o')
        sample_finished_at=(Get-Date).ToString('o')
        machine_cpu_percent=[double]$cpu.PercentProcessorTime
        machine_available_memory_gib=$os.FreePhysicalMemory/1MB
        machine_total_visible_memory_gib=$os.TotalVisibleMemorySize/1MB
        machine_cl_processes=@($processes | Where-Object ProcessName -eq 'cl').Count
        machine_msbuild_processes=@($processes | Where-Object ProcessName -eq 'MSBuild').Count
        machine_link_processes=@($processes | Where-Object ProcessName -eq 'link').Count
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $OutputPath -Encoding utf8
    $samples++
    if ($MaxSamples -ne 0 -and $samples -ge $MaxSamples) { break }
    $remaining = $IntervalSeconds - ((Get-Date) - $start).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
}
