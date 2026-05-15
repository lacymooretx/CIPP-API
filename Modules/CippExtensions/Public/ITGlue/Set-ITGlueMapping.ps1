function Set-ITGlueMapping {
    [CmdletBinding()]
    param (
        $CIPPMapping,
        $APIName,
        $Request
    )
    Get-CIPPAzDataTableEntity @CIPPMapping -Filter "PartitionKey eq 'ITGlueMapping'" | ForEach-Object {
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
        $AddObject = @{
            PartitionKey    = 'ITGlueMapping'
            RowKey          = "$($mapping.TenantId)"
            IntegrationId   = "$($mapping.IntegrationId)"
            IntegrationName = "$($mapping.IntegrationName)"
        }

        Add-CIPPAzDataTableEntity @CIPPMapping -Entity $AddObject -Force
        Write-LogMessage -API $APINAME -headers $Request.Headers -message "Added mapping for $($mapping.name)." -Sev 'Info'
    }
    $Result = [pscustomobject]@{'Results' = 'Successfully edited mapping table.' }

    Return $Result
}
