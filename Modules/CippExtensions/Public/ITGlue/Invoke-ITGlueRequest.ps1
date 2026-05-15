function Invoke-ITGlueRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        $Body,

        [int]$PageSize = 100,

        # When set, returns the flattened collection of `data` items across all pages.
        [switch]$AllPages,

        # When set, returns the raw response (data + meta + links) of the single call.
        [switch]$Raw
    )

    if (-not $script:ITGlueBaseUrl -or -not $script:ITGlueHeaders) {
        throw 'IT Glue API not connected. Call Connect-ITGlueAPI first.'
    }

    # Normalize path
    if ($Path -notmatch '^https?://') {
        if ($Path -notmatch '^/') { $Path = "/$Path" }
        $Uri = "$($script:ITGlueBaseUrl)$Path"
    } else {
        $Uri = $Path
    }

    # Inject page[size] for GETs that lack it
    if ($Method -eq 'GET' -and $Uri -notmatch 'page%5Bsize%5D|page\[size\]') {
        $sep = if ($Uri.Contains('?')) { '&' } else { '?' }
        $Uri = "$Uri$($sep)page[size]=$PageSize"
    }

    $Collected = [System.Collections.Generic.List[object]]::new()
    $MaxRetries = 5

    do {
        $Attempt = 0
        $Response = $null
        while ($Attempt -lt $MaxRetries) {
            try {
                $Splat = @{
                    Uri         = $Uri
                    Method      = $Method
                    Headers     = $script:ITGlueHeaders
                    ErrorAction = 'Stop'
                }
                if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                    $Splat['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
                }
                $Response = Invoke-RestMethod @Splat
                break
            } catch {
                $StatusCode = $null
                if ($_.Exception.Response) {
                    $StatusCode = [int]$_.Exception.Response.StatusCode
                }
                if ($StatusCode -eq 429) {
                    $RetryAfter = 10
                    try {
                        $Header = $_.Exception.Response.Headers['Retry-After']
                        if ($Header) { $RetryAfter = [int]$Header }
                    } catch {}
                    Write-Information "IT Glue 429 rate-limited; sleeping $RetryAfter seconds before retry."
                    Start-Sleep -Seconds $RetryAfter
                    $Attempt++
                    continue
                }
                throw
            }
        }

        if ($Raw) { return $Response }

        if ($null -ne $Response.data) {
            if ($Response.data -is [System.Array]) {
                foreach ($item in $Response.data) { $Collected.Add($item) }
            } else {
                $Collected.Add($Response.data)
            }
        }

        $Uri = if ($AllPages -and $Response.links -and $Response.links.next) { $Response.links.next } else { $null }
    } while ($Uri)

    return $Collected.ToArray()
}
