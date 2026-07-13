function Get-CIPPAdminReportData {
    <#
    .SYNOPSIS
        Gather the Administrator Report model for a single tenant.
    .DESCRIPTION
        Assembles findings and report sections covering directory role assignments and
        a focused view of privileged-role membership for the CIPP "Administrator
        Report". Each section is gathered defensively so one failure never kills the
        report.
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

    $Roles = @()
    try { $Roles = @(New-GraphGetRequest -uri "$GraphBeta/directoryRoles?`$expand=members" -tenantid $TenantFilter) } catch {}

    $PrivilegedRoleNames = @(
        'Global Administrator', 'Company Administrator', 'Privileged Role Administrator',
        'Privileged Authentication Administrator', 'Security Administrator',
        'Exchange Administrator', 'SharePoint Administrator', 'User Administrator'
    )

    # ---- Directory role assignments -----------------------------------------------
    Invoke-Section 'Directory Role Assignments' {
        $r = New-RowList
        foreach ($role in ($Roles | Where-Object { @($_.members).Count -gt 0 })) {
            $members = @($role.members)
            $assigned = ($members | Select-Object -First 8 | ForEach-Object { $_.userPrincipalName ?? $_.displayName }) -join ', '
            $r.Add(@($role.displayName, $role.description, $members.Count, $assigned))
        }
        Add-Section 'Directory Role Assignments' 'info' "$($r.Count) directory roles have members." @('Role', 'Description', 'Members', 'Assigned to') $r 'No directory role assignments found.'
    }

    # ---- Privileged roles ----------------------------------------------------------
    $script:PrivMemberCount = 0
    $script:GaCount = 0
    Invoke-Section 'Privileged Roles' {
        $r = New-RowList
        foreach ($role in ($Roles | Where-Object { $PrivilegedRoleNames -contains $_.displayName })) {
            foreach ($m in @($role.members)) {
                $r.Add(@($role.displayName, ($m.displayName ?? $m.userPrincipalName), $m.userPrincipalName))
                $script:PrivMemberCount++
                if ($role.displayName -match 'Global Administrator|Company Administrator') { $script:GaCount++ }
            }
        }
        $st = if ($script:PrivMemberCount -gt 10) { 'warn' } else { 'info' }
        Add-Section 'Privileged Roles' $st "$($script:PrivMemberCount) privileged-role membership(s) across highly sensitive directory roles." @('Role', 'Member', 'UPN') $r 'No privileged-role members found.'
    }

    # ---- Findings ------------------------------------------------------------------
    $gaStatus = if ($script:GaCount -ge 2 -and $script:GaCount -le 5) { 'pass' } else { 'warn' }
    Add-Finding 'Global Administrators' $gaStatus "$($script:GaCount) account(s) hold Global Administrator (best practice: 2-5)."

    $privStatus = if ($script:PrivMemberCount -gt 10) { 'warn' } else { 'pass' }
    Add-Finding 'Privileged role membership' $privStatus "$($script:PrivMemberCount) privileged-role membership(s) assigned$(if ($script:PrivMemberCount -gt 10) { ' - review for least-privilege' })."

    return @{
        Title         = 'Administrator Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
