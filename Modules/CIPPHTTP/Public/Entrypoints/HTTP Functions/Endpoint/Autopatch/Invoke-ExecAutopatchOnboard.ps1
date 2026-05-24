using namespace System.Net

function Invoke-ExecAutopatchOnboard {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.ReadWrite
    .DESCRIPTION
        Onboards a tenant to Windows Autopatch by bucketing Windows managed devices into
        deployment audiences and creating driver and quality update policies for each bucket.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $null

    try {
        $TenantFilter = Get-CIPPAutopatchTenantFilter -Request $Request
        $Force = ConvertTo-CIPPAutopatchBoolean -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('force', 'Force', 'overwrite', 'Overwrite')) -Default $false
        $Categories = ConvertTo-CIPPAutopatchCategoryList -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('categories', 'Categories', 'updateCategories', 'UpdateCategories'))

        if (-not $Force) {
            $ExistingState = Get-CIPPAutopatchState -TenantFilter $TenantFilter
            if ($ExistingState.summary.isEnrolled) {
                return ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::Conflict
                        Body       = [PSCustomObject]@{
                            error        = 'This tenant already has Windows Autopatch policies, audiences, or enrolled assets. Submit force=true to create additional Autopatch configuration.'
                            tenantFilter = $TenantFilter
                            summary      = $ExistingState.summary
                        }
                    })
            }
        }

        $ManagedDevices = @(Get-CIPPAutopatchManagedDevices -TenantFilter $TenantFilter)
        if ($ManagedDevices.Count -eq 0) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = [PSCustomObject]@{ error = 'No Windows Intune managed devices with Azure AD device IDs were found.'; tenantFilter = $TenantFilter }
                })
        }

        $RingDefinitions = @(
            [PSCustomObject]@{ name = 'Test'; pattern = '^[01]' }
            [PSCustomObject]@{ name = 'Ring 1'; pattern = '^[2-7]' }
            [PSCustomObject]@{ name = 'Last'; pattern = '^[89a-f]' }
        )

        $Results = foreach ($Ring in $RingDefinitions) {
            $RingDeviceIds = @($ManagedDevices | Where-Object { $_.azureADDeviceId -match $Ring.pattern } | ForEach-Object { $_.azureADDeviceId })
            if ($RingDeviceIds.Count -eq 0) {
                [PSCustomObject]@{
                    ringName    = $Ring.name
                    skipped     = $true
                    reason      = 'No devices matched this bucket.'
                    deviceCount = 0
                }
                continue
            }

            New-CIPPAutopatchRingBuild -TenantFilter $TenantFilter -RingName $Ring.name -DeviceIds $RingDeviceIds -Categories $Categories
        }

        $Body = [PSCustomObject]@{
            tenantFilter       = $TenantFilter
            managedDeviceCount = $ManagedDevices.Count
            categories         = @($Categories)
            Results            = @($Results)
        }

        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Onboarded tenant to Autopatch with $($ManagedDevices.Count) Windows managed device(s)." -Sev Info -LogData $Body
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "ExecAutopatchOnboard failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
