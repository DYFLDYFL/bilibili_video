#Requires -Version 5.1
<#
.SYNOPSIS
  内嵌 Edge WebView2 浏览 B 站；点播/直播链接不打开网页，临时保存后直接 mpv 流式播放。
#>
param(
    [string]$Url = 'https://www.bilibili.com',
    [int]$Width = 1280,
    [int]$Height = 860
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Tools = Join-Path $Root 'tools\webview2'
$StreamScript = Join-Path $Root 'Start-StreamPlay.ps1'
$SwitchQualityScript = Join-Path $Root 'Switch-BiliQuality.ps1'
$StateFile = Join-Path $Root 'runtime\play-state.json'
$LinkFile = Join-Path $Root 'runtime\current-link.txt'
$AutoCookiesFile = Join-Path $Root 'runtime\bilibili-cookies.txt'
$FormatsScript = Join-Path $Root 'Bilibili-Formats.ps1'
$ConfigPath = Join-Path $Root 'config.ps1'
$YtdlpPath = $null
$YtdlpCookiesFile = $null
$YtdlpCookieBrowser = $null
$YtdlpUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'
$ShowConsole = $false
if (Test-Path -LiteralPath $ConfigPath) { . $ConfigPath }
if (-not $YtdlpCookiesFile) {
    $autoCookie = Join-Path $Root 'runtime\bilibili-cookies.txt'
    if (Test-Path -LiteralPath $autoCookie) { $YtdlpCookiesFile = $autoCookie }
}
if (Test-Path -LiteralPath $FormatsScript) { . $FormatsScript }
New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
if (Get-Command Set-BiliDiagLogPath -ErrorAction SilentlyContinue) {
    Set-BiliDiagLogPath (Join-Path $Root 'runtime')
    Write-BiliDiagSession -ScriptName 'Open-EdgeWeb' -Meta @{ url = $Url }
}
$PkgVer = '1.0.2903.40'
$PkgUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$PkgVer"

function Ensure-WebView2Assemblies {
    $winForms = Join-Path $Tools 'Microsoft.Web.WebView2.WinForms.dll'
    if (Test-Path $winForms) { return }

    Write-Host '首次运行：正在下载 WebView2 组件...'
    New-Item -ItemType Directory -Path $Tools -Force | Out-Null
    $zip = Join-Path $env:TEMP "Microsoft.Web.WebView2.$PkgVer.nupkg.zip"
    Invoke-WebRequest -Uri $PkgUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP 'webview2-nupkg') -Force

    $extracted = Join-Path $env:TEMP 'webview2-nupkg'
    $lib = Get-ChildItem -Path $extracted -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' |
        Where-Object { $_.DirectoryName -match '\\lib\\' } |
        Select-Object -First 1
    if (-not $lib) { throw 'NuGet 包中未找到 WinForms 程序集' }

    Copy-Item (Join-Path $lib.DirectoryName '*') $Tools -Force
    $arch = if ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
    $native = Get-ChildItem -Path $extracted -Recurse -Filter 'WebView2Loader.dll' |
        Where-Object { $_.DirectoryName -match "$arch\\native" } |
        Select-Object -First 1
    if ($native) { Copy-Item $native.FullName $Tools -Force }

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extracted -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-WebView2Tools {
    @(
        'Microsoft.Web.WebView2.Core.dll'
        'Microsoft.Web.WebView2.WinForms.dll'
        'WebView2Loader.dll'
    ) | ForEach-Object {
        $p = Join-Path $Tools $_
        if (-not (Test-Path $p)) {
            throw "缺少组件: $p`n请删除 tools\webview2 文件夹后重新运行以重新下载。"
        }
    }
}

function Initialize-WebView2Environment {
    [string]$userDataFolder = Join-Path $env:LOCALAPPDATA 'BilibiliEdge\WebView2'
    if (-not (Test-Path $userDataFolder)) {
        New-Item -ItemType Directory -Path $userDataFolder -Force | Out-Null
    }

    [string]$loaderFolder = (Resolve-Path -LiteralPath $Tools).Path
    try {
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($loaderFolder)
    } catch { }

    $task = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync(
        '', $userDataFolder, $null)
    return $task.GetAwaiter().GetResult()
}

function Test-MediaUrl([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    try { $u = [Uri]$raw } catch { return $false }
    $h = $u.AbsoluteUri
    return ($h -match 'bilibili\.com/video/' -or
            $h -match 'bilibili\.com/bangumi/play/' -or
            $h -match 'live\.bilibili\.com/\d+' -or
            $h -match 'bilibili\.com/blive/' -or
            $h -match 'b23\.tv/')
}

function Get-ExceptionMessage([Exception]$ex) {
    if ($ex.InnerException) { return Get-ExceptionMessage $ex.InnerException }
    return $ex.Message
}

if ($Url -notmatch '^\w+://') { $Url = "https://$Url" }

Ensure-WebView2Assemblies
Test-WebView2Tools

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Environment]::SetEnvironmentVariable('PATH', "$Tools;$env:PATH", 'Process')
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $Tools 'Microsoft.Web.WebView2.Core.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $Tools 'Microsoft.Web.WebView2.WinForms.dll'))

$script:HookJs = @'
(function() {
  if (window.__biliLinkHook) return;
  window.__biliLinkHook = true;
  function isMedia(h) {
    return /bilibili\.com\/video\//i.test(h)
      || /bilibili\.com\/bangumi\/play\//i.test(h)
      || /live\.bilibili\.com\/\d+/i.test(h)
      || /bilibili\.com\/blive\//i.test(h)
      || /b23\.tv\//i.test(h);
  }
  document.addEventListener('click', function(e) {
    var a = e.target.closest('a');
    if (!a || !a.href || !isMedia(a.href)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    chrome.webview.postMessage({ type: 'play', url: a.href });
  }, true);
})();
'@

$form = New-Object System.Windows.Forms.Form
$form.Text = 'B站 - Edge'
$form.Size = New-Object System.Drawing.Size($Width, $Height)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)

$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Fill'
$status.TextAlign = 'MiddleLeft'
$status.Text = '  点击视频 → mpv 自动播放；播放中点右侧「换画质」'

$btnQuality = New-Object System.Windows.Forms.Button
$btnQuality.Text = '换画质'
$btnQuality.Dock = 'Right'
$btnQuality.Width = 80
$btnQuality.Height = 28
$btnQuality.FlatStyle = 'Standard'

$btnDiag = New-Object System.Windows.Forms.Button
$btnDiag.Text = '日志'
$btnDiag.Dock = 'Right'
$btnDiag.Width = 52
$btnDiag.Height = 28
$btnDiag.FlatStyle = 'Standard'

$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'
$bottom.Height = 28
$bottom.Controls.Add($status)
$bottom.Controls.Add($btnQuality)
$bottom.Controls.Add($btnDiag)

$web = [Activator]::CreateInstance([Microsoft.Web.WebView2.WinForms.WebView2])
$web.Dock = 'Fill'

function Set-Status([string]$text) {
    $status.Text = $text
}

function Get-WebViewMessage($ev) {
    try {
        $raw = $ev.WebMessageAsJson
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $msg = $raw | ConvertFrom-Json
        if ($msg -is [string]) { $msg = $msg | ConvertFrom-Json }
        return $msg
    } catch {
        return $null
    }
}

$script:LastPlayUrl = ''
$script:LastPlayAt = [datetime]::MinValue
$script:LastQualityClick = [datetime]::MinValue
$script:CookieSyncPending = $false
$script:CookieSyncTimer = $null

function Sync-BiliCookiesNow {
    param([int]$TimeoutMs = 4000)
    if ($null -eq $web.CoreWebView2) { return $false }
    if (-not (Get-Command Export-BiliCookiesForPlay -ErrorAction SilentlyContinue)) { return $false }
    $ok = Export-BiliCookiesForPlay -CoreWebView2 $web.CoreWebView2 -OutPath $AutoCookiesFile -TimeoutMs $TimeoutMs
    if ($ok) {
        $script:YtdlpCookiesFile = $AutoCookiesFile
        Write-BiliDiag -Level 'INFO' -Category 'COOKIE' -Message 'Sync-BiliCookiesNow: OK'
    } else {
        Write-BiliDiag -Level 'WARN' -Category 'COOKIE' -Message 'Sync-BiliCookiesNow: failed'
    }
    return $ok
}

function Request-BiliCookieSync {
    if ($null -eq $web.CoreWebView2) { return }
    if ($script:CookieSyncTimer) {
        $script:CookieSyncTimer.Stop()
        $script:CookieSyncTimer.Dispose()
        $script:CookieSyncTimer = $null
    }
    $script:CookieSyncTimer = New-Object System.Windows.Forms.Timer
    $script:CookieSyncTimer.Interval = 600
    $script:CookieSyncTimer.Add_Tick({
        $script:CookieSyncTimer.Stop()
        $script:CookieSyncTimer.Dispose()
        $script:CookieSyncTimer = $null
        if ($script:CookieSyncPending) { return }
        $script:CookieSyncPending = $true
        try {
            [void](Sync-BiliCookiesNow -TimeoutMs 4000)
        } finally {
            $script:CookieSyncPending = $false
        }
    })
    $script:CookieSyncTimer.Start()
}

function Start-StreamPlay([string]$targetUrl) {
    if (-not (Test-MediaUrl $targetUrl)) { return $false }
    if (-not (Test-Path -LiteralPath $StreamScript)) {
        if (Get-Command Show-BiliUserError -ErrorAction SilentlyContinue) {
            Show-BiliUserError -Title '播放失败' -Summary '找不到播放脚本。' -Details @(
                "缺少文件：$StreamScript"
                '请确认项目文件完整，或重新下载本项目。'
            )
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "未找到: $StreamScript", $form.Text, 'OK', 'Error') | Out-Null
        }
        return $true
    }

    try { $uri = ([Uri]$targetUrl).AbsoluteUri } catch { $uri = $targetUrl.Trim() }

    $now = Get-Date
    if ($uri -eq $script:LastPlayUrl -and ($now - $script:LastPlayAt).TotalSeconds -lt 1.5) {
        return $true
    }
    $script:LastPlayUrl = $uri
    $script:LastPlayAt = $now

    Set-Status '  正在同步登录 Cookie…'
    $form.Refresh()
    [void](Sync-BiliCookiesNow -TimeoutMs 3000)

    Write-BiliDiag -Level 'INFO' -Category 'PLAY' -Message "Start stream: $uri"
    $psWindow = if ($ShowConsole) { 'Normal' } else { 'Hidden' }
    Start-Process powershell.exe -WindowStyle $psWindow -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StreamScript, '-Url', $uri
    ) -WorkingDirectory $Root | Out-Null

    Set-Status "正在流式播放: $uri"
    return $true
}

