# diskmon — SwiftUI Xcode 工程骨架 SOP

> **目标读者**:fire 2 worker  
> **栈**:SwiftUI MenuBarExtra + SwiftData + smartctl 子进程(macOS 13+)  
> **工程根**:`/Volumes/applelog/diskmon/`  
> **设计基调**:跟 Homecenter 0.5.1 米色 moody 一致,Fraunces 衬线 + 35mm 噪点 + 圆角克制  
> **本文档**:设计 + 步骤 + 关键代码片段,fire 2 按此搭工程;**不是完整代码**

---

## 0. 写给 fire 2 的总览

| 项 | 值 |
|---|---|
| 工程名 | `diskmon` |
| Bundle ID | `com.homecenter.diskmon` |
| 最低部署 | macOS 13.0 Ventura(MenuBarExtra 引入) |
| 推荐最低 | macOS 14.0(SwiftData 稳定 + `.menuBarExtraStyle(.window)`) |
| 工程形态 | **SPM 可执行包 + 手工 .app bundle**(不依赖 Xcode 全家桶) |
| 产物大小目标 | < 5MB(实测 1-3MB) |
| 启动时间目标 | < 100ms |
| 公证 | Hardened Runtime + Developer ID + notarytool |

**为什么不直接用 Xcode `.xcodeproj`**:
- 主人审美"轻量",Xcode 工程文件 1k+ 行 YAML 噪音
- 纯 SPM + `swift build` 一行命令出二进制,CI 友好
- `.app` bundle 用 `cp` + `Info.plist` + `codesign` 自己包,控精度
- SwiftUI 4+ 的 `MenuBarExtra` 0-OC-bridge,纯 Swift 即可

---

## 1. Xcode 工程创建步骤

### 1.1 推荐方式:SPM 可执行 + 手工 .app

```bash
cd /Volumes/applelog/diskmon
swift package init --type executable --name diskmon
# 生成:Package.swift  Sources/diskmon/main.swift(改成 DiskMonApp.swift)
rm Sources/diskman/main.swift  # 占位,后面 @main 替换
mkdir -p Sources/diskmon/{Models,Services,Views,Storage,Resources}
mkdir -p Resources/{Info.plist,diskmon.entitlements,Assets.xcassets}
```

> **注意**:`swift package init` 生成的 `main.swift` 是 SPM 可执行入口,`@main` 结构用 `DiskMonApp.swift` 替代(SPM 允许二者存一,通常删 `main.swift`)。

### 1.2 Package.swift 配置(关键)

```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "diskmon",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "diskmon", targets: ["diskmon"])],
    targets: [.executableTarget(name: "diskmon",
        resources: [.process("Resources")])]
)
```

**说明**:
- `platforms: [.macOS(.v14)]` — SwiftData + `.menuBarExtraStyle(.window)` 需要 14+,主人 mac 15.7.4 满足
- `resources: [.process("Resources")]` — SPM 编译时把 `Info.plist` / `.entitlements` / `.xcassets` 注入 bundle(但 `.entitlements` 实际是 codesign 时用,不是 SPM 资源,见 §6.3)
- 不依赖任何外部 SPM 包,纯 Apple SDK

### 1.3 对比:为什么不用 xcodeproj gem

| 方式 | 优点 | 缺点 |
|---|---|---|
| **SPM exec + 手工 .app** | 一行 build、git diff 干净、CI 简单 | 缺 Xcode IDE 图形调试 |
| `xcodeproj` Ruby gem | 可脚本化生成 .xcodeproj | 1000+ 行 XML,YAML 噪音 |
| 手建 Xcode 工程 | IDE 完美 | 主人审美重,工程文件 commit 不优雅 |
| SwiftPM `.xcodeproj` 自动生成 | Xcode 能开 | fire 2 调试时仍首选 |

**fire 2 调试技巧**:`swift package generate-xcodeproj` 已被 Apple 废弃,改用 `xed Package.swift`(Xcode 14+ 可直接打开 SPM 包做 IDE 调试),release build 仍走 `swift build -c release`。

### 1.4 产物目录约定

