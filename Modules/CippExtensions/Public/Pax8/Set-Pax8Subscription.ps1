function Set-Pax8Subscription {
    <#
    .SYNOPSIS
        Buy a new Pax8 subscription or change the quantity of an existing one.
    .DESCRIPTION
        - With -Quantity (and no existing sub for the product): creates an
          order via POST /v1/orders, with the lineItem productId/quantity.
        - With -Add or -Remove: updates the existing sub's quantity via
          PUT /v1/subscriptions/{id}.
        - Enforces Pax8.AllowedCustomRoles when called from an HTTP context
          (Headers parameter present) — same pattern as Sherweb.

        SKU is the Pax8 productId (UUID). The /api/ListCSPsku endpoint
        returns SKUs that match this expectation so the SPA picker works
        without modification.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$CompanyId,
        [Parameter(Mandatory = $true)]
        [string]$SKU,
        [int]$Quantity,
        [int]$Add,
        [int]$Remove,
        [string]$BillingTerm = 'Monthly',
        [string]$TenantFilter,
        $Headers
    )

    if ($Headers) {
        # AllowedCustomRoles role gate — identical to Sherweb's pattern.
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
                throw 'This user is not allowed to modify Pax8 subscriptions.'
            }
        }
    }

    if ($TenantFilter) {
        $CustomerId = (Get-Tenants -TenantFilter $TenantFilter).customerId
        $CompanyId = Get-ExtensionMapping -Extension 'Pax8' | Where-Object { $_.RowKey -eq $CustomerId } | Select-Object -ExpandProperty IntegrationId
    }
    if ([string]::IsNullOrEmpty($CompanyId)) {
        throw 'No Pax8 mapping found'
    }

    $AuthHeaders = Get-Pax8Authentication

    # Match by productId on the company's current subscriptions
    $ExistingSubscription = Get-Pax8Subscriptions -CompanyId $CompanyId -SKU $SKU

    if (-not $ExistingSubscription) {
        if ($Add -or $Remove) {
            throw "Unable to Add or Remove. No existing Pax8 subscription with productId '$SKU' found."
        }
        if (-not $Quantity -or $Quantity -le 0) {
            throw 'A valid Quantity must be specified to create a new Pax8 subscription when none currently exists.'
        }
        # POST /v1/orders
        $OrderBody = @{
            companyId = $CompanyId
            lineItems = @(
                @{
                    productId      = $SKU
                    billingTerm    = $BillingTerm
                    quantity       = $Quantity
                    lineItemNumber = 1
                }
            )
        } | ConvertTo-Json -Depth 10
        $Order = Invoke-RestMethod -Uri 'https://api.pax8.com/v1/orders' -Method POST -Headers $AuthHeaders -Body $OrderBody -ContentType 'application/json' -ErrorAction Stop
        return $Order
    }

    $SubscriptionId = $ExistingSubscription[0].id
    $CurrentQuantity = [int]$ExistingSubscription[0].quantity

    if ($Add) {
        $FinalQuantity = $CurrentQuantity + $Add
    } elseif ($Remove) {
        $FinalQuantity = $CurrentQuantity - $Remove
        if ($FinalQuantity -lt 0) {
            throw "Cannot remove more licenses than currently allocated. Current: $CurrentQuantity, Attempting to remove: $Remove."
        }
    } else {
        if (-not $Quantity -or $Quantity -le 0) {
            throw 'A valid Quantity must be specified if Add/Remove are not used.'
        }
        $FinalQuantity = $Quantity
    }

    $UpdateBody = @{ quantity = $FinalQuantity } | ConvertTo-Json
    $Uri = "https://api.pax8.com/v1/subscriptions/$SubscriptionId"
    $Update = Invoke-RestMethod -Uri $Uri -Method PUT -Headers $AuthHeaders -Body $UpdateBody -ContentType 'application/json' -ErrorAction Stop
    return $Update
}
