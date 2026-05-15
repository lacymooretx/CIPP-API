function Get-Pax8Mapping {
    [CmdletBinding()]
    param (
        $CIPPMapping
    )

    $ExtensionMappings = Get-ExtensionMapping -Extension 'Pax8'

    $Tenants = Get-Tenants -IncludeErrors
    $Mappings = foreach ($Mapping in $ExtensionMappings) {
        $Tenant = $Tenants | Where-Object { $_.customerId -eq $Mapping.RowKey }
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

    try {
        $Pax8Companies = Get-Pax8Companies | ForEach-Object {
            [PSCustomObject]@{
                name  = $_.name
                value = "$($_.id)"
            }
        } | Sort-Object -Property name
    } catch {
        $Message = if ($_.ErrorDetails.Message) {
            Get-NormalizedError -Message $_.ErrorDetails.Message
        } else {
            $_.Exception.Message
        }
        Write-LogMessage -Message "Could not get Pax8 Companies, error: $Message" -Level Error -tenant 'CIPP' -API 'Pax8Mapping'
        $Pax8Companies = @([PSCustomObject]@{ name = "Could not get Pax8 Companies, error: $Message"; value = '-1' })
    }

    $MappingObj = [PSCustomObject]@{
        Companies = @($Pax8Companies)
        Mappings  = @($Mappings)
    }
    return $MappingObj
}
