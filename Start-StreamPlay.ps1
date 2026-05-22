#Requires -Version 5.1
<#
.SYNOPSIS
  解析 B 站链接并用 mpv 流式播放（点播 / 直播）。退出或切换时自动清理缓冲。
  直播从接入时刻起计时（不显示开播以来的总时长）。
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Url
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$RuntimeDir = Join-Path $Root 'runtime'
$CacheRoot = Join-Path $RuntimeDir 'play-cache'
$LinkFile = Join-Path $RuntimeDir 'current-link.txt'
$PidFile = Join-Path $RuntimeDir 'play.pid'
$ConfigPath = Join-Path $Root 'config.ps1'

$YtdlpPath = $null
$MpvPath = $null
$FfmpegPath = $null
$MpvCacheSecs = 300
$LiveCacheSecs = 20
$VodFormat = 'bestvideo+bestaudio/best'
$LiveFormat = 'best[ext=flv]/best/best'

if (Test-Path $ConfigPath) { . $ConfigPath }

function Find-Executable {
    param([string]$Name, [string]$Override, [string[]]$Fallbacks)
    if ($Override -and (Test-Path -LiteralPath $Override)) { return (Resolve-Path -LiteralPath $Override).Path }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $Fallbacks) {
        if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path }
    }
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
                    -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
            } elseif ($_ -match '^\d+$') {
                Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/F', '/T', '/PID', $_) `
                    -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
            }
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $CacheRoot -Filter 'play.pids' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '^(\w+)=(\d+)$') {
                Stop-Process -Id ([int]$Matches[2]) -Force -ErrorAction SilentlyContinue
            }
        }
    }
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

function Resolve-LiveStreamUrl {
    param([string]$YtdlpExe, [string]$MediaUrl)
    $output = & $YtdlpExe @('-f', $LiveFormat, '-g', '--no-playlist', $MediaUrl) 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join "`n")
    }
    $url = @($output | Where-Object { $_ -match '^\w+://' } | Select-Object -First 1)
    if (-not $url) { throw "未能解析直播流地址: $MediaUrl" }
    return $url
}

function Start-LivePlayerDirect {
    param(
        [string]$MpvExe,
        [string]$YtdlpExe,
        [string]$MediaUrl,
        [string]$SessionDir,
        [string]$PipeName
    )

    $mpvArgs = @(
        '--force-window=yes'
        '--keep-open=yes'
        '--ytdl=yes'
        "--ytdl-executable=$YtdlpExe"
        "--ytdl-format=$LiveFormat"
        '--force-seekable=no'
        '--rebase-start-time=yes'
        '--cache=yes'
        "--cache-secs=$LiveCacheSecs"
        '--demuxer-max-bytes=52428800'
        '--demuxer-max-back-bytes=20971520'
        "--input-ipc-server=\\.\pipe\$PipeName"
        '--msg-level=all=warn'
        $MediaUrl
    )
    $proc = Start-Process -FilePath $MpvExe -ArgumentList $mpvArgs -PassThru
    return [pscustomobject]@{
        Mode = 'direct'
        Main = $proc
    }
}

