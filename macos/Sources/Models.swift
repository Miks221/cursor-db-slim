import Foundation

struct CleanFilter: Equatable {
    var cleanArchived = true
    var cleanInactive = true
    var inactiveDays = 7
    var cleanCreatedBefore = false
    var createdBeforeDays = 30
    var useDateRange = false
    var rangeStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    var rangeEnd = Date()
    var followSubagents = true
    var cleanDrafts = false
    var cleanWorktree = false
    var cleanSpec = false
    var cleanProject = false
    var cleanBestOfN = false
}

struct Header {
    var id: String
    var created: Int64
    var updated: Int64
    var archived: Bool
    var isSub: Bool
    var root: String?
    var isDraft: Bool
    var isWorktree: Bool
    var isSpec: Bool
    var isProject: Bool
    var isBestOfN: Bool
    var name: String
}

struct ClassifyResult {
    var heads: [String: Header]
    var keep: Set<String>
    var purge: Set<String>
    var archived: Set<String>
    var stale: Set<String>
    var tooOld: Set<String>
    var outOfRange: Set<String>
    var drafts: Set<String>
    var worktrees: Set<String>
    var specs: Set<String>
    var projects: Set<String>
    var bestOfN: Set<String>
}

struct PrefixStat: Identifiable {
    var id: String { name }
    var name: String
    var rows: Int
    var bytes: Int64
}

struct DryRunReport {
    var classify: ClassifyResult
    var stats: [PrefixStat]
    var keepRows: Int
    var keepBytes: Int64
    var projected: Int64
    var droppedBlobRows: Int
    var currentSize: Int64
    var freeSpace: Int64
}

struct VerifyResult {
    var integrityOK: Bool
    var headerCount: Int
    var kvCount: Int
    var nonTextKeys: Int
    var fileSize: Int64
    var email: String?
    var hasToken: Bool
}

struct BackupItem: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var kind: String
    var size: Int64
    var modified: Date

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum AppTab: String, CaseIterable, Identifiable {
    case clean = "清理"
    case backups = "备份"
    var id: String { rawValue }
}

enum BackupStore {
    static func items(beside dbPath: String) -> [BackupItem] {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let live = URL(fileURLWithPath: dbPath).lastPathComponent
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        var stems: [String: (size: Int64, date: Date)] = [:]
        for name in names {
            guard name.hasPrefix(live + ".") else { continue }
            if name.hasSuffix(".empty-after-corruption") { continue }
            let url = dir.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let stem: String
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") {
                stem = String(name.dropLast(4))
            } else {
                stem = name
            }
            if stem == live { continue }
            var cur = stems[stem] ?? (0, .distantPast)
            cur.size += size
            if date > cur.date { cur.date = date }
            stems[stem] = cur
        }

        return stems.map { stem, info in
            BackupItem(
                path: dir.appendingPathComponent(stem).path,
                kind: kindLabel(stem, live: live),
                size: info.size,
                modified: info.date
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    static func kindLabel(_ stem: String, live: String) -> String {
        let suffix = String(stem.dropFirst(live.count))
        if suffix.hasPrefix(".pre-slim") { return "清理前原库" }
        if suffix.hasPrefix(".pre-typefix") { return "类型修复前" }
        if suffix.hasPrefix(".backup") { return "Cursor 自动备份" }
        if suffix.hasPrefix(".bak-") { return "清理备份" }
        if suffix.hasPrefix(".repaired") || suffix.hasPrefix(".slim") { return "未完成的半成品" }
        return "其它备份"
    }

    static func snapshotNeed(dbSize: Int64) -> Int64 {
        dbSize + 512 * 1024 * 1024
    }

    static func delete(_ item: BackupItem) throws {
        let fm = FileManager.default
        for extra in ["", "-wal", "-shm"] {
            let p = item.path + extra
            if fm.fileExists(atPath: p) {
                try fm.removeItem(atPath: p)
            }
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

func friendlyError(_ error: Error) -> String {
    friendlySQLite(error.localizedDescription)
}

func friendlySQLite(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("unable to open database file") {
        return "打不开这个库文件。如果备份或清理已经走完，新库多半已经就位，直接打开 Cursor 看会话和登录即可。若 Cursor 也打不开，把同目录的 state.vscdb-wal 和 state.vscdb-shm 先挪到别处再试。"
    }
    if lower.contains("database is locked") || lower.contains("database is busy") {
        return "库正被占用。请确认 Cursor 已完全退出（菜单里退出，不要只关窗口）后再试。"
    }
    if lower.contains("disk i/o error") || (lower.contains("disk") && lower.contains("full")) {
        return "磁盘读写失败或空间不够，写不完新库或备份。"
    }
    if raw.hasPrefix("打开数据库失败：") {
        return friendlySQLite(String(raw.dropFirst("打开数据库失败：".count)))
    }
    return raw
}

func humanSize(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n)
    var i = 0
    while v >= 1024 && i < units.count - 1 {
        v /= 1024
        i += 1
    }
    return String(format: v >= 10 || i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func daysAgoMs(_ days: Int) -> Int64 {
    nowMs() - Int64(days) * 86_400_000
}

func dateMs(_ d: Date) -> Int64 {
    Int64(d.timeIntervalSince1970 * 1000)
}

func defaultDBURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
}
