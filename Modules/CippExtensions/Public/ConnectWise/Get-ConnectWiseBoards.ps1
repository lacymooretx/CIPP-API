function Get-ConnectWiseBoards {
    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json).ConnectWise
    $Headers = Get-ConnectWiseHeaders -Configuration $Configuration

    $BaseURL = "$($Configuration.BaseURL)/v4_6_release/apis/3.0"

    $Boards = Invoke-RestMethod -Uri "$BaseURL/service/boards?pageSize=1000" -Method GET -Headers $Headers
    $Priorities = Invoke-RestMethod -Uri "$BaseURL/service/priorities?pageSize=1000" -Method GET -Headers $Headers

    return @{
        Boards     = $Boards
        Priorities = $Priorities
    }
}
