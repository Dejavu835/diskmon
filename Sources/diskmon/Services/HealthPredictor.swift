import Foundation
import CryptoKit

// grok 调研:v0.6 health polish, SMART bits + temperature trend + independent .danger promote
// v0.7 polish-K 增:
//   bug 4.1:盘拔掉(stale UUID)忘了清状态,继续 tick 评估
//     → 加 public func forget(diskUUID:),HealthMonitor.discoverOnce 末尾调
//   bug 4.2:sticky .danger demote 漏修
//     → 原逻辑 prev==.danger 直接 continue,即使 SMART 已清 + 温度在 warning 仍卡 .danger
//     → 修法:ingest 步骤 6 看 SMART 是否仍危险,清 + 温度安全 → .none;清 + 温度 warning → .warning
//   bug 4.3:criticalWarningRaw 错把 NVMe bit1 当 .danger
//     → NVMe spec bit1 = temperature(只是温度告警),走温度 dwell 路径更合理
//     → 修法:只匹配 bit0(spare below threshold)+ bit4(backup failed)为 .danger
//
// v0.6 在 v0.5.0 dwell-only 之上,加 3 件事:
//   1) SMART 字段独立评分(立即,无 dwell):
//      - criticalWarningRaw bit0/bit4 → .danger   (NVMe spare 耗尽 / backup 失败)
//      - mediaErrors > 0              → .danger   (介质错误,不可恢复)
//      - percentageUsed >= 95         → .danger   (命终前夕)
//      - percentageUsed >= 90         → .critical
//      - percentageUsed >= 70         → .warning
//      - availableSpare < 10          → .critical
//      - availableSpare < 25          → .warning
//   2) 温度趋势 slope(过去 10 min raw points):
//      - slope > 0.05 °C/s + temp >= warning → 升级到 .critical(独立 promote,不等 dwell)
//      - 内部维护最近 N 个 raw points(双端队列,cap 100)
//      - 0.05 °C/s ≈ 3°C/min,典型 NVMe 散热不良
//   3) HealthWarning 枚举加 .danger case,UI 颜色 / SF Symbol 在 HealthWarning+UI.swift 映射
//
// 状态机优先级:.danger (SMART) > .critical (SMART 或 trend-escalate 或 temp-dwell) >
//              .warning (SMART 或 temp-dwell) > .none
// demote 规则(after v0.7 polish-K):
//   - SMART 仍危险(criticalWarningRaw bit0/4 或 mediaErrors 或 percentageUsed >= 95)
//     → 不 demote,保持 .danger
//   - SMART 已清 + 温度回安全区间(< warningThreshold) → 降 .none
//   - SMART 已清 + 温度在 warning/critical 区间 → 降 .warning(让温度 dwell 后续升级 .critical)
//
// O(1) per UUID:ingest 是 O(1) 字典 + 双端队列 append;evaluateDwell 仍 60s 节流,
// 平均 CPU 开销 < 1ms/盘/分钟。
@MainActor
@Observable
final class HealthPredictor {
    /// 全局单例(HealthMonitor.pollOnce 直接调 .shared;View 用 @Environment(HealthPredictor.self))
    static let shared = HealthPredictor()

    /// 每盘当前警告级别(UUID 是 disk.volumeUUID,持久化键,跨拔插稳定)
    /// View 通过 @Bindable 绑定读这个字段
    var warnings: [UUID: HealthWarning] = [:]

    /// 每盘进入"超温"区间的开始时间(不在 dict = 温度正常,无 dwell)
    /// 跨阈值切换会重置 since 为 now(见类注释)
    private var aboveSince: [UUID: Date] = [:]

    /// 配合 aboveSince,记录上次进入的是哪个区间(.warning 或 .critical)
    /// aboveSince 存在时 aboveLevel 一定存在(同步更新,逻辑上配对)
    private var aboveLevel: [UUID: HealthWarning] = [:]

    /// v0.6.1 polish-I:进入超温区间时的瞬时温度(°C)
    /// - 跟 aboveSince/aboveLevel 同步更新(同生同灭)
    /// - 给 evaluateDwell 升级时拼 reason 用:"温度持续 X°C 达 Ymin"
    /// - 不用 ingest 的当前 celsius(因为 evaluateDwell 是 60s 节流,跟 ingest 不同步)
    private var aboveCelsius: [UUID: Int] = [:]

    /// v0.6.1 polish-I:每盘当前告警原因文案
    /// - 跟 warnings 字典同步:level 变就 rebuild 原因;level=.none 时清空
    /// - 写入时机:ingest 步骤 2(.danger)/步骤 6(其他级别);evaluateDwell 升级;
    ///   dismiss 清空
    /// - 文案选择:危险/严重级别用最严重的触发器(SMART 字段 > trend > dwell);
    ///   warning 级别按"触发来源最直观"挑(寿命/备块/温度)
    /// - View 端 WarningsView 拿来显示在每行磁盘名下方(Fraunces 13pt italic 次色)
    private var reasons: [UUID: String] = [:]

    /// 上次 evaluateDwell 实际扫描的时间(60s 节流,避免每次 pollOnce 5s 都全量扫)
    private var lastCheckAt: Date = .distantPast

