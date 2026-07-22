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

        # Upstream #6390: schedule a license decrease at renewal. Originally Sherweb-only; here it is
        # provider-generic so a Pax8-mapped tenant gets the same capability (Pax8 also blocks mid-term
        # decreases on committed products, so the decrease can only take effect at renewal).
        # (The switch above already handles Cancel per-provider, so upstream's duplicate Cancel block is intentionally omitted.)
        if ($Action -eq 'ScheduleRemoval') {
            $RemoveCount = [int]($Request.Body.Remove ?? 1)
            if ($RemoveCount -lt 1) { $RemoveCount = 1 }
            $DaysBefore = [int]($Request.Body.DaysBeforeRenewal ?? 3)
            if ($DaysBefore -lt 1) { $DaysBefore = 3 }

            switch ($Provider) {
                'Sherweb' {
                    $Subscription = Get-SherwebCurrentSubscription -TenantFilter $TenantFilter -SKU $SKU | Select-Object -First 1
                    if (-not $Subscription) { throw "No existing subscription with SKU '$SKU' found." }
                    $RenewalDate = $Subscription.commitmentTerm.renewalConfiguration.renewalDate
                    if (-not $RenewalDate) {
                        throw "The subscription '$($Subscription.productName)' does not have a renewal date, so a decrease cannot be scheduled at renewal."
                    }
                    $ProductName = $Subscription.productName
                    $ScheduledCommand = 'Invoke-SherwebScheduledLicenseRemoval'
                }
                'Pax8' {
                    $Subscription = Get-Pax8Subscriptions -TenantFilter $TenantFilter -SKU $SKU | Select-Object -First 1
                    if (-not $Subscription) { throw "No existing subscription with SKU '$SKU' found." }
                    # Pax8 committed products expose commitmentTerm.endDate as the renewal boundary; fall back
                    # to the subscription endDate. Month-to-month subs have neither and can be decreased now.
                    $RenewalDate = $Subscription.commitmentTerm.endDate ?? $Subscription.endDate
                    if (-not $RenewalDate) {
                        throw "The subscription '$($Subscription.productName)' has no commitment/renewal date (likely a month-to-month term), so a decrease cannot be scheduled at renewal. Use the immediate decrease action instead."
                    }
                    $ProductName = $Subscription.productName
                    $ScheduledCommand = 'Invoke-Pax8ScheduledLicenseRemoval'
                }
                default { throw "ScheduleRemoval is not supported for provider '$Provider'." }
            }

            $RunAt = ([datetimeoffset]$RenewalDate).UtcDateTime.AddDays(-$DaysBefore)
            if ($RunAt -le [datetime]::UtcNow) {
                throw "The renewal date ($(([datetimeoffset]$RenewalDate).ToString('yyyy-MM-dd'))) minus $DaysBefore day(s) is already in the past. Use the immediate decrease action instead."
            }

            $TaskBody = [pscustomobject]@{
                TenantFilter  = $TenantFilter
                Name          = "Decrease $Provider License at Renewal: $ProductName (-$RemoveCount)"
                Command       = @{
                    value = $ScheduledCommand
                    label = $ScheduledCommand
                }
                Parameters    = [pscustomobject]@{
                    SKU    = $SKU
                    Remove = $RemoveCount
                }
                ScheduledTime = [int64]([datetimeoffset]$RunAt).ToUnixTimeSeconds()
            }
            $null = Add-CIPPScheduledTask -Task $TaskBody -hidden $false -Headers $Headers
            $Result = "Scheduled a decrease of $RemoveCount license(s) for '$ProductName' on $($RunAt.ToString('yyyy-MM-dd HH:mm')) UTC, $DaysBefore day(s) before the renewal date. The decrease only executes if at least $RemoveCount license(s) are unassigned at that time."
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
