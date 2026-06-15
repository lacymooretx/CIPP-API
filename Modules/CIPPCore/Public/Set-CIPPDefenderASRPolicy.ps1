function Set-CIPPDefenderASRPolicy {
    <#
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [string]$TenantFilter,
        $ASR,
        $Headers,
        [string]$APIName,
        [switch]$TemplateOnly
    )

    # Fallback to block mode
    $Mode = $ASR.Mode ?? 'block'

    # Lookup table: ASR input property name -> Graph settingDefinitionId suffix
    $ASRRuleMap = [ordered]@{
        BlockObfuscatedScripts  = 'blockexecutionofpotentiallyobfuscatedscripts'
        BlockAdobeChild         = 'blockadobereaderfromcreatingchildprocesses'
        BlockWin32Macro         = 'blockwin32apicallsfromofficemacros'
        BlockCredentialStealing = 'blockcredentialstealingfromwindowslocalsecurityauthoritysubsystem'
        BlockPSExec             = 'blockprocesscreationsfrompsexecandwmicommands'
        WMIPersistence          = 'blockpersistencethroughwmieventsubscription'
        BlockOfficeExes         = 'blockofficeapplicationsfromcreatingexecutablecontent'
        BlockOfficeApps         = 'blockofficeapplicationsfrominjectingcodeintootherprocesses'
        BlockYoungExe           = 'blockexecutablefilesrunningunlesstheymeetprevalenceagetrustedlistcriterion'
        blockJSVB               = 'blockjavascriptorvbscriptfromlaunchingdownloadedexecutablecontent'
        BlockWebshellForServers = 'blockwebshellcreationforservers'
        blockOfficeComChild     = 'blockofficecommunicationappfromcreatingchildprocesses'
        BlockSystemTools        = 'blockuseofcopiedorimpersonatedsystemtools'
        blockOfficeChild        = 'blockallofficeapplicationsfromcreatingchildprocesses'
        BlockUntrustedUSB       = 'blockuntrustedunsignedprocessesthatrunfromusb'
        EnableRansomwareVac     = 'useadvancedprotectionagainstransomware'
        BlockExesMail           = 'blockexecutablecontentfromemailclientandwebmail'
        BlockUnsignedDrivers    = 'blockabuseofexploitedvulnerablesigneddrivers'
        BlockSafeMode           = 'blockrebootingmachineinsafemode'
    }

    $ASRPrefix = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules'
    $ASRSettings = foreach ($Rule in $ASRRuleMap.GetEnumerator()) {
        if ($ASR.($Rule.Key)) {
            $DefinitionId = "${ASRPrefix}_$($Rule.Value)"
            @{
                '@odata.type'       = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                settingDefinitionId = $DefinitionId
                choiceSettingValue  = @{
                    '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                    value         = "${DefinitionId}_${Mode}"
                }
            }
        }
    }

    # NOTE: This is emitted as a standalone Settings Catalog policy, NOT bound to the
    # Endpoint Security "Attack Surface Reduction Rules" template (e8c053d6-...).
    # When a policy carries that templateReference, Microsoft Graph requires EITHER every
    # rule the template defines to be present in groupSettingCollectionValue.children, OR
    # each child to include its own settingInstanceTemplateReference. Emitting a subset of
    # rules under the template (the common case) therefore failed with
    # "Property children in payload has a value that does not match schema."
    # Dropping the template binding (and the group-level settingInstanceTemplateReference)
    # makes any subset of rules valid while applying the identical ASR CSP settings. The
    # child structure is unchanged, so Standards comparison/reads still parse it correctly.
    $ASRBodyObj = @{
        name            = 'ASR Default rules'
        description     = ''
        platforms       = 'windows10'
        technologies    = 'mdm,microsoftSense'
        roleScopeTagIds = @('0')
        settings        = @(@{
                '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
                settingInstance = @{
                    '@odata.type'               = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
                    settingDefinitionId         = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules'
                    groupSettingCollectionValue = @(@{children = $ASRSettings })
                }
            })
    }

    if ($TemplateOnly) { return $ASRBodyObj }

    $ASRbody = ConvertTo-Json -Depth 15 -Compress -InputObject $ASRBodyObj
    $CheckExistingASR = New-GraphGETRequest -uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -tenantid $TenantFilter
    if ('ASR Default rules' -in $CheckExistingASR.Name) {
        "$($TenantFilter): ASR Policy already exists. Skipping"
    } else {
        Write-Host $ASRbody
        if (($ASRSettings | Measure-Object).Count -gt 0) {
            $ASRRequest = New-GraphPOSTRequest -uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -tenantid $TenantFilter -type POST -body $ASRbody
            Write-Host ($ASRRequest.id)
            if ($ASR.AssignTo -and $ASR.AssignTo -ne 'none') {
                $AssignBody = if ($ASR.AssignTo -ne 'AllDevicesAndUsers') { '{"assignments":[{"id":"","target":{"@odata.type":"#microsoft.graph.' + $($ASR.AssignTo) + 'AssignmentTarget"}}]}' } else { '{"assignments":[{"id":"","target":{"@odata.type":"#microsoft.graph.allDevicesAssignmentTarget"}},{"id":"","target":{"@odata.type":"#microsoft.graph.allLicensedUsersAssignmentTarget"}}]}' }
                $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$($ASRRequest.id)')/assign" -tenantid $TenantFilter -type POST -body $AssignBody
                Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Assigned policy 'ASR Default rules' to $($ASR.AssignTo)" -Sev 'Info'
            }
            "$($TenantFilter): Successfully added ASR Settings"
        }
    }
}