```
/Volumes/applelog/diskmon/
├── .build/release/diskmon           # 二进制(SPM 编译产物)
├── .build/release/diskmon.dSYM      # 调试符号
├── build/                           # 手工 .app bundle 暂存(不进 git)
│   └── diskmon.app/
│       ├── Contents/
│       │   ├── MacOS/diskmon        # 拷自 .build/release/diskmon
│       │   ├── Info.plist           # 手工 plist(见 §3.7)
│       │   ├── Resources/           # 字体 / 资产(SPM 抽出来)
│       │   ├── PkgInfo              # "APPL????"(8 字节)
│       │   └── _CodeSignature/      # codesign 生成
└── dist/                            # 公证产物 DMG(不进 git)
```

---

## 2. 文件树(完整 + 职责)

```
/Volumes/applelog/diskmon/
├── Package.swift                                 # SPM 清单(见 §1.2)
├── README.md                                     # 已存在,保留
├── docs/
│   ├── RESEARCH.md                               # 已存在
│   └── SWIFTUI-SCAFFOLD.md                       # 本文档
├── .github/                                      # CI 预留(预创建,空)
│   └── workflows/
│       └── release.yml                           # 预留 fire 5 填
├── src/                                          # ⚠️ 预创建但空,fire 2 不动它
│   └── .gitkeep
├── Sources/diskmon/                              # fire 2 创建
│   ├── DiskMonApp.swift                          # @main 入口 + MenuBarExtra 场景
│   ├── Models/
│   │   ├── SmartData.swift                       # SMART 字段 struct + 解析逻辑
│   │   ├── TemperatureSample.swift               # @Model 单点温度样本
│   │   └── DiskInfo.swift                        # BSD Name / Volume UUID / 挂载点
│   ├── Services/
│   │   ├── SmartctlService.swift                 # Process 子进程封装 + 解析
│   │   ├── DiskDiscoveryService.swift            # diskutil 探测 + Volume UUID 持久化
│   │   ├── HealthMonitor.swift                   # @MainActor ObservableObject 调度
│   │   ├── NotificationService.swift             # UNUserNotificationCenter 封装
│   │   └── SmartctlPathLocator.swift             # 双路径探测(/opt/homebrew + /usr/local)
│   ├── Views/
│   │   ├── MenuBarLabel.swift                    # 菜单栏图标 + 温度数字(stacked)
│   │   ├── PopoverView.swift                     # 主 popover 容器 + 顶栏
│   │   ├── TemperatureCard.swift                 # 大读数 + 临界告警
│   │   ├── SmartCard.swift                       # SMART 全字段卡片
│   │   ├── HistoryChart.swift                    # Swift Charts 折线图 + trim 动画
│   │   ├── DiskPickerView.swift                  # 多盘选择下拉
│   │   ├── NoiseOverlay.swift                    # 35mm 噪点 + vignette(全局)
│   │   └── PreferencesView.swift                 # Settings 窗口(独立 Scene)
│   ├── Storage/
│   │   ├── SwiftDataStack.swift                  # ModelContainer 工厂 + 降采样
│   │   ├── DownSampler.swift                     # 1秒→1分→1小时 聚合
│   │   └── HealthLevel.swift                     # 告警等级 enum(.normal/.warning/.critical/.danger)
│   ├── Resources/
│   │   ├── Info.plist                            # 手工 plist(见 §3.7)
│   │   ├── diskmon.entitlements                  # 关闭沙盒 + Hardened Runtime
│   │   ├── Assets.xcassets/                      # 菜单栏 icon 1x/2x/3x + 配色 token
│   │   │   ├── Contents.json
│   │   │   └── AppIcon.appiconset/
│   │   └── Fonts/                                # Fraunces Variable(.ttf)预留,fire 5 填
│   └── Utilities/
│       ├── ByteFormatter.swift                   # TBW / Power On Hours 格式化
│       └── Throttle.swift                        # 轮询节流(避免主线程)
└── .gitignore                                    # 已存在(.build/ / .app / .dSYM 已含)
```

