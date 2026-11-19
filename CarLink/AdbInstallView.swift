import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置 › ADB 工具 › 安装应用
//
// 两种来源：
//  1) 链接安装：可让车机自己下载（POST /api/device/app/install/url），
//     或由手机下载后上传（POST /api/device/app/install，二进制 body）——
//     后者不要求车机外网可达，带签名 / 时效的下载地址更稳妥。
//  2) 本机文件：fileImporter 选 .apk，复制到临时目录后上传。
// 安装完成后用已有的 /api/device/app/control（action=start）直接打开应用。
// 车机端 v1.1.33+ 才提供安装接口，低版本车机入口自动禁用。

private struct PickedApk {
    let url: URL
    let name: String
    let size: Int64
}

/// 进度用引用类型持有，避免在 escaping 回调里捕获 View 值类型
final class ApkInstallProgress: ObservableObject {
    @Published var value: Double = 0
    @Published var text: String = ""
}

struct AdbInstallView: View {
    @EnvironmentObject var conn: ConnectionStore

    enum Mode: String, CaseIterable, Identifiable {
        case link = "链接安装"
        case file = "本机文件"
        var id: String { rawValue }
    }

    enum Phase {
        case idle
        case working
        case done(ApkInstallResult)
        case failed(String)
    }

    @StateObject private var prog = ApkInstallProgress()
    @State private var mode: Mode = .link
    @State private var link = ""
    @State private var byPhone = true
    @State private var picked: PickedApk?
    @State private var showPicker = false
    @State private var phase: Phase = .idle
    @State private var launching = false
    @State private var toast: String?

    private var supported: Bool { conn.carInfo?.appInstall == true }
    private var busy: Bool {
        switch phase {
        case .working: return true
        default: return false
        }
    }
    private var doneResult: ApkInstallResult? {
        if case .done(let r) = phase { return r }
        return nil
    }
    private var failureText: String? {
        if case .failed(let m) = phase { return m }
        return nil
    }
    private var canInstall: Bool {
        guard conn.isConnected, supported, !busy else { return false }
        switch mode {
        case .link: return !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return picked != nil
        }
    }

    var body: some View {
        List {
            statusSection
            sourceSection
            if busy { progressSection }
            if let r = doneResult { resultSection(r) }
            if let msg = failureText { failureSection(msg) }
            tipsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("安装应用")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [UTType(filenameExtension: "apk") ?? .item],
                      allowsMultipleSelection: false) { result in
            handlePicked(result)
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeInOut(duration: 0.18), value: toast)
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            HStack {
                Label("车机端版本", systemImage: "car.fill")
                Spacer()
                Text(conn.carInfo?.version ?? "?").foregroundStyle(.secondary)
            }
            HStack {
                Label("ADB 安装能力", systemImage: "square.and.arrow.down")
                Spacer()
                Text(supported ? "可用" : "需 v1.1.33+")
                    .font(.caption)
                    .foregroundStyle(supported ? .green : .orange)
            }
            if !conn.isConnected {
                Text("未连接车机，请先在「车机」页连接")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("状态")
        } footer: {
            Text("安装走车机本地 root adbd 回环（端口 9876 / 5555），需要车机保持无线 ADB 调试开启。安装完成后可直接打开应用。")
        }
    }

    // MARK: 来源

