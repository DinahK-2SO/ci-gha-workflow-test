Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:PlatformModule=Join-Path $PSScriptRoot 'NativeArchitecture.psm1'
Import-Module $script:PlatformModule
$script:EnvironmentNames=@(
    'PATH','INCLUDE','LIB','LIBPATH','EXTERNAL_INCLUDE','VCToolsInstallDir',
    'VCToolsVersion','WindowsSdkDir','WindowsSDKVersion','UniversalCRTSdkDir',
    'UCRTVersion','VSINSTALLDIR','VCINSTALLDIR','VSCMD_ARG_HOST_ARCH','VSCMD_ARG_TGT_ARCH'
)

function Assert-DlsSafePath([string]$Path) {
    if ($Path -match '["%!&|<>^`\r\n]') { throw 'Unsupported shell character in a DLS tool path.' }
}

function Set-DlsProcessValue([string]$Name,$Value) {
    if ($null -eq $Value) {
        # Preserve an absent variable rather than binding null as an empty string.
        [Environment]::SetEnvironmentVariable($Name,[NullString]::Value,'Process')
    } else {
        [Environment]::SetEnvironmentVariable($Name,[string]$Value,'Process')
    }
}

function Get-DlsPeMachine([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $reader=[IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Not a PE image: $Path" }
        $stream.Position=0x3c
        $offset=$reader.ReadUInt32()
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}

function Get-DlsNativeMachine([string]$Path,$Platform,[switch]$Coff) {
    $machine=if ($Coff) {
        $reader=[IO.BinaryReader]::new([IO.File]::OpenRead($Path))
        try { $reader.ReadUInt16() } finally { $reader.Dispose() }
    } else { Get-DlsPeMachine $Path }
    if ($machine -ne $Platform.machine_value) {
        throw ('Expected native {0}, found machine 0x{1:X4}: {2}' -f $Platform.architecture,$machine,$Path)
    }
    '0x{0:X4}' -f $machine
}

function Assert-DlsAvailableHost {
    $busy=@(Get-Process | Where-Object {
        $_.ProcessName -in @('MSBuild','cl','c1xx','c1','link','cmake','ninja','clang','clang++','clang-cl','lld-link') -or
        $_.ProcessName -like 'opencv_perf*' -or $_.ProcessName -like 'opencv_test*'
    })
    if ($busy.Count) { throw "Another build or OpenCV test is active: $($busy.Id -join ','); leave it alone." }
    if ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory -lt 24*1MB) {
        throw 'Less than 24 GiB free memory.'
    }
}

function Get-DlsToolset([string]$VisualStudio) {
    Assert-DlsSafePath $VisualStudio
    $platform=Get-NativeBuildPlatform
    $versionFile=Join-Path $VisualStudio 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
    $version=(Get-Content -LiteralPath $versionFile -Raw).Trim()
    $bin=Join-Path $VisualStudio "VC\Tools\MSVC\$version\bin\$($platform.compiler_subdirectory)"
    $batchName=if ($platform.architecture -eq 'x64') { 'vcvars64.bat' } else { 'vcvarsarm64.bat' }
    $vcvars=Join-Path $VisualStudio "VC\Auxiliary\Build\$batchName"
    $compiler=Join-Path $bin 'cl.exe'
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $helper=Join-Path $PSScriptRoot 'BoundedProcess.cs'
    $paths=@(
        $versionFile,$compiler,(Join-Path $bin 'c1xx.dll'),(Join-Path $bin 'c2.dll'),
        (Join-Path $bin 'link.exe'),$vswhere,$helper,$PSCommandPath,
        $vcvars,$script:PlatformModule,
        (Join-Path $VisualStudio 'VC\Auxiliary\Build\vcvarsall.bat'),
        (Join-Path $VisualStudio 'Common7\Tools\VsDevCmd.bat')
    )
    $hashes=@{}
    foreach ($path in $paths) { $hashes[[IO.Path]::GetFullPath($path)]=(Get-FileHash -LiteralPath $path).Hash }
    $compilerMachine=Get-DlsNativeMachine $compiler $platform
    if (-not ('DlsMeasuredProcess' -as [type])) { Add-Type -Path $helper }
    [pscustomobject]@{
        VisualStudio=$VisualStudio; Version=$version; Compiler=$compiler; Bin=$bin
        CompilerVersion=(Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        VsWhere=$vswhere; VcVars=$vcvars; Platform=$platform; CompilerMachine=$compilerMachine
        FrozenHashes=$hashes
    }
}

function New-DlsEnvironment {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)][string]$Directory,
        [string]$WindowsSdkVersion='10.0.26100.0'
    )
    $Directory=[IO.Path]::GetFullPath($Directory)
    Assert-DlsSafePath $Directory
    if ($WindowsSdkVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Invalid SDK version.' }
    if (Test-Path -LiteralPath $Directory) { throw 'Use a fresh compiler-environment directory.' }
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $batch=Join-Path $Directory 'initialize.cmd'
    $exporter=Join-Path $Directory 'export-environment.ps1'
    $valuesPath=Join-Path $Directory 'native-environment.json'
    $vsLog=Join-Path $Directory 'vcvars.log'
    $outerLog=Join-Path $Directory 'initialize.log'
    $powershell=(Get-Process -Id $PID).Path
    Assert-DlsSafePath $powershell
    $exportText=@'
param([string]$OutputPath)
$ErrorActionPreference='Stop'
$values=[ordered]@{}
foreach($name in @('PATH','INCLUDE','LIB','LIBPATH','EXTERNAL_INCLUDE','VCToolsInstallDir',
    'VCToolsVersion','WindowsSdkDir','WindowsSDKVersion','UniversalCRTSdkDir','UCRTVersion',
    'VSINSTALLDIR','VCINSTALLDIR','VSCMD_ARG_HOST_ARCH','VSCMD_ARG_TGT_ARCH')) {
    $values[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
[ordered]@{
    values=$values
    current_directory_search_policy=[Environment]::GetEnvironmentVariable('NoDefaultCurrentDirectoryInExePath','Process')
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding utf8
'@
    [IO.File]::WriteAllText($exporter,$exportText,[Text.UTF8Encoding]::new($false))
    $lines=@(
        '@echo off','setlocal',
        "call `"$($Tools.VcVars)`" $WindowsSdkVersion -vcvars_ver=$($Tools.Version) > `"$vsLog`" 2>&1",
        'if errorlevel 1 exit /b %errorlevel%',
        "`"$powershell`" -NoLogo -NoProfile -File `"$exporter`" -OutputPath `"$valuesPath`"",
        'exit /b %errorlevel%'
    )
    [IO.File]::WriteAllText($batch,($lines -join "`r`n")+"`r`n",[Text.Encoding]::ASCII)
    $oldPath=[Environment]::GetEnvironmentVariable('PATH','Process')
    $policy=[Environment]::GetEnvironmentVariable('NoDefaultCurrentDirectoryInExePath','Process')
    try {
        [Environment]::SetEnvironmentVariable('PATH',((Split-Path $Tools.VsWhere)+';'+$oldPath),'Process')
        $run=[DlsMeasuredProcess]::Run($batch,[string[]]@(),$Directory,$outerLog,60)
    } finally {
        Set-DlsProcessValue 'PATH' $oldPath
    }
    if ($run.ExitCode -ne 0 -or $run.TimedOut) { throw "Compiler environment failed; see $vsLog and $outerLog" }
    $diagnostic=Get-Content -LiteralPath $vsLog -Raw
    if ($diagnostic -match '(?i)is not recognized|\[ERROR:|environment may be incomplete') {
        throw "Compiler initialization emitted an error diagnostic; see $vsLog"
    }
    $snapshot=Get-Content -LiteralPath $valuesPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($name in @('PATH','INCLUDE','LIB','VCToolsVersion','WindowsSDKVersion','WindowsSdkDir')) {
        if (-not $snapshot.values[$name]) { throw "Missing compiler environment value: $name" }
    }
    $arch=$Tools.Platform.architecture.ToLowerInvariant()
    if ($snapshot.values.VSCMD_ARG_HOST_ARCH -ne $arch -or
        $snapshot.values.VSCMD_ARG_TGT_ARCH -ne $arch -or
        $snapshot.values.VCToolsVersion.TrimEnd('\') -ne $Tools.Version -or
        $snapshot.values.WindowsSDKVersion.TrimEnd('\') -ne $WindowsSdkVersion) {
        throw 'The initialized architecture, toolset or SDK differs from the selected profile.'
    }
    if ($snapshot.current_directory_search_policy -cne $policy -or
        [Environment]::GetEnvironmentVariable('NoDefaultCurrentDirectoryInExePath','Process') -cne $policy) {
        throw 'The current-directory search policy changed unexpectedly.'
    }
    $ucrt=Join-Path $snapshot.values.WindowsSdkDir "Lib\$WindowsSdkVersion\ucrt\$arch\ucrt.lib"
    if (-not (Test-Path -LiteralPath $ucrt)) { throw "The selected $arch CRT import library is missing: $ucrt" }
    [pscustomobject]@{
        Values=$snapshot.values
        Metadata=[ordered]@{
            status='initialized_without_discovery_warning'
            toolset=$Tools.Version; windows_sdk=$WindowsSdkVersion
            host=$snapshot.values.VSCMD_ARG_HOST_ARCH; target=$snapshot.values.VSCMD_ARG_TGT_ARCH
            current_directory_search_policy_preserved=$true
            installer_directory_added_only_to_task_process_path=$true
            process_path_restored=$true; machine_or_user_environment_changed=$false
            environment_file=$valuesPath; environment_sha256=(Get-FileHash $valuesPath).Hash
            initialization_log=$vsLog; initialization_log_sha256=(Get-FileHash $vsLog).Hash
            batch_sha256=(Get-FileHash $batch).Hash; exporter_sha256=(Get-FileHash $exporter).Hash
            initialization_run=$run
        }
    }
}

function Invoke-DlsEnvironment {
    param([Parameter(Mandatory)]$Environment,[Parameter(Mandatory)][scriptblock]$Action)
    $saved=@{}
    try {
        foreach ($name in $script:EnvironmentNames) {
            $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
            Set-DlsProcessValue $name $Environment.Values[$name]
        }
        & $Action
    } finally {
        foreach ($name in $saved.Keys) { Set-DlsProcessValue $name $saved[$name] }
    }
}

Export-ModuleMember -Function Assert-DlsSafePath,Get-DlsPeMachine,Get-DlsNativeMachine,Assert-DlsAvailableHost,Get-DlsToolset,New-DlsEnvironment,Invoke-DlsEnvironment
