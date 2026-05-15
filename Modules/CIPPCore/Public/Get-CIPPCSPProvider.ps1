function Get-CIPPCSPProvider {
    <#
    .SYNOPSIS
        Returns which CSP integration owns a given tenant, based on the
        Pax8Mapping and SherwebMapping tables.
    .DESCRIPTION
        Lookup order is Pax8 first, Sherweb second. Returns the string
        'Pax8', 'Sherweb', or $null when neither mapping has the tenant.

        Callers should use this from the /api/ListCSPLicenses,
        /api/ListCSPsku, /api/ExecCSPLicense, and AddUser dispatchers
        so a single CIPP UI/endpoint can talk to whichever CSP a partner
        has wired up for that specific tenant.
    .PARAMETER TenantFilter
        Either a CIPP defaultDomainName, customerId GUID, or initial domain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )
    $CustomerId = (Get-Tenants -TenantFilter $TenantFilter).customerId
    if ([string]::IsNullOrEmpty($CustomerId)) { return $null }

    $Pax8 = Get-ExtensionMapping -Extension 'Pax8' | Where-Object { $_.RowKey -eq $CustomerId } | Select-Object -First 1
    if ($Pax8 -and $Pax8.IntegrationId) { return 'Pax8' }

    $Sherweb = Get-ExtensionMapping -Extension 'Sherweb' | Where-Object { $_.RowKey -eq $CustomerId } | Select-Object -First 1
    if ($Sherweb -and $Sherweb.IntegrationId) { return 'Sherweb' }

    return $null
}