**职责关键点**:
- `DiskMonApp.swift` 只做 Scene 组装,**不写业务逻辑**
- `Services/*` 是 actor 或 @MainActor 类,负责 IO / 子进程 / 调度
- `Views/*` 纯 SwiftUI 视图,从 `HealthMonitor` 读 `@Published` / `@Observable`
- `Storage/*` SwiftData 持久化,对外只暴露 `ModelContainer` + 增删查
- `Utilities/*` 纯函数,无副作用,易测

---

## 3. 关键代码片段(每段 ≤ 20 行)

### 3.1 MenuBarExtra 入口(@main)

```swift
import SwiftUI
@main
struct DiskMonApp: App {
    @State private var monitor = HealthMonitor()
    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
        Settings { PreferencesView().environment(monitor) }
    }
}
```

**要点**:
- `MenuBarExtra` 是 macOS 13+ API,`@main` 替代 `AppDelegate`/`NSApplicationDelegate`
- `.menuBarExtraStyle(.window)` 给 popover 加毛玻璃 + 圆角,默认 `.menu` 是下拉式(本项目不用)
- `Settings` Scene 自动挂到 ⌘, 菜单(无需手动代码)

### 3.2 smartctl 子进程调用(Process API)

```swift
import Foundation
actor SmartctlService {
    func read(device: String) async throws -> String {
        let path = SmartctlPathLocator.resolve()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-a", "-d", "nvme", device]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw SmartctlError.exit(proc.terminationStatus) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

**smartctl 退码含义**:
| 退码 | 含义 | 处理 |
|---|---|---|
| 0 | OK | 解析 stdout |
| 1 | SMART warning | 解析 + 标记 warning |
| 2 | SMART pre-fail | 解析 + 标记 critical |
| **251** | **权限不足(FDA 缺失)** | **弹引导:去 Prefs → Privacy → Full Disk Access** |
| 其他 | 子进程错 | log + 重试 3 次,放弃 |

### 3.3 diskutil 探测外接盘

```swift
import Foundation
actor DiskDiscoveryService {
    func listDisks() async throws -> [DiskInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["list", "-plist"]
        let pipe = Pipe(); proc.standardOutput = pipe
        try proc.run(); proc.waitUntilExit()
        let plist = try PropertyListSerialization
            .propertyList(from: pipe.fileHandleForReading.readDataToEndOfFile(),
                          format: nil) as! [String: Any]
        return parse(plist: plist)  // 抽 AllDisksAndPartitions → [DiskInfo]
    }
}
```

**解析 plist 路径**:
```
Root dict
  └─ "AllDisksAndPartitions" → [arr]
       └─ "Disks" → [arr of dict]
            ├─ "DeviceIdentifier": "disk5"  ← BSD Name
            ├─ "VolumeUUID": "5A8E..."      ← 持久化键
            └─ "Partitions" → [arr]
                 └─ "MountPoint": "/Volumes/applelog"
