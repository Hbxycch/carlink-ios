import SwiftUI

// MARK: - 摄像头推流管理（三路独立开关 + RTMP 地址 + 实时状态）
//
// 数据来自车机端 /api/stream/status；开关和地址修改走 /api/config
// （stream_front_on / stream_front_url 这类键），车机收到后立即生效。

struct CameraStreamView: View {
    @EnvironmentObject var conn: ConnectionStore
    @State private var status: StreamStatusResponse?
    @State private var loadError: String?
    @State private var busy = false

    var body: some View {
        List {
            if let st = status {
                ForEach(st.streams) { s in
                    Section {
                        CameraStreamRow(
                            info: s,
                            onToggle: { on in await setStream(s.camera, on: on) },
                            onSaveURL: { url in await setStreamURL(s.camera, url: url) }
                        )
                    }
                }
                Section {
                    if let ff = st.ffmpeg {
                        ffmpegRow(ff)
                    }
                } header: {
                    Text("推流组件")
                } footer: {
                    Text("零转码尾随 DVR 录像推流（TS→FLV），不占用摄像头与编码器，不影响本机录像；车机熄火停录后推流自动暂停，恢复录像后自动续推。首次开启时车机自动从 OTA 服务器下载推流组件（约 22MB）。需要车机端 v1.1.26 及以上。")
                }
            } else if let err = loadError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("加载中…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("摄像头推流")
        .task { await reload() }
        .refreshable { await reload() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { await reload() }
        }
    }

    // MARK: 推流组件（ffmpeg）部署状态

    @ViewBuilder
    private func ffmpegRow(_ ff: StreamFfmpeg) -> some View {
        if ff.installed == true {
            Label("已就绪", systemImage: "checkmark.circle.fill")
                .foregroundStyle(CL.green)
        } else {
            switch ff.state ?? "" {
            case "downloading":
                HStack(spacing: 10) {
                    Label("下载中 \(ff.progress ?? 0)%", systemImage: "arrow.down.circle")
                        .foregroundStyle(CL.orange)
                    Spacer()
                    ProgressView(value: Double(ff.progress ?? 0), total: 100)
                        .frame(maxWidth: 120)
                }
            case "error":
                VStack(alignment: .leading, spacing: 4) {
                    Label("部署失败", systemImage: "xmark.circle.fill")
                        .foregroundStyle(CL.red)
                    if let e = ff.error {
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text("开启推流时自动重试（间隔 10 分钟）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            default:
                Label("未部署，开启推流后自动下载", systemImage: "arrow.down.circle.dotted")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 数据操作

    private func reload() async {
        guard !busy, let api = conn.client else { return }
        do {
            let r = try await api.streamStatus()
            status = r
            loadError = nil
        } catch {
            if status == nil { loadError = ConnLogStore.describe(error) }
        }
    }

    private func setStream(_ cam: String, on: Bool) async {
        guard let api = conn.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.updateConfig(["stream_\(cam)_on": on])
            // 车机端起 / 停推流线程要几秒，稍等再刷新
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let r = try? await api.streamStatus() { status = r }
        } catch {
            ConnLogStore.shared.log("ERR", "推流开关失败: \(ConnLogStore.describe(error))")
            if let r = try? await api.streamStatus() { status = r }
        }
    }

    private func setStreamURL(_ cam: String, url: String) async {
        guard let api = conn.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.updateConfig(["stream_\(cam)_url": url])
            if let r = try? await api.streamStatus() { status = r }
        } catch {
            ConnLogStore.shared.log("ERR", "保存推流地址失败: \(ConnLogStore.describe(error))")
        }
    }
}

// MARK: - 单路摄像头设置块

private struct CameraStreamRow: View {
    let info: StreamInfo
    let onToggle: (Bool) async -> Void
    let onSaveURL: (String) async -> Void

    @State private var urlText: String = ""
    @State private var urlDirty = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(info.title, isOn: Binding(
                    get: { info.on ?? false },
                    set: { on in Task { await onToggle(on) } }
                ))
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(info.stateColor)
                    .frame(width: 8, height: 8)
                Text(info.stateTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let segs = info.segments, (info.on ?? false) {
                    Text("已推 \(segs) 段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if saved {
                    Label("已保存", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(CL.green)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 8) {
                TextField("rtmp://…（推流地址）", text: $urlText)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: urlText) { _ in
                        urlDirty = urlText != (info.url ?? "")
                        saved = false
                    }
                    .onSubmit { Task { await save() } }
                if urlDirty {
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let err = info.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(CL.red)
                    .lineLimit(4)
            }
        }
        .onAppear { urlText = info.url ?? "" }
    }

    private func save() async {
        await onSaveURL(urlText.trimmingCharacters(in: .whitespaces))
        urlDirty = false
        withAnimation { saved = true }
    }
}
