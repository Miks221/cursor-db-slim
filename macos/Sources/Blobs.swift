import Foundation
import SQLite3

// agentKv:blob 是会话检查点的内容寻址存储。一部分块是加密的，看不到它们还引用了谁，
// 所以只删「被清理会话走得到、保留会话走不到」的块，谁都走不到的原样保留。

let checkpointPrefixes = ["agentKv:checkpoint:", "agentKv:bubbleCheckpoint:"]
let blobPrefix = "agentKv:blob:"
let blobSeedPrefixes = ["bubbleId", "composerData", "checkpointId"]

/// base 本身和 base: 开头的键；不会命中以 base 为前缀的其他 id。
func idRanges(_ base: String) -> [(String, String)] {
    [(base, base + "\u{01}"), (base + ":", base + ";")]
}

func scopedRanges(_ cid: String, prefixes: [String] = composerScoped) -> [(String, String)] {
    prefixes.flatMap { idRanges("\($0):\(cid)") }
        + checkpointPrefixes.flatMap { idRanges("\($0)\(cid)") }
}

func isPurgedCheckpoint(_ key: String, purge: Set<String>) -> Bool {
    for p in checkpointPrefixes where key.hasPrefix(p) {
        let rest = key.dropFirst(p.count)
        let cid = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return purge.contains(cid)
    }
    return false
}

struct BlobPlan {
    var total = 0
    var keepKeys = Set<String>()
    var dropKeys = Set<String>()
    var dropBytes: Int64 = 0
}

func columnData(_ stmt: OpaquePointer?, _ i: Int32) -> Data {
    guard let ptr = sqlite3_column_blob(stmt, i) else { return Data() }
    let n = Int(sqlite3_column_bytes(stmt, i))
    return n > 0 ? Data(bytes: ptr, count: n) : Data()
}

private func isHex(_ c: UInt8) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}

private func isB64(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
        || c == 0x2B || c == 0x2F || c == 0x2D || c == 0x5F
}

private func hexValue(_ c: UInt8) -> UInt8 {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    default: return c - 0x61 + 10
    }
}

private func hexDecode(_ bytes: ArraySlice<UInt8>) -> Data {
    var out = Data(capacity: bytes.count / 2)
    var it = bytes.makeIterator()
    while let hi = it.next(), let lo = it.next() {
        out.append(hexValue(hi) << 4 | hexValue(lo))
    }
    return out
}

func base64Bytes(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t, options: .ignoreUnknownCharacters)
}

/// 所有可能是块哈希的 32 字节串；调用方再按已知块过滤，误报只会少删。
func hashCandidates(_ data: Data) -> [Data] {
    let b = [UInt8](data)
    let n = b.count
    var out: [Data] = []
    if n >= 34 {
        // protobuf 长度 32 的 length-delimited 字段：tag 末字节 wire type 2，后接 0x20
        for i in 1..<(n - 32) where b[i] == 0x20 && b[i - 1] < 0x80 && b[i - 1] & 7 == 2 {
            out.append(Data(b[(i + 1)...(i + 32)]))
        }
    }
    var i = 0
    while i < n {
        guard isHex(b[i]) else { i += 1; continue }
        var j = i
        while j < n && isHex(b[j]) { j += 1 }
        var k = i
        while j - k >= 64 {
            out.append(hexDecode(b[k..<(k + 64)]))
            k += 64
        }
        i = j
    }
    if n >= 44 {
        for e in 43..<n where b[e] == 0x3D {
            let slice = b[(e - 43)..<e]
            guard slice.allSatisfy(isB64) else { continue }
            if let s = String(bytes: slice, encoding: .ascii), let d = base64Bytes(s + "="),
               d.count == 32 {
                out.append(d)
            }
        }
    }
    return out
}

private func encodedString(_ s: String, into out: inout [Data]) {
    if s.hasPrefix("~") && s.count > 8 {
        if let d = base64Bytes(String(s.dropFirst())) { out.append(d) }
    } else if s.count >= 64 && s.count % 2 == 0 && s.utf8.allSatisfy(isHex) {
        out.append(hexDecode(ArraySlice(Array(s.utf8))))
    }
}

/// JSON 里 "~base64" 或长十六进制的字段（conversationState 等）解码后收进 out。
func encodedStates(_ obj: Any, into out: inout [Data]) {
    if let s = obj as? String {
        encodedString(s, into: &out)
    } else if let d = obj as? [String: Any] {
        for v in d.values { encodedStates(v, into: &out) }
    } else if let a = obj as? [Any] {
        for v in a { encodedStates(v, into: &out) }
    }
}