function Switch-CurrentQuality {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        [System.Windows.Forms.MessageBox]::Show(
            '当前没有在播放的视频。请先点击一个视频链接。',
            $form.Text, 'OK', 'Information') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $SwitchQualityScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            "未找到: $SwitchQualityScript", $form.Text, 'OK', 'Error') | Out-Null
        return
    }

    $now = Get-Date
    if (($now - $script:LastQualityClick).TotalSeconds -lt 2) {
        Set-Status '  画质窗口正在打开…'
        return
    }
    $script:LastQualityClick = $now

    Set-Status '  正在获取画质列表…'
    $form.Refresh()

    Set-Status '  正在同步登录 Cookie…'
    $form.Refresh()
    $cookieOk = Sync-BiliCookiesNow -TimeoutMs 5000
    if (-not $cookieOk) {
        $details = Get-CookieExportFailureMessage
        Show-BiliUserError -Title 'Cookie 导出失败' -Summary (
            '未能从本窗口导出 B 站登录 Cookie（SESSDATA），高画质可能不可用。'
        ) -Details $details
    }
    Set-Status '  正在获取画质列表…'
    $form.Refresh()

    Write-BiliDiag -Level 'INFO' -Category 'QUALITY' -Message 'Launch Switch-BiliQuality.ps1'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $SwitchQualityScript
    ) -WorkingDirectory $Root | Out-Null
}

