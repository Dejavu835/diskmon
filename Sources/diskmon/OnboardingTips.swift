import SwiftUI
import TipKit
import Foundation

// v0.9.3 minimax-C: TipKit 5 步 onboarding (macOS 14+ 真实首次启动教程)
// ============================================================================
// grok 2 调研(已确认):
//   - macOS 14+ 用 TipKit:`Tips.configure()` 在 `App.init` + `Tip` + `TipView` / `popoverTip`
//   - macOS 15+ 有 `TipGroup` class(但只是 priority wrapper,不是 protocol);
//     本实装 5 步走自己的"step index"逻辑 + 5 个独立 Tip struct,避免绑定 macOS 15+
//   - in-popover intro(在 MenuBarExtra 内)— 不要 modal sheet(会抢焦点)
//   - 非 intrusive:Esc / click-outside dismiss,系统默认 TipView 自带 "X" / "Next" 按钮
//   - Persist skip in `@AppStorage` 跨 launch 保留
//   - 不 replay if skipped;re-show on major `CFBundleShortVersionString` bump;
//     reset on settings wipe
//   - 5 步 diskmon-specific:
//     1. menu-bar live temp
//     2. pick external volume(UUID survives TB4 re-plug)
//     3. SMART + 4-tier health
//     4. 1H/24H/7D chart
//     5. health-change notifications + FDA if smartctl is blocked
// ============================================================================
//
// 设计决策:
// - 5 Tip struct(每个 struct = 一步,struct 自动 Sendable / 编译期固定)
// - 用 @State `currentStep: Int` + `onChangeTip` 走 5 步顺序(macOS 14+ 兼容)
// - Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationSupport)])
//   在 `App.init()` 调一次(macOS 14+ API,guard 老系统)
// - @AppStorage("hasCompletedOnboarding") + @AppStorage("lastKnownVersion") 双 @AppStorage key:
//   - "hasCompletedOnboarding" (Bool, false default) = 永久跳过标志
//   - "lastKnownVersion" (String, "" default) = 上次 major.minor,触发 What's New
// - Tips.resetDatastore() 在 major version bump 时调,让旧用户看到新版本教程
// - 严格不写 Localizable.strings(全部用 `String(localized: ..., defaultValue: ...)` 兜底)
//
// 严禁:
// - 不写 Localizable.strings(全部用 `String(localized: ..., defaultValue: ...)` 兜底)
// - 不 mock data;tip 文本硬编码英文(主人审美:英语克制描述,跟 macOS Sonoma+ 风格一致)
// - 不动 AppSettings;只新增 2 个 @AppStorage key
// - 不依赖 macOS 15+ TipGroup class(向下兼容 macOS 14)

// MARK: - Step 1: Menu-bar live temperature

/// 步骤 1:菜单栏实时温度(点击 diskmon 图标看温度 / 健康度 / SMART 状态)
struct MenuBarTempTip: Tip {
    var title: Text { Text("Live temperature in your menu bar") }
    var message: Text {
        Text("Click the diskmon icon to see real-time temperature, health, and SMART status of your connected drives.")
    }
    var image: Image? { Image(systemName: "thermometer.medium") }
}

// MARK: - Step 2: Pick external volume (UUID-sticky)

/// 步骤 2:选择外置盘(UUID 锚定 — TB4 拔插后配置不丢)
struct PickVolumeTip: Tip {
    var title: Text { Text("Pick your volume") }
    var message: Text {
        Text("Each volume is tracked by UUID — survives Thunderbolt re-plug, so your settings stay sticky.")
    }
    var image: Image? { Image(systemName: "externaldrive.fill") }
}

// MARK: - Step 3: SMART + 4-tier health

/// 步骤 3:SMART + 4 档健康度(GOOD / AVERAGE / LOW / BAD)
struct SmartHealthTip: Tip {
    var title: Text { Text("SMART + 4-tier health") }
    var message: Text {
        Text("diskmon polls SMART every 5 seconds. DriveDx-style GOOD / AVERAGE / LOW / BAD with actionable next steps.")
    }
    var image: Image? { Image(systemName: "heart.text.square") }
}

// MARK: - Step 4: 1H / 24H / 7D history chart

