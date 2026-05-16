function Invoke-ListIntegrationHealth {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        CIPP.Extension.Read
    .SYNOPSIS
        Connection probes + mapping counts for every enabled extension.
    .DESCRIPTION
        Loops the enabled extensions in Extensionsconfig and probes each
        one's auth + a trivial read (1 row) to confirm credentials still
        work. Also reports how many CIPP tenants are mapped to each
        extension. Designed to feed the SPA Integrations index page so
        users see at a glance which integrations are healthy.

        Each probe is wrapped in try/catch so one bad credential set
        doesn't poison the rest of the dashboard.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = (Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json
    $MappingTable = Get-CIPPTable -TableName 'CippMapping'

    $Probe = {
        param([string]$Name, [string]$MappingPartition, [scriptblock]$Action)
        $Result = [ordered]@{
            name           = $Name
            enabled        = $false
            healthy        = $false
            mappingCount   = 0
            detail         = ''
        }
        if ($MappingPartition) {
            $Result.mappingCount = (Get-CIPPAzDataTableEntity @MappingTable -Filter "PartitionKey eq '$MappingPartition'" |
                Where-Object { $null -ne $_.IntegrationId -and $_.IntegrationId -ne '' } |
                Measure-Object).Count
        }
        try {
            $Result.detail = & $Action
            $Result.enabled = $true
            $Result.healthy = $true
        } catch {
            $Result.detail = "Probe failed: $($_.Exception.Message)"
        }
        [PSCustomObject]$Result
    }

    $Results = @()

    if ($Configuration.ITGlue.Enabled -eq $true) {
        $Results += & $Probe 'ITGlue' 'ITGlueMapping' {
            Connect-ITGlueAPI -configuration $Configuration
            $r = Invoke-ITGlueRequest -Path '/organizations' -PageSize 1 -Raw
            "Reachable. $($r.meta.'total-count') organizations visible."
        }
    }

    if ($Configuration.ConnectWise.Enabled -eq $true) {
        $Results += & $Probe 'ConnectWise' 'ConnectWiseMapping' {
            $Headers = Get-ConnectWiseHeaders -Configuration $Configuration.ConnectWise
            $info = Invoke-RestMethod -Uri "$($Configuration.ConnectWise.BaseURL)/v4_6_release/apis/3.0/system/info" -Method GET -Headers $Headers -ErrorAction Stop
            "Reachable. Version $($info.version)."
        }
    }

    if ($Configuration.Pax8.Enabled -eq $true) {
        $Results += & $Probe 'Pax8' 'Pax8Mapping' {
            $h = Get-Pax8Authentication
            $r = Invoke-RestMethod -Uri 'https://api.pax8.com/v1/companies?page=0&size=1' -Method GET -Headers $h -ErrorAction Stop
            "Reachable. $($r.page.totalElements) companies visible."
        }
    }

    if ($Configuration.Sherweb.Enabled -eq $true) {
        $Results += & $Probe 'Sherweb' 'SherwebMapping' {
            $null = Get-SherwebAuthentication
            'Reachable.'
        }
    }

    if ($Configuration.Hudu.Enabled -eq $true) {
        $Results += & $Probe 'Hudu' 'HuduMapping' {
            Connect-HuduAPI -configuration $Configuration
            $v = Get-HuduAppInfo
            "Reachable. Hudu $($v.version)."
        }
    }

    if ($Configuration.NinjaOne.Enabled -eq $true) {
        $Results += & $Probe 'NinjaOne' 'NinjaOneMapping' {
            $t = Get-NinjaOneToken -configuration $Configuration.NinjaOne
            if ($t) { 'Reachable.' } else { throw 'No token returned.' }
        }
    }

    if ($Configuration.HaloPSA.Enabled -eq $true) {
        $Results += & $Probe 'HaloPSA' 'HaloMapping' {
            $t = Get-HaloToken -configuration $Configuration.HaloPSA
            if ($t) { 'Reachable.' } else { throw 'No token returned.' }
        }
    }

    if ($Configuration.GitHub.Enabled -eq $true) {
        $Results += & $Probe 'GitHub' $null {
            $r = Invoke-GitHubApiRequest -Method 'GET' -Path 'user'
            "Reachable as $($r.login)."
        }
    }

    if ($Configuration.HIBP.Enabled -eq $true) {
        $Results += & $Probe 'HIBP' $null {
            $null = Get-HIBPConnectionTest
            'Reachable.'
        }
    }

    return [HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            integrations = $Results
            generatedAt  = (Get-Date).ToString('o')
        }
    }
}
