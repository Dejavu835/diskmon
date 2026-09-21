# diskmon 独立代码审查

审查对象：https://github.com/Dejavu835/diskmon（注意是 **Dejavu835**，不是 Dejavu845）  
审查基线：`main` @ `506c6e0`（公开仓库标注 4.0.1 / MIT）  
审查日期：2026-09-21  
审查人：独立 Cursor Agent（未参与本仓库的功能实现）  
本机无法编译或运行 macOS App；结论来自源码、测试、打包脚本和仓库文档，不是真机复测。

---

## 1. 产品是干什么的

**中文（白话）**  
DiskMon 是一个只做 Mac 的菜单栏小工具。插上外接硬盘后，它盯这块盘热不热、SMART 健不健康、读写忙不忙。雷电 / USB4 盒子通常能读到真实温度和寿命；很多 USB 桥接盒在 macOS 上读不到 SMART，这时界面会显示「—」，不会假装成 0°C。另外还带格式化、测速、文件系统检查等进阶功能——这些已经超出「只看温度」的范围。

**English (short)**  
A macOS menu-bar app that watches external-disk temperature, SMART, and health. It prefers IOKit, then `smartctl`. USB bridges that cannot pass SMART show an honest dash, not fake 0 °C.

---

## 2. 架构概览

数据大致这样走：

```
diskutil list / NSWorkspace 热插拔
        ↓
DiskDiscoveryService          找 /Volumes 下的外接卷（Volume UUID 当主键）
        ↓
DiskCaptureService            先 IOKit / diskutil 原生 SMART
        ↓
SmartctlService               原生不够时再 spawn smartctl（最少约 30 秒一次）
        ↓
HealthMonitor                 1 秒～1 分钟轮询，算健康等级，写 SwiftData
        ↓
菜单栏温度 / 弹出卡片 / 通知 / 历史曲线
```

仓库分三层：

| 层 | 目录 | 作用 |
|---|---|---|
| 纯逻辑（可测） | `Sources/DiskMonCore/` | 健康规则、SMART 数字换算、格式化命令规划、掉盘判断 |
| 原生 IOKit | `Sources/DiskMonIOKitSMART/` | 不经过 smartctl 读 NVMe / ATA SMART |
| App | `Sources/diskmon/` | SwiftUI 菜单栏、设置、格式化、测速、自检 |

打包走 SPM + `./build_v4.sh`，adhoc 签名，产物在 gitignore 的 `dist/v4/`。测试在 `Tests/DiskMonCoreTests/`（文档称 63 项通过）。没有 CI。

---

## 3. 优点

1. **诚实**。USB 桥读不到 SMART 时显示「—」，并且 README 直接写清 Darwin 做不到 Linux 那种 `sntrealtek` 透传。这是这个项目最值钱的产品判断。
2. **关键数字有测试**。寿命百分比用 ATA 的 Normalized VALUE、Data Units 不会把裸计数当 TB、Critical Warning bit3（只读）会升危险——这些都有单元测试，不是靠印象写的。
3. **格式化有第二道闸**。`FormatPlan` 先规划 argv，再由服务去 spawn；系统盘 / `Macintosh HD` / 根卷会被拒绝；确认词必须等于盘名或 BSD。测试覆盖了「拒绝内置盘」。
4. **4.0.1 采样节制是对的**。同一物理盘多卷只采一次 SMART；`smartctl` 30 秒下限、2.5 秒超时；缺温度不写入 0°C。
5. **身份用 Volume UUID**。Thunderbolt 拔插后 BSD 名会变，这个选择是对的。
6. **体积小、依赖少**。菜单栏原生 App，不套 Electron。

---

## 4. 问题 / 风险 / 缺陷

按严重程度。**安全** 指「会不会伤到用户的盘或电脑」；**正确性** 指「数字/文案会不会说错」；**体验** 指「普通人会不会用错」；**可维护** 指「以后还改不改得动」。

### 安全

