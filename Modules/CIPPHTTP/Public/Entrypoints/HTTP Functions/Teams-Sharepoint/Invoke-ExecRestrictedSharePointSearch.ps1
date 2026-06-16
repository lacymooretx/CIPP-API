function Invoke-ExecRestrictedSharePointSearch {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        Enable or disable Restricted SharePoint Search (the Microsoft 365 Copilot oversharing
        guardrail) via the SAM app's SharePoint admin CSOM path — the same authenticated path
        Get-CIPPSPOTenant / Set-CIPPSPOTenant use. Equivalent to the SPO cmdlet
        Set-SPOTenantRestrictedSearchMode -Mode Enabled|Disabled. RestrictedSearchMode is a
        tenant CSOM enum property (0 = Disabled, 1 = Enabled).

        Body/query params:
          TenantFilter (required)
          Mode         - 'Enabled' (default) | 'Disabled'
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $Request.Body.TenantFilter ?? $Request.Query.TenantFilter ?? $Request.Body.tenantFilter ?? $Request.Query.tenantFilter
    $Mode = ($Request.Body.Mode ?? $Request.Query.Mode ?? 'Enabled').ToString()

    try {
        if (-not $TenantFilter) { throw 'TenantFilter is required.' }
        $ModeValue = if ($Mode -eq 'Enabled' -or $Mode -eq '1') { 1 } else { 0 }

        $SharePointInfo = Get-SharePointAdminLink -Public $false -tenantFilter $TenantFilter
        $AdminUrl = $SharePointInfo.AdminUrl

        # Read current tenant CSOM properties (gives us the _ObjectIdentity_ + current mode).
        $Tenant = Get-CIPPSPOTenant -TenantFilter $TenantFilter -SkipCache

        # Diagnostic mode: surface every tenant property name + value that relates to search/restriction.
        if ($Mode -eq 'Read') {
            $Props = $Tenant.PSObject.Properties |
                Where-Object { $_.Name -match 'search|restrict|copilot|coreSharing' } |
                ForEach-Object { "$($_.Name)=$($_.Value)" }
            return ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = @{ Results = "search/restrict properties: $($Props -join ' | ')"; AllPropertyNames = @($Tenant.PSObject.Properties.Name) } })
        }

        $Before = $Tenant.RestrictedSearchMode
        $Identity = ([string]$Tenant._ObjectIdentity_) -replace "`n", '&#xA;'

        # CSOM SetProperty on the tenant enum property RestrictedSearchMode.
        $XML = @"
<Request AddExpandoFieldTypeSuffix="true" SchemaVersion="15.0.0.0" LibraryVersion="16.0.0.0" ApplicationName="CIPP" xmlns="http://schemas.microsoft.com/sharepoint/clientquery/2009"><Actions><SetProperty Id="114" ObjectPathId="110" Name="RestrictedSearchMode"><Parameter Type="Enum">$ModeValue</Parameter></SetProperty></Actions><ObjectPaths><Identity Id="110" Name="$Identity" /></ObjectPaths></Request>
"@
        $AdditionalHeaders = @{ 'Accept' = 'application/json;odata=verbose' }
        $CsomResponse = New-GraphPostRequest -scope "$AdminUrl/.default" -tenantid $TenantFilter -Uri "$AdminUrl/_vti_bin/client.svc/ProcessQuery" -Type POST -Body $XML -ContentType 'text/xml' -AddedHeaders $AdditionalHeaders
        $CsomJson = try { $CsomResponse | ConvertTo-Json -Depth 6 -Compress } catch { "$CsomResponse" }

        $After = (Get-CIPPSPOTenant -TenantFilter $TenantFilter -SkipCache).RestrictedSearchMode
        $Result = "Restricted SharePoint Search for ${TenantFilter}: before=$Before, requested=$Mode ($ModeValue), after=$After | CSOM: $CsomJson"
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Result -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed to set Restricted SharePoint Search for ${TenantFilter}: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Result -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result }
        })
}
