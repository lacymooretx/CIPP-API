function New-ExoRequest {
    <#
    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding(DefaultParameterSetName = 'ExoRequest')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ExoRequest')]
        [string]$cmdlet,

        [Parameter(Mandatory = $false, ParameterSetName = 'ExoRequest')]
        $cmdParams,

        [Parameter(Mandatory = $false, ParameterSetName = 'ExoRequest')]
        [string]$Select,

        [Parameter(Mandatory = $false, ParameterSetName = 'ExoRequest')]
        [string]$Anchor,

        [Parameter(Mandatory = $false, ParameterSetName = 'ExoRequest')]
        [bool]$useSystemMailbox,

        [string]$tenantid,

        [bool]$NoAuthCheck,

        [switch]$Compliance,
        [ValidateSet('v1.0', 'beta')]
        [string]$ApiVersion = 'beta',

        [Parameter(ParameterSetName = 'AvailableCmdlets')]
        [switch]$AvailableCmdlets,

        $ModuleVersion = '3.9.2',
        [switch]$AsApp
    )
    if ((Get-AuthorisedRequest -TenantID $tenantid) -or $NoAuthCheck -eq $True) {
        if ($Compliance.IsPresent) {
            $Resource = 'https://ps.compliance.protection.outlook.com'
        } else {
            $Resource = 'https://outlook.office365.com'
        }
        $token = Get-GraphToken -Tenantid $tenantid -scope "$Resource/.default" -AsApp:$AsApp.IsPresent

        if ($cmdParams) {
            #if cmdParams is a pscustomobject, convert to hashtable, otherwise leave as is
            $Params = $cmdParams
        } else {
            $Params = @{}
        }

        # (C) Per-mailbox EXO cmdlets must be routed (anchored) to the target mailbox's home
        #     server, otherwise EXO returns CmdletProxyNotAvailableException
        #     ("Cmdlet needs proxy ... Required Server FQDN ..."). When the caller didn't pass
        #     an explicit -Anchor, anchor to the target mailbox (Identity/Mailbox) for these.
        $PerMailboxCmdlets = @(
            'Set-Mailbox', 'Set-CASMailbox', 'Set-MailboxAuditBypassAssociation',
            'Set-MailboxAutoReplyConfiguration', 'Set-MailboxMessageConfiguration',
            'Set-MailboxRegionalConfiguration', 'Set-MailboxCalendarConfiguration',
            'Set-Clutter', 'Set-FocusedInbox', 'Set-CalendarProcessing'
        )
        if (-not $Anchor -and $cmdlet -in $PerMailboxCmdlets) {
            $TargetMailbox = if ($Params.Identity) { $Params.Identity } elseif ($Params.Mailbox) { $Params.Mailbox }
            if ($TargetMailbox) { $Anchor = "$TargetMailbox" }
        }

        # (B) A few "void setter" cmdlets return their full config object on the write path.
        #     For Set-OrganizationConfig that object includes the compressed OrganizationConfigHash
        #     blob, which the REST round-trip can't decode ("The archive entry was compressed using
        #     an unsupported compression method") — so the write succeeds but deserialising the
        #     response throws. Project the response down to a harmless property so the blob is
        #     never returned. Extend this map for any other cmdlet that hits the same decode error.
        $VoidSetterProjection = @{
            'Set-OrganizationConfig' = 'Identity'
        }
        if (-not $Select -and $VoidSetterProjection.ContainsKey($cmdlet)) {
            $Select = $VoidSetterProjection[$cmdlet]
        }

        $ExoBody = ConvertTo-Json -Depth 20 -Compress -InputObject @{
            CmdletInput = @{
                CmdletName = $cmdlet
                Parameters = $Params
            }
        }
        $ExoBody = Get-CIPPTextReplacement -TenantFilter $tenantid -Text $ExoBody -EscapeForJson

        $Tenant = Get-Tenants -IncludeErrors | Where-Object { $_.defaultDomainName -eq $tenantid -or $_.customerId -eq $tenantid -or $_.initialDomainName -eq $tenantid } | Select-Object -First 1
        if (-not $Tenant -and $NoAuthCheck -eq $true) {
            $Tenant = [PSCustomObject]@{
                customerId = $tenantid
            }
        }
        if (!$Anchor) {
            $MailboxGuid = 'bb558c35-97f1-4cb9-8ff7-d53741dc928c'
            if ($cmdlet -in 'Set-AdminAuditLogConfig') {
                $MailboxGuid = '8cc370d3-822a-4ab8-a926-bb94bd0641a9'
            }
            if ($Compliance.IsPresent) {
                $Anchor = "UPN:SystemMailbox{$MailboxGuid}@$($tenant.initialDomainName)"
            } else {
                $Anchor = "APP:SystemMailbox{$MailboxGuid}@$($tenant.customerId)"
            }
        }
        #if the anchor is a GUID, try looking up the user.
        if ($Anchor -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            Write-Verbose "Anchor is a GUID, looking up user. GUID is $Anchor"
            $NewAnchor = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/users/$Anchor/?`$select=UserPrincipalName,id" -tenantid $tenantid -NoAuthCheck $NoAuthCheck
            if ($NewAnchor) {
                $Anchor = $NewAnchor.UserPrincipalName
                Write-Verbose "Found GUID, using $Anchor"
            } else {
                Write-Error "Failed to find user with GUID $Anchor"
            }
        }

        Write-Verbose "Using $Anchor"

        $Headers = @{
            Authorization     = $Token.Authorization
            Prefer            = 'odata.maxpagesize=1000'
            'X-AnchorMailbox' = $Anchor
        }

        # Compliance API trickery. Capture Location headers on redirect, extract subdomain and prepend to compliance URL
        if ($Compliance.IsPresent) {
            if (!$Tenant.ComplianceUrl) {
                Write-Verbose "Getting Compliance URL for $($tenant.defaultDomainName)"
                $URL = "$Resource/adminapi/$ApiVersion/$($tenant.customerId)/EXOBanner('AutogenSession')?Version=$ModuleVersion"
                Invoke-CIPPRestMethod -ResponseHeadersVariable ComplianceHeaders -MaximumRedirection 0 -ErrorAction SilentlyContinue -Uri $URL -Headers $Headers -SkipHttpErrorCheck | Out-Null
                $RedirectedHost = ([System.Uri]($ComplianceHeaders.Location | Select-Object -First 1)).Host
                $RedirectedHostname = '{0}.ps.compliance.protection.outlook.com' -f ($RedirectedHost -split '\.' | Select-Object -First 1)
                $Resource = "https://$($RedirectedHostname)"
                try {
                    $null = [System.Uri]$Resource
                    $Tenant | Add-Member -MemberType NoteProperty -Name ComplianceUrl -Value $Resource
                    $TenantTable = Get-CIPPTable -tablename 'Tenants'
                    Add-CIPPAzDataTableEntity @TenantTable -Entity $Tenant -Force
                } catch {
                    Write-Error "Failed to get the Compliance URL for $($tenant.defaultDomainName), invalid URL - check the Anchor and try again."
                    return
                }
            } else {
                $Resource = $Tenant.ComplianceUrl
            }
            Write-Verbose "Redirecting to $Resource"
        }

        if ($PSCmdlet.ParameterSetName -eq 'AvailableCmdlets') {
            $Headers.CommandName = '*'
            $URL = "$Resource/adminapi/v1.0/$($tenant.customerId)/EXOModuleFile?Version=$ModuleVersion"
            Write-Verbose "GET [ $URL ]"
            return (Invoke-CIPPRestMethod -Uri $URL -Headers $Headers).value.exportedCmdlets -split ',' | Where-Object { $_ } | Sort-Object
        }

        if ($PSCmdlet.ParameterSetName -eq 'ExoRequest') {
            try {
                if ($Select) { $Select = "?`$select=$Select" }
                $URL = "$Resource/adminapi/$ApiVersion/$($tenant.customerId)/InvokeCommand$Select"

                Write-Information "POST [ $URL ] | tenant: $tenantid | cmdlet: $cmdlet"
                Write-Verbose "Request Body: $ExoBody"
                $ReturnedData = do {
                    $ExoRequestParams = @{
                        Uri         = $URL
                        Method      = 'POST'
                        Body        = $ExoBody
                        Headers     = $Headers
                        ContentType = 'application/json; charset=utf-8'
                    }

                    $Return = Invoke-CIPPRestMethod @ExoRequestParams -ResponseHeadersVariable ResponseHeaders
                    $URL = $Return.'@odata.nextLink'
                    $Return
                } until ($null -eq $URL)

                Write-Verbose "Response Headers: $($ResponseHeaders | ConvertTo-Json -Depth 5 -Compress)"
                if ($ReturnedData.'@adminapi.warnings' -and $null -eq $ReturnedData.value) {
                    $ReturnedData.value = $ReturnedData.'@adminapi.warnings'
                }
            } catch {
                $ErrorMess = $($_.Exception.Message)
                try {
                    $ReportedError = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue)
                    $Message = if ($ReportedError.error.details.message) {
                        $ReportedError.error.details.message
                    } elseif ($ReportedError.error.innererror) {
                        $ReportedError.error.innererror.internalException.message
                    } elseif ($ReportedError.error.message) { $ReportedError.error.message }
                } catch { $Message = $_.ErrorDetails }
                if ($null -eq $Message) { $Message = $ErrorMess }
                # (B) For void setters, the write applied server-side; only decoding the compressed
                #     response blob failed. Don't surface that as a failure. The $Select projection
                #     above should normally prevent it; this is a fallback if the cmdlet ignores it.
                if ($Message -match 'unsupported compression method' -and $VoidSetterProjection.ContainsKey($cmdlet)) {
                    Write-Information "EXO $cmdlet applied; suppressing benign response-decode error (compressed config blob on return path)."
                    return
                }
                throw $Message
            }
            return $ReturnedData.value
        }
    } else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope'
    }
}
