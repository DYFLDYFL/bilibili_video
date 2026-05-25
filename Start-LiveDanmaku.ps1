#Requires -Version 5.1
<#
  Danmaku sidecar: node listen.js (JSONL file) + transparent overlay on mpv.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RoomId,
    [int]$MpvPid = 0,
    [string]$CookiesFile = '',
    [float]$Speed = 10.0,
    [float]$Rate = 0
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSCommandPath
$RuntimeDir = Join-Path $Root 'runtime'
New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null

. (Join-Path $Root 'Bilibili-Formats.ps1')
. (Join-Path $Root 'Bilibili-DanmakuOverlay.ps1')

if (Get-Command Set-BiliDiagLogPath -ErrorAction SilentlyContinue) {
    Set-BiliDiagLogPath $RuntimeDir
    Write-BiliDiagSession -ScriptName 'Start-LiveDanmaku' -Meta @{ roomId = $RoomId; mpvPid = $MpvPid }
}

$nodeDir = Join-Path $Root 'tools\live-danmaku'
$listen = Join-Path $nodeDir 'listen.js'
if (-not (Test-Path -LiteralPath $listen)) {
    Write-BiliDiag -Level 'ERROR' -Category 'DANMAKU' -Message "listen.js missing: $listen"
    exit 2
}

if (-not $CookiesFile) {
    $CookiesFile = Join-Path $RuntimeDir 'bilibili-cookies.txt'
}

$realRoomId = $RoomId
try {
    $resolved = Get-BiliLiveRoomId -ShortId $RoomId
    if ($resolved) { $realRoomId = $resolved }
} catch {
    Write-BiliDiag -Level 'WARN' -Category 'DANMAKU' -Message ("Get-BiliLiveRoomId fallback: {0}" -f $_.Exception.Message)
}
Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Message ("RoomId short={0} real={1}" -f $RoomId, $realRoomId)

$outFile = Join-Path $RuntimeDir ("danmaku-{0}.jsonl" -f $PID)
'' | Out-File -FilePath $outFile -Encoding UTF8 -Force

$nodeProc = $null
$nodeArgs = @($listen, $realRoomId, $outFile)
if (Test-Path -LiteralPath $CookiesFile) { $nodeArgs += $CookiesFile }
try {
    $nodeProc = Start-Process -FilePath 'node' -ArgumentList $nodeArgs `
        -WorkingDirectory $nodeDir -WindowStyle Hidden -PassThru
    Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Message ("node spawned pid={0} room={1}" -f $nodeProc.Id, $realRoomId)
} catch {
    Write-BiliDiagException -Category 'DANMAKU' -Context 'node start failed' -ErrorRecord $_
    exit 3
}

try {
    Start-DanmakuOverlay -OutFile $outFile -MpvPid $MpvPid -Speed $Speed -Rate $Rate
} catch {
    Write-BiliDiagException -Category 'DANMAKU' -Context 'overlay crashed' -ErrorRecord $_
} finally {
    Write-BiliDiag -Level 'INFO' -Category 'DANMAKU' -Message 'overlay exited; cleaning up'
    try { if ($nodeProc -and -not $nodeProc.HasExited) { Stop-Process -Id $nodeProc.Id -Force -ErrorAction SilentlyContinue } } catch { }
    try { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } catch { }
}
