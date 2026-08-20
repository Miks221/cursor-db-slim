import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var dbPath = defaultDBURL().path
    @Published var dbSize: Int64 = 0
    @Published var freeSpace: Int64 = 0
    @Published var cursorRunning = false
    @Published var filter = CleanFilter()
    @Published var report: DryRunReport?
    @Published var verify: VerifyResult?
    @Published var busy = false
    @Published var progress = ""
    @Published var errorText: String?
    @Published var doneText: String?
    @Published var tab: AppTab = .clean
    @Published var backups: [BackupItem] = []

    let engine = Engine()
    private var timer: Timer?

    init() {
        refreshMeta()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMeta() }
        }
    }

    func refreshMeta() {
        if FileManager.default.fileExists(atPath: dbPath) {
            dbSize = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            dbSize = 0
        }
        if let vals = try? URL(fileURLWithPath: dbPath).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = vals.volumeAvailableCapacityForImportantUsage {
            freeSpace = cap
        } else {
            freeSpace = 0
        }
        cursorRunning = Self.isCursorRunning()
        backups = BackupStore.items(beside: dbPath)
    }

    var backupTotal: Int64 { backups.reduce(0) { $0 + $1.size } }

    var canSnapshot: Bool {
        dbSize > 0 && freeSpace >= BackupStore.snapshotNeed(dbSize: dbSize)
    }

    func pickDB() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.allowedContentTypes = [UTType(filenameExtension: "vscdb") ?? .data]
        p.directoryURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url {
            dbPath = url.path
            report = nil
            verify = nil
            refreshMeta()
        }
    }

    func dryRun() {
        guard !busy else { return }
        busy = true
        errorText = nil
        doneText = nil
        progress = "正在预估…"
        let path = dbPath
        let filter = filter
        let current = dbSize
        let free = freeSpace
        Task {
            do {
                let cls = try await engine.classify(dbPath: path, filter: filter)
                let (rows, bytes, stats, dropped) = try await engine.measure(
                    dbPath: path, keep: cls.keep, dropBlobs: filter.dropAgentBlobs
                )
                let projected = Int64(Double(bytes) * 1.15)
                await MainActor.run {
                    self.report = DryRunReport(
                        classify: cls, stats: stats, keepRows: rows, keepBytes: bytes,
                        projected: projected, droppedBlobRows: dropped,
                        currentSize: current, freeSpace: free
                    )
                    self.progress = ""
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.progress = ""
                    self.busy = false
                }
            }
        }
    }

    func confirmAndApply() {
        guard let report else {
            errorText = "请先做一次预估。"
            return
        }
        refreshMeta()
        let purge = report.classify.purge.count
        let keep = report.classify.keep.count
        let sizeLine = "将清理 \(purge) 条会话，保留 \(keep) 条。\n体积约从 \(humanSize(report.currentSize)) 降到 \(humanSize(report.projected))。"
        if canSnapshot {
            alert(
                title: "确认清理",
                message: sizeLine + "\n原库会改名为带时间戳的备份，可在「备份」页删除。",
                primary: "开始清理",
                style: .warning
            ) { [weak self] in
                self?.maybeQuitThenApply()
            }
            return
        }
        let need = BackupStore.snapshotNeed(dbSize: dbSize)
        alert(
            title: "磁盘不足，无法再复制一份备份",
            message: sizeLine
                + "\n\n当前剩余 \(humanSize(freeSpace))，再完整复制一份大约需要 \(humanSize(need))。"
                + "\n继续的话，只会把原库改名留下（不另占空间）。没有第二份拷贝，删掉改名文件就无法回滚。"
                + "\n确定仍要清理？",
            primary: "空间不足，仍要清理",
            style: .critical
        ) { [weak self] in
            self?.maybeQuitThenApply()
        }
    }

    private func maybeQuitThenApply() {
        if Self.isCursorRunning() {
            alert(
                title: "Cursor 正在运行",
                message: "改库前必须退出 Cursor。确定现在退出并继续清理？未保存的编辑可能丢失。",
                primary: "退出 Cursor 并清理",
                style: .critical
            ) { [weak self] in
                Task { await self?.quitCursorThenApply() }
            }
        } else {
            Task { await apply() }
        }
    }

    private func quitCursorThenApply() async {
        busy = true
        progress = "正在退出 Cursor…"
        let script = NSAppleScript(source: "tell application \"Cursor\" to quit")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Self.isCursorRunning() { break }
        }
        refreshMeta()
        if Self.isCursorRunning() {
            busy = false
            progress = ""
            errorText = "Cursor 仍在运行，请手动 Cmd+Q 后再试。"
            return
        }
        await apply()
    }

    private func apply() async {
        guard let report else { return }
        busy = true
        errorText = nil
        doneText = nil
        progress = "开始清理…"
        let path = dbPath
        let keep = report.classify.keep
        let drop = filter.dropAgentBlobs
        do {
            let result = try await engine.apply(dbPath: path, keep: keep, dropBlobs: drop) { line in
                Task { @MainActor in
                    self.progress = line
                }
            }
            refreshMeta()
            verify = result
            if result.integrityOK && result.nonTextKeys == 0 {
                doneText = "完成。新库 \(humanSize(result.fileSize))，会话 \(result.headerCount) 条，KV \(result.kvCount) 行，integrity_check=ok。登录：\(result.email ?? "无")。原库已列入「备份」页，确认正常后再删。"
                backups = BackupStore.items(beside: path)
            } else {
                errorText = "清理后校验未完全通过：integrity=\(result.integrityOK)，非 TEXT 键 \(result.nonTextKeys)。"
            }
        } catch {
            errorText = error.localizedDescription
        }
        progress = ""
        busy = false
    }

    func confirmDelete(_ item: BackupItem) {
        alert(
            title: "删除备份",
            message: "删除 \(item.fileName)（\(humanSize(item.size))）？此操作不能撤销。",
            primary: "删除",
            style: .critical
        ) { [weak self] in
            do {
                try BackupStore.delete(item)
                self?.refreshMeta()
            } catch {
                self?.errorText = error.localizedDescription
            }
        }
    }

    func snapshotNow() {
        guard canSnapshot else {
            errorText = "剩余 \(humanSize(freeSpace))，再复制一份当前库大约需要 \(humanSize(BackupStore.snapshotNeed(dbSize: dbSize)))。"
            return
        }
        if Self.isCursorRunning() {
            alert(
                title: "Cursor 正在运行",
                message: "完整备份前必须退出 Cursor。确定现在退出并备份？",
                primary: "退出并备份",
                style: .critical
            ) { [weak self] in
                Task { await self?.quitThenSnapshot() }
            }
            return
        }
        Task { await runSnapshot() }
    }

    private func quitThenSnapshot() async {
        busy = true
        progress = "正在退出 Cursor…"
        let script = NSAppleScript(source: "tell application \"Cursor\" to quit")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Self.isCursorRunning() { break }
        }
        refreshMeta()
        if Self.isCursorRunning() {
            busy = false
            progress = ""
            errorText = "Cursor 仍在运行，请手动 Cmd+Q 后再备份。"
            return
        }
        await runSnapshot()
    }

    private func runSnapshot() async {
        busy = true
        errorText = nil
        doneText = nil
        progress = "正在备份…"
        let path = dbPath
        do {
            let dest = try await engine.createSnapshot(dbPath: path) { line in
                Task { @MainActor in self.progress = line }
            }
            refreshMeta()
            doneText = "已备份到 \(URL(fileURLWithPath: dest).lastPathComponent)（\(humanSize(dbSize))）。"
            tab = .backups
        } catch {
            errorText = error.localizedDescription
        }
        progress = ""
        busy = false
    }

    private func alert(title: String, message: String, primary: String, style: NSAlert.Style, onOK: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        a.addButton(withTitle: primary)
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            onOK()
        }
    }

    static func isCursorRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-lf", "Cursor.app"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").contains { line in
            let s = String(line)
            return s.contains("Cursor.app")
                && !s.contains("CursorDBCleaner")
                && !s.contains("Cursor 数据库清理")
        }
    }
}
