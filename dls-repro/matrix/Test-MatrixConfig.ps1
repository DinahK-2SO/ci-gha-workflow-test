#Requires -Version 7.0
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\MatrixConfig.psm1" -Force
$fixture=[IO.Path]::GetTempFileName()
try {
    $entry='{"id":"one","enabled":true,"command":["msvc","2022"],"launches":4,"blocks":2,"sweeps":8}'
    "[`n/* $entry, */`n$entry, // trailing comma`n]" | Set-Content -LiteralPath $fixture
    $c=@(Read-RuntimeMatrix $fixture)
    if ($c.Count -ne 1 -or $c[0].id -cne 'one' -or $c[0].cpu -ne -1) { throw 'Comments or defaults not respected' }
    if ($null -ne $c[0].practical_band_pct) { throw 'Old config acquired a practical band' }
    foreach ($value in '0','-2','100','"2"','true','2.5') {
        $withBand = $entry.Replace('"id":', ('"practical_band_pct":' + $value + ',"id":'))
        "[$withBand]" | Set-Content -LiteralPath $fixture
        $rejected=$false
        try { $parsed=@(Read-RuntimeMatrix $fixture) } catch { $rejected=$true }
        if ($value -eq '2.5') {
            if ($rejected -or $parsed[0].practical_band_pct -ne 2.5) { throw 'Valid practical threshold rejected' }
        } elseif (!$rejected) { throw "Invalid practical threshold accepted: $value" }
    }
    foreach ($bad in @("[$entry,$entry]",$entry,"[$($entry.Replace('true','1'))]",
        "[$($entry.Replace('2022','2017'))]","[$($entry.Replace('"launches":4','"launches":3'))]",
        "[$($entry.Replace('one','../one'))]")) {
        $rejected=$false
        try { Set-Content -LiteralPath $fixture -Value $bad; $null=Read-RuntimeMatrix $fixture } catch { $rejected=$true }
        if (!$rejected) { throw "Invalid config accepted: $bad" }
    }
} finally { Remove-Item -LiteralPath $fixture }
'PASS: commented objects, invalid settings and duplicate ids.'
