function Invoke-ListCSPsku {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Directory.Read
    .DESCRIPTION
        Lists available CSP SKUs and current subscriptions for a tenant via the Sherweb integration.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    $TenantFilter = $Request.Query.tenantFilter
    $CurrentSkuOnly = $Request.Query.currentSkuOnly

    try {
        $Provider = Get-CIPPCSPProvider -TenantFilter $TenantFilter
        switch ($Provider) {
            'Pax8' {
                if ($CurrentSkuOnly) {
                    $GraphRequest = Get-Pax8Subscriptions -TenantFilter $TenantFilter
                } else {
                    $GraphRequest = Get-Pax8Catalog -TenantFilter $TenantFilter
                }
            }
            'Sherweb' {
                if ($CurrentSkuOnly) {
                    $GraphRequest = Get-SherwebCurrentSubscription -TenantFilter $TenantFilter
                } else {
                    $GraphRequest = Get-SherwebCatalog -TenantFilter $TenantFilter
                }
            }
            default {
                $GraphRequest = @()
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        if ($_.Exception.Message -in @('No Sherweb mapping found', 'No Pax8 mapping found')) {
            $GraphRequest = @()
            $StatusCode = [HttpStatusCode]::OK
        } else {
            $GraphRequest = [PSCustomObject]@{
                name = @(@{value = 'Error getting catalog' })
                sku  = $_.Exception.Message
            }
            $StatusCode = [HttpStatusCode]::InternalServerError
        }
    }

    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = @($GraphRequest)
    }
}
