Function Invoke-ListSharepointSettings {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Sharepoint.Admin.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    #  XXX - Seems to be an unused endpoint? -Bobby


    # Interact with query parameters or the body of the request.
    $Tenant = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    # The SharePoint admin settings endpoint requires an application token; without -AsApp the
    # delegated token lacks the SharePoint admin scope and the call fails with a 500/UnknownError.
    $Settings = New-GraphGetRequest -tenantid $Tenant -Uri 'https://graph.microsoft.com/beta/admin/sharepoint/settings' -AsApp $true

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @($Settings)
        })

}
