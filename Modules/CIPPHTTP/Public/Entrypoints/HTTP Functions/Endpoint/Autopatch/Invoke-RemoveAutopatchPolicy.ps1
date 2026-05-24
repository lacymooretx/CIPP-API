using namespace System.Net

function Invoke-RemoveAutopatchPolicy {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.ReadWrite
    .DESCRIPTION
        Deletes a Windows Autopatch update policy by ID.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $null

    try {
        $TenantFilter = Get-CIPPAutopatchTenantFilter -Request $Request
        $PolicyId = [string](Get-CIPPAutopatchRequestValue -Request $Request -Names @('policyId', 'PolicyId', 'id', 'ID'))
        if ([string]::IsNullOrWhiteSpace($PolicyId)) {
            return ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = [PSCustomObject]@{ error = 'policyId is required.'; tenantFilter = $TenantFilter }
                })
        }

        $Result = Remove-CIPPAutopatchUpdatePolicy -TenantFilter $TenantFilter -PolicyId $PolicyId
        $Body = [PSCustomObject]@{
            tenantFilter = $TenantFilter
            policyId     = $PolicyId
            Results      = @([PSCustomObject]@{ success = $true; response = $Result })
        }

        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Removed Autopatch policy $PolicyId." -Sev Info -LogData $Body
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "RemoveAutopatchPolicy failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
