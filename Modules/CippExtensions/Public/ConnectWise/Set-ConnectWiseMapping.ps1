function Set-ConnectWiseMapping {
    param (
        $CIPPMapping,
        $APIName,
        $Request
    )

    Get-CIPPAzDataTableEntity @CIPPMapping -Filter "PartitionKey eq 'ConnectWiseMapping'" | ForEach-Object {
        Remove-AzDataTableEntity -Force @CIPPMapping -Entity $_
    }

    # Body shape tolerance: UI posts an array; programmatic callers may wrap as {items:[...]} or {mappings:[...]}.
    $Items = if ($Request.Body -is [System.Collections.IEnumerable] -and $Request.Body -isnot [string] -and $Request.Body -isnot [System.Collections.IDictionary]) {
        $Request.Body
    } elseif ($Request.Body.items) {
        $Request.Body.items
    } elseif ($Request.Body.mappings) {
        $Request.Body.mappings
    } else {
        @($Request.Body)
    }
    foreach ($Mapping in $Items) {
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
