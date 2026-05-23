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
    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Query.TenantFilter ?? $Request.Body.tenantFilter ?? $Request.Body.TenantFilter

    if ([string]::IsNullOrWhiteSpace($TenantFilter)) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = [PSCustomObject]@{ error = 'tenantFilter is required' }
            })
    }

    try {
        $Policies = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatePolicies' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop
        $Audiences = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop
        $Assets = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/admin/windows/updates/updatableAssets' -tenantid $TenantFilter -AsApp $true -NoAuthCheck $true -ErrorAction Stop

        $Body = [PSCustomObject]@{
            tenantFilter        = $TenantFilter
            updatePolicies      = @($Policies)
            deploymentAudiences = @($Audiences)
            updatableAssets     = @($Assets)
            summary             = @{
                policyCount   = @($Policies).Count
                audienceCount = @($Audiences).Count
                assetCount    = @($Assets).Count
                isEnrolled    = (@($Policies).Count -gt 0 -or @($Audiences).Count -gt 0)
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "ListWindowsAutopatch failed: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Body = [PSCustomObject]@{ error = $ErrorMessage.NormalizedError; tenantFilter = $TenantFilter }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{ StatusCode = $StatusCode; Body = $Body })
}
