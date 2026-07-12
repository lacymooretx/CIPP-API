function Get-CIPPAccessReportData {
    <#
    .SYNOPSIS
        Gather the Mailbox Access Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "Mailbox Access Report" from cached tenant data
        (CIPP mailbox / calendar permission reports, with Exchange Online fallback).
        Returns a report model consumable by Write-CippReportHtml. Every section is
        gathered defensively - a failure in one section is captured and the rest of
        the report still renders.
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

    # ---- Mailbox delegate access --------------------------------------------------
    Invoke-Section 'Mailbox Delegate Access' {
        $r = New-RowList
        $entries = 0
        $fullAccess = 0
        $perm = @(Get-CIPPMailboxPermissionReport -TenantFilter $TenantFilter)
        foreach ($mbx in $perm) {
            $mbxName = ($mbx.MailboxDisplayName ?? $mbx.MailboxUPN)
            foreach ($p in @($mbx.Permissions)) {
                $rights = "$($p.AccessRights)"
                $r.Add(@($mbxName, $p.User, $rights))
                $entries++
                if ($rights -match 'FullAccess') { $fullAccess++ }
            }
        }
        $st = if ($fullAccess -gt 0) { 'warn' } else { 'info' }
        Add-Finding 'Delegate access entries' 'info' "$entries delegate mailbox permission entries are configured across the tenant."
        if ($fullAccess -gt 0) {
            Add-Finding 'Full Access delegation' 'warn' "$fullAccess non-owner FullAccess grant(s) exist - review that each delegate is still required."
        } else {
            Add-Finding 'Full Access delegation' 'pass' 'No non-owner FullAccess mailbox grants found.'
        }
        Add-Section 'Mailbox Delegate Access' $st "$entries delegate permission entries across $($perm.Count) mailboxes ($fullAccess FullAccess grant(s))." @('Mailbox', 'User', 'Access rights') $r 'No delegate mailbox permissions found.'
    }

    # ---- Calendar permissions -----------------------------------------------------
    Invoke-Section 'Calendar Permissions' {
        $r = New-RowList
        $entries = 0
        $cal = @(Get-CIPPCalendarPermissionReport -TenantFilter $TenantFilter)
        foreach ($c in $cal) {
            $calName = ($c.CalendarDisplayName ?? $c.CalendarUPN)
            foreach ($p in @($c.Permissions)) {
                $r.Add(@($calName, $p.User, "$($p.AccessRights)"))
                $entries++
            }
        }
        Add-Section 'Calendar Permissions' 'info' "$entries non-default calendar permission entries across $($cal.Count) calendars." @('Mailbox', 'User', 'Access') $r 'No non-default calendar permissions found.'
    }

    return @{
        Title         = 'Mailbox Access Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
