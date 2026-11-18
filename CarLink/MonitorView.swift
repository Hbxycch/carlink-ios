import SwiftUI
import UIKit
import AVFoundation

// MARK: - 车机监控（三路画面 + 双画面源）
//
// 画面来源（设置里可选，也可在页面右上角「设置」里改）：
//   auto     : 优先 easyNVR 的 HLS，起播失败 / 6 秒无画面 → 该路单独降级到车机快照流
//   hls      : 只走 easyNVR HLS（连续视频，需要手机能访问 NVR）
//   snapshot : 只走车机 /api/camera/frame 的 1fps JPEG（只要连上车机就能看）
//
// HLS 地址不写死在代码里：从车机 /api/stream/status 拿到三路 RTMP 地址提取流名，
// 再套「easyNVR 服务地址 + 地址模板」拼出来，模板支持 {base} / {host} / {key}。

struct MonitorView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var settings: SettingsStore

    @State private var layout = 4                 // 1 / 2 / 4
    @State private var patrol = false
    @State private var current = "front"
    @State private var streams: [String: StreamInfo] = [:]
    @State private var hlsFailed: Set<String> = []
    @State private var frames: [String: UIImage] = [:]
    @State private var showSettings = false
    @State private var fullCam: String?
    @State private var toast: String?

    private let cams = ["front", "rear", "free"]
    private let patrolTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private let statusTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            if conn.health == .offline { offlineBar }
            segmentRow
            grid
            tools
            alertBar
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("车机监控")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            MonitorSettingsSheet()
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullCam != nil },
            set: { if !$0 { fullCam = nil } }
        )) {
            if let cam = fullCam {
                MonitorFullscreen(cam: cam,
                                  title: camTitle(cam),
                                  hlsURL: hlsURL(cam),
                                  source: settings.monitorSource,
                                  onClose: { fullCam = nil })
            }
        }
        .task { await loadStreams() }
        .onReceive(statusTimer) { _ in
            Task { await loadStreams() }
            if settings.monitorSource == .auto, !hlsFailed.isEmpty {
                // 每 30s 给失败过的通道一次重新尝试 HLS 的机会（5s 刷新 → 每 6 次）
                retryTick += 1
                if retryTick % 6 == 0 { hlsFailed.removeAll() }
            }
        }
        .onReceive(patrolTimer) { _ in
            guard patrol, layout == 1 else { return }
            if let i = cams.firstIndex(of: current) {
                current = cams[(i + 1) % cams.count]
            }
        }
        .onChange(of: layout) { v in
            if v != 1 { patrol = false }
        }
        .overlay(alignment: .bottom) {
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
    }

    @State private var retryTick = 0

    // MARK: 断链提示（复用 ConnectionStore 的实时链路状态）

    private var offlineBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.system(size: 12, weight: .bold))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(offlineText).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
            Spacer(minLength: 0)
            Button("重连") { Task { await conn.probeNow() } }
                .font(.system(size: 11.5, weight: .bold))
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.92)))
                .foregroundStyle(CL.red)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(CL.red))
    }

    private var offlineText: String {
        var s = "车机连接已断开"
        if let since = conn.offlineSince {
            s += " · 已断开 \(max(0, Int(Date().timeIntervalSince(since)))) 秒"
        }
        if conn.reconnectAttempt > 0 { s += " · 第 \(conn.reconnectAttempt + 1) 次重连" }
        return s
    }

    // MARK: 档位 + 轮巡

    private var segmentRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach([1, 2, 4], id: \.self) { n in
                    Button {
                        layout = n
                    } label: {
                        Text("\(n)")
                            .font(.system(size: 13, weight: layout == n ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(layout == n ? Color(uiColor: .systemBackground) : .clear)
                                    .shadow(color: layout == n ? .black.opacity(0.1) : .clear, radius: 2, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(uiColor: .tertiarySystemFill)))

            Button {
                guard layout == 1 else {
                    toast = "轮巡只在单路视图生效"
                    autoHideToast()
                    return
                }
                patrol.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(patrol ? CL.green : Color(uiColor: .tertiaryLabel))
                        .frame(width: 6, height: 6)
                    Text("轮巡").font(.system(size: 12))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(uiColor: .systemBackground)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 宫格

    private var visibleCams: [String] {
        switch layout {
        case 1: return [current]
        case 2: return ["front", "rear"]
        default: return cams
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: layout == 1 ? 1 : 2)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(visibleCams, id: \.self) { cam in
                MonitorCell(
                    cam: cam,
                    title: camTitle(cam),
                    selected: layout != 4 && cam == current,
                    source: settings.monitorSource,
                    hlsURL: hlsURL(cam),
                    fps: Double(max(1, settings.monitorSnapshotFps)),
                    online: conn.isOnline,
                    hlsFailed: hlsFailed.contains(cam),
                    streamState: streams[cam]?.state,
                    onFail: { hlsFailed.insert(cam) },
                    onTap: { current = cam },
                    onDoubleTap: { current = cam; fullCam = cam },
                    onFrame: { img in
                        if let img = img { frames[cam] = img } else { frames.removeValue(forKey: cam) }
                    }
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
            if layout == 4 {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                    .overlay(Text("CH04 预留").font(.system(size: 10)).foregroundStyle(.secondary))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
    }

    // MARK: 工具条

    private var tools: some View {
        HStack(spacing: 6) {
            toolButton("全屏", icon: "arrow.up.left.and.arrow.down.right") {
                guard conn.isOnline else { toast = "车机未连接"; autoHideToast(); return }
                fullCam = current
            }
            toolButton("抓拍", icon: "camera") { capture() }
            toolButton("来源 · \(settings.monitorSource.shortTitle)", icon: "rectangle.on.rectangle") {
                cycleSource()
            }
            toolButton("设置", icon: "slider.horizontal.3") { showSettings = true }
        }
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .regular))
                Text(title).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(uiColor: .systemBackground)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func cycleSource() {
        let all = MonitorSource.allCases
        if let i = all.firstIndex(of: settings.monitorSource) {
            settings.monitorSource = all[(i + 1) % all.count]
        }
        hlsFailed.removeAll()
        toast = "画面来源：\(settings.monitorSource.title)"
        autoHideToast()
    }

    private func capture() {
        guard let img = frames[current] else {
            toast = settings.monitorSource == .hls
                ? "HLS 画面暂不支持抓拍，切换到快照流可抓"
                : "当前通道还没有可用画面"
            autoHideToast()
            return
        }
        toast = "已保存到相册"
        autoHideToast()
        Task {
            do {
                guard let data = img.jpegData(compressionQuality: 0.9) else {
                    toast = "保存失败：无法生成图片"
                    autoHideToast()
                    return
                }
                let dir = FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent("monitor-\(current)-\(Int(Date().timeIntervalSince1970)).jpg")
                try data.write(to: url)
                _ = try await PhotoSaver.saveToAlbum(fileAt: url)
            } catch {
                toast = "保存失败：\(error.localizedDescription)"
                autoHideToast()
            }
        }
    }

    private func autoHideToast() {
        let text = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == text { toast = nil }
        }
    }

    // MARK: 告警条

    private var alertBar: some View {
        Group {
            if let msg = alertMessage {
                HStack(alignment: .top, spacing: 7) {
                    Text("!")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(RoundedRectangle(cornerRadius: 5).fill(CL.orange))
                    Text(msg)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(uiColor: .label))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(CL.orange.opacity(0.12)))
            }
        }
    }

    private var alertMessage: String? {
        if !conn.isOnline { return "画面已暂停：车机连接断开，保留最后一帧" }
        if settings.monitorSource != .snapshot && hlsURL("front") == nil {
            return "未配置 easyNVR 地址，正在使用车机快照流（设置 › 车机监控）"
        }
        for cam in cams {
            if let s = streams[cam], s.on == true, let err = s.lastError, !err.isEmpty {
                return "\(camTitle(cam)) 推流异常：\(err)"
            }
            if let s = streams[cam], s.on == true, (s.state ?? "") == "no-ffmpeg" {
                return "\(camTitle(cam)) 推流未就绪：车机缺少 ffmpeg 组件"
            }
        }
        return nil
    }

    // MARK: 数据

    private func loadStreams() async {
        guard let api = conn.client else { return }
        if let st = try? await api.streamStatus() {
            var map: [String: StreamInfo] = [:]
            for s in st.streams { map[s.camera] = s }
            streams = map
        }
    }

    private func camTitle(_ cam: String) -> String {
        switch cam {
        case "front": return "前摄"
        case "rear": return "后摄"
        case "free": return "自由视角"
        default: return cam
        }
    }

    /// 从 RTMP 推流地址提取流名（.../live/KEY）
    private func streamKey(_ rtmp: String) -> String {
        let t = rtmp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t) else { return "" }
        let parts = u.path.split(separator: "/").map(String.init)
        return parts.last ?? ""
    }

    /// 拼 HLS 地址；没配 easyNVR 服务地址时返回 nil（自动模式会用快照流）
    private func hlsURL(_ cam: String) -> URL? {
        guard let s = streams[cam], let rtmp = s.url, !rtmp.isEmpty else { return nil }
        let key = streamKey(rtmp)
        guard !key.isEmpty else { return nil }
        let base = settings.monitorNvrBase.trimmingCharacters(in: .whitespacesAndNewlines)
        var tpl = settings.monitorHlsTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if tpl.isEmpty { tpl = "{base}/hls/{key}/{key}_live.m3u8" }
        if tpl.contains("{base}") && base.isEmpty { return nil }
        let host = URL(string: rtmp)?.host ?? ""
        let str = tpl
            .replacingOccurrences(of: "{base}", with: base)
            .replacingOccurrences(of: "{host}", with: host)
            .replacingOccurrences(of: "{key}", with: key)
        return URL(string: str)
    }
}

// MARK: - 单个通道格子

struct MonitorCell: View {
    let cam: String
    let title: String
    let selected: Bool
    let source: MonitorSource
    let hlsURL: URL?
    let fps: Double
    let online: Bool
    let hlsFailed: Bool
    let streamState: String?
    let onFail: () -> Void
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onFrame: (UIImage?) -> Void

    @State private var hlsError: String?

    /// 实际使用的来源
    private var useHLS: Bool {
        guard online else { return false }
        switch source {
        case .snapshot: return false
        case .hls: return true
        case .auto: return !hlsFailed && hlsURL != nil
        }
    }

    private var liveTag: String {
        if !online { return "离线" }
        return useHLS ? "HLS" : "快照"
    }

    var body: some View {
        ZStack {
            Color.black

            if !online {
                frozenPlaceholder
            } else if useHLS, let url = hlsURL {
                HLSPlayer(onState: { st in
                    switch st {
                    case .failed(let msg), .stalled(let msg):
                        if source == .auto { onFail() } else { hlsError = msg }
                    case .playing:
                        hlsError = nil
                    case .loading:
                        break
                    }
                }, url: url)
                .onAppear { onFrame(nil) }
                if let e = hlsError {
                    errorOverlay(e, retry: false)
                }
            } else if source == .hls {
                errorOverlay(hlsURL == nil ? "未配置 easyNVR 地址\n设置 › 车机监控" : "HLS 连接失败", retry: true)
            } else {
                SnapshotFrame(cam: cam, fps: fps, onImage: onFrame)
            }

            overlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? CL.blue : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
    }

    private var frozenPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.55))
            Text("信号中断").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        }
    }

    private func errorOverlay(_ text: String, retry: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: retry ? "exclamationmark.triangle" : "hourglass")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            Text(text)
                .font(.system(size: 9.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
            if source == .auto || retry {
                Text("将自动改用快照流").font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.55))
    }

    private var overlay: some View {
        VStack {
            HStack(alignment: .top, spacing: 4) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(online ? CL.green : CL.red)
                        .frame(width: 5, height: 5)
                    Text("CH\(channelNo) \(title)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                if (streamState ?? "") == "pushing" {
                    HStack(spacing: 2) {
                        Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 4, height: 4)
                        Text("REC").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.tsFormatter.string(from: ctx.date))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
                Text(liveTag)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }
        }
        .padding(5)
    }

    private var channelNo: Int {
        switch cam {
        case "front": return 1
        case "rear": return 2
        case "free": return 3
        default: return 0
        }
    }

    static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 快照流画面（1fps JPEG 轮询）

