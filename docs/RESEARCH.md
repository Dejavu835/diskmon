# diskmon 调研报告(精简版)

> 本文件是调研精简版：核心结论 + 关键数据 + 风险。

**调研日期**:2026-09-01 · **作者**:explore fire 1 · **状态**:精简落盘

---

## 0. 摘要(写给主人)

| 维度 | 结论 |
|---|---|
| 推荐栈 | **SwiftUI MenuBarExtra + SwiftData + smartctl 子进程**(原生 mac) |
| 备选 1 | Tauri 2 + Rust + Web 前端(可复用 Homecenter-rebuild 经验) |
| 备选 2 | Python rumps + smartctl(最快验证,1-2 天 PoC) |
| 不推荐 | Electron(80MB+ + 主人审美不喜欢) |
| SMART 取数 | **smartctl 子进程** 唯一靠谱(IOKit 需 entitlement+hardened runtime 工程量翻 3-5 倍) |
| 持久化 | SwiftData(SwiftUI)/ SQLite(Tauri)/ JSONL(rumps) |
| 美学对齐 | 跟 Homecenter 0.5.1 米色 moody 一致(Fraunces + 35mm 噪点 + 0.2.5B 配色) |

---

## 1. 4 种栈对比(关键)

| 维度 | **SwiftUI MenuBarExtra** | **Tauri 2** | **Electron** | **Python rumps** |
|---|---|---|---|---|
| 语言 | Swift 5.9+ | Rust + Web | Node + Chromium | Python 3.x |
| 编译产物 | **< 5MB** ✅(1-3MB) | 3-8MB(边缘) | 80-150MB ❌ | 5-40MB |
| 启动速度 | < 100ms | ~200-400ms | 500ms-2s | 200-500ms |
| 美学契合"克制" | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐ |
| 主人已掌握栈 | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐ | ⭐⭐⭐⭐⭐ |
| IOKit / smartctl 友好 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐ | ⭐⭐ |
| 体积目标 < 5MB | ✅ | ✅(边缘) | ❌ | ⚠️ |
| **总分** | **4.7** | **3.9** | **1.7** | **2.7** |

**结论:SwiftUI 赢。** 体积 1-3MB 远超 < 5MB,美学直接渲米色 moody 不用手工调,IOKit / smartctl Swift 一等公民。

---

## 2. 3 竞品分析

| 维度 | iStat Menus 7.3 | DriveDx 1.12.1 | SMARTReporter(开源) | **diskmon 目标** |
|---|---|---|---|---|
| 体积 | ~50MB+ | ~30MB | < 5MB | **< 5MB** |
| 菜单栏 | 极简 stacked(图标+数字) | 状态条(无数字) | 古典 icon | **温度数字 + SF Symbol** |
| Popover 风格 | 多 section | 主窗口 dashboard | 无 | **moody 配色 + 历史曲线** |
| 温度告警 | 规则引擎 | **多档 pre-fail**(Warning/Failing/Failed) | 基础 | **多档(80/85/90)** |
| 美学契合度 | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐ | **目标 ⭐⭐⭐⭐⭐** |

**关键学习**:
- iStat Menus 的 stacked 模式(图标+温度数字)**是主人菜单栏最熟悉的形态**,学
- DriveDx 的 pre-fail 多档告警**是 SMART 监控的灵魂**,diskmon 必学
- SMARTReporter 太老,**不学**

---

## 3. macOS 读 NVMe SMART 三种方案

| 方案 | 数据完整 | 需 sudo | 实现复杂度 | 性能 | 风险 |
|---|---|---|---|---|---|
| **A. smartctl 子进程**(主推) | ⭐⭐⭐⭐⭐ | 部分 | ⭐ 极低 | 50-200ms | 子进程开销 |
| B. IOKit IOCTL | ⭐⭐⭐ | 否 | ⭐⭐⭐⭐⭐ | < 10ms | entitlement / Hardened Runtime / 沙盒拒 |
| C. diskutil / system_profiler | ⭐(无 SMART 字段) | 否 | ⭐ | 快 | 不可用 |

**选 A**。主人已装 smartctl 7.5,跨桥接 NVMe 成熟,不需 entitlement。

---

## 4. NVMe SMART 关键字段(对主人价值)

| 字段 | 含义 | 主人价值 | UI 表现 |
|---|---|---|---|
| **Temperature** | 当前温度 | ⭐⭐⭐⭐⭐ | **菜单栏图标 + 大读数 + 历史曲线** |
| **Critical Warning** | 8 个 flag(温度/寿命/RO/备份失败) | ⭐⭐⭐⭐⭐ | 顶栏 alert badge |
| **Percentage Used** | 已用寿命 | ⭐⭐⭐⭐⭐ | 进度条 + 数字 |
| **Available Spare** | 备块剩余 | ⭐⭐⭐⭐ | 进度条 + 数字 |
| **Data Units Read/Write** | 累计 TBW | ⭐⭐⭐⭐ | 数字 + 历史 |
| **Power On Hours** | 累计上电小时 | ⭐⭐⭐ | 数字 |
| **Unsafe Shutdowns** | 异常断电 | ⭐⭐⭐⭐(TB4 桥接) | 数字 + 趋势 |
| **Media and Data Integrity Errors** | 介质错误 | ⭐⭐⭐⭐⭐ | **任何 > 0 立即红** |
| **Warning/Critical Comp. Temperature Time** | 临界温度累计 | ⭐⭐⭐ | 数字 |