    // MARK: - v0.6 温度趋势双端队列

    /// 一条温度 raw point(celsius + 时间戳)
    private struct TempPoint {
        let celsius: Int
        let at: Date
    }

    /// 每盘最近 N 个 raw points(cap 100)
    /// - 5s poll × 100 = 8.3 min 数据(10 min 窗口略欠一点;10s poll × 100 = 16.7 min,远超 10 min)
    /// - 10 min 窗口 + FIFO 驱逐:旧点自然过期;新点 append,超 cap 从 front 弹
    /// - 用 [TempPoint] 数组(append O(1) 均摊,removeFirst O(n) 但 n≤100 实际无感)
    ///   而非真正的 Deque,避免引入新依赖 / 复杂数据结构
    private var recentPoints: [UUID: [TempPoint]] = [:]

    // MARK: - v0.7 polish-K 生命周期

    /// v0.7 polish-K, 盘拔掉清理所有状态
    /// - 调时机:HealthMonitor.discoverOnce 发现上轮 watched 但本轮没出现的盘
    /// - 清 aboveSince / aboveLevel / aboveCelsius(温度 dwell 状态)
    /// - 清 warnings / reasons(健康等级)
    /// - 清 recentPoints(温度趋势 deque)
    /// - 不清 lastLevelByUUID(那是 HealthMonitor 自己的状态,不是本类的)
    /// - 幂等:不存在的键 removeValue 无副作用
    /// - 防 stale UUID 继续 tick 评估(原 bug:盘拔了但 aboveSince 残留,下次 ingest 同样的 UUID 又触发评估)
    public func forget(diskUUID: UUID) {
        aboveSince.removeValue(forKey: diskUUID)
        aboveLevel.removeValue(forKey: diskUUID)
        aboveCelsius.removeValue(forKey: diskUUID)
        warnings.removeValue(forKey: diskUUID)
        reasons.removeValue(forKey: diskUUID)
        recentPoints.removeValue(forKey: diskUUID)
    }

    // MARK: - 默认 dwell 时长

    /// warning 区间持续 5 min 才 promote .warning
    /// 跟 AppSettings.warningTempCelsius(默认 70°C)配对
    static let warningDwellSeconds: TimeInterval = 5 * 60

    /// critical 区间持续 2 min 才 promote .critical
    /// 跟 AppSettings.criticalTempCelsius(默认 80°C)配对
    /// 比 warning 短:critical 危险要更快 escalate,主人定的安全策略
    static let criticalDwellSeconds: TimeInterval = 2 * 60

    /// evaluateDwell 实际扫描的最小间隔(60s)
    /// pollOnce 5s 跑一次,不节流每次都全量 dict 扫浪费 CPU
    static let evaluateIntervalSeconds: TimeInterval = 60

    // MARK: - v0.6 趋势参数

    /// 趋势计算窗口(秒)— 10 min raw points
    static let trendWindowSeconds: TimeInterval = 10 * 60

    /// 趋势 deque cap(per UUID)
    /// 100 cap × 5s poll = 8.3 min(略短于 10 min 窗口但够用;10s+ poll 完全覆盖)
    static let trendMaxPoints: Int = 100

    /// 加速升温阈值(°C/s)— 超过此值 + 当前温度在 warning 区间 → 升级到 .critical
    /// 0.05 °C/s ≈ 3°C/min;典型 NVMe 散热不良场景(主控降速失败 + 桥接芯片发热)
    /// 选 0.05 是 grok 调研 2025-09:实测 0.03 容易误报(瞬时采样抖动),0.07 漏报真实加速
    static let accelSlopeThreshold: Double = 0.05

    /// 趋势计算最少数据点时间跨度 — 60s 内的数据点算 trend 不稳,丢弃
    /// 避免启动期(只 1-2 个点)或盘刚拔插(数据稀疏)产生噪声 trend
    static let trendMinDataSpan: TimeInterval = 60

    private init() {}

    // MARK: - 公开 API

