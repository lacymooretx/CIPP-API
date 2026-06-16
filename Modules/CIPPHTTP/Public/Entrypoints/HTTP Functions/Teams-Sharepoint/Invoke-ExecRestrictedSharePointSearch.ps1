function Invoke-ExecRestrictedSharePointSearch {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Core.ReadWrite
    .DESCRIPTION
        Enable or disable Restricted SharePoint Search (the Microsoft 365 Copilot oversharing
        guardrail) via the SAM app's SharePoint admin CSOM path — the same authenticated path
        Get-CIPPSPOTenant / Set-CIPPSPOTenant use. Equivalent to the cmdlet
        Set-SPOTenantRestrictedSearchMode / Set-PnPTenantRestrictedSearchMode -Mode Enabled|Disabled.

        IMPORTANT: RestrictedSearchMode is NOT a settable CSOM *property* on the Tenant object
        (a SetProperty attempt returns 'Field or property "RestrictedSearchMode" does not exist').
        It is applied by calling the Tenant *method* SetSPORestrictedSearchMode with an Enum
        parameter (0 = Disabled, 1 = Enabled). This CSOM was captured from the real
        Set-PnPTenantRestrictedSearchMode wire request and validated live against aspendora.com.

        AUTH NOTE: the SharePoint admin CSOM endpoint (ProcessQuery) requires a SharePoint
        *admin* token, obtained the same way every other CIPP SharePoint operation
        (Get/Set-CIPPSPOTenant) does: the DELEGATED GDAP token. That token only works if the
        managed tenant's GDAP relationship actually carries the **SharePoint Administrator**
        role. If it does not (the role has 0 members in the customer tenant), this returns
        HTTP 401. The fleet fix is to add SharePoint Administrator to CIPP's GDAP role set
        (same pattern as Compliance Administrator) — NOT to add a SharePoint application
        permission: SharePoint rejects CIPP's secret-based app-only token with
        "Unsupported app only token" (app-only would require certificate auth). See
        CIPP-FLEET-AUTOMATION-GAPS.md.

        Body/query params:
          TenantFilter (required)
          Mode         - 'Enabled' (default) | 'Disabled'
          AsApp        - force app-only (diagnostic only; SharePoint rejects secret app-only)
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $TenantFilter = $Request.Body.TenantFilter ?? $Request.Query.TenantFilter ?? $Request.Body.tenantFilter ?? $Request.Query.tenantFilter
    $Mode = ($Request.Body.Mode ?? $Request.Query.Mode ?? 'Enabled').ToString()
    # Delegated GDAP is the working path (needs SharePoint Administrator in GDAP). AsApp is a
    # diagnostic override only — SharePoint rejects CIPP's secret-based app-only token.
    $AsAppRaw = $Request.Body.AsApp ?? $Request.Query.AsApp
    $AsApp = $AsAppRaw -in @($true, 'true', 'True', 1, '1', 'yes', 'on')

    try {
        if (-not $TenantFilter) { throw 'TenantFilter is required.' }
        $ModeValue = if ($Mode -eq 'Enabled' -or $Mode -eq '1') { 1 } else { 0 }

        $SharePointInfo = Get-SharePointAdminLink -Public $false -tenantFilter $TenantFilter
        $AdminUrl = $SharePointInfo.AdminUrl

        # Construct a fresh Tenant admin object (TypeId is the well-known SPO Tenant CSOM type)
        # and invoke the SetSPORestrictedSearchMode method. The Enum parameter is the mode value.
        $XML = @"
<Request AddExpandoFieldTypeSuffix="true" SchemaVersion="15.0.0.0" LibraryVersion="16.0.0.0" ApplicationName="CIPP" xmlns="http://schemas.microsoft.com/sharepoint/clientquery/2009"><Actions><ObjectPath Id="2" ObjectPathId="1" /><Method Name="SetSPORestrictedSearchMode" Id="3" ObjectPathId="1"><Parameters><Parameter Type="Enum">$ModeValue</Parameter></Parameters></Method></Actions><ObjectPaths><Constructor Id="1" TypeId="{268004ae-ef6b-4e9b-8425-127220d84719}" /></ObjectPaths></Request>
"@
        $AdditionalHeaders = @{ 'Accept' = 'application/json;odata=verbose' }
        $PostParams = @{
            scope         = "$AdminUrl/.default"
            tenantid      = $TenantFilter
            Uri           = "$AdminUrl/_vti_bin/client.svc/ProcessQuery"
            Type          = 'POST'
            Body          = $XML
            ContentType   = 'text/xml'
            AddedHeaders  = $AdditionalHeaders
        }
        if ($AsApp) { $PostParams.AsApp = $true }
        $CsomResponse = New-GraphPostRequest @PostParams

        # The ProcessQuery response is an array whose first element carries ErrorInfo (null = success).
        $ErrorInfo = $null
        foreach ($item in @($CsomResponse)) {
            if ($null -ne $item -and $item.PSObject.Properties.Name -contains 'ErrorInfo') { $ErrorInfo = $item.ErrorInfo; break }
        }
        if ($ErrorInfo) {
            throw "CSOM error setting Restricted SharePoint Search: $($ErrorInfo.ErrorMessage)"
        }

        $Result = "Restricted SharePoint Search for ${TenantFilter} set to $Mode ($ModeValue) — CSOM accepted (ErrorInfo: null)."
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