**告警阈值(参考,fire 2 实测后主人调)**:

| 阈值 | 数值 | 触发 |
|---|---|---|
| 温度警告 | 70-80℃ | 菜单栏变橙 |
| 温度临界 | 80-85℃ | 菜单栏变红 + popover 顶部 alert |
| 温度危险 | ≥ 85℃ | 弹系统通知 |
| Percentage Used 警告 | ≥ 70% | popover 卡片橙色 |
| Percentage Used 危险 | ≥ 90% | 弹通知 |
| Media Errors > 0 | 任何 | **立即红 + 通知** |

---

## 5. 主人审美落地

### 菜单栏图标(候选)

| 候选 | 主人契合 | 推荐 |
|---|---|---|
| `thermometer.sun.fill` + 温度数字(stacked) | ⭐⭐⭐⭐ | ✅ 主推 |
| `internaldrive` + 温度数字 | ⭐⭐⭐ | 备选 |
| 纯文字 `42°` | ⭐⭐⭐⭐⭐ | fallback 状态 |

### Popover 配色(米色 moody 候选 hex,**fire 2 校准**)

| 元素 | 亮色 | 暗色 |
|---|---|---|
| Popover 背景 | `#F5F0E8` | `#1C1A18` |
| 卡片背景 | `#EFE8DD` | `#26221E` |
| 文字主色 | `#2A2520` | `#E8DFD2` |
| 文字次色 | `#7A6F5F` | `#9B8E7C` |
| 强调(正常) | `#C77E4A` | `#C77E4A` |
| 强调(警告) | `#D98C2A` | `#D98C2A` |
| 强调(危险) | `#A83838` | `#A83838` |

> **fire 2 之前需主人在 `Homecenter docs/02-DESIGN-SYSTEM.md` 指认精确 token**

### 字体

- 标题:**Fraunces**(主人硬性偏好),em 用 italic
- 数字读数:**SF Mono / SF Pro Tabular Numbers**(等宽数字)
- 正文:SF Pro

### 视觉细节

- 35mm 噪点(opacity 0.04)
- 圆角 12px(卡片)/ 8px(嵌套)
- 历史曲线 `Path` + `trim` 动画进入
- 暗色下加 vignette(边缘 12% 暗)
- 暗 / 亮跟随系统,@Environment(\.colorScheme)

---

## 6. 工程量估算(主推 SwiftUI)

| 模块 | 工作量 |
|---|---|
| Xcode 工程 + MenuBarExtra 骨架 | 0.5 天 |
| smartctl 子进程 + 解析 | 1 天 |
| SwiftData schema + 历史降采样 | 1 天 |
| Popover UI(温度 + SMART 卡片 + 历史) | 3 天 |
| 告警逻辑(温度 + SMART 多档) | 1 天 |
| 偏好设置(轮询间隔、阈值) | 0.5 天 |
| 公证 + DMG + Sparkle | 1 天 |
| 视觉打磨(米色 moody + Fraunces + 噪点) | 2 天 |
| **总计** | **~10 天** |

---

## 7. 风险(主人需知道)

| 风险 | 影响 | 缓解 |
|---|---|---|
| **macOS 15 Full Disk Access** | smartctl 读 `/dev/diskN` 需 TCC 授权 | 启动后引导用户去 Prefs → Privacy → Full Disk Access |
| **TB4 桥接 NVMe 拔插** | `/dev/diskN` 节点会变 | 用 Volume UUID 持久化(BSD Name) |
| **smartctl 路径** | Apple Silicon `/opt/homebrew/bin/`,Intel `/usr/local/bin/` | 双路径探测 |
| **米色 moody 精确 hex** | 上表 hex 是候选,主人审美为准 | fire 2 之前主人在 Homecenter design system 指认 |
| **Apple docs / Tauri 2 文档站抓不到** | explore 无法引用 API 签名 | fire 2 dev agent 直接在 Xcode / cargo 选 |
| **Apple Silicon smartctl flag** | 内置 SSD 需 `-d sntasus`,外接 NVMe 一般 `-d nvme` | fire 2 跑 `smartctl --scan` 测 |

---

## 8. 引用来源(诚实清单)

| 引用 | 抓取状态 |
|---|---|
| iStat Menus 7.3 产品页 | ✅ 成功 |
| DriveDx 1.12.1 产品页 | ✅ 成功 |
| Wikipedia SMART / IOKit / SMC | ✅ 成功 |
| rumps GitHub(BSD-3, 3.3k stars) | ✅ 成功 |
| Tauri 2 文档站 | ❌ 404 |
| Apple MenuBarExtra docs | ❌ dynamic_page(需 JS) |
| SMARTReporter(volitions) | ❌ network error |
| nvme-cli GitHub | ❌ 404 |

---

## 9. 一行结论

> **SwiftUI MenuBarExtra + SwiftData + smartctl,10 天到 v0.1,体积 1-3MB,美学对标 0.5.1 米色 moody。**

---

**fire 1 done.**
