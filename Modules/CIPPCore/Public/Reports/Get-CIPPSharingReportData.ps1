function Get-CIPPSharingReportData {
    <#
    .SYNOPSIS
        Gather the External Sharing Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "External Sharing Report" from live tenant data
        (Microsoft Graph via New-GraphGetRequest). Surfaces the tenant-level
        SharePoint/OneDrive external sharing capability and enumerates sites so
        external exposure can be assessed. Returns a report model consumable by
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

    # ---- Tenant Sharing Settings ---------------------------------------------------
    Invoke-Section 'Tenant Sharing Settings' {
        $spo = New-GraphGetRequest -uri "$GraphBeta/admin/sharepoint/settings" -tenantid $TenantFilter -AsApp $true
        $cap = "$($spo.sharingCapability)"
        $r = New-RowList
        $r.Add(@('Sharing capability', $cap))
        $r.Add(@('Sharing domain restriction mode', $spo.sharingDomainRestrictionMode))
        $r.Add(@('Default sharing link type', $spo.defaultSharingLinkType))
        $r.Add(@('Default link permission', $spo.defaultLinkPermission))
        $r.Add(@('Resharing by external users enabled', [bool]$spo.isResharingByExternalUsersEnabled))
        $r.Add(@('Anonymous link expiration (days)', $spo.sharingLinkDefaultExpirationInDays))
        $r.Add(@('Site creation disabled', [bool]$spo.isSiteCreationDisabled))

        switch -Wildcard ($cap) {
            'externalUserAndGuestSharing' {
                Add-Finding 'External sharing capability' 'fail' 'Tenant allows anonymous ("Anyone") sharing links (ExternalUserAndGuestSharing). This exposes content without sign-in.'
                $st = 'fail'
            }
            'externalUserSharingOnly' {
                Add-Finding 'External sharing capability' 'warn' 'Tenant allows sharing with new and existing external guests (ExternalUserSharingOnly). Guests must authenticate.'
                $st = 'warn'
            }
            'existingExternalUserSharingOnly' {
                Add-Finding 'External sharing capability' 'warn' 'Tenant allows sharing with existing external guests only (ExistingExternalUserSharingOnly).'
                $st = 'warn'
            }
            'disabled' {
                Add-Finding 'External sharing capability' 'pass' 'External sharing is disabled; content can only be shared internally.'
                $st = 'pass'
            }
            default {
                Add-Finding 'External sharing capability' 'info' "Tenant sharing capability: $cap."
                $st = 'info'
            }
        }
        Add-Section 'Tenant Sharing Settings' $st "Tenant-level SharePoint/OneDrive external sharing configuration (capability: $cap)." @('Property', 'Value') $r 'Sharing settings unavailable.'
    }

    # ---- Sites ---------------------------------------------------------------------
    Invoke-Section 'Sites' {
        $sites = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/sites?search=*' -tenantid $TenantFilter -AsApp $true)
        $r = New-RowList
        foreach ($s in $sites) { $r.Add(@(($s.displayName ?? $s.name), $s.webUrl, $s.createdDateTime)) }
        Add-Finding 'SharePoint sites' 'info' "$($sites.Count) site(s) discovered in the tenant."
        Add-Section 'Sites' 'info' "$($sites.Count) SharePoint sites." @('Site', 'URL', 'Created') $r 'No sites returned.'
    }

    return @{
        Title         = 'External Sharing Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
