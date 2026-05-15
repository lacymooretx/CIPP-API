function Get-ITGlueFormattedBlock ($Heading, $Body) {
    return @"
<h3 style="margin-top:16px;border-bottom:1px solid #ddd;padding-bottom:4px;">$Heading</h3>
<table style="width:100%;border-collapse:collapse;">$Body</table>
"@
}
