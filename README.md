# Edge 网页窗口

用本机 **Microsoft Edge** 以单窗口（`--app` 模式）打开网页，默认 B 站首页。

## 启动

双击 `打开网页.bat`，或：

```powershell
.\Open-EdgeWeb.ps1
.\Open-EdgeWeb.ps1 -Url 'https://www.bilibili.com'
```

## 说明

- 使用系统已安装的 Edge，共享你的登录状态与扩展（与平时用 Edge 一致）
- 不修改系统设置，不下载额外组件
- 指定其他网址：`-Url 'https://example.com'`
