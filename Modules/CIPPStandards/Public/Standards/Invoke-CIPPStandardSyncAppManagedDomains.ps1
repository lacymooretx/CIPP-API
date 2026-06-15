function Invoke-CIPPStandardSyncAppManagedDomains {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) SyncAppManagedDomains
    .SYNOPSIS
        (Label) Restrict OneDrive Sync app to managed (domain-joined) devices
    .DESCRIPTION
        (Helptext) Restricts the OneDrive Sync app so it only runs on computers joined to the specified AD domains (Graph admin/sharepoint/settings isUnmanagedSyncAppForTenantRestricted + allowedDomainGuidsForSyncApp). Requires the AD domain GUID(s) of the tenant's managed devices - leaving them empty would block the sync client on every device, so this standard refuses to remediate without at least one domain GUID.
        (DocsDescription) Sets `isUnmanagedSyncAppForTenantRestricted` to true and `allowedDomainGuidsForSyncApp` to the supplied list, the "Allow syncing only on computers joined to specific domains" control. Get the domain GUID(s) from the customer's on-prem AD (`(Get-ADDomain).ObjectGUID`). This is distinct from the `unmanagedSync` standard, which controls the Conditional-Access based browser access policy (`Set-SPOTenant -ConditionalAccessPolicy`). CIS M365 5.0 7.3.2.
    .NOTES
        CAT
            SharePoint Standards
        TAG
            "CIS M365 5.0 (7.3.2)"
        ADDEDCOMPONENT
            {"type":"textField","name":"standards.SyncAppManagedDomains.allowedDomainGuids","label":"Allowed AD domain GUID(s) for the Sync app (comma or newline separated)","required":true}
        IMPACT
            High Impact
        ADDEDDATE
            2026-06-15
        POWERSHELLEQUIVALENT
            Update-MgBetaAdminSharePointSetting / Set-SPOTenant -IsUnmanagedSyncAppForTenantRestricted
        RECOMMENDEDBY
            "CIS"
        REQUIREDCAPABILITIES
            "SHAREPOINTWAC"
            "SHAREPOINTSTANDARD"
            "SHAREPOINTENTERPRISE"
            "ONEDRIVE_BASIC"
            "ONEDRIVE_ENTERPRISE"
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards
    #>

    param($Tenant, $Settings)
    $TestResult = Test-CIPPStandardLicense -StandardName 'SyncAppManagedDomains' -TenantFilter $Tenant -RequiredCapabilities @('SHAREPOINTWAC', 'SHAREPOINTSTANDARD', 'SHAREPOINTENTERPRISE', 'ONEDRIVE_BASIC', 'ONEDRIVE_ENTERPRISE')

    if ($TestResult -eq $false) {
        return $true
    } #we're done.

    try {
        $CurrentInfo = New-GraphGetRequest -Uri 'https://graph.microsoft.com/beta/admin/sharepoint/settings' -tenantid $Tenant -AsApp $true
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -API 'Standards' -Tenant $Tenant -Message "Could not get the SharePoint settings for $Tenant. Error: $ErrorMessage" -Sev Error
        return
    }

    # Normalize the requested allowed-domain GUIDs (comma/newline/space separated) to a clean array.
    $AllowedDomains = @(($Settings.allowedDomainGuids -split '[\r\n,; ]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $CurrentRestricted = [bool]$CurrentInfo.isUnmanagedSyncAppForTenantRestricted
    $CurrentDomains = @($CurrentInfo.allowedDomainGuidsForSyncApp | ForEach-Object { "$_" })
    # State is correct when the restriction is on and the allowed-domain sets match (order-insensitive).
    $DomainsMatch = (@(Compare-Object -ReferenceObject $CurrentDomains -DifferenceObject $AllowedDomains).Count -eq 0)
    $StateIsCorrect = $CurrentRestricted -and $DomainsMatch

    if ($Settings.remediate -eq $true) {
        if ($AllowedDomains.Count -eq 0) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message 'SyncAppManagedDomains: refusing to remediate with no allowed domain GUIDs - that would block the OneDrive Sync app on every device. Provide at least one AD domain GUID.' -sev Error
            return
        }
        if ($StateIsCorrect -eq $true) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message 'OneDrive Sync app is already restricted to the configured managed domains' -sev Info
        } else {
            try {
                $Body = @{
                    isUnmanagedSyncAppForTenantRestricted = $true
                    allowedDomainGuidsForSyncApp          = @($AllowedDomains)
                }
                $BodyJson = ConvertTo-Json -InputObject $Body -Compress
                $null = New-GraphPostRequest -tenantid $Tenant -Uri 'https://graph.microsoft.com/beta/admin/sharepoint/settings' -AsApp $true -Type patch -Body $BodyJson -ContentType 'application/json'
                Write-LogMessage -API 'Standards' -tenant $Tenant -message "Restricted OneDrive Sync app to managed domains: $($AllowedDomains -join ', ')" -sev Info
            } catch {
                $ErrorMessage = Get-CippException -Exception $_
                Write-LogMessage -API 'Standards' -tenant $Tenant -message "Failed to restrict OneDrive Sync app to managed domains: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
            }
        }
    }

    if ($Settings.alert -eq $true) {
        if ($StateIsCorrect -eq $true) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message 'OneDrive Sync app is restricted to the configured managed domains' -sev Info
        } else {
            Write-StandardsAlert -message 'OneDrive Sync app is not restricted to the configured managed domains' -object $CurrentInfo -tenant $Tenant -standardName 'SyncAppManagedDomains' -standardId $Settings.standardId
            Write-LogMessage -API 'Standards' -tenant $Tenant -message 'OneDrive Sync app is not restricted to the configured managed domains' -sev Info
        }
    }

    if ($Settings.report -eq $true) {
        $CurrentValue = @{
            isUnmanagedSyncAppForTenantRestricted = $CurrentRestricted
            allowedDomainGuidsForSyncApp          = $CurrentDomains
        }
        $ExpectedValue = @{
            isUnmanagedSyncAppForTenantRestricted = $true
            allowedDomainGuidsForSyncApp          = $AllowedDomains
        }
        Set-CIPPStandardsCompareField -FieldName 'standards.SyncAppManagedDomains' -CurrentValue $CurrentValue -ExpectedValue $ExpectedValue -Tenant $Tenant
        Add-CIPPBPAField -FieldName 'SyncAppManagedDomains' -FieldValue $StateIsCorrect -StoreAs bool -Tenant $Tenant
    }
}
