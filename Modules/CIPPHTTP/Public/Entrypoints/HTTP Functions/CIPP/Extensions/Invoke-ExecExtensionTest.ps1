Function Invoke-ExecExtensionTest {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.Extension.Read
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)
    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json)
    # Interact with query parameters or the body of the request.
    try {
        switch ($Request.Query.extensionName) {
            'HaloPSA' {
                $token = Get-HaloToken -configuration $Configuration.HaloPSA
                if ($token) {
                    $Results = [pscustomobject]@{'Results' = 'Successfully Connected to HaloPSA' }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to HaloPSA, check your API credentials and try again.' }
                }
            }
            'Gradient' {
                $GradientToken = Get-GradientToken -Configuration $Configuration.Gradient
                if ($GradientToken) {
                    try {
                        $ExistingIntegrations = Invoke-RestMethod -Uri 'https://app.usegradient.com/api/vendor-api/organization' -Method GET -Headers $GradientToken
                        if ($ExistingIntegrations.Status -ne 'active') {
                            $ActivateRequest = Invoke-RestMethod -Uri 'https://app.usegradient.com/api/vendor-api/organization/status/active' -Method PATCH -Headers $GradientToken
                        }
                        $Results = [pscustomobject]@{'Results' = 'Successfully Connected to Gradient' }
                    } catch {
                        $Results = [pscustomobject]@{'Results' = 'Failed to connect to Gradient, check your API credentials and try again.' }
                    }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to Gradient, check your API credentials and try again.' }
                }
            }
            'CIPP-API' {
                $Results = [pscustomobject]@{'Results' = 'You cannot test the CIPP-API from CIPP. Please check the documentation on how to test the CIPP-API.' }
            }
            'NinjaOne' {
                $token = Get-NinjaOneToken -configuration $Configuration.NinjaOne
                if ($token) {
                    $Results = [pscustomobject]@{'Results' = 'Successfully Connected to NinjaOne' }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to NinjaOne, check your API credentials and try again.' }
                }
            }
            'PWPush' {
                $Payload = 'This is a test from CIPP'
                $PasswordLink = New-PwPushLink -Payload $Payload
                if ($PasswordLink) {
                    $Results = [pscustomobject]@{Results = @(@{'resultText' = 'Successfully generated PWPush, hit the Copy to Clipboard button to retrieve the test.'; 'copyField' = $PasswordLink; 'state' = 'success' }) }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'PWPush is not enabled' }
                }
            }
            'Hudu' {
                Connect-HuduAPI -configuration $Configuration
                $Version = Get-HuduAppInfo
                if ($Version.version) {
                    $Results = [pscustomobject]@{'Results' = ('Successfully Connected to Hudu, version: {0}' -f $Version.version) }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to Hudu, check your API credentials and try again.' }
                }
            }
            'ConnectWise' {
                $CWConfig = $Configuration.ConnectWise
                $Headers = Get-ConnectWiseHeaders -Configuration $CWConfig
                $SystemInfo = Invoke-RestMethod -Uri "$($CWConfig.BaseURL)/v4_6_release/apis/3.0/system/info" -Method GET -Headers $Headers -ErrorAction Stop
                if ($SystemInfo.version) {
                    $Results = [pscustomobject]@{'Results' = ('Successfully Connected to ConnectWise Manage, version: {0} ({1})' -f $SystemInfo.version, $SystemInfo.serverTimeZone) }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to ConnectWise Manage, check your API credentials and base URL.' }
                }
            }
            'ITGlue' {
                Connect-ITGlueAPI -configuration $Configuration
                $Probe = Invoke-ITGlueRequest -Path '/organizations' -PageSize 1 -Raw
                if ($null -ne $Probe.data) {
                    $Total = if ($Probe.meta -and $Probe.meta.'total-count') { $Probe.meta.'total-count' } else { ($Probe.data | Measure-Object).Count }
                    $Region = if ($Configuration.ITGlue.Region.value) { $Configuration.ITGlue.Region.value } elseif ($Configuration.ITGlue.Region) { "$($Configuration.ITGlue.Region)" } else { 'US' }
                    $Results = [pscustomobject]@{'Results' = ('Successfully Connected to IT Glue ({0} region). {1} organizations visible.' -f $Region, $Total) }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to IT Glue, check your API key, region, and that the key has access enabled.' }
                }
            }
            'Sherweb' {
                $token = Get-SherwebAuthentication
                if ($token) {
                    $Results = [pscustomobject]@{'Results' = 'Successfully Connected to Sherweb' }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to Sherweb, check your API credentials and try again.' }
                }
            }
            'Pax8' {
                $Headers = Get-Pax8Authentication
                $Probe = Invoke-RestMethod -Uri 'https://api.pax8.com/v1/companies?page=0&size=1' -Method GET -Headers $Headers -ErrorAction Stop
                $TotalCompanies = if ($Probe.page.totalElements) { $Probe.page.totalElements } else { ($Probe.content | Measure-Object).Count }
                if ($null -ne $Probe) {
                    $Results = [pscustomobject]@{'Results' = ('Successfully Connected to Pax8. {0} companies visible.' -f $TotalCompanies) }
                } else {
                    $Results = [pscustomobject]@{'Results' = 'Failed to connect to Pax8, check your API credentials and try again.' }
                }
            }
            'HIBP' {
                $ConnectionTest = Get-HIBPConnectionTest
                $Results = [pscustomobject]@{'Results' = 'Successfully Connected to HIBP' }
            }
            'GitHub' {
                $GitHubResponse = Invoke-GitHubApiRequest -Method 'GET' -Path 'user' -ReturnHeaders
                if ($GitHubResponse.login) {
                    if ($GitHubResponse.Headers.'x-oauth-scopes') {
                        $Results = [pscustomobject]@{ 'Results' = "Successfully connected to GitHub user: $($GitHubResponse.login) with scopes: $($GitHubResponse.Headers.'x-oauth-scopes')" }
                    } else {
                        $Results = [pscustomobject]@{ 'Results' = "Successfully connected to GitHub user: $($GitHubResponse.login) using a Fine Grained PAT" }
                    }
                } else {
                    $Results = [pscustomobject]@{ 'Results' = 'Failed to connect to GitHub. Check your API credentials and try again.' }
                }
            }
        }
    } catch {
        $Results = [pscustomobject]@{'Results' = "Failed to connect: $($_.Exception.Message). Line $($_.InvocationInfo.ScriptLineNumber)" }
    }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $Results
        })

}
