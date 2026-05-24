using namespace System.Net

function Invoke-ListWindowsAutopatch {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.Read
    .DESCRIPTION
        Aggregated read view of a tenant's Windows Autopatch v2 state via the WUfB Deployment Service
        Graph API (admin/windows/updates/*). Returns updatePolicies, deploymentAudiences, and
        enrolled updatableAssets — enough to confirm whether a tenant is onboarded and the shape
        of its ring distribution.

        Requires the SAM app to have WindowsUpdates.ReadWrite.All Application permission granted
        in the target tenant. Use ExecCPVPermissions + per-tenant CPV refresh if endpoints
        return 403.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    try {
        $TenantFilter = Get-CIPPAutopatchTenantFilter -Request $Request
        $IncludeManagedDevices = ConvertTo-CIPPAutopatchBoolean -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('includeManagedDevices', 'IncludeManagedDevices')) -Default $false
        $IncludeAudienceMembers = ConvertTo-CIPPAutopatchBoolean -Value (Get-CIPPAutopatchRequestValue -Request $Request -Names @('includeAudienceMembers', 'IncludeAudienceMembers')) -Default $true

        $Body = Get-CIPPAutopatchState -TenantFilter $TenantFilter -IncludeManagedDevices:$IncludeManagedDevices -IncludeAudienceMembers:$IncludeAudienceMembers
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "ListWindowsAutopatch failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
