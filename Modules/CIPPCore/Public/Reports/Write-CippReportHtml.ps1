function Write-CippReportHtml {
    <#
    .SYNOPSIS
        Render a CIPP report model into a self-contained, branded HTML document.
    .DESCRIPTION
        Shared rendering engine for the Aspendora / CIPP report suite. Takes a report
        model (title, tenant, branding, executive-summary findings, and sections) and
        returns a single self-contained HTML string (inline CSS + JS: sortable and
        filterable tables, collapsible sections, print-friendly). Branding (logo + accent
        colour) is pulled from the CIPP BrandingSettings unless supplied on the model.

        Report model shape:
          @{
            Title        = 'Microsoft 365 Security Report'
            TenantName   = '3E NDT LLC'
            TenantDomain = '3endt.com'
            GeneratedDate= '11 July 2026'          # optional; defaults to today
            Logo         = 'data:image/png;base64,...'  # optional; else BrandingSettings
            Colour       = '#B71A28'                # optional; else BrandingSettings
            Findings     = @( @{ Title=''; Status='pass|warn|fail|info'; Detail='' } )
            Sections     = @( @{ Title=''; Status='pass|warn|fail|info'; Description='';
                                  Columns=@('A','B'); Rows=@(@('1','2')); Empty='...' }  # table
                               # or @{ Title=''; Status=''; Description=''; Html='<raw>' }
                            )
          }
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Report
    )

    # ---- branding: model overrides, else BrandingSettings, else defaults ----------
    $Logo = $Report.Logo
    $Colour = $Report.Colour
    if (-not $Logo -or -not $Colour) {
        try {
            $BrandingTable = Get-CIPPTable -TableName 'Config'
            $Branding = Get-CIPPAzDataTableEntity @BrandingTable -Filter "PartitionKey eq 'BrandingSettings' and RowKey eq 'BrandingSettings'"
            if (-not $Logo) { $Logo = $Branding.logo }
            if (-not $Colour) { $Colour = $Branding.colour }
        } catch { Write-Information "Report branding lookup skipped: $($_.Exception.Message)" }
    }
    if (-not $Colour) { $Colour = '#B71A28' }

    # ---- helpers ------------------------------------------------------------------
    function _enc($v) { [System.Net.WebUtility]::HtmlEncode([string]$v) }
    function _fmt($v) {
        if ($null -eq $v) { return '' }
        if ($v -is [bool]) { return $(if ($v) { 'Yes' } else { 'No' }) }
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
            $items = @($v)
            if ($items.Count -eq 0) { return '' }
            $scalars = $items | Where-Object { $_ -is [string] -or $_ -is [int] -or $_ -is [long] -or $_ -is [double] }
            if ($scalars.Count -eq $items.Count) {
                $s = ($items | Select-Object -First 6) -join ', '
                if ($items.Count -gt 6) { $s += " +$($items.Count - 6) more" }
                return $s
            }
            $labels = foreach ($x in ($items | Select-Object -First 6)) {
                if ($x -is [hashtable] -or $x.PSObject) { $x.displayName ?? $x.userPrincipalName ?? $x.Name ?? $x.id ?? 'item' } else { [string]$x }
            }
            $s = ($labels) -join ', '
            if ($items.Count -gt 6) { $s += " +$($items.Count - 6) more" }
            return $s
        }
        $s = [string]$v
        if ($s -match '^(\d{4}-\d{2}-\d{2})T[\d:]') { return $Matches[1] }
        return $s
    }
    function _slug($s) { (($s -replace '[^a-zA-Z0-9]+', '-').Trim('-')).ToLower() }

    $statusPill = @{
        pass = @{ cls = 'p-ok'; label = 'Good'; dot = 'd-ok'; badge = 'b-ok'; sym = [char]0x2713 }
        warn = @{ cls = 'p-warn'; label = 'Review'; dot = 'd-warn'; badge = 'b-warn'; sym = '!' }
        fail = @{ cls = 'p-bad'; label = 'Action'; dot = 'd-bad'; badge = 'b-bad'; sym = [char]0x2717 }
        info = @{ cls = 'p-info'; label = 'Info'; dot = 'd-info'; badge = 'b-info'; sym = 'i' }
    }
    function _st($s) { if ($statusPill.ContainsKey([string]$s)) { [string]$s } else { 'info' } }

    $GeneratedDate = if ($Report.GeneratedDate) { $Report.GeneratedDate } else { (Get-Date).ToString('dd MMMM yyyy') }
    $TenantName = if ($Report.TenantName) { $Report.TenantName } else { $Report.TenantDomain }

    # ---- table builder ------------------------------------------------------------
    function _table($cols, $rows, $empty) {
        if (-not $empty) { $empty = 'No records found.' }
        # Build rows without PowerShell array-flattening: each $r is one row (array of cells).
        $trs = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $rows) {
            foreach ($r in $rows) {
                $cells = @($r)
                $tds = ($cells | ForEach-Object { "<td>$(_enc (_fmt $_))</td>" }) -join ''
                $trs.Add("<tr>$tds</tr>")
            }
        }
        if ($trs.Count -eq 0) { return "<p class='empty'>$(_enc $empty)</p>" }
        $thead = ($cols | ForEach-Object { "<th>$(_enc $_)</th>" }) -join ''
        "<div class='tablewrap'><input class='tfilter' placeholder='Filter $($trs.Count) rows&#8230;'>" +
        "<table class='dt'><thead><tr>$thead</tr></thead><tbody>$($trs -join '')</tbody></table></div>"
    }

    # ---- executive summary --------------------------------------------------------
    $order = @{ fail = 0; warn = 1; pass = 2; info = 3 }
    $cards = @($Report.Findings) | Where-Object { $_ } | Sort-Object { $order[(_st $_.Status)] }
    $fhtml = foreach ($f in $cards) {
        $m = $statusPill[(_st $f.Status)]
        "<div class='card fcard $($m.dot -replace 'd-','')'><div class='fbadge $($m.badge)'>$($m.sym)</div>" +
        "<div><div class='t'>$(_enc $f.Title)</div><div class='d'>$(_enc $f.Detail)</div></div></div>"
    }

    # ---- executive risk score / grade (from findings) -----------------------------
    $sList = @($cards | ForEach-Object { _st $_.Status })
    $failN = @($sList | Where-Object { $_ -eq 'fail' }).Count
    $warnN = @($sList | Where-Object { $_ -eq 'warn' }).Count
    $passN = @($sList | Where-Object { $_ -eq 'pass' }).Count
    $heroHtml = ''
    if (($failN + $warnN + $passN) -gt 0) {
        $score = [math]::Max(0, 100 - ($failN * 15) - ($warnN * 5))
        $grade = if ($score -ge 90) { 'A' } elseif ($score -ge 80) { 'B' } elseif ($score -ge 70) { 'C' } elseif ($score -ge 60) { 'D' } else { 'F' }
        $band = if ($score -ge 80) { 'ok' } elseif ($score -ge 60) { 'warn' } else { 'bad' }
        $heroHtml = "<div class='hero hero-$band'><div class='hero-ring'><div class='hero-grade'>$grade</div>" +
        "<div class='hero-score'>$score<span>/100</span></div></div>" +
        "<div class='hero-txt'><div class='hero-h'>Security posture</div>" +
        "<div class='hero-sub'><span class='hs-bad'>$failN action</span> &#183; <span class='hs-warn'>$warnN to review</span> &#183; <span class='hs-ok'>$passN passing</span></div>" +
        "<div class='hero-note'>Weighted from this report's checks; higher is better.</div></div></div>"
    }

    # ---- toc + sections -----------------------------------------------------------
    $toc = @('<h3>Sections</h3>')
    $sec = @()
    foreach ($s in @($Report.Sections)) {
        if (-not $s) { continue }
        $st = _st $s.Status
        $m = $statusPill[$st]
        $sid = _slug $s.Title
        $toc += "<a href='#$sid'><span class='dotpill $($m.dot)'></span>$(_enc $s.Title)</a>"
        $body = if ($s.Html) { $s.Html } else { _table $s.Columns $s.Rows $s.Empty }
        $sec += "<section class='rep' id='$sid'><div class='head'><div style='flex:1'>" +
        "<h2>$(_enc $s.Title)</h2><div class='desc'>$(_enc $s.Description)</div></div>" +
        "<span class='pill $($m.cls)'>$($m.label)</span><span class='chev'>&#9662;</span></div>" +
        "<div class='body'>$body</div></section>"
    }

    # ---- brand header block -------------------------------------------------------
    $brandHtml = if ($Logo) {
        "<img class='logo-img' src='$Logo' alt='logo'>"
    } else {
        "<div class='logo-txt'>ASPEND<span style='color:$Colour'>O</span>RA</div><div class='tag'>Technologies</div>"
    }

    $css = @"
