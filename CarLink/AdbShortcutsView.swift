import SwiftUI
import UIKit

// MARK: - ADB 快捷指令（模型 + 本地持久化）
//
// 指令通过车机端 POST /api/device/shell 在本地 root adbd 回环执行，
// 与截屏、应用控制共用同一套通道。车机端 v1.1.32+ 才提供该接口。
// 重启类指令走 /api/device/reboot（先回执再执行），避免 shell 读超时被误判失败。

struct AdbShortcut: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case shell
        case reboot
    }

    var id: String = UUID().uuidString
    var name: String = ""
    var command: String = ""
    var note: String = ""
    var dangerous: Bool = false
    var kind: Kind = .shell
    var builtin: Bool = false
}

struct AdbRunResult: Identifiable {
    let id = UUID()
    let name: String
    let command: String
    let output: String
    let ms: Int?
    let ok: Bool
}

@MainActor
final class AdbShortcutStore: ObservableObject {
    @Published private(set) var items: [AdbShortcut] = []
    private static let key = "adbShortcuts.v1"

    /// 预置常用指令：首次使用或「恢复预置」时写入
    static let presets: [AdbShortcut] = [
        AdbShortcut(id: "preset-model", name: "设备型号与系统",
                    command: "getprop ro.product.model; getprop ro.build.version.release",
                    note: "机型 + Android 版本", builtin: true),
        AdbShortcut(id: "preset-ip", name: "车机 IP 地址",
                    command: "ip addr show wlan0 | grep 'inet '",
                    note: "无线网卡地址；无输出时可改用 ifconfig wlan0", builtin: true),
        AdbShortcut(id: "preset-wifi", name: "WiFi 网络列表",
                    command: "dumpsys wifi | grep -i 'ssid' | head -20",
                    note: "已保存 / 扫描到的 SSID", builtin: true),
        AdbShortcut(id: "preset-disk", name: "存储占用",
                    command: "df -h /sdcard /data", builtin: true),
        AdbShortcut(id: "preset-mem", name: "内存概况",
                    command: "cat /proc/meminfo | head -6", builtin: true),
        AdbShortcut(id: "preset-temp", name: "CPU 温度",
                    command: "cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -5",
                    note: "部分机型没有温控节点", builtin: true),
        AdbShortcut(id: "preset-apps", name: "已安装应用",
                    command: "pm list packages -3", builtin: true),
        AdbShortcut(id: "preset-screen", name: "抓取车机屏幕",
                    command: "screencap -p /sdcard/Pictures/CarCap/adb-screen.png",
                    note: "落盘到 CarCap 目录，可在车机文件里查看", builtin: true),
        AdbShortcut(id: "preset-launch", name: "拉起 CarLink 服务",
                    command: "monkey -p com.zood.carlink -c android.intent.category.LAUNCHER 1",
                    note: "服务被杀后重新拉起", builtin: true),
        AdbShortcut(id: "preset-reboot", name: "重启车机", command: "reboot",
                    note: "走专用重启通道，先回执再执行", dangerous: true,
                    kind: .reboot, builtin: true)
    ]

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([AdbShortcut].self, from: data) {
            items = list
        } else {
            items = Self.presets
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func upsert(_ s: AdbShortcut) {
        if let i = items.firstIndex(where: { $0.id == s.id }) { items[i] = s }
        else { items.append(s) }
        persist()
    }

    func delete(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func reset() {
        items = Self.presets
        persist()
    }
}

// MARK: - 设置 › ADB 工具 › 快捷指令

struct AdbShortcutsView: View {
    @EnvironmentObject var conn: ConnectionStore
    @StateObject private var store = AdbShortcutStore()

    @State private var status: [String: Any]?
    @State private var statusError: String?
    @State private var loadingStatus = false

    @State private var editing: AdbShortcut?
    @State private var showEditor = false
    @State private var pending: AdbShortcut?
    @State private var runningId: String?
    @State private var result: AdbRunResult?
    @State private var showResetConfirm = false
    @State private var toast: String?

    private var supported: Bool { conn.carInfo?.adbShell == true }

    var body: some View {
        List {
            statusSection
            shortcutsSection
            tipsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("ADB 快捷指令")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    EditButton()
                    Button { editing = nil; showEditor = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增指令")
                }
            }
        }
        .task { await refreshStatus() }
        .refreshable { await refreshStatus() }
        .sheet(isPresented: $showEditor) {
            AdbShortcutEditor(item: editing) { saved in
                store.upsert(saved)
                flash("已保存「\(saved.name)」")
            }
        }
        .sheet(item: $result) { AdbResultSheet(result: $0) }
        .alert("执行高危指令？", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            Button("取消", role: .cancel) { pending = nil }
            Button("确认执行", role: .destructive) {
                let s = pending
                pending = nil
                if let s = s { run(s) }
            }
        } message: {
            Text("将执行：\(pending?.command ?? "")\n\n高危指令会改变车机状态，确认继续？")
        }
        .alert("恢复预置指令？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                store.reset()
                flash("已恢复预置指令")
            }
        } message: {
            Text("当前自定义的指令会被覆盖，无法撤销。")
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: 连接状态

    private var statusSection: some View {
        Section {
            HStack {
                Label("adbd 回环", systemImage: "cable.connector")
                Spacer()
                if loadingStatus {
                    ProgressView()
                } else if let s = status {
                    let on = s["adb"] as? Bool == true
                    let port = (s["port"] as? NSNumber)?.intValue ?? 0
                    Text(on ? "在线 · 端口 \(port > 0 ? String(port) : "9876")" : "离线")
                        .font(.caption)
                        .foregroundStyle(on ? .green : .orange)
                } else {
                    Text(statusError ?? "未检测")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let e = status?["error"] as? String, !e.isEmpty {
                Text(e).font(.caption2).foregroundStyle(.tertiary)
            }
            Button("刷新状态") { Task { await refreshStatus() } }
                .font(.subheadline)
        } header: {
            Text("连接状态")
        } footer: {
            Text("指令通过车机本地 root adbd 回环执行（端口 9876 / 5555），需要车机保持无线 ADB 调试开启；车机端 v1.1.32 及以上才可用。")
        }
    }

    // MARK: 指令列表

    private var shortcutsSection: some View {
        Section {
            ForEach(store.items) { s in
                Button {
                    if s.dangerous { pending = s } else { run(s) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.kind == .reboot ? "power" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14))
                            .foregroundStyle(s.dangerous ? .orange : CL.blue)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(s.name).font(.subheadline.weight(.medium))
                                if s.dangerous {
                                    Text("高危")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                                }
                                if s.builtin {
                                    Text("预置").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Text(s.command)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !s.note.isEmpty {
                                Text(s.note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if runningId == s.id {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle").foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!conn.isConnected || !supported || runningId != nil)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { store.delete(id: s.id) } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button { editing = s; showEditor = true } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                }
            }
            .onMove { store.move(from: $0, to: $1) }

            if store.items.isEmpty {
                Text("还没有指令，点右上角 + 新增，或恢复预置。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Text("快捷指令 \(store.items.count) 条")
        } footer: {
            Text(supported
                 ? "点一条立即执行并查看回显；标记「高危」的会先二次确认。左滑可编辑 / 删除，右上角「编辑」可拖动排序。"
                 : "需要车机端 v1.1.32 及以上版本，请先升级车机端。")
        }
    }

    private var tipsSection: some View {
        Section {
            Button { showResetConfirm = true } label: {
                Label("恢复预置指令", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("预置覆盖机型、网络、存储、内存、温度、已装应用、抓屏、拉起服务与重启；命令文本可自由增删改。命令在 root 权限下执行，请谨慎填写。")
        }
    }

    // MARK: 执行

    private func refreshStatus() async {
        guard let api = conn.client else {
            statusError = "未连接车机"
            return
        }
        loadingStatus = true
        defer { loadingStatus = false }
        do {
            status = try await api.adbStatus()
            statusError = nil
        } catch {
            statusError = (error as? APIError)?.message ?? "状态获取失败"
        }
    }

    private func run(_ s: AdbShortcut) {
        guard let api = conn.client else { flash("未连接车机"); return }
        guard supported else { flash("请先升级车机端到 v1.1.32"); return }
        runningId = s.id
        Task {
            defer { runningId = nil }
            let t0 = Date()
            do {
                if s.kind == .reboot {
                    try await api.rebootCar()
                    result = AdbRunResult(
                        name: s.name,
                        command: "reboot（专用重启通道）",
                        output: "重启指令已下发，车机约 30 秒后重新上线。\n期间连接会断开，属正常现象。",
                        ms: Int(Date().timeIntervalSince(t0) * 1000),
                        ok: true)
                } else {
                    let r = try await api.runAdbShell(command: s.command)
                    let out = (r["output"] as? String) ?? ""
                    result = AdbRunResult(
                        name: s.name,
                        command: s.command,
                        output: out.isEmpty ? "（命令已执行，无输出）" : out,
                        ms: (r["ms"] as? NSNumber)?.intValue,
                        ok: (r["ok"] as? Bool) ?? true)
                }
            } catch {
                result = AdbRunResult(
                    name: s.name,
                    command: s.command,
                    output: "执行失败：\((error as? APIError)?.message ?? error.localizedDescription)",
                    ms: nil,
                    ok: false)
            }
        }
    }

    // MARK: 提示

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.bottom, 18)
                .transition(.opacity)
        }
    }

    private func flash(_ text: String) {
        toast = text
        let v = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == v { toast = nil }
        }
    }
}

// MARK: - 新增 / 编辑指令

struct AdbShortcutEditor: View {
    let item: AdbShortcut?
    let onSave: (AdbShortcut) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var note = ""
    @State private var dangerous = false

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，如「查看车机 IP」", text: $name)
                    TextField("说明（可选）", text: $note)
                } header: {
                    Text("基本信息")
                }

                Section {
                    TextEditor(text: $command)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 90)
                    Toggle("高危指令（执行前二次确认）", isOn: $dangerous)
                } header: {
                    Text("ADB shell 命令")
                } footer: {
                    Text("在车机 root adbd 上执行，支持管道，多条命令用 ; 分隔。禁止换行 / 控制字符，以及关闭或卸载 CarLink 自身。命令上限 1024 字符，输出最多回传 4000 字符。")
                }

                if item?.kind == AdbShortcut.Kind.reboot {
                    Section {
                        Label("这是预置重启指令，会走专用重启通道（先回执再执行），不会等待 shell 超时。",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(item == nil ? "新增指令" : "编辑指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid)
                }
            }
            .onAppear {
                guard let s = item else { return }
                name = s.name
                command = s.command
                note = s.note
                dangerous = s.dangerous
            }
        }
    }

    private func save() {
        var s = item ?? AdbShortcut()
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        s.note = note.trimmingCharacters(in: .whitespaces)
        s.dangerous = dangerous
        onSave(s)
        dismiss()
    }
}

// MARK: - 执行结果

struct AdbResultSheet: View {
    let result: AdbRunResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.ok ? .green : .orange)
                        Text(result.ok ? "执行完成" : "执行结果")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let ms = result.ms {
                            Text("\(ms) ms").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("命令").font(.caption).foregroundStyle(.secondary)
                        Text(result.command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color(uiColor: .tertiarySystemFill)))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("输出").font(.caption).foregroundStyle(.secondary)
                        Text(result.output.isEmpty ? "（无输出）" : result.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    }
                }
                .padding()
            }
            .navigationTitle(result.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("复制输出") { UIPasteboard.general.string = result.output }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
