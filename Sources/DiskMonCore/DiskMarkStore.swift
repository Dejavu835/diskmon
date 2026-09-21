import Foundation

public enum DiskUserMark: String, Equatable, Sendable {
    case none = ""
    case trouble = "trouble"
}

/// Per-volume-UUID marks. JSON map, no UserDefaults in this type.
public struct DiskMarkStore: Equatable, Sendable {
    public var raw: [String: String]

    public init(_ raw: [String: String] = [:]) {
        self.raw = raw
    }

    public func mark(for uuid: String) -> DiskUserMark {
        guard let token = raw[uuid], let mark = DiskUserMark(rawValue: token) else {
            return .none
        }
        return mark
    }

    public mutating func set(_ mark: DiskUserMark, for uuid: String) {
        let id = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if mark == .none {
            raw.removeValue(forKey: id)
        } else {
            raw[id] = mark.rawValue
        }
    }

    public static func parse(_ json: String) -> DiskMarkStore {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return DiskMarkStore()
        }
        return DiskMarkStore(dict)
    }

    public func json() -> String {
        guard let data = try? JSONEncoder().encode(raw),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
