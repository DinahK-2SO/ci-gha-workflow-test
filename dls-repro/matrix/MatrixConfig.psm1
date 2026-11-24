Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Read-RuntimeMatrix([string]$Path) {
    $entries = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($entries -isnot [array]) { throw 'Expected a JSONC array of environment objects.' }
    $ids = @{}
    foreach ($e in $entries) {
        if ($e -isnot [System.Collections.IDictionary]) { throw 'Each entry must be an object.' }
        $keys = @('id','enabled','command','launches','blocks','sweeps')
        if (@($keys | Where-Object { !$e.Contains($_) }).Count -or
            @($e.Keys | Where-Object { $_ -cnotin ($keys + @('cpu','seed')) }).Count) { throw 'Invalid or missing environment fields.' }
        $id = $e.id
        if ($id -isnot [string] -or $id -cnotmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,31}$' -or
            $id -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$' -or $ids.ContainsKey($id)) { throw "Invalid or duplicate id: $id" }
        $ids[$id] = $true
        if ($e.enabled -isnot [bool]) { throw "Expected boolean enabled: $id" }
        $c = $e.command
        if ($c -isnot [array] -or $c.Count -lt 2 -or @($c | Where-Object {
            $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_ -match '[\x00-\x1f]'
        }).Count) { throw "Expected command argument array: $id" }
        switch -CaseSensitive ($c[0]) {
            'msvc' { if ($c.Count -ne 2 -or $c[1] -cnotin '2019','2022','2026') { throw "Unsupported MSVC command: $id" } }
            'windows' { if ($c.Count -ne 3 -or $c[1] -cnotin 'gcc','clang') { throw "Unsupported Windows command: $id" } }
            'wsl' { if ($c.Count -ne 4 -or $c[2] -cnotin 'gcc','clang' -or $c[1].StartsWith('-')) { throw "Unsupported WSL command: $id" } }
            default { throw "Unknown command: $($c[0])" }
        }
        if (!$e.Contains('cpu')) { $e.cpu = -1 }
        if (!$e.Contains('seed')) { $e.seed = 20261124 }
        foreach ($pair in @(@('launches',2,32),@('blocks',1,64),@('sweeps',1,10000),@('cpu',-1,1023),@('seed',0,2147483647))) {
            $n = $e[$pair[0]]
            if (($n -isnot [int] -and $n -isnot [long]) -or $n -lt $pair[1] -or $n -gt $pair[2]) {
                throw "Invalid $($pair[0]) for $id (expected integer $($pair[1])..$($pair[2]))."
            }
        }
        if ($e.launches % 2) { throw "Use even launches for balanced link order: $id" }
        $e
    }
}
Export-ModuleMember -Function Read-RuntimeMatrix
