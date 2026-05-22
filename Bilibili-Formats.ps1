#Requires -Version 5.1
<#
  yt-dlp 解析 B 站画质；Cookie / Referer / UA 按社区惯例传给 yt-dlp 与 mpv。
  诊断日志：runtime/diag.log（见 Write-BiliDiag / Get-BiliDiagRecent）
#>

$script:BiliDiagLog = $null
$script:BiliDiagMaxBytes = 512KB
$script:BiliDiagKeepLines = 1500
$script:LastCookieExportDiag = $null
$script:BiliDiagLock = New-Object object

function Set-BiliDiagLogPath {
    param([string]$RuntimeDir)
    if (-not $RuntimeDir) { return }
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    $script:BiliDiagLog = Join-Path $RuntimeDir 'diag.log'
}

function Invoke-BiliDiagLocked {
    param([scriptblock]$Action)
    [System.Threading.Monitor]::Enter($script:BiliDiagLock)
    try { & $Action } finally { [System.Threading.Monitor]::Exit($script:BiliDiagLock) }
}

function Invoke-BiliDiagRotate {
    if (-not $script:BiliDiagLog -or -not (Test-Path -LiteralPath $script:BiliDiagLog)) { return }
    try {
        $len = (Get-Item -LiteralPath $script:BiliDiagLog).Length
        if ($len -le $script:BiliDiagMaxBytes) { return }
        $tail = @(Get-Content -LiteralPath $script:BiliDiagLog -Tail $script:BiliDiagKeepLines -Encoding UTF8 -ErrorAction SilentlyContinue)
        $header = '[{0:yyyy-MM-dd HH:mm:ss}] [INFO] [DIAG] --- log rotated (kept last {1} lines) ---' -f (Get-Date), $tail.Count
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($script:BiliDiagLog, @($header) + $tail, $utf8)
    } catch { }
}

function Write-BiliDiag {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',
        [string]$Category = 'APP',
        [string]$Message = '',
        [string]$Script = '',
        [hashtable]$Data = $null
    )
    if (-not $script:BiliDiagLog) { return }
    if (-not $Script) {
        $frame = Get-PSCallStack | Select-Object -Skip 1 -First 1
        if ($frame -and $frame.ScriptName) {
            $Script = [System.IO.Path]::GetFileNameWithoutExtension($frame.ScriptName)
        }
    }
    $extra = ''
    if ($Data -and $Data.Count -gt 0) {
        $parts = @($Data.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
        $extra = ' | ' + ($parts -join ' ')
    }
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] [{3}] {4}{5}' -f (
        Get-Date), $Level, $Category, $Script, $Message, $extra
    Invoke-BiliDiagLocked {
        Invoke-BiliDiagRotate
        $utf8 = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::AppendAllText($script:BiliDiagLog, $line + [Environment]::NewLine, $utf8)
    }
}

function Write-BiliDiagException {
    param(
        [string]$Category = 'ERROR',
        [string]$Context = '',
        [object]$ErrorRecord = $null,
        [string]$Script = ''
    )
    $err = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord } else { $_ }
    $msg = if ($err.Exception) { $err.Exception.Message } else { "$err" }
    $diagMsg = if ($Context) { "$Context : $msg" } else { $msg }
    Write-BiliDiag -Level 'ERROR' -Category $Category -Script $Script -Message $diagMsg
    if ($err.ScriptStackTrace) {
        foreach ($stLine in ($err.ScriptStackTrace -split '\r?\n')) {
            if ($stLine.Trim()) {
                Write-BiliDiag -Level 'DEBUG' -Category $Category -Script $Script -Message ("  at {0}" -f $stLine.Trim())
            }
        }
    }
}

function Write-BiliDiagSession {
    param(
        [string]$ScriptName,
        [hashtable]$Meta = $null
    )
    $meta = @{}
    if ($Meta) { $Meta.GetEnumerator() | ForEach-Object { $meta[$_.Key] = $_.Value } }
    $meta['pid'] = $PID
    Write-BiliDiag -Level 'INFO' -Category 'SESSION' -Script $ScriptName -Message '--- start ---' -Data $meta
}

