#Requires -Version 5.1
<#
.SYNOPSIS
  B 站链接 → yt-dlp 取流（Cookie + Referer）→ mpv 直链播放。
  点击即播最高可用画质；播放中用 Switch-BiliQuality.ps1 通过 mpv IPC 换画质。
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,
    [string]$Format = ''
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$RuntimeDir = Join-Path $Root 'runtime'
$CacheRoot = Join-Path $RuntimeDir 'play-cache'
$LinkFile = Join-Path $RuntimeDir 'current-link.txt'
$PidFile = Join-Path $RuntimeDir 'play.pid'
$StateFile = Join-Path $RuntimeDir 'play-state.json'
$ConfigPath = Join-Path $Root 'config.ps1'
$FormatsScript = Join-Path $Root 'Bilibili-Formats.ps1'
$MpvPipeName = 'bili-play-ipc'

$YtdlpPath = $null
$MpvPath = $null
$FfmpegPath = $null
$YtdlpCookiesFile = $null
$YtdlpCookieBrowser = $null
$YtdlpUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'
$MpvCacheSecs = 300
$LiveCacheSecs = 20
$DefaultVodFormat = 'bestvideo+bestaudio/best'
$DefaultLiveFormat = 'best[ext=flv]/best/best'
$DanmakuSpeed = 10.0

if (Test-Path $ConfigPath) { . $ConfigPath }
if (Test-Path -LiteralPath $FormatsScript) { . $FormatsScript }
if (Get-Command Set-BiliDiagLogPath -ErrorAction SilentlyContinue) {
    Set-BiliDiagLogPath $RuntimeDir
    Write-BiliDiagSession -ScriptName 'Start-StreamPlay' -Meta @{ url = $Url }
}
if (-not $YtdlpCookiesFile) {
    $autoCookie = Join-Path $RuntimeDir 'bilibili-cookies.txt'
    if (Test-Path -LiteralPath $autoCookie) { $YtdlpCookiesFile = $autoCookie }
}

