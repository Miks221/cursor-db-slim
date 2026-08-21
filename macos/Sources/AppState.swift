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
                    self.errorText = friendlyError(error)
                    self.progress = ""
                    self.busy = false
                }
            }
        }
    }

    func confirmAndApply() {
        guard let report else {
            errorText = "请先点「预估」，确认要清理多少后再清理。"
            return
        }
        refreshMeta()
        let purge = report.classify.purge.count
        let keep = report.classify.keep.count
        let sizeLine = "将清理 \(purge) 条会话，保留 \(keep) 条。\n体积约从 \(humanSize(report.currentSize)) 降到 \(humanSize(report.projected))。"
        if canSnapshot {
            alert(
                title: "确认清理",
                message: sizeLine + "\n原库会改名为带时间戳的备份，可在「备份」页删除。清理完成后若提示打不开库，一般可以忽略，先打开 Cursor 看会话和登录是否还在。",
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
        await Self.quitCursorMain()
        refreshMeta()
        if Self.isCursorRunning() {
            busy = false
            progress = ""
            errorText = "Cursor 还没完全退出。请用菜单里的退出或 Cmd+Q（不要只关窗口）后再试。"
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
                let account = result.email ?? "未检测到"
                doneText = "清理完成。新库 \(humanSize(result.fileSize))，保留 \(result.headerCount) 条会话。登录账号：\(account)。原库已出现在「备份」页，先打开 Cursor 确认正常，再删备份。"
                backups = BackupStore.items(beside: path)
            } else {
                errorText = "新库已经换上，但复查没完全通过（完整性\(result.integrityOK ? "通过" : "未通过")，非文本键 \(result.nonTextKeys) 个）。先打开 Cursor 看会话和登录是否还在，先别删备份。"
            }
        } catch {
            errorText = friendlyError(error)
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
                self?.errorText = friendlyError(error)
            }
        }
    }

    func snapshotNow() {
        guard canSnapshot else {
            errorText = "磁盘不够再复制一份。剩余 \(humanSize(freeSpace))，完整备份大约需要 \(humanSize(BackupStore.snapshotNeed(dbSize: dbSize)))。清理时仍会把原库改名留下。"
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
        await Self.quitCursorMain()
        refreshMeta()
        if Self.isCursorRunning() {
            busy = false
            progress = ""
            errorText = "Cursor 还没完全退出。请用菜单里的退出或 Cmd+Q（不要只关窗口）后再备份。"
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
            doneText = "备份完成：\(URL(fileURLWithPath: dest).lastPathComponent)（\(humanSize(dbSize))）。可在「备份」页查看或删除。"
            tab = .backups
        } catch {
            errorText = friendlyError(error)
        }
        progress = ""
        busy = false
    }

    static func quitCursorMain() async {
        for app in cursorMainApps() {
            app.terminate()
        }
        NSAppleScript(source: "tell application \"Cursor\" to quit")?.executeAndReturnError(nil)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !isCursorRunning() { break }
        }
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

    static func cursorMainApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let url = app.bundleURL else { return false }
            return url.lastPathComponent == "Cursor.app"
                && app.activationPolicy == .regular
        }
    }

    static func isCursorRunning() -> Bool {
        !cursorMainApps().isEmpty
    }
}
