function Get-ITGlueMapping {
    [CmdletBinding()]
    param (
        $CIPPMapping
    )

    $ExtensionMappings = Get-ExtensionMapping -Extension 'ITGlue'

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
    try {
        $Configuration = (Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json -ea stop
        Connect-ITGlueAPI -configuration $Configuration

        $OrgsRaw = Invoke-ITGlueRequest -Path '/organizations' -AllPages
        $ITGlueOrganizations = foreach ($Org in $OrgsRaw) {
            [PSCustomObject]@{
                name  = $Org.attributes.name
                value = "$($Org.id)"
            }
        }
        $ITGlueOrganizations = $ITGlueOrganizations | Sort-Object -Property name
    } catch {
        $Message = if ($_.ErrorDetails.Message) {
            Get-NormalizedError -Message $_.ErrorDetails.Message
        } else {
            $_.Exception.message
        }

        Write-LogMessage -Message "Could not get IT Glue Organizations, error: $Message" -Level Error -tenant 'CIPP' -API 'ITGlueMapping'
        $ITGlueOrganizations = @([PSCustomObject]@{ name = "Could not get IT Glue Organizations, error: $Message"; value = '-1' })
    }

    $MappingObj = [PSCustomObject]@{
        Companies = @($ITGlueOrganizations)
        Mappings  = @($Mappings)
    }

    return $MappingObj
}