struct SnapshotFrame: View {
    @EnvironmentObject var conn: ConnectionStore
    let cam: String
    let fps: Double
    let onImage: (UIImage?) -> Void

    @State private var image: UIImage?
    @State private var errorText: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let e = errorText {
                    VStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(e)
                            .font(.system(size: 9))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 8)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .task(id: cam) { await loop() }
    }

    private func loop() async {
        while !Task.isCancelled {
            if let api = conn.client {
                do {
                    let data = try await api.fetchCameraFrame(cam: cam)
                    if let img = UIImage(data: data) {
                        image = img
                        errorText = nil
                        onImage(img)
                    }
                } catch {
                    if image == nil {
                        errorText = (error as? APIError)?.message ?? "画面获取失败"
                    }
                }
            } else {
                errorText = "未连接车机"
            }
            let interval = max(0.6, 1.0 / max(0.5, fps))
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

// MARK: - HLS 播放（AVPlayerLayer，无控件、静音）

enum HLSPlayState {
    case loading
    case playing
    case failed(String)
    case stalled(String)
}

struct HLSPlayer: UIViewRepresentable {
    let onState: (HLSPlayState) -> Void
    let url: URL

    init(onState: @escaping (HLSPlayState) -> Void, url: URL) {
        self.onState = onState
        self.url = url
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.onState = onState
        v.load(url)
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.onState = onState
        uiView.load(url)
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) {
        uiView.teardown()
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var avLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var player: AVPlayer?
    private var currentURL: URL?
    private var obs: [NSKeyValueObservation] = []
    private var watchdog: DispatchWorkItem?
    var onState: ((HLSPlayState) -> Void)?

    func load(_ url: URL) {
        guard currentURL != url else { return }
        teardown()
        currentURL = url
        backgroundColor = .black
        avLayer.videoGravity = .resizeAspectFill

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = true
        p.actionAtItemEnd = .none
        avLayer.player = p
        player = p

        onState?(.loading)

        obs.append(item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            let msg = it.error?.localizedDescription ?? "HLS 加载失败"
            DispatchQueue.main.async { self?.onState?(.failed(msg)) }
        })
        obs.append(p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
            guard pl.timeControlStatus == .playing else { return }
            DispatchQueue.main.async { self?.onState?(.playing) }
        })

        p.play()

        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if (self.player?.timeControlStatus ?? .paused) != .playing {
                self.onState?(.stalled("HLS 无画面（6 秒超时）"))
            }
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    func teardown() {
        watchdog?.cancel()
        watchdog = nil
        obs.forEach { $0.invalidate() }
        obs.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        avLayer.player = nil
        currentURL = nil
    }

    deinit {
        teardown()
    }
}

// MARK: - 全屏单路

struct MonitorFullscreen: View {
    let cam: String
    let title: String
    let hlsURL: URL?
    let source: MonitorSource
    let onClose: () -> Void

    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var settings: SettingsStore
    @State private var failed = false

    private var useHLS: Bool {
        switch source {
        case .snapshot: return false
        case .hls: return true
        case .auto: return !failed && hlsURL != nil
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if conn.isOnline {
                if useHLS, let url = hlsURL {
                    HLSPlayer(onState: { st in
                        switch st {
                        case .failed, .stalled:
                            if source == .auto { failed = true }
                        default:
                            break
                        }
                    }, url: url)
                } else {
                    SnapshotFrame(cam: cam, fps: Double(max(1, settings.monitorSnapshotFps)), onImage: { _ in })
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash").font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
                    Text("车机连接已断开，画面已暂停").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
            }

            VStack {
                HStack {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    Spacer()
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(useHLS ? "HLS" : "快照")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                Spacer()
            }
        }
    }
}

// MARK: - 监看设置（页面内 sheet：只暴露最常用的三项）

struct MonitorSettingsSheet: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("画面来源", selection: $settings.monitorSource) {
                        ForEach(MonitorSource.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("画面来源")
                } footer: {
                    Text("\(settings.monitorSource.detail)。\n自动模式：优先 easyNVR HLS，某一路起播失败或 6 秒无画面时，该路单独改用快照流，之后每 30 秒重试一次 HLS。")
                }

                Section {
                    TextField("easyNVR 服务地址", text: $settings.monitorNvrBase)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("HLS 地址模板", text: $settings.monitorHlsTemplate)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("easyNVR")
                } footer: {
                    Text("服务地址示例：http://192.168.10.100:10800。模板中 {base} = 服务地址，{key} = 推流流名，{host} = 车机推流的主机。留空则不会走 HLS。")
                }

                Section {
                    Picker("刷新频率", selection: $settings.monitorSnapshotFps) {
                        Text("1 帧/秒").tag(1)
                        Text("2 帧/秒").tag(2)
                    }
                } header: {
                    Text("车机快照流")
                } footer: {
                    Text("车机端每秒解一帧（640×360 JPEG），不占用摄像头与编码器；需要车机端 v1.1.28 及以上。")
                }
            }
            .navigationTitle("监看设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
