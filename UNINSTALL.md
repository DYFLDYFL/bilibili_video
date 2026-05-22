# 卸载说明

## 1. 停止播放

关闭 mpv 播放窗口，或在任务管理器中结束 `mpv.exe` / `mpvnet.exe`、`yt-dlp.exe`。

## 2. 删除项目目录

直接删除整个 `c:\code\video` 文件夹即可。

## 3. 清理本地数据（可选）

```powershell
# 播放缓冲与临时链接（正常退出时已自动删除）
Remove-Item "c:\code\video\runtime" -Recurse -Force -ErrorAction SilentlyContinue

# WebView2 用户数据（登录 Cookie 等）
Remove-Item "$env:LOCALAPPDATA\BilibiliEdge" -Recurse -Force -ErrorAction SilentlyContinue
```

## 4. 卸载依赖工具（可选）

```powershell
winget uninstall yt-dlp.yt-dlp
winget uninstall mpv.net
```

## 5. 删除 WebView2 SDK（可选）

项目内的 `tools\webview2\*.dll` 随项目目录一起删除即可。  
WebView2 Runtime（随 Edge 安装）无需单独卸载。
