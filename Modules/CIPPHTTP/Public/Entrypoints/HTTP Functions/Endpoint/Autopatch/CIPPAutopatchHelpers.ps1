function Get-CIPPAutopatchPropertyValue {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Object -is [hashtable] -and $Object.ContainsKey($Name)) {
        return $Object[$Name]
    }

    $Property = $Object.PSObject.Properties[$Name]
    if ($Property) {
        return $Property.Value
    }

    return $null
}

function Get-CIPPAutopatchRequestValue {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        $Request,
        [string[]]$Names,
        $Default = $null
    )

    foreach ($Name in $Names) {
        $QueryValue = Get-CIPPAutopatchPropertyValue -Object $Request.Query -Name $Name
        if ($null -ne $QueryValue -and $QueryValue -ne '') {
            return $QueryValue
        }

        $BodyValue = Get-CIPPAutopatchPropertyValue -Object $Request.Body -Name $Name
        if ($null -ne $BodyValue -and $BodyValue -ne '') {
            return $BodyValue
        }
    }

    return $Default
}

function Get-CIPPAutopatchTenantFilter {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param($Request)

    $TenantFilter = Get-CIPPAutopatchRequestValue -Request $Request -Names @('tenantFilter', 'TenantFilter', 'tenantId', 'TenantId')
    if ($TenantFilter -and $TenantFilter.PSObject.Properties.Name -contains 'value') {
        $TenantFilter = $TenantFilter.value
    }

    if ([string]::IsNullOrWhiteSpace([string]$TenantFilter)) {
        throw 'tenantFilter is required'
    }

    return [string]$TenantFilter
}

function ConvertTo-CIPPAutopatchBoolean {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        $Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }
    if ($Value -is [bool]) {
        return $Value
    }
    if ($Value.PSObject.Properties.Name -contains 'value') {
        return ConvertTo-CIPPAutopatchBoolean -Value $Value.value -Default $Default
    }

    $Text = ([string]$Value).Trim().ToLowerInvariant()
    switch ($Text) {
        { $_ -in @('true', '1', 'yes', 'y', 'on') } { return $true }
        { $_ -in @('false', '0', 'no', 'n', 'off') } { return $false }
        default { return [bool]$Value }
    }
}

function ConvertTo-CIPPAutopatchList {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        $Value,
        [string[]]$Default = @(),
        [switch]$ToLower
    )

    $Items = [System.Collections.Generic.List[string]]::new()

    function Add-CIPPAutopatchListItem {
        param($Item)

        if ($null -eq $Item) {
            return
        }

        if ($Item -is [string]) {
            $Text = $Item.Trim()
            if ([string]::IsNullOrWhiteSpace($Text)) {
                return
            }

            if ($Text.StartsWith('[') -or $Text.StartsWith('{')) {
                try {
                    $JsonValue = $Text | ConvertFrom-Json -ErrorAction Stop
                    Add-CIPPAutopatchListItem -Item $JsonValue
                    return
                } catch {
                    # Fall through to delimiter splitting.
                }
            }

            foreach ($Part in ($Text -split '[,;\r\n]+')) {
                $CleanPart = $Part.Trim()
                if (-not [string]::IsNullOrWhiteSpace($CleanPart)) {
                    $Items.Add($ToLower.IsPresent ? $CleanPart.ToLowerInvariant() : $CleanPart)
                }
            }
            return
        }

        if ($Item -is [System.Collections.DictionaryEntry]) {
            Add-CIPPAutopatchListItem -Item $Item.Value
            return
        }

        if ($Item -is [hashtable]) {
            if ($Item.ContainsKey('value')) {
                Add-CIPPAutopatchListItem -Item $Item['value']
                return
            }
            if ($Item.ContainsKey('id')) {
                Add-CIPPAutopatchListItem -Item $Item['id']
                return
            }
            foreach ($HashValue in $Item.Values) {
                Add-CIPPAutopatchListItem -Item $HashValue
            }
            return
        }

        if ($Item.PSObject.Properties.Name -contains 'value') {
            Add-CIPPAutopatchListItem -Item $Item.value
            return
        }

        if ($Item.PSObject.Properties.Name -contains 'id') {
            Add-CIPPAutopatchListItem -Item $Item.id
            return
        }

        if ($Item -is [System.Collections.IEnumerable]) {
            foreach ($NestedItem in $Item) {
                Add-CIPPAutopatchListItem -Item $NestedItem
            }
            return
        }

        Add-CIPPAutopatchListItem -Item ([string]$Item)
    }

    Add-CIPPAutopatchListItem -Item $Value

    if ($Items.Count -eq 0 -and $Default.Count -gt 0) {
        foreach ($DefaultItem in $Default) {
            $Items.Add($ToLower.IsPresent ? $DefaultItem.ToLowerInvariant() : $DefaultItem)
        }
    }

    return @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function ConvertTo-CIPPAutopatchCategoryList {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        $Value,
        [string[]]$Default = @('driver', 'quality')
    )

    $Categories = ConvertTo-CIPPAutopatchList -Value $Value -Default $Default -ToLower
    $AllowedCategories = @('driver', 'quality')
    $InvalidCategories = @($Categories | Where-Object { $AllowedCategories -notcontains $_ })

    if ($InvalidCategories.Count -gt 0) {
        throw "Unsupported Autopatch update category: $($InvalidCategories -join ', '). Supported categories are: $($AllowedCategories -join ', ')."
    }

    return @($Categories)
}

