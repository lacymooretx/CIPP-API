using namespace System.Net

function Invoke-ListAutopatchEnrollmentStatus {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.Read
    .DESCRIPTION
        Returns Windows Autopatch enrollment status joined to Intune managed device inventory.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $null

    try {
        $TenantFilter = Get-CIPPAutopatchTenantFilter -Request $Request
        $IncludeUnenrolled = ConvertTo-CIPPAutopatchBoolean -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('includeUnenrolled', 'IncludeUnenrolled')) -Default $true
        $DeviceFilter = ConvertTo-CIPPAutopatchList -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('deviceIds', 'DeviceIds', 'deviceId', 'DeviceId', 'azureADDeviceIds', 'AzureADDeviceIds', 'ids', 'Ids'))
        $State = Get-CIPPAutopatchState -TenantFilter $TenantFilter -IncludeManagedDevices
        $Results = @($State.enrollmentStatus)

        if (-not $IncludeUnenrolled) {
            $Results = @($Results | Where-Object { $_.isEnrolled })
        }

        if ($DeviceFilter.Count -gt 0) {
            $Lookup = @($DeviceFilter | ForEach-Object { $_.ToLowerInvariant() })
            $Results = @($Results | Where-Object {
                    $Lookup -contains ([string]$_.azureADDeviceId).ToLowerInvariant() -or
                    $Lookup -contains ([string]$_.id).ToLowerInvariant() -or
                    $Lookup -contains ([string]$_.deviceName).ToLowerInvariant() -or
                    $Lookup -contains ([string]$_.serialNumber).ToLowerInvariant()
                })
        }

        $Body = [PSCustomObject]@{
            tenantFilter = $TenantFilter
            Results      = @($Results)
            Metadata     = [PSCustomObject]@{
                count              = $Results.Count
                includeUnenrolled  = $IncludeUnenrolled
                policyCount        = $State.summary.policyCount
                audienceCount      = $State.summary.audienceCount
                assetCount         = $State.summary.assetCount
                managedDeviceCount = $State.summary.managedDeviceCount
                warnings           = @($State.warnings)
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "ListAutopatchEnrollmentStatus failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
