function Invoke-ListCSPReconciliation {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.Directory.Read
    .SYNOPSIS
        Per-tenant license reconciliation: paid seats vs assigned seats.
    .DESCRIPTION
        For every tenant that is mapped to a CSP provider (Pax8 or
        Sherweb), pulls Get-CIPPLicenseOverview and projects one row per
        SKU showing:
            paid     - TotalLicenses (purchased seats at the CSP)
            assigned - CountUsed (M365 users currently assigned)
            idle     - paid - assigned (positive = paying for unused seats)

        Returns a flat list sorted by idle desc so the biggest waste is
        surfaced first. Caller may pass ?tenantFilter=X to filter to a
        single tenant; otherwise scans all CSP-mapped tenants.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $TenantFilter = $Request.Query.tenantFilter
    $MappingTable = Get-CIPPTable -TableName 'CippMapping'
    $Pax8Mappings    = Get-CIPPAzDataTableEntity @MappingTable -Filter "PartitionKey eq 'Pax8Mapping'"    | Where-Object { $_.IntegrationId }
    $SherwebMappings = Get-CIPPAzDataTableEntity @MappingTable -Filter "PartitionKey eq 'SherwebMapping'" | Where-Object { $_.IntegrationId }

    $ProviderByCustomerId = @{}
    foreach ($m in $Pax8Mappings)    { $ProviderByCustomerId[$m.RowKey] = 'Pax8' }
    foreach ($m in $SherwebMappings) { if (-not $ProviderByCustomerId.ContainsKey($m.RowKey)) { $ProviderByCustomerId[$m.RowKey] = 'Sherweb' } }

    $TenantsToScan = if ($TenantFilter) {
        Get-Tenants -TenantFilter $TenantFilter -IncludeErrors
    } else {
        Get-Tenants -IncludeErrors | Where-Object { $ProviderByCustomerId.ContainsKey($_.customerId) }
    }

    $Rows = [System.Collections.Generic.List[object]]::new()
    foreach ($Tenant in $TenantsToScan) {
        $Provider = $ProviderByCustomerId[$Tenant.customerId]
        if (-not $Provider) { continue }

        try {
            $Overview = Get-CIPPLicenseOverview -TenantFilter $Tenant.defaultDomainName
        } catch {
            $Rows.Add([PSCustomObject]@{
                tenant         = $Tenant.displayName
                tenantDomain   = $Tenant.defaultDomainName
                provider       = $Provider
                skuPartNumber  = '(error)'
                paid           = 0
                assigned       = 0
                idle           = 0
                error          = $_.Exception.Message
            }) | Out-Null
            continue
        }

        foreach ($lic in $Overview) {
            $Paid     = 0; [int]::TryParse("$($lic.TotalLicenses)", [ref]$Paid)     | Out-Null
            $Assigned = 0; [int]::TryParse("$($lic.CountUsed)",     [ref]$Assigned) | Out-Null
            if ($Paid -eq 0 -and $Assigned -eq 0) { continue }
            $Rows.Add([PSCustomObject]@{
                tenant         = $Tenant.displayName
                tenantDomain   = $Tenant.defaultDomainName
                provider       = $Provider
                skuPartNumber  = "$($lic.skuPartNumber)"
                skuId          = "$($lic.skuId)"
                paid           = $Paid
                assigned       = $Assigned
                idle           = $Paid - $Assigned
            }) | Out-Null
        }
    }

    $Sorted = $Rows | Sort-Object -Property @{Expression='idle';Descending=$true}, tenant, skuPartNumber

    return [HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            rows        = @($Sorted)
            generatedAt = (Get-Date).ToString('o')
            totalRows   = ($Sorted | Measure-Object).Count
            totalIdle   = (($Sorted | Where-Object { $_.idle -gt 0 }).idle | Measure-Object -Sum).Sum
        }
    }
}
