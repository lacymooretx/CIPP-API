function Invoke-ExecReport {
    <#
    .SYNOPSIS
        On-demand CIPP report generation for a tenant (any report type).
    .DESCRIPTION
        Generates an Aspendora / CIPP report of the requested ReportType for a single
        tenant and returns the branded HTML. Default returns JSON
        { Results, ReportName, ReportHtml }; pass Download=true to stream raw HTML.
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $TriggerMetadata.FunctionName
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed the Report endpoint' -Sev 'Debug'

    $TenantFilter = $Request.Body.TenantFilter ?? $Request.Query.TenantFilter
    $ReportType = $Request.Body.ReportType ?? $Request.Query.ReportType ?? 'Security'
    $TruthyValues = @($true, 'true', 'True', 1, '1', 'yes', 'on')
    $Download = ($Request.Body.Download ?? $Request.Query.Download) -in $TruthyValues
    $ConnectWiseTicket = ($Request.Body.ConnectWiseTicket ?? $Request.Query.ConnectWiseTicket) -in $TruthyValues

    if (-not $TenantFilter) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = ConvertTo-Json -InputObject @{ Results = 'TenantFilter is required.' }
            })
    }

    try {
        $Report = Push-ExecReport -TenantFilter $TenantFilter -ReportType $ReportType -ConnectWiseTicket $ConnectWiseTicket
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Generated $ReportType report for $TenantFilter" -Sev 'Info'

        if ($Download) {
            return ([HttpResponseContext]@{
                    StatusCode  = [HttpStatusCode]::OK
                    Body        = $Report.ReportHtml
                    ContentType = 'text/html; charset=utf-8'
                    Headers     = @{ 'Content-Disposition' = "attachment; filename=`"$($Report.ReportName)`"" }
                })
        }

        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = ConvertTo-Json -Depth 5 -InputObject @{
                    Results    = $Report.Results
                    ReportName = $Report.ReportName
                    ReportHtml = $Report.ReportHtml
                }
            })
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Report ($ReportType) failed: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = ConvertTo-Json -InputObject @{ Results = "Failed to generate report: $($ErrorMessage.NormalizedError)" }
            })
    }
}
