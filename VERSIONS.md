# 版本说明

本仓库用 **Git 标签（tag）** 和 **发布分支（release branch）** 保留各版本代码，方便以后切换或对比。

| 版本 | 说明 | 标签 | 分支 |
|------|------|------|------|
| **v1.4** | 当前：**直播弹幕 overlay 改进** | `v1.4` | `main` |
| **v1.3.3** | 直播弹幕（DeepSeek 部分可用） | `v1.3.3` | `release/1.3.3` |
| **v1.3.2** | 维护补丁（`.gitignore`） | `v1.3.2` | `release/1.3.2` |
| **v1.3.2extra** | 实验归档（弹幕初版，已并入 v1.3.3） | `v1.3.2extra` | `release/1.3.2extra` |
| **v1.3.1** | 忽略 Poe MCP 本地文件 | `v1.3.1` | — |
| **v1.3** | 换画质加速 + 智能 Cookie | `v1.3` | `release/1.3` |
| **v1.2** | 直播画质修复 | `v1.2` | `release/1.2` |
| **v1.1** | 高画质 / 大会员流式 | `v1.1` | `release/1.1` |
| **v1.0** | 历史版：基础流式播放，**无**大会员高画质能力 | `v1.0` | `release/1.0` |

---

## v1.4 — 直播弹幕 overlay 改进（当前）

**适用场景：** v1.3.3 基础上，直播弹幕 **显示更多、跟窗更稳**（仍属实验功能）。

**相比 v1.3.3 改进：**

- overlay：`EnumWindows` 查找 mpv 主窗口，全屏/置顶时周期性重设 `HWND_TOPMOST`
- 启动前最多等 5 秒 mpv 窗口就绪再挂 overlay
- 修复 `listen.js` 弹幕颜色字段、去重、`DANMU_MSG` 事件监听
- 可调 `$DanmakuRate`（秒/条，0=不限制）控制显示密度
- overlay 就绪提示「弹幕已就绪，等待消息…」

**限制：**

- 仍为实验功能，高密度直播间可能卡顿或漏弹幕
- 需 Node.js + `tools/live-danmaku/` 下 `npm install`

**切换到 v1.4：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或
git checkout v1.4
cd tools/live-danmaku && npm install
```

---

## v1.3.3 — 直播弹幕 overlay（DeepSeek 部分可用）

**适用场景：** v1.3.2 基础上，直播 mpv 播放时可显示 **少量弹幕**（实验性，尚不完善）。

**相比 v1.3.2 新增（DeepSeek 修改）：**

- 直播自动启弹幕 sidecar：`Start-LiveDanmaku.ps1` + `Bilibili-DanmakuOverlay.ps1`
- `tools/live-danmaku/listen.js`：Node 拉 B 站直播弹幕，JSONL 与 overlay 通信
- overlay 修复：WinForms 线程异常、mpv 窗口 HWND 重绑、心跳超时检测
- 可调弹幕滚动速度（`$DanmakuSpeed`，默认 10）
- `Get-BiliLiveRoomId`：短号 → 真实 room_id

**限制：**

- **仅能显示部分弹幕**，稳定性/同步/密度均未达可用产品级
- 需 **Node.js**；首次在 `tools/live-danmaku/` 执行 `npm install`
- 仅 **直播**；点播无弹幕

**切换到 v1.3.3：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或
git checkout v1.3.3
cd tools/live-danmaku && npm install
```

---

## v1.3.2extra — 实验归档（弹幕初版）

> 已并入 **v1.3.3**；保留分支供对比初版失败实现。

**状态：** 在 v1.3.2 基础上首次尝试直播弹幕 overlay，**未能正常工作**。

**尝试内容：**

- `Start-LiveDanmaku.ps1` + `Bilibili-DanmakuOverlay.ps1`：Node 拉取直播弹幕 + WinForms 透明悬浮窗叠在 mpv 上
- `tools/live-danmaku/`：`listen.js`（`bilibili-live-danmaku`）经 JSONL 文件与 overlay 通信
- `Start-StreamPlay.ps1`：直播开播后自动启动弹幕 sidecar
- `Get-BiliLiveRoomId`（`Bilibili-Formats.ps1`）：短号解析为真实 `room_id`

**失败 / 未稳定：**