/// 步骤 4:1H / 24H / 7D 历史曲线(每个 tab 不同时间窗)
struct HistoryChartTip: Tip {
    var title: Text { Text("1H / 24H / 7D history") }
    var message: Text {
        Text("Each tab shows a different time range. Hover for tooltip, click-drag to zoom, ⌘E to export.")
    }
    var image: Image? { Image(systemName: "chart.line.uptrend.xyaxis") }
}

// MARK: - Step 5: Notifications + Full Disk Access

/// 步骤 5:通知 + Full Disk Access(FDA 跑 SMART self-test 需要)
struct NotificationsFDATip: Tip {
    var title: Text { Text("Notifications + Full Disk Access") }
    var message: Text {
        Text("diskmon needs Full Disk Access to run SMART self-tests. Get alerts on Warning / Critical / Danger only — no cry-wolf.")
    }
    var image: Image? { Image(systemName: "bell.badge") }
}

// MARK: - OnboardingTipView (5 步 stepper 自管)

/// v0.9.3 minimax-C:Onboarding 5 步 stepper(自管顺序,macOS 14+ 兼容)
/// - 不用 macOS 15+ `TipGroup` class(避免绑定新系统;TipGroup 在 SDK 是 final class,
///   不是 protocol,不能 extend;只支持 builder 形式 `Tips { Tip1(); Tip2() }`)
/// - 用 @State `currentStep: Int` 0..4 切换 5 个独立 Tip
/// - 顶部:TipView 显示当前 step(系统默认 UI:title / message / image)
/// - 底部:手动 Next 按钮(琥珀胶囊) + step indicator "1/5" + Skip 按钮
/// - 走完 5 步 → onFinish() 回调(由调用方 hasOnboarded = true)
/// - 不调 Tips.invalidate()(保留 5 tip "未展示" 状态,让 OnboardingStore.reset 仍能
///   触发完整 5 步重显)
struct OnboardingTipView: View {
    let onFinish: () -> Void
    let onSkip: () -> Void

    /// v0.9.3 minimax-C:5 步 tip 数组(顺序固定)
    private let tips: [any Tip] = [
        MenuBarTempTip(),
        PickVolumeTip(),
        SmartHealthTip(),
        HistoryChartTip(),
        NotificationsFDATip()
    ]

    /// v0.9.3 minimax-C:当前 step(0..<5)— 每次 next 递增,>4 → onFinish
    @State private var currentStep: Int = 0

    /// v0.9.3 minimax-C:5 步总数(常量,避免 magic number)
    private static let totalSteps: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 步骤 1:TipView(系统默认 UI 渲染当前 tip)
            // - macOS 15+:TipView(_:arrowEdge:action:)(any Tip?)— 任务部署目标
            // - macOS 14:有 init(_:arrowEdge:action:)<Content: Tip>,但只能接具体 generic Content,
            //   不能接 [any Tip];SDK 14 只能走 popoverTip / TipView 绑定单一 tip
            // - 简化路径:macOS 14 直接显静态标题(完整 5 步 stepper 仍可走,只是 TipView 不渲染)
            // - macOS 13 兜底:无 TipKit,直接显 "Step X/5" + 标题
            if #available(macOS 15, *) {
                TipView(tips[currentStep], arrowEdge: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // macOS 13/14 兜底:TipKit 在但 TipView 简化降级
                Text("Step \(currentStep + 1) of \(Self.totalSteps)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            // 步骤 2:stepper 控件(Back / step indicator / Next / Skip)
            stepper
        }
    }