function Get-BiliDiagRecent {
    param(
        [int]$Lines = 100,
        [string]$Category = '',
        [string]$Level = ''
    )
    if (-not $script:BiliDiagLog -or -not (Test-Path -LiteralPath $script:BiliDiagLog)) {
        return @('（尚无 diag.log）')
    }
    $all = @(Get-Content -LiteralPath $script:BiliDiagLog -Tail ([Math]::Max($Lines * 3, 200)) -Encoding UTF8 -ErrorAction SilentlyContinue)
    $filtered = @($all | Where-Object {
        $ok = $true
        if ($Category -and $_ -notmatch "\[$([regex]::Escape($Category))\]") { $ok = $false }
        if ($Level -and $_ -notmatch "\[$([regex]::Escape($Level))\]") { $ok = $false }
        $ok
    })
    if ($filtered.Count -gt $Lines) {
        return @($filtered | Select-Object -Last $Lines)
    }
    if ($filtered.Count -gt 0) { return $filtered }
    return @($all | Select-Object -Last $Lines)
}

function Show-BiliUserError {
    param(
        [string]$Title,
        [string]$Summary,
        [string[]]$Details = @()
    )
    Write-BiliDiag -Level 'ERROR' -Category 'UI' -Message "${Title}: ${Summary}"
    foreach ($d in $Details) {
        if ($d) { Write-BiliDiag -Level 'ERROR' -Category 'DETAIL' -Message $d }
    }
    $body = $Summary
    if ($Details -and $Details.Count -gt 0) {
        $body += "`n`n【详情】`n" + (($Details | Where-Object { $_ }) -join "`n")
    }
    if ($script:BiliDiagLog) {
        $body += "`n`n完整日志文件：`n$($script:BiliDiagLog)"
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.MessageBox]::Show($body, $Title, 'OK', 'Warning') | Out-Null
}

function Open-BiliDiagLog {
    if (-not $script:BiliDiagLog -or -not (Test-Path -LiteralPath $script:BiliDiagLog)) {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            '尚无日志。出错后会自动写入 runtime\diag.log。',
            '诊断日志', 'OK', 'Information') | Out-Null
        return
    }
    $recent = Get-BiliDiagRecent -Lines 40 -Level 'ERROR'
    if ($recent.Count -gt 0 -and $recent[0] -notmatch '尚无') {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $preview = ($recent -join "`n")
        if ($preview.Length -gt 1200) { $preview = $preview.Substring($preview.Length - 1200) }
        [System.Windows.Forms.MessageBox]::Show(
            "最近 ERROR 日志（完整内容在记事本）：`n`n$preview",
            '诊断日志', 'OK', 'Information') | Out-Null
    }
    Start-Process notepad.exe -ArgumentList $script:BiliDiagLog | Out-Null
}

function Show-BiliBusyForm {
    param(
        [string]$Message = '请稍候…',
        [string]$Title = 'Bilibili 播放器'
    )
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = 'FixedDialog'
    $form.Size = New-Object System.Drawing.Size(440, 130)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "  $Message"
    $label.Dock = 'Fill'
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.Controls.Add($label)
    $form.Add_Shown({
        $form.TopMost = $true
        $form.Activate()
        $form.BringToFront()
    })
    [void]$form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return $form
}

function Close-BiliBusyForm {
    param($Form)
    if ($null -eq $Form) { return }
    try {
        if (-not $Form.IsDisposed) { $Form.Close() }
    } catch { }
    try {
        if (-not $Form.IsDisposed) { $Form.Dispose() }
    } catch { }
}

function Get-CookieExportFailureMessage {
    $d = $script:LastCookieExportDiag
    if (-not $d) {
        return @(
            '未能读取 WebView2 Cookie（无诊断信息）。'
            '请关闭窗口后重新打开 打开网页.vbs'
        )
    }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("读取到的 Cookie 数量：$($d.TotalCount)")
    if ($d.Names -and $d.Names.Count -gt 0) {
        [void]$lines.Add('Cookie 名称：' + ($d.Names -join ', '))
    } else {
        [void]$lines.Add('Cookie 名称：（无）')
    }
    if ($d.HasSess) {
        [void]$lines.Add('已发现 SESSDATA，但写入文件失败。')
    } else {
        [void]$lines.Add('未发现 SESSDATA（登录态 Cookie）。')
    }
    if ($d.UriResults) {
        [void]$lines.Add('各来源：' + ($d.UriResults -join ' | '))
    }
    if ($d.Error) {
        [void]$lines.Add("异常：$($d.Error)")
    }
    [void]$lines.Add('可尝试：① 本窗口退出后重新登录 ② config.ps1 设置 $YtdlpCookieBrowser = ''edge''')
    return $lines.ToArray()
}

