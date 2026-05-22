#Requires -Version 5.1
<#
.SYNOPSIS
  用本机 Microsoft Edge 以独立应用窗口打开网页（单窗口，使用系统 Edge）。
.EXAMPLE
  .\Open-EdgeWeb.ps1
  .\Open-EdgeWeb.ps1 -Url 'https://www.bilibili.com/video/xxx'
#>
param(
    [string]$Url = 'https://www.bilibili.com',
    [int]$Width = 1280,
    [int]$Height = 800
)

$ErrorActionPreference = 'Stop'

function Get-EdgePath {
    $paths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

if ($Url -notmatch '^\w+://') {
    $Url = "https://$Url"
}

$edge = Get-EdgePath
if (-not $edge) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        '未找到 Microsoft Edge，请先安装 Edge 浏览器。',
        '打开网页',
        'OK',
        'Error') | Out-Null
    exit 1
}

# --app：单窗口应用模式，使用本机 Edge 与用户配置
$args = @(
    "--app=$Url"
    "--window-size=$Width,$Height"
)

Start-Process -FilePath $edge -ArgumentList $args
