function Get-CIPPAccountsReportData {
    <#
    .SYNOPSIS
        Gather the Accounts & Licensing Report model for a single tenant.
    .DESCRIPTION
        Assembles an account summary and a licensed-user section plus executive
        findings for the CIPP "Accounts & Licensing Report" from live tenant data
        (Microsoft Graph via New-GraphGetRequest). Returns a report model
        consumable by Write-CippReportHtml. Every section is gathered defensively
        - a failure in one section is captured and the rest of the report still
        renders.
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

    $Users = @()
    try { $Users = @(New-GraphGetRequest -uri "$GraphBeta/users?`$select=id,displayName,userPrincipalName,accountEnabled,userType,assignedLicenses,createdDateTime&`$top=999" -tenantid $TenantFilter) } catch {}

    $total = $Users.Count
    $enabled = @($Users | Where-Object { $_.accountEnabled }).Count
    $disabled = $total - $enabled
    $licensed = @($Users | Where-Object { @($_.assignedLicenses).Count -gt 0 }).Count
    $unlicensed = $total - $licensed
    $guests = @($Users | Where-Object { "$($_.userType)" -eq 'Guest' }).Count
    $members = @($Users | Where-Object { "$($_.userType)" -eq 'Member' }).Count

    # ---- Summary ------------------------------------------------------------------
    Invoke-Section 'Summary' {
        $r = New-RowList
        $r.Add(@('Total users', $total))
        $r.Add(@('Enabled', $enabled))
        $r.Add(@('Disabled', $disabled))
        $r.Add(@('Licensed', $licensed))
        $r.Add(@('Unlicensed', $unlicensed))
        $r.Add(@('Guests', $guests))
        $r.Add(@('Members', $members))
        Add-Section 'Summary' 'info' 'Account and licensing totals for the tenant.' @('Property', 'Value') $r
    }

    # ---- Licensed Users -----------------------------------------------------------
    Invoke-Section 'Licensed Users' {
        $r = New-RowList
        foreach ($u in ($Users | Where-Object { @($_.assignedLicenses).Count -gt 0 })) {
            $r.Add(@($u.displayName, $u.userPrincipalName, [bool]$u.accountEnabled, $u.userType, @($u.assignedLicenses).Count))
        }
        Add-Section 'Licensed Users' 'info' "$licensed licensed user(s)." @('Display name', 'UPN', 'Enabled', 'Type', 'License count') $r 'No licensed users found.'
    }

    # ---- Findings -----------------------------------------------------------------
    Add-Finding 'Total accounts' 'info' "$total user account(s): $enabled enabled, $disabled disabled."
    Add-Finding 'Licensed accounts' 'info' "$licensed of $total account(s) are licensed."

    $guestPct = if ($total -gt 0) { [math]::Round(100 * $guests / $total) } else { 0 }
    if ($guestPct -gt 25) {
        Add-Finding 'Guest accounts' 'warn' "Guests make up $guestPct% of accounts ($guests/$total)."
    }
    $enabledUnlicensed = @($Users | Where-Object { $_.accountEnabled -and @($_.assignedLicenses).Count -eq 0 }).Count
    if ($enabledUnlicensed -gt 10) {
        Add-Finding 'Enabled unlicensed accounts' 'warn' "$enabledUnlicensed enabled account(s) have no license assigned."
    }

    return @{
        Title         = 'Accounts & Licensing Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