function Get-WebView2UserDataDir {
    $eb = Join-Path $env:LOCALAPPDATA 'BilibiliEdge\WebView2\EBWebView'
    if (Test-Path -LiteralPath (Join-Path $eb 'Default')) { return $eb }
    return $null
}

function Test-CookieFileHasSessdata {
    param([string]$Path)
    return ($Path -and (Test-Path -LiteralPath $Path) -and
        (Select-String -LiteralPath $Path -Pattern 'SESSDATA' -Quiet))
}

function Resolve-YtdlpCookiesFile {
    param(
        [string]$CookiesFile,
        [string]$RuntimeDir = ''
    )
    foreach ($candidate in @($CookiesFile, $(if ($RuntimeDir) { Join-Path $RuntimeDir 'bilibili-cookies.txt' }))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate) -and (Test-CookieFileHasSessdata $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-WebView2CookiesMerged {
    param(
        $CoreWebView2,
        [int]$TimeoutMs = 4000
    )
    if ($null -eq $CoreWebView2) { return @() }

    function Wait-CookieTask($task, [int]$remainingMs) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $task.IsCompleted -and $sw.ElapsedMilliseconds -lt $remainingMs) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 15
        }
        return ($task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled)
    }

    $merged = @{}
    $uriResults = New-Object System.Collections.Generic.List[string]
    $budget = $TimeoutMs
    $lastError = ''
    foreach ($uri in @('https://www.bilibili.com', 'https://bilibili.com')) {
        if ($budget -le 0) { break }
        $label = if ($uri) { $uri } else { '(全部)' }
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $task = $CoreWebView2.CookieManager.GetCookiesAsync([string]$uri)
            if (-not (Wait-CookieTask $task $budget)) {
                [void]$uriResults.Add("${label}:超时")
                continue
            }
            $budget -= [int][Math]::Max(1, $sw.ElapsedMilliseconds)
            $batch = @($task.Result)
            [void]$uriResults.Add(('{0}:{1}个' -f $label, $batch.Count))
            foreach ($c in $batch) {
                if ($null -eq $c -or [string]::IsNullOrWhiteSpace([string]$c.Name)) { continue }
                $k = '{0}|{1}|{2}' -f $c.Name, $c.Domain, $c.Path
                $merged[$k] = $c
            }
            $hasSess = $false
            foreach ($c in $merged.Values) {
                if ($c.Name -eq 'SESSDATA' -and -not [string]::IsNullOrWhiteSpace([string]$c.Value)) {
                    $hasSess = $true
                    break
                }
            }
            if ($hasSess) { break }
        } catch {
            $lastError = $_.Exception.Message
            [void]$uriResults.Add("${label}:失败")
        }
    }
    $all = @($merged.Values)
    $names = @($all | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    $hasSessdata = $false
    foreach ($c in $all) {
        if ($c.Name -eq 'SESSDATA' -and -not [string]::IsNullOrWhiteSpace([string]$c.Value)) {
            $hasSessdata = $true
            break
        }
    }
    $script:LastCookieExportDiag = [pscustomobject]@{
        TotalCount  = $all.Count
        Names       = $names
        HasSess     = $hasSessdata
        UriResults  = $uriResults.ToArray()
        Error       = $lastError
    }
    return $all
}

function ConvertTo-PlainBiliCookie {
    param($Raw)
    $exp = [datetime]::MinValue
    try {
        if ($null -ne $Raw.Expires) {
            $exp = [datetime]$Raw.Expires
        }
    } catch { }
    return [pscustomobject]@{
        Name       = [string]$Raw.Name
        Value      = [string]$Raw.Value
        Domain     = [string]$Raw.Domain
        Path       = [string]$Raw.Path
        IsSecure   = [bool]$Raw.IsSecure
        IsHttpOnly = [bool]$Raw.IsHttpOnly
        Expires    = $exp
    }
}