/// Foundation 解析不了的 JSON（如孤立代理项转义）直接扫原始字节里的引号串；
/// 这两类编码串里没有反斜杠，不用处理转义。
func encodedStatesRaw(_ data: Data, into out: inout [Data]) {
    let b = [UInt8](data)
    var i = 0
    while i < b.count {
        guard b[i] == 0x22 else { i += 1; continue }
        var j = i + 1
        while j < b.count && b[j] != 0x22 && b[j] != 0x5C { j += 1 }
        if j < b.count && b[j] == 0x22, j - i - 1 >= 9,
           let s = String(bytes: b[(i + 1)..<j], encoding: .utf8) {
            encodedString(s, into: &out)
        }
        i += 1
    }
}

final class BlobPlanner {
    private let box: SQLiteBox
    private(set) var known: [Data: String] = [:]
    private var cache: [Data: [Data]] = [:]

    init(box: SQLiteBox) throws {
        self.box = box
        let stmt = try box.prepare(
            "SELECT key FROM cursorDiskKV WHERE key >= 'agentKv:blob:' AND key < 'agentKv:blob;'"
        )
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: c)
            let hex = Array(key.utf8.dropFirst(blobPrefix.utf8.count))
            guard hex.count == 64, hex.allSatisfy(isHex) else { continue }
            known[hexDecode(ArraySlice(hex))] = key
        }
    }

    func seeds(_ cid: String) throws -> Set<Data> {
        let stmt = try box.prepare("SELECT value FROM cursorDiskKV WHERE key >= ? AND key < ?")
        defer { sqlite3_finalize(stmt) }
        var refs = Set<Data>()
        for (lo, hi) in scopedRanges(cid, prefixes: blobSeedPrefixes) {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, lo, -1, SQLITE_TRANSIENT_BLOBS)
            sqlite3_bind_text(stmt, 2, hi, -1, SQLITE_TRANSIENT_BLOBS)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let raw = columnData(stmt, 0)
                var chunks = [raw]
                if let obj = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) {
                    encodedStates(obj, into: &chunks)
                } else {
                    encodedStatesRaw(raw, into: &chunks)
                }
                for chunk in chunks {
                    for h in hashCandidates(chunk) where known[h] != nil { refs.insert(h) }
                }
            }
        }
        return refs
    }

    func closure(_ roots: Set<Data>) throws -> Set<Data> {
        let stmt = try box.prepare("SELECT value FROM cursorDiskKV WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        var seen = Set<Data>()
        var stack = roots.filter { known[$0] != nil }.map { $0 }
        while let h = stack.popLast() {
            if seen.contains(h) { continue }
            seen.insert(h)
            var kids = cache[h]
            if kids == nil {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, known[h]!, -1, SQLITE_TRANSIENT_BLOBS)
                let data = sqlite3_step(stmt) == SQLITE_ROW ? columnData(stmt, 0) : Data()
                kids = hashCandidates(data).filter { $0 != h && known[$0] != nil }
                cache[h] = kids
            }
            stack.append(contentsOf: kids!.filter { !seen.contains($0) })
        }
        return seen
    }

    func plan(keep: Set<String>, purge: Set<String>) throws -> BlobPlan {
        var keepRoots = Set<Data>()
        for cid in keep { keepRoots.formUnion(try seeds(cid)) }
        var purgeRoots = Set<Data>()
        for cid in purge { purgeRoots.formUnion(try seeds(cid)) }
        let keepSet = try closure(keepRoots)
        let drop = try closure(purgeRoots).subtracting(keepSet)
        var result = BlobPlan(total: known.count)
        result.keepKeys = Set(keepSet.compactMap { known[$0] })
        result.dropKeys = Set(drop.compactMap { known[$0] })
        let stmt = try box.prepare(
            "SELECT COALESCE(length(CAST(value AS BLOB)),0) FROM cursorDiskKV WHERE key = ?"
        )
        defer { sqlite3_finalize(stmt) }
        for key in result.dropKeys {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_BLOBS)
            if sqlite3_step(stmt) == SQLITE_ROW { result.dropBytes += sqlite3_column_int64(stmt, 0) }
        }
        return result
    }
}

private let SQLITE_TRANSIENT_BLOBS = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
