#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Package = 'C:\opencv-onboard\msbuild5x-20261110\tools\pythonarm64.3.13.14.nupkg',
    [string]$Destination = 'C:\opencv-onboard\msbuild5x-20261110\tools\python-dev-3.13.14-arm64',
    [string]$Dumpbin = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.44.35207\bin\Hostarm64\arm64\dumpbin.exe',
    [ValidateSet('ARM64','x64')][string]$Architecture = 'ARM64',
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'NativeArchitecture.psm1')
$platform=Get-NativeBuildPlatform $Architecture
if (Test-Path -LiteralPath $Destination) { throw 'Native development prefix already exists.' }
if (Test-Path -LiteralPath $OutputPath) { throw 'Native development receipt already exists.' }
$pin=if ($platform.architecture -ceq 'ARM64') {
    'rKajQq4oPqo6C6OTxgHG2LLA8by9iaAWDP5Co3qbTwyW658om0v/ISo3oTfis2iheP0JRY87edXpR4wPFEIxdw=='
} else {
    'GyWF09xWs3V7Pfh8mlQF7sgRQo9+XtqgQ5c3gCBaUtnUK1k8MCpZwU4N6bXqI4BibpLBRKQuiYDXkeKnHG0k3A=='
}
$expected = [Convert]::ToHexString([Convert]::FromBase64String($pin))
$hash = (Get-FileHash -LiteralPath $Package -Algorithm SHA512).Hash
if ($hash -cne $expected) { throw 'Package differs from the official NuGet SHA-512.' }
$destinationPath = [IO.Path]::GetFullPath($Destination)
$prefix = $destinationPath.TrimEnd('\') + '\'
$archive = [IO.Compression.ZipFile]::OpenRead($Package)
try {
    foreach ($entry in $archive.Entries) {
        $relative = $entry.FullName.Replace('/','\')
        $resolved = [IO.Path]::GetFullPath((Join-Path $destinationPath $relative))
        if ([IO.Path]::IsPathRooted($relative) -or
            -not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Unexpected archive destination path.'
        }
    }
} finally { $archive.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($Package,$destinationPath)
$python = Join-Path $destinationPath 'tools\python.exe'
$header = Join-Path $destinationPath 'tools\include\Python.h'
$library = Join-Path $destinationPath 'tools\libs\python313.lib'
foreach ($path in @($python,$header,$library)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing native development file: $path" }
}
$null=Get-NativeArtifact $python $platform.architecture
$null=Get-NativeArtifact (Join-Path $destinationPath 'tools\python313.dll') $platform.architecture
$headers = & $Dumpbin /nologo /headers $library
if ($LASTEXITCODE -ne 0) { throw 'Native import-library inspection failed.' }
$machines = @($headers | Select-String -Pattern '^\s*([0-9a-fA-F]{4}) machine\b' |
    ForEach-Object {[Convert]::ToInt32($_.Matches[0].Groups[1].Value,16)} | Sort-Object -Unique)
if ($machines.Count -ne 1 -or $machines[0] -ne $platform.machine_value) {
    throw "Import-library machine type is not exclusively $($platform.architecture)."
}
$raw = & $python -I -B -c 'import json,sys,sysconfig,importlib.util; print(json.dumps({"executable":sys.executable,"version":sys.version,"include":sysconfig.get_path("include"),"numpy_present":importlib.util.find_spec("numpy") is not None}))'
if ($LASTEXITCODE -ne 0) { throw 'Native interpreter identity check failed.' }
$identity = ($raw -join "`n") | ConvertFrom-Json
if ($identity.version -notmatch '^3\.13\.14 ') { throw 'Unexpected native Python version.' }
[ordered]@{
    prepared_at=(Get-Date).ToString('o')
    status='native_python_development_ready_numpy_pending'
    package=$Package
    architecture=$platform.architecture
    package_source="https://www.nuget.org/api/v2/package/$($platform.python_package)/3.13.14"
    package_metadata_source="https://www.nuget.org/api/v2/Packages(Id='$($platform.python_package)',Version='3.13.14')"
    package_sha512=$hash
    destination=$destinationPath
    identity=$identity
    interpreter_machine=$platform.machine
    interpreter_sha256=(Get-FileHash -LiteralPath $python).Hash
    python_header_sha256=(Get-FileHash -LiteralPath $header).Hash
    import_library=$library
    import_library_sha256=(Get-FileHash -LiteralPath $library).Hash
    import_library_machine_headers=@($headers | Select-String -Pattern 'machine \(' | ForEach-Object {$_.Line.Trim()} | Sort-Object -Unique)
    full_build_environment_ready=$false
    system_installation_changed=$false
    global_path_changed=$false
    conda_terms_accepted=$false
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output "Verified isolated $($platform.architecture) interpreter, runtime DLL, headers and import library; matching NumPy is still required."
