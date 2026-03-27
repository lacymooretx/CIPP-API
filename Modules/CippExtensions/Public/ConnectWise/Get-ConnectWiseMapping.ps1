function Get-ConnectWiseMapping {
    param ($CIPPMapping)

    $ExtensionMappings = Get-ExtensionMapping -Extension 'ConnectWise'
    $Tenants = Get-Tenants -IncludeErrors

    $Mappings = foreach ($Mapping in $ExtensionMappings) {
        $Tenant = $Tenants | Where-Object { $_.RowKey -eq $Mapping.RowKey }
        if ($Tenant) {
            [PSCustomObject]@{
                TenantId        = $Tenant.customerId
                Tenant          = $Tenant.displayName
                TenantDomain    = $Tenant.defaultDomainName
                IntegrationId   = $Mapping.IntegrationId
                IntegrationName = $Mapping.IntegrationName
            }
        }
    }

    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json -ErrorAction Stop).ConnectWise
    $Headers = Get-ConnectWiseHeaders -Configuration $Configuration

    $BaseURL = "$($Configuration.BaseURL)/v4_6_release/apis/3.0"
    $Page = 1
    $PageSize = 1000
    $AllCompanies = [System.Collections.Generic.List[object]]::new()

    do {
        $Result = Invoke-RestMethod -Uri "$BaseURL/company/companies?pageSize=$PageSize&page=$Page&conditions=status/name=%22Active%22" -Method GET -Headers $Headers
        if ($Result) {
            $AllCompanies.AddRange(@($Result))
        }
        $Page++
    } while ($Result.Count -eq $PageSize)

    $Companies = $AllCompanies | ForEach-Object {
        [PSCustomObject]@{
            name  = $_.name
            value = "$($_.id)"
        }
    }

    $MappingObj = [PSCustomObject]@{
        Companies = @($Companies)
        Mappings  = @($Mappings)
    }

    return $MappingObj
}
