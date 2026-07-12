function Get-CIPPSecurityReportData {
    <#
    .SYNOPSIS
        Gather the Microsoft 365 Security Report model for a single tenant.
    .DESCRIPTION
        Assembles the executive-summary findings and report sections for the
        Aspendora / CIPP "Microsoft 365 Security Report" from live tenant data
        (Microsoft Graph via New-GraphGetRequest, Exchange Online via New-ExoRequest,
        and CIPP helpers such as Get-CIPPMFAState). Returns a report model consumable
        by Write-CippReportHtml. Every section is gathered defensively - a failure in
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

    $Users = @()
    try { $Users = @(New-GraphGetRequest -uri "$GraphBeta/users?`$select=id,displayName,userPrincipalName,accountEnabled,mail,jobTitle,department,assignedLicenses,passwordPolicies,createdDateTime,userType&`$top=999" -tenantid $TenantFilter) } catch {}

    # ---- Company Information ------------------------------------------------------
    Invoke-Section 'Company Information' {
        $r = New-RowList
        $r.Add(@('Display name', $Org.displayName))
        $r.Add(@('Default domain', $DefaultDomain))
        $r.Add(@('Tenant ID', $Org.id))
        $r.Add(@('Country', $Org.countryLetterCode))
        $r.Add(@('Tech notification mails', ($Org.technicalNotificationMails -join ', ')))
        $r.Add(@('Directory sync enabled', [bool]$Org.onPremisesSyncEnabled))
        $r.Add(@('Created', $Org.createdDateTime))
        Add-Section 'Company Information' 'info' 'Tenant identity and primary configuration.' @('Property', 'Value') $r
    }

    # ---- Users --------------------------------------------------------------------
    Invoke-Section 'Microsoft 365 Users' {
        $enabled = @($Users | Where-Object { $_.accountEnabled }).Count
        $licensed = @($Users | Where-Object { @($_.assignedLicenses).Count -gt 0 }).Count
        $r = New-RowList
        foreach ($u in $Users) { $r.Add(@($u.displayName, $u.userPrincipalName, [bool]$u.accountEnabled, $u.mail, $u.jobTitle, $u.userType)) }
        Add-Section 'Microsoft 365 Users' 'info' "$($Users.Count) users ($enabled enabled, $licensed licensed)." @('Display name', 'UPN', 'Enabled', 'Mail', 'Job title', 'Type') $r
    }

    # ---- Password configuration ---------------------------------------------------
    Invoke-Section 'Password Expiry Disabled' {
        $noExpiry = @($Users | Where-Object { $_.passwordPolicies -match 'DisablePasswordExpiration' })
        $weak = @($Users | Where-Object { $_.passwordPolicies -match 'DisableStrongPassword' })
        $r = New-RowList
        foreach ($u in $noExpiry) { $r.Add(@($u.displayName, $u.userPrincipalName, $u.passwordPolicies)) }
        if ($weak.Count -gt 0) { Add-Finding 'Strong password enforcement' 'warn' "$($weak.Count) account(s) have strong-password enforcement disabled." }
        $st = if ($weak.Count -gt 0) { 'warn' } else { 'info' }
        Add-Section 'Password Expiry Disabled' $st "$($noExpiry.Count) accounts have password expiry disabled; $($weak.Count) have strong-password enforcement disabled." @('Display name', 'UPN', 'Password policies') $r 'All accounts use the default password policy.'
    }

    # ---- MFA (reuse CIPP helper) --------------------------------------------------
    Invoke-Section 'Microsoft 365 User MFA Status' {
        $mfa = @(Get-CIPPMFAState -TenantFilter $TenantFilter)
        $mfaEnabled = @($mfa | Where-Object { "$($_.AccountEnabled)" -ne 'False' })
        $covered = @($mfaEnabled | Where-Object { "$($_.CoveredByCA)" -match 'Enforc|All Apps' -or "$($_.CoveredBySD)" -in @('True', 'Enforced') })
        $registered = @($mfaEnabled | Where-Object { "$($_.MFACapable)" -eq 'True' -or "$($_.MFARegistration)" -eq 'True' })
        $n = [math]::Max($mfaEnabled.Count, 1)
        $pctC = [math]::Round(100 * $covered.Count / $n); $pctR = [math]::Round(100 * $registered.Count / $n)
        $stC = if ($pctC -ge 95) { 'pass' } elseif ($pctC -ge 70) { 'warn' } else { 'fail' }
        $stR = if ($pctR -ge 90) { 'pass' } elseif ($pctR -ge 60) { 'warn' } else { 'fail' }
        Add-Finding 'MFA enforcement (CA/SD)' $stC "$pctC% of enabled accounts are covered by an MFA-enforcing policy ($($covered.Count)/$($mfaEnabled.Count))."
        Add-Finding 'MFA registration' $stR "$pctR% of enabled accounts have registered strong auth ($($registered.Count)/$($mfaEnabled.Count))."
        $r = New-RowList
        foreach ($m in $mfaEnabled) { $r.Add(@($m.DisplayName, ($m.UPN ?? $m.userPrincipalName), [bool]$m.IsAdmin, $m.MFACapable, $m.MFARegistration, $m.CoveredByCA, $m.PerUser)) }
        Add-Section 'Microsoft 365 User MFA Status' $(if ($stC -ne 'pass') { $stC } else { $stR }) "$pctC% policy-covered, $pctR% registered." @('Display name', 'UPN', 'Admin', 'MFA capable', 'Registered', 'Covered by CA', 'Per-user') $r
    }

    # ---- Global admins / roles ----------------------------------------------------
    Invoke-Section 'Global Administrators' {
        $roles = @(New-GraphGetRequest -uri "$GraphBeta/directoryRoles?`$expand=members" -tenantid $TenantFilter)
        $ga = $roles | Where-Object { $_.displayName -match 'Global Administrator|Company Administrator' } | Select-Object -First 1
        $gaMembers = @($ga.members)
        $r = New-RowList
        foreach ($m in $gaMembers) { $r.Add(@($m.displayName, $m.userPrincipalName, $m.id)) }
        $st = if ($gaMembers.Count -ge 2 -and $gaMembers.Count -le 5) { 'pass' } else { 'warn' }
        Add-Finding 'Global Administrators' $st "$($gaMembers.Count) account(s) hold Global Administrator (best practice: 2-5)."
        Add-Section 'Global Administrators' $st "$($gaMembers.Count) accounts hold Global Administrator." @('Display name', 'User principal name', 'Object ID') $r
        $rr = New-RowList
        foreach ($role in ($roles | Where-Object { @($_.members).Count -gt 0 })) {
            $rr.Add(@($role.displayName, $role.description, @($role.members).Count, (($role.members | Select-Object -First 8 | ForEach-Object { $_.userPrincipalName }) -join ', ')))
        }
        Add-Section 'Role Assignments' 'info' "$($rr.Count) directory roles have members." @('Role', 'Description', 'Members', 'Assigned to') $rr
    }

    # ---- Conditional access -------------------------------------------------------
    Invoke-Section 'Conditional Access Policies' {
        $ca = @(New-GraphGetRequest -uri "$GraphBeta/identity/conditionalAccess/policies" -tenantid $TenantFilter)
        $enabled = @($ca | Where-Object { $_.state -eq 'enabled' })
        $r = New-RowList
        foreach ($p in $ca) { $r.Add(@($p.displayName, $p.state, $p.createdDateTime, $p.modifiedDateTime)) }
        $st = if ($enabled.Count -gt 0) { 'pass' } else { 'warn' }
        Add-Finding 'Conditional Access' $st "$($enabled.Count) of $($ca.Count) CA policies enabled."
        Add-Section 'Conditional Access Policies' 'info' "$($ca.Count) policies, $($enabled.Count) enabled." @('Name', 'State', 'Created', 'Modified') $r
    }

    # ---- Authentication methods ---------------------------------------------------
    Invoke-Section 'Authentication Methods' {
        $amp = New-GraphGetRequest -uri "$GraphBeta/policies/authenticationMethodsPolicy" -tenantid $TenantFilter
        $r = New-RowList
        foreach ($m in $amp.authenticationMethodConfigurations) { $r.Add(@($m.id, $m.state)) }
        Add-Section 'Authentication Methods' 'info' 'Tenant authentication method configuration.' @('Method', 'State') $r
    }

    # ---- Domains ------------------------------------------------------------------
    Invoke-Section 'Domains' {
        $domains = @(New-GraphGetRequest -uri "$GraphBeta/domains" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($d in $domains) { $r.Add(@($d.id, $d.authenticationType, [bool]$d.isVerified, [bool]$d.isDefault, ($d.supportedServices -join ', '))) }
        Add-Section 'Domains' 'info' "$($domains.Count) domains." @('Domain', 'Auth type', 'Verified', 'Default', 'Services') $r
    }

    # ---- Licenses (reuse CIPP helper) ---------------------------------------------
    Invoke-Section 'Microsoft 365 Licenses' {
        $lic = @(Get-CIPPLicenseOverview -TenantFilter $TenantFilter)
        $r = New-RowList
        foreach ($l in $lic) { $r.Add(@(($l.License ?? $l.skuPartNumber), $l.CountUsed, $l.CountAvailable, $l.TotalLicenses)) }
        Add-Section 'Microsoft 365 Licenses' 'info' "$($lic.Count) license SKUs." @('License', 'Used', 'Available', 'Total') $r
    }

    # ---- Mailboxes / forwarding ---------------------------------------------------
    Invoke-Section 'Microsoft 365 Mailboxes' {
        $mbx = @(New-ExoRequest -tenantid $TenantFilter -cmdlet 'Get-Mailbox' -cmdParams @{ ResultSize = 'Unlimited' })
        $r = New-RowList
        foreach ($m in $mbx) { $r.Add(@($m.displayName, ($m.UserPrincipalName ?? $m.PrimarySmtpAddress ?? $m.UPN), $m.RecipientTypeDetails, $m.PrimarySmtpAddress)) }
        Add-Section 'Microsoft 365 Mailboxes' 'info' "$($mbx.Count) mailboxes." @('Display name', 'UPN', 'Type', 'Primary SMTP') $r

        $fwd = New-RowList
        foreach ($m in $mbx) {
            $target = $m.ForwardingSmtpAddress ?? $m.ForwardingAddress
            if ($target) { $fwd.Add(@(($m.UserPrincipalName ?? $m.displayName ?? $m.UPN), $target, [bool]$m.DeliverToMailboxAndForward)) }
        }
        $stf = if ($fwd.Count -gt 0) { 'fail' } else { 'pass' }
        Add-Finding 'Mailbox forwarding' $stf $(if ($fwd.Count) { "$($fwd.Count) mailbox(es) forward mail to another address." } else { 'No mailbox-level forwarding configured.' })
        Add-Section 'Mailbox Forwarding' $stf 'Mailbox-level forwarding (a common exfiltration / BEC vector).' @('Mailbox', 'Forwards to', 'Keep copy') $fwd 'No forwarding configured.'
    }

    # ---- Inbox rules forwarding ---------------------------------------------------
    Invoke-Section 'Inbox Rules Forwarding Externally' {
        $rules = @(Get-CIPPMailboxRulesReport -TenantFilter $TenantFilter)
        $ext = @($rules | Where-Object { $_.ForwardTo -or $_.RedirectTo -or $_.ForwardAsAttachmentTo })
        $r = New-RowList
        foreach ($rule in $ext) { $r.Add(@(($rule.MailboxOwnerId ?? $rule.Mailbox), $rule.Name, ($rule.ForwardTo ?? $rule.RedirectTo), [bool]$rule.Enabled)) }
        $st = if ($ext.Count -gt 0) { 'fail' } else { 'pass' }
        Add-Finding 'Inbox rule forwarding' $st $(if ($ext.Count) { "$($ext.Count) inbox rule(s) forward or redirect mail." } else { 'No forwarding inbox rules found.' })
        Add-Section 'Inbox Rules Forwarding Externally' $st 'Client-side inbox rules that forward/redirect mail.' @('Mailbox', 'Rule', 'Forwards to', 'Enabled') $r 'No forwarding inbox rules found.'
    }

    # ---- Transport rules ----------------------------------------------------------
    Invoke-Section 'Transport Rules' {
        $tr = @(New-ExoRequest -tenantid $TenantFilter -cmdlet 'Get-TransportRule')
        $r = New-RowList
        foreach ($t in $tr) { $r.Add(@($t.Name, $t.State, $t.Priority, $t.Description)) }
        Add-Section 'Transport Rules' 'info' "$($tr.Count) transport rules." @('Name', 'State', 'Priority', 'Description') $r
    }

    # ---- App registrations & enterprise apps --------------------------------------
    Invoke-Section 'Azure AD App Registrations' {
        $apps = @(New-GraphGetRequest -uri "$GraphBeta/applications?`$select=id,appId,displayName,createdDateTime,publisherDomain,passwordCredentials,keyCredentials&`$top=999" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($a in $apps) {
            $creds = @($a.passwordCredentials) + @($a.keyCredentials)
            $nextExp = ($creds | Where-Object { $_.endDateTime } | Sort-Object endDateTime | Select-Object -First 1).endDateTime
            $r.Add(@($a.displayName, $a.appId, $a.publisherDomain, $a.createdDateTime, $nextExp))
        }
        Add-Section 'Azure AD App Registrations' 'info' "$($apps.Count) registered applications." @('Name', 'App ID', 'Publisher domain', 'Created', 'Next credential expiry') $r
    }
    Invoke-Section 'Enterprise Applications' {
        $sps = @(New-GraphGetRequest -uri "$GraphBeta/servicePrincipals?`$select=id,appId,displayName,accountEnabled,servicePrincipalType&`$top=999" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($s in $sps) { $r.Add(@($s.displayName, $s.appId, [bool]$s.accountEnabled, $s.servicePrincipalType)) }
        Add-Section 'Enterprise Applications' 'info' "$($sps.Count) service principals." @('Name', 'App ID', 'Enabled', 'Type') $r
    }

    # ---- Groups -------------------------------------------------------------------
    Invoke-Section 'Microsoft 365 Groups' {
        $groups = @(New-GraphGetRequest -uri "$GraphBeta/groups?`$select=id,displayName,mailNickname,mail,groupTypes,visibility,securityEnabled&`$top=999" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($g in $groups) { $r.Add(@($g.displayName, $g.mailNickname, ($g.groupTypes -join ', '), $g.mail, $g.visibility)) }
        Add-Section 'Microsoft 365 Groups' 'info' "$($groups.Count) groups." @('Display name', 'Nickname', 'Type', 'Mail', 'Visibility') $r
    }

    # ---- Devices ------------------------------------------------------------------
    Invoke-Section 'Devices' {
        $devices = @(New-GraphGetRequest -uri "$GraphBeta/deviceManagement/managedDevices?`$top=999" -tenantid $TenantFilter)
        $r = New-RowList
        foreach ($d in $devices) { $r.Add(@($d.deviceName, $d.operatingSystem, $d.osVersion, $d.complianceState, $d.lastSyncDateTime, $d.userPrincipalName)) }
        Add-Section 'Devices' 'info' "$($devices.Count) managed devices." @('Device', 'OS', 'Version', 'Compliance', 'Last sync', 'User') $r
    }

    return @{
        Title         = 'Microsoft 365 Security Report'
        TenantName    = $TenantName
        TenantDomain  = $DefaultDomain
        GeneratedDate = (Get-Date).ToString('dd MMMM yyyy')
        Findings      = $Findings
        Sections      = $Sections
    }
}