function Get-CIPPAutopatchManagedDevices {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter
    )

    $Uri = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$select=id,azureADDeviceId,deviceName,userPrincipalName,operatingSystem,osVersion,complianceState,lastSyncDateTime,enrolledDateTime,managedDeviceOwnerType,serialNumber,manufacturer,model&$top=999'
    $ManagedDevices = New-GraphGetRequest -uri $Uri -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop

    return @($ManagedDevices | Where-Object {
            $_.operatingSystem -match 'Windows' -and -not [string]::IsNullOrWhiteSpace([string]$_.azureADDeviceId)
        })
}

function Resolve-CIPPAutopatchDeviceIds {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        $DeviceIds,
        [array]$ManagedDevices = $null
    )

    $RequestedDeviceIds = ConvertTo-CIPPAutopatchList -Value $DeviceIds
    if ($RequestedDeviceIds.Count -eq 0) {
        return [PSCustomObject]@{
            requestedDeviceIds = @()
            resolvedDeviceIds  = @()
            unresolvedDeviceIds = @()
            devices            = @()
        }
    }

    if ($null -eq $ManagedDevices) {
        try {
            $ManagedDevices = Get-CIPPAutopatchManagedDevices -TenantFilter $TenantFilter
        } catch {
            $ManagedDevices = @()
        }
    }

    $DeviceLookup = @{}
    foreach ($Device in @($ManagedDevices)) {
        foreach ($LookupValue in @($Device.azureADDeviceId, $Device.id, $Device.deviceName, $Device.serialNumber)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$LookupValue)) {
                $DeviceLookup[[string]$LookupValue.ToLowerInvariant()] = $Device
            }
        }
    }

    $ResolvedDeviceIds = [System.Collections.Generic.List[string]]::new()
    $ResolvedDevices = [System.Collections.Generic.List[object]]::new()
    $UnresolvedDeviceIds = [System.Collections.Generic.List[string]]::new()

    foreach ($RequestedDeviceId in $RequestedDeviceIds) {
        $LookupKey = [string]$RequestedDeviceId.ToLowerInvariant()
        if ($DeviceLookup.ContainsKey($LookupKey)) {
            $Device = $DeviceLookup[$LookupKey]
            if (-not [string]::IsNullOrWhiteSpace([string]$Device.azureADDeviceId)) {
                $ResolvedDeviceIds.Add([string]$Device.azureADDeviceId)
                $ResolvedDevices.Add($Device)
            } else {
                $UnresolvedDeviceIds.Add($RequestedDeviceId)
            }
        } else {
            $ResolvedDeviceIds.Add($RequestedDeviceId)
        }
    }

    return [PSCustomObject]@{
        requestedDeviceIds = @($RequestedDeviceIds)
        resolvedDeviceIds  = @($ResolvedDeviceIds | Select-Object -Unique)
        unresolvedDeviceIds = @($UnresolvedDeviceIds | Select-Object -Unique)
        devices            = @($ResolvedDevices)
    }
}

function New-CIPPAutopatchAssetObject {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string[]]$DeviceIds
    )

    return @($DeviceIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | ForEach-Object {
            @{
                '@odata.type' = '#microsoft.graph.windowsUpdates.azureADDevice'
                id            = $_
            }
        })
}

