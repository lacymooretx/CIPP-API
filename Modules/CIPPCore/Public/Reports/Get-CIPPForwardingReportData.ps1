function Get-CIPPForwardingReportData {
    <#
    .SYNOPSIS
        Gather the External Forwarding Report model for a single tenant.
    .DESCRIPTION
        Assembles findings and report sections covering mailbox-level forwarding,
        inbox-rule forwarding and transport-rule forwarding for the CIPP
        "External Forwarding Report". Reuses CIPP report helpers where available and
        gathers each section defensively so one failure never kills the report.
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

    # ---- Mailbox forwarding (reuse CIPP helper) -----------------------------------
    Invoke-Section 'Mailbox Forwarding' {
        $fwd = @(Get-CIPPMailboxForwardingReport -TenantFilter $TenantFilter)
        $external = @($fwd | Where-Object { "$($_.ForwardingType)" -eq 'External' -or $_.ForwardingSmtpAddress })
        $r = New-RowList
        foreach ($m in $fwd) { $r.Add(@(($m.UPN ?? $m.DisplayName ?? $m.PrimarySmtpAddress), $m.ForwardTo, [bool]$m.DeliverToMailboxAndForward)) }
        $st = if ($external.Count -gt 0) { 'fail' } else { 'pass' }
        Add-Finding 'Mailbox forwarding' $st $(if ($external.Count) { "$($external.Count) mailbox(es) forward mail to an external address." } else { 'No external mailbox-level forwarding configured.' })
        Add-Section 'Mailbox Forwarding' $st 'Mailbox-level forwarding (a common exfiltration / BEC vector).' @('Mailbox', 'Forwards to', 'Keep copy') $r 'No mailbox forwarding configured.'
    }

    # ---- Inbox rules forwarding (reuse CIPP helper) -------------------------------
    Invoke-Section 'Inbox Rules Forwarding' {
        $rules = @(Get-CIPPMailboxRulesReport -TenantFilter $TenantFilter)
        $ext = @($rules | Where-Object { $_.ForwardTo -or $_.RedirectTo -or $_.ForwardAsAttachmentTo })
        $r = New-RowList
        foreach ($rule in $ext) {
            $target = @($rule.ForwardTo) + @($rule.RedirectTo) + @($rule.ForwardAsAttachmentTo) | Where-Object { $_ }
            $r.Add(@(($rule.MailboxOwnerId ?? $rule.Mailbox ?? $rule.UserPrincipalName), $rule.Name, ($target -join ', '), [bool]$rule.Enabled))
        }
        $st = if ($ext.Count -gt 0) { 'fail' } else { 'pass' }
        Add-Finding 'Inbox rule forwarding' $st $(if ($ext.Count) { "$($ext.Count) inbox rule(s) forward or redirect mail." } else { 'No forwarding inbox rules found.' })
        Add-Section 'Inbox Rules Forwarding' $st 'Client-side inbox rules that forward/redirect mail.' @('Mailbox', 'Rule', 'Forwards to', 'Enabled') $r 'No forwarding inbox rules found.'
    }

    # ---- Transport rules forwarding -----------------------------------------------
    Invoke-Section 'Transport Rules Forwarding' {
        $tr = @(New-ExoRequest -tenantid $TenantFilter -cmdlet 'Get-TransportRule')
        $fwd = @($tr | Where-Object { $_.RedirectMessageTo -or $_.BlindCopyTo -or $_.CopyTo })
        $r = New-RowList
        foreach ($t in $fwd) {
            $target = @($t.RedirectMessageTo) + @($t.BlindCopyTo) + @($t.CopyTo) | Where-Object { $_ }
            $r.Add(@($t.Name, $t.State, ($target -join ', ')))
        }
        $st = if ($fwd.Count -gt 0) { 'fail' } else { 'pass' }
        Add-Finding 'Transport rule forwarding' $st $(if ($fwd.Count) { "$($fwd.Count) transport rule(s) redirect or copy mail to another recipient." } else { 'No forwarding transport rules found.' })
        Add-Section 'Transport Rules Forwarding' $st 'Transport (mail-flow) rules that redirect, blind-copy or copy mail.' @('Name', 'State', 'Redirects to') $r 'No forwarding transport rules found.'
    }

    return @{
        Title         = 'External Forwarding Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
