function Get-Pax8OrderStatus {
    <#
    .SYNOPSIS
        Returns a Pax8 order (by orderId) for status polling after a buy/cancel.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrderId
    )
    $Headers = Get-Pax8Authentication
    $Uri = "https://api.pax8.com/v1/orders/$OrderId"
    return Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
}