$btnQuality.Add_Click({
    try {
        Switch-CurrentQuality
    } catch {
        if (Get-Command Show-BiliUserError -ErrorAction SilentlyContinue) {
            Show-BiliUserError -Title '换画质' -Summary $_.Exception.Message -Details @(
                '点击底栏「日志」查看详情。'
            )
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message, $form.Text, 'OK', 'Error') | Out-Null
        }
    }
})
$btnDiag.Add_Click({ Open-BiliDiagLog })

function Navigate-To([string]$target) {
    [string]$t = $target.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return }
    if ($t -notmatch '^\w+://') { $t = "https://$t" }
    if (Start-StreamPlay $t) { return }
    if ($null -ne $web.CoreWebView2) {
        $web.CoreWebView2.Navigate($t)
    } else {
        $web.Source = [Uri]$t
    }
}

$form.Controls.Add($bottom)
$form.Controls.Add($web)

$form.Add_Shown({
    $web.Add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if (-not $e.IsSuccess) {
            [System.Windows.Forms.MessageBox]::Show(
                "无法启动 WebView2：`n$(Get-ExceptionMessage $e.InitializationException)",
                $form.Text, 'OK', 'Error') | Out-Null
            $form.Close()
            return
        }

        $core = $web.CoreWebView2
        $core.Settings.IsWebMessageEnabled = $true
        $core.Settings.AreDefaultScriptDialogsEnabled = $true
        $core.Settings.IsStatusBarEnabled = $false
        $core.Settings.UserAgent = (
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'
        )

        $core.add_NavigationStarting({
            param($s, $ev)
            [string]$navUri = $ev.Uri
            if (-not (Test-MediaUrl $navUri)) { return }
            $ev.Cancel = $true
            [void](Start-StreamPlay $navUri)
        })

        $core.add_NewWindowRequested({
            param($s, $ev)
            $ev.Handled = $true
            [string]$newUri = $ev.Uri
            if (-not (Start-StreamPlay $newUri)) { Navigate-To $newUri }
        })

        $core.add_WebMessageReceived({
            param($s, $ev)
            $msg = Get-WebViewMessage $ev
            if ($null -eq $msg) { return }
            if ($msg.url -and $msg.type -eq 'play') {
                [void](Start-StreamPlay ([string]$msg.url))
            }
        })

        $core.add_NavigationCompleted({
            param($s, $ev)
            if ($ev.IsSuccess) {
                if ($ev.Uri -match 'bilibili\.com') {
                    Request-BiliCookieSync
                }
                Set-Status '点击视频 → mpv 自动播放；播放中点右侧「换画质」'
            } else {
                Set-Status "加载失败 ($($ev.WebErrorStatus))"
            }
        })

        Navigate-To $Url
        [void]$core.AddScriptToExecuteOnDocumentCreatedAsync([string]$script:HookJs)
    })

    try {
        $wvEnv = Initialize-WebView2Environment
        [void]$web.EnsureCoreWebView2Async($wvEnv)
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "无法启动 WebView2：`n$(Get-ExceptionMessage $_.Exception)",
            $form.Text, 'OK', 'Error') | Out-Null
        $form.Close()
    }
})

[void][System.Windows.Forms.Application]::Run($form)