function Add-CIPPAutopatchAssetEnrollment {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [string[]]$DeviceIds,
        [string[]]$Categories
    )

    $Assets = New-CIPPAutopatchAssetObject -DeviceIds $DeviceIds
    if ($Assets.Count -eq 0) {
        throw 'At least one Azure AD device ID is required.'
    }

    $Results = foreach ($Category in $Categories) {
        try {
            $Body = @{
                updateCategory = $Category
                assets         = @($Assets)
            } | ConvertTo-Json -Depth 20 -Compress
            $Response = New-GraphPOSTRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/enrollAssets' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -body $Body -ErrorAction Stop
            [PSCustomObject]@{
                category = $Category
                success  = $true
                response = $Response
            }
        } catch {
            $ErrorMessage = Get-CippException -Exception $_
            [PSCustomObject]@{
                category = $Category
                success  = $false
                error    = $ErrorMessage.NormalizedError
            }
        }
    }

    return @($Results)
}

function Remove-CIPPAutopatchAssetEnrollment {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [string[]]$DeviceIds,
        [string[]]$Categories
    )

    $Assets = New-CIPPAutopatchAssetObject -DeviceIds $DeviceIds
    if ($Assets.Count -eq 0) {
        throw 'At least one Azure AD device ID is required.'
    }

    $Results = foreach ($Category in $Categories) {
        try {
            $Body = @{
                updateCategory = $Category
                assets         = @($Assets)
            } | ConvertTo-Json -Depth 20 -Compress
            $Response = New-GraphPOSTRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets/unenrollAssets' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -body $Body -ErrorAction Stop
            [PSCustomObject]@{
                category = $Category
                success  = $true
                response = $Response
            }
        } catch {
            $ErrorMessage = Get-CippException -Exception $_
            [PSCustomObject]@{
                category = $Category
                success  = $false
                error    = $ErrorMessage.NormalizedError
            }
        }
    }

    return @($Results)
}

function New-CIPPAutopatchDeploymentAudience {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter
    )

    $Body = @{
        '@odata.type' = '#microsoft.graph.windowsUpdates.deploymentAudience'
    } | ConvertTo-Json -Depth 10 -Compress

    return New-GraphPOSTRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -body $Body -ErrorAction Stop
}

function Set-CIPPAutopatchAudienceMembers {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [string]$AudienceId,
        [string[]]$AddDeviceIds = @(),
        [string[]]$RemoveDeviceIds = @()
    )

    if ([string]::IsNullOrWhiteSpace($AudienceId)) {
        throw 'Audience ID is required.'
    }

    $BodyObject = @{}
    $AddMembers = New-CIPPAutopatchAssetObject -DeviceIds $AddDeviceIds
    $RemoveMembers = New-CIPPAutopatchAssetObject -DeviceIds $RemoveDeviceIds

    if ($AddMembers.Count -gt 0) {
        $BodyObject['addMembers'] = @($AddMembers)
    }
    if ($RemoveMembers.Count -gt 0) {
        $BodyObject['removeMembers'] = @($RemoveMembers)
    }

    if ($BodyObject.Keys.Count -eq 0) {
        return [PSCustomObject]@{ skipped = $true; reason = 'No audience membership changes supplied.' }
    }

    $Body = $BodyObject | ConvertTo-Json -Depth 20 -Compress
    return New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences/$AudienceId/updateAudience" -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -body $Body -ErrorAction Stop
}

function New-CIPPAutopatchUpdatePolicy {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [string]$AudienceId,
        [ValidateSet('driver', 'quality')]
        [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($AudienceId)) {
        throw 'Audience ID is required.'
    }

    $FilterType = switch ($Category) {
        'driver' { '#microsoft.graph.windowsUpdates.driverUpdateFilter' }
        'quality' { '#microsoft.graph.windowsUpdates.qualityUpdateFilter' }
    }

    $Body = @{
        '@odata.type'                   = '#microsoft.graph.windowsUpdates.updatePolicy'
        audience                        = @{
            id = $AudienceId
        }
        autoEnrollmentUpdateCategories  = @($Category)
        complianceChangeRules           = @(
            @{
                '@odata.type' = '#microsoft.graph.windowsUpdates.contentApprovalRule'
                contentFilter = @{
                    '@odata.type' = $FilterType
                }
            }
        )
    } | ConvertTo-Json -Depth 20 -Compress

    return New-GraphPOSTRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatePolicies' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -body $Body -ErrorAction Stop
}