function Write-BiliCookieNetscapeFile {
    param($Cookies, [string]$OutPath)
    $list = @($Cookies | ForEach-Object { ConvertTo-PlainBiliCookie $_ })
    if ($list.Count -eq 0) { return $false }
    $hasSess = $false
    foreach ($c in $list) {
        if ($c.Name -eq 'SESSDATA' -and -not [string]::IsNullOrWhiteSpace($c.Value)) {
            $hasSess = $true
            break
        }
    }
    if (-not $hasSess) { return $false }

    $dir = [System.IO.Path]::GetDirectoryName($OutPath)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Netscape HTTP Cookie File')
    [void]$sb.AppendLine('# https://curl.haxx.se/rfc/cookie_spec.html')
    [void]$sb.AppendLine('# Exported by BilibiliEdge')
    $epoch = [datetime]::SpecifyKind((Get-Date '1970-01-01'), [System.DateTimeKind]::Utc)

    foreach ($c in $list) {
        [string]$domain = $c.Domain
        if ([string]::IsNullOrWhiteSpace($domain)) { continue }
        if (-not $domain.StartsWith('.')) { $domain = ".$domain" }
        [string]$path = if ([string]::IsNullOrWhiteSpace($c.Path)) { '/' } else { $c.Path }
        [string]$secure = if ($c.IsSecure) { 'TRUE' } else { 'FALSE' }
        [long]$expSec = 0
        if ($c.Expires.Year -gt 1970) {
            $expSec = [long][Math]::Floor(($c.Expires.ToUniversalTime() - $epoch).TotalSeconds)
            if ($expSec -lt 0) { $expSec = 0 }
            if ($expSec -gt 2147483647) { $expSec = 2147483647 }
        }
        [string]$domOut = if ($c.IsHttpOnly) { "#HttpOnly_$domain" } else { $domain }
        [void]$sb.AppendLine((
            $domOut, 'TRUE', $path, $secure, [string]$expSec, $c.Name, $c.Value
        ) -join "`t")
    }

    $enc = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $sw = New-Object System.IO.StreamWriter($OutPath, $false, $enc)
    try {
        $sw.Write($sb.ToString())
    } finally {
        $sw.Close()
    }
    return (Test-Path -LiteralPath $OutPath)
}

function Export-BiliCookiesForPlay {
    param(
        $CoreWebView2,
        [string]$OutPath,
        [int]$TimeoutMs = 4000
    )
    if ($null -eq $CoreWebView2) {
        $script:LastCookieExportDiag = [pscustomobject]@{
            TotalCount = 0; Names = @(); HasSess = $false
            UriResults = @('WebView2 未初始化'); Error = ''
        }
        Write-BiliDiag -Level 'WARN' -Category 'COOKIE' -Message 'Export skipped: CoreWebView2 is null'
        return $false
    }
    try {
        $cookies = Get-WebView2CookiesMerged -CoreWebView2 $CoreWebView2 -TimeoutMs $TimeoutMs
        Write-BiliDiag -Level 'INFO' -Category 'COOKIE' -Message (
            'Export try: count={0} hasSess={1} out={2}' -f $cookies.Count, $script:LastCookieExportDiag.HasSess, $OutPath
        )
        if ($cookies.Count -eq 0) { return $false }
        $ok = Write-BiliCookieNetscapeFile -Cookies $cookies -OutPath $OutPath
        if ($ok) {
            Write-BiliDiag -Level 'INFO' -Category 'COOKIE' -Message "Export OK -> $OutPath"
        } else {
            Write-BiliDiag -Level 'WARN' -Category 'COOKIE' -Message 'Export fail: Write-BiliCookieNetscapeFile returned false'
        }
        return $ok
    } catch {
        $prev = $script:LastCookieExportDiag
        $script:LastCookieExportDiag = [pscustomobject]@{
            TotalCount = if ($prev) { $prev.TotalCount } else { 0 }
            Names      = if ($prev) { @($prev.Names) } else { @() }
            HasSess    = if ($prev) { [bool]$prev.HasSess } else { $false }
            UriResults = if ($prev) { @($prev.UriResults) } else { @() }
            Error      = $_.Exception.Message
        }
        Write-BiliDiagException -Category 'COOKIE' -Context 'Export exception' -ErrorRecord $_
        return $false
    }
}

function Normalize-BiliUrl([string]$raw) {
    [string]$u = $raw.Trim()
    if ($u -match '(https?://(?:www\.)?bilibili\.com/video/[^/?#\s]+)') { return $Matches[1] }
    if ($u -match '(https?://live\.bilibili\.com/\d+)') { return $Matches[1] }
    if ($u -match '(https?://(?:www\.)?bilibili\.com/blive/[^/?#\s]+)') { return $Matches[1] }
    if ($u -match '(https?://b23\.tv/[^/?#\s]+)') { return $Matches[1] }
    return $u
}

