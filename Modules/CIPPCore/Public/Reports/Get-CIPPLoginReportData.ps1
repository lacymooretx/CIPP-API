function Get-CIPPLoginReportData {
    <#
    .SYNOPSIS
        Gather the User Login Report model for a single tenant.
    .DESCRIPTION
        Assembles recent and failed sign-in sections plus executive findings for
        the CIPP "User Login Report" from live tenant data (Microsoft Graph
        sign-in logs via New-GraphGetRequest). Sign-in logs require Entra ID P1;
        if unavailable the defensive Invoke-Section wrapper captures the error and
        the rest of the report still renders.
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

    # Sign-in logs (Entra ID P1 required) - gathered defensively so both sections
    # and the ratio finding share the same pull.
    $SignIns = @()
    $SignInError = $null
    try { $SignIns = @(New-GraphGetRequest -uri "$GraphBeta/auditLogs/signIns?`$top=200&`$orderby=createdDateTime desc" -tenantid $TenantFilter) } catch { $SignInError = $_.Exception.Message }

    $failed = @($SignIns | Where-Object { [int]("$($_.status.errorCode)" -as [int]) -ne 0 })

    # ---- Recent Sign-ins ----------------------------------------------------------
    Invoke-Section 'Recent Sign-ins' {
        if ($SignInError) { throw $SignInError }
        $r = New-RowList
        foreach ($s in $SignIns) {
            $status = if ([int]("$($s.status.errorCode)" -as [int]) -eq 0) { 'Success' } else { 'Failure' }
            $location = (@($s.location.city, $s.location.countryOrRegion) | Where-Object { $_ }) -join ', '
            $r.Add(@($s.userPrincipalName, $s.appDisplayName, $status, $s.ipAddress, $location, $s.createdDateTime))
        }
        Add-Section 'Recent Sign-ins' 'info' "$($SignIns.Count) most recent sign-ins captured." @('User', 'App', 'Status', 'IP', 'Location', 'Date') $r 'No sign-ins found.'
    }

    # ---- Failed Sign-ins ----------------------------------------------------------
    Invoke-Section 'Failed Sign-ins' {
        if ($SignInError) { throw $SignInError }
        $r = New-RowList
        foreach ($s in $failed) {
            $r.Add(@($s.userPrincipalName, $s.appDisplayName, $s.status.failureReason, $s.ipAddress, $s.createdDateTime))
        }
        $st = if ($failed.Count -gt 0) { 'warn' } else { 'pass' }
        Add-Section 'Failed Sign-ins' $st "$($failed.Count) failed sign-in(s)." @('User', 'App', 'Failure reason', 'IP', 'Date') $r 'No failed sign-ins found.'
    }

    # ---- Findings -----------------------------------------------------------------
    if ($SignInError) {
        Add-Finding 'Sign-in logs' 'info' "Sign-in logs could not be retrieved (Entra ID P1 may be required): $SignInError"
    } else {
        Add-Finding 'Recent sign-ins' 'info' "$($SignIns.Count) recent sign-in(s) captured."
        $ratio = if ($SignIns.Count -gt 0) { [math]::Round(100 * $failed.Count / $SignIns.Count) } else { 0 }
        $st = if ($ratio -ge 30) { 'warn' } else { 'info' }
        Add-Finding 'Failed sign-in ratio' $st "$ratio% of recent sign-ins failed ($($failed.Count)/$($SignIns.Count))."
    }

    return @{
        Title         = 'User Login Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
