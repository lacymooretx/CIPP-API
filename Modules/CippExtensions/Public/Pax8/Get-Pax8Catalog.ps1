function Get-Pax8Catalog {
    <#
    .SYNOPSIS
        Lists products available to the partner from Pax8.
    .DESCRIPTION
        Pax8's product catalog is partner-scoped (not per-company), unlike
        Sherweb. We accept a TenantFilter for call-site parity but it only
        validates the tenant has a Pax8 mapping; the catalog itself is the
        same global partner catalog. Results are projected with sku set to
        the productId UUID so the AddUser SKU picker (which binds to `sku`)
        works directly.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$CompanyId,
        [string]$TenantFilter,
        [int]$PageSize = 200,
        [int]$MaxPages = 50,
        [string]$VendorName
    )

    if ($TenantFilter) {
        $TenantFilter = (Get-Tenants -TenantFilter $TenantFilter).customerId
        $CompanyId = Get-ExtensionMapping -Extension 'Pax8' | Where-Object { $_.RowKey -eq $TenantFilter } | Select-Object -ExpandProperty IntegrationId
        if ([string]::IsNullOrEmpty($CompanyId)) {
            throw 'No Pax8 mapping found'
        }
    }

    $Headers = Get-Pax8Authentication
    $All = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $MaxPages; $i++) {
        $QS = "page=$i&size=$PageSize"
        if ($VendorName) { $QS += "&vendorName=$([uri]::EscapeDataString($VendorName))" }
        $Uri = "https://api.pax8.com/v1/products?$QS"
        $Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
        if ($Response.content) {
            foreach ($p in $Response.content) {
                $All.Add([PSCustomObject]@{
                        id              = $p.id
                        sku             = $p.id
                        productId       = $p.id
                        productName     = $p.name
                        vendorName      = $p.vendorName
                        vendorSku       = $p.vendorSku
                        productSku      = $p.sku
                        shortDescription= $p.shortDescription
                        requiresCommitment = $p.requiresCommitment
                    })
            }
        }
        $TotalPages = if ($Response.page.totalPages) { [int]$Response.page.totalPages } else { 1 }
        if (($i + 1) -ge $TotalPages) { break }
    }
    return $All.ToArray()
}
