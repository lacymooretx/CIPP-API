function Invoke-ITGlueExtensionSync {
    <#
        .FUNCTIONALITY
        Internal
        .SYNOPSIS
        Synchronizes a single tenant's M365 directory into IT Glue.
        Mirrors the surface of Invoke-HuduExtensionSync but targets IT Glue's
        first-class primitives:
          - M365 Users  -> IT Glue Contacts + Flexible Asset (rich-text metadata)
          - M365 Devices -> IT Glue Configurations
          - M365 Domains -> IT Glue Flexible Asset (optional)
    #>
    param(
        $Configuration,
        $TenantFilter
    )

    try {
        Connect-ITGlueAPI -configuration $Configuration
        $ITGConfig = $Configuration.ITGlue
        $Tenant = Get-Tenants -TenantFilter $TenantFilter -IncludeErrors

        $CompanyResult = [PSCustomObject]@{
            Name    = $Tenant.displayName
            Users   = 0
            Devices = 0
            Errors  = [System.Collections.Generic.List[string]]@()
            Logs    = [System.Collections.Generic.List[string]]@()
        }

        # --- Resolve tenant -> IT Glue org and field mappings ---
        $MappingTable = Get-CIPPTable -TableName 'CippMapping'
        $Mappings = Get-CIPPAzDataTableEntity @MappingTable -Filter "PartitionKey eq 'ITGlueMapping' or PartitionKey eq 'ITGlueFieldMapping'"

        $TenantMap = $Mappings | Where-Object { $_.PartitionKey -eq 'ITGlueMapping' -and $_.RowKey -eq $Tenant.customerId }
        if (!$TenantMap) { return 'Tenant not found in IT Glue mapping table' }
        $OrgId = $TenantMap.IntegrationId

        $UserFlexAssetTypeId = ($Mappings | Where-Object { $_.PartitionKey -eq 'ITGlueFieldMapping' -and $_.RowKey -eq 'Users' }).IntegrationId
        $DeviceConfigTypeId  = ($Mappings | Where-Object { $_.PartitionKey -eq 'ITGlueFieldMapping' -and $_.RowKey -eq 'Devices' }).IntegrationId

        $CompanyResult.Logs.Add("Starting IT Glue sync for $($Tenant.displayName) (org $OrgId)")

        # --- CIPP URL for management links ---
        $ConfigTable = Get-Cipptable -tablename 'Config'
        $CippCfg = Get-CippAzDataTableEntity @ConfigTable -Filter "PartitionKey eq 'InstanceProperties' and RowKey eq 'CIPPURL'"
        $CIPPURL = if ($CippCfg.Value) { 'https://{0}' -f $CippCfg.Value } else { $null }

        # --- Source data ---
        $Cache = Get-CippExtensionReportingData -TenantFilter $Tenant.defaultDomainName -IncludeMailboxes

        $DefaultSerials = [System.Collections.Generic.List[string]]@('SystemSerialNumber', 'To Be Filled By O.E.M.', 'System Serial Number', '0123456789', '123456789', 'TobefilledbyO.E.M.')
        if ($ITGConfig.ExcludeSerials) {
            $null = $DefaultSerials.AddRange(($ITGConfig.ExcludeSerials -split ','))
        }

        # ============================================================
        # USERS
        # ============================================================
        if (![string]::IsNullOrEmpty($UserFlexAssetTypeId)) {
            try {
                Sync-ITGlueUsers -OrgId $OrgId -Tenant $Tenant -Cache $Cache -FlexAssetTypeId $UserFlexAssetTypeId `
                    -CreateMissing ($ITGConfig.CreateMissingUsers -eq $true) -CIPPURL $CIPPURL `
                    -CompanyResult $CompanyResult
            } catch {
                $CompanyResult.Errors.Add("Users: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
            }
        } else {
            $CompanyResult.Logs.Add('User Flexible Asset Type not mapped — skipping user sync')
        }

        # ============================================================
        # DEVICES
        # ============================================================
        if (![string]::IsNullOrEmpty($DeviceConfigTypeId)) {
            try {
                Sync-ITGlueDevices -OrgId $OrgId -Tenant $Tenant -Cache $Cache -ConfigTypeId $DeviceConfigTypeId `
                    -CreateMissing ($ITGConfig.CreateMissingDevices -eq $true) -ExcludeSerials $DefaultSerials `
                    -CompanyResult $CompanyResult
            } catch {
                $CompanyResult.Errors.Add("Devices: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
            }
        } else {
            $CompanyResult.Logs.Add('Device Configuration Type not mapped — skipping device sync')
        }

        # ============================================================
        # DOMAINS (optional)
        # ============================================================
        if ($ITGConfig.ImportDomains -eq $true) {
            try {
                Sync-ITGlueDomains -OrgId $OrgId -Tenant $Tenant -Cache $Cache `
                    -Monitor ($ITGConfig.MonitorDomains -eq $true) `
                    -CompanyResult $CompanyResult
            } catch {
                $CompanyResult.Errors.Add("Domains: $($_.Exception.Message)")
            }
        }

        # ============================================================
        # Log results
        # ============================================================
        $LogMessage = "IT Glue sync complete for $($Tenant.displayName): $($CompanyResult.Users) users, $($CompanyResult.Devices) devices, $($CompanyResult.Errors.Count) errors"
        if ($CompanyResult.Errors.Count -gt 0) {
            Write-LogMessage -API 'ITGlueSync' -tenant $Tenant.defaultDomainName -message "$LogMessage. First error: $($CompanyResult.Errors[0])" -sev Warning
        } else {
            Write-LogMessage -API 'ITGlueSync' -tenant $Tenant.defaultDomainName -message $LogMessage -sev Info
        }

        return $CompanyResult
    } catch {
        Write-LogMessage -API 'ITGlueSync' -tenant $TenantFilter -message "IT Glue sync failed: $($_.Exception.Message)" -sev Error
        throw
    }
}

# ---------- USERS ----------
function Sync-ITGlueUsers {
    param($OrgId, $Tenant, $Cache, $FlexAssetTypeId, [bool]$CreateMissing, $CIPPURL, $CompanyResult)

    Initialize-ITGlueUserFlexAssetFields -FlexAssetTypeId $FlexAssetTypeId

    $ExistingContacts = Invoke-ITGlueRequest -Path "/organizations/$OrgId/relationships/contacts" -AllPages
    # IT Glue does not expose flexible_assets under /organizations/:id/relationships/. Use the top-level endpoint with filters.
    $ExistingAssets = Invoke-ITGlueRequest -Path "/flexible_assets?filter[organization-id]=$OrgId&filter[flexible-asset-type-id]=$FlexAssetTypeId" -AllPages

    $LicensedUsers = $Cache.Users | Where-Object { $null -ne $_.assignedLicenses.skuId } | Sort-Object userPrincipalName
    $CompanyResult.Logs.Add("Found $(($LicensedUsers | Measure-Object).Count) licensed users")

    foreach ($User in $LicensedUsers) {
        $UPN = $User.userPrincipalName
        try {
            if (-not $UPN) { continue }
            if ($UPN -match '\.smtp\.exclaimer\.cloud$') {
                $CompanyResult.Logs.Add("Skipping Exclaimer shadow account: $UPN")
                continue
            }

            # ----- Contact upsert (separate try/catch so a failure doesn't block the Flex Asset) -----
            try {
                $ExistingContact = $ExistingContacts | Where-Object {
                    $emails = @($_.attributes.'contact-emails')
                    $emails.value -contains $UPN
                } | Select-Object -First 1

                $ContactPayload = @{
                    data = @{
                        type       = 'contacts'
                        attributes = @{
                            'organization-id'  = [int]$OrgId
                            'first-name'       = if ($User.givenName) { "$($User.givenName)" } else { ($UPN -split '@')[0] }
                            'last-name'        = "$($User.surname)"
                            'title'            = "$($User.jobTitle)"
                            'contact-emails'   = @(@{ value = $UPN; primary = $true; 'label-name' = 'Work' })
                        }
                    }
                }
                if ($User.mobilePhone) {
                    $ContactPayload.data.attributes['contact-phones'] = @(@{ value = "$($User.mobilePhone)"; primary = $true; 'label-name' = 'Mobile' })
                }

                if ($ExistingContact) {
                    # PSA-synced contacts (e.g. ConnectWise) are owned by the integration; IT Glue rejects most attribute updates.
                    # Leave the existing contact alone and rely on the Flex Asset to carry CIPP's M365 metadata.
                    if ([string]::IsNullOrEmpty($ExistingContact.attributes.'psa-integration')) {
                        $null = Invoke-ITGlueRequest -Path "/contacts/$($ExistingContact.id)" -Method PATCH -Body $ContactPayload -Raw
                    } else {
                        $CompanyResult.Logs.Add("Contact $UPN is PSA-synced ($($ExistingContact.attributes.'psa-integration')); not updating, Flex Asset will be written.")
                    }
                } elseif ($CreateMissing) {
                    $null = Invoke-ITGlueRequest -Path "/organizations/$OrgId/relationships/contacts" -Method POST -Body $ContactPayload -Raw
                }
            } catch {
                $cMsg = $_.Exception.Message
                $cDetail = ''
                try {
                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        $Parsed = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                        if ($Parsed.errors) { $cDetail = ' | ' + (($Parsed.errors | ForEach-Object { "$($_.title): $($_.detail)" }) -join '; ') }
                    }
                } catch {}
                Write-LogMessage -API 'ITGlueSync' -tenant $Tenant.defaultDomainName -message "Contact upsert failed for ${UPN}: ${cMsg}${cDetail}" -sev Warning
                # Do not rethrow — let the Flex Asset attempt continue.
            }

            # ----- Flex Asset upsert -----
            $UserLicenses = ($User.assignedLicenses.skuId | ForEach-Object {
                $sid = $_
                ($Cache.Licenses | Where-Object { $_.skuId -eq $sid } | Select-Object -First 1).skuPartNumber
            }) -join ', '

            $UserGroups = ($Cache.Groups | Where-Object { $_.members.id -contains $User.id }).displayName -join '<br>'
            $UserRoles  = ($Cache.AllRoles | Where-Object { $_.members.id -contains $User.id }).displayName -join '<br>'
            $UserDevices = $Cache.Devices | Where-Object { $_.userId -eq $User.id -or $_.userPrincipalName -eq $UPN }

            $Mailbox = $Cache.Mailboxes | Where-Object { $_.userPrincipalName -eq $UPN -or $_.PrimarySmtpAddress -eq $UPN } | Select-Object -First 1
            $MailboxUsage = $Cache.MailboxUsage | Where-Object { $_.userPrincipalName -eq $UPN } | Select-Object -First 1
            $OneDrive = $Cache.OneDriveUsage | Where-Object { $_.userPrincipalName -eq $UPN } | Select-Object -First 1

            $OverviewRows = @(
                Get-ITGlueFormattedField -Title 'Display Name'        -Value "$($User.displayName)"
                Get-ITGlueFormattedField -Title 'User Principal Name' -Value $UPN
                Get-ITGlueFormattedField -Title 'Object ID'           -Value "$($User.id)"
                Get-ITGlueFormattedField -Title 'Account Enabled'     -Value "$($User.accountEnabled)"
                Get-ITGlueFormattedField -Title 'Job Title'           -Value "$($User.jobTitle)"
                Get-ITGlueFormattedField -Title 'Office Location'     -Value "$($User.officeLocation)"
                Get-ITGlueFormattedField -Title 'Mobile Phone'        -Value "$($User.mobilePhone)"
                Get-ITGlueFormattedField -Title 'Licenses'            -Value $UserLicenses
            ) -join "`n"

            $Bodies = @( Get-ITGlueFormattedBlock -Heading 'User Overview' -Body $OverviewRows )

            if ($Mailbox) {
                $MailRows = @(
                    Get-ITGlueFormattedField -Title 'Primary SMTP'       -Value "$($Mailbox.PrimarySmtpAddress)"
                    Get-ITGlueFormattedField -Title 'Mailbox Type'       -Value "$($Mailbox.RecipientTypeDetails)"
                    Get-ITGlueFormattedField -Title 'Forwarding Address' -Value "$($Mailbox.ForwardingSmtpAddress)"
                ) -join "`n"
                $Bodies += Get-ITGlueFormattedBlock -Heading 'Mailbox' -Body $MailRows
            }
            if ($MailboxUsage) {
                $Rows = @(
                    Get-ITGlueFormattedField -Title 'Storage Used (MB)' -Value "$([math]::Round($MailboxUsage.StorageUsedInBytes / 1MB,2))"
                    Get-ITGlueFormattedField -Title 'Item Count'        -Value "$($MailboxUsage.ItemCount)"
                ) -join "`n"
                $Bodies += Get-ITGlueFormattedBlock -Heading 'Mailbox Usage' -Body $Rows
            }
            if ($OneDrive) {
                $Rows = @(
                    Get-ITGlueFormattedField -Title 'Storage Used (MB)' -Value "$([math]::Round($OneDrive.StorageUsedInBytes / 1MB,2))"
                    Get-ITGlueFormattedField -Title 'File Count'        -Value "$($OneDrive.FileCount)"
                ) -join "`n"
                $Bodies += Get-ITGlueFormattedBlock -Heading 'OneDrive' -Body $Rows
            }
            if ($UserGroups) { $Bodies += Get-ITGlueFormattedBlock -Heading 'Groups' -Body "<tr><td colspan='2' style='padding:4px 8px;'>$UserGroups</td></tr>" }
            if ($UserRoles)  { $Bodies += Get-ITGlueFormattedBlock -Heading 'Directory Roles' -Body "<tr><td colspan='2' style='padding:4px 8px;'>$UserRoles</td></tr>" }
            if ($UserDevices) {
                $DevList = ($UserDevices | ForEach-Object { "$($_.deviceName) ($($_.operatingSystem))" }) -join '<br>'
                $Bodies += Get-ITGlueFormattedBlock -Heading 'Intune Devices' -Body "<tr><td colspan='2' style='padding:4px 8px;'>$DevList</td></tr>"
            }
            if ($CIPPURL) {
                $LinkHtml = "<a target='_blank' href='$CIPPURL/identity/administration/users/user?tenantFilter=$($Tenant.defaultDomainName)&userId=$($User.id)'>View in CIPP</a> &nbsp;|&nbsp; " +
                            "<a target='_blank' href='https://entra.microsoft.com/$($Tenant.defaultDomainName)/#blade/Microsoft_AAD_IAM/UserDetailsMenuBlade/Profile/userId/$($User.id)'>Entra ID</a>"
                $Bodies += Get-ITGlueFormattedBlock -Heading 'Management Links' -Body "<tr><td colspan='2' style='padding:4px 8px;'>$LinkHtml</td></tr>"
            }

            $RichTextBody = $Bodies -join "`n"

            $Traits = @{
                'name'                       = "$($User.displayName) - $UPN"
                'email-address'              = $UPN
                'microsoft-365-object-id'    = "$($User.id)"
                'microsoft-365'              = $RichTextBody
            }

            $ExistingAsset = $ExistingAssets | Where-Object { $_.attributes.traits.'microsoft-365-object-id' -eq $User.id } | Select-Object -First 1

            $AssetPayload = @{
                data = @{
                    type       = 'flexible-assets'
                    attributes = @{
                        'organization-id'         = [int]$OrgId
                        'flexible-asset-type-id'  = [int]$FlexAssetTypeId
                        traits                    = $Traits
                    }
                }
            }

            if ($ExistingAsset) {
                $null = Invoke-ITGlueRequest -Path "/flexible_assets/$($ExistingAsset.id)" -Method PATCH -Body $AssetPayload -Raw
            } else {
                $null = Invoke-ITGlueRequest -Path '/flexible_assets' -Method POST -Body $AssetPayload -Raw
            }

            $CompanyResult.Users++
        } catch {
            $Msg = $_.Exception.Message
            # Pull the IT Glue JSON:API error body if present for actionable detail
            $Detail = ''
            try {
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $Parsed = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                    if ($Parsed.errors) { $Detail = ' | ' + (($Parsed.errors | ForEach-Object { "$($_.title): $($_.detail) ($($_.source.pointer))" }) -join '; ') }
                }
            } catch {}
            $FullMsg = "User ${UPN}: ${Msg}${Detail}"
            $CompanyResult.Errors.Add($FullMsg)
            Write-LogMessage -API 'ITGlueSync' -tenant $Tenant.defaultDomainName -message $FullMsg -sev Warning
        }
    }
}

