#Requires -Version 5.1
param([string]$Format = '')

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$RuntimeDir = Join-Path $Root 'runtime'
$StateFile = Join-Path $RuntimeDir 'play-state.json'
$ConfigPath = Join-Path $Root 'config.ps1'
$FormatsScript = Join-Path $Root 'Bilibili-Formats.ps1'

$YtdlpPath = $null
$YtdlpCookiesFile = $null
$YtdlpCookieBrowser = $null
$YtdlpUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'

if (Test-Path $ConfigPath) { . $ConfigPath }
if (Test-Path -LiteralPath $FormatsScript) { . $FormatsScript }
Set-BiliDiagLogPath $RuntimeDir
Write-BiliDiagSession -ScriptName 'Switch-BiliQuality'
if (-not $YtdlpCookiesFile) {
    $auto = Join-Path $RuntimeDir 'bilibili-cookies.txt'
    if (Test-Path -LiteralPath $auto) { $YtdlpCookiesFile = $auto }
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

function Find-Ytdlp {
    if ($YtdlpPath -and (Test-Path -LiteralPath $YtdlpPath)) { return $YtdlpPath }
    $cmd = Get-Command yt-dlp -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

if (-not (Test-Path -LiteralPath $StateFile)) {
    Write-BiliDiag -Category 'QUALITY' -Message 'Aborted: no play-state.json'
    Show-BiliUserError -Title '换画质' -Summary '当前没有在播放的视频。' -Details @(
        '请先点击一个视频链接，等 mpv 开始播放后再点「换画质」。'
        "状态文件不存在：$StateFile"
    )
    exit 0
}

try {
    $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $url = [string]$state.url
    $pipeName = [string]$state.pipeName
    $isLive = [bool]$state.isLive
    Write-BiliDiag -Category 'QUALITY' -Message ("URL={0} pipe={1} live={2}" -f $url, $pipeName, $isLive)

    if ([string]::IsNullOrWhiteSpace($url)) { throw '无法确定当前播放链接。' }

    $ytdlp = Find-Ytdlp
    if (-not $ytdlp) {
        throw '未找到 yt-dlp。请运行：winget install yt-dlp.yt-dlp'
    }

    $cookiePath = Resolve-YtdlpCookiesFile -CookiesFile $YtdlpCookiesFile -RuntimeDir $RuntimeDir
    Write-BiliDiag -Category 'QUALITY' -Message (
        'Cookie file={0} browser={1}' -f $(if ($cookiePath) { $cookiePath } else { '(none)' }), $(if ($YtdlpCookieBrowser) { $YtdlpCookieBrowser } else { '(none)' })
    )

    $formatSpec = $Format
    if ([string]::IsNullOrWhiteSpace($formatSpec)) {
        $busy = $null
        try {
            Write-BiliDiag -Category 'QUALITY' -Message 'Fetching formats via yt-dlp...'
            $busy = Show-BiliBusyForm -Message '正在获取画质列表，请稍候…（约 10–30 秒）' -Title '换画质'
            $formatSpec = Select-BilibiliFormat -YtdlpExe $ytdlp -MediaUrl $url -IsLive:$isLive `
                -Referer $url -UserAgent $YtdlpUserAgent `
                -CookieBrowser $YtdlpCookieBrowser -CookiesFile $YtdlpCookiesFile -RuntimeDir $RuntimeDir
        } finally {
            Close-BiliBusyForm $busy
        }
        if (-not $formatSpec) {
            Write-BiliDiag -Category 'QUALITY' -Message 'User cancelled quality picker'
            exit 0
        }
    }
    Write-BiliDiag -Category 'QUALITY' -Message "Format selected: $formatSpec"

    $streams = Resolve-StreamUrls -YtdlpExe $ytdlp -MediaUrl $url -FormatSpec $formatSpec `
        -Referer $url -UserAgent $YtdlpUserAgent `
        -CookieBrowser $YtdlpCookieBrowser -CookiesFile $YtdlpCookiesFile -RuntimeDir $RuntimeDir
    Write-BiliDiag -Category 'QUALITY' -Message ("Stream URLs resolved: {0}" -f $streams.Count)

    Switch-MpvStreamQuality -PipeName $pipeName -StreamUrls $streams -Referrer $url -IsLive:$isLive
    Write-BiliDiag -Category 'QUALITY' -Message 'Switch-MpvStreamQuality OK'
} catch {
    Write-BiliDiagException -Category 'QUALITY' -Context 'Quality switch failed' -ErrorRecord $_ -Script 'Switch-BiliQuality'
    Show-BiliUserError -Title '换画质失败' -Summary $_.Exception.Message -Details @(
        "视频链接：$url"
        "mpv 管道：$pipeName"
        '若提示无法连接 mpv，请确认 mpv 窗口仍在播放。'
        '若只有 480P，请查看 Cookie 导出是否成功（见日志）。'
    )
    exit 1
}
