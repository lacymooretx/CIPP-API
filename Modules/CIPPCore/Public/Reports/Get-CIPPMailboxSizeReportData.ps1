function Get-CIPPMailboxSizeReportData {
    <#
    .SYNOPSIS
        Gather the Mailbox Size Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "Mailbox Size Report" from cached tenant data
        (Get-CIPPMailboxesReport, which carries mailbox usage and quota bytes).
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
    # human-readable byte formatter
    function Format-Bytes($Bytes) {
        $b = 0L
        if (-not [int64]::TryParse("$Bytes", [ref]$b) -or $b -le 0) { return '0 B' }
        $units = @('B', 'KB', 'MB', 'GB', 'TB')
        $i = 0; $val = [double]$b
        while ($val -ge 1024 -and $i -lt ($units.Count - 1)) { $val /= 1024; $i++ }
        return ('{0:0.##} {1}' -f $val, $units[$i])
    }

    # ---- shared data gathered up front (read-only in sections) ---------------------
    $Org = $null
    try { $Org = New-GraphGetRequest -uri "$GraphBeta/organization" -tenantid $TenantFilter | Select-Object -First 1 } catch {}
    $TenantName = if ($Org.displayName) { $Org.displayName } else { $TenantFilter }
    $DefaultDomain = ($Org.verifiedDomains | Where-Object { $_.isDefault }).name
    if (-not $DefaultDomain) { $DefaultDomain = $TenantFilter }

    # ---- Mailboxes ----------------------------------------------------------------
    Invoke-Section 'Mailboxes' {
        $mbx = @(Get-CIPPMailboxesReport -TenantFilter $TenantFilter)
        $r = New-RowList
        $nearQuota = 0
        $archiveEnabled = 0
        foreach ($m in $mbx) {
            $used = try { [int64]$m.storageUsedInBytes } catch { 0 }
            $quota = try { [int64]$m.prohibitSendReceiveQuotaInBytes } catch { 0 }
            $items = $m.MailboxItemCount
            $util = if ($quota -gt 0) { [math]::Round(100 * $used / $quota, 1) } else { 0 }
            if ($quota -gt 0 -and $util -ge 90) { $nearQuota++ }
            if ($m.ArchiveEnabled -eq $true) { $archiveEnabled++ }
            $r.Add(@(
                    ($m.displayName ?? $m.UPN ?? $m.primarySmtpAddress),
                    $m.recipientTypeDetails,
                    (Format-Bytes $used),
                    $items,
                    (Format-Bytes $quota),
                    "$util%"
                ))
        }
        $st = if ($nearQuota -gt 0) { 'warn' } else { 'info' }
        Add-Finding 'Mailbox inventory' 'info' "$($mbx.Count) mailboxes reported; $archiveEnabled have an online archive enabled."
        if ($nearQuota -gt 0) {
            Add-Finding 'Mailboxes near quota' 'warn' "$nearQuota mailbox(es) are at 90% or more of their quota - consider archiving or a quota increase."
        } else {
            Add-Finding 'Mailboxes near quota' 'pass' 'No mailboxes are within 10% of their quota.'
        }
        Add-Section 'Mailboxes' $st "$($mbx.Count) mailboxes; $nearQuota at >=90% quota; $archiveEnabled archive-enabled." @('Mailbox', 'Type', 'Total size', 'Item count', 'Quota', 'Utilisation %') $r 'No mailbox data found.'
    }

    return @{
        Title         = 'Mailbox Size Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