function Remove-CIPPAutopatchUpdatePolicy {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [string]$PolicyId
    )

    if ([string]::IsNullOrWhiteSpace($PolicyId)) {
        throw 'Policy ID is required.'
    }

    return New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta/admin/windows/updates/updatePolicies/$PolicyId" -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -type DELETE -body '{}' -ErrorAction Stop
}

function Get-CIPPAutopatchPolicyCategory {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param($Policy)

    $Categories = @()
    if ($Policy.autoEnrollmentUpdateCategories) {
        $Categories += @($Policy.autoEnrollmentUpdateCategories)
    }

    foreach ($Rule in @($Policy.complianceChangeRules)) {
        $FilterType = [string]$Rule.contentFilter.'@odata.type'
        if ($FilterType -match 'driverUpdateFilter') {
            $Categories += 'driver'
        } elseif ($FilterType -match 'qualityUpdateFilter') {
            $Categories += 'quality'
        }
    }

    return @($Categories | Where-Object { $_ } | Select-Object -Unique)
}

function Get-CIPPAutopatchState {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [switch]$IncludeManagedDevices,
        [switch]$IncludeAudienceMembers
    )

    $Warnings = [System.Collections.Generic.List[string]]::new()

    $Policies = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatePolicies' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop)
    $Audiences = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop)
    $Assets = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop)

    if ($IncludeAudienceMembers.IsPresent) {
        foreach ($Audience in $Audiences) {
            try {
                $Members = @(New-GraphGetRequest -uri "https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences/$($Audience.id)/members" -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop)
                $Audience | Add-Member -NotePropertyName members -NotePropertyValue $Members -Force
                $Audience | Add-Member -NotePropertyName memberCount -NotePropertyValue $Members.Count -Force
            } catch {
                $Warnings.Add("Could not read members for deployment audience $($Audience.id): $($_.Exception.Message)")
                $Audience | Add-Member -NotePropertyName members -NotePropertyValue @() -Force
                $Audience | Add-Member -NotePropertyName memberCount -NotePropertyValue 0 -Force
            }

            try {
                $Exclusions = @(New-GraphGetRequest -uri "https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences/$($Audience.id)/exclusions" -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop)
                $Audience | Add-Member -NotePropertyName exclusions -NotePropertyValue $Exclusions -Force
                $Audience | Add-Member -NotePropertyName exclusionCount -NotePropertyValue $Exclusions.Count -Force
            } catch {
                $Warnings.Add("Could not read exclusions for deployment audience $($Audience.id): $($_.Exception.Message)")
                $Audience | Add-Member -NotePropertyName exclusions -NotePropertyValue @() -Force
                $Audience | Add-Member -NotePropertyName exclusionCount -NotePropertyValue 0 -Force
            }
        }
    }

    $ManagedDevices = @()
    if ($IncludeManagedDevices.IsPresent) {
        try {
            $ManagedDevices = @(Get-CIPPAutopatchManagedDevices -TenantFilter $TenantFilter)
        } catch {
            $Warnings.Add("Could not read Intune managed devices: $($_.Exception.Message)")
        }
    }

    $ManagedDeviceLookup = @{}
    foreach ($Device in $ManagedDevices) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Device.azureADDeviceId)) {
            $ManagedDeviceLookup[[string]$Device.azureADDeviceId.ToLowerInvariant()] = $Device
        }
    }

    $EnrolledAssetIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $EnrollmentStatus = [System.Collections.Generic.List[object]]::new()

    foreach ($Asset in $Assets) {
        if ([string]::IsNullOrWhiteSpace([string]$Asset.id)) {
            continue
        }

        $null = $EnrolledAssetIds.Add([string]$Asset.id)
        $Device = $ManagedDeviceLookup[[string]$Asset.id.ToLowerInvariant()]
        $EnrollmentCategories = @($Asset.enrollments | ForEach-Object { $_.updateCategory } | Where-Object { $_ } | Select-Object -Unique)

        $EnrollmentStatus.Add([PSCustomObject]@{
                id                   = $Asset.id
                azureADDeviceId      = $Asset.id
                deviceName           = $Device.deviceName
                userPrincipalName    = $Device.userPrincipalName
                operatingSystem      = $Device.operatingSystem
                osVersion            = $Device.osVersion
                complianceState      = $Device.complianceState
                lastSyncDateTime     = $Device.lastSyncDateTime
                enrolledDateTime     = $Device.enrolledDateTime
                serialNumber         = $Device.serialNumber
                manufacturer         = $Device.manufacturer
                model                = $Device.model
                isEnrolled           = $true
                enrollmentCategories = ($EnrollmentCategories -join ', ')
                rawAsset             = $Asset
            })
    }

    if ($IncludeManagedDevices.IsPresent) {
        foreach ($Device in $ManagedDevices) {
            if ([string]::IsNullOrWhiteSpace([string]$Device.azureADDeviceId)) {
                continue
            }
            if ($EnrolledAssetIds.Contains([string]$Device.azureADDeviceId)) {
                continue
            }

            $EnrollmentStatus.Add([PSCustomObject]@{
                    id                   = $Device.azureADDeviceId
                    azureADDeviceId      = $Device.azureADDeviceId
                    deviceName           = $Device.deviceName
                    userPrincipalName    = $Device.userPrincipalName
                    operatingSystem      = $Device.operatingSystem
                    osVersion            = $Device.osVersion
                    complianceState      = $Device.complianceState
                    lastSyncDateTime     = $Device.lastSyncDateTime
                    enrolledDateTime     = $Device.enrolledDateTime
                    serialNumber         = $Device.serialNumber
                    manufacturer         = $Device.manufacturer
                    model                = $Device.model
                    isEnrolled           = $false
                    enrollmentCategories = ''
                    rawAsset             = $null
                })
        }
    }

    $PolicySummary = @($Policies | ForEach-Object {
            $PolicyCategories = Get-CIPPAutopatchPolicyCategory -Policy $_
            [PSCustomObject]@{
                id         = $_.id
                audienceId = $_.audience.id
                categories = ($PolicyCategories -join ', ')
                rawPolicy  = $_
            }
        })

    return [PSCustomObject]@{
        tenantFilter        = $TenantFilter
        updatePolicies      = @($Policies)
        deploymentAudiences = @($Audiences)
        updatableAssets     = @($Assets)
        managedDevices      = @($ManagedDevices)
        enrollmentStatus    = @($EnrollmentStatus)
        policySummary       = @($PolicySummary)
        summary             = [PSCustomObject]@{
            policyCount          = @($Policies).Count
            audienceCount        = @($Audiences).Count
            assetCount           = @($Assets).Count
            managedDeviceCount   = @($ManagedDevices).Count
            enrolledDeviceCount  = @($EnrollmentStatus | Where-Object { $_.isEnrolled }).Count
            unenrolledDeviceCount = @($EnrollmentStatus | Where-Object { -not $_.isEnrolled }).Count
            isEnrolled           = (@($Policies).Count -gt 0 -or @($Audiences).Count -gt 0 -or @($Assets).Count -gt 0)
        }
        warnings            = @($Warnings)
    }
}