function Get-YtdlpCookieArgSets {
    param(
        [string]$CookieBrowser,
        [string]$CookiesFile,
        [string]$RuntimeDir = ''
    )
    $sets = New-Object System.Collections.Generic.List[object]
    $resolved = Resolve-YtdlpCookiesFile -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir
    if ($resolved) {
        $sets.Add([pscustomobject]@{ Args = @('--cookies', $resolved) }) | Out-Null
    }
    if ($CookieBrowser) {
        $sets.Add([pscustomobject]@{ Args = @('--cookies-from-browser', [string]$CookieBrowser) }) | Out-Null
    }
    if ($sets.Count -eq 0) {
        $sets.Add([pscustomobject]@{ Args = @() }) | Out-Null
    }
    return $sets.ToArray()
}

function Invoke-YtdlpExe {
    param([string]$YtdlpExe, [string[]]$YtdlpArgs)
    $argv = New-Object System.Collections.Generic.List[string]
    foreach ($a in $YtdlpArgs) {
        if ($null -ne $a -and "$a".Length -gt 0) { [void]$argv.Add([string]$a) }
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return @(& $YtdlpExe $argv.ToArray() 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() }
            else { "$_" }
        })
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-InfoMaxVideoHeight($Info) {
    if (-not $Info -or -not $Info.formats) { return 0 }
    $heights = @($Info.formats | Where-Object { $_.height } | ForEach-Object { [int]$_.height })
    if ($heights.Count -eq 0) { return 0 }
    return ($heights | Measure-Object -Maximum).Maximum
}

function Invoke-YtdlpJson {
    param(
        [string]$YtdlpExe,
        [string]$MediaUrl,
        [string]$Referer,
        [string]$UserAgent,
        [string]$CookieBrowser,
        [string]$CookiesFile,
        [string]$RuntimeDir
    )
    [string]$url = Normalize-BiliUrl $MediaUrl
    [string]$ref = if ($Referer) { $Referer } else { $url }
    Write-BiliDiag -Level 'INFO' -Category 'YTDLP' -Message ("Fetching video info: {0}" -f $url)
    $base = @('-J', '--no-playlist', '--no-warnings', '--referer', $ref)
    if ($UserAgent) { $base += @('--user-agent', $UserAgent) }

    function Invoke-Once([string[]]$Extra) {
        # Important: $Extra (cookie args) must come before `-- URL`, otherwise yt-dlp
        # treats `--cookies <file>` as a positional URL argument and silently ignores it.
        $allArgs = $base + $Extra + @('--', $url)
        $lines = Invoke-YtdlpExe -YtdlpExe $YtdlpExe -YtdlpArgs $allArgs
        if ($LASTEXITCODE -ne 0) {
            $err = $lines -join "`n"
            if ($err -notmatch '^\s*\{') { throw $err }
        }
        $json = ($lines | Where-Object { $_.TrimStart().StartsWith('{') }) -join "`n"
        if (-not $json.Trim()) { throw ($lines -join "`n") }
        return ($json | ConvertFrom-Json)
    }

    $bestInfo = $null
    $bestHeight = 0
    $lastErr = $null
    $sets = @(Get-YtdlpCookieArgSets -CookieBrowser $CookieBrowser -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir)
    if ($sets.Count -eq 0) {
        $sets = @([pscustomobject]@{ Args = @() })
    }
    $triedBrowsers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $sets) {
        $argStr = [string[]]$entry.Args -join ' '
        if ($argStr -match '--cookies-from-browser\s+(\S+)') { [void]$triedBrowsers.Add($Matches[1]) }
        try {
            $info = Invoke-Once ([string[]]$entry.Args)
            $h = Get-InfoMaxVideoHeight $info
            Write-BiliDiag -Level 'INFO' -Category 'YTDLP' -Message ("Cookie set [{0}]: maxH={1}" -f ($argStr -replace '^$','(none)'), $h)
            if ($h -gt $bestHeight) { $bestHeight = $h; $bestInfo = $info }
            if ($h -gt 480) { break }
        } catch { $lastErr = $_ }
    }

    # Auto-fallback: when quality is still ≤ 480p, silently retry with the user's real Edge browser
    # cookies, which carry proper 大会员 entitlements even if the in-app WebView2 profile doesn't.
    if ($bestHeight -le 480) {
        foreach ($browser in @('edge', 'chrome', 'firefox')) {
            if ($triedBrowsers.Contains($browser)) { continue }
            [void]$triedBrowsers.Add($browser)
            try {
                Write-BiliDiag -Level 'INFO' -Category 'YTDLP' -Message "Low quality fallback: trying --cookies-from-browser $browser"
                $info = Invoke-Once @('--cookies-from-browser', $browser)
                $h = Get-InfoMaxVideoHeight $info
                Write-BiliDiag -Level 'INFO' -Category 'YTDLP' -Message ("Browser fallback [$browser]: maxH={0}" -f $h)
                if ($h -gt $bestHeight) { $bestHeight = $h; $bestInfo = $info }
                if ($h -gt 480) { break }
            } catch {
                Write-BiliDiag -Level 'WARN' -Category 'YTDLP' -Message ("Browser fallback [$browser] failed: {0}" -f $_.Exception.Message)
            }
        }
    }

    if ($bestInfo) { return $bestInfo }
    if ($lastErr) {
        Write-BiliDiag -Category 'YTDLP' -Message ("Invoke-YtdlpJson fail: {0}" -f $lastErr.Exception.Message)
        throw $lastErr.Exception.Message
    }
    Write-BiliDiag -Category 'YTDLP' -Message 'Invoke-YtdlpJson: no info returned'
    throw '无法获取视频信息。请在本窗口登录 B 站后再试。'
}

