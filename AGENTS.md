# diskmon — Agent 工作约定

## 项目

- **栈**:SwiftUI MenuBarExtra + SwiftData + smartctl 子进程(SPM exec,不是 Xcode)
- **目标**:mac 轻量化菜单栏 app,监控外接盘温度 + SMART + 健康度
- **状态**:v4.0.1
- **分发**:`./build_v4.sh` → `dist/v4/diskmon.app`（本地 ad-hoc 签,Gatekeeper 弹窗右键打开）

## 硬规则

- **只做 mac app**:iOS / iPadOS / iPhone / iPad 端**暂不做、不测试、不投入资源**(2026-07-18 主人全局硬规则,这里继承)
- **不写 mock / 占位 / console.log 假装做** — 任何功能必须真跑(连真实 smartctl 解析字段)(2026-06-06 主人产品价值观)
- **不编 LLM/协议名/版本号/数字** — 字段名/阈值全部从真实 `smartctl -a -d nvme /dev/diskN` 输出摘
- **写报告用中文**
- **克制比装饰更高级** — 不堆功能
- **看图不靠 LLM 描述,必 sips 实测像素** — 主人全局硬规则
- **改数据流必须实测 binary** — build 0 错 ≠ 数据流通了(2026-09-01 diskmon fire 3 教训)

## 主人审美