    /// v0.9.3 minimax-C:底部 stepper(Back / "1/5" / Next / Skip)
    /// - Back:disabled when currentStep == 0(第 1 步无前一步)
    /// - Next:currentStep < 4 → next;== 4 → onFinish()(走完最后一步)
    /// - Skip:永久跳过(直接 onSkip → AppStorage = true 永久 gate 关)
    private var stepper: some View {
        HStack(spacing: 8) {
            // Back
            Button {
                guard currentStep > 0 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep -= 1
                }
            } label: {
                Text(String(localized: "onboarding.back", defaultValue: "Back"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(currentStep == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .disabled(currentStep == 0)
            .help(String(localized: "onboarding.back.help", defaultValue: "Previous step"))

            // step indicator "1/5"
            Text("\(currentStep + 1) / \(Self.totalSteps)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            // Next / Finish
            Button {
                advance()
            } label: {
                Text(currentStep < Self.totalSteps - 1
                     ? String(localized: "onboarding.next", defaultValue: "Next")
                     : String(localized: "onboarding.done", defaultValue: "Done"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dsNormal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.dsNormal.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help(currentStep < Self.totalSteps - 1
                  ? String(localized: "onboarding.next.help", defaultValue: "Next step")
                  : String(localized: "onboarding.done.help", defaultValue: "Finish onboarding"))

            // Skip / Don't show again
            Button {
                onSkip()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(String(
                localized: "onboarding.skip.help",
                defaultValue: "Don't show this again"
            ))
            .accessibilityLabel(String(
                localized: "onboarding.skip.label",
                defaultValue: "Skip onboarding"
            ))
        }
    }

    /// v0.9.3 minimax-C:推进到下一步 / 完成
    /// - 末步(4):next 走完 → onFinish()(由调用方 AppStorage gate 永久关闭)
    /// - 其它:next → currentStep += 1
    /// - **不**调 Tips.invalidate()(保留 5 tip "未展示" 状态,让 OnboardingStore.reset
    ///   仍能触发完整 5 步重显 — 用户主动 skip 跟走完的语义保持一致)
    private func advance() {
        if currentStep < Self.totalSteps - 1 {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentStep += 1
            }
        } else {
            // 末步 → onFinish(调用方会 hasOnboarded = true + markCompleted)
            onFinish()
        }
    }
}

// MARK: - Onboarding Persistence (AppStorage bridge)

/// v0.9.3 minimax-C:Onboarding 持久化辅助
/// - AppStorage 真相源(用户主动 "Don't show again" / 走完 5 步)
/// - TipKit datastore 临时状态(单 session 5 步走完 / Esc 跳过的状态)
/// - 两者双轨:AppStorage = 永久跳过;TipKit = 本次是否要显
@MainActor
enum OnboardingStore {
    /// UserDefaults key — 用户是否已完成 onboarding(主动 skip / 走完 5 步 / 设置里重置)
    static let hasCompletedKey = "hasCompletedOnboarding"
    /// UserDefaults key — 上次 major version bump 触发 What's New 的 major.minor
    static let lastKnownVersionKey = "lastKnownVersion"

    /// 当前 app 版本(CFBundleShortVersionString),fallback "0.0.0"
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 当前 major.minor("0.9.3" → "0.9")— 用来判断 "0.9.x" 内不触发 What's New
    /// 跨 major.minor 才触发(0.9 → 0.10 → 1.0)
    static var currentMajorMinor: String {
        let parts = currentVersion.split(separator: ".")
        guard parts.count >= 2 else { return currentVersion }
        return "\(parts[0]).\(parts[1])"
    }

    /// 上次记录的 major.minor — UserDefaults "lastKnownVersion" 存的是 major.minor
    static var lastKnownMajorMinor: String {
        UserDefaults.standard.string(forKey: lastKnownVersionKey) ?? ""
    }

    /// 持久化当前 major.minor — 在 What's New sheet 关闭后调,下次启动对比
    static func recordCurrentVersion() {
        UserDefaults.standard.set(currentMajorMinor, forKey: lastKnownVersionKey)
    }

    /// 是否应该显 What's New(major.minor 变更)
    /// - 首次启动: lastKnown = "" → 不显(让 onboarding 先走)
    /// - 后续启动: lastKnown != currentMajorMinor → 显 1 次
    /// - 同 major.minor: 不显
    static func shouldShowWhatsNew(hasCompletedOnboarding: Bool) -> Bool {
        // 未完成 onboarding 的用户不显 What's New(让 5 步先走)
        guard hasCompletedOnboarding else { return false }
        // 首次启动 → 不显(没"上次"可言)
        guard !lastKnownMajorMinor.isEmpty else { return false }
        // major.minor 变化 → 显
        return lastKnownMajorMinor != currentMajorMinor
    }

    /// 标记 onboarding 完成 + 记录当前版本(用户点 "Don't show again" 或走完 5 步)
    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: hasCompletedKey)
        recordCurrentVersion()
    }

    /// 重置 onboarding(让用户能再次看到 5 步)— 留给 Preferences → "Reset Onboarding" 按钮
    /// v0.9.3 不实现 Preferences 入口(任务硬规则:不改 5 Preferences 子 View);
    /// 暴露 API 给未来 Settings 按钮调,跟主流程解耦
    static func reset() {
        UserDefaults.standard.set(false, forKey: hasCompletedKey)
        UserDefaults.standard.removeObject(forKey: lastKnownVersionKey)
    }
}
