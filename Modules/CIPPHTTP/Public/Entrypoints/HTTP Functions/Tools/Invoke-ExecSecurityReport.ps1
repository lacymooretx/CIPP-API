function Invoke-ExecSecurityReport {
    <#
    .SYNOPSIS
        On-demand Microsoft 365 Security Report for a tenant.
    .DESCRIPTION
        Generates the Aspendora / CIPP "Microsoft 365 Security Report" for a single
        tenant and returns the branded HTML. By default returns JSON
        { Results, ReportName, ReportHtml } for the frontend to preview/download.
        Pass Download=true (query or body) to stream the raw HTML with a
        text/html content type instead.
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $TriggerMetadata.FunctionName
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed the Security Report endpoint' -Sev 'Debug'

    $TenantFilter = $Request.Body.TenantFilter ?? $Request.Query.TenantFilter
    $TruthyValues = @($true, 'true', 'True', 1, '1', 'yes', 'on')
    $Download = ($Request.Body.Download ?? $Request.Query.Download) -in $TruthyValues

    if (-not $TenantFilter) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = ConvertTo-Json -InputObject @{ Results = 'TenantFilter is required.' }
            })
    }

    try {
        $Report = Push-ExecSecurityReport -TenantFilter $TenantFilter
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Generated Security Report for $TenantFilter" -Sev 'Info'

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
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Security Report failed: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = ConvertTo-Json -InputObject @{ Results = "Failed to generate report: $($ErrorMessage.NormalizedError)" }
            })
    }
}
