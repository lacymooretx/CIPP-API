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
                        commitmentTerm = $s.commitmentTerm
                        partnerCost   = $s.partnerCost
                        currencyCode  = $s.currencyCode
                    })
            }
        }
        $TotalPages = if ($Response.page.totalPages) { [int]$Response.page.totalPages } else { 1 }
        if (($i + 1) -ge $TotalPages) { break }
    }

    # Enrich subs that came back from Pax8 with productName=null. Pax8's
    # /v1/subscriptions endpoint omits productName for many older / vendor-
    # specific rows. Fetch the partner catalog once (cached on $script: scope
    # for the lifetime of this PS process) and resolve missing names from it.
    if ($All | Where-Object { -not $_.productName }) {
        if (-not $script:Pax8ProductNameMap) {
            try {
                $script:Pax8ProductNameMap = @{}
                $Catalog = Get-Pax8Catalog
                foreach ($p in $Catalog) {
                    if ($p.id) { $script:Pax8ProductNameMap[[string]$p.id] = $p.productName }
                }
                Write-Information ("Pax8 catalog cache populated with {0} products" -f $script:Pax8ProductNameMap.Count)
            } catch {
                Write-Information "Pax8 catalog fetch for productName enrichment failed: $($_.Exception.Message)"
                $script:Pax8ProductNameMap = @{}
            }
        }
        foreach ($s in $All) {
            if (-not $s.productName -and $s.productId) {
                $key = [string]$s.productId
                if ($script:Pax8ProductNameMap.ContainsKey($key)) {
                    $s.productName = $script:Pax8ProductNameMap[$key]
                }
            }
        }
    }

    if ($SKU)         { return $All | Where-Object { $_.sku -eq $SKU -or $_.productId -eq $SKU } }
    if ($ProductName) { return $All | Where-Object { $_.productName -eq $ProductName } }
    return $All.ToArray()
}
