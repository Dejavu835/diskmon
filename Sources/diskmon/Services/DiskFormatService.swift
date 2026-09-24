import Foundation
import AppKit
import DiskMonCore

/// Spawn diskutil only after FormatPlan returns a command. Never uses mount -t ntfs -o rw.
@MainActor
@Observable
final class DiskFormatService {
    var ntfsKitAvailable: Bool = false
    var ntfsKitPersonality: String = "NTFSKit"
    var lastProbeOutput: String = ""
    var lastMessage: String?
    var isBusy: Bool = false
    /// Bundled GPL mkntfs from NTFSKit/ntfs-3g.
    var bundledMkntfsPath: String = DiskFormatService.locateBundledMkntfs() ?? ""

    var canFormatNTFS: Bool { ntfsKitAvailable || !bundledMkntfsPath.isEmpty }

    static func locateBundledMkntfs() -> String? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("ntfskit.fs/Contents/Resources/mkntfs"),
            bundle.url(forResource: "mkntfs", withExtension: nil),
            bundle.url(forResource: "mkntfs", withExtension: nil, subdirectory: "ntfskit.fs/Contents/Resources")
        ]
        for url in candidates {
            if let path = url?.path, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func refreshProbe() async {
        bundledMkntfsPath = Self.locateBundledMkntfs() ?? bundledMkntfsPath
        let output = await Self.runDiskutil(["listFilesystems"])
        lastProbeOutput = output
        let names = NTFSKitProbe.personalities(from: output)
        ntfsKitAvailable = NTFSKitProbe.isNTFSKitAvailable(personalities: names)
        if let p = NTFSKitProbe.ntfsKitPersonality(in: names) {
            ntfsKitPersonality = p
        }
    }

    func request(for disk: DiskInfo, personality: FormatPersonality, confirm: String, volumeName: String, partitionBSD: String = "", eraseWholeDisk: Bool = true) -> FormatRequest {
        FormatRequest(
            bsdName: disk.bsdName,
            displayName: disk.displayName,
            mountPoint: disk.mountPoint,
            isInternal: disk.isInternal,
            volumeName: volumeName,
            personality: personality,
            confirmToken: confirm,
            ntfsKitAvailable: ntfsKitAvailable,
            ntfsKitPersonality: ntfsKitPersonality,
            mkntfsPath: bundledMkntfsPath,
            partitionBSDName: partitionBSD,
            eraseWholeDisk: eraseWholeDisk
        )
    }

    func format(disk: DiskInfo, personality: FormatPersonality, confirm: String, volumeName: String, remountAfter: Bool = true, eraseWholeDisk: Bool = false) async -> String {
        var part = ""
        if !eraseWholeDisk || (personality == .ntfsKit && !ntfsKitAvailable) {
            part = await resolvePartitionBSD(disk)
        }
        if personality == .ntfsKit, !ntfsKitAvailable {
            let unmount = FormatPlan.planUnmountDisk(request(for: disk, personality: personality, confirm: "", volumeName: volumeName))
            if case .command = unmount {
                _ = await run(unmount)
            }
        }
        let req = request(
            for: disk,
            personality: personality,
            confirm: confirm,
            volumeName: volumeName,
            partitionBSD: part,
            eraseWholeDisk: eraseWholeDisk
        )
        let plan = FormatPlan.planEraseDisk(req)
        if case .refused(let reason) = plan {
            lastMessage = reason
            return reason
        }
        let erase = await run(plan)
        if !Self.isFailure(erase) {
            Self.notifyUserAction(uuid: disk.volumeUUID, op: "format")
        }
        if !remountAfter || Self.isFailure(erase) { return erase }
        let mounted = await mount(disk: disk)
        let check = await verifyFormatted(disk: disk, personality: personality, partitionBSD: part)
        let joined = [erase, mounted, check].filter { !$0.isEmpty }.joined(separator: "\n")
        lastMessage = joined
        return joined
    }

    /// User-tapped NTFS write. No process until this runs. Remount once; do not retry.
    func enableNTFSWrite(disk: DiskInfo) async -> String {
        guard disk.isNTFSVolume else { return "not ntfs" }
        if NTFSAccess.isBitLocker(disk.filesystemName) {
            return "BitLocker: unlock on Windows"
        }
        if !ntfsKitAvailable {
            return "extension off"
        }
        return await remount(disk: disk)
    }

    private func verifyFormatted(disk: DiskInfo, personality: FormatPersonality, partitionBSD: String) async -> String {
        let node = partitionBSD.isEmpty ? disk.bsdName : partitionBSD
        let info = await Self.runDiskutil(["info", node])
        guard let reported = Self.plistString(info, key: "FilesystemType") else {
            return ""
        }
        if FormatPlan.filesystemMatches(personality, reported: reported) {
            return "filesystem \(reported)"
        }
        return "filesystem mismatch: \(reported)"
    }

    /// Volume DeviceIdentifier from diskutil info; whole-disk names get s1.
    func resolvePartitionBSD(_ disk: DiskInfo) async -> String {
        if let mp = disk.mountPoint, !mp.isEmpty {
            let plist = await Self.runDiskutil(["info", "-plist", mp])
            if let id = Self.plistString(plist, key: "DeviceIdentifier"), !id.isEmpty {
                return id
            }
        }
        let bsd = disk.bsdName
        if bsd.range(of: #"disk\d+s\d+"#, options: .regularExpression) != nil {
            return bsd
        }
        return bsd + "s1"
    }

    nonisolated private static func plistString(_ xml: String, key: String) -> String? {
        let pattern = "<key>\(key)</key>\\s*<string>([^<]+)</string>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[r])
    }

    func unmount(disk: DiskInfo) async -> String {
        let req = request(for: disk, personality: .exfat, confirm: "", volumeName: disk.displayName)
        let out = await run(FormatPlan.planUnmountDisk(req))
        if !Self.isFailure(out) { Self.notifyUserAction(uuid: disk.volumeUUID, op: "unmount") }
        return out
    }

    func eject(disk: DiskInfo) async -> String {
        let req = request(for: disk, personality: .exfat, confirm: "", volumeName: disk.displayName)
        let out = await run(FormatPlan.planEject(req))
        if !Self.isFailure(out) { Self.notifyUserAction(uuid: disk.volumeUUID, op: "eject") }
        return out
    }

    func mount(disk: DiskInfo) async -> String {
        let req = request(for: disk, personality: .exfat, confirm: "", volumeName: disk.displayName)
        return await run(FormatPlan.planMountDisk(req))
    }

    /// Unmount + mountDisk so NTFSKit can replace a stale Apple NTFS read-only mount.
    func remount(disk: DiskInfo) async -> String {
        let req = request(for: disk, personality: .exfat, confirm: "", volumeName: disk.displayName)
        var logs: [String] = []
        for step in FormatPlan.planRemount(req) {
            if case .refused(let reason) = step {
                lastMessage = reason
                return reason
            }
            let out = await run(step)
            logs.append(out)
            if Self.isFailure(out) {
                let joined = logs.joined(separator: "\n")
                lastMessage = joined
                return joined
            }
        }
        let joined = logs.joined(separator: "\n")
        lastMessage = joined
        return joined
    }

    func rename(disk: DiskInfo, newName: String) async -> String {
        let req = request(for: disk, personality: .exfat, confirm: "", volumeName: newName)
        return await run(FormatPlan.planRename(req))
    }

    func openInFinder(_ disk: DiskInfo) -> String {
        guard let mp = disk.mountPoint, !mp.isEmpty else {
            return "not mounted"
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp, isDirectory: true))
        return "ok"
    }

    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    nonisolated private static func isFailure(_ message: String) -> Bool {
        message.hasPrefix("exit ") || message.hasPrefix("spawn failed") || message.hasPrefix("refused")
    }

    nonisolated static func notifyUserAction(uuid: String, op: String) {
        NotificationCenter.default.post(
            name: .diskmonUserDiskAction,
            object: nil,
            userInfo: ["uuid": uuid, "op": op]
        )
    }

    private func run(_ plan: FormatPlan.Outcome) async -> String {
        switch plan {
        case .refused(let reason):
            lastMessage = reason
            return reason
        case .command(let argv):
            isBusy = true
            defer { isBusy = false }
            let out = await Self.runArgv(argv)
            lastMessage = out
            return out
        }
    }

    nonisolated private static func runDiskutil(_ args: [String]) async -> String {
        await runArgv([FormatPlan.diskutil] + args)
    }

    nonisolated private static func runArgv(_ argv: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: argv[0])
                proc.arguments = Array(argv.dropFirst())
                let out = Pipe()
                let err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: combined.isEmpty ? "ok" : combined)
                    } else {
                        cont.resume(returning: "exit \(proc.terminationStatus): \(combined.prefix(400))")
                    }
                } catch {
                    cont.resume(returning: "spawn failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

extension Notification.Name {
    static let diskmonUserDiskAction = Notification.Name("com.homecenter.diskmon.userDiskAction")
}
