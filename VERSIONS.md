# 版本说明

本仓库用 **Git 标签（tag）** 和 **发布分支（release branch）** 保留各版本代码，方便以后切换或对比。

| 版本 | 说明 | 标签 | 分支 |
|------|------|------|------|
| **v1.2** | 当前推荐：**直播画质修复** | `v1.2` | `main`、`release/1.2` |
| **v1.1** | 高画质 / 大会员流式 | `v1.1` | `release/1.1` |
| **v1.0** | 历史版：基础流式播放，**无**大会员高画质能力 | `v1.0` | `release/1.0` |

---

## v1.2 — 直播画质修复（当前）

**适用场景：** v1.1 基础上，修复直播换画质失败、画质列表重复 CDN 镜像等问题。

**相比 v1.1 改进：**

- 直播流无 `height` 时，用 **format 数量** 判断 yt-dlp 是否解析成功（不再误判为失败）
- 已有可用结果时 **跳过** 浏览器 Cookie 回退，减少无谓重试与超时
- 直播换画质列表按 `source` / `blue_ray` / `ultra_high_res` 等 **前缀去重**（同画质多 CDN 镜像只显示一项）

**切换到 v1.2：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或固定到标签
git checkout v1.2
```

---

## v1.1 — 高画质版

**适用场景：** 已登录 B 站大会员，希望在 mpv 里自动/手动选 1080P+、4K 等画质。

**相比 v1.0 新增：**

- WebView2 登录态同步到 `runtime/bilibili-cookies.txt`，供 yt-dlp 使用
- 点击视频后 **自动选最高可用画质** 流式播放
- 播放中底栏 **「换画质」**，通过 mpv IPC 切换，不必重启播放器
- 结构化诊断日志 `runtime/diag.log`（底栏 **「日志」** 可预览）
- 公共模块 `Bilibili-Formats.ps1`（Cookie 导出、格式解析、诊断、IPC）
- `Switch-BiliQuality.ps1` 独立换画质脚本

**切换到 v1.1：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或固定到标签
git checkout v1.1
```

---

## v1.0 — 历史版（无大会员流式功能）

**适用场景：** 只需「点链接 → mpv 播放」，不依赖网页登录 Cookie，接受 yt-dlp 默认可用画质（常为 480P）。

**v1.0 能力：**

- Edge WebView2 内嵌浏览 B 站，拦截点播 / 直播链接
- yt-dlp + mpv **流式播放**（不经过浏览器内播放器）
- 全页浏览，无底栏工具条
- 本地 `config.ps1` 可选配置

**v1.0 没有（v1.1 才有）：**

- Cookie 导出与 `SESSDATA` 同步
- 大会员 / 高画质格式链
- 播放中换画质
- `runtime/diag.log` 诊断体系
- `Bilibili-Formats.ps1`、`Switch-BiliQuality.ps1`

**切换到 v1.0：**

```powershell
git fetch origin
git checkout release/1.0
# 或
git checkout v1.0
```

> 切换版本后若行为异常，可删除 `runtime/` 与 `%LOCALAPPDATA%\BilibiliEdge` 后重新打开（见 [UNINSTALL.md](./UNINSTALL.md)）。

---

## 版本对照（速查）

| 功能 | v1.0 | v1.1 | v1.2 |
|------|:----:|:----:|:----:|
| WebView2 浏览 B 站 | ✅ | ✅ | ✅ |
| 点击链接触发 mpv 流式播放 | ✅ | ✅ | ✅ |
| 直播 / 点播 | ✅ | ✅ | ✅ |
| WebView2 Cookie → yt-dlp | ❌ | ✅ | ✅ |
| 大会员高画质（1080P+ / 4K 等） | ❌ | ✅ | ✅ |
| 播放中「换画质」 | ❌ | ✅ | ✅ |
| `runtime/diag.log` 排查 | ❌ | ✅ | ✅ |
| 底栏「换画质」「日志」按钮 | ❌ | ✅ | ✅ |
| 直播换画质（无 height 时可用） | ❌ | ❌ | ✅ |
| 直播画质列表 CDN 去重 | ❌ | ❌ | ✅ |

---

## 在 GitHub 上查看

- 标签列表：<https://github.com/DYFLDYFL/bilibili_video/tags>
- v1.2 代码：`git checkout v1.2` 或分支 `main`
- v1.1 代码：`git checkout v1.1` 或分支 `release/1.1`
- v1.0 代码：`git checkout v1.0` 或分支 `release/1.0`