function Get-VipTag([string]$Note) {
    if (-not $Note) { return '' }
    if ($Note -match '会员|VIP|vip|付费|专享|高码率|杜比|HDR|4K|8K|1080P\s*高|1080P高|1080P\+') { return ' [会员/高画质]' }
    return ''
}

function Format-SizeLabel($f) {
    if ($f.filesize) { return (' · {0:N1}MB' -f ($f.filesize / 1MB)) }
    if ($f.filesize_approx) { return (' · ~{0:N1}MB' -f ($f.filesize_approx / 1MB)) }
    return ''
}

function Build-FormatOptions {
    param($Info, [bool]$IsLive)
    $list = New-Object System.Collections.Generic.List[object]

    if ($IsLive) {
        $list.Add([pscustomobject]@{ Label = '自动（当前最高）'; Format = 'best[ext=flv]/best/best' })
        foreach ($f in ($Info.formats | Where-Object { $_.format_id -and ($_.url -or $_.manifest_url) } |
            Sort-Object @{ E = { $_.height } }, @{ E = { $_.tbr } } -Descending)) {
            $label = if ($f.height) { '{0}p' -f $f.height } else { $f.format_note }
            if (-not $label) { $label = $f.format_id }
            $list.Add([pscustomobject]@{
                Label  = ('{0}{1} ({2})' -f $label, (Get-VipTag $f.format_note), $f.format_id)
                Format = [string]$f.format_id
            })
        }
        return $list.ToArray()
    }

    $list.Add([pscustomobject]@{ Label = '自动（最高可用）'; Format = 'bestvideo+bestaudio/best' })

    $audios = @($Info.formats | Where-Object {
        $_.format_id -match '^\d' -and $_.acodec -and $_.acodec -ne 'none'
    } | Sort-Object @{ E = { $_.abr } } -Descending)
    $bestAudio = ($audios | Select-Object -First 1).format_id

    $videos = @($Info.formats | Where-Object {
        $_.format_id -match '^\d' -and $_.vcodec -ne 'none' -and ($_.acodec -eq 'none' -or -not $_.acodec) -and $_.height
    })
    $seen = @{}
    foreach ($g in ($videos | Group-Object { [int]$_.height } | Sort-Object Name -Descending)) {
        if ($seen[$g.Name]) { continue }
        $seen[$g.Name] = $true
        $v = $g.Group | Sort-Object tbr -Descending | Select-Object -First 1
        $fmt = if ($bestAudio) { '{0}+{1}' -f $v.format_id, $bestAudio } else {
            'bestvideo[height<={0}]+bestaudio/best[height<={0}]' -f $v.height
        }
        $note = if ($v.format_note) { " · $($v.format_note)" } else { '' }
        $list.Add([pscustomobject]@{
            Label  = ('{0}p{1}{2}{3} ({4})' -f $v.height, (Get-VipTag $v.format_note), $note, (Format-SizeLabel $v), $fmt)
            Format = $fmt
        })
    }

    $uniq = New-Object System.Collections.Generic.List[object]
    $labels = @{}
    foreach ($item in $list) {
        if ($labels.ContainsKey($item.Label)) { continue }
        $labels[$item.Label] = $true
        $uniq.Add($item) | Out-Null
    }
    return $uniq.ToArray()
}