    private var sourceSection: some View {
        Section {
            Picker("来源", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .link {
                TextField("https://…/xxx.apk", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("由手机下载后上传（推荐）", isOn: $byPhone)
                Button { install() } label: {
                    HStack {
                        Label("下载并安装", systemImage: "link.badge.plus")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(!canInstall)
            } else {
                Button { showPicker = true } label: {
                    HStack {
                        Label(picked == nil ? "选择 APK 文件" : "重新选择", systemImage: "folder")
                        Spacer()
                    }
                }
                if let p = picked {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.subheadline.weight(.medium))
                        Text(Fmt.bytes(p.size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { install() } label: {
                    HStack {
                        Label("上传并安装", systemImage: "square.and.arrow.up")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(!canInstall || picked == nil)
            }
        } header: {
            Text("安装来源")
        } footer: {
            Text(mode == .link
                 ? (byPhone
                    ? "链接由手机下载后传给车机，不要求车机能访问外网；带签名 / 时效的下载地址更稳妥。"
                    : "车机直接从该地址下载安装，省手机流量；要求车机自身能访问该地址。失败时请改用「由手机下载后上传」。")
                 : "从「文件」App 或 iCloud 选择 .apk，上传到车机后由本地 root adbd 执行 pm install -r。")
        }
    }

    private var progressSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(prog.text.isEmpty ? "处理中…" : prog.text).font(.subheadline)
            }
            if prog.value > 0, prog.value < 1 {
                ProgressView(value: prog.value)
                Text("\(Int(prog.value * 100))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: { Text("进度") }
    }

    // MARK: 结果

    private func resultSection(_ r: ApkInstallResult) -> some View {
        Section {
            infoRow("应用包名", r.package.isEmpty ? "未解析到包名" : r.package)
            infoRow("版本", r.versionName.isEmpty ? "—" : "\(r.versionName) (\(r.versionCode))")
            infoRow("文件大小", Fmt.bytes(r.size))
            infoRow("耗时", "\(r.ms) ms")
            if !r.output.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("pm install 输出").font(.caption).foregroundStyle(.secondary)
                    Text(r.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            Button { launch(r.package) } label: {
                HStack {
                    Label("打开应用", systemImage: "play.circle.fill")
                    Spacer()
                    if launching { ProgressView() }
                }
            }
            .disabled(r.package.isEmpty || launching || !conn.isConnected)
            Button("再装一个") { reset() }
        } header: {
            Text("安装结果")
        } footer: {
            Text(r.message.isEmpty ? (r.ok ? "安装成功" : "安装失败") : r.message)
        }
    }

    private func failureSection(_ msg: String) -> some View {
        Section {
            Text(msg).font(.subheadline).foregroundStyle(.red)
            Button("重试") { install() }.disabled(!canInstall)
        } header: { Text("安装失败") }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var tipsSection: some View {
        Section {
            Text("• 覆盖安装同包名应用会保留数据；签名不一致会失败，需先卸载旧版。")
            Text("• 不允许通过本功能覆盖安装 CarLink 自身（会中断服务），车机端请走 OTA 升级。")
            Text("• APK 上限 200 MB。安装期间车机可能短暂卡顿，属正常现象。")
        } header: { Text("说明") }
    }

    private var toastView: some View {
        Group {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 动作

    private func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let src = urls.first else { return }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            guard src.lastPathComponent.lowercased().hasSuffix(".apk") else {
                phase = .failed("所选文件不是 .apk，请重新选择")
                return
            }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("carlink-apk-\(UUID().uuidString).apk")
            do {
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
                let attr = try FileManager.default.attributesOfItem(atPath: dst.path)
                let size = (attr[.size] as? NSNumber)?.int64Value ?? 0
                picked = PickedApk(url: dst, name: src.lastPathComponent, size: size)
                phase = .idle
            } catch {
                phase = .failed("读取文件失败：\(error.localizedDescription)")
            }
        case .failure(let e):
            phase = .failed("选择文件失败：\(e.localizedDescription)")
        }
    }

    private func install() {
        guard let api = conn.client else { phase = .failed("未连接车机"); return }
        guard supported else { phase = .failed("车机端不支持，请先升级到 v1.1.33"); return }
        guard !busy else { return }
        let useLink = mode == .link
        let linkText = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneDownload = byPhone
        let local = picked

        Task { @MainActor in
            prog.value = 0
            prog.text = "准备中…"
            phase = .working
            do {
                let r: ApkInstallResult
                if useLink {
                    guard !linkText.isEmpty else { throw APIError("请输入 APK 下载地址") }
                    if phoneDownload {
                        prog.text = "正在下载 APK…"
                        let f = try await api.downloadApkToTemp(linkText)
                        prog.text = "正在上传到车机…"
                        let holder = prog
                        r = try await api.installApk(fileAt: f) { [weak holder] p in
                            Task { @MainActor in holder?.value = p }
                        }
                        try? FileManager.default.removeItem(at: f)
                    } else {
                        prog.text = "车机正在下载并安装…"
                        r = try await api.installApkFromURL(linkText)
                    }
                } else {
                    guard let f = local else { throw APIError("请先选择 APK 文件") }
                    prog.text = "正在上传到车机…"
                    let holder = prog
                    r = try await api.installApk(fileAt: f.url) { [weak holder] p in
                        Task { @MainActor in holder?.value = p }
                    }
                }
                prog.value = 1
                phase = .done(r)
            } catch {
                phase = .failed(Self.errText(error))
            }
        }
    }

    private func launch(_ pkg: String) {
        guard let api = conn.client, !pkg.isEmpty else { return }
        launching = true
        Task { @MainActor in
            defer { launching = false }
            do {
                let r = try await api.controlApp(packageName: pkg, action: "start")
                let ok = r["ok"] as? Bool == true
                toast = ok ? "已打开 \(pkg)" : (r["message"] as? String ?? "启动失败")
            } catch {
                toast = "启动失败：\(Self.errText(error))"
            }
            clearToastLater()
        }
    }

    private func clearToastLater() {
        let current = toast
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == current { toast = nil }
        }
    }

    private func reset() {
        phase = .idle
        prog.value = 0
        prog.text = ""
        picked = nil
        link = ""
        toast = nil
    }

    private static func errText(_ e: Error) -> String {
        (e as? APIError)?.message ?? e.localizedDescription
    }
}
