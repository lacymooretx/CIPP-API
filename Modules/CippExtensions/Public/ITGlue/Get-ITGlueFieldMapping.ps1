function Get-ITGlueFieldMapping {
    [CmdletBinding()]
    param (
        $CIPPMapping
    )

    $Mappings = Get-ExtensionMapping -Extension 'ITGlueField'

    $CIPPFieldHeaders = @(
        [PSCustomObject]@{
            Title       = 'IT Glue Flexible Asset Types'
            FieldType   = 'FlexAssetTypes'
            Description = 'Choose the Flexible Asset Type that will receive the M365 User rich-text record. A new field will be added to the type if needed.'
        }
        [PSCustomObject]@{
            Title       = 'IT Glue Configuration Types'
            FieldType   = 'ConfigurationTypes'
            Description = 'Choose the Configuration Type that synced M365 Devices will be created under.'
        }
    )
    $CIPPFields = @(
        [PSCustomObject]@{
            FieldName  = 'Users'
            FieldLabel = 'Flexible Asset Type for M365 Users'
            FieldType  = 'FlexAssetTypes'
        }
        [PSCustomObject]@{
            FieldName  = 'Devices'
            FieldLabel = 'Configuration Type for M365 Devices'
            FieldType  = 'ConfigurationTypes'
        }
    )

    $FlexAssetTypes = @()
    $ConfigTypes = @()

    $Table = Get-CIPPTable -TableName Extensionsconfig
    try {
        $Configuration = (Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json -ea stop
        Connect-ITGlueAPI -configuration $Configuration

        try {
            $FlexAssetTypesRaw = Invoke-ITGlueRequest -Path '/flexible_asset_types' -AllPages
            $FlexAssetTypes = foreach ($Type in $FlexAssetTypesRaw) {
                [PSCustomObject]@{
                    FieldType = 'FlexAssetTypes'
                    name      = $Type.attributes.name
                    value     = "$($Type.id)"
                }
            }
        } catch {
            $Message = $_.Exception.Message
            Write-LogMessage -Message "Could not get IT Glue Flexible Asset Types, error: $Message" -Level Error -tenant 'CIPP' -API 'ITGlueMapping'
            $FlexAssetTypes = @([PSCustomObject]@{ FieldType = 'FlexAssetTypes'; name = "Could not get Flexible Asset Types: $Message"; value = '-1' })
        }

        try {
            $ConfigTypesRaw = Invoke-ITGlueRequest -Path '/configuration_types' -AllPages
            $ConfigTypes = foreach ($Type in $ConfigTypesRaw) {
                [PSCustomObject]@{
                    FieldType = 'ConfigurationTypes'
                    name      = $Type.attributes.name
                    value     = "$($Type.id)"
                }
            }
        } catch {
            $Message = $_.Exception.Message
            Write-LogMessage -Message "Could not get IT Glue Configuration Types, error: $Message" -Level Error -tenant 'CIPP' -API 'ITGlueMapping'
            $ConfigTypes = @([PSCustomObject]@{ FieldType = 'ConfigurationTypes'; name = "Could not get Configuration Types: $Message"; value = '-1' })
        }
    } catch {
        $Message = $_.Exception.Message
        Write-LogMessage -Message "Could not connect to IT Glue, error: $Message" -Level Error -tenant 'CIPP' -API 'ITGlueMapping'
        $FlexAssetTypes = @([PSCustomObject]@{ FieldType = 'FlexAssetTypes'; name = "Could not connect: $Message"; value = '-1' })
        $ConfigTypes = @([PSCustomObject]@{ FieldType = 'ConfigurationTypes'; name = "Could not connect: $Message"; value = '-1' })
    }

    $Unset = [PSCustomObject]@{
        name  = '--- Do not synchronize ---'
        value = $null
        type  = 'unset'
    }

    $MappingObj = [PSCustomObject]@{
        CIPPFields        = $CIPPFields
        CIPPFieldHeaders  = $CIPPFieldHeaders
        IntegrationFields = @($Unset) + @($FlexAssetTypes) + @($ConfigTypes)
        Mappings          = @($Mappings)
    }

    return $MappingObj
}
