#Requires -Version 5.1
<#
.SYNOPSIS
  从当前 Git 标签打包发布 zip（不含 runtime、config.ps1、node_modules、WebView2 SDK）。
.EXAMPLE
  .\Pack-Release.ps1 -Version v1.5
#>
param(
    [Parameter(Mandatory)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$tag = if ($Version -match '^v') { $Version } else { "v$Version" }

git -C $Root rev-parse "$tag^{commit}" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "标签不存在: $tag（请先打 tag 并提交）"
}

$dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zipName = "bilibili_video-$tag.zip"
$zipPath = Join-Path $dist $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Push-Location $Root
try {
    git archive --format=zip --output $zipPath $tag
} finally {
    Pop-Location
}

$sizeMb = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
Write-Host "已打包: $zipPath ($sizeMb MB)"
Write-Host "解压后: 复制 config.ps1.example 为 config.ps1；直播弹幕需在 tools\live-danmaku 执行 npm install"
