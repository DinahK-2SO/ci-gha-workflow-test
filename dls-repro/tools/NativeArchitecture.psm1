Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-NativeBuildPlatform([string]$Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
    switch ($Architecture.ToLowerInvariant()) {
        'arm64' {
            [pscustomobject]@{
                architecture='ARM64'; machine='0xaa64'; machine_value=0xaa64
                compiler_subdirectory='Hostarm64\arm64'; msbuild_subdirectory='arm64'
                python_package='pythonarm64'; python_tag='win_arm64'
                workload_file='expected-workload.json'
            }
        }
        'x64' {
            [pscustomobject]@{
                architecture='x64'; machine='0x8664'; machine_value=0x8664
                compiler_subdirectory='Hostx64\x64'; msbuild_subdirectory='amd64'
                python_package='python'; python_tag='win_amd64'
                workload_file='expected-workload-x64.json'
            }
        }
        default { throw "Unsupported native Windows architecture: $Architecture. Supported targets are x64 and ARM64; cross-compilation is not selected." }
    }
}

function Get-NativeArtifact([string]$Path,[string]$Architecture) {
    $platform=Get-NativeBuildPlatform $Architecture
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Invalid PE artifact: $Path"
    }
    $pe=[BitConverter]::ToInt32($bytes,0x3c)
    if ($pe -lt 64 -or $pe -gt $bytes.Length-6 -or [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550) {
        throw "Invalid PE signature: $Path"
    }
    if ([BitConverter]::ToUInt16($bytes,$pe+4) -ne $platform.machine_value) {
        throw "Artifact does not match $($platform.architecture): $Path"
    }
    [ordered]@{path=$Path;sha256=(Get-FileHash -LiteralPath $Path).Hash;machine=$platform.machine;bytes=$bytes.Length}
}

function Get-RecordedBuildPlatform($Configuration,$Protocol = $null) {
    # Records predating architecture selection belong to the ARM64-only harness.
    $architecture=if ($Configuration.PSObject.Properties['architecture']) {$Configuration.architecture} else {'ARM64'}
    $platform=Get-NativeBuildPlatform $architecture
    if ($Protocol -and $Protocol.PSObject.Properties['architecture'] -and $Protocol.architecture -cne $platform.architecture) {
        throw 'Frozen protocol and configuration architectures differ.'
    }
    return $platform
}

Export-ModuleMember -Function Get-NativeBuildPlatform,Get-NativeArtifact,Get-RecordedBuildPlatform
