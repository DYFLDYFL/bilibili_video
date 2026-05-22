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
$LinkFile = Join-Path $Root 'runtime\current-link.txt'
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
      || /live\.bilibili\.com\/\d+/i.test(h)
      || /bilibili\.com\/blive\//i.test(h)
      || /b23\.tv\//i.test(h);
  }
  document.addEventListener('click', function(e) {
    var a = e.target.closest('a');
    if (!a || !a.href || !isMedia(a.href)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    chrome.webview.postMessage(JSON.stringify({ type: 'play', url: a.href }));
  }, true);
})();
'@

$form = New-Object System.Windows.Forms.Form
$form.Text = 'B站 - Edge'
$form.Size = New-Object System.Drawing.Size($Width, $Height)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)

$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = 'Top'
$toolbar.Height = 40

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = '<'; $btnBack.Location = New-Object System.Drawing.Point(8, 8)
$btnBack.Size = New-Object System.Drawing.Size(32, 24); $btnBack.Enabled = $false

$btnFwd = New-Object System.Windows.Forms.Button
$btnFwd.Text = '>'; $btnFwd.Location = New-Object System.Drawing.Point(44, 8)
$btnFwd.Size = New-Object System.Drawing.Size(32, 24); $btnFwd.Enabled = $false

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新'; $btnRefresh.Location = New-Object System.Drawing.Point(80, 8)
$btnRefresh.Size = New-Object System.Drawing.Size(52, 24)

$btnHome = New-Object System.Windows.Forms.Button
$btnHome.Text = '首页'; $btnHome.Location = New-Object System.Drawing.Point(136, 8)
$btnHome.Size = New-Object System.Drawing.Size(52, 24)

$address = New-Object System.Windows.Forms.TextBox
$address.Text = $Url
$address.Location = New-Object System.Drawing.Point(200, 8)
$address.Size = New-Object System.Drawing.Size(700, 24)
$address.Anchor = 'Top,Left,Right'

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = '前往'; $btnGo.Size = New-Object System.Drawing.Size(52, 24)
$btnGo.Anchor = 'Top,Right'

$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Bottom'
$status.Height = 24
$status.TextAlign = 'MiddleLeft'
$status.Text = '点播/直播链接将用 mpv 流式播放，不在网页内打开'

$web = [Activator]::CreateInstance([Microsoft.Web.WebView2.WinForms.WebView2])
$web.Dock = 'Fill'

function Set-Status([string]$text) {
    $status.Text = $text
}

function Start-StreamPlay([string]$targetUrl) {
    if (-not (Test-MediaUrl $targetUrl)) { return $false }
    if (-not (Test-Path -LiteralPath $StreamScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            "未找到: $StreamScript", $form.Text, 'OK', 'Error') | Out-Null
        return $true
    }

    try { $uri = ([Uri]$targetUrl).AbsoluteUri } catch { $uri = $targetUrl.Trim() }

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StreamScript, '-Url', $uri
    ) -WorkingDirectory $Root | Out-Null

    Set-Status "正在流式播放: $uri"
    return $true
}

function Navigate-To([string]$target) {
    [string]$t = $target.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return }
    if ($t -notmatch '^\w+://') { $t = "https://$t" }
    if (Start-StreamPlay $t) { return }
    $address.Text = $t
    Set-Status "正在加载: $t"
    if ($null -ne $web.CoreWebView2) {
        $web.CoreWebView2.Navigate($t)
    } else {
        $web.Source = [Uri]$t
    }
}

function Update-Layout {
    $w = $form.ClientSize.Width
    $btnGo.Location = New-Object System.Drawing.Point(($w - 60), 8)
    $address.Width = $w - 280
}
$form.Add_Resize({ Update-Layout })
Update-Layout

$toolbar.Controls.AddRange(@($btnBack, $btnFwd, $btnRefresh, $btnHome, $address, $btnGo))
$form.Controls.Add($toolbar)
$form.Controls.Add($status)
$form.Controls.Add($web)

$btnGo.Add_Click({ Navigate-To $address.Text })
$address.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Navigate-To $address.Text }
})
$btnHome.Add_Click({ Navigate-To 'https://www.bilibili.com' })
$btnRefresh.Add_Click({ $web.Reload() })
$btnBack.Add_Click({ if ($web.CanGoBack) { $web.GoBack() } })
$btnFwd.Add_Click({ if ($web.CanGoForward) { $web.GoForward() } })

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
            if (Start-StreamPlay $navUri) { $ev.Cancel = $true }
        })

        $core.add_NewWindowRequested({
            param($s, $ev)
            $ev.Handled = $true
            [string]$newUri = $ev.Uri
            if (-not (Start-StreamPlay $newUri)) { Navigate-To $newUri }
        })

        $core.add_WebMessageReceived({
            param($s, $ev)
            try {
                $msg = $ev.WebMessageAsJson | ConvertFrom-Json
                if ($msg.url -and ($msg.type -eq 'play' -or $msg.type -eq 'save')) {
                    [void](Start-StreamPlay ([string]$msg.url))
                }
            } catch { }
        })

        $core.add_NavigationCompleted({
            param($s, $ev)
            $btnBack.Enabled = $web.CanGoBack
            $btnFwd.Enabled = $web.CanGoForward
            if ($web.Source) { $address.Text = $web.Source.ToString() }
            if ($ev.IsSuccess) {
                Set-Status '点播/直播链接将用 mpv 流式播放，不在网页内打开'
            } else {
                Set-Status "加载失败 ($($ev.WebErrorStatus))，请点刷新重试"
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
