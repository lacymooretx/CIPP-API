function Get-ConnectWiseHeaders {
    [CmdletBinding()]
    param (
        $Configuration
    )

    if ([string]::IsNullOrEmpty($Configuration.CompanyID) -or [string]::IsNullOrEmpty($Configuration.PublicKey)) {
        throw 'ConnectWise Manage configuration is incomplete. CompanyID and PublicKey are required.'
    }

    $PrivateKey = Get-ExtensionAPIKey -Extension 'ConnectWise'
    $AuthString = "$($Configuration.CompanyID)+$($Configuration.PublicKey):$PrivateKey"
    $EncodedAuth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AuthString))

    $Headers = @{
        Authorization  = "Basic $EncodedAuth"
        clientId       = $Configuration.ClientID
        'Content-Type' = 'application/json'
    }

    return $Headers
}