function Start-LivePlayerPiped {
    param(
        [string]$MpvExe,
        [string]$YtdlpExe,
        [string]$FfmpegExe,
        [string]$MediaUrl,
        [string]$SessionDir,
        [string]$PipeName
    )

    $streamUrl = Resolve-LiveStreamUrl -YtdlpExe $YtdlpExe -MediaUrl $MediaUrl
    $logFile = Join-Path $SessionDir 'live-play.log'

    $mpvArgs = @(
        '--force-window=yes'
        '--keep-open=yes'
        '--no-ytdl'
        '--demuxer-lavf-format=flv'
        '--force-seekable=no'
        '--rebase-start-time=yes'
        '--cache=yes'
        "--cache-secs=$LiveCacheSecs"
        '--demuxer-max-bytes=52428800'
        '--demuxer-max-back-bytes=20971520'
        "--input-ipc-server=\\.\pipe\$PipeName"
        '--msg-level=all=warn'
        '-'
    )

    $ffArgs = @(
        '-nostdin', '-hide_banner', '-loglevel', 'warning',
        '-fflags', '+nobuffer+flush_packets',
        '-flags', 'low_delay',
        '-probesize', '32768',
        '-analyzeduration', '500000',
        '-i', $streamUrl,
        '-c', 'copy',
        '-f', 'flv',
        '-reset_timestamps', '1',
        '-muxdelay', '0',
        '-muxpreload', '0',
        'pipe:1'
    )

    $mpvPsi = New-Object System.Diagnostics.ProcessStartInfo
    $mpvPsi.FileName = $MpvExe
    $mpvPsi.Arguments = ($mpvArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f ($_.Replace('"', '\"')) } else { $_ }
    }) -join ' '
    $mpvPsi.UseShellExecute = $false
    $mpvPsi.RedirectStandardInput = $true
    $mpvPsi.CreateNoWindow = $true
    $mpvProc = [System.Diagnostics.Process]::Start($mpvPsi)

    $ffPsi = New-Object System.Diagnostics.ProcessStartInfo
    $ffPsi.FileName = $FfmpegExe
    $ffPsi.UseShellExecute = $false
    $ffPsi.RedirectStandardOutput = $true
    $ffPsi.RedirectStandardError = $true
    $ffPsi.CreateNoWindow = $true
    $ffPsi.Arguments = ($ffArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f ($_.Replace('"', '\"')) } else { $_ }
    }) -join ' '
    $ffProc = [System.Diagnostics.Process]::Start($ffPsi)

    $pipePs = [powershell]::Create()
    $null = $pipePs.AddScript({
        param($Ff, $Mpv, $Log)
        try {
            $Ff.StandardOutput.BaseStream.CopyTo($Mpv.StandardInput.BaseStream)
        } catch {
            [System.IO.File]::AppendAllText($Log, ('pipe: ' + $_.Exception.Message + [Environment]::NewLine))
        } finally {
            try { $Mpv.StandardInput.Close() } catch { }
        }
    }).AddArgument($ffProc).AddArgument($mpvProc).AddArgument($logFile)
    $pipeAsync = $pipePs.BeginInvoke()

    $errPs = [powershell]::Create()
    $null = $errPs.AddScript({
        param($Ff, $Log)
        try {
            while (($line = $Ff.StandardError.ReadLine()) -ne $null) {
                [System.IO.File]::AppendAllText($Log, ($line + [Environment]::NewLine))
            }
        } catch { }
    }).AddArgument($ffProc).AddArgument($logFile)
    $errAsync = $errPs.BeginInvoke()

    return [pscustomobject]@{
        Mode      = 'piped'
        Main      = $mpvProc
        Ffmpeg    = $ffProc
        PipePs    = $pipePs
        PipeAsync = $pipeAsync
        ErrPs     = $errPs
        ErrAsync  = $errAsync
    }
}

function Start-LivePlayer {
    param(
        [string]$MpvExe,
        [string]$YtdlpExe,
        [string]$FfmpegExe,
        [string]$MediaUrl,
        [string]$SessionDir,
        [string]$PipeName
    )

    if ($FfmpegExe) {
        try {
            $piped = Start-LivePlayerPiped -MpvExe $MpvExe -YtdlpExe $YtdlpExe -FfmpegExe $FfmpegExe `
                -MediaUrl $MediaUrl -SessionDir $SessionDir -PipeName $PipeName
            Start-Sleep -Seconds 3
            if (-not $piped.Main.HasExited) {
                return $piped
            }
            Stop-LivePlayer $piped
        } catch {
            $msg = $_.Exception.Message
            [System.IO.File]::AppendAllText((Join-Path $SessionDir 'live-play.log'), ('fallback: ' + $msg + [Environment]::NewLine))
        }
    }

    return Start-LivePlayerDirect -MpvExe $MpvExe -YtdlpExe $YtdlpExe `
        -MediaUrl $MediaUrl -SessionDir $SessionDir -PipeName $PipeName
}

function Stop-LivePlayer($LiveHandle) {
    if ($null -eq $LiveHandle) { return }
    foreach ($proc in @($LiveHandle.Main, $LiveHandle.Ffmpeg)) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch { }
        }
    }
    foreach ($item in @(
        @{ Ps = $LiveHandle.PipePs; Async = $LiveHandle.PipeAsync }
        @{ Ps = $LiveHandle.ErrPs; Async = $LiveHandle.ErrAsync }
    )) {
        if ($null -eq $item.Ps) { continue }
        try {
            if ($null -ne $item.Async -and -not $item.Async.IsCompleted) {
                $item.Ps.Stop()
            } elseif ($null -ne $item.Async) {
                $item.Ps.EndInvoke($item.Async) | Out-Null
            }
        } catch { }
        $item.Ps.Dispose()
    }
}