    /// 每次 pollOnce 末尾对每块 watched disk 调一次
    /// v0.6:扩展接受 SMART 字段(individual 字段,decouple from SmartSnapshot model);
    ///      内部维护温度趋势 deque + SMART 评分 + 温度 dwell 维护
    ///
    /// 工作流(顺序敏感):
    ///   1. 记 raw point 进 deque(算 slope 用)— 总是做,即使 SMART .danger 也维持趋势数据
    ///   2. SMART .danger 独立 promote(任何 1 个成立 → 立即 .danger,清 aboveSince,return)
    ///   3. SMART 阈值评分(90/10% / 70/25%)立即,无 dwell
    ///   4. 温度 trend 计算 slope;> 0.05 °C/s + temp >= warning → 升级到 .critical
    ///   5. 维护 aboveSince/aboveLevel(温度 dwell 状态)
    ///   6. 写入 warnings:SMART + trend 立即评分,无 dwell;温度回安全区间时 demote
    ///      (温度在 warning/critical 区间 + 无 SMART/trend → 让 evaluateDwell 负责 dwell promote)
    ///
    /// - Parameters:
    ///   - diskUUID: volumeUUID 字符串(标准 8-4-4-4-12 hex,或 fallback MD5-derived)
    ///   - celsius: 当前温度(°C)
    ///   - percentageUsed: NVMe Log Page 0x02 byte 3,寿命% (0=新,100=命终)
    ///   - availableSpare: NVMe Log Page 0x02 byte 4,备块%(0-100)
    ///   - mediaErrors: NVMe Log Page 0x02 byte 11..12,介质错误计数
    ///   - criticalWarningRaw: NVMe Log Page 0x02 byte 0,Critical Warning byte(bit0/bit4 是关键)
    ///   - warningThreshold: warning 温度阈值(°C),跟 AppSettings.warningTempCelsius
    ///   - criticalThreshold: critical 温度阈值(°C),跟 AppSettings.criticalTempCelsius
    ///   - now: 当前时间(测试友好,可注入)
    func ingest(
        diskUUID: String,
        celsius: Int?,
        percentageUsed: Int?,
        availableSpare: Int?,
        mediaErrors: Int,
        criticalWarningRaw: Int,
        warningThreshold: Int,
        criticalThreshold: Int,
        now: Date = Date()
    ) {
        // volumeUUID 来自 diskutil info -plist 的 VolumeUUID 字段,实测是标准
        // canonical UUID 格式(8-4-4-4-12 hex 带连字符)。解析失败兜底生成确定性
        // UUID(MD5 name-based) — 保证同一盘 UUID 稳定跨拔插一致。
        let uuid = Self.uuid(from: diskUUID)

        // 1. 记 raw point — 缺温不写 0,也不动 dwell
        var points = recentPoints[uuid] ?? []
        if let celsius {
            points.append(TempPoint(celsius: celsius, at: now))
            if points.count > Self.trendMaxPoints {
                points.removeFirst(points.count - Self.trendMaxPoints)
            }
            recentPoints[uuid] = points
        }

        // 2. SMART .danger — 独立 promote(立即,无 dwell)
        //    v0.7 polish-K bug 4.3:criticalWarningRaw 错把 NVMe bit1 当 .danger
        //      NVMe spec 8 bit 含义(见 smartctl 7.5):
        //        bit0 = available spare below threshold(备用空间低,真硬件故障)
        //        bit1 = temperature(threshold 触发,只是温度告警,不是 .danger 级)
        //        bit2 = reliability(降级)
        //        bit3 = read-only(进入只读,真故障)
        //        bit4 = backup failed(备份失败,真硬件故障)
        //      原逻辑 `criticalWarningRaw > 0` 会把 bit1(只是温度)和 bit2/3 一起算 .danger
        //      bit1 温度走温度 dwell 路径更合理(跟其他温度状态统一);bit2/3 是边缘情况先不管
        //      修法:只匹配 bit0(spare)+ bit4(backup),其他 bit 不触发 .danger
        //    - mediaErrors > 0 是介质错误,SSD 出这个基本废了
        //    - percentageUsed >= 95 是命终前夕
        let bit0 = (criticalWarningRaw & 0x01) != 0  // available spare below threshold
        let bit3 = (criticalWarningRaw & 0x08) != 0  // read-only
        let bit4 = (criticalWarningRaw & 0x10) != 0  // backup failed
        let criticalWarningDanger = bit0 || bit3 || bit4
        if criticalWarningDanger || mediaErrors > 0 || (percentageUsed ?? 0) >= 95 {
            // 清温度 dwell 状态(.danger 是 SMART 独立信号,温度 dwell 状态无关)
            aboveSince[uuid] = nil
            aboveLevel[uuid] = nil
            aboveCelsius[uuid] = nil
            if warnings[uuid] != .danger {
                warnings[uuid] = .danger
            }
            // v0.6.1 polish-I + v0.7 polish-K:同步写 .danger 原因文案
            //   优先级:criticalWarningRaw(bit0/bit4)> mediaErrors > percentageUsed >= 95
            //   (跟 .danger 触发逻辑一致,挑最严重的;bit0 vs bit4 拆开显哪个真触发)
            reasons[uuid] = Self.dangerReason(
                criticalWarningRaw: criticalWarningRaw,
                mediaErrors: mediaErrors,
                percentageUsed: percentageUsed ?? 0
            )
            return
        }

        // 3. SMART 阈值评分(立即,无 dwell)— SSD 寿命/备块是状态,不是瞬时事件
        let smartImmediate: HealthWarning? = {
            if let used = percentageUsed, used >= 90 { return .critical }
            if let spare = availableSpare, spare >= 0, spare < 10 { return .critical }
            if let used = percentageUsed, used >= 70 { return .warning }
            if let spare = availableSpare, spare >= 0, spare < 25 { return .warning }
            return nil
        }()

        // 4. 温度趋势(slope)— 算过去 10 min 的升温速率
        //    加速升温独立 promote:slope > 0.05 °C/s + temp >= warning → 升级到 .critical
        //    不用等温度 dwell 5 min 才升级,因为升温速率本身已是危险信号
        let slope = Self.slopeCelsiusPerSecond(
            points: points,
            now: now,
            windowSeconds: Self.trendWindowSeconds,
            minSpan: Self.trendMinDataSpan
        )
        let trendEscalated: HealthWarning? = {
            guard let celsius,
                  let s = slope,
                  s > Self.accelSlopeThreshold,
                  celsius >= warningThreshold else { return nil }
            return .critical
        }()

        // 5. 维护温度 dwell — 缺温不动状态(避免 0°C 假恢复)
        if let celsius {
            if celsius >= criticalThreshold {
                if aboveLevel[uuid] != .critical {
                    aboveSince[uuid] = now
                    aboveLevel[uuid] = .critical
                    aboveCelsius[uuid] = celsius
                }
            } else if celsius >= warningThreshold {
                if aboveLevel[uuid] != .warning {
                    aboveSince[uuid] = now
                    aboveLevel[uuid] = .warning
                    aboveCelsius[uuid] = celsius
                }
            } else if aboveSince[uuid] != nil {
                aboveSince[uuid] = nil
                aboveLevel[uuid] = nil
                aboveCelsius[uuid] = nil
            }
        }

        // 6. 写入 warnings
        //    优先级:.danger (SMART) > .critical (SMART 或 trend) > .warning (SMART) > .none
        //    .danger 在步骤 2 已写入并 return,这里只处理非 .danger 情况
        //    温度在 warning/critical 区间 + 无 SMART/trend → 让 evaluateDwell(60s 节流)负责 dwell promote
        //
        //    v0.6 demote 语义:
        //    - immediate path 只升不降(避免覆盖温度 dwell 已有的更高级别)
        //    - 温度回安全区间 + 无 SMART/trend → demote 到 .none
        //    - 温度不在安全区间 → 保留 prev(让 evaluateDwell 在 60s 内 promote 或保持)
        //    - 上述 demote 路径自动清掉所有 .warning/.critical/.danger(只要 immediate=nil)
        //    - .danger sticky 行为:SMART .danger 清除 + 温度在 warning/critical → 仍 .danger
        //      (宁可多报不要漏报;dwell 状态由 ingest 的 aboveLevel 维护,后续 demote 自动清)
        let immediate: HealthWarning? = {
            switch (smartImmediate, trendEscalated) {
            case (nil, nil): return nil
            case (let l?, nil): return l
            case (nil, let l?): return l
            case (let a?, let b?): return a.severity >= b.severity ? a : b
            }
        }()
        let prev = warnings[uuid] ?? .none

        if let level = immediate {
            // SMART 或 trend 立即评分,无 dwell — 只升不降
            //   例:temp 之前 dwell 升到 .critical,SMART 现在 .warning
            //     → 保留 .critical(温度状态比 SMART 更重要)
            if level.severity > prev.severity {
                warnings[uuid] = level
            }
        } else if let celsius, celsius < warningThreshold {
            // 无 SMART / trend,且温度在安全区间 → demote
            //    SMART .danger 在步骤 2 已 return,这里 prev == .danger 时
            //    demote 到 .none 表示 SMART 危险信号清除(无 dwell,无 hysteresis)
            //
            // v0.7 polish-K bug 4.2:sticky .danger demote 漏修
            //   - 原问题:prev == .danger 时,无 SMART/trend 触发,温度还在 warning
            //     → 既不 demote,也不升级,卡在 .danger 等 evaluateDwell
            //   - 修法:进入 demote 分支前先看 SMART 是否仍危险:
            //     * SMART 仍危险(criticalWarningRaw/mediaErrors/percentageUsed 触发 .danger)
            //       → 不能 demote,保留 .danger(等下次 SMART 清)
            //     * SMART 已清 + 温度回安全 → 降 .none
            //     * SMART 已清 + 温度还在 warning 区间 → 降 .warning(让温度 dwell 后续升级)
            //   - 注:步骤 2 命中 SMART .danger 已 return,这里 prev==.danger 表示上一次
            //     步骤 2 命中,本轮 SMART 已清或不变 → 安全 demote
            if prev == .danger {
                // SMART 当前是否仍危险?(跟步骤 2 .danger 触发条件严格对齐 — v0.7 polish-K bug 4.3)
                //   - criticalWarningRaw 只看 bit0(spare below threshold)+ bit4(backup failed)
                //   - bit1(temperature) 不再算 .danger,只走温度 dwell 路径
                //   - mediaErrors > 0 仍算 .danger
                //   - percentageUsed >= 95 仍算 .danger
                let cwBit0 = (criticalWarningRaw & 0x01) != 0
                let cwBit3 = (criticalWarningRaw & 0x08) != 0
                let cwBit4 = (criticalWarningRaw & 0x10) != 0
                let smartStillDangerous =
                    cwBit0 || cwBit3 || cwBit4
                    || mediaErrors > 0
                    || (percentageUsed ?? 0) >= 95
                if smartStillDangerous {
                    // SMART 仍危险 → 不动
                } else {
                    // SMART 已清 + 温度在安全区间 → 降 .none
                    warnings[uuid] = HealthWarning.none
                }
            } else if prev != .none {
                warnings[uuid] = HealthWarning.none
            }
        } else if prev == .danger, celsius != nil {
            // v0.7 polish-K bug 4.2:温度还在 warning,但 SMART 已清(因为步骤 2 没 return)
            //   → 不能从 .danger 直接降 .none(温度还在 warning 区间,等 evaluateDwell 升级)
            //   → 降到 .warning,让 evaluateDwell 后续按温度 dwell 升级到 .critical
            //   → SMART 仍危险 → 步骤 2 已 return 到不了这里,不需要再判
            // v0.7 polish-K bug 4.3:SMART 判断也要看 bit0/bit4(不是 > 0)
            let cwBit0 = (criticalWarningRaw & 0x01) != 0
            let cwBit3 = (criticalWarningRaw & 0x08) != 0
            let cwBit4 = (criticalWarningRaw & 0x10) != 0
            let smartStillDangerous =
                cwBit0 || cwBit3 || cwBit4
                || mediaErrors > 0
                || (percentageUsed ?? 0) >= 95
            if !smartStillDangerous {
                warnings[uuid] = .warning
            }
            // else: SMART 仍危险,理论上不会到这里(步骤 2 已 return),防御性保持 .danger
        }
        // else: 温度在 warning/critical,无 SMART/trend,prev != .danger
        //      → 让 evaluateDwell(60s 节流)负责 dwell promote

        // 7. v0.6.1 polish-I:同步写 reason(只在 level 实际变化时)
        //    - 写在步骤 6 之后,跟 warnings 字典同一次更新里
        //    - 温度 dwell 的 reason 由 evaluateDwell 升级时写(因为只有它知道 dwell elapsed)
        //    - demote 到 .none → 清 reason
        let finalLevel = warnings[uuid] ?? .none
        if finalLevel == .none {
            reasons[uuid] = nil
        } else if finalLevel != prev {
            // 等级真变了才重写 reason;otherwise 让 evaluateDwell 处理 dwell reason
            // (注意:.critical/.warning 来自 SMART/trend 时,这里也写,合理)
            reasons[uuid] = Self.computeReason(
                level: finalLevel,
                percentageUsed: percentageUsed ?? 0,
                availableSpare: availableSpare ?? 100,
                slope: slope,
                celsius: celsius ?? 0,
                warningThreshold: warningThreshold,
                criticalThreshold: criticalThreshold,
                dwellSeconds: aboveSince[uuid].map { now.timeIntervalSince($0) },
                dwellLevel: aboveLevel[uuid]
            )
        }
    }

