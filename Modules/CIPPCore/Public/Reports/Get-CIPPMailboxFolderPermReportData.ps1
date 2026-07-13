function Get-CIPPMailboxFolderPermReportData {
    <#
    .SYNOPSIS
        Gather the Mailbox Permissions Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "Mailbox Permissions Report". True per-folder permission
        enumeration (Get-MailboxFolderPermission per mailbox) is too heavy for a live
        report, so mailbox-level delegate permissions (Get-CIPPMailboxPermissionReport)
        are used as the practical stand-in. Returns a report model consumable by
        Write-CippReportHtml. Every section is gathered defensively - a failure in one
        section is captured and the rest of the report still renders.
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

    # ---- Mailbox permissions ------------------------------------------------------
    Invoke-Section 'Mailbox Permissions' {
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
        Add-Finding 'Permission entries' 'info' "$entries mailbox permission entries are configured across the tenant."
        if ($fullAccess -gt 0) {
            Add-Finding 'Full Access / external delegation' 'warn' "$fullAccess non-owner FullAccess grant(s) exist - confirm each delegate (and any external principal) is still authorised."
        } else {
            Add-Finding 'Full Access / external delegation' 'pass' 'No non-owner FullAccess mailbox grants found.'
        }
        Add-Section 'Mailbox Permissions' $st "$entries permission entries across $($perm.Count) mailboxes ($fullAccess FullAccess grant(s))." @('Mailbox', 'User', 'Permissions') $r 'No mailbox permissions found.'
    }

    # ---- scope note (Html section) ------------------------------------------------
    $Sections.Add(@{
            Title       = 'About This Report'
            Status      = 'info'
            Description = 'Scope of the permissions shown above.'
            Html        = "<p>This report lists <strong>mailbox-level</strong> delegate permissions (Full Access, Send As and Send on Behalf equivalents) for every mailbox in the tenant. Detailed <strong>per-folder</strong> permissions (for example individual Calendar, Contacts or subfolder sharing) are not enumerated live because that scan is resource intensive across a full tenant. Folder-level permission detail for a specific mailbox is available on request.</p>"
        })

    return @{
        Title         = 'Mailbox Permissions Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