- overlay 与 mpv 窗口跟随、弹幕绘制、WebSocket 连接等未达可用状态
- 依赖 Node.js；需在 `tools/live-danmaku/` 执行 `npm install`

**切换到 v1.3.2extra（仅查阅实验代码）：**

```powershell
git fetch origin
git checkout release/1.3.2extra
# 或
git checkout v1.3.2extra
cd tools/live-danmaku && npm install
```

---

## v1.3.2 — 维护补丁

**适用场景：** 与 v1.3.1 功能相同，仅仓库维护调整。

**相比 v1.3.1 变更：**

- `.gitignore` 改为忽略整个 `tools/`（含 WebView2 SDK 等本地下载内容，避免 IDE 绿点提示）

**切换到 v1.3.2：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或固定到标签
git checkout v1.3.2
```

---

## v1.3.1 — 维护补丁

**适用场景：** 与 v1.3 功能相同，仅仓库维护调整。

**相比 v1.3 变更：**

- `.gitignore` 忽略 `.poe/` 与 `poe-mcp-session.mdc`（个人 Poe 模型调用，与播放项目无关）

**切换到 v1.3.1：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或固定到标签
git checkout v1.3.1
```

---

## v1.3 — 换画质加速 + 智能 Cookie

**适用场景：** v1.2 基础上，减少点播放/换画质时的等待，换画质响应更快。

**相比 v1.2 改进：**

- **智能 Cookie 同步**：15 分钟内已导出 SESSDATA 则直接使用；过期则后台异步刷新；仅首次无 Cookie 时阻塞同步
- **换画质内联执行**：不再启动 `Switch-BiliQuality.ps1` 子进程，主窗口内直接弹窗切流（约 3–10 秒）
- **yt-dlp 解析简化**：首个可用 Cookie 集成功即返回，减少无谓回退
- 画质选择器增加 **登录/大会员提示**（`Get-BiliQualityHint`）
- 防重复点击：换画质进行中忽略重复触发

**切换到 v1.3：**

```powershell
git fetch origin
git checkout main
git pull origin main
# 或固定到标签
git checkout v1.3
```

---

## v1.2 — 直播画质修复

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

| 功能 | v1.0 | v1.1 | v1.2 | v1.3 |
|------|:----:|:----:|:----:|:----:|
| WebView2 浏览 B 站 | ✅ | ✅ | ✅ | ✅ |
| 点击链接触发 mpv 流式播放 | ✅ | ✅ | ✅ | ✅ |
| 直播 / 点播 | ✅ | ✅ | ✅ | ✅ |
| WebView2 Cookie → yt-dlp | ❌ | ✅ | ✅ | ✅ |
| 大会员高画质（1080P+ / 4K 等） | ❌ | ✅ | ✅ | ✅ |
| 播放中「换画质」 | ❌ | ✅ | ✅ | ✅ |
| `runtime/diag.log` 排查 | ❌ | ✅ | ✅ | ✅ |
| 底栏「换画质」「日志」按钮 | ❌ | ✅ | ✅ | ✅ |
| 直播换画质（无 height 时可用） | ❌ | ❌ | ✅ | ✅ |
| 直播画质列表 CDN 去重 | ❌ | ❌ | ✅ | ✅ |
| 智能 Cookie（新鲜度缓存） | ❌ | ❌ | ❌ | ✅ |
| 换画质内联（无子进程） | ❌ | ❌ | ❌ | ✅ |

---

## 在 GitHub 上查看

- 标签列表：<https://github.com/DYFLDYFL/bilibili_video/tags>
- v1.4 代码：`git checkout v1.4` 或分支 `main`
- v1.3.3 代码：`git checkout v1.3.3` 或分支 `release/1.3.3`
- v1.3.2 代码：`git checkout v1.3.2` 或分支 `release/1.3.2`
- v1.3.2extra 初版归档：`git checkout v1.3.2extra` 或分支 `release/1.3.2extra`
- v1.3.1 代码：`git checkout v1.3.1`
- v1.3 代码：`git checkout v1.3` 或分支 `release/1.3`
- v1.2 代码：`git checkout v1.2` 或分支 `release/1.2`
- v1.1 代码：`git checkout v1.1` 或分支 `release/1.1`
- v1.0 代码：`git checkout v1.0` 或分支 `release/1.0`
