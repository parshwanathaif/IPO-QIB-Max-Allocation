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
    $cur = Invoke-RestMethod 'https://www.nseindia.com/api/ipo-current-issue' -WebSession $s -UserAgent $ua -Headers $h
    foreach ($it in $cur) {
        if (-not $it.symbol) { continue }
        $d = Invoke-RestMethod "https://www.nseindia.com/api/ipo-detail?symbol=$([uri]::EscapeDataString($it.symbol))&series=$($it.series)" -WebSession $s -UserAgent $ua -Headers $h
        $row = $d.issueInfo.dataList | Where-Object { $_.title -match 'Maximum Bid Quantity for QIB' } | Select-Object -First 1
        if ($row) {
            $items += [ordered]@{ key = Norm $it.companyName; name = $it.companyName; exchange = 'NSE'; symbol = $it.symbol; maxQibSh = Shares $row.value }
        }
        Start-Sleep -Milliseconds 700
    }
    $status.nse = 'ok'
} catch { $status.nse = "$($_.Exception.Message)" }

# BSE's API refuses scripted requests (403), so BSE-only issues use the ipopremium figure from gmp.json.

$out = [ordered]@{ updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss+00:00'); status = $status; items = $items }
$json = $out | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $root 'exchange.json'), $json, (New-Object Text.UTF8Encoding $false))
"NSE: $($status.nse)  items: $($items.Count)"
$items | ForEach-Object { "{0,-4} {1,-45} {2,12:N0}" -f $_.exchange, $_.name, $_.maxQibSh }

if (-not $NoPush -and $items.Count) {
    $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    Push-Location $root
    try {
        & $git pull -q --rebase origin main
        & $git add exchange.json
        & $git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) { & $git commit -q -m "Update NSE/BSE max QIB bid"; & $git push -q }
    } finally { Pop-Location }
}
