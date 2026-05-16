function Invoke-ListPax8Usage {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.Directory.Read
    .SYNOPSIS
        Returns Pax8 usage summaries for a tenant or a specific subscription.
        Pass ?tenantFilter=X for all subs of a tenant, or
             ?subscriptionId=X for one sub.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $TenantFilter   = $Request.Query.tenantFilter
    $SubscriptionId = $Request.Query.subscriptionId

    try {
        if ($SubscriptionId) {
            $Result = Get-Pax8UsageSummaries -SubscriptionId $SubscriptionId
        } elseif ($TenantFilter) {
            $Result = Get-Pax8UsageSummaries -TenantFilter $TenantFilter
        } else {
            return [HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = 'Provide tenantFilter or subscriptionId query parameter.'
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $Result = "Failed to list Pax8 usage: $($_.Exception.Message)"
        $StatusCode = [HttpStatusCode]::InternalServerError
    }
    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = @($Result)
    }
}
