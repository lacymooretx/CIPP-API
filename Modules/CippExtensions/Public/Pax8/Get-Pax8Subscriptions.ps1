function Get-Pax8Subscriptions {
    <#
    .SYNOPSIS
        Lists active Pax8 subscriptions for a tenant or company.
    .DESCRIPTION
        Resolves TenantFilter -> Pax8 companyId via the Pax8Mapping table,
        then pages through GET /v1/subscriptions?companyId=...&status=Active.
        Project results into a shape the existing CIPP SPA license tables
        (built for Sherweb) can consume directly:
            sku         = productId (UUID; used by the AddUser picker as value)
            productName = product display name
            quantity    = current seat count
        Other Pax8-native fields (productId, billingTerm, status, price,
        billingStart, endDate) are preserved on the same object.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$TenantFilter,
        [string]$CompanyId,
        [string]$SKU,
        [string]$ProductName,
        [int]$PageSize = 200,
        [int]$MaxPages = 50
    )

    if ($TenantFilter) {
        $TenantFilter = (Get-Tenants -TenantFilter $TenantFilter).customerId
        $CompanyId = Get-ExtensionMapping -Extension 'Pax8' | Where-Object { $_.RowKey -eq $TenantFilter } | Select-Object -ExpandProperty IntegrationId
    }
    if ([string]::IsNullOrEmpty($CompanyId)) {
        throw 'No Pax8 mapping found'
    }

    $Headers = Get-Pax8Authentication
    $All = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $MaxPages; $i++) {
        $Uri = "https://api.pax8.com/v1/subscriptions?companyId=$CompanyId&status=Active&page=$i&size=$PageSize"
        $Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
        if ($Response.content) {
            foreach ($s in $Response.content) {
                $All.Add([PSCustomObject]@{
                        id            = $s.id
                        sku           = $s.productId
                        productId     = $s.productId
                        productName   = $s.productName
                        quantity      = $s.quantity
                        price         = $s.price
                        billingTerm   = $s.billingTerm
                        status        = $s.status
                        billingStart  = $s.billingStart
                        startDate     = $s.startDate
                        endDate       = $s.endDate
                        partnerCost   = $s.partnerCost
                        currencyCode  = $s.currencyCode
                    })
            }
        }
        $TotalPages = if ($Response.page.totalPages) { [int]$Response.page.totalPages } else { 1 }
        if (($i + 1) -ge $TotalPages) { break }
    }

    if ($SKU)         { return $All | Where-Object { $_.sku -eq $SKU -or $_.productId -eq $SKU } }
    if ($ProductName) { return $All | Where-Object { $_.productName -eq $ProductName } }
    return $All.ToArray()
}