:root{--brand:$Colour;--ink:#1b1b1d;--ink2:#3a3d42;--mut:#6b7480;--line:#e4e7ec;--bg:#f4f6f9;--card:#fff;
--ok:#1e8e3e;--warn:#c9820a;--bad:#c5221f;--info:#2f6db0;}
*{box-sizing:border-box}
body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--bg);-webkit-font-smoothing:antialiased}
.wrap{max-width:1200px;margin:0 auto;padding:0 20px}
header.top{background:#fff;border-bottom:4px solid var(--brand)}
.top .wrap{display:flex;align-items:center;justify-content:space-between;gap:20px;flex-wrap:wrap;padding:20px}
.logo-img{height:52px;width:auto;display:block}
.logo-txt{font-weight:800;font-size:26px;letter-spacing:.5px;color:var(--ink);line-height:1}
.tag{font-size:11px;letter-spacing:3px;text-transform:uppercase;color:var(--mut)}
.rtitle{text-align:right}
.rtitle h1{margin:0;font-size:19px;font-weight:700;color:var(--ink)}
.rtitle .meta{color:var(--mut);font-size:12.5px;margin-top:3px}
main{padding:24px 0 60px}
.layout{display:grid;grid-template-columns:230px minmax(0,1fr);gap:26px;align-items:start}
.layout>*{min-width:0}
nav.toc{position:sticky;top:16px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;max-height:calc(100vh - 32px);overflow:auto}
nav.toc h3{margin:4px 6px 8px;font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--mut)}
nav.toc a{display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:6px;color:var(--ink);font-size:12.5px;text-decoration:none}
nav.toc a:hover{background:var(--bg)}
.dotpill{width:8px;height:8px;border-radius:50%;flex:0 0 auto}
.d-ok{background:var(--ok)}.d-warn{background:var(--warn)}.d-bad{background:var(--bad)}.d-info{background:#9db3c8}
.hero{display:flex;align-items:center;gap:22px;background:var(--card);border:1px solid var(--line);border-left:6px solid var(--info);border-radius:12px;padding:18px 22px;margin:0 0 16px}
.hero-ok{border-left-color:var(--ok)}.hero-warn{border-left-color:var(--warn)}.hero-bad{border-left-color:var(--bad)}
.hero-ring{width:96px;height:96px;border-radius:50%;display:flex;flex-direction:column;align-items:center;justify-content:center;flex:0 0 auto;color:#fff;line-height:1}
.hero-ok .hero-ring{background:var(--ok)}.hero-warn .hero-ring{background:var(--warn)}.hero-bad .hero-ring{background:var(--bad)}
.hero-grade{font-size:34px;font-weight:800}
.hero-score{font-size:13px;font-weight:600;opacity:.92}.hero-score span{opacity:.7}
.hero-h{font-size:18px;font-weight:700;color:var(--ink)}
.hero-sub{margin-top:4px;font-size:13px;color:var(--ink2)}
.hs-bad{color:var(--bad);font-weight:600}.hs-warn{color:var(--warn);font-weight:600}.hs-ok{color:var(--ok);font-weight:600}
.hero-note{margin-top:4px;font-size:11.5px;color:var(--mut)}
.summary{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:12px;margin:0 0 22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.fcard{display:flex;gap:12px;align-items:flex-start;border-left:4px solid var(--info)}
.fcard.ok{border-left-color:var(--ok)}.fcard.warn{border-left-color:var(--warn)}.fcard.bad{border-left-color:var(--bad)}
.fbadge{width:26px;height:26px;border-radius:50%;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:700;flex:0 0 auto;font-size:14px}
.b-ok{background:var(--ok)}.b-warn{background:var(--warn)}.b-bad{background:var(--bad)}.b-info{background:var(--info)}
.fcard .t{font-weight:600;font-size:13px}
.fcard .d{color:var(--mut);font-size:12.5px;margin-top:2px}
section.rep{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:0 0 16px;overflow:hidden;scroll-margin-top:16px}
section.rep>.head{display:flex;align-items:center;gap:12px;padding:14px 18px;cursor:pointer;user-select:none}
section.rep>.head:hover{background:#fafbfc}
section.rep h2{margin:0;font-size:15.5px;font-weight:600;flex:1;color:var(--ink)}
section.rep .desc{color:var(--mut);font-weight:400;font-size:12.5px;margin-top:2px}
.pill{font-size:11px;font-weight:700;padding:3px 9px;border-radius:20px;text-transform:uppercase;letter-spacing:.4px}
.p-ok{background:#e6f4ea;color:var(--ok)}.p-warn{background:#fbefd6;color:#96650a}.p-bad{background:#fce8e6;color:var(--bad)}.p-info{background:#eaf1f8;color:var(--info)}
.chev{color:var(--mut);transition:transform .15s}
section.collapsed .chev{transform:rotate(-90deg)}
section.collapsed>.body{display:none}
.body{padding:0 18px 18px}
.tablewrap{overflow-x:auto}
.tfilter{width:100%;max-width:320px;margin:2px 0 10px;padding:7px 10px;border:1px solid var(--line);border-radius:7px;font-size:13px}
table.dt{border-collapse:collapse;width:100%;font-size:12.5px}
table.dt th{background:var(--ink);color:#fff;text-align:left;padding:8px 10px;position:sticky;top:0;cursor:pointer;white-space:nowrap;font-weight:600}
table.dt th:hover{background:#000}
table.dt td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top;font-variant-numeric:tabular-nums}
table.dt tbody tr:nth-child(even){background:#fafbfc}
table.dt tbody tr:hover{background:#f6eef0}
.empty{color:var(--mut);font-style:italic;padding:8px 0}
footer{color:var(--mut);font-size:12px;text-align:center;padding:24px 0;border-top:1px solid var(--line)}
@media(max-width:900px){.layout{grid-template-columns:1fr}nav.toc{position:static;max-height:none}}
@media print{body{background:#fff}nav.toc,.tfilter{display:none}section.rep{break-inside:avoid;border:1px solid #ccc}section.collapsed>.body{display:block}header.top{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
"@

    $js = @'
document.querySelectorAll('section.rep>.head').forEach(h=>h.addEventListener('click',()=>h.parentElement.classList.toggle('collapsed')));
document.querySelectorAll('.tfilter').forEach(inp=>inp.addEventListener('input',e=>{var q=e.target.value.toLowerCase(),tb=inp.parentElement.querySelector('tbody');tb.querySelectorAll('tr').forEach(tr=>{tr.style.display=tr.textContent.toLowerCase().includes(q)?'':'none';});}));
document.querySelectorAll('table.dt th').forEach((th,i)=>th.addEventListener('click',()=>{var tb=th.closest('table').querySelector('tbody'),rows=[].slice.call(tb.querySelectorAll('tr'));var asc=th.dataset.asc!=='1';th.dataset.asc=asc?'1':'0';rows.sort(function(a,b){var x=a.children[i].textContent.trim(),y=b.children[i].textContent.trim();var nx=parseFloat(x.replace(/[^0-9.-]/g,'')),ny=parseFloat(y.replace(/[^0-9.-]/g,''));if(!isNaN(nx)&&!isNaN(ny))return asc?nx-ny:ny-nx;return asc?x.localeCompare(y):y.localeCompare(x);});rows.forEach(function(r){tb.appendChild(r);});}));
'@

    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(_enc $Report.Title) &#8212; $(_enc $TenantName)</title><style>$css</style></head><body>
<header class="top"><div class="wrap">
  <div class="brand">$brandHtml</div>
  <div class="rtitle"><h1>$(_enc $Report.Title)</h1>
  <div class="meta">$(_enc $TenantName) &#183; $(_enc $Report.TenantDomain) &#183; $(_enc $GeneratedDate)</div></div>
</div></header>
<main><div class="wrap"><div class="layout">
<nav class="toc">$($toc -join '')</nav>
<div>$heroHtml<div class="summary">$($fhtml -join '')</div>$($sec -join '')</div>
</div></div></main>
<footer>Generated by Aspendora Technologies from live Microsoft 365 data via CIPP &#183; $(_enc $GeneratedDate)<br>
Confidential &#8212; prepared for $(_enc $TenantName).</footer>
<script>$js</script></body></html>
"@
    return $html
}
