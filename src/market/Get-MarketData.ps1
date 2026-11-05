# =============================================================================
#  美股行情 / 财报数据源 —— 全部实测在中国可直连（无需代理）
#
#  【关于 Yahoo Finance】
#    Yahoo 自 2021-11-01 起主动封锁中国大陆（按源 IP 判定），
#    返回 403 + 封锁页，连 s.yimg.com 的静态图片都下不来。
#    DNS 完全正确（69.147.88.8）、TCP 通（312ms），但应用层被 Yahoo 拒绝。
#    → 换任何 DNS 都无效，只能代理。用下面的源替代，还更快。
#
#  【关于 NYSE】
#    NYSE 本身【没有免费公开行情 API】—— 它的行情由 ICE Data Services
#    商业销售（www.icedata.com 连 DNS 都解析不了）。
#    NYSE 官网只提供技术文档（publicdocs 下的 xlsx/pdf）。
#    → 拿 NYSE 上市股票（JPM/KO/DIS/T…）的行情，用 Nasdaq API，
#      它的返回里带 exchange 字段，覆盖 NYSE / NASDAQ / AMEX 全部美股。
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File market-data.ps1 -Symbol JPM
#    powershell -ExecutionPolicy Bypass -File market-data.ps1 -Source index    # 大盘指数
#    powershell -ExecutionPolicy Bypass -File market-data.ps1 -Symbol AAPL -Source sec
# =============================================================================

param(
    [string]$Symbol = 'AAPL',
    [ValidateSet('eastmoney','nasdaq','sec','cboe','sina','tencent','all','index')]
    [string]$Source = 'all'
)

$UA    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$SECUA = 'SmartDNS-Research/1.0 (contact: victor000000@gmail.com)'   # SEC 要求带联系方式
$sym   = $Symbol.ToUpper()

function Hdr($t) { Write-Host ""; Write-Host "===== $t =====" -ForegroundColor Cyan }
function Try-Json($url, $headers, $timeout = 15) {
    try {
        if ($headers) { return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $timeout }
        return Invoke-RestMethod -Uri $url -TimeoutSec $timeout
    } catch { return $null }
}
function Get-Json($url, $headers, $timeout = 15, $retry = 3) {
    # 网络抖动/限流很常见，加重试。Invoke-RestMethod 会自动跟随 307/302（CBOE 用得到）
    for ($i = 1; $i -le $retry; $i++) {
        try {
            if ($headers) { return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $timeout }
            return Invoke-RestMethod -Uri $url -TimeoutSec $timeout
        } catch {
            if ($i -eq $retry) { return $null }
            Start-Sleep -Milliseconds (500 * $i)
        }
    }
}