```

**持久化策略**:
- 启动时读 `~/Library/Application Support/diskmon/watched-volumes.json`
- 存的是 Volume UUID,**不是** BSD Name(因 TB4 拔插 BSD Name 会变)
- 每次轮询 `diskutil list`,UUID 命中 → 拿当前 BSD Name
- 5s 轮询一次,BSD Name 变了自动重绑(无感)

### 3.4 SwiftData schema(降采样)

```swift
import SwiftData
@Model final class TemperatureSample {
    @Attribute(.unique) var id: UUID
    var diskUUID: String       // 哪个盘(Volume UUID,不是 BSD Name)
    var timestamp: Date
    var celsius: Double
    var granularity: String    // "raw" / "minute" / "hour"
    init(diskUUID: String, celsius: Double, granularity: String) {
        self.id = UUID(); self.diskUUID = diskUUID
        self.timestamp = .now; self.celsius = celsius; self.granularity = granularity
    }
}
```

**ModelContainer 配**:
```swift
let schema = Schema([TemperatureSample.self /* + SmartSnapshot 后续 */])
let config = ModelConfiguration(
    "diskmon", schema: schema,
    isStoredInMemoryOnly: false,
    allowsSave: true,
    cloudKitDatabase: .none   // 本地,不上云
)
let container = try ModelContainer(for: schema, configurations: config)
```

**降采样规则**(写在 `DownSampler.swift`):
| 输入 | 输出 | 保留期 |
|---|---|---|
| 1s raw(实时轮询) | 1个 | 7 天 |
| 1 分聚合(1min mean/min/max) | 1个 | 30 天 |
| 1 小时聚合 | 1个 | 1 年 |

`@Attribute(.unique)` 索引在 `(diskUUID, timestamp, granularity)`,查询 `WHERE diskUUID = ? AND timestamp BETWEEN ? AND ? AND granularity = ?`。

### 3.5 MenuBarExtra 标签(温度 + 图标,stacked)

```swift
struct MenuBarLabel: View {
    @Bindable var monitor: HealthMonitor
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            Text("\(Int(monitor.currentTemp))°")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(monitor.healthLevel.color)
        .symbolEffect(.pulse, options: .repeating,
                      isActive: monitor.healthLevel == .danger)
    }
    private var iconName: String { monitor.healthLevel == .danger
        ? "thermometer.sun.fill" : "thermometer.medium" }
}
```

**栈级切换**:
- < 70℃:灰色 `thermometer.medium`
- 70-80℃:橙色
- 80-85℃:红色
- ≥ 85℃:红色 + `pulse` 动效(系统级 .symbolEffect,无需自写)

### 3.6 告警逻辑(HealthLevel)

```swift
enum HealthLevel: String, Codable { case normal, warning, critical, danger
    var color: Color {
        switch self {
        case .normal: .dsNormal    // #C77E4A(暖灰)
        case .warning: .dsWarning  // #D98C2A
        case .critical: .dsCritical// #A83838
        case .danger: .dsDanger    // #A83838 + pulse
        }
    }
}
func evaluate(smart: SmartData) -> HealthLevel {
    if smart.mediaErrors > 0 { return .danger }
    if smart.percentageUsed >= 90 { return .critical }
    if smart.celsius >= 85 { return .danger }
    if smart.celsius >= 80 { return .critical }
    if smart.celsius >= 70 || smart.percentageUsed >= 70 { return .warning }
    return .normal
}
```

**UserNotifications 触发**(写在 `NotificationService.swift`):
- 等级变化才发,不重复
- `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` 启动时弹一次
- 走 `UNNotificationRequest` 异步投递,`UNMutableNotificationContent` body 含盘名 + 字段

### 3.7 entitlements + Info.plist

**`diskmon.entitlements`**(关沙盒 + 开 Hardened Runtime):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key>
  <false/>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
</dict></plist>
```

**为什么关沙盒**:
- smartctl `/dev/diskN` 是裸设备 IO,沙盒拒
- IOKit `IOServiceMatching("IONVMeBlockStorageDevice")` 在沙盒外才好用
- 走 Hardened Runtime(`--options=runtime`)+ 公证即可保证安全,不需要沙盒

**`Info.plist`** 关键字段:
```xml
<key>CFBundleIdentifier</key>          <string>com.homecenter.diskmon</string>
<key>CFBundleName</key>                <string>diskmon</string>
<key>CFBundleDisplayName</key>         <string>DiskMon</string>
<key>CFBundleExecutable</key>          <string>diskmon</string>
<key>CFBundleVersion</key>             <string>0.1.0</string>
<key>CFBundleShortVersionString</key>  <string>0.1.0</string>
<key>CFBundlePackageType</key>         <string>APPL</string>
<key>LSMinimumSystemVersion</key>      <string>14.0</string>
<key>LSUIElement</key>                 <true/>   <!-- 不在 Dock 显示 -->
<key>NSHighResolutionCapable</key>     <true/>
```

**`LSUIElement` 必为 `true`**:菜单栏 app,无主窗口,不在 Dock 出现。

---

## 4. 数据流(ASCII)

