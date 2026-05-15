function Get-ITGlueFormattedField ($Title, $Value) {
    return @"
<tr><th style="text-align:left;padding:4px 8px;background:#f5f5f5;width:35%;">$Title</th><td style="padding:4px 8px;">$Value</td></tr>
"@
}
