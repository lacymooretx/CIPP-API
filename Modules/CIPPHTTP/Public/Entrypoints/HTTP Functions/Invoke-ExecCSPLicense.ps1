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

        switch ($Provider) {
            'Pax8' {
                if ($Action -eq 'Add')    { $null = Set-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Add $Request.Body.Add }
                if ($Action -eq 'Remove') { $null = Set-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Remove $Request.Body.Remove }
                if ($Action -eq 'NewSub') {
                    $BillingTerm = if ($Request.Body.BillingTerm) { "$($Request.Body.BillingTerm)" } else { 'Monthly' }
                    $null = Set-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Quantity $Request.Body.Quantity -BillingTerm $BillingTerm
                }
                if ($Action -eq 'Cancel') { $null = Remove-Pax8Subscription -Headers $Headers -TenantFilter $TenantFilter -SubscriptionIds $Request.Body.SubscriptionIds }
            }
            'Sherweb' {
                if ($Action -eq 'Add')    { $null = Set-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Add $Request.Body.Add }
                if ($Action -eq 'Remove') { $null = Set-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Remove $Request.Body.Remove }
                if ($Action -eq 'NewSub') { $null = Set-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SKU $SKU -Quantity $Request.Body.Quantity }
                if ($Action -eq 'Cancel') { $null = Remove-SherwebSubscription -Headers $Headers -TenantFilter $TenantFilter -SubscriptionIds $Request.Body.SubscriptionIds }
            }
        }
        $Result = "License change executed successfully via $Provider."
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
