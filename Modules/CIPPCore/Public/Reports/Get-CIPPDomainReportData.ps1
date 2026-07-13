function Get-CIPPDomainReportData {
    <#
    .SYNOPSIS
        Gather the Domain Health Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "Domain Health Report" from the CIPP Domain Analyser
        (SPF / DKIM / DMARC / MX / DNSSEC scored results per domain). Falls back to a
        Graph domain listing when analyser data is unavailable. Returns a report model
        consumable by Write-CippReportHtml. Every section is gathered defensively - a
        failure in one section is captured and the rest of the report still renders.
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
    function Convert-Flag($Value, $Yes, $No) {
        if ($Value -eq $true) { return $Yes }
        if ($Value -eq $false) { return $No }
        if ([string]::IsNullOrWhiteSpace("$Value")) { return $No }
        return "$Value"
    }

    # ---- shared data gathered up front (read-only in sections) ---------------------
    $Org = $null
    try { $Org = New-GraphGetRequest -uri "$GraphBeta/organization" -tenantid $TenantFilter | Select-Object -First 1 } catch {}
    $TenantName = if ($Org.displayName) { $Org.displayName } else { $TenantFilter }
    $DefaultDomain = ($Org.verifiedDomains | Where-Object { $_.isDefault }).name
    if (-not $DefaultDomain) { $DefaultDomain = $TenantFilter }

    # ---- Domain health ------------------------------------------------------------
    Invoke-Section 'Domain Health' {
        $domains = @()
        try { $domains = @(Get-CIPPDomainAnalyser -TenantFilter $TenantFilter) } catch { $domains = @() }

        if (-not $domains -or $domains.Count -eq 0) {
            # Fallback: list domains from Graph with a note that health data is unavailable.
            $graphDomains = @(New-GraphGetRequest -uri "$GraphBeta/domains" -tenantid $TenantFilter)
            $r = New-RowList
            foreach ($d in $graphDomains) {
                $r.Add(@($d.id, 'N/A', 'N/A', 'N/A', 'N/A', 'N/A'))
            }
            Add-Finding 'Domain health data' 'warn' 'Domain Analyser results were unavailable - run the Domain Analyser to populate SPF/DKIM/DMARC health.'
            Add-Section 'Domain Health' 'warn' "$($graphDomains.Count) domains listed. Health data is unavailable - Domain Analyser has not run for this tenant." @('Domain', 'MX', 'SPF', 'DKIM', 'DMARC', 'DNSSEC') $r 'No domains found.'
            return
        }

        $r = New-RowList
        $spfFail = 0; $dmarcFail = 0; $dkimGap = 0; $dnssecGap = 0
        foreach ($d in $domains) {
            $spfOk = ($d.SPFPassAll -eq $true) -or ("$($d.ActualSPFRecord)" -and "$($d.ActualSPFRecord)" -notmatch 'No SPF')
            $spfPresent = ("$($d.ActualSPFRecord)" -and "$($d.ActualSPFRecord)" -notmatch 'No SPF Record')
            $dmarcPolicy = "$($d.DMARCActionPolicy)"
            $dmarcOk = -not [string]::IsNullOrWhiteSpace($dmarcPolicy)
            $mx = Convert-Flag $d.MXPassTest 'Pass' 'Fail'
            $spf = if ($d.SPFPassAll -eq $true) { 'Pass' } elseif ($spfPresent) { 'Present (soft)' } else { 'Missing' }
            $dkim = Convert-Flag $d.DKIMEnabled 'Enabled' 'Not enabled'
            $dmarc = if ($dmarcOk) { $dmarcPolicy } else { 'Missing' }
            $dnssec = Convert-Flag $d.DNSSECPresent 'Present' 'Absent'

            if (-not $spfPresent) { $spfFail++ }
            if (-not $dmarcOk) { $dmarcFail++ }
            if ($d.DKIMEnabled -ne $true) { $dkimGap++ }
            if ($d.DNSSECPresent -ne $true) { $dnssecGap++ }

            $r.Add(@($d.Domain, $mx, $spf, $dkim, $dmarc, $dnssec))
        }

        $st = if ($spfFail -gt 0 -or $dmarcFail -gt 0) { 'fail' } elseif ($dkimGap -gt 0 -or $dnssecGap -gt 0) { 'warn' } else { 'pass' }
        Add-Section 'Domain Health' $st "$($domains.Count) domains: $spfFail missing SPF, $dmarcFail missing DMARC, $dkimGap without DKIM, $dnssecGap without DNSSEC." @('Domain', 'MX', 'SPF', 'DKIM', 'DMARC', 'DNSSEC') $r 'No domains found.'

        # findings
        if ($spfFail -gt 0) {
            Add-Finding 'SPF' 'fail' "$spfFail domain(s) have no SPF record - a required anti-spoofing control."
        } else {
            Add-Finding 'SPF' 'pass' 'All domains publish an SPF record.'
        }
        if ($dmarcFail -gt 0) {
            Add-Finding 'DMARC' 'fail' "$dmarcFail domain(s) have no DMARC policy - configure DMARC to protect against spoofing."
        } else {
            Add-Finding 'DMARC' 'pass' 'All domains publish a DMARC policy.'
        }
        $dkimSt = if ($dkimGap -gt 0) { 'warn' } else { 'pass' }
        Add-Finding 'DKIM' $dkimSt $(if ($dkimGap -gt 0) { "$dkimGap domain(s) do not have DKIM signing enabled." } else { 'DKIM signing is enabled on all domains.' })
        $dnssecSt = if ($dnssecGap -gt 0) { 'warn' } else { 'pass' }
        Add-Finding 'DNSSEC' $dnssecSt $(if ($dnssecGap -gt 0) { "$dnssecGap domain(s) do not have DNSSEC present." } else { 'DNSSEC is present on all domains.' })
    }

    return @{
        Title         = 'Domain Health Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
