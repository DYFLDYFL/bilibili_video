# B站 Edge 浏览器 + 流式播放

内嵌 **Edge WebView2** 浏览 B 站首页和列表；**点播 / 直播链接不在网页内打开**，临时记下链接后由 **mpv** 直接流式播放。

## 点击链接时发生什么

1. 拦截视频 / 直播链接（不跳转播放页）
2. 临时写入 `runtime/current-link.txt`（播放结束自动删除）
3. 启动 mpv 边下边播
4. 点新链接时自动关掉上一个 mpv，改播新视频

支持的链接：

- `https://www.bilibili.com/video/...`（点播）
- `https://live.bilibili.com/...`（直播）
- `https://www.bilibili.com/blive/...`
- `https://b23.tv/...`（短链）

**直播计时**：从您开始观看起算（00:00:00），不显示开播以来的总时长；只缓冲最近约 20 秒，之前的画面无法回看。

## 缓冲位置

| 位置 | 说明 |
|------|------|
| 内存 | mpv 播放缓冲，关播放器即释放 |
| `runtime/play-cache/` | 临时分片，退出 / 切换时自动删除 |

## 启动

双击 **`打开网页.vbs`**（无终端黑窗），或：

```powershell
.\Open-EdgeWeb.ps1
.\Open-EdgeWeb.ps1 -Url 'https://www.bilibili.com'
```

首次运行会下载 WebView2 组件到 `tools\webview2\`（需联网）。

## 依赖

```powershell
winget install yt-dlp.yt-dlp
winget install yt-dlp.FFmpeg
winget install mpv.net
```

可选：复制 `config.ps1.example` 为 `config.ps1`，自定义 yt-dlp / mpv 路径。

## 环境

- Windows 10/11
- 已安装 Microsoft Edge
