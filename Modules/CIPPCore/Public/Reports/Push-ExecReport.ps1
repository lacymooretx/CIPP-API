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
    $Html = Write-CippReportHtml -Report $Model

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
