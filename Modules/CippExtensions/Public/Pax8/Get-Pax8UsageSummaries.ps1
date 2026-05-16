function Get-Pax8UsageSummaries {
    <#
    .SYNOPSIS
        Lists Pax8 usage summaries for a subscription, or for all subs of a
        tenant when called with -TenantFilter.
    .DESCRIPTION
        Pax8 usage summaries live under /v1/subscriptions/{id}/usage-summaries.
        Metered Microsoft Azure plans and similar consumption products generate
        usage summary rows monthly.

        When given a TenantFilter (and no SubscriptionId), this helper first
        pulls all active subscriptions for that tenant and aggregates usage
        across them - handy for "what is this customer consuming this month"
        review pages.
    #>
    param(
        [string]$TenantFilter,
        [string]$SubscriptionId,
        [int]$PageSize = 100,
        [int]$MaxPages = 25
    )

    $Headers = Get-Pax8Authentication

    $SubIds = @()
    if ($SubscriptionId) {
        $SubIds = @($SubscriptionId)
    } elseif ($TenantFilter) {
        $Subs = Get-Pax8Subscriptions -TenantFilter $TenantFilter
        $SubIds = @($Subs | Where-Object { $_.id } | ForEach-Object { $_.id })
    } else {
        throw 'Provide -SubscriptionId or -TenantFilter.'
    }

    $All = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $SubIds) {
        for ($i = 0; $i -lt $MaxPages; $i++) {
            $Uri = "https://api.pax8.com/v1/subscriptions/$id/usage-summaries?page=$i&size=$PageSize"
            try {
                $Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
            } catch {
                # 404 simply means this sub has no usage summaries (most non-metered subs)
                break
            }
            if ($Response.content) {
                foreach ($u in $Response.content) {
                    $u | Add-Member -NotePropertyName 'subscriptionId' -NotePropertyValue $id -Force
                    $All.Add($u)
                }
            }
            $TotalPages = if ($Response.page.totalPages) { [int]$Response.page.totalPages } else { 1 }
            if (($i + 1) -ge $TotalPages) { break }
        }
    }
    return $All.ToArray()
}
