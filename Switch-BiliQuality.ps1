#Requires -Version 5.1
<#
.SYNOPSIS
  独立命令行入口：从 runtime/play-state.json 读取当前播放，弹出画质选择并切流。
  日常使用请通过 Open-EdgeWeb.ps1 主窗口的「换画质」按钮（已内联，无子进程开销）。
#>
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
. $FormatsScript
Set-BiliDiagLogPath $RuntimeDir
Write-BiliDiagSession -ScriptName 'Switch-BiliQuality'
if (-not $YtdlpCookiesFile) {
    $auto = Join-Path $RuntimeDir 'bilibili-cookies.txt'
    if (Test-Path -LiteralPath $auto) { $YtdlpCookiesFile = $auto }
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Test-Path -LiteralPath $StateFile)) {
    Show-BiliUserError -Title '换画质' -Summary '当前没有在播放的视频。' -Details @(
        '请先点击视频，等 mpv 开始播放后再调用本脚本。'
        "状态文件不存在：$StateFile"
    )
    exit 0
}

$url = ''
$pipeName = ''
try {
    $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $url = [string]$state.url
    $pipeName = [string]$state.pipeName
    $isLive = [bool]$state.isLive
    Write-BiliDiag -Category 'QUALITY' -Message ("URL={0} pipe={1} live={2}" -f $url, $pipeName, $isLive)
    if ([string]::IsNullOrWhiteSpace($url)) { throw '无法确定当前播放链接。' }

    $ytdlp = Find-YtdlpExe -Override $YtdlpPath
    if (-not $ytdlp) { throw '未找到 yt-dlp。请运行：winget install yt-dlp.yt-dlp' }

    $formatSpec = $Format
    if ([string]::IsNullOrWhiteSpace($formatSpec)) {
        $busy = $null
        try {
            $busy = Show-BiliBusyForm -Message '正在获取画质列表…' -Title '换画质'
            $formatSpec = Select-BilibiliFormat -YtdlpExe $ytdlp -MediaUrl $url -IsLive:$isLive `
                -Referer $url -UserAgent $YtdlpUserAgent `
                -CookieBrowser $YtdlpCookieBrowser -CookiesFile $YtdlpCookiesFile -RuntimeDir $RuntimeDir
        } finally { Close-BiliBusyForm $busy }
        if (-not $formatSpec) { exit 0 }
    }

    $streams = Resolve-StreamUrls -YtdlpExe $ytdlp -MediaUrl $url -FormatSpec $formatSpec `
        -Referer $url -UserAgent $YtdlpUserAgent `
        -CookieBrowser $YtdlpCookieBrowser -CookiesFile $YtdlpCookiesFile -RuntimeDir $RuntimeDir
    Switch-MpvStreamQuality -PipeName $pipeName -StreamUrls $streams -Referrer $url -IsLive:$isLive
    Write-BiliDiag -Category 'QUALITY' -Message 'Switch OK'
} catch {
    Write-BiliDiagException -Category 'QUALITY' -Context 'Quality switch failed' -ErrorRecord $_ -Script 'Switch-BiliQuality'
    Show-BiliUserError -Title '换画质失败' -Summary $_.Exception.Message -Details @(
        "视频链接：$url"
        "mpv 管道：$pipeName"
        '若提示无法连接 mpv，请确认 mpv 窗口仍在播放。'
    )
    exit 1
}
