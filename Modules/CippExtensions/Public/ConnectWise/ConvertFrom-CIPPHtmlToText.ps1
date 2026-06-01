function ConvertFrom-CIPPHtmlToText {
    <#
    .SYNOPSIS
        Converts an HTML string (including CIPP MJML alert emails) into readable plain text.
    .DESCRIPTION
        ConnectWise Manage ticket descriptions and notes are plain-text fields and do not
        render HTML. CIPP alert templates are full MJML email documents, so posting them
        verbatim dumps raw markup into the ticket (see CW #54851). This helper removes the
        email scaffold and produces a compact, readable representation: HTML tables become
        pipe-delimited rows, links become "label (url)", and blank layout lines are dropped.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Html
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Html)) { return $Html }
        # If it doesn't look like HTML, return it untouched.
        if ($Html -notmatch '<[a-zA-Z!/]') { return $Html.Trim() }

        $text = $Html

        # Drop non-content blocks and comments (incl. Outlook/MSO conditional comments).
        $text = [regex]::Replace($text, '(?is)<head\b.*?</head>', '')
        $text = [regex]::Replace($text, '(?is)<style\b.*?</style>', '')
        $text = [regex]::Replace($text, '(?is)<script\b.*?</script>', '')
        $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')

        # Links: <a href="url">label</a> -> "label (url)", dropping empty/placeholder hosts.
        $text = [regex]::Replace($text, '(?is)<a\b[^>]*?href\s*=\s*["'']([^"'']*)["''][^>]*>(.*?)</a>', {
            param($m)
            $url = $m.Groups[1].Value.Trim()
            $label = ([regex]::Replace($m.Groups[2].Value, '(?s)<[^>]+>', '')).Trim()
            if ($url -and $url -match '^https?://[^/]') { "$label ($url)" } else { $label }
        })

        # Table cells -> pipe separators; list items -> dashes; block elements/rows -> newlines.
        $text = [regex]::Replace($text, '(?is)</t[dh]>\s*<t[dh][^>]*>', ' | ')
        $text = [regex]::Replace($text, '(?is)<li[^>]*>', '- ')
        $text = [regex]::Replace($text, '(?is)<(br|/p|/div|/h[1-6]|/li|/tr|/table)\s*/?>', "`n")

        # Strip all remaining tags, then decode entities (&amp; &#39; &nbsp; ...).
        $text = [regex]::Replace($text, '(?s)<[^>]+>', '')
        $text = [System.Net.WebUtility]::HtmlDecode($text)

        # Tidy whitespace: normalise newlines, collapse spaces, trim/clean each line, drop blanks.
        $text = $text -replace '\r\n?', "`n"
        $lines = foreach ($line in ($text -split "`n")) {
            $clean = ($line -replace '[ \t]+', ' ').Trim(([char[]]@(' ', "`t", '|'))).Trim()
            if ($clean) { $clean }
        }
        return ($lines -join "`n").Trim()
    }
}
