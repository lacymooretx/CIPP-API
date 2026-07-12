function Get-CIPPApplicationReportData {
    <#
    .SYNOPSIS
        Gather the Registered Applications Report model for a single tenant.
    .DESCRIPTION
        Assembles findings and report sections covering Entra ID app registrations
        (with secret / certificate credential expiry) and enterprise applications
        (service principals) for the CIPP "Registered Applications Report". Each
        section is gathered defensively so one failure never kills the report.
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

    $Now = Get-Date
    $Soon = $Now.AddDays(30)
    $script:AnyExpired = $false
    $script:AnyExpiring = $false

    # ---- App registrations --------------------------------------------------------
    Invoke-Section 'App Registrations' {
        $apps = @(New-GraphGetRequest -uri "$GraphBeta/applications?`$select=id,appId,displayName,createdDateTime,publisherDomain,passwordCredentials,keyCredentials&`$top=999" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($a in $apps) {
            $secretExpiry = ($a.passwordCredentials | Where-Object { $_.endDateTime } | Sort-Object endDateTime | Select-Object -First 1).endDateTime
            $certExpiry = ($a.keyCredentials | Where-Object { $_.endDateTime } | Sort-Object endDateTime | Select-Object -First 1).endDateTime

            $secretStatus = 'None'
            if ($secretExpiry) {
                $d = [datetime]$secretExpiry
                if ($d -lt $Now) { $secretStatus = 'Expired'; $script:AnyExpired = $true }
                elseif ($d -lt $Soon) { $secretStatus = 'Expiring'; $script:AnyExpiring = $true }
                else { $secretStatus = 'Valid' }
            }
            $certStatus = 'None'
            if ($certExpiry) {
                $d = [datetime]$certExpiry
                if ($d -lt $Now) { $certStatus = 'Expired'; $script:AnyExpired = $true }
                elseif ($d -lt $Soon) { $certStatus = 'Expiring'; $script:AnyExpiring = $true }
                else { $certStatus = 'Valid' }
            }
            $r.Add(@($a.displayName, $a.appId, $a.publisherDomain, $a.createdDateTime, $secretExpiry, $secretStatus, $certExpiry, $certStatus))
        }
        Add-Section 'App Registrations' 'info' "$($apps.Count) registered applications." @('Name', 'App Id', 'Publisher domain', 'Created', 'Secret expiry', 'Secret status', 'Cert expiry', 'Cert status') $r 'No app registrations found.'
    }

    # ---- Enterprise applications ---------------------------------------------------
    Invoke-Section 'Enterprise Applications' {
        $sps = @(New-GraphGetRequest -uri "$GraphBeta/servicePrincipals?`$select=id,appId,displayName,accountEnabled,servicePrincipalType,appOwnerOrganizationId&`$top=999" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($s in $sps) { $r.Add(@($s.displayName, $s.appId, [bool]$s.accountEnabled, $s.servicePrincipalType)) }
        Add-Section 'Enterprise Applications' 'info' "$($sps.Count) service principals (enterprise applications)." @('Name', 'App Id', 'Enabled', 'Type') $r 'No enterprise applications found.'
    }

    # ---- Credential health finding ------------------------------------------------
    if ($script:AnyExpired) {
        Add-Finding 'Application credentials' 'fail' 'One or more applications have an expired secret or certificate.'
    } elseif ($script:AnyExpiring) {
        Add-Finding 'Application credentials' 'warn' 'One or more application secrets or certificates expire within 30 days.'
    } else {
        Add-Finding 'Application credentials' 'pass' 'No application secrets or certificates are expired or expiring within 30 days.'
    }

    return @{
        Title         = 'Registered Applications Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