function New-CIPPAutopatchRingBuild {
    <#
    .FUNCTIONALITY
        Internal
    #>
    param(
        [string]$TenantFilter,
        [string]$RingName,
        [string[]]$DeviceIds,
        [string[]]$Categories
    )

    if ($DeviceIds.Count -eq 0) {
        throw "No devices supplied for Autopatch ring '$RingName'."
    }

    $Audience = New-CIPPAutopatchDeploymentAudience -TenantFilter $TenantFilter
    $MembershipResult = Set-CIPPAutopatchAudienceMembers -TenantFilter $TenantFilter -AudienceId $Audience.id -AddDeviceIds $DeviceIds
    $EnrollmentResults = Add-CIPPAutopatchAssetEnrollment -TenantFilter $TenantFilter -DeviceIds $DeviceIds -Categories $Categories
    $PolicyResults = foreach ($Category in $Categories) {
        New-CIPPAutopatchUpdatePolicy -TenantFilter $TenantFilter -AudienceId $Audience.id -Category $Category
    }

    return [PSCustomObject]@{
        ringName          = $RingName
        audience          = $Audience
        deviceCount       = $DeviceIds.Count
        categories        = @($Categories)
        membershipResult  = $MembershipResult
        enrollmentResults = @($EnrollmentResults)
        policyResults     = @($PolicyResults)
    }
}