function Start-VodPlayer {
    param(
        [string]$MpvExe,
        [string]$YtdlpExe,
        [string]$MediaUrl,
        [string]$SessionDir,
        [string]$PipeName
    )

    $mpvArgs = @(
        '--force-window=yes'
        '--keep-open=yes'
        '--ytdl=yes'
        "--ytdl-executable=$YtdlpExe"
        "--ytdl-format=$VodFormat"
        '--cache=yes'
        "--cache-dir=$SessionDir"
        "--demuxer-max-bytes=$((($MpvCacheSecs * 1024 * 1024) / 4))B"
        "--input-ipc-server=\\.\pipe\$PipeName"
        '--msg-level=all=warn'
        $MediaUrl
    )
    return Start-Process -FilePath $MpvExe -ArgumentList $mpvArgs -PassThru
}

try { $Url = ([Uri]$Url.Trim()).AbsoluteUri } catch { throw "无效链接: $Url" }

$ytdlp = Find-Executable -Name 'yt-dlp' -Override $YtdlpPath -Fallbacks @()
$mpv = Find-Executable -Name 'mpv' -Override $MpvPath -Fallbacks @(
    (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net\mpvnet.exe')
    (Join-Path $env:LOCALAPPDATA 'Programs\mpv.net\mpv.exe')
)
$ffmpegFallback = (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
$ffmpeg = Find-Executable -Name 'ffmpeg' -Override $FfmpegPath -Fallbacks @($ffmpegFallback)
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
Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-PlayCacheSession $_.FullName
}

$sessionDir = Join-Path $CacheRoot ("session-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), $PID)
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
$sessionDir = (Resolve-Path -LiteralPath $sessionDir).Path

$pipeName = "bili-play-$PID"
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$env:TEMP = $sessionDir
$env:TMP = $sessionDir
$watcher = $null
$liveHandle = $null

try {
    if ($isLive) {
        $liveHandle = Start-LivePlayer -MpvExe $mpv -YtdlpExe $ytdlp -FfmpegExe $ffmpeg `
            -MediaUrl $Url -SessionDir $sessionDir -PipeName $pipeName
        $proc = $liveHandle.Main
        $pidLines = @("mpv=$($proc.Id)")
        if ($null -ne $liveHandle.Ffmpeg) { $pidLines += "ffmpeg=$($liveHandle.Ffmpeg.Id)" }
        Set-Content -LiteralPath $PidFile -Value $pidLines -Encoding ASCII
    } else {
        $proc = Start-VodPlayer -MpvExe $mpv -YtdlpExe $ytdlp `
            -MediaUrl $Url -SessionDir $sessionDir -PipeName $pipeName
        Set-Content -LiteralPath $PidFile -Value "mpv=$($proc.Id)" -Encoding ASCII
    }

    Start-Sleep -Milliseconds 800
    $watcher = Start-MpvCacheWatcher -PipeName $pipeName -CacheDir $sessionDir
    $proc.WaitForExit()
    if ($null -ne $liveHandle) {
        Stop-LivePlayer $liveHandle
    }
} finally {
    Stop-MpvCacheWatcher $watcher
    Stop-LivePlayer $liveHandle
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LinkFile -Force -ErrorAction SilentlyContinue
    Remove-PlayCacheSession $sessionDir
}
