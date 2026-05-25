# B站 Edge 浏览器 + 流式播放

**当前版本：v1.4** — 历史版本说明见 [VERSIONS.md](./VERSIONS.md)。

内嵌 **Edge WebView2** 浏览 B 站；点播 / 直播链接由 **yt-dlp + mpv** 流式播放（Cookie + Referer，支持大会员高画质）。**v1.4** 起直播可实验性显示弹幕 overlay（尚不完善）。

## 流程（opus 思路）

1. **点击视频** → 立即流式播放（自动最高可用画质，不弹窗）
2. **播放中点「换画质」** → 弹出画质列表 → 通过 mpv IPC 切换流（不重启播放器）
3. 点播切换时会尽量保持当前播放进度

## 大会员高画质

须在本工具浏览窗口 **登录 B 站**（Cookie 须含 `SESSDATA`）。若仍只有 480P：

1. 确认网页端同一视频能选 1080P+/4K
2. 检查 `runtime/bilibili-cookies.txt` 是否有 `SESSDATA`
3. 更新 yt-dlp：`yt-dlp -U`
4. 或在 `config.ps1` 设置 `$DefaultVodFormat` 为大会员优先链

## 启动

双击 **`打开网页.vbs`**，或：

```powershell
.\Open-EdgeWeb.ps1
```

## 依赖

```powershell
winget install yt-dlp.yt-dlp
winget install yt-dlp.FFmpeg
winget install mpv.net
```

## 出错排查

所有错误写入 **`runtime/diag.log`**，格式：

```
[时间] [级别] [分类] [脚本] 消息 | key=value
```

级别：`INFO` / `WARN` / `ERROR` / `DEBUG`。分类：`SESSION`、`COOKIE`、`PLAY`、`QUALITY`、`YTDLP`。

浏览窗口底栏点 **「日志」** 可预览最近 ERROR 并打开完整文件。把日志发给我即可排查。

PowerShell 查看最近日志：

```powershell
. .\Bilibili-Formats.ps1
Set-BiliDiagLogPath .\runtime
Get-BiliDiagRecent -Lines 50
Get-BiliDiagRecent -Category COOKIE -Lines 30
```

## 可选配置

复制 `config.ps1.example` 为 `config.ps1`：

```powershell
$ShowConsole = $true
$DefaultVodFormat = '100029+30280/100026+30280/bestvideo+bestaudio/best'
```
