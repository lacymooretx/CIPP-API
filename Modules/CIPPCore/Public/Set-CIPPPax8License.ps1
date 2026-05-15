function Set-CIPPPax8License {
    <#
    .SYNOPSIS
        Thin convenience wrapper around Set-Pax8Subscription, mirroring
        Set-CIPPSherwebLicense. Used by the AddUser flow when a tenant is
        Pax8-mapped and the new-user form selected a Pax8 license to order.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$tenantFilter,

        [Parameter(Mandatory = $true)]
        [string]$SKUid,

        [int]$Quantity,
        [int]$Add,
        [int]$Remove,
        $Headers
    )
    Set-Pax8Subscription -SKU $SKUid -Quantity $Quantity -Add $Add -Remove $Remove -TenantFilter $tenantFilter -Headers $Headers
}
