function Invoke-AddWin32ScriptApp {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Endpoint.Application.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    $Win32ScriptApp = $Request.Body
    $AssignTo = $Win32ScriptApp.AssignTo -eq 'customGroup' ? $Win32ScriptApp.CustomGroup : $Win32ScriptApp.AssignTo

    # Validate required fields
    if ([string]::IsNullOrEmpty($Win32ScriptApp.ApplicationName) -and [string]::IsNullOrEmpty($Win32ScriptApp.applicationName)) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = @('Application name is required') }
            })
    }

    if ([string]::IsNullOrEmpty($Win32ScriptApp.installScript)) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = @('Install script is required') }
            })
    }

    # Use whichever case was provided
    $AppName = if ($Win32ScriptApp.ApplicationName) { $Win32ScriptApp.ApplicationName } else { $Win32ScriptApp.applicationName }

    $AllowedTenants = Test-CIPPAccess -Request $Request -TenantList

    # Resolve target tenants. Historically this only honored the multi-tenant `selectedTenants`
    # array supplied by the CIPP UI. Callers using the standard single-tenant `TenantFilter`
    # (the API / MCP, like every other endpoint) resolved to zero tenants and got a silent
    # 200 { Results: null } no-op with nothing logged. Honor both inputs.
    if ($Request.Body.selectedTenants) {
        $Tenants = ($Request.Body.selectedTenants | Where-Object { $AllowedTenants -contains $_.customerId -or $AllowedTenants -contains 'AllTenants' }).defaultDomainName
    } else {
        $TenantFilter = $Request.Body.tenantFilter ?? $Request.Query.tenantFilter ?? $Request.Query.TenantFilter
        if ($TenantFilter) {
            $ResolvedTenant = Get-Tenants -IncludeErrors | Where-Object { $_.defaultDomainName -eq $TenantFilter -or $_.customerId -eq $TenantFilter }
            if ($ResolvedTenant -and ($AllowedTenants -contains 'AllTenants' -or $AllowedTenants -contains $ResolvedTenant.customerId)) {
                $Tenants = @($ResolvedTenant.defaultDomainName)
            }
        }
    }

    # Fail loudly instead of the previous silent 200 { Results: null } when no tenant resolved.
    if (-not $Tenants) {
        return ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = @{ Results = @('No target tenant resolved. Provide `selectedTenants` (array of {customerId, defaultDomainName}) or a `TenantFilter`, and ensure you have access to it.') }
            })
    }

    $Results = foreach ($Tenant in $Tenants) {
        try {
            $CompleteObject = [PSCustomObject]@{
                tenant                = $Tenant
                Applicationname       = $AppName
                assignTo              = $AssignTo
                InstallationIntent    = $Win32ScriptApp.InstallationIntent
                type                  = 'Win32ScriptApp'
                description           = $Win32ScriptApp.description
                publisher             = $Win32ScriptApp.publisher
                installScript         = $Win32ScriptApp.installScript
                uninstallScript       = $Win32ScriptApp.uninstallScript
                detectionPath         = $Win32ScriptApp.detectionPath
                detectionFile         = $Win32ScriptApp.detectionFile
                detectionScript       = $Win32ScriptApp.detectionScript
                runAsAccount          = if ($Win32ScriptApp.InstallAsSystem) { 'system' } else { 'user' }
                deviceRestartBehavior = if ($Win32ScriptApp.DisableRestart) { 'suppress' } else { 'allow' }
                runAs32Bit            = [bool]$Win32ScriptApp.runAs32Bit
                enforceSignatureCheck = [bool]$Win32ScriptApp.enforceSignatureCheck
            } | ConvertTo-Json -Depth 15

            $Table = Get-CippTable -tablename 'apps'
            $Table.Force = $true
            Add-CIPPAzDataTableEntity @Table -Entity @{
                JSON         = "$CompleteObject"
                RowKey       = "$((New-Guid).GUID)"
                PartitionKey = 'apps'
                status       = 'Not Deployed yet'
            }
            "Successfully added Win32 Script App for $($Tenant) to queue."
            Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant -message "Successfully added Win32 Script App $AppName to queue" -Sev 'Info'
        } catch {
            Write-LogMessage -headers $Headers -API $APIName -tenant $Tenant -message "Failed to add Win32 Script App $AppName to queue. Error: $($_.Exception.Message)" -Sev 'Error'
            "Failed to add Win32 Script App for $($Tenant) to queue: $($_.Exception.Message)"
        }
    }

    $body = [PSCustomObject]@{ 'Results' = $Results }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })
}
