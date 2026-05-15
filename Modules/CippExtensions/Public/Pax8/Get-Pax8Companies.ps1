function Get-Pax8Companies {
    <#
    .SYNOPSIS
        Returns the partner's Pax8 companies (paginated).
    .DESCRIPTION
        Pages through GET /v1/companies until exhausted. Pax8 uses
        zero-indexed `page` + `size` (max 200) and returns
        { content: [...], page: { totalPages, ... } } shapes.
    #>
    [CmdletBinding()]
    param(
        [int]$PageSize = 200,
        [int]$MaxPages = 100
    )

    $Headers = Get-Pax8Authentication
    $Companies = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $MaxPages; $i++) {
        $Uri = "https://api.pax8.com/v1/companies?page=$i&size=$PageSize"
        $Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
        if ($Response.content) {
            foreach ($c in $Response.content) { $Companies.Add($c) }
        }
        $TotalPages = if ($Response.page.totalPages) { [int]$Response.page.totalPages } else { 1 }
        if (($i + 1) -ge $TotalPages) { break }
    }

    return $Companies.ToArray()
}
