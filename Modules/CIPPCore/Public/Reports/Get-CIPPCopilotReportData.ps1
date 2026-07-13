function Get-CIPPCopilotReportData {
    <#
    .SYNOPSIS
        Gather the Copilot Readiness Report model for a single tenant.
    .DESCRIPTION
        Assembles findings and report sections covering Microsoft 365 Copilot licensing
        and the conditional-access policies that govern Copilot access for the CIPP
        "Copilot Readiness Report". Reuses CIPP helpers where available and gathers each
        section defensively so one failure never kills the report.
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

    # ---- Copilot licensing (reuse CIPP helper) ------------------------------------
    $script:CopilotSeats = 0
    $script:CopilotSkuCount = 0
    Invoke-Section 'Copilot Licensing' {
        $lic = @(Get-CIPPLicenseOverview -TenantFilter $TenantFilter)
        $copilot = @($lic | Where-Object { "$($_.License)" -match 'Copilot' -or "$($_.skuPartNumber)" -match 'Copilot' })
        $r = New-RowList
        foreach ($l in $copilot) {
            $r.Add(@(($l.License ?? $l.skuPartNumber), $l.CountUsed, $l.CountAvailable, $l.TotalLicenses))
            $script:CopilotSeats += [int]($l.CountUsed ?? 0)
        }
        $script:CopilotSkuCount = $copilot.Count
        $st = if ($copilot.Count -gt 0) { 'pass' } else { 'info' }
        Add-Section 'Copilot Licensing' $st "$($copilot.Count) Copilot license SKU(s) found." @('License', 'Used', 'Available', 'Total') $r 'No Copilot licenses found.'
    }

    # ---- Conditional access --------------------------------------------------------
    $script:EnabledCaCount = 0
    Invoke-Section 'Conditional Access' {
        $ca = @(New-GraphGetRequest -uri "$GraphBeta/identity/conditionalAccess/policies" -tenantid $TenantFilter)
        $enabled = @($ca | Where-Object { $_.state -eq 'enabled' })
        $script:EnabledCaCount = $enabled.Count
        $r = New-RowList
        foreach ($p in $enabled) { $r.Add(@($p.displayName, $p.state)) }
        Add-Section 'Conditional Access' 'info' "$($enabled.Count) of $($ca.Count) conditional-access policies enabled; these govern Copilot access." @('Name', 'State') $r 'No enabled conditional-access policies found.'
    }

    # ---- Findings ------------------------------------------------------------------
    if ($script:CopilotSkuCount -gt 0) {
        Add-Finding 'Copilot licensing' 'pass' "$($script:CopilotSkuCount) Copilot license SKU(s) present ($($script:CopilotSeats) seat(s) in use)."
    } else {
        Add-Finding 'Copilot licensing' 'info' 'No Copilot licenses found.'
    }
    Add-Finding 'Conditional Access coverage' 'info' "$($script:EnabledCaCount) enabled conditional-access policy(ies) govern access to Copilot."

    return @{
        Title         = 'Copilot Readiness Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