```
[启动] → DiskMonApp @main
    │
    ├─→ SmartctlPathLocator.resolve()
    │       ↓ /opt/homebrew/bin/smartctl 或 /usr/local/bin/smartctl
    │
    ├─→ DiskDiscoveryService.listDisks()  (5s 轮询)
    │       ↓ diskutil list -plist → [DiskInfo]
    │       ↓ Volume UUID 持久化比对 → 当前 BSD Name
    │       ↓ 写回 ~/Library/Application Support/diskmon/watched-volumes.json
    │
    ├─→ HealthMonitor.start()  (1s 轮询)
    │       ├─ 对每块 watched disk:
    │       │   SmartctlService.read(device: BSD Name)
    │       │       ↓ Process 子进程 50-200ms
    │       │       ↓ stdout 解析 → SmartData struct
    │       │       ↓ 退码 251? → 触发 Full Disk Access 引导弹窗
    │       │
    │       ├─ evaluate(smart:) → HealthLevel
    │       ├─ 等级变化? → NotificationService.send()
    │       ├─ 写 SwiftData TemperatureSample(granularity: "raw")
    │       └─ 触发 DownSampler.run()  (60s 一次,聚合 raw→minute→hour)
    │
    ├─→ @Published / @Observable 推送变化
    │       ├─→ MenuBarLabel: 实时温度数字
    │       ├─→ PopoverView: 卡片刷新(温度 / SMART / 曲线)
    │       └─→ HistoryChart: Swift Charts 重绘
    │
    └─→ MenuBarExtra 一直显示在系统菜单栏
            ↓ 点击
            PopoverView 出现(用户能看到历史/详情)
            ↓ 点 ⌘,
            PreferencesView 出现(轮询间隔/阈值/已监控盘)
```

**关键不变量**:
- `HealthMonitor` 是唯一真相源(Single Source of Truth)
- 所有 View `@Bindable var monitor: HealthMonitor`,无自管 state
- SwiftData 只在 `HealthMonitor` 内部写,View 只读

---

## 5. 视觉落地 checklist(待 fire 2 校准)

> ⚠️ 以下 hex / 字号是 **RESEARCH.md §5 候选值**,fire 2 写代码前**先读** `Homecenter/docs/02-DESIGN-SYSTEM.md` 拿精确 token,以那个为准。

### 5.1 配色 token(写入 `Assets.xcassets`)

| 元素 | 亮色 hex | 暗色 hex | 用途 |
|---|---|---|---|
| 背景主 | `#F5F0E8` | `#1C1A18` | Popover 底 |
| 背景卡片 | `#EFE8DD` | `#26221E` | `TemperatureCard` / `SmartCard` |
| 文字主 | `#2A2520` | `#E8DFD2` | 标题 / 大读数 |
| 文字次 | `#7A6F5F` | `#9B8E7C` | 副标 / 单位 |
| 分隔线 | `#DCD2C0` | `#322E2A` | card 间 |
| 强调(正常) | `#C77E4A` | `#C77E4A` | 数字 / 正常状态 |
| 警告 | `#D98C2A` | `#D98C2A` | 70-80℃ / Used 70%+ |
| 危险 | `#A83838` | `#A83838` | ≥ 85℃ / Media Errors > 0 |
| 成功 | `#7A8F5C` | `#7A8F5C` | 健康度良好 badge |

**xcassets 写法**(`Assets.xcassets/Contents.json` + 一组 `colorset/`,每个 `colorset/Contents.json` 含 `Appearance: "luminosity"` two `color` 块)。

### 5.2 字体

| 元素 | 字体 | 字号 | 备注 |
|---|---|---|---|
| 大读数(温度) | SF Pro / Tabular | 56pt bold | monospacedDigit() |
| 菜单栏数字 | SF Mono | 13pt medium | 必须 tabular |
| 卡片标题 | **Fraunces** | 18pt | em 用 italic |
| 卡片副标 | SF Pro | 13pt regular | |
| SMART 字段键 | SF Mono | 12pt | |
| SMART 字段值 | SF Mono | 12pt bold | tabular 对齐 |
| 正文 | SF Pro | 14pt | |

**Fraunces 加载**:`Sources/diskmon/Resources/Fonts/Fraunces-Variable.ttf` 拖入,在 `Info.plist` 加 `ATSApplicationFontsPath` 数组(SPM bundle 资源路径,fire 5 视觉阶段补)。

### 5.3 视觉细节

