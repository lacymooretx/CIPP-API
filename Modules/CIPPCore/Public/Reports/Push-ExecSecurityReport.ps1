function Push-ExecSecurityReport {
    <#
    .SYNOPSIS
        Generate the Microsoft 365 Security Report for a tenant and return it as an
        email-ready attachment (schedulable command).
    .DESCRIPTION
        Gathers the report model (Get-CIPPSecurityReportData), renders branded HTML
        (Write-CippReportHtml), and returns a result object with a base64 HTML
        TaskAttachments entry so the CIPP scheduler (Send-CIPPScheduledTaskAlert ->
        Send-CIPPAlert) emails the report as an attachment when PostExecution includes
        Email. Also returned inline (ReportHtml/ReportName) for on-demand callers.
        Schedule it like the Report Builder: POST /api/AddScheduledItem with
        command 'Push-ExecSecurityReport', a TenantFilter, Recurrence (e.g. 30d),
        and postExecution Email.
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )

    $Model = Get-CIPPSecurityReportData -TenantFilter $TenantFilter
    $Html = Write-CippReportHtml -Report $Model

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Base64 = [Convert]::ToBase64String($Bytes)
    $SafeDomain = ($Model.TenantDomain -replace '[^a-zA-Z0-9_\-\.]', '_')
    $FileName = "Aspendora-Security-Report-$SafeDomain-$((Get-Date).ToString('yyyy-MM-dd')).html"

    $FailCount = @($Model.Findings | Where-Object { $_.Status -eq 'fail' }).Count
    $WarnCount = @($Model.Findings | Where-Object { $_.Status -eq 'warn' }).Count
    $ResultMessage = "Microsoft 365 Security Report generated for $($Model.TenantName) ($($Model.TenantDomain)) - $(@($Model.Sections).Count) sections, $FailCount action item(s), $WarnCount to review."

    return @{
        Results         = $ResultMessage
        TaskAttachments = @(
            @{
                Name         = $FileName
                ContentType  = 'text/html'
                ContentBytes = $Base64
            }
        )
        ReportName      = $FileName
        ReportHtml      = $Html
    }
}
