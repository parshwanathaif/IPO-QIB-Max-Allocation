# Fetch "Maximum Bid Quantity for QIB" for current IPOs from NSE and publish exchange.json.
# NSE refuses requests from cloud servers (GitHub Actions gets 403), so this runs on your own PC.
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\fetch_exchange.ps1 [-NoPush]
param([switch]$NoPush)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Norm([string]$name) {
    # first two significant words, same rule as normName() in index.html
    $s = $name.ToLower() -replace '\b(limited|ltd|the|and|india)\b|&|[^a-z0-9 ]', ' '
    (($s -split '\s+' | Where-Object { $_ }) | Select-Object -First 2) -join ' '
}
function Shares([string]$v) { [int64](([regex]::Match(($v -replace ',', ''), '\d+')).Value) }

$items = @(); $status = [ordered]@{}

# ---- NSE ----
try {
    $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest 'https://www.nseindia.com/market-data/all-upcoming-issues-ipo' -WebSession $s -UserAgent $ua -UseBasicParsing | Out-Null
    $h = @{ Referer = 'https://www.nseindia.com/market-data/all-upcoming-issues-ipo'; Accept = 'application/json' }
    # current issues plus NSE's upcoming lists (mainboard and SME), one entry per symbol
    $cur = @()
    foreach ($u in 'ipo-current-issue', 'all-upcoming-issues?category=ipo', 'all-upcoming-issues?category=sme') {
        try { $r = Invoke-RestMethod "https://www.nseindia.com/api/$u" -WebSession $s -UserAgent $ua -Headers $h; if ($r -is [array]) { $cur += $r } } catch {}
    }
    $cur = $cur | Where-Object { $_.symbol } | Sort-Object symbol -Unique
    foreach ($it in $cur) {
        if (-not $it.symbol) { continue }
        $ser = if ($it.series) { $it.series } else { 'EQ' }
        try { $d = Invoke-RestMethod "https://www.nseindia.com/api/ipo-detail?symbol=$([uri]::EscapeDataString($it.symbol))&series=$ser" -WebSession $s -UserAgent $ua -Headers $h } catch { continue }
        $row = $d.issueInfo.dataList | Where-Object { $_.title -match 'Maximum Bid Quantity for QIB' } | Select-Object -First 1
        if ($row) {
            $items += [ordered]@{ key = Norm $it.companyName; name = $it.companyName; exchange = 'NSE'; symbol = $it.symbol; maxQibSh = Shares $row.value }
        }
        Start-Sleep -Milliseconds 700
    }
    $status.nse = 'ok'
} catch { $status.nse = "$($_.Exception.Message)" }

# BSE's API refuses scripted requests (403), so BSE-only issues use the ipopremium figure from gmp.json.

"NSE: $($status.nse)  items: $($items.Count)"
$items | ForEach-Object { "{0,-4} {1,-45} {2,12:N0}" -f $_.exchange, $_.name, $_.maxQibSh }

# rewrite (and publish) only when the figures changed, so the repo doesn't fill with timestamp-only commits
$path = Join-Path $root 'exchange.json'
$sig = { param($list) ($list | ForEach-Object { "$($_.key)=$($_.maxQibSh)" } | Sort-Object) -join ';' }
$old = if (Test-Path $path) { @((Get-Content $path -Raw | ConvertFrom-Json).items) } else { @() }
# keep figures for issues NSE no longer lists (closed / listed) so the app never falls back to the estimate
$items = @($items) + @($old | Where-Object { $k = $_.key; -not ($items | Where-Object { $_.key -eq $k }) } |
    ForEach-Object { [ordered]@{ key = $_.key; name = $_.name; exchange = $_.exchange; symbol = $_.symbol; maxQibSh = $_.maxQibSh } } | Select-Object -First 60)
$changed = $items.Count -and ((& $sig $items) -ne (& $sig $old))
if ($changed) {
    $out = [ordered]@{ updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00'); status = $status; items = $items }
    $json = ($out | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
} else { 'No change in NSE figures.' }

$ErrorActionPreference = 'Continue'  # git writes progress/warnings to stderr; don't treat them as failures
if (-not $NoPush -and $changed) {
    $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    Push-Location $root
    try {
        & $git add exchange.json
        & $git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) { & $git commit -q -m "Update NSE max QIB bid" }
        & $git pull -q --rebase origin main
        & $git push -q
    } finally { Pop-Location }
}
