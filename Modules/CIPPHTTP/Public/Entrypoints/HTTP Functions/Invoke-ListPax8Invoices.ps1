function Invoke-ListPax8Invoices {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.Directory.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    try {
        $Result = Get-Pax8Invoices
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $Result = "Failed to list Pax8 invoices: $($_.Exception.Message)"
        $StatusCode = [HttpStatusCode]::InternalServerError
    }
    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = @($Result)
    }
}
