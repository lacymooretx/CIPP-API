function Invoke-ListCSPOrderStatus {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Directory.Read
    .SYNOPSIS
        Poll an order/tracking id returned by /api/ExecCSPLicense (NewSub).
    .DESCRIPTION
        Pax8: Get-Pax8OrderStatus returns the order with .status (e.g.,
        PENDING / PROCESSING / COMPLETED / FAILED).
        Sherweb: Get-SherwebOrderStatus returns a tracking object whose
        shape varies by request type.
        Caller passes ?provider=Pax8|Sherweb&trackingId=... — the SPA
        already has both values from the ExecCSPLicense response.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $Provider   = $Request.Query.provider
    $TrackingId = $Request.Query.trackingId

    if ([string]::IsNullOrEmpty($Provider) -or [string]::IsNullOrEmpty($TrackingId)) {
        return [HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = 'Both `provider` and `trackingId` query params are required.'
        }
    }

    try {
        switch ($Provider) {
            'Pax8'    { $Result = Get-Pax8OrderStatus -OrderId $TrackingId }
            'Sherweb' { $Result = Get-SherwebOrderStatus -RequestTrackingId $TrackingId }
            default   { throw "Unknown provider: $Provider" }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $Result = "Failed to fetch order status: $($_.Exception.Message)"
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body       = $Result
    }
}