| 严重度 | 问题 | 说明 |
|---|---|---|
| 高 | 格式化会擦整块物理盘 | 界面看起来像「这块卷」，实际 `diskutil eraseDisk` 用的是整盘 BSD（例如 `disk4`）。一块外接盘上如果有两个分区，点其中一个就会把整盘清空。 |
| 高 | 「确认」可以一键点出来 | 文案说「输入盘名」，旁边却有按钮直接填入盘名 / BSD。对会误触的人，这几乎等于没有确认。 |
| 中 | 捆绑了 GPL 的 `mkntfs`，源码不在仓库 | `Sources/diskmon/Resources/ntfskit.fs/` 里有约 364KB 的 `mkntfs` 二进制；`vendor/` 被 gitignore。仓库已是 **public + MIT**。GPL-2.0 要求能拿到对应源码。公开分发前这是合规风险，不是风格问题。 |
| 中 | 打包脚本改了 Bundle ID | `build_v4.sh` 把 ID 改成 `com.homecenter.diskmon.v4`，源码 `Info.plist` 仍是 `com.homecenter.diskmon`。设置、SwiftData、登录启动、完整磁盘访问授权会按两个 App 算。 |
| 低 | 权限文件过宽且打包没用上 | `diskmon.entitlements` 开了 JIT、关闭库校验、允许未签名可执行内存。菜单栏读盘工具不该要这些。`build_v4.sh` 的 `codesign` 也没有带上这份文件——死配置，但容易被下次误用。 |
| 低 | 未沙盒、未公证 | 本地自用可接受。公开下载会被 Gatekeeper 拦截，只能右键打开。 |

没有发现 API key、密码或 token 进仓库。

### 正确性

| 严重度 | 问题 | 说明 |
|---|---|---|
| 中 | 通知把 NVMe bit0 说成「温度超阈值」 | NVMe 规范：bit0 = 备用空间低于阈值，bit1 才是温度。健康规则写对了，通知中英文字写错了。用户会按错方向处理。本 PR 已改文案。 |
| 中 | 源码版本还是 0.9.18 | `Info.plist` 是 0.9.18，README / 打包脚本是 4.0.1。`swift run` 的 About 页会显示旧版本。本 PR 已对齐到 4.0.1。 |
| 中 | About 页 GitHub 链到不存在的组织 | `https://github.com/dejavuteam/diskmon`，真实仓库是 `Dejavu835/diskmon`。本 PR 已改。 |
| 低 | 菜单栏 `celsius > 0` 才显示数字 | 0°C 或负数会显示「—」。SSD 很少到 0°C，但逻辑上这是「有读数却藏起来」。 |
| 低 | 通知缺温度时写成 0° | `smart.celsius ?? 0` 会让「危险」通知出现 0°，和「缺温度不写 0」的原则打架。 |
| 低 | `smartctl` 只找两个硬编码路径 | 注释写了「先查 PATH」，代码没有。从终端以外启动的 App 本来 PATH 就短，这还算合理；nix / MacPorts 用户会找不到。本 PR 补了 MacPorts + PATH 回退。 |

### 体验

| 严重度 | 问题 | 说明 |
|---|---|---|
| 高 | 产品已经从「看温度」长成「磁盘工具箱」 | 格式化、NTFS 可写、1GB 测速、SMART 自检、`verifyVolume` 都在弹出层里。对非技术用户，误点格式化的代价远大于多看一个温度。 |
| 中 | 测速会在盘上写约 1GB | 实现是认真的（`F_NOCACHE` / `F_FULLFSYNC`）。进程中途退出可能留下 `.diskmon-bench-*`。没有二次确认「这会磨损寿命」。 |
| 中 | 没有公证、没有自动更新 | 公开推荐下载时，用户会遇到「无法验证开发者」。没有 Sparkle，修 bug 只能口头通知重装。 |
| 低 | 只支持 Apple Silicon + macOS 14+ | README 写了。公开时标题里必须写死，避免 Intel 用户白下。 |
| 低 | 历史库可能涨得很快 | 内部笔记：SwiftData 约 58MB、温度样本十二万行。有降采样，但 raw 行仍在涨。 |

### 可维护

| 严重度 | 问题 | 说明 |
|---|---|---|
| 高 | 单文件过大、注释是施工日志 | `DiskDetailView.swift` 约 3506 行，`HealthMonitor.swift` 约 1397 行。大量「v0.8 polish-L / grok 调研」注释。新人（和下一个 Agent）很难找到现行规则。 |
| 高 | `AGENTS.md` 描述的是旧骨架 | 文件树还是「28 个文件 / fire 6 写 AGENTS.md」，和现在的三层仓库对不上。后续 Agent 会按过期地图施工。 |
| 中 | 文档互相打架 | README 写当前分支是 `v4.0.1-accuracy`，公开默认分支是 `main`。SOP 仍写 macOS 13 / Bundle ID 不带 `.v4`。 |
| 中 | 没有 CI | 测试只在作者 Mac 上跑过。`FormatPlanTests` 里有一条会真调 `diskutil`，Linux / 无 diskutil 的环境会挂。本 PR 用 `#if os(macOS)` 包起来。 |
| 低 | 空目录 `src/` | 只剩 `.gitkeep`，像早期 Tauri 残留。 |