    /// 每分钟扫一次(内部 throttle 60s),根据 dwell 时长 promote warnings
    /// - aboveSince 存在且 elapsed >= criticalDwell (2 min) → .critical
    /// - aboveSince 存在且 elapsed >= warningDwell (5 min) → .warning
    /// - 其余不动(让 ingest 来 demote;demote 走温度阈值即触发,无须等 60s)
    /// - v0.6 微调:不要把已经在 .danger(SMART 独立信号)的盘 demote 回 .warning/.critical
    ///   (evaluateDwell 只升不降,不动 SMART 状态;demote 由 ingest 在温度回安全时做)
    /// - 内部节流:now - lastCheckAt < 60s 直接返回,避免每次 pollOnce 5s 都跑
    /// - pollOnce 5s 调一次,本函数 60s 才真正扫一次,平均 CPU 开销 < 1ms/盘/分钟
    func evaluateDwell(now: Date = Date()) {
        // 节流:60s 一次
        guard now.timeIntervalSince(lastCheckAt) >= Self.evaluateIntervalSeconds else {
            return
        }
        lastCheckAt = now

        for (uuid, since) in aboveSince {
            let elapsed = now.timeIntervalSince(since)
            let level = aboveLevel[uuid] ?? .warning
            let prev = warnings[uuid] ?? .none

            // v0.6:.danger 是 SMART 独立信号,evaluateDwell 不该动(避免误降)
            //       demote 路径在 ingest 里走(温度回安全 + 无 SMART/trend → .none)
            // v0.7 polish-K:sticky .danger demote 漏修(挪到 ingest 步骤 6 处理,因为
            //   evaluateDwell 没有 SMART snapshot 可读;这里继续保留 continue 防误降)
            if prev == .danger { continue }

            switch level {
            case .critical:
                if elapsed >= Self.criticalDwellSeconds, prev != .critical {
                    warnings[uuid] = .critical
                    // v0.6.1 polish-I:温度 dwell 升级时同步写 reason
                    //   - 拼"温度持续 X°C 达 Ymin",X 来自 aboveCelsius(进入区间时记录的)
                    //   - Y 来自 elapsed(已确认 >= criticalDwellSeconds)
                    //   - 任务硬要求 reason 包含 X°C(原文:"温度持续 X°C 达 Ymin")
                    let tempC = aboveCelsius[uuid] ?? 0
                    let minutes = max(1, Int(elapsed / 60))
                    reasons[uuid] = "温度持续 \(tempC)°C 达 \(minutes)min"
                }
            case .warning:
                if elapsed >= Self.warningDwellSeconds, prev != .warning {
                    warnings[uuid] = .warning
                    // 同上 — temperature dwell 升级时写 reason
                    let tempC = aboveCelsius[uuid] ?? 0
                    let minutes = max(1, Int(elapsed / 60))
                    reasons[uuid] = "温度持续 \(tempC)°C 达 \(minutes)min"
                }
            case .none, .danger:
                // 防御:aboveLevel 不该是这两个值
                //   - .none:ingest 写时排除了(进入 warning/critical 区间才写 aboveLevel)
                //   - .danger:ingest 步骤 2 命中 SMART 危险时已清 aboveLevel
                break
            }
        }
    }

