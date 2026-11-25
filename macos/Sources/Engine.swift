import Foundation
import SQLite3

let composerScoped = [
    "bubbleId", "composerData", "checkpointId", "composerVirtualRowHeights",
    "ofsContent", "codeBlockPartialInlineDiffFates",
]
let keepWholesale = ["inlineDiff", "composer.content."]

actor Engine {
    func classify(dbPath: String, filter: CleanFilter) throws -> ClassifyResult {
        let box = SQLiteBox()
        try box.open(dbPath, readonly: true)
        defer { box.close() }

        let rows = try box.queryRows(
            "SELECT composerId, createdAt, lastUpdatedAt, isArchived, isSubagent, value FROM composerHeaders"
        )
        var heads: [String: Header] = [:]
        for row in rows {
            guard let cid = row[0].string else { continue }
            let raw = row[5].string ?? "{}"
            let info = parseJSON(raw)
            let sub = info["subagentInfo"] as? [String: Any]
            let root = [
                sub?["rootParentConversationId"], sub?["parentComposerId"], info["parentComposerId"],
            ].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
            heads[cid] = Header(
                id: cid,
                created: row[1].int,
                updated: row[2].int,
                archived: row[3].int != 0,
                isSub: row[4].int != 0 || bool(info["isSubagent"]),
                root: root,
                isDraft: cid == "empty-state-draft" || bool(info["isDraft"]),
                isWorktree: bool(info["isWorktree"]),
                isSpec: bool(info["isSpec"]),
                isProject: bool(info["isProject"]),
                isBestOfN: bool(info["isBestOfNSubcomposer"]),
                name: (info["name"] as? String) ?? ""
            )
        }
        for (cid, h) in heads where h.isSub || h.isBestOfN {
            var root = h.root
            var seen: Set<String> = [cid]
            while let r = root, let parent = heads[r], parent.isSub || parent.isBestOfN,
                  let next = parent.root, !next.isEmpty, !seen.contains(r) {
                seen.insert(r)
                root = next
            }
            heads[cid]?.root = root
        }

        let staleCut = daysAgoMs(filter.inactiveDays)
        let createdCut = daysAgoMs(filter.createdBeforeDays)
        let rangeLo = dateMs(filter.rangeStart)
        let rangeHi = dateMs(filter.rangeEnd) + 86_400_000 - 1

        var archived = Set<String>()
        var stale = Set<String>()
        var tooOld = Set<String>()
        var outOfRange = Set<String>()
        var drafts = Set<String>()
        var worktrees = Set<String>()
        var specs = Set<String>()
        var projects = Set<String>()
        var bestOfN = Set<String>()
        var selfPurge = Set<String>()

        let typeFilterOn = filter.cleanDrafts || filter.cleanWorktree
            || filter.cleanSpec || filter.cleanProject || filter.cleanBestOfN
        let rangeFilterOn = filter.cleanArchived || filter.cleanInactive
            || filter.cleanCreatedBefore || filter.useDateRange

        for (cid, h) in heads {
            var rangeHit = false
            if filter.cleanArchived && h.archived {
                archived.insert(cid); rangeHit = true
            }
            if filter.cleanInactive && !h.archived && h.updated < staleCut {
                stale.insert(cid); rangeHit = true
            }
            if filter.cleanCreatedBefore && h.created > 0 && h.created < createdCut {
                tooOld.insert(cid); rangeHit = true
            }
            if filter.useDateRange && (h.updated < rangeLo || h.updated > rangeHi) {
                outOfRange.insert(cid); rangeHit = true
            }

            var typeHit = false
            if filter.cleanDrafts && h.isDraft {
                drafts.insert(cid); typeHit = true
            }
            if filter.cleanWorktree && h.isWorktree {
                worktrees.insert(cid); typeHit = true
            }
            if filter.cleanSpec && h.isSpec {
                specs.insert(cid); typeHit = true
            }
            if filter.cleanProject && h.isProject {
                projects.insert(cid); typeHit = true
            }
            if filter.cleanBestOfN && h.isBestOfN {
                bestOfN.insert(cid); typeHit = true
            }

            // 两边都勾了：必须同时命中时间/状态 和 类型。
            // 只勾一边：命中那一边即可。两边都不勾：不删任何会话。
            let hit: Bool
            if rangeFilterOn && typeFilterOn {
                hit = rangeHit && typeHit
            } else if rangeFilterOn {
                hit = rangeHit
            } else if typeFilterOn {
                hit = typeHit
            } else {
                hit = false
            }
            if hit { selfPurge.insert(cid) }
        }

        var keep = Set(heads.keys).subtracting(selfPurge)
        if filter.followSubagents {
            for (cid, h) in heads {
                guard h.isSub || h.isBestOfN, let root = h.root, heads[root] != nil else { continue }
                if keep.contains(root) {
                    keep.insert(cid)
                } else {
                    keep.remove(cid)
                }
            }
        }
        return ClassifyResult(
            heads: heads, keep: keep, purge: Set(heads.keys).subtracting(keep),
            archived: archived, stale: stale, tooOld: tooOld, outOfRange: outOfRange,
            drafts: drafts, worktrees: worktrees, specs: specs, projects: projects,
            bestOfN: bestOfN
        )
    }

    func measure(dbPath: String, keep: Set<String>, purge: Set<String>) throws
        -> (Int, Int64, [PrefixStat], BlobPlan)
    {
        let box = SQLiteBox()
        try box.open(dbPath, readonly: true)
        defer { box.close() }
        let plan = try BlobPlanner(box: box).plan(keep: keep, purge: purge)
        var stats: [PrefixStat] = []
        var keepRows = 0
        var keepBytes: Int64 = 0

        func add(_ name: String, _ rows: Int, _ bytes: Int64) {
            stats.append(PrefixStat(name: name, rows: rows, bytes: bytes))
            keepRows += rows
            keepBytes += bytes
        }

        for prefix in composerScoped {
            var rows = 0
            var bytes: Int64 = 0
            for cid in keep {
                for (lo, hi) in idRanges("\(prefix):\(cid)") {
                    let pair = try rangeSum(box, lo: lo, hi: hi)
                    rows += pair.0
                    bytes += pair.1
                }
            }
            add(prefix, rows, bytes)
        }
        for prefix in keepWholesale {
            let pair = try rangeSum(box, lo: prefix, hi: prefix + "~")
            add(prefix + "*", pair.0, pair.1)
        }
        let item = try rangeSumTable(box, table: "ItemTable")
        add("ItemTable", item.0, item.1)

        let agent = try rangeSum(box, lo: "agentKv:", hi: "agentKv;")
        add("agentKv:*", agent.0 - plan.dropKeys.count, agent.1 - plan.dropBytes)
        return (keepRows, keepBytes, stats.sorted { $0.bytes > $1.bytes }, plan)
    }

    /// confirmed 是用户在预估时确认要删的会话；预估之后新出现的会话一律保留。
    func apply(
        dbPath: String,
        purge confirmed: Set<String>,
        progress: @escaping @Sendable (String) -> Void
    ) throws -> VerifyResult {
        let out = dbPath + ".slim"
        func removeSlim() {
            for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: out + s) }
        }
        removeSlim()

        progress("[1/5] 合并 WAL …")
        try checkpointWAL(dbPath)

        let src = SQLiteBox()
        try src.open(dbPath, readonly: true)
        let dst = SQLiteBox()
        var swapped = false
        defer {
            src.close()
            dst.close()
            if !swapped { removeSlim() }
        }
        let badSrc = try nonTextKeys(src)
        if badSrc > 0 {
            throw EngineError.message("原库有 \(badSrc) 个非文本键，先用命令行 repair --apply 修复，原库没有改动。")
        }
        let current = Set(try src.queryRows("SELECT composerId FROM composerHeaders").compactMap { $0[0].string })
        let purge = confirmed.intersection(current)
        let keep = current.subtracting(purge)
        progress("      计算检查点块引用 …")
        let plan = try BlobPlanner(box: src).plan(keep: keep, purge: purge)
        try dst.open(out, readonly: false)
        try dst.exec("PRAGMA journal_mode=OFF")
        try dst.exec("PRAGMA synchronous=OFF")

        progress("[2/5] 复制表结构与配置 …")
        let ddls = try src.queryRows(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'"
        )
        for row in ddls {
            if let sql = row[0].string { try dst.exec(sql) }
        }

        try copyItemTable(src: src, dst: dst, keep: keep)
        try copyHeaders(src: src, dst: dst, keep: keep)

        progress("[3/5] 复制保留会话正文 …")
        var total = 0
        for prefix in composerScoped {
            for cid in keep {
                for (lo, hi) in idRanges("\(prefix):\(cid)") {
                    total += try copyKV(src: src, dst: dst, lo: lo, hi: hi)
                }
            }
            progress("      \(prefix) 累计 \(total) 行")
        }
        for prefix in keepWholesale {
            total += try copyKV(src: src, dst: dst, lo: prefix, hi: prefix + "~")
        }
        total += try copyAgentKV(src: src, dst: dst) { key in
            plan.dropKeys.contains(key) || isPurgedCheckpoint(key, purge: purge)
        }
        progress("      agentKv 累计 \(total) 行")

        progress("[4/5] 校验新库 …")
        let lost = try missingKeys(dst, plan.keepKeys)
        if lost > 0 {
            throw EngineError.message("保留会话引用的 \(lost) 个检查点块没进新库，已中止，原库没有改动。")
        }
        var short = 0
        for cid in keep where try scopedCount(src, cid) != scopedCount(dst, cid) { short += 1 }
        if short > 0 {
            throw EngineError.message("\(short) 个保留会话的行数和原库对不上，已中止，原库没有改动。")
        }
        let items = "SELECT COUNT(*) FROM ItemTable"
        let heads = "SELECT COUNT(*) FROM composerHeaders"
        if try src.scalarInt(items) != dst.scalarInt(items) || dst.scalarInt(heads) != keep.count {
            throw EngineError.message("配置或会话头行数和原库对不上，已中止，原库没有改动。")
        }
        let verified = try verifyOpen(dst, filePath: out)
        if !verified.integrityOK {
            throw EngineError.message("新库完整性检查没通过，原库没有改动。")
        }
        if verified.nonTextKeys > 0 {
            throw EngineError.message("新库里还有 \(verified.nonTextKeys) 个非文本键，已中止，原库没有改动。")
        }
        try dst.exec("PRAGMA journal_mode=WAL")
        src.close()
        dst.close()

        progress("[5/5] 就位 …")
        try swapIn(dbPath: dbPath, newPath: out, backupSuffix: ".bak-\(BackupStore.stamp())")
        swapped = true
        var result = verified
        result.fileSize =
            (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? NSNumber)?.int64Value
            ?? verified.fileSize
        return result
    }

    func createSnapshot(dbPath: String, progress: @escaping @Sendable (String) -> Void) throws -> String {
        let dest = dbPath + ".bak-" + BackupStore.stamp()
        if FileManager.default.fileExists(atPath: dest) {
            throw EngineError.message("备份文件已存在：\(dest)")
        }
        progress("合并 WAL …")
        try checkpointWAL(dbPath)
        progress("复制库文件 …")
        try FileManager.default.copyItem(atPath: dbPath, toPath: dest)
        return dest
    }

    func verifyPath(_ dbPath: String) throws -> VerifyResult {
        let box = SQLiteBox()
        try box.open(dbPath, readonly: true)
        defer { box.close() }
        return try verifyOpen(box, filePath: dbPath)
    }

    private func verifyOpen(_ box: SQLiteBox, filePath: String) throws -> VerifyResult {
        let ok = (try box.scalarText("PRAGMA integrity_check")) == "ok"
        let heads = try box.scalarInt("SELECT COUNT(*) FROM composerHeaders")
        let kv = try box.scalarInt("SELECT COUNT(*) FROM cursorDiskKV")
        let bad = try nonTextKeys(box)
        let email = try box.scalarText("SELECT value FROM ItemTable WHERE key='cursorAuth/cachedEmail'")
        let token = try box.scalarText("SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'")
        let size = (try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? NSNumber)?.int64Value ?? 0
        return VerifyResult(
            integrityOK: ok, headerCount: heads, kvCount: kv, nonTextKeys: bad,
            fileSize: size, email: email, hasToken: !(token ?? "").isEmpty
        )
    }

    private func nonTextKeys(_ box: SQLiteBox) throws -> Int {
        try box.scalarInt("SELECT COUNT(*) FROM ItemTable WHERE typeof(key)!='text'")
            + box.scalarInt("SELECT COUNT(*) FROM composerHeaders WHERE typeof(composerId)!='text'")
            + box.scalarInt("SELECT COUNT(*) FROM cursorDiskKV WHERE typeof(key)!='text'")
    }

    private func scopedCount(_ box: SQLiteBox, _ cid: String) throws -> Int {
        try scopedRanges(cid).reduce(0) { $0 + (try rangeSum(box, lo: $1.0, hi: $1.1)).0 }
    }

    private func copyItemTable(src: SQLiteBox, dst: SQLiteBox, keep: Set<String>) throws {
        let ins = try dst.prepare("INSERT INTO ItemTable(key, value) VALUES (?,?)")
        defer { sqlite3_finalize(ins) }
        let stmt = try src.prepare("SELECT key, value FROM ItemTable")
        defer { sqlite3_finalize(stmt) }
        let rebuilt: Set<String> = ["composer.composerHeaders", "composer.composerHeaders.version"]
        var present = Set<String>()
        try dst.exec("BEGIN")
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row = SQLiteBox.readRow(stmt)
            guard let key = row[0].string else { continue }
            if rebuilt.contains(key) { present.insert(key); continue }
            sqlite3_reset(ins)
            dst.bind(ins, index: 1, .text(key))
            dst.bind(ins, index: 2, row.count > 1 ? row[1].asKVValue : .null)
            guard sqlite3_step(ins) == SQLITE_DONE else {
                try? dst.exec("ROLLBACK")
                throw EngineError.message("复制配置失败：\(dst.lastError)")
            }
        }
        try dst.exec("COMMIT")

        let header = try rebuildIndex(src: src, keep: keep)
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payload = String(data: data, encoding: .utf8) ?? "{\"allComposers\":[]}"
        let count = (header["allComposers"] as? [Any])?.count ?? 0
        let version = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(count)"
        let up = try dst.prepare("INSERT OR REPLACE INTO ItemTable(key, value) VALUES (?,?)")
        defer { sqlite3_finalize(up) }
        for (key, value) in [("composer.composerHeaders", payload), ("composer.composerHeaders.version", version)]
            where present.contains(key) {
            sqlite3_reset(up)
            dst.bind(up, index: 1, .text(key))
            dst.bind(up, index: 2, .text(value))
            guard sqlite3_step(up) == SQLITE_DONE else {
                throw EngineError.message("写会话索引失败：\(dst.lastError)")
            }
        }
    }

    /// 按源表的列原样复制，Cursor 加列也不会错位。
    private func copyHeaders(src: SQLiteBox, dst: SQLiteBox, keep: Set<String>) throws {
        let cols = try src.queryRows("PRAGMA table_info(composerHeaders)").compactMap { $0[1].string }
        guard let idCol = cols.firstIndex(of: "composerId") else {
            throw EngineError.message("composerHeaders 没有 composerId 列")
        }
        let list = cols.map { "\"\($0)\"" }.joined(separator: ",")
        let sel = try src.prepare("SELECT \(list) FROM composerHeaders")
        defer { sqlite3_finalize(sel) }
        let marks = Array(repeating: "?", count: cols.count).joined(separator: ",")
        let ins = try dst.prepare("INSERT INTO composerHeaders(\(list)) VALUES (\(marks))")
        defer { sqlite3_finalize(ins) }
        try dst.exec("BEGIN")
        while sqlite3_step(sel) == SQLITE_ROW {
            guard let c = sqlite3_column_text(sel, Int32(idCol)) else { continue }
            let cid = String(cString: c)
            guard keep.contains(cid) else { continue }
            sqlite3_reset(ins)
            for i in 0..<cols.count {
                if i == idCol {
                    sqlite3_bind_text(ins, Int32(i + 1), cid, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_value(ins, Int32(i + 1), sqlite3_column_value(sel, Int32(i)))
                }
            }
            guard sqlite3_step(ins) == SQLITE_DONE else {
                try? dst.exec("ROLLBACK")
                throw EngineError.message("复制会话头失败：\(dst.lastError)")
            }
        }
        try dst.exec("COMMIT")
    }

    /// agentKv 的值原样复制（二进制不转文本），跳过 skip 命中的键。
    private func copyAgentKV(src: SQLiteBox, dst: SQLiteBox, skip: (String) -> Bool) throws -> Int {
        let sel = try src.prepare(
            "SELECT key, value FROM cursorDiskKV WHERE key >= 'agentKv:' AND key < 'agentKv;'"
        )
        defer { sqlite3_finalize(sel) }
        let ins = try dst.prepare("INSERT INTO cursorDiskKV(key, value) VALUES (?,?)")
        defer { sqlite3_finalize(ins) }
        try dst.exec("BEGIN")
        var n = 0
        while sqlite3_step(sel) == SQLITE_ROW {
            guard let c = sqlite3_column_text(sel, 0) else { continue }
            let key = String(cString: c)
            if skip(key) { continue }
            sqlite3_reset(ins)
            sqlite3_bind_text(ins, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_value(ins, 2, sqlite3_column_value(sel, 1))
            guard sqlite3_step(ins) == SQLITE_DONE else {
                try? dst.exec("ROLLBACK")
                throw EngineError.message("复制 agentKv 失败：\(dst.lastError)")
            }
            n += 1
        }
        try dst.exec("COMMIT")
        return n
    }

    private func missingKeys(_ box: SQLiteBox, _ keys: Set<String>) throws -> Int {
        let stmt = try box.prepare("SELECT 1 FROM cursorDiskKV WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        var lost = 0
        for key in keys {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_ROW { lost += 1 }
        }
        return lost
    }

    private func checkpointWAL(_ dbPath: String) throws {
        let live = SQLiteBox()
        try live.open(dbPath, readonly: false)
        let rows = try live.queryRows("PRAGMA wal_checkpoint(TRUNCATE)")
        live.close()
        let busy = rows.first?[0].int ?? 1
        let wal = dbPath + "-wal"
        let left = (try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.int64Value ?? 0
        if busy != 0 || left > 0 {
            throw EngineError.message("WAL 没能合并进主库（Cursor 可能还开着），已中止，原库没有改动。")
        }
    }

    private func copyKV(src: SQLiteBox, dst: SQLiteBox, lo: String, hi: String) throws -> Int {
        let sel = try src.prepare("SELECT key, value FROM cursorDiskKV WHERE key >= ? AND key < ?")
        defer { sqlite3_finalize(sel) }
        sqlite3_bind_text(sel, 1, lo, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(sel, 2, hi, -1, SQLITE_TRANSIENT)
        let ins = try dst.prepare("INSERT INTO cursorDiskKV(key, value) VALUES (?,?)")
        defer { sqlite3_finalize(ins) }
        try dst.exec("BEGIN")
        var n = 0
        while sqlite3_step(sel) == SQLITE_ROW {
            let row = SQLiteBox.readRow(sel)
            guard let key = row[0].string else { continue }
            sqlite3_reset(ins)
            dst.bind(ins, index: 1, .text(key))
            dst.bind(ins, index: 2, row.count > 1 ? row[1].asKVValue : .null)
            guard sqlite3_step(ins) == SQLITE_DONE else {
                try? dst.exec("ROLLBACK")
                throw EngineError.message("复制会话正文失败：\(dst.lastError)")
            }
            n += 1
        }
        try dst.exec("COMMIT")
        return n
    }

    private func rebuildIndex(src: SQLiteBox, keep: Set<String>) throws -> [String: Any] {
        let rows = try src.queryRows(
            "SELECT composerId, isSubagent, value FROM composerHeaders"
        )
        var heads: [[String: Any]] = []
        var draft: [String: Any]?
        for row in rows {
            guard let cid = row[0].string, keep.contains(cid) else { continue }
            var info = parseJSON(row[2].string ?? "{}")
            if info.isEmpty { info = ["type": "head", "composerId": cid] }
            info["composerId"] = cid
            let isSub = row[1].int != 0 || bool(info["isSubagent"]) || bool(info["isBestOfNSubcomposer"])
            if isSub { continue }
            if cid == "empty-state-draft" || bool(info["isDraft"]) {
                draft = info
                continue
            }
            heads.append(info)
        }
        heads.sort { jsonInt($0["lastUpdatedAt"] ?? $0["createdAt"]) > jsonInt($1["lastUpdatedAt"] ?? $1["createdAt"]) }
        var all: [[String: Any]] = []
        if let draft { all.append(draft) }
        all.append(contentsOf: heads)
        return ["allComposers": all]
    }

    private func rangeSum(_ box: SQLiteBox, lo: String, hi: String) throws -> (Int, Int64) {
        let stmt = try box.prepare(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) FROM cursorDiskKV WHERE key >= ? AND key < ?"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, lo, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, hi, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1))
    }

    private func rangeSumTable(_ box: SQLiteBox, table: String) throws -> (Int, Int64) {
        let stmt = try box.prepare(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(value AS BLOB))),0) FROM \(table)"
        )
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1))
    }

    private func swapIn(dbPath: String, newPath: String, backupSuffix: String) throws {
        let fm = FileManager.default
        let backup = dbPath + backupSuffix
        for s in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: newPath + s)
        }
        try fm.moveItem(atPath: dbPath, toPath: backup)
        for s in ["-wal", "-shm"] {
            if fm.fileExists(atPath: dbPath + s) {
                try? fm.moveItem(atPath: dbPath + s, toPath: backup + s)
            }
        }
        do {
            try fm.moveItem(atPath: newPath, toPath: dbPath)
        } catch {
            try? fm.moveItem(atPath: backup, toPath: dbPath)
            for s in ["-wal", "-shm"] where fm.fileExists(atPath: backup + s) {
                try? fm.moveItem(atPath: backup + s, toPath: dbPath + s)
            }
            throw error
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func parseJSON(_ raw: String) -> [String: Any] {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

private func bool(_ v: Any?) -> Bool {
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.boolValue }
    return false
}

private func jsonInt(_ v: Any?) -> Int64 {
    if let n = v as? NSNumber { return n.int64Value }
    if let i = v as? Int { return Int64(i) }
    if let i = v as? Int64 { return i }
    return 0
}
