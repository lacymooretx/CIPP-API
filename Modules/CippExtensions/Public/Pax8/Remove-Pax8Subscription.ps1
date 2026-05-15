function Remove-Pax8Subscription {
    <#
    .SYNOPSIS
        Cancel one or more Pax8 subscriptions.
    .DESCRIPTION
        Pax8 cancels per subscription via DELETE /v1/subscriptions/{id}.
        Accepts a single ID or an array. Enforces Pax8.AllowedCustomRoles
        when called from an HTTP context (Headers parameter present).
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$CompanyId,
        [Parameter(Mandatory = $true)]
        [string[]]$SubscriptionIds,
        [string]$TenantFilter,
        [datetime]$CancelDate,
        $Headers
    )

    if ($Headers) {
        $Table = Get-CIPPTable -TableName Extensionsconfig
        $ExtensionConfig = (Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json
        $Config = $ExtensionConfig.Pax8
        $AllowedRoles = $Config.AllowedCustomRoles.value
        if ($AllowedRoles -and $Headers.'x-ms-client-principal') {
            $UserRoles = Get-CIPPAccessRole -Headers $Headers
            $Allowed = $false
            foreach ($Role in $UserRoles) {
                if ($AllowedRoles -contains $Role) {
                    Write-Information "User has allowed CIPP role: $Role"
                    $Allowed = $true; break
                }
            }
            if (-not $Allowed) {
                throw 'This user is not allowed to modify Pax8 Licenses.'
            }
        }
    }

    if ($TenantFilter) {
        $CustomerId = (Get-Tenants -TenantFilter $TenantFilter).customerId
        $CompanyId = Get-ExtensionMapping -Extension 'Pax8' | Where-Object { $_.RowKey -eq $CustomerId } | Select-Object -ExpandProperty IntegrationId
    }

    $AuthHeaders = Get-Pax8Authentication
    $Results = foreach ($SubId in $SubscriptionIds) {
        $Uri = "https://api.pax8.com/v1/subscriptions/$SubId"
        if ($CancelDate) {
            $Uri += "?cancelDate=$($CancelDate.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        }
        Invoke-RestMethod -Uri $Uri -Method DELETE -Headers $AuthHeaders -ErrorAction Stop
    }
    return $Results
}