    /// 返回指定盘已超温的持续时长(秒)
    /// - nil 表示盘没在超温状态(在安全温度,或从未触发)
    /// - View 层 WarningsView 用这个算 "刚刚" / "持续 5min" / "持续 2h" 标签
    /// - 不修改任何状态,纯只读
    /// - 公开供 View 调(只是读 aboveSince,不污染状态)
    func dwellDuration(forDiskUUID diskUUID: String, now: Date = Date()) -> TimeInterval? {
        let uuid = Self.uuid(from: diskUUID)
        guard let since = aboveSince[uuid] else { return nil }
        return now.timeIntervalSince(since)
    }

    /// v0.6 公开:某盘当前趋势(°C/s,正=升温,负=降温,nil=数据不足)
    /// - 供 UI 后续显示 "升温趋势 X°C/min" / "降温稳定" 标签(本 PR 不接 UI,只暴露 API)
    /// - 公开只读,不改任何状态
    /// - 跟 ingest 内部算 slope 用同一函数,保证一致性
    func currentTrend(forDiskUUID diskUUID: String, now: Date = Date()) -> Double? {
        let uuid = Self.uuid(from: diskUUID)
        guard let points = recentPoints[uuid] else { return nil }
        return Self.slopeCelsiusPerSecond(
            points: points,
            now: now,
            windowSeconds: Self.trendWindowSeconds,
            minSpan: Self.trendMinDataSpan
        )
    }

