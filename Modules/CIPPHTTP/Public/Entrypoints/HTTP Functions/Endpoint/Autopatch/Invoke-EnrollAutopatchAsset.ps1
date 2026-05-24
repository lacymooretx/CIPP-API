using namespace System.Net

function Invoke-EnrollAutopatchAsset {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.ReadWrite
    .DESCRIPTION
        Enrolls one or more Azure AD Windows device IDs into Windows Autopatch update management
        for the selected update categories.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $null

    try {
        $TenantFilter = Get-CIPPAutopatchTenantFilter -Request $Request
        $DeviceInput = Get-CIPPAutopatchRequestValue -Request $Request -Names @('deviceIds', 'DeviceIds', 'deviceId', 'DeviceId', 'azureADDeviceIds', 'AzureADDeviceIds', 'ids', 'Ids')
        $Categories = ConvertTo-CIPPAutopatchCategoryList -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('categories', 'Categories', 'updateCategories', 'UpdateCategories'))
        $ResolvedDevices = Resolve-CIPPAutopatchDeviceIds -TenantFilter $TenantFilter -DeviceIds $DeviceInput

        if ($ResolvedDevices.resolvedDeviceIds.Count -eq 0) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = [PSCustomObject]@{ error = 'At least one Azure AD device ID is required.' }
                })
        }

        $Results = Add-CIPPAutopatchAssetEnrollment -TenantFilter $TenantFilter -DeviceIds $ResolvedDevices.resolvedDeviceIds -Categories $Categories
        $FailedResults = @($Results | Where-Object { -not $_.success })

        $Body = [PSCustomObject]@{
            tenantFilter        = $TenantFilter
            requestedDeviceIds  = @($ResolvedDevices.requestedDeviceIds)
            resolvedDeviceIds   = @($ResolvedDevices.resolvedDeviceIds)
            unresolvedDeviceIds = @($ResolvedDevices.unresolvedDeviceIds)
            categories          = @($Categories)
            Results             = @($Results)
            failedCount         = $FailedResults.Count
        }

        $Message = "Enrolled $($ResolvedDevices.resolvedDeviceIds.Count) device(s) into Autopatch categories: $($Categories -join ', ')"
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -Sev Info -LogData $Body
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "EnrollAutopatchAsset failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
