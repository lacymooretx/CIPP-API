function Invoke-ExecGraphRequest {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        Write-capable generic Microsoft Graph passthrough. Executes an arbitrary Graph
        request (GET/POST/PATCH/PUT/DELETE) against a single tenant. This is the on-demand
        escape hatch for one-off reads and writes that do not yet have a dedicated CIPP
        endpoint. Gated to CIPP.Core.ReadWrite (the write counterpart of ListGraphRequest's
        CIPP.Core.Read); every mutating call is audited. It can reach any Graph endpoint with
        any method, so the underlying SAM/GDAP permissions remain the real safety boundary.

        Parameters may be supplied via query string (GET-style) or request body (POST-style):
          TenantFilter (required) - tenant default domain or customer id
          Endpoint     (required) - relative Graph path (e.g. 'users/{id}') or a full URL
          Method                  - GET (default) | POST | PATCH | PUT | DELETE
          Version                 - 'beta' (default) | 'v1.0'  (ignored if Endpoint is a full URL)
          Body / GraphRequestBody - request body for write methods (object or JSON string)
          AsApp                   - application vs delegated token. DEFAULT $true (app-only).
                                    App-only is the correct mode for automated tenant management:
                                    it is governed by the SAM app permissions + GDAP roles, and has
                                    no interactive user session, so it is NOT subject to the customer's
                                    admin-user Conditional Access (phishing-resistant MFA / sign-in
                                    frequency). That keeps those human controls fully enforced while CIPP
                                    still works. Pass AsApp:$false ONLY for the rare op that genuinely
                                    requires a delegated/user context.
          NoPagination / DisablePagination - $true to disable paging on GET
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    # Accept params from body (POST-style) first, falling back to query (GET-style).
    $TenantFilter = $Request.Body.TenantFilter ?? $Request.Query.TenantFilter
    $Endpoint = $Request.Body.Endpoint ?? $Request.Query.Endpoint
    $Method = ($Request.Body.Method ?? $Request.Query.Method ?? 'GET').ToString().ToUpper()
    $Version = $Request.Body.Version ?? $Request.Query.Version ?? 'beta'
    $AsAppRaw = $Request.Body.AsApp ?? $Request.Query.AsApp
    $NoPaginationRaw = $Request.Body.NoPagination ?? $Request.Query.NoPagination ?? $Request.Query.DisablePagination
    $GraphBody = $Request.Body.GraphRequestBody ?? $Request.Body.Body

    # Coerce loosely-typed flags (query values arrive as strings) without throwing.
    $TruthyValues = @($true, 'true', 'True', 1, '1', 'yes', 'on')
    $FalsyValues = @($false, 'false', 'False', 0, '0', 'no', 'off')
    # Default to app-only: automated tenant management must run as the application (SAM perms + GDAP),
    # never as a delegated admin user — otherwise the customer's admin Conditional Access (phishing-
    # resistant MFA / sign-in frequency) correctly blocks it. Only an explicit AsApp:$false uses delegated.
    $AsApp = if ($AsAppRaw -in $FalsyValues) { $false } else { $true }
    $NoPagination = $NoPaginationRaw -in $TruthyValues

    $ValidMethods = @('GET', 'POST', 'PATCH', 'PUT', 'DELETE')

    # Validation
    if (-not $TenantFilter) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = [pscustomobject]@{ Results = 'TenantFilter is required.' }
            })
    }
    if (-not $Endpoint) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = [pscustomobject]@{ Results = 'Endpoint is required.' }
            })
    }
    if ($Method -notin $ValidMethods) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = [pscustomobject]@{ Results = "Invalid Method '$Method'. Allowed: $($ValidMethods -join ', ')." }
            })
    }

    # Build the full Graph URI. Allow a fully-qualified URL (e.g. a nextLink) to pass through.
    if ($Endpoint -match '^https?://') {
        $Uri = $Endpoint
    } else {
        $Uri = 'https://graph.microsoft.com/{0}/{1}' -f $Version, ($Endpoint -replace '^/+', '')
    }

    Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Graph passthrough: $Method $Uri (AsApp: $AsApp)" -Sev 'Debug'

    try {
        if ($Method -eq 'GET') {
            $GetParams = @{
                uri      = $Uri
                tenantid = $TenantFilter
            }
            if ($NoPagination) { $GetParams.noPagination = $true }
            if ($AsApp) { $GetParams.AsApp = $true }
            $Results = New-GraphGetRequest @GetParams
        } else {
            $BodyJson = if ($null -ne $GraphBody -and $GraphBody -ne '') {
                if ($GraphBody -is [string]) { $GraphBody } else { ConvertTo-Json -InputObject $GraphBody -Depth 20 -Compress }
            } else { $null }

            $PostParams = @{
                uri      = $Uri
                tenantid = $TenantFilter
                type     = $Method
            }
            if ($BodyJson) { $PostParams.body = $BodyJson }
            if ($AsApp) { $PostParams.AsApp = $true }
            $Results = New-GraphPOSTRequest @PostParams

            # Audit every mutating call at Info so it shows in the CIPP log.
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Executed Graph $Method against $Endpoint" -Sev 'Info'
        }

        $StatusCode = [HttpStatusCode]::OK
        $ResponseBody = [pscustomobject]@{ Results = $Results }
    } catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Graph passthrough failed: $Method $Endpoint - $ErrorMessage" -Sev 'Error'
        $StatusCode = [HttpStatusCode]::BadRequest
        $ResponseBody = [pscustomobject]@{ Results = "Graph Error: $ErrorMessage - Endpoint: $Endpoint" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $ResponseBody
        })
}
