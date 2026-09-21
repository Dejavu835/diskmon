import SwiftUI
import SwiftData
import DiskMonCore

/// 菜单栏标签 v0.2.0
/// 4 模式:temperature(默认) / health / sparkline / ok
/// 切换通过 @AppStorage("menuBarMode") 持久化,用户改完重启后保留
/// 健康度 / 主题用 Color.dsNormal/dsWarning/dsCritical/dsDanger token
/// v0.9.1 polish-O1:sparkline 模式 — 修假 sin 波 → 真 SwiftData 24h 温度历史
///   - 原 `sparklineSeries` 用 `sin(t * .pi * 2)` 生成假 sin 波,违反主人硬规则"不 mock"
///   - 新:走 `@Environment(\.modelContext)` → `FetchDescriptor<SmartSnapshot>` 拉
///     `selectedDisk` 最近 24 个 raw 采样;无数据返回 `[]`,SparklineView 自动空(不再假 sin)
///   - SwiftData 容器由 DiskMonApp 的 `.modelContainer(monitor.modelContainer)` 注入
///     (label 是 MenuBarExtra 子 view,跟 content 共享 modelContext env)
/// v0.9.1 polish-P1:sparkline 缓存 + .task 触发
///   - 原 `sparklineSeries` 是计算属性,每次 body redraw(5s 一次)都跑
///     `modelContext.fetch(FetchDescriptor + #Predicate + fetchLimit=24)`
///   - 5s 一次无谓 IO 浪费(性能瓶颈 Top-1,profile 硬规则性能 + UX 流畅)
///   - 新:@State 缓存 + `.task(id: volumeUUID)` 触发,只在切盘或 5s 周期时 fetch 一次
struct MenuBarLabel: View {
    @Bindable var monitor: HealthMonitor
    private var settings: AppSettings { AppSettings.shared }

    /// v0.9.1 polish-O1:SwiftData 容器 — sparklineSeries 拉 SmartSnapshot 用
    /// - 容器由 DiskMonApp.scene 的 `.modelContainer(monitor.modelContainer)` 注入
    /// - 兜底:nil → sparklineCache 走空数组路径(原 `sin` 假波路径已删)
    @Environment(\.modelContext) private var modelContext

    /// v0.9.1 polish-P1:sparkline 缓存(@State 而非计算属性,避免每次 redraw 重 fetch)
    /// - nil uuid → []
    /// - 5s 周期 refreshSparkline() 写入新值
    /// - sparklineMode 直接读 sparklineCache,无副作用
    @State private var sparklineCache: [Double] = []
    /// v0.9.1 polish-P1:上次 fetch 时间(防抖,可省 — 这里靠 .task 循环控制,留作日志/未来节流用)
    @State private var lastSparklineFetch: Date = .distantPast

