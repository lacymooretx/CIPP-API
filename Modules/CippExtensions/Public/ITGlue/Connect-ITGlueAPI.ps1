function Connect-ITGlueAPI {
    [CmdletBinding()]
    param (
        $Configuration
    )

    $APIKey = Get-ExtensionAPIKey -Extension 'ITGlue'

    $Region = if ($Configuration.ITGlue.Region) { $Configuration.ITGlue.Region } else { 'US' }
    $script:ITGlueBaseUrl = switch ($Region) {
        'EU' { 'https://api.eu.itglue.com' }
        'AU' { 'https://api.au.itglue.com' }
        default { 'https://api.itglue.com' }
    }

    $script:ITGlueHeaders = @{
        'x-api-key'    = $APIKey
        'Content-Type' = 'application/vnd.api+json'
        'Accept'       = 'application/vnd.api+json'
    }

    if ($Configuration.ITGlue.CFEnabled -eq $true -and $Configuration.CFZTNA.Enabled -eq $true) {
        $CFAPIKey = Get-ExtensionAPIKey -Extension 'CFZTNA'
        $script:ITGlueHeaders['CF-Access-Client-Id'] = $Configuration.CFZTNA.ClientId
        $script:ITGlueHeaders['CF-Access-Client-Secret'] = "$CFAPIKey"
        Write-Information 'CF-Access headers added to IT Glue API request'
    }
}