function Initialize-ITGlueUserFlexAssetFields {
    param([Parameter(Mandatory)] $FlexAssetTypeId)

    $Type = Invoke-ITGlueRequest -Path "/flexible_asset_types/$FlexAssetTypeId`?include=flexible_asset_fields" -Raw
    $Existing = @{}
    if ($Type.included) {
        foreach ($Field in $Type.included) {
            if ($Field.type -eq 'flexible-asset-fields') {
                $Existing[$Field.attributes.'name-key'] = $true
            }
        }
    }

    $Required = @(
        @{ name = 'Name';                    type = 'Text';       'show-in-list' = $true;  'required' = $true  }
        @{ name = 'Email Address';           type = 'Text';       'show-in-list' = $true;  'required' = $false }
        @{ name = 'Microsoft 365 Object ID'; type = 'Text';       'show-in-list' = $false; 'required' = $false }
        @{ name = 'Microsoft 365';           type = 'Textbox';    'show-in-list' = $false; 'required' = $false }
    )

    foreach ($Field in $Required) {
        $Key = ($Field.name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        if (-not $Existing.ContainsKey($Key)) {
            $Payload = @{
                data = @{
                    type       = 'flexible_asset_fields'
                    attributes = @{
                        'flexible-asset-type-id' = [int]$FlexAssetTypeId
                        'name'         = $Field.name
                        'kind'         = $Field.type
                        'show-in-list' = $Field.'show-in-list'
                        'required'     = $Field.'required'
                    }
                }
            }
            try { $null = Invoke-ITGlueRequest -Path '/flexible_asset_fields' -Method POST -Body $Payload -Raw } catch {
                Write-Warning ("Could not create flex asset field '{0}' on type {1}: {2}" -f $Field.name, $FlexAssetTypeId, $_.Exception.Message)
            }
        }
    }
}

# ---------- DEVICES ----------
function Sync-ITGlueDevices {
    param($OrgId, $Tenant, $Cache, $ConfigTypeId, [bool]$CreateMissing, $ExcludeSerials, $CompanyResult)

    $ExistingConfigs = Invoke-ITGlueRequest -Path "/organizations/$OrgId/relationships/configurations" -AllPages
    $IntuneDesktopDeviceTypes = @('windows', 'windowsrt', 'macmdm', 'macos', 'mac')

    $RawCount = ($Cache.Devices | Measure-Object).Count
    $Devices = $Cache.Devices | Where-Object {
        $osMatch = ($_.operatingSystem -and ($IntuneDesktopDeviceTypes -contains ($_.operatingSystem.ToString().ToLower())))
        $typeMatch = ($_.deviceType -and ($IntuneDesktopDeviceTypes -contains ($_.deviceType.ToString().ToLower())))
        ($osMatch -or $typeMatch) -and ($_.serialNumber -and $ExcludeSerials -notcontains $_.serialNumber)
    }
    $CompanyResult.Logs.Add("Devices: $RawCount in cache, $(($Devices | Measure-Object).Count) sync-eligible after filter, CreateMissing=$CreateMissing")

    foreach ($Device in $Devices) {
        try {
            $Match = $ExistingConfigs | Where-Object {
                ($_.attributes.'serial-number' -and $_.attributes.'serial-number' -eq $Device.serialNumber) -or
                ($_.attributes.notes -and $_.attributes.notes -match [regex]::Escape("intune-id:$($Device.id)"))
            } | Select-Object -First 1

            $Notes = @"
intune-id:$($Device.id)
azure-ad-id:$($Device.azureADDeviceId)
last-sync:$($Device.lastSyncDateTime)
compliance:$($Device.complianceState)
enrolled-by:$($Device.userPrincipalName)
"@

            $Payload = @{
                data = @{
                    type       = 'configurations'
                    attributes = @{
                        'organization-id'       = [int]$OrgId
                        'configuration-type-id' = [int]$ConfigTypeId
                        'name'                  = "$($Device.deviceName)"
                        'hostname'              = "$($Device.deviceName)"
                        'serial-number'         = "$($Device.serialNumber)"
                        'mac-address'           = "$($Device.wiFiMacAddress)"
                        'operating-system-notes'= "$($Device.operatingSystem) $($Device.osVersion)"
                        'notes'                 = $Notes
                    }
                }
            }
            if ($Device.manufacturer) { $Payload.data.attributes['manufacturer-name'] = "$($Device.manufacturer)" }
            if ($Device.model)        { $Payload.data.attributes['model-name']        = "$($Device.model)" }

            if ($Match) {
                # PSA-synced configurations are owned by the integration; IT Glue only allows updating a small
                # whitelist of attributes and rejects the rest. Skip the update entirely — ConnectWise wins.
                if (-not [string]::IsNullOrEmpty($Match.attributes.'psa-integration')) {
                    $CompanyResult.Logs.Add("Configuration $($Device.deviceName) is PSA-synced ($($Match.attributes.'psa-integration')); not updating.")
                    continue
                }
                $null = Invoke-ITGlueRequest -Path "/configurations/$($Match.id)" -Method PATCH -Body $Payload -Raw
            } elseif ($CreateMissing) {
                $null = Invoke-ITGlueRequest -Path "/organizations/$OrgId/relationships/configurations" -Method POST -Body $Payload -Raw
            } else {
                continue
            }

            $CompanyResult.Devices++
        } catch {
            $Msg = $_.Exception.Message
            $Detail = ''
            try {
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $Parsed = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                    if ($Parsed.errors) { $Detail = ' | ' + (($Parsed.errors | ForEach-Object { "$($_.title): $($_.detail) ($($_.source.pointer))" }) -join '; ') }
                }
            } catch {}
            $FullMsg = "Device $($Device.deviceName): $Msg$Detail"
            $CompanyResult.Errors.Add($FullMsg)
            Write-LogMessage -API 'ITGlueSync' -tenant $Tenant.defaultDomainName -message $FullMsg -sev Warning
        }
    }
}

