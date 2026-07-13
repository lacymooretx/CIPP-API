function Get-CIPPSharePointUsageReportData {
    <#
    .SYNOPSIS
        Gather the SharePoint & OneDrive Usage Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "SharePoint & OneDrive Usage Report" from cached CIPP
        reporting data (Get-CIPPSharePointSiteUsageReport / Get-CIPPOneDriveUsageReport)
        and Microsoft Graph (New-GraphGetRequest). Returns a report model consumable
        by Write-CippReportHtml. Every section is gathered defensively - a failure in
        one section is captured and the rest of the report still renders.
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

    # ---- SharePoint Sites ----------------------------------------------------------
    Invoke-Section 'SharePoint Sites' {
        $sites = @(Get-CIPPSharePointSiteUsageReport -TenantFilter $TenantFilter)
        $r = New-RowList
        $overCap = 0
        $totalUsed = 0.0
        foreach ($s in $sites) {
            $used = [double]($s.storageUsedInGigabytes ?? 0)
            $alloc = [double]($s.storageAllocatedInGigabytes ?? 0)
            $totalUsed += $used
            if ($alloc -gt 0 -and ($used / $alloc) -ge 0.9) { $overCap++ }
            $r.Add(@($s.displayName, ($s.ownerDisplayName ?? $s.ownerPrincipalName), "$used GB", "$alloc GB", $s.fileCount, $s.lastActivityDate))
        }
        if ($overCap -gt 0) { Add-Finding 'SharePoint storage saturation' 'warn' "$overCap site(s) are using 90% or more of their allocated storage." }
        Add-Finding 'SharePoint sites' 'info' "$($sites.Count) SharePoint site(s), $([math]::Round($totalUsed, 2)) GB total storage used."
        $st = if ($overCap -gt 0) { 'warn' } else { 'info' }
        Add-Section 'SharePoint Sites' $st "$($sites.Count) SharePoint sites, $([math]::Round($totalUsed, 2)) GB used; $overCap at 90%+ of allocation." @('Site', 'Owner', 'Storage used', 'Storage allocated', 'Files', 'Last activity') $r 'No SharePoint site usage data available.'
    }

    # ---- OneDrive ------------------------------------------------------------------
    Invoke-Section 'OneDrive' {
        $drives = @(Get-CIPPOneDriveUsageReport -TenantFilter $TenantFilter)
        $r = New-RowList
        $overCap = 0
        $totalUsed = 0.0
        foreach ($d in $drives) {
            $used = [double]($d.storageUsedInGigabytes ?? 0)
            $alloc = [double]($d.storageAllocatedInGigabytes ?? 0)
            $totalUsed += $used
            if ($alloc -gt 0 -and ($used / $alloc) -ge 0.9) { $overCap++ }
            $r.Add(@(($d.ownerDisplayName ?? $d.ownerPrincipalName), $d.webUrl, "$used GB", $d.fileCount, $d.lastActivityDate))
        }
        if ($overCap -gt 0) { Add-Finding 'OneDrive storage saturation' 'warn' "$overCap OneDrive(s) are using 90% or more of their allocated storage." }
        Add-Finding 'OneDrive drives' 'info' "$($drives.Count) OneDrive(s), $([math]::Round($totalUsed, 2)) GB total storage used."
        $st = if ($overCap -gt 0) { 'warn' } else { 'info' }
        Add-Section 'OneDrive' $st "$($drives.Count) OneDrive accounts, $([math]::Round($totalUsed, 2)) GB used; $overCap at 90%+ of allocation." @('Owner', 'URL', 'Storage used', 'Files', 'Last activity') $r 'No OneDrive usage data available.'
    }

    return @{
        Title         = 'SharePoint & OneDrive Usage Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
