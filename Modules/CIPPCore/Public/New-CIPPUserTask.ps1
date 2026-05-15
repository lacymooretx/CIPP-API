function New-CIPPUserTask {
    [CmdletBinding()]
    param (
        $UserObj,
        $APIName = 'New User Task',
        $TenantFilter,
        $Headers
    )
    $Results = [System.Collections.Generic.List[string]]::new()

    try {
        $CreationResults = New-CIPPUser -UserObj $UserObj -APIName $APIName -Headers $Headers
        $Results.Add('Created New User.')
        $Results.Add("Username: $($CreationResults.Username)")
        $Results.Add("Password: $($CreationResults.Password)")
    } catch {
        $Results.Add("$($_.Exception.Message)" )
        throw @{'Results' = $Results }
    }

    try {
        if ($UserObj.licenses.value) {
            # Form may submit a CSP SKU as either `cspLicense` (preferred, provider-agnostic)
            # or the legacy `sherwebLicense` (kept for backwards compatibility with older forms).
            $CspSku = $UserObj.cspLicense.value
            if (-not $CspSku) { $CspSku = $UserObj.sherwebLicense.value }
            if ($CspSku) {
                $CspProvider = Get-CIPPCSPProvider -TenantFilter $UserObj.tenantFilter
                if (-not $CspProvider) {
                    throw "No CSP mapping (Pax8 or Sherweb) for tenant $($UserObj.tenantFilter); cannot order CSP license."
                }
                switch ($CspProvider) {
                    'Pax8'    { $null = Set-Pax8Subscription    -Headers $Headers -TenantFilter $UserObj.tenantFilter -SKU $CspSku -Add 1 }
                    'Sherweb' { $null = Set-SherwebSubscription -Headers $Headers -TenantFilter $UserObj.tenantFilter -SKU $CspSku -Add 1 }
                }
                $null = $Results.Add("Added $CspProvider License, scheduling assignment")
                $taskObject = [PSCustomObject]@{
                    TenantFilter  = $UserObj.tenantFilter
                    Name          = "Assign License: $UserPrincipalName"
                    Command       = @{
                        value = 'Set-CIPPUserLicense'
                    }
                    Parameters    = [pscustomobject]@{
                        UserId      = $CreationResults.Username
                        APIName     = "$CspProvider License Assignment"
                        AddLicenses = $UserObj.licenses.value
                    }
                    ScheduledTime = 0 #right now, which is in the next 15 minutes and should cover most cases.
                    PostExecution = @{
                        Webhook = [bool]$Request.Body.PostExecution.webhook
                        Email   = [bool]$Request.Body.PostExecution.email
                        PSA     = [bool]$Request.Body.PostExecution.psa
                    }
                }
                Add-CIPPScheduledTask -Task $taskObject -hidden $false -Headers $Headers
            } else {
                $LicenseResults = Set-CIPPUserLicense -UserId $CreationResults.Username -TenantFilter $UserObj.tenantFilter -AddLicenses $UserObj.licenses.value -Headers $Headers
                $Results.Add($LicenseResults)
            }
        }
    } catch {
        Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Failed to assign the license. Error:$($_.Exception.Message)" -Sev 'Error'
        $Results.Add("Failed to assign the license. $($_.Exception.Message)")
    }

    try {
        if ($UserObj.AddedAliases) {
            $AliasResults = Add-CIPPAlias -User $CreationResults.Username -Aliases ($UserObj.AddedAliases -split '\s') -UserPrincipalName $CreationResults.Username -TenantFilter $UserObj.tenantFilter -APIName $APIName -Headers $Headers
            $Results.Add($AliasResults)
        }
    } catch {
        Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Failed to create the Aliases. Error:$($_.Exception.Message)" -Sev 'Error'
        $Results.Add("Failed to create the Aliases: $($_.Exception.Message)")
    }
    if ($UserObj.copyFrom.value) {
        Write-Host "Copying from $($UserObj.copyFrom.value)"
        $CopyFrom = Set-CIPPCopyGroupMembers -Headers $Headers -CopyFromId $UserObj.copyFrom.value -UserID $CreationResults.Username -TenantFilter $UserObj.tenantFilter
        $CopyFrom.Success | ForEach-Object { $Results.Add($_) }
        $CopyFrom.Error | ForEach-Object { $Results.Add($_) }
    }

    # Add to groups
    if ($UserObj.AddToGroups) {
        $UserObj.AddToGroups | ForEach-Object {
            try {
                $AddMemberResult = Add-CIPPGroupMember -Headers $Headers -GroupType $_.addedFields.groupType -GroupId $_.value -Member @($CreationResults.Username) -TenantFilter $UserObj.tenantFilter
                $Results.Add($AddMemberResult)
            } catch {
                $Results.Add("Failed to add to group $($_.label): $_")
            }
        }
    }

    if ($UserObj.setManager) {
        $ManagerResults = Set-CIPPManager -Users $CreationResults.Username -Manager $UserObj.setManager.value -TenantFilter $UserObj.tenantFilter -Headers $Headers
        $Results.Add($ManagerResults.Result)
    }

    if ($UserObj.setSponsor) {
        $SponsorResults = Set-CIPPSponsor -Users $CreationResults.Username -Sponsor $UserObj.setSponsor.value -TenantFilter $UserObj.tenantFilter -Headers $Headers
        $Results.Add($SponsorResults.Result)
    }

    return @{
        Results  = $Results
        Username = $CreationResults.Username
        Password = $CreationResults.Password
        CopyFrom = $CopyFrom
        User     = $CreationResults.User
    }
}
