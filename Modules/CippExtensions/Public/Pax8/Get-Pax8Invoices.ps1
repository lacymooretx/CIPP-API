function Get-Pax8Invoices {
    <#
    .SYNOPSIS
        Lists Pax8 invoices for the partner.
    .DESCRIPTION
        Pages through GET /v1/invoices. Pax8 invoices are partner-scoped
        (not per-customer); per-customer attribution lives on invoice line
        items via /v1/invoices/{id}/items. This helper returns the
        invoice headers; callers can drill into line items via the SPA.
    #>
    param(
        [int]$PageSize = 100,
        [int]$MaxPages = 50
    )

    $Headers = Get-Pax8Authentication
    $All = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $MaxPages; $i++) {
        $Uri = "https://api.pax8.com/v1/invoices?page=$i&size=$PageSize"
        $Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
        if ($Response.content) { foreach ($r in $Response.content) { $All.Add($r) } }
        $TotalPages = if ($Response.page.totalPages) { [int]$Response.page.totalPages } else { 1 }
        if (($i + 1) -ge $TotalPages) { break }
    }
    return $All.ToArray()
}