- **高级、克制、电影感**(像 MiniMax / Apple Vision Pro)
- **米色 moody 配色**(bg #F3EBDD / bg-elevated #FAF6EE / bg-sunken #E7DFD0 / fg #1C1917 / amber-500 #D97706 / critical #A83838)
- **暗色主题**(bg #0A0A0B)双套,`@Environment(\.colorScheme)` 自动
- **字体**:
  - 标题 **Fraunces** 衬线 em italic(已嵌 Variable 360K + Italic 414K)
  - 大数字 **SF Mono** `monospacedDigit`
  - 正文 **SF Pro**
- **35mm 胶片噪点 PNG** sigma=35 胶片质感
- **vignette** 暗色专属 RadialGradient 12% 黑
- **圆角** 卡片 12pt / 嵌套 8pt
- **Liquid Glass** 用 `.regularMaterial` 兜底

## 文件树(关键 28 + Resources)

```
diskmon/
├── Package.swift                              # SPM exec,macOS 13+,Bundle ID com.homecenter.diskmon
├── Sources/diskmon/
│   ├── DiskMonApp.swift                       # @main,MenuBarExtra + .modelContainer()
│   ├── Models/
│   │   ├── SmartData.swift                    # 11 NVMe 字段 + 4 档 HealthLevel
│   │   ├── SmartSnapshot.swift
│   │   ├── TemperatureSample.swift             # @Model + 3 级降采样
│   │   └── DiskInfo.swift                     # BSD Name / Volume UUID / MountPoint
│   ├── Services/
│   │   ├── SmartctlPathLocator.swift          # 双路径探测
│   │   ├── SmartctlService.swift              # Process + 11 字段 + 4 退码
│   │   ├── DiskDiscoveryService.swift         # diskutil + /Volumes/ 守卫
│   │   ├── HealthMonitor.swift                # @MainActor @Observable,1s/5s/60s 轮询
│   │   └── NotificationService.swift          # UN + FDA 引导
│   ├── Views/
│   │   ├── MenuBarLabel.swift                 # stacked 温度 + pulse
│   │   ├── PopoverView.swift                  # 3 卡片 stacked
│   │   ├── TemperatureCard.swift              # 56pt monospaced
│   │   ├── SmartCard.swift                    # 11 字段 + emoji + Critical Warning
│   │   ├── HistoryChart.swift                 # Swift Charts + 1H/24H/7D
│   │   ├── DiskPickerView.swift               # 2 盘列表
│   │   ├── NoiseOverlay.swift                 # 35mm tile
│   │   └── PreferencesView.swift              # 3 Tab
│   ├── Storage/{SwiftDataStack,DownSampler,HealthLevel}.swift
│   ├── Utilities/{ByteFormatter,Throttle,FrauncesFont}.swift
│   └── Resources/{Info.plist,diskmon.entitlements,Assets.xcassets,Fonts/}
├── docs/
│   ├── RESEARCH.md                            # 186 行精简调研
│   └── SWIFTUI-SCAFFOLD.md                    # 626 行 SOP
├── AGENTS.md                                  # 本文件
├── README.md                                  # 39 行项目简介
└── dist/                                      # 产物
    ├── diskmon.app
    └── diskmon-0.1.0.dmg
```

## 数据流

```
[DiskDiscovery] diskutil plist 找 /Volumes/* + /Volumes/ 守卫
       ↓
[SmartctlService] /opt/homebrew/bin/smartctl -a -d nvme /dev/diskN
       ↓ 1s 轮询
[HealthMonitor] 解析 11 字段 + 4 档 HealthLevel 判定
       ↓
   ├──→ [MenuBarExtra label] 实时温度 + pulse
   ├──→ [PopoverView] 3 卡片 + 顶栏 DiskPicker
   ├──→ [SwiftData] ~/Library/Application Support/diskmon.store
   └──→ [UNUserNotification] 等级变化触发通知
```

## 关键技术决策(已验证)

| 决策 | 原因 |
|---|---|
| SwiftUI MenuBarExtra | 1-3MB .app,原生 IOKit / smartctl 一等公民 |
| smartctl 子进程 | 唯一靠谱跨桥接 NVMe SMART 路径 |
| Volume UUID 持久化 | TB4 拔插 BSD Name 变化,UUID 稳定 |
| `/Volumes/` 守卫 | macOS 标准外接盘挂载点,busProtocol 字段不准(实测 disk4=PCI-Express) |
| SPM exec + 手工 .app bundle | 不用 Xcode 全家桶,产物 1MB 极致 |
| ad-hoc codesign | 无 Developer ID 时本机可用,公开分发需补 |

## 已完成 fire 队列(2026-09-01)

| Fire | 内容 | 状态 |
|---|---|---|
| 1 explore | 调研 | 完成 |
| 1.5 worker | SOP 626 行 → `docs/SWIFTUI-SCAFFOLD.md` | 完成 |
| 2 worker | SwiftUI 骨架 28 文件 / 336K | 完成 |
| 3 worker(aborted) | 数据流实装(部分完成) | 写 5 个 service 文件但漏 APFS bug |
| 3.5 verifier | 找到 APFS 索引 key 不匹配 bug | 完成 |
| 3.6 worker | 修 APFS 索引(parse 0 → 7 entries) | 完成 |
| 3.7 worker | 修 OSInternal 过滤(7 → 2 UUID) | 完成 |
| 4 worker | 7 View 接真实数据 | 完成 |
| 5 worker | Fraunces 字体 + 35mm PNG + .app + DMG | 完成(公证/Sparkle 需 Apple ID) |
| **6 worker(本任务)** | **写 AGENTS.md** | **本任务** |

## 验证清单(13 项)

| # | 项 | 状态 |
|---|---|---|
| 1 | swift build -c release 0 错 0 警 | ✅ |
| 2 | .app bundle 结构 | ✅ |
| 3 | 启动 .app 进程跑起 | ✅ |
| 4 | 菜单栏 status item 真实渲染 | ✅(CGWindowList 验证) |
| 5 | codesign verify | ✅(ad-hoc) |
| 6 | Gatekeeper | ⚠️ rejected(预期) |
| 7 | DMG hdiutil verify VALID | ✅ |
| 8 | 体积 < 5MB | ✅(binary 1.0MB / .app 2.6MB / .dmg 1.9MB) |
| 9 | quit 干净退出 + 持久化 | ✅ |
| 10 | .app 双击启动 | ✅ |
| 11 | codesign Developer ID | ⚠️ ad-hoc(需 Apple ID) |
| 12 | xcrun notarytool | ⚠️ 跳过(需 Apple ID) |
| 13 | Liquid Glass 兼容 | ✅(`.regularMaterial` 兜底) |

## 风险(主人要知道的)

1. **未公证** — Gatekeeper 弹窗,右键打开,公开分发需 Apple Developer ID($99/年)
2. **35mm 噪点 PNG 嵌** — +0.8MB
3. **未装 Sparkle** — 本地分发够用
4. **Apple Silicon only** — Intel 编译需 `--arch x86_64`
5. **Screencapture 抓不到 NSStatusItem** — macOS 隐私,验证用 CGWindowList

## 重新开发 / 接管指南

1. **写盘前用 `mdfind` 验路径**(路径 typo 是常事)
2. 读 `docs/SWIFTUI-SCAFFOLD.md`(626 行 SOP,代码片段 + 视觉 token + 验证清单)
3. 读 `docs/RESEARCH.md`(186 行调研精简版,4 栈对比 + SMART 字段 + 视觉落地)
4. 跑 `swift build -c release` 验证骨架能编译
5. 跑 `swift run` 验证数据流通(NSLog 应有 parse + discover 循环)
6. 改代码前:实测 `smartctl -a -d nvme /dev/diskN` 摘字段名,不准凭印象
7. 改 UI 前:读 `Homecenter-rebuild/docs/02-DESIGN-SYSTEM.md` 或 `docs/FAMILY-OS-UI-PROPOSALS.md` 拿主人定的精确米色 hex
8. 改数据流:实测 binary 15-30s,验证 NSLog + 副作用文件,不只看 build

## 作者

déjà vu_tao（mian）, Cursor Agent, MiniMax Agent, gorkbuild