```swift
// NoiseOverlay.swift(关键)
struct NoiseOverlay: View {
    var body: some View {
        Image("35mm")           // PNG 35mm 噪点纹理 256x256 tile
            .resizable(resizingMode: .tile)
            .opacity(0.04)
            .allowsHitTesting(false)
            .blendMode(.overlay)
    }
}
```
- **35mm 噪点** PNG 256×256 平铺,opacity 0.04,`.blendMode(.overlay)`(亮/暗都自然)
- **vignette** 暗色专属,边缘 `RadialGradient` 12% 暗
- **圆角**:`RoundedRectangle(cornerRadius: 12)` 卡片 / 8 嵌套
- **历史曲线动画**:`Path.trim(from: 0, to: animateValue).animation(.easeInOut(duration: 0.6), value: animateValue)`
- **Liquid Glass 兼容**:macOS 26+ 有原生 glass,fire 2 暂用 `.regularMaterial` 兜底
- **colorScheme**:`@Environment(\.colorScheme)` 切换 token,写一份双套

---

## 6. 编译 + 公证 SOP

### 6.1 命令行 build

```bash
cd /Volumes/applelog/diskmon
swift build -c release --arch arm64 --arch x86_64
# 产物:.build/release/diskmon(universal binary,~1.2MB)
file .build/release/diskmon  # 确认 Mach-O universal
```

### 6.2 手工打 .app bundle

```bash
APP=/Volumes/applelog/diskmon/build/diskmon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/diskmon "$APP/Contents/MacOS/"
cp Sources/diskmon/Resources/Info.plist "$APP/Contents/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"   # 8 字节
# 把 SPM Resources 抽到 .app/Contents/Resources
cp -R .build/release/diskmon_diskmon.bundle/* "$APP/Contents/Resources/"
# 写 _CodeSignature 之前先 codesign
```

> **SPM bundle 路径**:`.build/release/<PackageName>_<TargetName>.bundle`(含 Info.plist + 资源),fire 2 实测后可能要改 `diskmon_diskmon.bundle` 这个名字。

### 6.3 公证 + 签名

```bash
# 1. 签名
codesign --deep --force --options=runtime \
  --entitlements Sources/diskmon/Resources/diskmon.entitlements \
  --sign "Developer ID Application: <你的名字> (TEAMID)" \
  "$APP"
# 2. 验签
codesign -dv --verbose=4 "$APP"
# 3. 打 DMG
hdiutil create -volname DiskMon -srcfolder "$APP" -ov -format UDZO dist/diskmon.dmg
# 4. 提交公证
xcrun notarytool submit dist/diskmon.dmg \
  --keychain-profile "diskmon-notary" --wait
# 5. 装订 ticket
xcrun stapler staple dist/diskmon.dmg
```

**keychain-profile 准备**(只需一次):
```bash
xcrun notarytool store-credentials "diskmon-notary" \
  --apple-id "you@homecenter.cn" --team-id "TEAMID" \
  --password "app-specific-password"
```

### 6.4 Sparkle 集成(fire 5 阶段)

- 仓库:`https://github.com/sparkle-project/Sparkle`(SPM 集成,2.6+ SwiftUI-friendly)
- `Package.swift` 加 `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")`
- 启动时 `SPUUpdater.shared()`,调 `.checkForUpdates()`
- appcast.xml 放 `~/Library/Application Support/diskmon/appcast.xml` 或 GitHub Pages
- ⚠️ fire 2 骨架阶段**不集成**,等 v0.1 走通后再加

---

## 7. 验证清单(收尾 fire 2 自检)

- [ ] `swift build -c release` 0 错 0 警
- [ ] `swift run` 启动,菜单栏出现 `thermometer.medium` + 温度数字
- [ ] 第一次启动检测到 `applelog`,Volume UUID 写入 watched-volumes.json
- [ ] `smartctl -a -d nvme /dev/disk5` 解析无错(用真实主盘测)
- [ ] Full Disk Access 缺失时,退码 251 → 弹引导(系统 Prefs 链接)
- [ ] 温度 70℃ 触发橙色 / 80℃ 触发红色 / 85℃ 触发 pulse + 系统通知
- [ ] `diskutil list` 拔盘再插,BSD Name 变化,UUID 命中自动重绑
- [ ] SwiftData 写入 `~/Library/Containers/.../Data/Library/Application Support/diskmon.store`
- [ ] `du -sh .build/release/diskmon` < 5MB
- [ ] `.app` 双击启动,菜单栏图标出现,⌘Q 干净退出
- [ ] `codesign -dv` 显示 Developer ID + Hardened Runtime
- [ ] `xcrun notarytool submit` 公证通过(首次约 2-5 min)
- [ ] Liquid Glass 检查:popover 背景在 Sonoma+ 正确显示毛玻璃

