function Get-Pax8Authentication {
    <#
    .SYNOPSIS
        Returns auth headers for the Pax8 Partner API.
    .DESCRIPTION
        Performs an OAuth 2.0 client_credentials exchange against Pax8's
        token-manager and returns a header bag with the resulting Bearer
        token. Audience is fixed to https://api.pax8.com (Partner API).
    #>
    [CmdletBinding()]
    param()

    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Config = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json).Pax8
    if (-not $Config -or [string]::IsNullOrEmpty($Config.clientId)) {
        throw 'Pax8 integration is not configured. Set the Client ID and Client Secret in Settings > Integrations.'
    }

    $APIKey = Get-ExtensionAPIKey -Extension 'Pax8'
    if ([string]::IsNullOrEmpty($APIKey)) {
        throw 'Pax8 client secret is missing from Key Vault. Re-enter it in Settings > Integrations.'
    }

    $Body = @{
        client_id     = $Config.clientId
        client_secret = $APIKey
        audience      = 'https://api.pax8.com'
        grant_type    = 'client_credentials'
    } | ConvertTo-Json -Compress

    $Token = (Invoke-RestMethod -Uri 'https://token-manager.pax8.com/oauth/token' -Method POST -Body $Body -ContentType 'application/json').access_token
    if (-not $Token) { throw 'Pax8 returned no access_token.' }

    return @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }
}
