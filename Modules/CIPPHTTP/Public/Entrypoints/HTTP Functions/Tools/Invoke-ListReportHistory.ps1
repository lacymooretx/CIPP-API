function Invoke-ListReportHistory {
    <#
    .SYNOPSIS
        List previously generated reports (history) with score/grade for trend views.
    .DESCRIPTION
        Returns rows from the CippReportHistory table, newest first, optionally filtered
        by TenantFilter and/or ReportType.
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $TriggerMetadata.FunctionName
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed report history' -Sev 'Debug'

    $TenantFilter = $Request.Query.TenantFilter ?? $Request.Body.TenantFilter
    $ReportType = $Request.Query.ReportType ?? $Request.Body.ReportType

    try {
        $Table = Get-CIPPTable -TableName 'CippReportHistory'
        $Filters = [System.Collections.Generic.List[string]]::new()
        if ($TenantFilter -and $TenantFilter -ne 'AllTenants') { $Filters.Add("PartitionKey eq '$TenantFilter'") }
        if ($ReportType) { $Filters.Add("ReportType eq '$ReportType'") }
        $FilterString = $Filters -join ' and '
        $Rows = if ($FilterString) { Get-CIPPAzDataTableEntity @Table -Filter $FilterString } else { Get-CIPPAzDataTableEntity @Table }
        $Results = @($Rows | Sort-Object { [int64]$_.DateUnix } -Descending | Select-Object Tenant, TenantName, ReportType, Title, Score, Grade, Fail, Warn, Pass, Date)

        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = ConvertTo-Json -Depth 5 -InputObject @($Results)
            })
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = ConvertTo-Json -InputObject @{ Results = "Failed to list report history: $($ErrorMessage.NormalizedError)" }
            })
    }
}