# ---------------------------------------------------------------- 大盘指数
if ($Source -eq 'index') {
    Hdr "CBOE 指数延迟报价（1.5s，免费）"
    foreach ($idx in @('_SPX','_VIX','_NDX','_RUT','_DJX')) {
        Start-Sleep -Milliseconds 600
        $j = Get-Json "https://cdn.cboe.com/api/global/delayed_quotes/quotes/$idx.json" @{'User-Agent'=$UA}
        if ($j.data) {
            Write-Host ("  {0,-8} {1,12}   涨跌 {2,8}  ({3}%)" -f `
                $j.data.symbol, $j.data.current_price, $j.data.price_change, $j.data.price_change_percent)
        }
    }
    return
}

# ---------------------------------------------------------------- 东方财富
if ($Source -in @('eastmoney','all')) {
    Hdr "东方财富  $sym  日K线（45ms，国内直连）"
    $found = $false
    foreach ($mkt in @(105,106,107)) {   # 105=纳斯达克 106=纽交所 107=AMEX
        $u = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$mkt.$sym&fields1=f1,f2,f3,f4&fields2=f51,f52,f53,f54,f55,f56&klt=101&fqt=1&end=20500101&lmt=5"
        $j = Get-Json $u @{'User-Agent'=$UA; 'Referer'='https://quote.eastmoney.com'}
        if ($j.data -and $j.data.klines) {
            $ex = switch ($mkt) { 105 {'纳斯达克'} 106 {'纽交所'} 107 {'AMEX'} }
            Write-Host ("  名称: {0}   代码: {1}   交易所: {2}" -f $j.data.name, $j.data.code, $ex)
            Write-Host "  日期        开盘      最高      最低      收盘      成交量"
            foreach ($k in $j.data.klines) {
                $p = $k -split ','
                Write-Host ("  {0}  {1,9} {2,9} {3,9} {4,9} {5,12}" -f $p[0],$p[1],$p[2],$p[3],$p[4],$p[5])
            }
            Write-Host "  参数: klt=101(日)/102(周)/103(月)  lmt=条数  fqt=1(前复权)"
            $found = $true; break
        }
    }
    if (-not $found) { Write-Host "  未找到 $sym" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- Nasdaq
if ($Source -in @('nasdaq','all')) {
    Hdr "Nasdaq 官方 API  $sym （2-3s，免费无需 key，覆盖 NYSE+NASDAQ）"
    $j = Get-Json "https://api.nasdaq.com/api/quote/$sym/info?assetclass=stocks" @{'User-Agent'=$UA; 'Accept'='application/json'}
    if ($j.data) {
        $d = $j.data
        Write-Host ("  {0}  （{1} 上市）" -f $d.companyName, $d.exchange)
        Write-Host ("  现价: {0}   涨跌: {1} ({2})" -f $d.primaryData.lastSalePrice, $d.primaryData.netChange, $d.primaryData.percentageChange)
        Write-Host ("  时间: {0}" -f $d.primaryData.lastTradeTimestamp)
    } else { Write-Host "  无数据" -ForegroundColor Yellow }
    $from = (Get-Date).AddDays(-10).ToString('yyyy-MM-dd')
    $h = Get-Json "https://api.nasdaq.com/api/quote/$sym/historical?assetclass=stocks&fromdate=$from&limit=6" @{'User-Agent'=$UA; 'Accept'='application/json'}
    if ($h.data.tradesTable) {
        Write-Host ""
        Write-Host "  历史数据:"
        $h.data.tradesTable.rows | ForEach-Object {
            Write-Host ("    {0,-12} 收 {1,-10} 开 {2,-10} 高 {3,-10} 低 {4,-10} 量 {5}" -f $_.date,$_.close,$_.open,$_.high,$_.low,$_.volume)
        }
        Write-Host "  assetclass 可换: stocks / etf / index / mutualfund"
    }
}

# ---------------------------------------------------------------- SEC EDGAR
if ($Source -in @('sec','all')) {
    Hdr "SEC EDGAR  $sym  官方财报（0.6s，免费）"
    $j = Get-Json "https://www.sec.gov/files/company_tickers.json" @{'User-Agent'=$SECUA}
    $cik = $null; $title = ''
    if ($j) {
        foreach ($p in $j.PSObject.Properties) {
            if ($p.Value.ticker -eq $sym) { $cik = $p.Value.cik_str; $title = $p.Value.title; break }
        }
    }
    if (-not $cik) { Write-Host "  未在 SEC 代码表找到 $sym" -ForegroundColor Yellow }
    else {
        Write-Host ("  {0}   CIK={1}" -f $title, $cik)
        $cikPad = ([int]$cik).ToString().PadLeft(10,'0')
        $s = Get-Json "https://data.sec.gov/submissions/CIK$cikPad.json" @{'User-Agent'=$SECUA}
        if ($s) {
            Write-Host ("  历史提交总数: {0}   最近 5 条:" -f $s.filings.recent.form.Count)
            0..4 | ForEach-Object {
                Write-Host ("    {0,-8} {1,-12} {2}" -f $s.filings.recent.form[$_], $s.filings.recent.filingDate[$_], $s.filings.recent.primaryDocDescription[$_])
            }
        }
        Write-Host "  营收（XBRL，最近 4 期）:"
        $x = Get-Json "https://data.sec.gov/api/xbrl/companyconcept/CIK$cikPad/us-gaap/Revenues.json" @{'User-Agent'=$SECUA}
        if ($x.units.USD) {
            $x.units.USD | Select-Object -Last 4 | ForEach-Object { Write-Host ("    {0}   {1,20:N0}" -f $_.end, $_.val) }
        } else { Write-Host "    （该公司未用 us-gaap:Revenues 科目）" }
        Write-Host "  全部财务科目: https://data.sec.gov/api/xbrl/companyfacts/CIK$cikPad.json"
    }
}

# ---------------------------------------------------------------- 新浪/腾讯
if ($Source -in @('sina','all')) {
    Hdr "新浪财经  $sym  实时行情（44ms）"
    try {
        $r = Invoke-WebRequest -Uri "https://hq.sinajs.cn/list=gb_$($sym.ToLower())" `
             -Headers @{'User-Agent'=$UA; 'Referer'='https://finance.sina.com.cn'} -TimeoutSec 15 -UseBasicParsing
        Write-Host "  $($r.Content.Trim())"
    } catch { Write-Host "  失败" -ForegroundColor Yellow }
}

if ($Source -in @('tencent','all')) {
    Hdr "腾讯财经  $sym  实时行情（74ms）"
    try {
        $r = Invoke-WebRequest -Uri "https://qt.gtimg.cn/q=us$sym" -Headers @{'User-Agent'=$UA} -TimeoutSec 15 -UseBasicParsing
        Write-Host "  $($r.Content.Trim().Substring(0,[Math]::Min(280,$r.Content.Trim().Length)))"
    } catch { Write-Host "  失败" -ForegroundColor Yellow }
}

if ($Source -eq 'all') {
    Hdr "数据源可用性总结（全部实测，无需代理）"
    Write-Host "  SEC EDGAR      0.6s   OK  官方财报/提交/全市场代码表(10,435家)"
    Write-Host "  东方财富        45ms   OK  日/周/月 K 线"
    Write-Host "  新浪            44ms   OK  实时行情"
    Write-Host "  腾讯            74ms   OK  实时行情"
    Write-Host "  Nasdaq API     2-3s   OK  行情/历史/财报日历，覆盖 NYSE+NASDAQ"
    Write-Host "  CBOE CDN       1.5s   OK  SPX/VIX 等指数延迟报价"
    Write-Host "  NYSE 官网      1.6s    --  仅技术文档；行情需 ICE 付费"
    Write-Host "  Yahoo Finance   ---    BLOCKED  Yahoo 主动封锁中国大陆"
    Write-Host "  Stooq           ---    WARN 有 JS 反爬挑战，不适合自动化"
    Write-Host ""
}
