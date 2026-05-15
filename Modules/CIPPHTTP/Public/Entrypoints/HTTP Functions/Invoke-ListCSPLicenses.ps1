function Invoke-ListCSPLicenses {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Directory.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    $TenantFilter = $Request.Query.tenantFilter

    try {
        $Provider = Get-CIPPCSPProvider -TenantFilter $TenantFilter
        switch ($Provider) {
            'Pax8'    { $Result = Get-Pax8Subscriptions -TenantFilter $TenantFilter }
            'Sherweb' { $Result = Get-SherwebCurrentSubscription -TenantFilter $TenantFilter }
            default {
                $Result = 'No CSP mapping found for this tenant. Map it to Pax8 or Sherweb in Settings > Integrations.'
                $StatusCode = [HttpStatusCode]::BadRequest
            }
        }
        if (-not $StatusCode) { $StatusCode = [HttpStatusCode]::OK }
    } catch {
        $Result = "Unable to retrieve CSP licenses: $($_.Exception.Message)"
        $StatusCode = [HttpStatusCode]::BadRequest
    }

    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = @($Result)
    }
}
