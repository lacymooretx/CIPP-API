function Invoke-ExecExoRequest {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        Generic Exchange Online cmdlet passthrough. Runs an arbitrary EXO/Compliance cmdlet
        against a single tenant via New-ExoRequest. The on-demand escape hatch for one-off
        EXO reads/writes (Set-* / Get-* / New-* / Remove-*) that lack a dedicated CIPP endpoint
        - e.g. ExternalInOutlook, connector Enhanced Filtering, transport tweaks. Every call is
        audited; the SAM/GDAP Exchange.ManageAsApp scope remains the real safety boundary.

        Body/query params:
          TenantFilter (required)
          Cmdlet       (required) - EXO cmdlet name, e.g. 'Set-InboundConnector'
          CmdParams    - object of cmdlet parameters, e.g. { Identity: 'x', EFSkipLastIP: true }
          UseSystemMailbox - bool, route via the system mailbox (needed by some Set-* cmdlets)
          Compliance   - bool, run against the Security & Compliance PowerShell endpoint
          Anchor       - optional UPN anchor mailbox
          Select       - optional comma-separated property projection for reads
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    $TenantFilter = $Request.Body.TenantFilter ?? $Request.Query.TenantFilter
    $Cmdlet = $Request.Body.Cmdlet ?? $Request.Query.Cmdlet
    $CmdParams = $Request.Body.CmdParams ?? $Request.Body.cmdParams
    $Anchor = $Request.Body.Anchor ?? $Request.Query.Anchor
    $Select = $Request.Body.Select ?? $Request.Query.Select

    $TruthyValues = @($true, 'true', 'True', 1, '1', 'yes', 'on')
    $UseSystemMailbox = ($Request.Body.UseSystemMailbox ?? $Request.Query.UseSystemMailbox) -in $TruthyValues
    $Compliance = ($Request.Body.Compliance ?? $Request.Query.Compliance) -in $TruthyValues

    # Validation
    if (-not $TenantFilter) {
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = [pscustomobject]@{ Results = 'TenantFilter is required.' } })
    }
    if (-not $Cmdlet) {
        return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = [pscustomobject]@{ Results = 'Cmdlet is required.' } })
    }

    # Normalize CmdParams (PSCustomObject from JSON body) to a hashtable for New-ExoRequest.
    $ParamHash = $null
    if ($null -ne $CmdParams) {
        if ($CmdParams -is [hashtable]) {
            $ParamHash = $CmdParams
        } else {
            $ParamHash = @{}
            foreach ($Prop in $CmdParams.PSObject.Properties) { $ParamHash[$Prop.Name] = $Prop.Value }
        }
    }

    Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "EXO passthrough: $Cmdlet (Compliance: $Compliance)" -Sev 'Debug'

    try {
        $ExoParams = @{
            tenantid = $TenantFilter
            cmdlet   = $Cmdlet
        }
        if ($null -ne $ParamHash) { $ExoParams.cmdParams = $ParamHash }
        if ($UseSystemMailbox) { $ExoParams.useSystemMailbox = $true }
        if ($Compliance) { $ExoParams.Compliance = $true }
        if ($Anchor) { $ExoParams.Anchor = $Anchor }
        if ($Select) { $ExoParams.Select = $Select }

        $Results = New-ExoRequest @ExoParams

        # Audit mutating cmdlets (anything not a plain Get-) at Info.
        if ($Cmdlet -notmatch '^Get-') {
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "Executed EXO cmdlet $Cmdlet" -Sev 'Info'
        }

        $StatusCode = [HttpStatusCode]::OK
        $ResponseBody = [pscustomobject]@{ Results = $Results }
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "EXO passthrough failed: $Cmdlet - $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::BadRequest
        $ResponseBody = [pscustomobject]@{ Results = "EXO Error: $($ErrorMessage.NormalizedError) - Cmdlet: $Cmdlet" }
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $ResponseBody
        })
}