# ---------- DOMAINS ----------
function Sync-ITGlueDomains {
    param($OrgId, $Tenant, $Cache, [bool]$Monitor, $CompanyResult)

    $VerifiedDomains = $Cache.Domains | Where-Object { $_.isVerified -eq $true }
    if (-not $VerifiedDomains) {
        $CompanyResult.Logs.Add('No verified M365 domains found; skipping domain sync.')
        return
    }
    $CompanyResult.Logs.Add("Found $(($VerifiedDomains | Measure-Object).Count) verified M365 domains; Monitor=$Monitor")

    $TypeId = Get-ITGlueDomainsFlexAssetTypeId
    if (-not $TypeId) {
        $CompanyResult.Errors.Add('Domains: could not resolve or create the CIPP M365 Domains flex asset type.')
        return
    }

    $ExistingDomainAssets = Invoke-ITGlueRequest -Path "/flexible_assets?filter[organization-id]=$OrgId&filter[flexible-asset-type-id]=$TypeId" -AllPages

    # Optional DNS health enrichment via CIPP's domain analyser cache.
    $DomainHealthMap = @{}
    if ($Monitor) {
        try {
            $Analyser = Get-CIPPDomainAnalyser -TenantFilter $Tenant.defaultDomainName
            foreach ($A in $Analyser) {
                if ($A.Domain) { $DomainHealthMap[$A.Domain.ToLower()] = $A }
            }
            $CompanyResult.Logs.Add("Monitor: pulled $($DomainHealthMap.Count) domain analyser records.")
        } catch {
            $CompanyResult.Logs.Add("Monitor: could not pull domain analyser data: $($_.Exception.Message)")
        }
    }

    foreach ($D in $VerifiedDomains) {
        $DomainName = "$($D.id)"
        try {
            $SupportedServices = if ($D.supportedServices) { ($D.supportedServices -join ', ') } else { '' }
            $AuthType = "$($D.authenticationType)"

            $Rows = @(
                Get-ITGlueFormattedField -Title 'Domain Name'         -Value $DomainName
                Get-ITGlueFormattedField -Title 'Verified'            -Value "$($D.isVerified)"
                Get-ITGlueFormattedField -Title 'Default'             -Value "$($D.isDefault)"
                Get-ITGlueFormattedField -Title 'Initial'             -Value "$($D.isInitial)"
                Get-ITGlueFormattedField -Title 'Root'                -Value "$($D.isRoot)"
                Get-ITGlueFormattedField -Title 'Authentication Type' -Value $AuthType
                Get-ITGlueFormattedField -Title 'Supported Services'  -Value $SupportedServices
                Get-ITGlueFormattedField -Title 'Availability Status' -Value "$($D.availabilityStatus)"
            ) -join "`n"

            $Body = Get-ITGlueFormattedBlock -Heading 'Microsoft 365 Domain' -Body $Rows

            # Monitor: append a DNS health block.
            if ($Monitor) {
                $H = $DomainHealthMap[$DomainName.ToLower()]
                if ($H) {
                    $passText = { param($v) if ($null -eq $v -or $v -eq '') { 'Unknown' } elseif ($v -eq $true) { 'Pass' } else { 'Fail' } }
                    $hRows = @(
                        Get-ITGlueFormattedField -Title 'Score'              -Value ("{0} / {1} ({2}%)" -f $H.Score, $H.MaximumScore, $H.ScorePercentage)
                        Get-ITGlueFormattedField -Title 'MX Test'            -Value (& $passText $H.MXPassTest)
                        Get-ITGlueFormattedField -Title 'SPF Pass All'       -Value (& $passText $H.SPFPassAll)
                        Get-ITGlueFormattedField -Title 'SPF Record'         -Value "$($H.ActualSPFRecord)"
                        Get-ITGlueFormattedField -Title 'DMARC Present'      -Value "$($H.DMARCPresent)"
                        Get-ITGlueFormattedField -Title 'DMARC Action'       -Value "$($H.DMARCActionPolicy)"
                        Get-ITGlueFormattedField -Title 'DMARC Reporting'    -Value "$($H.DMARCReportingActive)"
                        Get-ITGlueFormattedField -Title 'DKIM Enabled'       -Value "$($H.DKIMEnabled)"
                        Get-ITGlueFormattedField -Title 'MX Records'         -Value (($H.ActualMXRecords -join '<br>'))
                    ) -join "`n"
                    $Body += "`n" + (Get-ITGlueFormattedBlock -Heading 'DNS Health (CIPP Domain Analyser)' -Body $hRows)
                    if ($H.ScoreExplanation) {
                        $explanation = $H.ScoreExplanation -join '<br>'
                        $Body += "`n" + (Get-ITGlueFormattedBlock -Heading 'Score Explanation' -Body "<tr><td colspan='2' style='padding:4px 8px;'>$explanation</td></tr>")
                    }
                } else {
                    $Body += "`n<p><em>No CIPP domain analyser data found yet for $DomainName. Run a tenant refresh and try again.</em></p>"
                }
            }

            $Traits = @{
                'name'                 = $DomainName
                'verified'             = "$($D.isVerified)"
                'default'              = "$($D.isDefault)"
                'authentication-type'  = $AuthType
                'supported-services'   = $SupportedServices
                'microsoft-365'        = $Body
            }

            $ExistingAsset = $ExistingDomainAssets | Where-Object { $_.attributes.traits.name -eq $DomainName } | Select-Object -First 1

            $Payload = @{
                data = @{
                    type       = 'flexible-assets'
                    attributes = @{
                        'organization-id'        = [int]$OrgId
                        'flexible-asset-type-id' = [int]$TypeId
                        traits                   = $Traits
                    }
                }
            }

            if ($ExistingAsset) {
                $null = Invoke-ITGlueRequest -Path "/flexible_assets/$($ExistingAsset.id)" -Method PATCH -Body $Payload -Raw
            } else {
                $null = Invoke-ITGlueRequest -Path '/flexible_assets' -Method POST -Body $Payload -Raw
            }
        } catch {
            $Msg = $_.Exception.Message
            $Detail = ''
            try {
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $Parsed = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                    if ($Parsed.errors) { $Detail = ' | ' + (($Parsed.errors | ForEach-Object { "$($_.title): $($_.detail)" }) -join '; ') }
                }
            } catch {}
            $Full = "Domain ${DomainName}: ${Msg}${Detail}"
            $CompanyResult.Errors.Add($Full)
            Write-LogMessage -API 'ITGlueSync' -tenant $Tenant.defaultDomainName -message $Full -sev Warning
        }
    }
}

