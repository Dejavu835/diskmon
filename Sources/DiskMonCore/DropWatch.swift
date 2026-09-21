import Foundation

public enum DropKind: String, Equatable, Sendable, Codable {
    case unmounted
    case ejected
    case dropped
}

public enum DropHint: String, Equatable, Sendable, Codable {
    case userAction
    case stillConnected
    case afterSleep
    case flap
    case usbCableOrPort
    case unknown
}

public struct DropEvent: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var uuid: String
    public var name: String
    public var bsdName: String
    public var bus: String?
    public var serial: String?
    public var at: Date
    public var kind: DropKind
    public var hint: DropHint
    public var returnedAt: Date?

    public init(
        id: String = UUID().uuidString,
        uuid: String,
        name: String,
        bsdName: String,
        bus: String? = nil,
        serial: String? = nil,
        at: Date,
        kind: DropKind,
        hint: DropHint,
        returnedAt: Date? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.bsdName = bsdName
        self.bus = bus
        self.serial = serial
        self.at = at
        self.kind = kind
        self.hint = hint
        self.returnedAt = returnedAt
    }

    public var identity: DropIdentity {
        DropIdentity(uuid: uuid, name: name, serial: serial)
    }
}

public struct DropContext: Equatable, Sendable {
    public var bsdNodeExists: Bool
    public var recentUserEject: Bool
    public var recentUserUnmount: Bool
    /// Finder / 系统卸载（didUnmount），不是本 App 点的，也不是拔线。
    public var recentWorkspaceUnmount: Bool
    /// Mounted .dmg / installer image — expected lifetime, never a cable fault.
    public var isDiskImage: Bool
    public var secondsSinceSleepOrWake: TimeInterval?
    public var secondsSincePriorDrop: TimeInterval?
    public var isUSB: Bool

    public init(
        bsdNodeExists: Bool,
        recentUserEject: Bool,
        recentUserUnmount: Bool,
        recentWorkspaceUnmount: Bool = false,
        isDiskImage: Bool = false,
        secondsSinceSleepOrWake: TimeInterval? = nil,
        secondsSincePriorDrop: TimeInterval? = nil,
        isUSB: Bool
    ) {
        self.bsdNodeExists = bsdNodeExists
        self.recentUserEject = recentUserEject
        self.recentUserUnmount = recentUserUnmount
        self.recentWorkspaceUnmount = recentWorkspaceUnmount
        self.isDiskImage = isDiskImage
        self.secondsSinceSleepOrWake = secondsSinceSleepOrWake
        self.secondsSincePriorDrop = secondsSincePriorDrop
        self.isUSB = isUSB
    }
}

/// Match a gone disk to a live one when Volume UUID changed after replug.
public struct DropIdentity: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var serial: String?

    public init(uuid: String, name: String, serial: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.serial = serial
    }

    public func matches(_ other: DropIdentity) -> Bool {
        if !uuid.isEmpty, uuid == other.uuid { return true }
        if let a = serial, let b = other.serial {
            let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
            let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
            if !x.isEmpty, x.caseInsensitiveCompare(y) == .orderedSame { return true }
        }
        let n = Self.norm(name)
        let m = Self.norm(other.name)
        return !n.isEmpty && n == m
    }

    public static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum DropClassifier {
    public static let userActionWindow: TimeInterval = 60
    public static let sleepWindow: TimeInterval = 120
    public static let flapWindow: TimeInterval = 600

    public static func classify(_ ctx: DropContext) -> (DropKind, DropHint) {
        // Installer / mounted images vanish by design — never a hardware drop.
        if ctx.isDiskImage {
            return (.ejected, .userAction)
        }
        if ctx.recentUserEject {
            return (.ejected, .userAction)
        }
        if ctx.recentUserUnmount || ctx.recentWorkspaceUnmount {
            return (.unmounted, .userAction)
        }
        if ctx.bsdNodeExists {
            return (.unmounted, .stillConnected)
        }
        if let prior = ctx.secondsSincePriorDrop, prior <= flapWindow {
            return (.dropped, .flap)
        }
        if let sleep = ctx.secondsSinceSleepOrWake, sleep <= sleepWindow {
            return (.dropped, .afterSleep)
        }
        if ctx.isUSB {
            return (.dropped, .usbCableOrPort)
        }
        return (.dropped, .unknown)
    }

    public static func wholeDiskBSD(_ bsd: String) -> String {
        let t = bsd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("disk") else { return t }
        var i = t.index(t.startIndex, offsetBy: 4)
        while i < t.endIndex, t[i].isNumber {
            i = t.index(after: i)
        }
        return String(t[..<i])
    }
}