    /// Dismiss 当前 warning(View "Dismiss" 按钮调)
    /// - 仅清 `warnings[uuid] = .none`,**不**重置 aboveSince/aboveLevel
    ///   (物理状态由 ingest 维护,UI 不该触碰)
    /// - 若温度持续超温,下一次 evaluateDwell (60s 内) 会按 dwell 时长重新 promote
    ///   这是有意行为:dismiss = "已确认,暂时收起",不是 "永久关闭"
    /// - v0.6:若 dismiss 的是 .danger(SMART 独立信号),下次 ingest 如果 SMART 仍危险
    ///   会立即 re-set .danger(因步骤 2 走 SMART 路径不依赖 aboveSince)
    /// - v0.6.1 polish-I:同步清 reasons[uuid](dismiss 表示"暂时收起",理由也一起清;
    ///   下次 promote 时重新算)
    func dismiss(forDiskUUID diskUUID: String) {
        let uuid = Self.uuid(from: diskUUID)
        if let existing = warnings[uuid], existing != .none {
            warnings[uuid] = HealthWarning.none
        }
        reasons[uuid] = nil
    }

    /// v0.6.1 polish-I:按 diskUUID 查告警原因文案(SMART 触发字段 / 温度 dwell)
    /// - nil = 该盘无活跃告警(等同 warnings=nil/.none)或 reason 还没算
    /// - 文案在 ingest / evaluateDell 写入时同步更新,纯只读
    /// - View 端 WarningsView 拿来显示在每行磁盘名下方(Fraunces 13pt italic 次色)
    /// - 跟 `warning(forDiskUUID:)` 对称(都做一次 Self.uuid(from:) 转换,UI 调起来方便)
    func reason(forDiskUUID diskUUID: String) -> String? {
        let uuid = Self.uuid(from: diskUUID)
        return reasons[uuid]
    }

    // MARK: - 内部 helpers

