# 卸载说明

## 1. 停止所有进程

双击 `关闭 B站缓冲播放.vbs`，或在终端运行：

```powershell
.\Stop-App.ps1
```

也可手动在任务管理器中结束 `yt-dlp.exe`、`bililive-go.exe`、`mpv.exe`。

## 2. 删除项目目录

直接删除整个 `c:\code\video` 文件夹即可。

## 3. 清理缓存和临时文件

```powershell
# 删除视频缓存（默认路径）
Remove-Item "C:\cache\bilibili" -Recurse -Force -ErrorAction SilentlyContinue

# 删除 bililive-go 临时配置（若残留）
Get-ChildItem "$env:TEMP" -Directory -Filter "bililive-go-*" |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
```

## 4. 卸载依赖工具（可选）

```powershell
winget uninstall yt-dlp.yt-dlp
winget uninstall mpv.net
```

bililive-go 为手动安装，直接删除其可执行文件即可。

## 5. 删除 WebView2 SDK（可选）

项目内的 `tools\webview2\*.dll` 随项目目录一起删除即可。  
WebView2 Runtime（随 Edge 安装）无需单独卸载。
