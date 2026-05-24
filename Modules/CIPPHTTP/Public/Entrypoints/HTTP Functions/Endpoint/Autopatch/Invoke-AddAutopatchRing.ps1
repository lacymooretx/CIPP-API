using namespace System.Net

function Invoke-AddAutopatchRing {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.ReadWrite
    .DESCRIPTION
        Creates a Windows Autopatch deployment audience, adds the supplied devices as members,
        enrolls those devices, and creates update policies for the selected categories.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $null

    try {
        $TenantFilter = Get-CIPPAutopatchTenantFilter -Request $Request
        $RingName = [string](Get-CIPPAutopatchRequestValue -Request $Request -Names @('ringName', 'RingName', 'name', 'Name') -Default 'Autopatch Ring')
        $DeviceInput = Get-CIPPAutopatchRequestValue -Request $Request -Names @('deviceIds', 'DeviceIds', 'deviceId', 'DeviceId', 'azureADDeviceIds', 'AzureADDeviceIds', 'ids', 'Ids')
        $Categories = ConvertTo-CIPPAutopatchCategoryList -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('categories', 'Categories', 'updateCategories', 'UpdateCategories'))
        $ResolvedDevices = Resolve-CIPPAutopatchDeviceIds -TenantFilter $TenantFilter -DeviceIds $DeviceInput

        if ($ResolvedDevices.resolvedDeviceIds.Count -eq 0) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = [PSCustomObject]@{ error = 'At least one Azure AD device ID is required to create an Autopatch ring.' }
                })
        }

        $RingResult = New-CIPPAutopatchRingBuild -TenantFilter $TenantFilter -RingName $RingName -DeviceIds $ResolvedDevices.resolvedDeviceIds -Categories $Categories
        $Body = [PSCustomObject]@{
            tenantFilter        = $TenantFilter
            requestedDeviceIds  = @($ResolvedDevices.requestedDeviceIds)
            resolvedDeviceIds   = @($ResolvedDevices.resolvedDeviceIds)
            unresolvedDeviceIds = @($ResolvedDevices.unresolvedDeviceIds)
            Results             = @($RingResult)
        }

        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Created Autopatch ring '$RingName' with $($ResolvedDevices.resolvedDeviceIds.Count) device(s)." -Sev Info -LogData $Body
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "AddAutopatchRing failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