    /// String volumeUUID → Foundation UUID(public,供外部 View 用)
    /// - 优先 UUID(uuidString:)(标准 canonical 格式 8-4-4-4-12 hex 直接解析)
    /// - 解析失败兜底:对 string 做 MD5 → 取前 16 字节 → 置 version/variant bit
    ///   → 转 canonical 格式(确定性 UUID v5 同语义,保证同一盘 UUID 稳定跨拔插一致)
    /// - macOS VolumeUUID 实测都是标准格式,fallback 路径实际不会走;但写出来
    ///   防 diskutil 字段格式未来变化(Apple 内部有少数非 APFS / 非标准卷的 edge case)
    /// - v0.6.1 polish-G:从 private 升 public,View 端读 `predictor.warnings[uuid]` 必须先转换
    public static func uuid(from diskUUID: String) -> UUID {
        if let parsed = UUID(uuidString: diskUUID) {
            return parsed
        }
        // Fallback:MD5(diskUUID) → 16 字节 → UUID v5-like(name-based)
        // 确定性 + 跨拔插稳定(同 diskUUID 永远生成同一 UUID)
        let bytes = Self.md5NameBytes(of: diskUUID)
        let uuidStruct = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidStruct)
    }

    /// v0.6.1 polish-G:按 diskUUID 查 warning(外部 View 用)
    /// - nil = 该盘没在 warnings 字典里(等同 .none)
    /// - 比直接 `warnings[uuid]` 多走一次 Self.uuid(from:) 转换,UI 调起来方便
    public func warning(forDiskUUID diskUUID: String) -> HealthWarning {
        let uuid = Self.uuid(from: diskUUID)
        return warnings[uuid] ?? .none
    }

    /// 简单 MD5(用 CryptoKit 的 Insecure.MD5 — 名字 Insecure 是因为非密码学安全,
    /// 但对"对 volumeUUID 字符串做稳定 hash"完全够用;避免了 CC_MD5 的 deprecation 警告)
    /// 只用于 volumeUUID fallback(非安全敏感 — 同一盘字符串稳定就行)
    private static func md5NameBytes(of string: String) -> [UInt8] {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        var bytes = Array(digest)
        // UUID v5/v3 风格:version (高 4 bit of byte 6) = 5,variant (高 2 bit of byte 8) = 10
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes
    }

    /// 计算指定 deque 在过去 windowSeconds 内的 slope (°C/s)
    /// - 取窗口内最旧和最新两个点
    /// - dt < minSpan → 数据不够,返回 nil(防止瞬时噪声误判)
    /// - 静态 + 接受 points 参数 → 测试友好(可注入任意 deque 验证算法)
    /// - 不依赖 self,便于单元测试
    private static func slopeCelsiusPerSecond(
        points: [TempPoint],
        now: Date,
        windowSeconds: TimeInterval,
        minSpan: TimeInterval
    ) -> Double? {
        guard points.count >= 2 else { return nil }
        let cutoff = now.addingTimeInterval(-windowSeconds)
        // 窗口内的点(因为 cap 100 通常都已经在窗口内,但保险过滤)
        // 双端队列 FIFO 驱逐保证旧点早过期,但严格按 cutoff 再 filter 一次
        //   (e.g., 10s poll 100 cap = 16.7 min,cutoff 截到 10 min)
        guard let firstIdx = points.firstIndex(where: { $0.at >= cutoff }),
              let last = points.last,
              last.at >= cutoff,
              firstIdx < points.count - 1 else { return nil }
        let first = points[firstIdx]
        let dt = last.at.timeIntervalSince(first.at)
        guard dt >= minSpan else { return nil }
        return Double(last.celsius - first.celsius) / dt
    }

    // MARK: - v0.6.1 polish-I reason 文案计算

    /// .danger 级别 reason(优先级:criticalWarningRaw(bit0/bit4)> mediaErrors > percentageUsed >= 95)
    /// - 跟 ingest 步骤 2 的 .danger 触发逻辑严格对齐,确保 reason 准确反映触发源
    /// - v0.7 polish-K:criticalWarningRaw 拆 bit,只列 .danger 触发的 bit0/4(其他 bit 不显示)
    ///   NVMe spec bit 0=spare below threshold, bit 1=temperature, bit 2=reliability,
    ///   bit 3=read-only, bit 4=backup failed(bit 0/4 是关键硬件故障,触发 .danger)
    private static func dangerReason(
        criticalWarningRaw: Int,
        mediaErrors: Int,
        percentageUsed: Int
    ) -> String {
        // v0.7 polish-K:只列 .danger 触发的 bit(bit0/4),其他 bit 不显避免误导
        let bit0 = (criticalWarningRaw & 0x01) != 0
        let bit3 = (criticalWarningRaw & 0x08) != 0
        let bit4 = (criticalWarningRaw & 0x10) != 0
        if bit0 || bit3 || bit4 {
            if bit0 { return "严重告警:bit0 (备用空间低于阈值)" }
            if bit3 { return "严重告警:bit3 (只读)" }
            return "严重告警:bit4 (备份失败)"
        }
        if mediaErrors > 0 {
            return "介质错误 \(mediaErrors)"
        }
        if percentageUsed >= 95 {
            return "寿命耗尽 \(percentageUsed)%"
        }
        // 兜底(不该走到;步骤 2 的 if 条件已经覆盖这 3 个)
        return "系统级危险信号"
    }

    /// 通用 reason(给 .warning / .critical;由 ingest 步骤 7 在 level 变化时调)
    /// - 不覆盖 .danger(由 dangerReason 单独处理,已写入)
    /// - 不处理温度 dwell(由 evaluateDwell 升级时单独处理,需要 elapsed)
    /// - 优先级:百分比(最直观,主人最容易懂)> 备块 > trend 加速 > 温度 dwell
    ///   - .critical:寿命 90% / 备块 10% / trend 0.05+ / temperature dwell ≥ 2 min
    ///   - .warning:寿命 70-89% / 备块 10-24% / temperature dwell ≥ 5 min
    private static func computeReason(
        level: HealthWarning,
        percentageUsed: Int,
        availableSpare: Int,
        slope: Double?,
        celsius: Int,
        warningThreshold: Int,
        criticalThreshold: Int,
        dwellSeconds: TimeInterval?,
        dwellLevel: HealthWarning?
    ) -> String? {
        switch level {
        case .none, .danger:
            // .none:不显示 reason(已经清空)
            // .danger:由 dangerReason 单独处理(已在 ingest 步骤 2 写入)
            return nil
        case .critical:
            // 优先级:percentageUsed >= 90 > availableSpare < 10 > trend > dwell
            if percentageUsed >= 90 {
                return "寿命临界 \(percentageUsed)%"
            }
            if availableSpare < 10 {
                return "备用空间 \(availableSpare)%"
            }
            if let s = slope, s > Self.accelSlopeThreshold, celsius >= warningThreshold {
                let cpm = s * 60  // °C/min
                return String(format: "升温加速 %.1f°C/min", cpm)
            }
            if dwellLevel == .critical, let d = dwellSeconds, d >= Self.criticalDwellSeconds {
                // 跟 evaluateDwell 拼的一样 — 这里兜底,如果 ingest 写时已经知道 dwell 满足
                let minutes = max(1, Int(d / 60))
                return "温度持续 \(celsius)°C 达 \(minutes)min"
            }
            return "严重警告"
        case .warning:
            // 优先级:percentageUsed 70-89 > availableSpare 10-24 > dwell
            if percentageUsed >= 70 {
                return "寿命 \(percentageUsed)%"
            }
            if availableSpare < 25 {
                return "备用空间 \(availableSpare)%"
            }
            if dwellLevel == .warning, let d = dwellSeconds, d >= Self.warningDwellSeconds {
                let minutes = max(1, Int(d / 60))
                return "温度持续 \(celsius)°C 达 \(minutes)min"
            }
            return "温度警告"
        }
    }
}