---

## 5. 建议修复顺序

先做会伤数据或说错话的，再做公开分发门槛，最后再收拾仓库。

1. **格式化改成擦「这一卷」，或弹窗写明「整块物理盘、所有分区」**  
   现在 `eraseDisk` + 整盘 BSD。至少警告里点名 `diskN` 上的每一个卷名。确认框去掉「一键填入盘名」按钮，必须手打。
2. **公开分发前处理 GPL**  
   要么把 NTFSKit / ntfs-3g 源码和构建说明放进仓库（或给出稳定地址），要么默认包不带 `mkntfs`，NTFS 格式化改成可选。MIT 主程序可以继续 MIT。
3. **统一 Bundle ID 和版本号**  
   源码、打包脚本、About、登录启动、完整磁盘访问用同一个 `com.homecenter.diskmon` 和 `4.0.1`。不要用 `.v4` 另开一个身份，除非你真的想让新旧 App 并存。
4. **公开下载前做公证，或明确写「仅自己编译」**  
   没有 Apple Developer ID 就不要当正式安装包推。README 现有「右键打开」可以保留，但不要暗示这是普通用户安装方式。
5. **砍或藏进阶功能**  
   默认弹出层只留：温度、健康、SMART、掉盘。格式化 / 测速 / 自检放进设置或单独「专家」页，并加破坏性操作的二次手打确认。
6. **补 CI：`swift test` 在 macOS runner**  
   不要在测试里无条件 spawn `diskutil`。核心解析测试保持纯函数。
7. **重写 `AGENTS.md` 和 README 的「当前文件树」**  
   删掉 fire 队列考古。写清三层目录、真实 Bundle ID、不能 mock、改数据流必须真机验。
8. **拆 `DiskDetailView` / `HealthMonitor`**  
   按页面或服务切开。删掉过期的版本日记注释，只留「为什么」和现行不变量。
9. **通知缺温度时写「—」而不是 0°**；菜单栏不要用 `celsius > 0` 当「无数据」。
10. **历史库设硬上限并验证 DownSampler 真的删 raw**  
    内部已看到 58MB。公开用户挂两块盘跑一个月会抱怨「这个小工具怎么占这么多」。

本 PR 已做的小改（不够解决 1–5，只修明确说错/链错的）：

- About 的 GitHub 地址改为 `Dejavu835/diskmon`
- 源码 `Info.plist` 版本改为 4.0.1
- NVMe bit0 通知改为「备用空间低于阈值」
- `smartctl` 增加 MacPorts 与 PATH 回退
- 依赖 `diskutil` 的测试加上 macOS 条件编译

---

## 6. 能不能对外推广？

**仓库已经是 public。** 这和「能不能当产品推」不是一回事。

| 场景 | 建议 |
|---|---|
| 自己用、朋友要源码、当作品集 | 可以。诚实、有测试、故事清楚。 |
| Product Hunt / 微博 / 给不懂电脑的人下 DMG | **还不行。** 未公证、格式化会擦整盘、确认可一键跳过、GPL 二进制无源码、进阶功能太多。 |
| 开源项目主页（「自己编译，专家工具」） | 可以，但要先改 About 链接、版本号、GPL 说明，并在 README 第一屏写：未公证、会格式化整盘、USB 桥常常没有温度。 |

一句话：**这是一个认真的个人 Mac 工具，还不是可以放心推荐给陌生人安装的产品。**  
先把「擦盘」和「许可证」收住，再谈推广。

---

## 审查范围外

- 没有在 Mac 上启动 `.app`，菜单栏像素、Gatekeeper 弹窗、真盘温度以作者 2026-09-21 笔记为准。
- 没有重跑 `swift test`（当前环境是 Linux）。
- 没有评审视觉稿是否「电影感」——那是审美，不是对错。
