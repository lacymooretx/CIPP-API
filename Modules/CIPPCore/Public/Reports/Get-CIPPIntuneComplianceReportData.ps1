function Get-CIPPIntuneComplianceReportData {
    <#
    .SYNOPSIS
        Gather the Intune Compliance Report model for a single tenant.
    .DESCRIPTION
        Assembles managed-device and compliance-policy sections plus executive
        findings for the CIPP "Intune Compliance Report" from live tenant data
        (CIPP report helpers with a Microsoft Graph fallback). Returns a report
        model consumable by Write-CippReportHtml. Every section is gathered
        defensively - a failure in one section is captured and the rest of the
        report still renders.
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

    # Managed devices - prefer the CIPP report helper, fall back to live Graph.
    $Devices = @()
    try { $Devices = @(Get-CIPPManagedDevicesReport -TenantFilter $TenantFilter) } catch {
        try { $Devices = @(New-GraphGetRequest -uri "$GraphBeta/deviceManagement/managedDevices?`$top=999" -tenantid $TenantFilter) } catch {}
    }

    # Compliance policies - prefer the CIPP report helper, fall back to live Graph.
    $Policies = @()
    try { $Policies = @(Get-CIPPIntuneCompliancePolicyReport -TenantFilter $TenantFilter) } catch {
        try { $Policies = @(New-GraphGetRequest -uri "$GraphBeta/deviceManagement/deviceCompliancePolicies?`$expand=assignments" -tenantid $TenantFilter) } catch {}
    }

    # ---- Devices ------------------------------------------------------------------
    Invoke-Section 'Devices' {
        $total = $Devices.Count
        $compliant = @($Devices | Where-Object { "$($_.complianceState)" -eq 'compliant' }).Count
        $nonCompliant = @($Devices | Where-Object { "$($_.complianceState)" -and "$($_.complianceState)" -ne 'compliant' }).Count
        $pct = if ($total -gt 0) { [math]::Round(100 * $compliant / $total) } else { 0 }
        $st = if ($pct -ge 95) { 'pass' } elseif ($pct -ge 80) { 'warn' } else { 'fail' }
        Add-Finding 'Device compliance' $st "$pct% of managed devices are compliant ($compliant/$total)."
        $stNC = if ($nonCompliant -eq 0) { 'pass' } else { 'warn' }
        Add-Finding 'Non-compliant devices' $stNC $(if ($nonCompliant) { "$nonCompliant managed device(s) are not compliant." } else { 'All managed devices are compliant.' })
        $r = New-RowList
        foreach ($d in $Devices) {
            $r.Add(@($d.deviceName, $d.userPrincipalName, $d.operatingSystem, $d.osVersion, $d.complianceState, $d.managedDeviceOwnerType, $d.lastSyncDateTime))
        }
        Add-Section 'Devices' $st "$total managed devices, $pct% compliant." @('Device', 'User', 'OS', 'OS Version', 'Compliance state', 'Ownership', 'Last sync') $r 'No managed devices found.'
    }

    # ---- Compliance Policies ------------------------------------------------------
    Invoke-Section 'Compliance Policies' {
        $r = New-RowList
        foreach ($p in $Policies) {
            $platform = if ($p.PolicyTypeName) { $p.PolicyTypeName }
            elseif ($p.'@odata.type') { ($p.'@odata.type' -replace '#microsoft.graph.', '') }
            else { '' }
            $assigned = if ($null -ne $p.PolicyAssignment) { $p.PolicyAssignment }
            elseif ($p.assignments) { "$(@($p.assignments).Count) assignment(s)" }
            else { '' }
            $r.Add(@($p.displayName, $platform, $assigned))
        }
        Add-Section 'Compliance Policies' 'info' "$($Policies.Count) compliance policies." @('Policy', 'Platform', 'Assigned') $r 'No compliance policies found.'
    }

    return @{
        Title         = 'Intune Compliance Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