public struct DropWatchStore: Equatable, Sendable {
    public var events: [DropEvent]
    public static let cap = 40

    public init(_ events: [DropEvent] = []) {
        self.events = events
    }

    public mutating func append(_ event: DropEvent, now: Date = Date()) {
        events.append(event)
        let start = now.addingTimeInterval(-7 * 86_400)
        events = Array(events.filter { $0.at >= start }.suffix(Self.cap))
    }

    public mutating func markReturned(uuid: String, at: Date) {
        markReturned(matching: DropIdentity(uuid: uuid, name: "", serial: nil), at: at)
    }

    public mutating func markReturned(matching id: DropIdentity, at: Date) {
        guard let i = events.lastIndex(where: { $0.returnedAt == nil && $0.identity.matches(id) }) else { return }
        events[i].returnedAt = at
        if events[i].uuid != id.uuid, !id.uuid.isEmpty {
            events[i].uuid = id.uuid
        }
    }

    public func lastOpenDrop(uuid: String) -> DropEvent? {
        events.last(where: { $0.uuid == uuid && $0.returnedAt == nil })
    }

    public func lastDrop(uuid: String) -> DropEvent? {
        events.last(where: { $0.uuid == uuid && $0.kind == .dropped })
    }

    public func drops(since: Date) -> [DropEvent] {
        events.filter { $0.at >= since && $0.kind == .dropped }
    }

    public func openDrops() -> [DropEvent] {
        events.filter { $0.kind == .dropped && $0.returnedAt == nil }
    }

    public static func parse(_ json: String) -> DropWatchStore {
        guard let data = json.data(using: .utf8) else { return DropWatchStore() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([DropEvent].self, from: data) else {
            return DropWatchStore()
        }
        return DropWatchStore(list)
    }

    public func json() -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(events),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}

/// What the 掉盘 card should say *right now*. Unmount/eject are not anomalies.
public enum DropNowState: Equatable, Sendable {
    case steady
    /// Finder / in-app eject or unmount. Not a fault.
    case expectedGone(DropEvent)
    case missing(DropEvent)
    case flap(count: Int, last: DropEvent)
}

public struct DropRow: Equatable, Sendable, Identifiable {
    public var event: DropEvent
    public var times: Int
    public var id: String { event.id }

    public init(event: DropEvent, times: Int = 1) {
        self.event = event
        self.times = times
    }
}

public enum DropStory {
    /// Ignore installer / mounted images forever (historical events too).
    public static func hardwareEvents(_ events: [DropEvent]) -> [DropEvent] {
        events.filter { ev in
            let bus = (ev.bus ?? "").uppercased()
            return !bus.contains("DISK IMAGE") && !bus.contains("DISKIMAGE")
        }
    }

    /// Open unexpected drop > 24h flaps that already came back > nothing to worry about.
    public static func now(
        _ events: [DropEvent],
        online: [DropIdentity] = [],
        expectedGone: DropEvent? = nil,
        at: Date = Date()
    ) -> DropNowState {
        let events = hardwareEvents(events)
        if let open = events.last(where: { $0.kind == .dropped && $0.returnedAt == nil }) {
            let stillGone = online.allSatisfy { !$0.matches(open.identity) }
            if stillGone { return .missing(open) }
        }
        if let gone = expectedGone {
            let stillGone = online.allSatisfy { !$0.matches(gone.identity) }
            if stillGone { return .expectedGone(gone) }
        }
        let day = events.filter { $0.kind == .dropped && $0.at >= at.addingTimeInterval(-86_400) }
        if day.count >= 2, let last = day.last {
            return .flap(count: day.count, last: last)
        }
        return .steady
    }

    /// Newest unexpected drops only, collapsed per disk within 1h.
    public static func history(_ events: [DropEvent], limit: Int = 2) -> [DropRow] {
        let dropped = hardwareEvents(events).filter { $0.kind == .dropped }
        var rows: [DropRow] = []
        for ev in dropped.reversed() {
            if let i = rows.firstIndex(where: {
                $0.event.uuid == ev.uuid && abs($0.event.at.timeIntervalSince(ev.at)) < 3600
            }) {
                var row = rows[i]
                row.times += 1
                if ev.at > row.event.at { row.event = ev }
                rows[i] = row
            } else {
                rows.append(DropRow(event: ev, times: 1))
            }
            if rows.count >= limit { break }
        }
        return rows
    }
}
