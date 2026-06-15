function Invoke-EditExConnector {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Exchange.Connector.ReadWrite
    .DESCRIPTION
        Edits an Exchange Online mail connector. Toggles the connector Enabled state and,
        for Inbound connectors, configures Enhanced Filtering for Connectors ("skip listing")
        so spoof/DMARC/external-tag evaluation uses the real sender IP when mail is fronted by
        a 3rd-party gateway (Avanan / Proofpoint / Mimecast, etc.).

        Body/query params:
          tenantFilter (required)
          GUID         (required) - connector Identity
          Type         (required) - 'Inbound' or 'Outbound'
          State        - 'Enable' / 'Disable'. If omitted, the Enabled state is left unchanged.
        Enhanced Filtering (Inbound connectors only):
          EFSkipLastIP - bool. Skip the last/most-recent IP. Mutually exclusive with EFSkipIPs.
          EFSkipIPs    - array or comma/newline string of IPs/CIDRs to skip.
          EFUsers      - array or comma/newline string of recipients EF applies to (empty = all).
          EFTestMode   - bool.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $Guid = $Request.Query.GUID ?? $Request.Body.GUID
    $Type = $Request.Query.Type ?? $Request.Body.Type
    $ConnectorState = $Request.Query.State ?? $Request.Body.State

    # Loose truthy coercion for query/body flags (query values arrive as strings).
    $TruthyValues = @($true, 'true', 'True', 1, '1', 'yes', 'on')

    # Normalize a value that may be an array (JSON body) or a delimited string (query) to string[].
    $ToEFArray = {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [array]) { return @($Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
        return @("$Value" -split '[\r\n,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    # Enhanced Filtering inputs (Inbound connectors only)
    $EFSkipLastIPRaw = $Request.Body.EFSkipLastIP ?? $Request.Query.EFSkipLastIP
    $EFTestModeRaw = $Request.Body.EFTestMode ?? $Request.Query.EFTestMode
    $EFSkipIPs = & $ToEFArray ($Request.Body.EFSkipIPs ?? $Request.Query.EFSkipIPs)
    $EFUsers = & $ToEFArray ($Request.Body.EFUsers ?? $Request.Query.EFUsers)
    $HasEFChange = ($null -ne $EFSkipLastIPRaw) -or ($null -ne $EFTestModeRaw) -or ($null -ne $EFSkipIPs) -or ($null -ne $EFUsers)

    try {
        if (-not $Guid) { throw 'GUID (connector Identity) is required.' }
        if ($Type -notin @('Inbound', 'Outbound')) { throw "Type must be 'Inbound' or 'Outbound'." }
        if ($HasEFChange -and $Type -ne 'Inbound') { throw 'Enhanced Filtering settings are only valid on Inbound connectors.' }

        $Params = @{ Identity = $Guid }

        # Only touch Enabled when State was explicitly provided, so EF-only edits don't flip it.
        if (-not [string]::IsNullOrEmpty($ConnectorState)) {
            $Params.Enabled = $ConnectorState -eq 'Enable'
        }

        if ($HasEFChange) {
            if ($null -ne $EFSkipLastIPRaw) { $Params.EFSkipLastIP = ($EFSkipLastIPRaw -in $TruthyValues) }
            if ($null -ne $EFTestModeRaw) { $Params.EFTestMode = ($EFTestModeRaw -in $TruthyValues) }
            # EFSkipIPs and EFSkipLastIP are mutually exclusive in EXO; setting explicit IPs
            # requires EFSkipLastIP=$false. Apply that automatically when the caller didn't specify.
            if ($null -ne $EFSkipIPs) {
                $Params.EFSkipIPs = $EFSkipIPs
                if ($null -eq $EFSkipLastIPRaw) { $Params.EFSkipLastIP = $false }
            }
            if ($null -ne $EFUsers) { $Params.EFUsers = $EFUsers }
        }

        if ($Params.Keys.Count -le 1) { throw 'No connector changes supplied (provide State and/or Enhanced Filtering settings).' }

        $null = New-ExoRequest -tenantid $TenantFilter -cmdlet "Set-$($Type)Connector" -cmdParams $Params -UseSystemMailbox $true

        $ChangeParts = [System.Collections.Generic.List[string]]::new()
        if ($Params.ContainsKey('Enabled')) { $ChangeParts.Add("Enabled=$($Params.Enabled)") }
        if ($Params.ContainsKey('EFSkipLastIP')) { $ChangeParts.Add("EFSkipLastIP=$($Params.EFSkipLastIP)") }
        if ($Params.ContainsKey('EFSkipIPs')) { $ChangeParts.Add("EFSkipIPs=[$($Params.EFSkipIPs -join ', ')]") }
        if ($Params.ContainsKey('EFUsers')) { $ChangeParts.Add("EFUsers=[$($Params.EFUsers -join ', ')]") }
        if ($Params.ContainsKey('EFTestMode')) { $ChangeParts.Add("EFTestMode=$($Params.EFTestMode)") }
        $Result = "Updated $Type connector $($Guid): $($ChangeParts -join '; ')"

        Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message $Result -sev Info
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CIPPException -Exception $_
        Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Failed editing Connector $($Guid). Error: $($ErrorMessage.NormalizedError)" -Sev Error -LogData $ErrorMessage
        $Result = $ErrorMessage.NormalizedError
        $StatusCode = [HttpStatusCode]::Forbidden
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{Results = $Result }
        })

}