**实测 SOP**(fire 2 必跑):
```bash
# 0. 路径
which smartctl  # 应 /opt/homebrew/bin/smartctl
ls -la /dev/disk5  # 主盘 /dev/diskN
# 1. 手工验证
/opt/homebrew/bin/smartctl -a -d nvme /dev/disk5 | head -40
# 2. 看 Critical Warning / Temperature / Percentage Used / Media Errors
# 3. 把字段名记下来,fire 3 解析用
```

---

## 8. fire 2 不要做的事(边界)

- ❌ 不要引入 CocoaPods / Carthage
- ❌ 不要用 SwiftUI 5(未发布,`@Observable` Swift 5.9+ 已够)
- ❌ 不要装 第三方 SMART 解析库(`IORegistryEntry` 自写比依赖稳)
- ❌ 不要做单元测试工程(本项目手测 + 公证通过为准,v0.2 再加)
- ❌ 不要集成 Sparkle(留给 fire 5)
- ❌ 不要关掉 `.menuBarExtraStyle(.window)`(默认 .menu 是下拉式,主人审美不要)
- ❌ 不要写完整 `HistoryChart` 数据(fire 2 只搭骨架,fire 3 填数据源)
- ❌ 不要做主窗口(`WindowGroup`),菜单栏 app 只能 `MenuBarExtra` + `Settings`

---

## 9. 风险(主推栈已知问题)

| 风险 | 影响 | 缓解 |
|---|---|---|
| **Full Disk Access** 缺失 | smartctl 退码 251,读不出数据 | 启动检测 + 系统 Prefs 引导 |
| **TB4 拔插** BSD Name 变化 | 监控中断 | Volume UUID 持久化(§3.3) |
| **smartctl 路径** Apple Silicon vs Intel | 二进制找不到 | `SmartctlPathLocator` 双路径探测 |
| **Apple Silicon NVMe flag** | 内置需 `-d sntasus`,外接 `-d nvme` | fire 2 `smartctl --scan` 跑一次记结果 |
| **moody hex 精确 token** | RESEARCH 是候选,主人审美为准 | fire 2 之前读 Homecenter 02-DESIGN-SYSTEM.md |
| **Sandbox 关闭** 公证更严 | Hardened Runtime 必开 + 全 entitlement 声明 | `--options=runtime` + entitlements 文件(§3.7) |
| **MenuBarExtra 频繁刷新** | 菜单栏闪烁 | 节流 1s + 仅温度变化 ≥ 0.5℃ 才刷 |

---

## 10. fire 2 → fire 3 交接

fire 2 完成后应产出:
1. `/Volumes/applelog/diskmon/Package.swift`(§1.2)
2. `Sources/diskmon/DiskMonApp.swift` 入口(§3.1)
3. `Sources/diskmon/Services/SmartctlPathLocator.swift`(可空实现,fire 3 填)
4. `Sources/diskmon/Resources/Info.plist`(§3.7)
5. `Sources/diskmon/Resources/diskmon.entitlements`(§3.7)
6. 验证清单(§7)全绿

fire 3 接力:
- `SmartctlService` 真实解析(`--scan` 测 + 正则 / line scanner)
- `HealthMonitor` 调度
- `DiskDiscoveryService` 真实 plist 解析
- SwiftData 真实写入

---

**SOP 完。** fire 2 按 §1 → §2 → §3 → §6.1 → §7 顺序执行,每天 1 次进度回报。  
主人拍板栈后开火,本 SOP 假设栈已选 SwiftUI 主推方案。