function Show-QualityPicker {
    param([array]$Choices, [string]$Title, [string]$LoginHint)
    if (-not $Choices -or $Choices.Count -eq 0) { throw '没有可用画质' }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '选择画质'
    if ($Title) { $dlg.Text += ' - ' + ($Title.Substring(0, [Math]::Min(40, $Title.Length))) }
    $dlg.Size = New-Object System.Drawing.Size(560, 440)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    $dlg.ShowInTaskbar = $true

    $hint = New-Object System.Windows.Forms.Label
    $hint.Dock = 'Top'
    $hint.Height = 52
    $hint.Text = "  $LoginHint"

    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    foreach ($c in $Choices) { [void]$list.Items.Add($c.Label) }
    $list.SelectedIndex = 0

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Bottom'
    $panel.Height = 44
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '切换到此画质'
    $ok.Location = New-Object System.Drawing.Point(300, 8)
    $ok.Size = New-Object System.Drawing.Size(120, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(430, 8)
    $cancel.Size = New-Object System.Drawing.Size(80, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $panel.Controls.AddRange(@($ok, $cancel))
    $dlg.Controls.Add($list)
    $dlg.Controls.Add($hint)
    $dlg.Controls.Add($panel)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    $list.Add_DoubleClick({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
    $dlg.Add_Shown({
        $dlg.TopMost = $true
        $dlg.Activate()
        $dlg.BringToFront()
    })

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $Choices[$list.SelectedIndex]
}

function Select-BilibiliFormat {
    param(
        [string]$YtdlpExe,
        [string]$MediaUrl,
        [bool]$IsLive,
        [string]$Referer,
        [string]$UserAgent,
        [string]$CookieBrowser,
        [string]$CookiesFile,
        [string]$RuntimeDir
    )
    $info = Invoke-YtdlpJson -YtdlpExe $YtdlpExe -MediaUrl $MediaUrl -Referer $Referer `
        -UserAgent $UserAgent -CookieBrowser $CookieBrowser -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir
    $choices = Build-FormatOptions -Info $info -IsLive:$IsLive
    Write-BiliDiag -Level 'INFO' -Category 'QUALITY' -Message ("Format choices: {0}" -f $choices.Count)
    $maxH = Get-InfoMaxVideoHeight $info
    $cookiePath = Resolve-YtdlpCookiesFile -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir
    $hasSess = [bool]$cookiePath
    $hint = if ($maxH -gt 480) {
        '已识别大会员 Cookie，带 [会员/高画质] 标记的选项可用。'
    } elseif (-not $hasSess) {
        '未导出 SESSDATA。请在本窗口登录 B 站后重试，或在 config.ps1 中设置 $YtdlpCookieBrowser = ''edge''。'
    } else {
        '本应用使用独立浏览器环境，其大会员登录态可能与系统 Edge 不同步。' +
        '请在本窗口内退出后重新登录大会员账号，或在 config.ps1 中设置 $YtdlpCookieBrowser = ''edge'' 直接读取系统 Edge Cookie。'
    }
    $picked = Show-QualityPicker -Choices $choices -Title $info.title -LoginHint $hint
    if (-not $picked) { return $null }
    return [string]$picked.Format
}

function Resolve-StreamUrls {
    param(
        [string]$YtdlpExe,
        [string]$MediaUrl,
        [string]$FormatSpec,
        [string]$Referer,
        [string]$UserAgent,
        [string]$CookieBrowser,
        [string]$CookiesFile,
        [string]$RuntimeDir
    )
    [string]$fmt = $FormatSpec
    [string]$u = Normalize-BiliUrl $MediaUrl
    [string]$ref = if ($Referer) { $Referer } else { $u }
    $base = @('-f', $fmt, '-g', '--no-playlist', '--referer', $ref)
    if ($UserAgent) { $base += @('--user-agent', $UserAgent) }

    $attempts = New-Object System.Collections.Generic.List[object]
    $triedBrowserSets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in (Get-YtdlpCookieArgSets -CookieBrowser $CookieBrowser -CookiesFile $CookiesFile -RuntimeDir $RuntimeDir)) {
        [void]$attempts.Add([pscustomobject]@{ Args = [string[]]$entry.Args })
        $argStr = [string[]]$entry.Args -join ' '
        if ($argStr -match '--cookies-from-browser\s+(\S+)') { [void]$triedBrowserSets.Add($Matches[1]) }
    }
    foreach ($browser in @('edge', 'chrome', 'firefox')) {
        if (-not $triedBrowserSets.Contains($browser)) {
            [void]$attempts.Add([pscustomobject]@{ Args = @('--cookies-from-browser', $browser) })
        }
    }
    [void]$attempts.Add([pscustomobject]@{ Args = @() })

    $lastErr = $null
    foreach ($entry in $attempts) {
        $set = [string[]]$entry.Args
        # cookie args MUST precede `-- URL`, otherwise yt-dlp parses them as extra URLs.
        $allArgs = $base + $set + @('--', $u)
        $output = Invoke-YtdlpExe -YtdlpExe $YtdlpExe -YtdlpArgs $allArgs
        if ($LASTEXITCODE -eq 0) {
            $streams = @($output | Where-Object { $_ -match '^\w+://' })
            if ($streams.Count -gt 0) { return $streams }
        }
        $lastErr = $output -join "`n"
    }
    throw "未能解析播放地址：`n$lastErr"
}

function Invoke-MpvIpc {
    param(
        [string]$PipeName,
        [array]$Command,
        [int]$TimeoutMs = 8000
    )
    $client = $null
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        try {
            $client.Connect($TimeoutMs)
        } catch {
            throw "无法连接 mpv（管道 $PipeName）。请确认 mpv 正在播放。"
        }
        $writer = New-Object System.IO.StreamWriter($client)
        $reader = New-Object System.IO.StreamReader($client)
        $writer.AutoFlush = $true
        $reqId = Get-Random -Minimum 1 -Maximum 999999
        $payload = @{ command = $Command; request_id = $reqId } | ConvertTo-Json -Compress
        $writer.WriteLine($payload)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if ($reader.EndOfStream) { Start-Sleep -Milliseconds 30; continue }
            $line = $reader.ReadLine()
            if (-not $line) { Start-Sleep -Milliseconds 30; continue }
            try {
                $resp = $line | ConvertFrom-Json
                if ($resp.request_id -eq $reqId) { return $resp }
            } catch { }
        }
        return $null
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }
}

function Switch-MpvStreamQuality {
    param(
        [string]$PipeName,
        [string[]]$StreamUrls,
        [string]$Referrer,
        [bool]$IsLive
    )
    if (-not $StreamUrls -or $StreamUrls.Count -eq 0) { throw '没有可用流地址' }

    $pos = $null
    if (-not $IsLive) {
        $timeResp = Invoke-MpvIpc -PipeName $PipeName -Command @('get_property', 'time-pos')
        if ($timeResp -and $null -ne $timeResp.data) {
            $pos = [double]$timeResp.data
        }
    }

    if ($Referrer) {
        [void](Invoke-MpvIpc -PipeName $PipeName -Command @('set_property', 'referrer', $Referrer))
    }

    if ($StreamUrls.Count -ge 2) {
        $loadResp = Invoke-MpvIpc -PipeName $PipeName -Command @('loadfile', $StreamUrls[0], 'replace')
        if ($loadResp -and $loadResp.error -eq 'success') {
            [void](Invoke-MpvIpc -PipeName $PipeName -Command @('audio-add', $StreamUrls[1], 'select'))
        } else {
            throw 'mpv 切换视频流失败，请确认播放器仍在运行。'
        }
    } else {
        $loadResp = Invoke-MpvIpc -PipeName $PipeName -Command @('loadfile', $StreamUrls[0], 'replace')
        if (-not $loadResp -or $loadResp.error -ne 'success') {
            throw 'mpv 切换流失败，请确认播放器仍在运行。'
        }
    }

    if ($null -ne $pos -and $pos -gt 1) {
        Start-Sleep -Milliseconds 600
        [void](Invoke-MpvIpc -PipeName $PipeName -Command @('set_property', 'time-pos', $pos))
    }
}

function Test-MpvNetPath([string]$Path) {
    return ($Path -and $Path -match '(?i)mpvnet\.exe$')
}

function Add-MpvNetLaunchArgs {
    param([string]$MpvExe, [string[]]$MpvArgs)
    if (Test-MpvNetPath $MpvExe) {
        return @('--process-instance=multi') + $MpvArgs
    }
    return $MpvArgs
}

function Add-MpvStreamArgs {
    param([string[]]$MpvArgs, [string[]]$StreamUrls, [string]$Referrer)
    if ($Referrer) { $MpvArgs += ('--referrer={0}' -f $Referrer) }
    if ($StreamUrls.Count -ge 2) {
        $MpvArgs += $StreamUrls[0]
        $MpvArgs += ('--audio-file={0}' -f $StreamUrls[1])
        return $MpvArgs
    }
    $MpvArgs += $StreamUrls[0]
    return $MpvArgs
}
