function Push-ExecReport {
    <#
    .SYNOPSIS
        Generate a CIPP report of the given type for a tenant and return it as an
        email-ready attachment (generic schedulable command).
    .DESCRIPTION
        The generic scheduler entry point for the Aspendora / CIPP report suite. Gathers
        the report model (Get-CIPPReportData -ReportType), renders branded HTML
        (Write-CippReportHtml), and returns Results + a base64 HTML TaskAttachments entry
        so the CIPP scheduler emails it when PostExecution includes Email. Schedule via
        POST /api/AddScheduledItem with command 'Push-ExecReport' and parameters
        { TenantFilter, ReportType }.
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [string]$ReportType = 'Security'
    )

    $Model = Get-CIPPReportData -TenantFilter $TenantFilter -ReportType $ReportType

    # ---- history + trend (best-effort; never blocks report generation) ------------
    $Score = Get-CippReportScore -Findings $Model.Findings
    $CurFailTitles = @(@($Model.Findings) | Where-Object { "$($_.Status)".ToLower() -eq 'fail' } | ForEach-Object { $_.Title })
    try {
        $HistTable = Get-CIPPTable -TableName 'CippReportHistory'
        $Prev = Get-CIPPAzDataTableEntity @HistTable -Filter "PartitionKey eq '$TenantFilter' and ReportType eq '$ReportType'" |
            Sort-Object { [int64]$_.DateUnix } -Descending | Select-Object -First 1
        if ($Prev -and $Score.Scored) {
            $PrevFail = @()
            try { $PrevFail = @(($Prev.FailTitles | ConvertFrom-Json)) } catch {}
            $Model.Trend = @{
                PrevScore    = [int]$Prev.Score
                PrevDate     = ([datetime]$Prev.Date).ToString('dd MMM yyyy')
                NewFail      = @($CurFailTitles | Where-Object { $_ -notin $PrevFail }).Count
                ResolvedFail = @($PrevFail | Where-Object { $_ -notin $CurFailTitles }).Count
            }
        }
    } catch { Write-LogMessage -API 'ReportHistory' -message "history read: $($_.Exception.Message)" -Sev 'Error' }

    $Html = Write-CippReportHtml -Report $Model

    # persist this run
    try {
        $HistTable = Get-CIPPTable -TableName 'CippReportHistory'
        $Now = Get-Date
        Add-CIPPAzDataTableEntity @HistTable -Entity @{
            PartitionKey = "$TenantFilter"
            RowKey       = "$ReportType-$([guid]::NewGuid().ToString())"
            Tenant       = "$TenantFilter"
            TenantName   = "$($Model.TenantName)"
            ReportType   = "$ReportType"
            Title        = "$($Model.Title)"
            Score        = [int]$Score.Score
            Grade        = "$($Score.Grade)"
            Fail         = [int]$Score.Fail
            Warn         = [int]$Score.Warn
            Pass         = [int]$Score.Pass
            FailTitles   = ($CurFailTitles | ConvertTo-Json -Compress)
            Date         = $Now.ToString('o')
            DateUnix     = [int64]($Now.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
        } -Force | Out-Null
    } catch { Write-LogMessage -API 'ReportHistory' -message "history write: $($_.Exception.Message)" -Sev 'Error' }

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Base64 = [Convert]::ToBase64String($Bytes)
    $SafeDomain = ($Model.TenantDomain -replace '[^a-zA-Z0-9_\-\.]', '_')
    $SafeType = ($ReportType -replace '[^a-zA-Z0-9]', '')
    $FileName = "Aspendora-$SafeType-Report-$SafeDomain-$((Get-Date).ToString('yyyy-MM-dd')).html"

    $FailCount = @($Model.Findings | Where-Object { $_.Status -eq 'fail' }).Count
    $WarnCount = @($Model.Findings | Where-Object { $_.Status -eq 'warn' }).Count
    $ResultMessage = "$($Model.Title) generated for $($Model.TenantName) ($($Model.TenantDomain)) - $(@($Model.Sections).Count) sections, $FailCount action item(s), $WarnCount to review."

    return @{
        Results         = $ResultMessage
        TaskAttachments = @(
            @{ Name = $FileName; ContentType = 'text/html'; ContentBytes = $Base64 }
        )
        ReportName      = $FileName
        ReportHtml      = $Html
    }
}
