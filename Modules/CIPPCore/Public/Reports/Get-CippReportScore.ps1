function Get-CippReportScore {
    <#
    .SYNOPSIS
        Compute the weighted posture score/grade for a report from its findings.
    .DESCRIPTION
        Shared scoring used by Write-CippReportHtml (the posture hero) and
        Push-ExecReport (history/trend). Score starts at 100 and is penalised per
        finding: -15 for each 'fail', -5 for each 'warn' (floored at 0). Info-only
        reports return Scored=$false. Returns @{ Scored; Score; Grade; Fail; Warn; Pass }.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param($Findings)

    $valid = @('pass', 'warn', 'fail', 'info')
    $st = foreach ($f in @($Findings)) {
        if ($f) { $s = "$($f.Status)".ToLower(); if ($valid -contains $s) { $s } else { 'info' } }
    }
    $fail = @($st | Where-Object { $_ -eq 'fail' }).Count
    $warn = @($st | Where-Object { $_ -eq 'warn' }).Count
    $pass = @($st | Where-Object { $_ -eq 'pass' }).Count
    $scored = ($fail + $warn + $pass) -gt 0
    $score = [math]::Max(0, 100 - ($fail * 15) - ($warn * 5))
    $grade = if ($score -ge 90) { 'A' } elseif ($score -ge 80) { 'B' } elseif ($score -ge 70) { 'C' } elseif ($score -ge 60) { 'D' } else { 'F' }
    return @{ Scored = $scored; Score = $score; Grade = $grade; Fail = $fail; Warn = $warn; Pass = $pass }
}