# Ensure the "CIPP M365 Domains" flex asset type exists, creating it (with required fields) if not.
# Returns the integer type ID, or $null on hard failure. Caches the result on $script: scope for the run.
function Get-ITGlueDomainsFlexAssetTypeId {
    if ($script:ITGlueDomainsFlexAssetTypeId) { return $script:ITGlueDomainsFlexAssetTypeId }

    $TypeName = 'CIPP M365 Domains'

    # Try to find an existing type by name (paged).
    $AllTypes = Invoke-ITGlueRequest -Path '/flexible_asset_types' -AllPages
    $Match = $AllTypes | Where-Object { $_.attributes.name -eq $TypeName } | Select-Object -First 1
    if ($Match) {
        $script:ITGlueDomainsFlexAssetTypeId = [int]$Match.id
        return $script:ITGlueDomainsFlexAssetTypeId
    }

    # Otherwise create it with the required fields inline.
    $CreatePayload = @{
        data = @{
            type       = 'flexible_asset_types'
            attributes = @{
                name          = $TypeName
                description   = 'Microsoft 365 verified domains synced by CIPP. One row per domain.'
                icon          = 'globe'
                enabled       = $true
                'show-in-menu'= $true
            }
            relationships = @{
                'flexible-asset-fields' = @{
                    data = @(
                        @{ type = 'flexible_asset_fields'; attributes = @{ order = 1; name = 'Name';                kind = 'Text';    required = $true;  'show-in-list' = $true;  'use-for-title' = $true } }
                        @{ type = 'flexible_asset_fields'; attributes = @{ order = 2; name = 'Verified';            kind = 'Text';    required = $false; 'show-in-list' = $true } }
                        @{ type = 'flexible_asset_fields'; attributes = @{ order = 3; name = 'Default';             kind = 'Text';    required = $false; 'show-in-list' = $true } }
                        @{ type = 'flexible_asset_fields'; attributes = @{ order = 4; name = 'Authentication Type'; kind = 'Text';    required = $false; 'show-in-list' = $false } }
                        @{ type = 'flexible_asset_fields'; attributes = @{ order = 5; name = 'Supported Services';  kind = 'Text';    required = $false; 'show-in-list' = $false } }
                        @{ type = 'flexible_asset_fields'; attributes = @{ order = 6; name = 'Microsoft 365';       kind = 'Textbox'; required = $false; 'show-in-list' = $false } }
                    )
                }
            }
        }
    }

    try {
        $Created = Invoke-ITGlueRequest -Path '/flexible_asset_types' -Method POST -Body $CreatePayload -Raw
        if ($Created.data.id) {
            $script:ITGlueDomainsFlexAssetTypeId = [int]$Created.data.id
            return $script:ITGlueDomainsFlexAssetTypeId
        }
    } catch {
        Write-Warning ("Failed to create '{0}' flex asset type: {1}" -f $TypeName, $_.Exception.Message)
    }
    return $null
}
