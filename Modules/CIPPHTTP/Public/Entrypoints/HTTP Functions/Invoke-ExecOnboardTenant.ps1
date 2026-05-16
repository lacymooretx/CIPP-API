function Invoke-ExecOnboardTenant {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.Extension.ReadWrite
    .SYNOPSIS
        Cross-integration onboarding orchestrator. Adds or updates a CIPP
        tenant's mappings across Pax8, IT Glue, ConnectWise, Sherweb, Hudu
        in one call — idempotent, only touches the mappings you reference.
    .DESCRIPTION
        Two modes:

        1. Explicit mappings — POST a body like
           {
             "tenantId":"<customerId-guid>",
             "mappings": {
               "Pax8":        "<pax8-company-uuid>",
               "ITGlue":      "<itglue-org-id>",
               "ConnectWise": "<cw-company-id>",
               "Hudu":        "<hudu-company-id>",
               "Sherweb":     "<sherweb-customer-id>"
             }
           }
           Each entry creates/overwrites the mapping for that one tenant
           in that one mapping table. Other tenants are untouched.

        2. Auto-match by name — POST
           {
             "tenantId":"<customerId-guid>" | "all",
             "autoMatch": true,
             "providers": ["Pax8","ITGlue","ConnectWise"]   // optional, defaults to enabled
           }
           For each provider, pulls the remote list and matches by
           normalized display name. Unique matches get linked; ambiguous
           or zero matches are skipped and reported back.

        Body shape tolerance: cipp_call MCP wraps payloads as objects,
        so this accepts the request body as-is and reads .tenantId / .mappings
        / .autoMatch directly.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $Body          = $Request.Body
    $TenantId      = "$($Body.tenantId)"
    $AutoMatch     = $Body.autoMatch -eq $true
    $ExplicitMaps  = $Body.mappings
    $RequestedProv = $Body.providers
    $Results       = [System.Collections.Generic.List[object]]::new()

    $MappingTable = Get-CIPPTable -TableName 'CippMapping'
    $Tenants = Get-Tenants -IncludeErrors

    # Decide which tenants to operate on
    $TenantsToProcess = if ($TenantId -eq 'all') {
        $Tenants
    } elseif ($TenantId) {
        @($Tenants | Where-Object { $_.customerId -eq $TenantId -or $_.defaultDomainName -eq $TenantId })
    } else {
        return [HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = 'tenantId is required (use "all" for every tenant).'
        }
    }
    if (-not $TenantsToProcess) {
        return [HttpResponseContext]@{ StatusCode = [HttpStatusCode]::NotFound; Body = "Tenant '$TenantId' not found." }
    }

    # Which providers are in play?
    $ExtTable = Get-CIPPTable -TableName Extensionsconfig
    $ExtCfg   = (Get-CIPPAzDataTableEntity @ExtTable).config | ConvertFrom-Json
    $EnabledProviders = @()
    foreach ($p in @('Pax8','ITGlue','ConnectWise','Hudu','Sherweb')) {
        if ($ExtCfg.$p.Enabled -eq $true) { $EnabledProviders += $p }
    }
    $ActiveProviders = if ($RequestedProv) {
        $RequestedProv | Where-Object { $EnabledProviders -contains $_ }
    } else { $EnabledProviders }

    # If explicit mappings are provided, AutoMatch is implied off for those providers
    if ($ExplicitMaps) {
        foreach ($prop in $ExplicitMaps.PSObject.Properties) {
            $Provider = $prop.Name
            $IntegrationId = "$($prop.Value)"
            $TargetTenant = $TenantsToProcess | Select-Object -First 1
            if ($TenantsToProcess.Count -gt 1) {
                $Results.Add([PSCustomObject]@{ provider=$Provider; status='skipped'; reason='Explicit mappings only supported for a single tenant.' }) | Out-Null
                continue
            }
            $PartitionKey = "${Provider}Mapping"
            $AddObject = @{
                PartitionKey    = $PartitionKey
                RowKey          = "$($TargetTenant.customerId)"
                IntegrationId   = $IntegrationId
                IntegrationName = "(set via onboarding orchestrator)"
            }
            Add-CIPPAzDataTableEntity @MappingTable -Entity $AddObject -Force
            $Results.Add([PSCustomObject]@{
                tenant = $TargetTenant.displayName; provider = $Provider; status='mapped'; integrationId=$IntegrationId
            }) | Out-Null
        }
    }

    if ($AutoMatch -and $ActiveProviders) {
        # Pull remote lists once per provider, cache by provider name
        $RemoteByProvider = @{}
        $Normalize = { param($s)
            ($s -replace '[^a-z0-9]','').ToLowerInvariant()
        }
        foreach ($Provider in $ActiveProviders) {
            try {
                $remote = switch ($Provider) {
                    'Pax8'        { Get-Pax8Companies }
                    'ITGlue'      {
                        $Table = Get-CIPPTable -TableName Extensionsconfig
                        $Cfg = (Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json
                        Connect-ITGlueAPI -configuration $Cfg
                        Invoke-ITGlueRequest -Path '/organizations' -AllPages | ForEach-Object {
                            [PSCustomObject]@{ id = $_.id; name = $_.attributes.name }
                        }
                    }
                    'ConnectWise' { (Get-ConnectWiseMapping -CIPPMapping $MappingTable).Companies | ForEach-Object { [PSCustomObject]@{ id=$_.value; name=$_.name } } }
                    'Hudu'        { (Get-HuduMapping -CIPPMapping $MappingTable).Companies          | ForEach-Object { [PSCustomObject]@{ id=$_.value; name=$_.name } } }
                    'Sherweb'     { Get-SherwebCustomers | ForEach-Object { [PSCustomObject]@{ id=$_.id; name=$_.displayName } } }
                }
                $RemoteByProvider[$Provider] = @($remote)
            } catch {
                $Results.Add([PSCustomObject]@{ provider=$Provider; status='error'; reason="Could not list remote companies: $($_.Exception.Message)" }) | Out-Null
                $RemoteByProvider[$Provider] = $null
            }
        }

        foreach ($Tenant in $TenantsToProcess) {
            $TenantKey = & $Normalize $Tenant.displayName
            foreach ($Provider in $ActiveProviders) {
                if ($null -eq $RemoteByProvider[$Provider]) { continue }
                $PartitionKey = "${Provider}Mapping"
                $Existing = Get-CIPPAzDataTableEntity @MappingTable -Filter "PartitionKey eq '$PartitionKey' and RowKey eq '$($Tenant.customerId)'"
                if ($Existing) {
                    $Results.Add([PSCustomObject]@{ tenant=$Tenant.displayName; provider=$Provider; status='already_mapped'; integrationId=$Existing.IntegrationId }) | Out-Null
                    continue
                }
                $Hits = $RemoteByProvider[$Provider] | Where-Object { (& $Normalize $_.name) -eq $TenantKey }
                if (-not $Hits) {
                    $Results.Add([PSCustomObject]@{ tenant=$Tenant.displayName; provider=$Provider; status='no_match' }) | Out-Null
                } elseif (($Hits | Measure-Object).Count -gt 1) {
                    $Results.Add([PSCustomObject]@{ tenant=$Tenant.displayName; provider=$Provider; status='ambiguous'; candidates=@($Hits | ForEach-Object { "$($_.id):$($_.name)" }) }) | Out-Null
                } else {
                    $h = $Hits | Select-Object -First 1
                    $AddObject = @{
                        PartitionKey    = $PartitionKey
                        RowKey          = "$($Tenant.customerId)"
                        IntegrationId   = "$($h.id)"
                        IntegrationName = "$($h.name)"
                    }
                    Add-CIPPAzDataTableEntity @MappingTable -Entity $AddObject -Force
                    $Results.Add([PSCustomObject]@{ tenant=$Tenant.displayName; provider=$Provider; status='mapped'; integrationId="$($h.id)"; integrationName="$($h.name)" }) | Out-Null
                }
            }
        }
    }

    return [HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            results = @($Results)
            summary = @{
                mapped         = ($Results | Where-Object { $_.status -eq 'mapped' }        | Measure-Object).Count
                already_mapped = ($Results | Where-Object { $_.status -eq 'already_mapped' }| Measure-Object).Count
                no_match       = ($Results | Where-Object { $_.status -eq 'no_match' }      | Measure-Object).Count
                ambiguous      = ($Results | Where-Object { $_.status -eq 'ambiguous' }     | Measure-Object).Count
                errors         = ($Results | Where-Object { $_.status -eq 'error' }         | Measure-Object).Count
            }
        }
    }
}