    enum MenuBarMode: String, CaseIterable, Identifiable {
        case temperature, health, sparkline, ok
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .temperature: return "thermometer.medium"
            case .health:      return "heart.text.square"
            case .sparkline:   return "chart.line.uptrend.xyaxis"
            case .ok:          return "externaldrive.fill"
            }
        }
        var localizedLabel: String {
            switch self {
            case .temperature: return String(localized: "menubar.mode.temperature", defaultValue: "Temperature")
            case .health:      return String(localized: "menubar.mode.health", defaultValue: "Health")
            case .sparkline:   return String(localized: "menubar.mode.sparkline", defaultValue: "Sparkline")
            case .ok:          return String(localized: "menubar.mode.ok", defaultValue: "OK")
            }
        }
    }

    var body: some View {
        Group {
            switch resolvedMode {
            case .temperature: temperatureMode
            case .health:      healthMode
            case .sparkline:   sparklineMode
            case .ok:          okMode
            }
        }
        .symbolEffect(
            .pulse, options: .repeating,
            isActive: settings.showMenuBarPulse && displayLevel == .danger
        )
    }

    // MARK: - temperature 模式(默认)

    private var temperatureMode: some View {
        HStack(spacing: 3) {
            Image(systemName: iconForLevel)
                .symbolRenderingMode(.hierarchical)
            Text(tempText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(labelColor)
    }

    // MARK: - health 模式(3 个 stacked SF Symbol)

    private var healthMode: some View {
        HStack(spacing: 2) {
            healthSymbol
            Text(levelAbbrev)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundStyle(labelColor)
    }

    private var healthSymbol: some View {
        let color = labelColor
        return HStack(spacing: 1) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
        }
        .foregroundStyle(color.opacity(0.55))
        .overlay(
            // 用 mask 显示几个点亮
            HStack(spacing: 1) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(lightDots >= 1 ? color : .clear)
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(lightDots >= 2 ? color : .clear)
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(lightDots >= 3 ? color : .clear)
            }
        )
    }

    private var lightDots: Int {
        switch displayLevel {
        case .normal:   return 3
        case .warning:  return 2
        case .critical: return 1
        case .danger:   return 1
        }
    }

    private var levelAbbrev: String {
        switch displayLevel {
        case .normal:   return "OK"
        case .warning:  return "WRN"
        case .critical: return "CRT"
        case .danger:   return "DNG"
        }
    }

    // MARK: - sparkline 模式(24h 最高温度 mini 折线)

    /// v0.9.1 polish-P1:sparklineMode 改用 @State sparklineCache,而非每次 redraw 重 fetch
    /// - SparklineView 接收缓存的 [Double],SwiftUI 把 data 当 let 传入,无副作用
    /// - `.task(id: volumeUUID)` 在切盘 / 进入 sparkline mode 时启动,周期 5s refresh
    private var sparklineMode: some View {
        HStack(spacing: 4) {
            SparklineView(
                values: sparklineCache,
                lineColor: labelColor,
                fillColor: labelColor.opacity(0.18),
                frameSize: CGSize(width: 40, height: 16)
            )
            Text(tempText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(labelColor)
        // v0.9.1 polish-P1:volumeUUID 变化 → task 取消旧 + 启动新(立即 fetch)
        //   不在 sparkline mode 时(sparklineMode view 不挂载)→ task 不跑,无 fetch
        //   5s 周期:task 内 while + Task.sleep 循环
        .task(id: monitor.selectedDisk?.volumeUUID ?? "_none") {
            // 切盘 → 立即 fetch(避免新盘显示旧盘 sparkline 一帧)
            await refreshSparkline()
            // 5s 周期 refresh(跟 HealthMonitor.pollOnce 间隔对齐,新采样点能立即反映)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await refreshSparkline()
            }
        }
    }

    /// v0.9.1 polish-P1:refresh sparkline 缓存 — 从 SwiftData 拉 24 个 raw 采样
    /// - nil uuid → 空数组(切走盘 / 没盘)
    /// - 排序:fetch descriptor 拿新→旧,.reversed() 翻成旧→新(折线从左到右 = 时间正序)
    /// - 写 @State sparklineCache → 触发 sparklineMode 重新 body(SparklineView 重画)
    /// - 5s 周期调用,主线程 IO(模型是 in-process SwiftData,fetch 几毫秒)
    /// - 不再走 `sin()` 假波生成(违反"不 mock"硬规则,polish-O1 已修)
    /// - v0.9.1 build fix:SwiftData #Predicate 宏不能直接引用 type 静态属性
    ///   (SmartSnapshot.granularityRaw),需要先 capture 到本地 let,跟 DownSampler/HealthMonitor 模式一致
    private func refreshSparkline() async {
        guard let uuid = monitor.selectedDisk?.volumeUUID else {
            sparklineCache = []
            return
        }
        let rawGranularity = SmartSnapshot.granularityRaw
        var descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == rawGranularity
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        // v0.9.1 build fix:FetchDescriptor 没有 `prefix(_:)` 方法(那是 SwiftUI LazySequence 的),
        //   SwiftData 用 `fetchLimit` 限制行数;跟 HealthMonitor.recordPowerSample 模式一致
        descriptor.fetchLimit = 24
        let snapshots = (try? modelContext.fetch(descriptor)) ?? []
        // reverse(新→旧)再 reversed() → 旧→新(SparklineView 画线从左到右 = 时间正序)
        sparklineCache = Array(snapshots.reversed().compactMap { s -> Double? in
            SmartParse.isPlausibleCelsius(s.celsius) ? Double(s.celsius) : nil
        })
        lastSparklineFetch = Date()
    }

    // MARK: - ok 模式(只在全部 Good 时显示琥珀点)

    private var okMode: some View {
        HStack(spacing: 3) {
            Image(systemName: "externaldrive.fill")
                .symbolRenderingMode(.hierarchical)
            Circle()
                .fill(labelColor)
                .frame(width: 5, height: 5)
        }
        .foregroundStyle(labelColor)
    }

    // MARK: - 计算属性

    private var displayLevel: HealthLevel {
        if settings.menuBarColorScopeRaw == "selected",
           let uuid = monitor.selectedDisk?.volumeUUID {
            return monitor.level(for: uuid)
        }
        return monitor.worstLevel
    }

    private var resolvedMode: MenuBarMode {
        let stored = MenuBarMode(rawValue: settings.menuBarModeRaw) ?? .temperature
        if settings.autoOKWhenHealthy && displayLevel == .normal { return .ok }
        return stored
    }

    private var iconForLevel: String {
        switch displayLevel {
        case .normal:   return "thermometer.medium"
        case .warning:  return "thermometer.medium"
        case .critical: return "thermometer.high"
        case .danger:   return "thermometer.sun.fill"
        }
    }

    /// 数据未就绪显 —,否则 "42°"
    private var tempText: String {
        if !monitor.isReady {
            return String(
                localized: "menubar.notready",
                defaultValue: "—°"
            )
        }
        // polish-P2 fallback:温度未采集(0)也显 —
        guard let c = monitor.current.celsius, c > 0 else { return "—°" }
        return "\(c)°"
    }

    /// 文字色:未就绪灰,正常米色,警告/危险按等级
    private var labelColor: Color {
        if !monitor.isReady { return .secondary }
        return displayLevel.color
    }
}
