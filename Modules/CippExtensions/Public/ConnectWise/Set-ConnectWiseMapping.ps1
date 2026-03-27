function Set-ConnectWiseMapping {
    param (
        $CIPPMapping,
        $APIName,
        $Request
    )

    Get-CIPPAzDataTableEntity @CIPPMapping -Filter "PartitionKey eq 'ConnectWiseMapping'" | ForEach-Object {
        Remove-AzDataTableEntity -Force @CIPPMapping -Entity $_
    }

    foreach ($Mapping in $Request.Body) {
        if ($Mapping.TenantId) {
            $AddObject = @{
                PartitionKey    = 'ConnectWiseMapping'
                RowKey          = "$($Mapping.TenantId)"
                IntegrationId   = "$($Mapping.IntegrationId)"
                IntegrationName = "$($Mapping.IntegrationName)"
            }
            Add-CIPPAzDataTableEntity @CIPPMapping -Entity $AddObject -Force
            Write-LogMessage -API $APIName -headers $Request.Headers -message "Added ConnectWise mapping for $($Mapping.name)." -Sev 'Info'
        }
    }
}
