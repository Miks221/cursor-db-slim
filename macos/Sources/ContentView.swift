import SwiftUI

private let ink = Color(red: 0.14, green: 0.16, blue: 0.17)
private let mist = Color.primary.opacity(0.05)
private let line = Color.primary.opacity(0.08)

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(line).frame(height: 1)
            Picker("", selection: $state.tab) {
                ForEach(AppTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Rectangle().fill(line).frame(height: 1)
            Group {
                if state.tab == .clean {
                    cleanPage
                } else {
                    backupPage
                }
            }
            Rectangle().fill(line).frame(height: 1)
            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cleanPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterBlock
                if let report = state.report { estimate(report) }
                notices
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var backupPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.backups.isEmpty ? "还没有备份" : "\(state.backups.count) 份 · \(humanSize(state.backupTotal))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.canSnapshot {
                    Button("备份当前库") { state.snapshotNow() }
                        .controlSize(.small)
                        .disabled(state.busy || state.dbSize == 0)
                } else {
                    Text("剩余 \(humanSize(state.freeSpace))，再复制一份约需 \(humanSize(BackupStore.snapshotNeed(dbSize: state.dbSize)))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if state.backups.isEmpty {
                Text("清理时会自动把原库改成带时间戳的备份。空间够时也可以在这里再复制一份。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                notices.padding(.horizontal, 16)
                Spacer()
            } else {
                List {
                    ForEach(state.backups) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(item.fileName)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(humanSize(item.size))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                Text(item.modified, format: Date.FormatStyle(date: .numeric, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Button("删除") { state.confirmDelete(item) }
                                .controlSize(.mini)
                                .disabled(state.busy)
                        }
                        .padding(.vertical, 2)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
                notices.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let done = state.doneText {
            banner(done, tone: .ok)
        }
        if let err = state.errorText {
            banner(err, tone: .bad)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("数据库清理")
                    .font(.system(size: 15, weight: .semibold))
                Text(URL(fileURLWithPath: state.dbPath).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(state.dbSize > 0 ? humanSize(state.dbSize) : "—")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 6) {
                    Text(state.cursorRunning ? "Cursor 主程序在运行" : "Cursor 主程序已退出")
                        .foregroundStyle(state.cursorRunning ? Color.orange : Color.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("剩余 \(humanSize(state.freeSpace))")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var filterBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("时间 / 状态（满足任一）")
            VStack(alignment: .leading, spacing: 6) {
                Toggle("已归档的会话", isOn: $state.filter.cleanArchived)
                dayRow(
                    on: $state.filter.cleanInactive,
                    prefix: "超过",
                    days: $state.filter.inactiveDays,
                    suffix: "天未更新",
                    fallback: 7
                )
                dayRow(
                    on: $state.filter.cleanCreatedBefore,
                    prefix: "创建已超过",
                    days: $state.filter.createdBeforeDays,
                    suffix: "天",
                    fallback: 30
                )
            }

            Divider().opacity(0.5).padding(.vertical, 4)
            label("仅限类型（不勾 = 不限；勾了只清这类里、且符合上面条件的）")
            VStack(alignment: .leading, spacing: 6) {
                Toggle("空白草稿", isOn: $state.filter.cleanDrafts)
                Toggle("独立工作区（从主仓库分出去的副本）", isOn: $state.filter.cleanWorktree)
                Toggle("规格规划（写需求/方案稿的会话）", isOn: $state.filter.cleanSpec)
                Toggle("项目型会话", isOn: $state.filter.cleanProject)
                Toggle("多方案竞选的子会话（同时跑多个方案再择优）", isOn: $state.filter.cleanBestOfN)
            }

            Divider().opacity(0.5).padding(.vertical, 4)
            label("其它")
            VStack(alignment: .leading, spacing: 6) {
                Toggle("子代理跟随父会话：父删子删，父留子留", isOn: $state.filter.followSubagents)
                Toggle("丢掉代理缓存（界面聊天还在，磁盘记录也还在）", isOn: $state.filter.dropAgentBlobs)
                Toggle("只保留某段日期内有更新的会话", isOn: $state.filter.useDateRange)
                if state.filter.useDateRange {
                    HStack(spacing: 8) {
                        DatePicker("从", selection: $state.filter.rangeStart, displayedComponents: .date)
                            .labelsHidden()
                        Text("至")
                            .foregroundStyle(.secondary)
                        DatePicker("到", selection: $state.filter.rangeEnd, displayedComponents: .date)
                            .labelsHidden()
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12.5))
        .tint(ink)
    }

    private func estimate(_ r: DryRunReport) -> some View {
        let c = r.classify
        return VStack(alignment: .leading, spacing: 8) {
            label("预估")
            HStack(spacing: 0) {
                mini("清理", "\(c.purge.count)", warn: true)
                mini("保留", "\(c.keep.count)")
                mini("新库", humanSize(r.projected))
                mini("可释放", humanSize(max(0, r.currentSize - r.projected)))
            }
            .background(mist, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            FlowNote {
                if c.archived.count > 0 { Text("归档 \(c.archived.count)") }
                if c.stale.count > 0 { Text("不活跃 \(c.stale.count)") }
                if c.tooOld.count > 0 { Text("创建过早 \(c.tooOld.count)") }
                if c.outOfRange.count > 0 { Text("日期外 \(c.outOfRange.count)") }
                if c.drafts.count > 0 { Text("草稿 \(c.drafts.count)") }
                if r.droppedBlobRows > 0 { Text("缓存 \(r.droppedBlobRows) 行") }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("选择库…") { state.pickDB() }
                .disabled(state.busy)
            if !state.progress.isEmpty {
                ProgressView().controlSize(.mini)
                Text(state.progress)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.tab == .clean {
                Button("预估") { state.dryRun() }
                    .disabled(state.busy || state.dbSize == 0)
                    .keyboardShortcut("r", modifiers: [.command])
                Button("清理") { state.confirmAndApply() }
                    .buttonStyle(.borderedProminent)
                    .tint(ink)
                    .disabled(state.busy || state.report == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func dayRow(on: Binding<Bool>, prefix: String, days: Binding<Int>, suffix: String, fallback: Int) -> some View {
        HStack(spacing: 6) {
            Toggle(prefix, isOn: on)
            TextField("", value: days, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 36, height: 20)
                .background(mist, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .disabled(!on.wrappedValue)
                .onChange(of: days.wrappedValue) { v in
                    if v < 1 { days.wrappedValue = fallback }
                    if v > 3650 { days.wrappedValue = 3650 }
                }
            Text(suffix)
                .foregroundStyle(on.wrappedValue ? .primary : .secondary)
        }
    }

    private func mini(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func label(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }

    private func banner(_ text: String, tone: BannerTone) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tone == .ok ? Color.primary : Color.red)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (tone == .ok ? Color.green : Color.red).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

private enum BannerTone { case ok, bad }

private struct FlowNote<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 10) { content() }
    }
}
