function New-ConnectWiseTicket {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        $Title,
        $Description,
        $Client
    )

    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json).ConnectWise
    $TicketTable = Get-CIPPTable -TableName 'PSATickets'
    $Headers = Get-ConnectWiseHeaders -Configuration $Configuration
    $BaseURL = "$($Configuration.BaseURL)/v4_6_release/apis/3.0"
    $TitleHash = Get-StringHash -String $Title

    if ($Configuration.ConsolidateTickets) {
        $ExistingTicket = Get-CIPPAzDataTableEntity @TicketTable -Filter "PartitionKey eq 'ConnectWise' and RowKey eq '$($Client)-$($TitleHash)'"
        if ($ExistingTicket) {
            Write-Information "Ticket already exists in ConnectWise: $($ExistingTicket.TicketID)"

            $Ticket = Invoke-RestMethod -Uri "$BaseURL/service/tickets/$($ExistingTicket.TicketID)" -Method GET -Headers $Headers -SkipHttpErrorCheck
            if ($Ticket.id -and -not $Ticket.closedFlag) {
                Write-Information 'Ticket is still open, adding note'
                $NoteBody = @{
                    text                   = $Description
                    detailDescriptionFlag  = $true
                    internalAnalysisFlag   = $false
                    resolutionFlag         = $false
                    internalFlag           = $true
                    externalFlag           = $false
                } | ConvertTo-Json -Compress

                try {
                    if ($PSCmdlet.ShouldProcess('Add note to ConnectWise ticket', 'Add note')) {
                        $null = Invoke-RestMethod -Uri "$BaseURL/service/tickets/$($ExistingTicket.TicketID)/notes" -Method POST -Headers $Headers -Body $NoteBody
                        Write-Information "Note added to ticket in ConnectWise: $($ExistingTicket.TicketID)"
                    }
                    return "Note added to ticket in ConnectWise: $($ExistingTicket.TicketID)"
                } catch {
                    $Message = if ($_.ErrorDetails.Message) {
                        Get-NormalizedError -Message $_.ErrorDetails.Message
                    } else {
                        $_.Exception.Message
                    }
                    Write-LogMessage -message "Failed to add note to ConnectWise ticket: $Message" -API 'ConnectWiseTicket' -sev Error -LogData (Get-CippException -Exception $_)
                    return "Failed to add note to ConnectWise ticket: $Message"
                }
            } else {
                Write-Information 'Existing ticket could not be found or is closed. Creating a new ticket.'
            }
        }
    }

    $TicketObject = @{
        summary = $Title
        company = @{
            id = [int]($Client | Select-Object -Last 1)
        }
        initialDescription = $Description
    }

    if ($Configuration.Board) {
        $BoardId = $Configuration.Board.value ?? $Configuration.Board
        $TicketObject.board = @{ id = [int]$BoardId }
    }

    if ($Configuration.Priority) {
        $PriorityId = $Configuration.Priority.value ?? $Configuration.Priority
        $TicketObject.priority = @{ id = [int]$PriorityId }
    }

    $Body = ConvertTo-Json -Compress -Depth 10 -InputObject $TicketObject

    Write-Information 'Sending ticket to ConnectWise Manage'
    Write-Information $Body
    try {
        if ($PSCmdlet.ShouldProcess('Send ticket to ConnectWise Manage', 'Create ticket')) {
            $Ticket = Invoke-RestMethod -Uri "$BaseURL/service/tickets" -Method POST -Headers $Headers -Body $Body
            Write-Information "Ticket created in ConnectWise: $($Ticket.id)"

            if ($Configuration.ConsolidateTickets) {
                $ConsolidationObject = [PSCustomObject]@{
                    PartitionKey = 'ConnectWise'
                    RowKey       = "$($Client)-$($TitleHash)"
                    Title        = $Title
                    ClientId     = $Client
                    TicketID     = $Ticket.id
                }
                Add-CIPPAzDataTableEntity @TicketTable -Entity $ConsolidationObject -Force
                Write-Information 'Ticket added to consolidation table'
            }
            return "Ticket created in ConnectWise: $($Ticket.id)"
        }
    } catch {
        $Message = if ($_.ErrorDetails.Message) {
            Get-NormalizedError -Message $_.ErrorDetails.Message
        } else {
            $_.Exception.Message
        }
        Write-LogMessage -message "Failed to send ticket to ConnectWise: $Message" -API 'ConnectWiseTicket' -sev Error -LogData (Get-CippException -Exception $_)
        Write-Information "Failed to send ticket to ConnectWise: $Message"
        Write-Information "Body we tried to ship: $Body"
        return "Failed to send ticket to ConnectWise: $Message"
    }
}