function Find-Executable {
    param([string]$Name, [string]$Override, [string[]]$Fallbacks = @())
    if ($Override -and (Test-Path -LiteralPath $Override)) {
        return (Resolve-Path -LiteralPath $Override).Path
    }
    foreach ($p in $Fallbacks) {
        if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-LiveUrl([string]$raw) {
    return ($raw -match 'live\.bilibili\.com/\d+' -or $raw -match 'bilibili\.com/blive/')
}

function Clear-PlayCacheDir([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-PlayCacheSession([string]$SessionDir) {
    if ([string]::IsNullOrWhiteSpace($SessionDir)) { return }
    Clear-PlayCacheDir $SessionDir
    Remove-Item -LiteralPath $SessionDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Stop-PreviousPlayer {
    if (Test-Path -LiteralPath $PidFile) {
        Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '^(\w+)=(\d+)$') {
                Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/F', '/T', '/PID', $Matches[2]) `
                    -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            } elseif ($_ -match '^\d+$') {
                Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/F', '/T', '/PID', $_) `
                    -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
            }
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    foreach ($playerName in @('mpvnet', 'mpv')) {
        Get-Process -Name $playerName -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
}

function Write-PlayState {
    param(
        [string]$MediaUrl,
        [bool]$IsLive,
        [int]$PlayerPid,
        [string]$RoomId = '',
        [bool]$DanmakuEnabled = $false
    )
    $state = @{
        url            = $MediaUrl
        pipeName       = $MpvPipeName
        isLive         = $IsLive
        playerPid      = $PlayerPid
        roomId         = $RoomId
        danmakuEnabled = $DanmakuEnabled
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Start-MpvCacheWatcher {
    param([string]$PipeName, [string]$CacheDir)
    $sb = {
        param($PipeName, $CacheDir)
        function Clear-Dir([string]$Dir) {
            if (-not (Test-Path -LiteralPath $Dir)) { return }
            Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        $client = $null
        try {
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
            if (-not $client.WaitForConnection(20000)) { return }
            $writer = New-Object System.IO.StreamWriter($client)
            $reader = New-Object System.IO.StreamReader($client)
            $writer.AutoFlush = $true
            foreach ($cmd in @('{"command":["enable_event","end-file",1]}', '{"command":["enable_event","file-loaded",1]}')) {
                $writer.WriteLine($cmd)
            }
            $fileCount = 0
            while ($client.IsConnected) {
                $line = $reader.ReadLine()
                if (-not $line) { Start-Sleep -Milliseconds 200; continue }
                try { $ev = $line | ConvertFrom-Json } catch { continue }
                if ($ev.event -eq 'file-loaded') {
                    if ($fileCount -gt 0) { Clear-Dir $CacheDir }
                    $fileCount++
                }
                if ($ev.event -eq 'end-file') { Clear-Dir $CacheDir }
            }
        } catch {
        } finally {
            if ($null -ne $client) { $client.Dispose() }
        }
    }
    return Start-Job -ScriptBlock $sb -ArgumentList $PipeName, $CacheDir
}

function Stop-MpvCacheWatcher($Job) {
    if ($null -eq $Job) { return }
    Stop-Job $Job -ErrorAction SilentlyContinue
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
}

function Start-LivePlayerDirect {
    param(
        [string]$MpvExe, [string]$YtdlpExe, [string]$MediaUrl,
        [string]$SessionDir, [string]$PipeName, [string]$FormatSpec,
        [string]$Referer, [string]$UserAgent,
        [string]$CookieBrowser, [string]$CookiesFile
    )
    $streamUrls = Resolve-StreamUrls -YtdlpExe $YtdlpExe -MediaUrl $MediaUrl -FormatSpec $FormatSpec `
        -Referer $Referer -UserAgent $UserAgent -CookieBrowser $CookieBrowser `
        -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir
    $mpvArgs = @(
        '--force-window=yes', '--keep-open=yes', '--no-ytdl', '--demuxer-lavf-format=flv',
        '--force-seekable=no', '--rebase-start-time=yes', '--cache=yes',
        "--cache-secs=$LiveCacheSecs", '--demuxer-max-bytes=52428800',
        '--demuxer-max-back-bytes=20971520', "--input-ipc-server=\\.\pipe\$PipeName",
        '--msg-level=all=warn'
    )
    $mpvArgs = Add-MpvStreamArgs -MpvArgs $mpvArgs -StreamUrls $streamUrls -Referrer $MediaUrl
    $mpvArgs = Add-MpvNetLaunchArgs -MpvExe $MpvExe -MpvArgs $mpvArgs
    $proc = Start-Process -FilePath $MpvExe -ArgumentList $mpvArgs -PassThru
    return [pscustomobject]@{ Mode = 'direct'; Main = $proc }
}

function Stop-LivePlayer($LiveHandle) {
    if ($null -eq $LiveHandle) { return }
    foreach ($proc in @($LiveHandle.Main, $LiveHandle.Ffmpeg)) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch { }
        }
    }
}

function Start-LiveDanmakuSidecar {
    param(
        [Parameter(Mandatory)]
        [string]$RoomId,
        [Parameter(Mandatory)]
        [int]$MpvPid
    )
    $sidecar = Join-Path $Root 'Start-LiveDanmaku.ps1'
    if (-not (Test-Path -LiteralPath $sidecar)) {
        if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
            Write-BiliDiag -Level 'WARN' -Category 'DANMAKU' -Script 'Start-StreamPlay' -Message "sidecar missing: $sidecar"
        }
        return $null
    }
    $argList = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', $sidecar,
        '-RoomId', $RoomId,
        '-MpvPid', $MpvPid,
        '-Speed', $DanmakuSpeed
    )
    if ($YtdlpCookiesFile -and (Test-Path -LiteralPath $YtdlpCookiesFile)) {
        $argList += @('-CookiesFile', $YtdlpCookiesFile)
    }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
        if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
            Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Script 'Start-StreamPlay' -Message ("sidecar pid={0} roomId={1} mpv={2}" -f $p.Id, $RoomId, $MpvPid)
        }
        return $p.Id
    } catch {
        if (Get-Command Write-BiliDiagException -ErrorAction SilentlyContinue) {
            Write-BiliDiagException -Category 'DANMAKU' -Context 'sidecar spawn failed' -ErrorRecord $_ -Script 'Start-StreamPlay'
        }
        return $null
    }
}

function Start-VodPlayer {
    param(
        [string]$MpvExe, [string]$YtdlpExe, [string]$MediaUrl,
        [string]$SessionDir, [string]$PipeName, [string]$FormatSpec,
        [string]$Referer, [string]$UserAgent,
        [string]$CookieBrowser, [string]$CookiesFile
    )
    $streamUrls = Resolve-StreamUrls -YtdlpExe $YtdlpExe -MediaUrl $MediaUrl -FormatSpec $FormatSpec `
        -Referer $Referer -UserAgent $UserAgent -CookieBrowser $CookieBrowser `
        -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir
    $mpvArgs = @(
        '--force-window=yes', '--keep-open=yes', '--no-ytdl', '--cache=yes',
        "--cache-dir=$SessionDir", "--demuxer-max-bytes=$((($MpvCacheSecs * 1024 * 1024) / 4))B",
        "--input-ipc-server=\\.\pipe\$PipeName", '--msg-level=all=warn'
    )
    $mpvArgs = Add-MpvStreamArgs -MpvArgs $mpvArgs -StreamUrls $streamUrls -Referrer $MediaUrl
    $mpvArgs = Add-MpvNetLaunchArgs -MpvExe $MpvExe -MpvArgs $mpvArgs
    return Start-Process -FilePath $MpvExe -ArgumentList $mpvArgs -PassThru
}

$ErrorLog = Join-Path $RuntimeDir 'play-error.log'

function Write-PlayError([string]$Message) {
    if (Get-Command Write-BiliDiag -ErrorAction SilentlyContinue) {
        Write-BiliDiag -Level 'ERROR' -Category 'PLAY' -Script 'Start-StreamPlay' -Message $Message
    } else {
        $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath $ErrorLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

try {
    try { $Url = ([Uri]$Url.Trim()).AbsoluteUri } catch { throw "无效链接: $Url" }
    if (Get-Command Normalize-BiliUrl -ErrorAction SilentlyContinue) {
        $Url = Normalize-BiliUrl $Url
    }

    $ytdlp = Find-Executable -Name 'yt-dlp' -Override $YtdlpPath -Fallbacks @()
    $mpv = Find-Executable -Name 'mpv' -Override $MpvPath -Fallbacks @(
        (Join-Path $env:LOCALAPPDATA 'Programs\mpv\mpv.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net\mpv.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net\mpvnet.exe')
    )
    $ffmpeg = Find-Executable -Name 'ffmpeg' -Override $FfmpegPath -Fallbacks @(
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    )
    if (-not $ytdlp) { throw '未找到 yt-dlp。请运行: winget install yt-dlp.yt-dlp' }
    if (-not $mpv) { throw '未找到 mpv。请运行: winget install mpv.net' }

    $isLive = Test-LiveUrl $Url
    if ($isLive -and -not $ffmpeg) {
        throw '直播播放需要 ffmpeg。请运行: winget install yt-dlp.FFmpeg'
    }

    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    Set-Content -LiteralPath $LinkFile -Value $Url -Encoding UTF8
    Stop-PreviousPlayer

    $formatSpec = $Format
    if ([string]::IsNullOrWhiteSpace($formatSpec)) {
        $formatSpec = if ($isLive) { $DefaultLiveFormat } else { $DefaultVodFormat }
    }

    $sessionDir = Join-Path $CacheRoot ("session-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), $PID)
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    $sessionDir = (Resolve-Path -LiteralPath $sessionDir).Path
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    $env:TEMP = $sessionDir
    $env:TMP = $sessionDir
    $watcher = $null
    $liveHandle = $null

    try {
        if ($isLive) {
            $liveHandle = Start-LivePlayerDirect -MpvExe $mpv -YtdlpExe $ytdlp -MediaUrl $Url `
                -SessionDir $sessionDir -PipeName $MpvPipeName -FormatSpec $formatSpec `
                -Referer $Url -UserAgent $YtdlpUserAgent `
                -CookieBrowser $YtdlpCookieBrowser -CookiesFile $YtdlpCookiesFile
            $proc = $liveHandle.Main
        } else {
            $proc = Start-VodPlayer -MpvExe $mpv -YtdlpExe $ytdlp -MediaUrl $Url `
                -SessionDir $sessionDir -PipeName $MpvPipeName -FormatSpec $formatSpec `
                -Referer $Url -UserAgent $YtdlpUserAgent `
                -CookieBrowser $YtdlpCookieBrowser -CookiesFile $YtdlpCookiesFile
        }

        Set-Content -LiteralPath $PidFile -Value "mpv=$($proc.Id)" -Encoding ASCII

        $danmakuPid = $null
        $liveRoomId = ''
        if ($isLive) {
            try {
                if (Get-Command Get-BiliLiveRoomId -ErrorAction SilentlyContinue) {
                    $resolved = Get-BiliLiveRoomId -Url $Url
                    if ($resolved) { $liveRoomId = [string]$resolved }
                }
            } catch {
                Write-BiliDiagException -Category 'DANMAKU' -Context 'resolve roomId' -ErrorRecord $_ -Script 'Start-StreamPlay'
            }
            if ($liveRoomId) {
                Start-Sleep -Milliseconds 800
                $danmakuPid = Start-LiveDanmakuSidecar -RoomId $liveRoomId -MpvPid $proc.Id
                if ($danmakuPid) {
                    Add-Content -LiteralPath $PidFile -Value "danmaku=$danmakuPid" -Encoding ASCII
                }
            } else {
                Write-BiliDiag -Level 'WARN' -Category 'DANMAKU' -Script 'Start-StreamPlay' -Message 'no roomId resolved; skip sidecar'
            }
        }

        Write-PlayState -MediaUrl $Url -IsLive:$isLive -PlayerPid $proc.Id `
            -RoomId $liveRoomId -DanmakuEnabled:([bool]$danmakuPid)

        $proc.WaitForExit()
        if ($null -ne $liveHandle) { Stop-LivePlayer $liveHandle }
    } finally {
        Stop-LivePlayer $liveHandle
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $LinkFile -Force -ErrorAction SilentlyContinue
        Remove-PlayCacheSession $sessionDir
    }
} catch {
    Write-PlayError $_.Exception.Message
    if (Get-Command Write-BiliDiagException -ErrorAction SilentlyContinue) {
        Write-BiliDiagException -Category 'PLAY' -Context 'Start-StreamPlay failed' -ErrorRecord $_ -Script 'Start-StreamPlay'
    }
    throw
}