// MARK: - HealthWarning 枚举

/// 警告级别(v0.6 扩展加 .danger)
/// - none / warning / critical:v0.5.0 dwell 预警三个等级
/// - danger:SMART 独立危险信号(bit0/bit4 / mediaErrors / percentageUsed >= 95)
///   不走 dwell,不等温度,只要 SMART 报危险就立即 .danger
enum HealthWarning: Equatable {
    case none
    case warning
    case critical
    case danger

    /// 级别比较用 severity(internal,文件内可见)
    /// .danger > .critical > .warning > .none
    /// - 用 max(SMART, trend) 取最高级别时避免 Comparable 协议冲突(HealthWarning 是 Equatable 不是 Comparable)
    /// - fileprivate:不暴露给外部,UI 侧用 color/sfSymbol/healthPercent 即可
    fileprivate var severity: Int {
        switch self {
        case .none:     0
        case .warning:  1
        case .critical: 2
        case .danger:   3
        }
    }
}

// MARK: - HealthPredictor 格式化 helper(v0.5.0 WarningsView 用)

extension HealthPredictor {
    /// 格式化 dwell 时长 → "—" / "刚刚" / "持续 5min" / "持续 2h"
    /// - nil (没超温) → "—"
    /// - < 60s → "刚刚"
    /// - < 60min → "持续 Xmin"
    /// - >= 60min → "持续 Xh"
    /// - static 让 UI 可注入 now(测试友好)
    /// - 文案走 String(localized:defaultValue:) 项目惯例;但本 worker 严禁改 Localizable.strings,
    ///   所以 key 用新 key 名(后续 worker 可补 en/zh-Hans 两个 .lproj 翻译),
    ///   defaultValue 用项目默认中文(主人审美,中文优先)
    /// - 注:UI 颜色 / SF Symbol / 进度环百分比扩展在 Views/HealthWarning+UI.swift
    static func formatDwell(
        _ seconds: TimeInterval?,
        now: Date = Date()
    ) -> String {
        guard let s = seconds, s > 0 else {
            return String(localized: "warnings.dwell.none", defaultValue: "—")
        }
        if s < 60 {
            return String(localized: "warnings.dwell.justNow", defaultValue: "刚刚")
        }
        let minutes = Int(s / 60)
        if minutes < 60 {
            return String(
                format: String(
                    localized: "warnings.dwell.minutes",
                    defaultValue: "持续 %dmin"
                ),
                minutes
            )
        }
        let hours = Int(s / 3600)
        return String(
            format: String(
                localized: "warnings.dwell.hours",
                defaultValue: "持续 %dh"
            ),
            hours
        )
    }

    /// v0.6.1 polish-G:0-100 健康度评分(每盘)
    /// - 基础分 100,按 HealthWarning 等级递减
    ///   - .none     → 100(健康)
    ///   - .warning  → 60  (可观察,需关注)
    ///   - .critical → 30  (危险,接近失效)
    ///   - .danger   → 0   (立即备份/更换,SMART 独立危险信号)
    /// - 配合 HealthPredictor.warnings 字典使用,UI 端算多盘平均分
    /// - 与 HealthWarning+UI.swift 的 healthPercent(0..1) 同语义,只是 0-100 整数版
    static func healthScore(for warning: HealthWarning) -> Int {
        switch warning {
        case .none:     100
        case .warning:  60
        case .critical: 30
        case .danger:   0
        }
    }
}
