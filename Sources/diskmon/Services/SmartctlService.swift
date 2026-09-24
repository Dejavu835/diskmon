import Foundation
import DiskMonCore

/// smartctl 子进程封装 + NVMe SMART 文本解析
/// v0.2.0:解析扩展到 NVMe Log Page 0x02 全 16 字段 + 累计功耗估算
/// v0.7 polish-K:
///   - 字段全改 optional,partial parse 友好(未解析到的字段保持 nil,不再用旧默认值 0)
///   - 新增 NVMe Supported Power States 解析(第一状态行 max watt → powerConsumptionWatts)
///   - 删 cumulativeEnergyKWh 引用(估算值已废)
/// 退码语义:
///   0  = OK,解析 stdout
///   1  = SMART warning,解析 + 标记 warning
///   2  = SMART pre-fail,解析 + 标记 critical
///   251 = Full Disk Access 缺失,弹引导
///   其它 = 子进程错,log + 重试
actor SmartctlService {
    enum SmartctlError: Error, LocalizedError {
        case missingExecutable
        case needsFullDiskAccess
        case commandFailed(Int32, String)
        case parseFailed(String)
        /// USB 桥接 / 设备不透传 SMART(Darwin 上 JMicron T70 等常见)
        case notSupported(String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                return String(
                    localized: "errortag.smartctl.missing",
                    defaultValue: "smartctl not found. Install via: brew install smartmontools"
                )
            case .needsFullDiskAccess:
                return String(
                    localized: "errortag.fda",
                    defaultValue: "DiskMon needs Full Disk Access to read SMART data."
                )
            case .commandFailed(let code, let raw):
                return "smartctl exit \(code)\n\(raw.prefix(200))"
            case .parseFailed(let raw):
                return String(
                    localized: "error.parse",
                    defaultValue: "Unable to parse smartctl output"
                ) + "\n\(raw.prefix(200))"
            case .notSupported(let reason):
                return String(
                    localized: "error.smart.unsupported",
                    defaultValue: "SMART is not available on this disk"
                ) + "\n\(reason)"
            }
        }
    }

    /// 每个 BSD 名上次成功的 -d 类型(空字符串 = 不加 -d)
    /// 避免每 5s 把 nvme/sat/sntjmicron 全试一遍
    private var deviceTypeCache: [String: String] = [:]
    /// 已确认不支持 SMART 的 BSD,下次发现换节点才清
    private var unsupportedDevices: Set<String> = []

    /// 完整子进程读取 + 解析(供 HealthMonitor 调用)
    /// v0.9.5:不再写死 `-d nvme`。USB SAT / JMicron / 纯 SCSI 盘按候选类型回退。
    /// - Returns: (SmartData, rawOutputText)
    func read(device: String) async throws -> (SmartData, String) {
        let node = device.hasPrefix("/dev/") ? device : "/dev/\(device)"
        if unsupportedDevices.contains(node) {
            throw SmartctlError.notSupported("cached: SMART not available on \(node)")
        }
        guard SmartctlPathLocator.resolve() != nil else {
            throw SmartctlError.missingExecutable
        }
        // 候选顺序:缓存命中优先 → NVMe(TB 外接盘主路径) → auto → sat → JMicron USB NVMe/ATA
        let cached = deviceTypeCache[node]
        let candidates: [String?]
        if let cached {
            candidates = [cached.isEmpty ? nil : cached]
        } else {
            candidates = ["nvme", nil, "sat", "sntjmicron", "usbjmicron"]
        }
        var lastError: SmartctlError?
        for dtype in candidates {
            do {
                let (data, raw) = try runOnce(node: node, type: dtype)
                deviceTypeCache[node] = dtype ?? ""
                unsupportedDevices.remove(node)
                return (data, raw)
            } catch SmartctlError.needsFullDiskAccess {
                throw SmartctlError.needsFullDiskAccess
            } catch SmartctlError.missingExecutable {
                throw SmartctlError.missingExecutable
            } catch let e as SmartctlError {
                lastError = e
                continue
            }
        }
        unsupportedDevices.insert(node)
        throw lastError ?? SmartctlError.notSupported(node)
    }

    /// 盘拔插后 BSD 变了,清失败缓存(discoverOnce 调)
    func invalidateDevice(_ device: String) {
        let node = device.hasPrefix("/dev/") ? device : "/dev/\(device)"
        deviceTypeCache.removeValue(forKey: node)
        unsupportedDevices.remove(node)
    }

    private func runOnce(node: String, type: String?) throws -> (SmartData, String) {
        guard let path = SmartctlPathLocator.resolve() else {
            throw SmartctlError.missingExecutable
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        if let type, !type.isEmpty {
            proc.arguments = ["-a", "-d", type, node]
        } else {
            proc.arguments = ["-a", node]
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let deadline = Date().addingTimeInterval(2.5)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            throw SmartctlError.commandFailed(-2, "smartctl timed out after 2.5s")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let combined = stdout + stderr
        let code = proc.terminationStatus
        switch code {
        case 251:
            throw SmartctlError.needsFullDiskAccess
        case 0, 1, 2:
            if let data = Self.parse(stdout: stdout) {
                return (data, stdout)
            }
            throw SmartctlError.parseFailed(stdout)
        default:
            throw SmartctlError.commandFailed(code, combined)
        }
    }

    // MARK: - 解析(NVMe Log 0x02,smartctl 7.5 实测)

    /// 解析 smartctl -a -d nvme 输出 → SmartData
    /// v0.2.0:16 字段 + cumulativeEnergyKWh 自动派生
    /// v0.7 polish-K:
    ///   - 字段全 optional,partial parse 友好(解析失败不写,保持 nil)
    ///   - 删 cumulativeEnergyKWh 派生(SmartData 字段已删)
    ///   - 新增 NVMe Supported Power States 解析(填 powerConsumptionWatts)
    /// - 不再返回 nil(partial-tolerant)— 至少 SMART 关键字段存在即可用
    ///   - 真完全没 SMART 块(modelNumber 也空)才返回 nil(让调用方视为 "parseFailed")
    static func parse(stdout: String) -> SmartData? {
        var data = SmartData()
        var sawAny = false
        // v0.7 polish-K:Supported Power States 块单独处理(在 SMART DATA 块之前,多行格式)
        //   找到 "Supported Power States" 标题行后,下一行是表头,再下一行开始是数据行
        //   数据行格式:" 0 +     4.20W    3.70W       -    0  0  0  0        0       0"
        //   取第一状态行(0 状态,通常 max power 最大)的 max watt
        var inPowerStatesBlock = false
        var powerStatesHeaderSeen = false

        for raw in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            // v0.7 polish-K:检测 Supported Power States 块
            //   - 标题行: "Supported Power States"
            //   - 表头行: "St Op     Max   Active     Idle   RL RT WL WT  Ent_Lat  Ex_Lat"
            //   - 数据行: " 0 +     4.20W    3.70W       -    0  0  0  0        0       0"
            if line.hasPrefix("Supported Power States") {
                inPowerStatesBlock = true
                powerStatesHeaderSeen = false
                continue
            }
            if inPowerStatesBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Power States 块结束条件(空行 / 下一段标题"===")— 显式退出
                //   - smartctl 7.5 输出:Power States 块后有空行 → "=== START OF SMART DATA SECTION ==="
                //   - 旧逻辑只检查空行;若未来 smartctl 输出无空行 + 直接 === 段,
                //     我们要主动检测并退出,避免永远困在 block 里
                if trimmed.isEmpty || trimmed.hasPrefix("===") {
                    inPowerStatesBlock = false
                    powerStatesHeaderSeen = false
                    continue
                }
                // 表头行含 "St" 或 "Op"(空数据行跳过)
                if !powerStatesHeaderSeen {
                    if trimmed.hasPrefix("St") || trimmed.contains("Max") {
                        powerStatesHeaderSeen = true
                    }
                    continue
                }
                if let state = NVMePowerStateParser.parseLine(line) {
                    data.nvmePowerStates.append(state)
                    sawAny = true
                }
                continue
            }

            // 典型格式:
            //   Temperature:                        67 Celsius
            //   Available Spare:                    100%
            //   Data Units Read:                    25,213,506 [12.9 TB]
            //   Critical Warning:                   0x00
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if val.isEmpty { continue }

            switch key {
            case "Model Number":
                data.modelNumber = val
                sawAny = true
            case "Serial Number":
                data.serialNumber = val
            case "Firmware Version":
                data.firmwareVersion = val
            case "SMART overall-health self-assessment test result":
                // PASSED / FAILED — v0.7 polish-K:只有解析成功才写 healthPassed(保持 nil = 未采集)
                data.healthPassed = (val == "PASSED")
                sawAny = true
            case "Critical Warning":
                // 0x00 / 0x04 形式
                if let hex = parseHex(val) {
                    data.criticalWarningRaw = hex
                    sawAny = true
                }
            case "Temperature", "Current Drive Temperature", "Current Temperature":
                if let n = intFrom(val) {
                    data.celsius = n
                    sawAny = true
                }
            case "Available Spare":
                if let n = intFrom(val) {
                    data.availableSpare = n
                }
            case "Percentage Used":
                if let n = intFrom(val) {
                    data.percentageUsed = n
                }
            case "Media and Data Integrity Errors":
                if let n = intFrom(val) {
                    data.mediaErrors = n
                    sawAny = true
                }
            case "Unsafe Shutdowns":
                if let n = intFrom(val) {
                    data.unsafeShutdowns = n
                }
            case "Power On Hours":
                if let n = intFrom(val) {
                    data.powerOnHours = n
                }
            case "Power Cycles":
                if let n = intFrom(val) {
                    data.powerCycles = n
                }
            case "Data Units Read":
                if let n = parseTB(val) {
                    data.dataUnitsReadTB = n
                }
            case "Data Units Written":
                if let n = parseTB(val) {
                    data.dataUnitsWrittenTB = n
                }
            case "Warning  Comp. Temperature Time":
                // 注意 smartctl 7.5 是双空格"Warning  Comp."
                if let n = intFrom(val) {
                    data.warningCompTempTime = n
                }
            case "Critical Comp. Temperature Time":
                if let n = intFrom(val) {
                    data.criticalCompTempTime = n
                }
            default:
                continue
            }
        }
        // ATA / USB SAT 属性表(ssd512 一类 SATA SSD 走这条,不是 NVMe Log 0x02)
        if Self.parseATAAttributes(stdout: stdout, into: &data) {
            sawAny = true
        }
        if let peak = NVMePowerStateParser.peakWatts(from: data.nvmePowerStates) {
            data.powerConsumptionWatts = peak
        }
        return sawAny ? data : nil
    }

    /// 解析 ATA SMART 属性表 → 填 SmartData
    /// 典型行:
    ///   194 Temperature_Celsius     0x0022   050   050   000    Old_age   Always       -       50
    ///   190 Airflow_Temperature_Cel 0x0022   061   054   045    Old_age   Always       -       39 (Min/Max 21/48)
    /// 返回 true 表示至少填了一个字段
    @discardableResult
    static func parseATAAttributes(stdout: String, into data: inout SmartData) -> Bool {
        var filled = false
        for raw in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // ATA 表: ID NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW...
            guard parts.count >= 10, Int(parts[0]) != nil else { continue }
            let name = parts[1]
            let rawInt = intFrom(parts[9])
            switch name {
            case "Temperature_Celsius", "Airflow_Temperature_Cel", "Temperature_Internal":
                if data.celsius == nil, let n = rawInt {
                    data.celsius = n
                    filled = true
                }
            case "Offline_Uncorrectable", "Reported_Uncorrect":
                // Uncorrectable only. Reallocated / pending are wear, not NVMe mediaErrors.
                if let n = rawInt, n > 0 {
                    data.mediaErrors = (data.mediaErrors ?? 0) + n
                    filled = true
                }
            case "Power_On_Hours", "Power_On_Hours_and_Msec":
                if data.powerOnHours == nil, let n = rawInt {
                    data.powerOnHours = n
                    filled = true
                }
            case "Power_Cycle_Count":
                if data.powerCycles == nil, let n = rawInt {
                    data.powerCycles = n
                    filled = true
                }
            case "Wear_Leveling_Count", "Percent_Lifetime_Remain",
                 "SSD_Life_Left", "Remaining_Lifetime_Perc":
                // VALUE = remaining life. RAW is usually erase count — never a percent.
                if data.percentageUsed == nil, parts.count > 3,
                   let used = SmartParse.percentageUsedFromWearValue(parts[3]) {
                    data.percentageUsed = used
                    filled = true
                }
            case "Available_Reservd_Space":
                // VALUE is remaining spare %. RAW is not a percent.
                if data.availableSpare == nil, parts.count > 3,
                   let spare = SmartParse.sparePercentFromNormalizedValue(parts[3]) {
                    data.availableSpare = spare
                    filled = true
                }
            case "Unsafe_Shutdown_Count", "Unexpected_Power_Loss_Ct":
                if data.unsafeShutdowns == nil, let n = rawInt {
                    data.unsafeShutdowns = n
                    filled = true
                }
            default:
                continue
            }
        }
        return filled
    }

    // MARK: - 字段解析 helpers

    private static func parseTB(_ s: String) -> Double? {
        SmartParse.dataUnitsToTB(s)
    }

    /// "100" 或 "100%" → 100
    private static func intFrom(_ s: String) -> Int? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .split(whereSeparator: { !$0.isNumber && $0 != "-" })
            .first
        return cleaned.flatMap { Int($0) }
    }

    /// "0x00" / "0x04" → 0 / 4
    private static func parseHex(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            return Int(t.dropFirst(2), radix: 16)
        }
        return Int(t)
    }

}

// v0.7 polish-K 注释:
//   Supported Power States 解析算法(给 grok 复盘):
//   1) 找 "Supported Power States" 标题行
//   2) 跳过表头行("St Op     Max   Active     Idle   RL RT WL WT  Ent_Lat  Ex_Lat")
//   3) 第一行数据(状态 0)= " 0 +     4.20W    3.70W       -    0  0  0  0        0       0"
//   4) split by whitespace → [state_num, op, max, active, idle, ...]
//   5) parts[2] = "4.20W" → strip "W" → Double("4.20") = 4.20
//   6) 只取 op == "+"(active),排除 op == "-"(idle 状态 0.0050W 不是硬件工作功耗)
//   7) 实际效果:WD Blue SN570 1TB 实测 powerConsumptionWatts = 4.20W
