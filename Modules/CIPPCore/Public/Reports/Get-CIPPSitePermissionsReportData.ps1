function Get-CIPPSitePermissionsReportData {
    <#
    .SYNOPSIS
        Gather the Site Permissions Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "Site Permissions Report" from live tenant data
        (Microsoft Graph via New-GraphGetRequest). Enumerates SharePoint sites so
        their access surface can be reviewed. Returns a report model consumable by
        Write-CippReportHtml. Every section is gathered defensively - a failure in
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
        $sites = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/sites?search=*' -tenantid $TenantFilter -AsApp $true | Select-Object -First 50)
        $r = New-RowList
        foreach ($s in $sites) {
            $webTemplate = if ($s.PSObject.Properties.Name -contains 'webTemplate') { $s.webTemplate } else { $s.sharepointIds.webId }
            $r.Add(@(($s.displayName ?? $s.name), $s.webUrl, $s.createdDateTime, $webTemplate))
        }
        Add-Finding 'SharePoint sites' 'info' "$($sites.Count) site(s) enumerated (bounded to the first 50)."
        Add-Section 'SharePoint Sites' 'info' "$($sites.Count) SharePoint sites (first 50)." @('Site', 'URL', 'Created', 'Web template') $r 'No sites returned.'
    }

    # ---- Permission note -----------------------------------------------------------
    Invoke-Section 'Site Permission Principals' {
        $r = New-RowList
        $note = 'Per-site permission principals (users, groups, and sharing links granted access to each site) require the Sites.FullControl.All Graph permission and are not enumerated in this report by default. This can be expanded on request once elevated SharePoint permissions are granted to the CIPP application.'
        $r.Add(@($note))
        Add-Section 'Site Permission Principals' 'info' 'How to obtain per-site permission detail.' @('Html') $r $note
    }

    return @{
        Title         = 'Site Permissions Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
