function Invoke-ExecCSPLicense {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Directory.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    $Headers = $Request.Headers

    $TenantFilter = $Request.Body.tenantFilter
    $Action = $Request.Body.Action
    $SKU = $Request.Body.SKU.value ?? $Request.Body.SKU

    try {
        $Provider = Get-CIPPCSPProvider -TenantFilter $TenantFilter
        if (-not $Provider) { throw 'No CSP mapping found for this tenant. Map it to Pax8 or Sherweb in Settings > Integrations.' }

        $TrackingId = $null
        switch ($Provider) {
            'Pax8' {
                if ($Action -eq 'Add')    { $Resp = Set-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Add $Request.Body.Add }
                if ($Action -eq 'Remove') { $Resp = Set-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Remove $Request.Body.Remove }
                if ($Action -eq 'NewSub') {
                    $BillingTerm = if ($Request.Body.BillingTerm) { "$($Request.Body.BillingTerm)" } else { 'Monthly' }
                    $Resp = Set-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Quantity $Request.Body.Quantity -BillingTerm $BillingTerm
                }
                if ($Action -eq 'Cancel') { $Resp = Remove-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SubscriptionIds $Request.Body.SubscriptionIds }
                # NewSub returns an order object with .id; Add/Remove return subscription PUT/DELETE result
                if ($Resp -and $Resp.id -and $Action -eq 'NewSub') { $TrackingId = "$($Resp.id)" }
            }
            'Sherweb' {
                if ($Action -eq 'Add')    { $Resp = Set-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Add $Request.Body.Add }
                if ($Action -eq 'Remove') { $Resp = Set-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Remove $Request.Body.Remove }
                if ($Action -eq 'NewSub') { $Resp = Set-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Quantity $Request.Body.Quantity }
                if ($Action -eq 'Cancel') { $Resp = Remove-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SubscriptionIds $Request.Body.SubscriptionIds }
                if ($Resp -and $Resp.requestTrackingId) { $TrackingId = "$($Resp.requestTrackingId)" }
            }
        }
        $Result = [PSCustomObject]@{
            Message    = "License change executed successfully via $Provider."
            Provider   = $Provider
            TrackingId = $TrackingId
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $Result = "Failed to execute license change. Error: $_"
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = $Result
    }
}
