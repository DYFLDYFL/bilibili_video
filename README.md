# B站 Edge 浏览器

内嵌 **Edge WebView2** 浏览 B 站，链接在本窗口打开，不会跳转到外部浏览器。

## 点播 / 直播链接

点击视频或直播间链接时**不会打开播放页**，而是把链接追加保存到：

```
saved/links.txt
```

每行格式：`时间<Tab>URL`。工具栏「链接文件」可用记事本查看。

匹配的链接类型：

- `https://www.bilibili.com/video/...`（点播）
- `https://live.bilibili.com/...`（直播）
- `https://www.bilibili.com/blive/...`
- `https://b23.tv/...`（短链）

## 启动

双击 `打开网页.bat`，或：

```powershell
.\Open-EdgeWeb.ps1
.\Open-EdgeWeb.ps1 -Url 'https://www.bilibili.com'
```

首次运行会下载 WebView2 组件到 `tools\webview2\`（需联网）。

## 环境

- Windows 10/11
- 已安装 Microsoft Edge
