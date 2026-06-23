function Invoke-ExecApproveAppConsentRequest {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Application.ReadWrite
    .DESCRIPTION
        Approves a pending Entra admin consent request server-side (app-only via the CIPP-SAM
        application) so a technician does not need to elevate to Global Administrator. It grants
        tenant-wide admin consent (oauth2PermissionGrant, consentType = AllPrincipals) for the
        requested application's delegated Microsoft Graph scopes by reusing Add-CIPPDelegatedPermission.
        Scopes Microsoft does not allow to be granted app-only, or scopes published by a non-Graph
        resource, are returned with the standard Entra consent URL as a manual fallback (no regression
        from today's "Approve in Entra" deep-link behaviour).
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $AppId = $Request.Query.appId ?? $Request.Body.appId
    $ConsentRequestId = $Request.Query.appConsentRequestId ?? $Request.Body.appConsentRequestId

    # Microsoft Graph first-party application id (the resource that publishes the common sign-in scopes).
    $GraphAppId = '00000003-0000-0000-c000-000000000000'

    try {
        if (-not $TenantFilter) { throw 'tenantFilter is required.' }
        if (-not $AppId -and -not $ConsentRequestId) { throw 'appId or appConsentRequestId is required.' }

        # 1. Resolve the app consent request to read its pending (delegated) scopes.
        if ($ConsentRequestId) {
            $ConsentRequest = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/identityGovernance/appConsent/appConsentRequests/$ConsentRequestId" -tenantid $TenantFilter
        } else {
            $FilterQuery = [System.Web.HttpUtility]::UrlEncode("appId eq '$AppId'")
            $ConsentRequest = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/identityGovernance/appConsent/appConsentRequests?`$filter=$FilterQuery" -tenantid $TenantFilter | Select-Object -First 1
        }

        if (-not $ConsentRequest) {
            throw "No app consent request found for the supplied identifiers in tenant $TenantFilter."
        }

        if (-not $AppId) { $AppId = $ConsentRequest.appId }
        $AppDisplayName = $ConsentRequest.appDisplayName
        $PendingScopes = @($ConsentRequest.pendingScopes.displayName | Where-Object { $_ })

        if ($PendingScopes.Count -eq 0) {
            throw "The consent request for '$AppDisplayName' has no pending scopes to grant (it may already be completed)."
        }

        # 2. Split the pending scopes into Microsoft Graph delegated scopes (the common case we can
        #    grant app-only) and everything else (handled via the manual consent URL fallback).
        $GraphSp = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/servicePrincipals(appId='$GraphAppId')?`$select=id,appId,oauth2PermissionScopes" -tenantid $TenantFilter
        $GraphScopeValues = @($GraphSp.oauth2PermissionScopes.value)

        $GraphScopes = @($PendingScopes | Where-Object { $GraphScopeValues -contains $_ })
        $UnmappedScopes = @($PendingScopes | Where-Object { $GraphScopeValues -notcontains $_ })

        $GrantResults = [System.Collections.Generic.List[string]]::new()
        $Granted = $false

        # 3. Grant admin consent for the Graph delegated scopes by reusing the existing helper.
        #    ApplicationId = the requested app (its SP becomes the oauth2PermissionGrant clientId);
        #    NoTranslateRequired = scopes are passed as literal scope names, not permission GUIDs.
        if ($GraphScopes.Count -gt 0) {
            $ResourceAccess = foreach ($Scope in $GraphScopes) { @{ id = $Scope; type = 'Scope' } }
            $RequiredResourceAccess = @(
                @{
                    resourceAppId  = $GraphAppId
                    resourceAccess = @($ResourceAccess)
                }
            )
            $AddResult = Add-CIPPDelegatedPermission -ApplicationId $AppId -RequiredResourceAccess $RequiredResourceAccess -NoTranslateRequired $true -TenantFilter $TenantFilter
            foreach ($Line in $AddResult) { $GrantResults.Add($Line) }
            if (($AddResult -match 'Successfully') -or ($AddResult -match 'All delegated permissions exist')) {
                $Granted = $true
            }
        }

        # 4. Manual fallback URL when some scopes are non-Graph, or the app-only grant did not succeed.
        $NeedsManual = ($UnmappedScopes.Count -gt 0) -or ($GraphScopes.Count -gt 0 -and -not $Granted)
        $ConsentUrl = $null
        if ($NeedsManual) {
            $ScopeString = ($PendingScopes -join ' ')
            if ($ConsentRequest.consentType -eq 'Static') {
                $ConsentUrl = "https://login.microsoftonline.com/$TenantFilter/adminConsent?client_id=$AppId&redirect_uri=https://entra.microsoft.com/TokenAuthorize"
            } else {
                $ConsentUrl = "https://login.microsoftonline.com/$TenantFilter/v2.0/adminConsent?client_id=$AppId&scope=$ScopeString&redirect_uri=https://entra.microsoft.com/TokenAuthorize"
            }
        }

        # 5. Best-effort re-read of the request status (granting consent does not always flip the
        #    workflow request to Completed via the API; surface whatever Graph reports).
        $FinalStatus = $null
        try {
            $UserConsent = New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/identityGovernance/appConsent/appConsentRequests/$($ConsentRequest.id)/userConsentRequests" -tenantid $TenantFilter
            $FinalStatus = ($UserConsent | Select-Object -First 1).status
        } catch {
            # non-fatal
        }

        # 6. Compose response message + audit log.
        $Messages = [System.Collections.Generic.List[string]]::new()
        if ($Granted) {
            $Messages.Add("Granted admin consent for '$AppDisplayName' (scopes: $($GraphScopes -join ', ')) in tenant $TenantFilter. Ask the user to sign in again.")
        }
        foreach ($Line in $GrantResults) { $Messages.Add($Line) }
        if ($UnmappedScopes.Count -gt 0) {
            $Messages.Add("The following scopes could not be granted automatically and need manual approval in Entra: $($UnmappedScopes -join ', '). Use the consent URL provided.")
        } elseif ($NeedsManual) {
            $Messages.Add('The automatic grant did not complete. Use the consent URL provided to approve in Entra.')
        }

        $Severity = if ($Granted -and -not $NeedsManual) { 'Info' } else { 'Warning' }
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "App consent approval for '$AppDisplayName' ($AppId) - granted: [$($GraphScopes -join ' ')]; manual fallback: [$($UnmappedScopes -join ' ')]" -Sev $Severity

        $Results = [PSCustomObject]@{
            Results        = ($Messages -join ' ')
            AppId          = $AppId
            AppDisplayName = $AppDisplayName
            GrantedScopes  = $GraphScopes
            ManualScopes   = $UnmappedScopes
            RequestStatus  = $FinalStatus
            ConsentUrl     = $ConsentUrl
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to approve app consent request: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $Results = [PSCustomObject]@{ Results = "Error: $($ErrorMessage.NormalizedError)" }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Results
        })
}
