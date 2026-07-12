function Get-CIPPLicenseReportData {
    <#
    .SYNOPSIS
        Gather the License Report model for a single tenant.
    .DESCRIPTION
        Assembles the license-inventory section plus executive findings for the
        CIPP "License Report" from live tenant data (Get-CIPPLicenseOverview).
        Returns a report model consumable by Write-CippReportHtml. Every section
        is gathered defensively - a failure in one section is captured and the
        rest of the report still renders.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )

    $GraphBeta = 'https://graph.microsoft.com/beta'
    $Findings = [System.Collections.Generic.List[object]]::new()
    $Sections = [System.Collections.Generic.List[object]]::new()

    function Add-Finding($Title, $Status, $Detail) {
        $Findings.Add(@{ Title = $Title; Status = $Status; Detail = $Detail })
    }
    # $Rows must be a List[object] whose elements are per-row cell arrays (no flattening).
    function Add-Section($Title, $Status, $Description, $Columns, $Rows, $Empty) {
        $Sections.Add(@{ Title = $Title; Status = $Status; Description = $Description; Columns = $Columns; Rows = $Rows; Empty = $Empty })
    }
    function New-RowList { , [System.Collections.Generic.List[object]]::new() }
    # run a section builder defensively so one failure never kills the report
    function Invoke-Section($Name, [scriptblock]$Builder) {
        try { & $Builder } catch {
            $r = New-RowList; $r.Add(@("$($_.Exception.Message)"))
            Add-Section $Name 'warn' 'This section could not be retrieved.' @('Error') $r 'Data unavailable.'
        }
    }

    # ---- shared data gathered up front (read-only in sections) ---------------------
    $Org = $null
    try { $Org = New-GraphGetRequest -uri "$GraphBeta/organization" -tenantid $TenantFilter | Select-Object -First 1 } catch {}
    $TenantName = if ($Org.displayName) { $Org.displayName } else { $TenantFilter }
    $DefaultDomain = ($Org.verifiedDomains | Where-Object { $_.isDefault }).name
    if (-not $DefaultDomain) { $DefaultDomain = $TenantFilter }

    $Licenses = @()
    try { $Licenses = @(Get-CIPPLicenseOverview -TenantFilter $TenantFilter) } catch {}

    # ---- Licenses -----------------------------------------------------------------
    Invoke-Section 'Licenses' {
        $totalAssigned = 0
        $overAssigned = [System.Collections.Generic.List[object]]::new()
        $underUsed = [System.Collections.Generic.List[object]]::new()
        $r = New-RowList
        foreach ($l in $Licenses) {
            $used = [int]("$($l.CountUsed)" -as [int])
            $available = [int]("$($l.CountAvailable)" -as [int])
            $total = [int]("$($l.TotalLicenses)" -as [int])
            $name = if ($l.License) { $l.License } else { $l.skuPartNumber }
            $util = if ($total -gt 0) { [math]::Round(100 * $used / $total) } else { 0 }
            $totalAssigned += $used
            if ($available -lt 0) { $overAssigned.Add([pscustomobject]@{ Name = $name; Available = $available }) }
            if ($available -gt 0) { $underUsed.Add([pscustomobject]@{ Name = $name; Available = $available }) }
            $r.Add(@($name, $used, $available, $total, "$util%"))
        }
        $st = if ($overAssigned.Count -gt 0) { 'warn' } else { 'info' }
        Add-Section 'Licenses' $st "$($Licenses.Count) license SKUs, $totalAssigned assigned in total." @('License', 'Used', 'Available', 'Total', 'Utilisation%') $r 'No licenses found.'

        Add-Finding 'Total assigned licenses' 'info' "$totalAssigned license(s) assigned across $($Licenses.Count) SKU(s)."
        if ($overAssigned.Count -gt 0) {
            $worst = $overAssigned | Sort-Object Available | Select-Object -First 1
            Add-Finding 'Over-assigned licenses' 'warn' "$($overAssigned.Count) SKU(s) are over-assigned (negative availability); most over-assigned: $($worst.Name) ($($worst.Available))."
        }
        if ($underUsed.Count -gt 0) {
            $most = $underUsed | Sort-Object Available -Descending | Select-Object -First 1
            Add-Finding 'Unused licenses' 'warn' "$($underUsed.Count) SKU(s) have unused seats; most under-utilised: $($most.Name) ($($most.Available) available)."
        }
    }

    return @{
        Title         = 'License Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
