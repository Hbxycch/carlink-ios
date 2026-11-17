import SwiftUI
import MobileVLCKit

// MARK: - 视频播放页（设计图 3.4：VLC 边下边播 + 全套控件）

struct PlayerView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    let file: CarFile
    /// 同分类全部条目（三路互切 / 相邻时段 / 自动连播）
    let siblings: [CarFile]

    @StateObject private var model = PlayerModel()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var currentFile: CarFile
    @State private var showInfo = false
    @State private var confirmDeleteLocal = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var fullscreen = false

    /// 0.5× ~ 10×（设计图倍速 chips：慢放查细节 / 快进找事件）
    private let rates: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 7.0, 10.0]

    init(file: CarFile, siblings: [CarFile]) {
        self.file = file
        self.siblings = siblings
        _currentFile = State(initialValue: file)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(mediaPlayer: model.mediaPlayer)
                .ignoresSafeArea()

            // 手势层（位于视频之上、控件之下）：单击切换控件，双击左右 ±10s。
            // 用独立的透明层承接手势，不依赖 UIKit 视图的触摸传递。
            HStack(spacing: 0) {
                tapZone { model.jump(-10) }
                tapZone { model.jump(10) }
            }
            .ignoresSafeArea()

            if model.buffering {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("缓冲中…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
            }

            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    if !fullscreen { badgesRow }
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar
                }
                .padding(fullscreen ? 14 : 16)
                .transition(.opacity)
            }
        }
        .statusBarHidden(fullscreen)
        .onAppear {
            if UserDefaults.standard.object(forKey: rateKey) != nil {
                model.rate = UserDefaults.standard.float(forKey: rateKey)
            }
            guard let api = conn.client else { return }
            model.play(url: playbackURL(for: file, api: api))
            scheduleHide()
        }
        .onDisappear {
            model.stop()
            if fullscreen { setFullscreen(false) }
        }
        .onChange(of: model.endedToken) { _ in handleEnded() }
        .alert("文件信息", isPresented: $showInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(infoText)
        }
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .confirmationDialog("删除本地副本？车机上的原片不受影响。",
                            isPresented: $confirmDeleteLocal, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let rec = localRecord { library.remove(rec) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶部：返回 + 摄像头 + 标题 + 下载/已在本地 + 更多菜单

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }

            CameraBadge(camera: currentFile.cameraEnum)

            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.dateTime(currentFile.date))
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if localRecord != nil {
                    LocalTag(compact: true)
                } else {
                    Text("\(Fmt.bytes(currentFile.size))\(durationText)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 4)

            if localRecord == nil {
                Button {
                    downloads.addOne(currentFile, target: .dashcam(categoryOf(currentFile)))
                    scheduleHide()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }

            Button {
                setFullscreen(!fullscreen)
                scheduleHide()
            } label: {
                Image(systemName: fullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }

            Menu {
                Button {
                    showInfo = true
                } label: {
                    Label("文件信息", systemImage: "info.circle")
                }
                if let rec = localRecord {
                    Button {
                        prepareShare(rec)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        confirmDeleteLocal = true
                    } label: {
                        Label("删除本地副本", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
    }

    // 状态徽标：● REC · TS 边下边播 · 🔒 锁定段
    private var badgesRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text("REC")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
            Text("TS 边下边播")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            if currentFile.locked == true {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("锁定段")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // 中部：±10s + 播放/暂停
    private var centerControls: some View {
        HStack(spacing: 44) {
            Button {
                model.jump(-10)
                scheduleHide()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "gobackward.10").font(.largeTitle)
                    Text("后退 10s").font(.caption2)
                }
                .foregroundStyle(.white)
            }
            Button {
                togglePlay()
            } label: {
                Image(systemName: model.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
            }
            Button {
                model.jump(10)
                scheduleHide()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "goforward.10").font(.largeTitle)
                    Text("前进 10s").font(.caption2)
                }
                .foregroundStyle(.white)
            }
        }
    }

    // 底部：进度 + 倍速 + 同刻三路 + 相邻时段
    private var bottomBar: some View {
        VStack(spacing: 9) {
            Slider(value: Binding(
                get: { model.position },
                set: { model.seek(to: $0) }
            ))
            .tint(currentFile.locked == true ? Color.red : Color.white)

            HStack {
                Text(model.timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Text("/ \(model.durationText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }

            // 倍速（按分类记忆，含 5/7/10× 快进档）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Text("倍速")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    ForEach(rates, id: \.self) { r in
                        let active = abs(model.rate - r) < 0.01
                        Button {
                            applyRate(r)
                        } label: {
                            Text(rateLabel(r))
                                .font(.system(size: 10, weight: active ? .bold : .regular))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(active ? CL.blue : Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 22)

            if !fullscreen {
                // 同刻三路（前 / 后 / 自由）
                HStack(spacing: 5) {
                    Text("三路")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    ForEach([Camera.front, .rear, .free], id: \.self) { cam in
                        cameraChip(cam)
                    }
                    Spacer()
                }

                // 相邻时段
                HStack {
                    if let prev = prevFile {
                        Button {
                            play(prev, syncPosition: false)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left").font(.caption2)
                                Text(Fmt.time(prev.date)).font(.caption)
                            }
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("相邻时段")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if let next = nextFile {
                        Button {
                            play(next, syncPosition: false)
                        } label: {
                            HStack(spacing: 3) {
                                Text(Fmt.time(next.date)).font(.caption)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 子组件

    @ViewBuilder
    private func cameraChip(_ cam: Camera) -> some View {
        let target = sameStampFiles.first { $0.cameraEnum == cam }
        let isCurrent = currentFile.cameraEnum == cam
        Button {
            if let t = target, !isCurrent {
                play(t, syncPosition: true)
            }
        } label: {
            Text(cam.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isCurrent ? Color.blue :
                        (target != nil ? Color.white.opacity(0.18) : Color.white.opacity(0.06)))
                )
                .opacity(target == nil && !isCurrent ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(target == nil || isCurrent)
    }

    private func tapZone(jumpAction: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                jumpAction()
                scheduleHide()
            }
            .onTapGesture { toggleControls() }
    }

    // MARK: - 数据

    /// 同一时间戳的条目（含自己）
    private var sameStampFiles: [CarFile] {
        siblings.filter { $0.id == currentFile.id || $0.sameStamp(as: currentFile) }
    }

    /// 同摄像头按时间排序的条目（相邻时段 / 自动连播）
    private var cameraTimeline: [CarFile] {
        siblings
            .filter { $0.cameraEnum == currentFile.cameraEnum }
            .sorted { $0.date < $1.date }
    }

    private var prevFile: CarFile? {
        guard let i = cameraTimeline.firstIndex(where: { $0.id == currentFile.id }), i > 0 else { return nil }
        return cameraTimeline[i - 1]
    }

    private var nextFile: CarFile? {
        guard let i = cameraTimeline.firstIndex(where: { $0.id == currentFile.id }),
              i + 1 < cameraTimeline.count else { return nil }
        return cameraTimeline[i + 1]
    }

    private var localRecord: LocalRecord? {
        library.record(for: currentFile)
    }

    private var infoText: String {
        let f = currentFile
        var lines = [
            "文件名：\(f.name)",
            "大小：\(Fmt.bytes(f.size))",
            "时间：\(Fmt.dateTime(f.date))",
            "摄像头：\(f.cameraEnum.title)",
            "车机路径：\(f.path)"
        ]
        if let d = DurationCache.duration(for: f.path) {
            lines.insert("时长：\(Fmt.duration(d))", at: 2)
        }
        return lines.joined(separator: "\n")
    }

    private var durationText: String {
        if let d = DurationCache.duration(for: currentFile.path) {
            return " · \(Fmt.duration(d))"
        }
        return ""
    }

    private var rateKey: String {
        "playerRate.\(categoryOf(currentFile).rawValue)"
    }

    // MARK: - 动作

    /// 已下载到「文件」App 的回退副本直接播本地，省流量也更快；
    /// 存相册的记录仍走车机流（相册资产需走 PhotoKit，不适合边下边播场景）
    private func playbackURL(for f: CarFile, api: APIClient) -> URL {
        if let rec = library.record(for: f), rec.kind == .fileTS {
            let local = LibraryStore.tsDirectory.appending(path: rec.localRef)
            if FileManager.default.fileExists(atPath: local.path) { return local }
        }
        return api.downloadURL(path: f.path)
    }

    private func play(_ f: CarFile, syncPosition: Bool) {
        currentFile = f
        if let api = conn.client {
            model.play(url: playbackURL(for: f, api: api),
                       resumePosition: syncPosition ? model.position : 0)
            scheduleHide()
        }
    }

    /// 全屏：横屏沉浸播放（旋转整屏 + 隐藏状态栏，退出时恢复竖屏）
    private func setFullscreen(_ on: Bool) {
        fullscreen = on
        OrientationLock.shared.set(on ? .landscape : .portrait)
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleHide()
    }

    private func togglePlay() {
        model.togglePlay()
        scheduleHide()
    }

    private func applyRate(_ r: Float) {
        model.setRate(r)
        UserDefaults.standard.set(r, forKey: rateKey)
        scheduleHide()
    }

    /// 播放结束：自动连播下一段（可关），否则唤出控件
    private func handleEnded() {
        if settings.autoPlayNext, let next = nextFile {
            play(next, syncPosition: false)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
            hideTask?.cancel()
        }
    }

    private func prepareShare(_ rec: LocalRecord) {
        let imgExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "bmp", "gif"]
        if rec.kind == .fileTS {
            shareURL = LibraryStore.tsDirectory.appending(path: rec.localRef)
            showShare = true
        } else if imgExts.contains((rec.name as NSString).pathExtension.lowercased()) {
            PhotoSaver.loadAssetImage(localId: rec.localRef, size: CGSize(width: 4096, height: 4096)) { img in
                guard let img = img, let data = img.jpegData(compressionQuality: 0.95) else { return }
                let url = FileManager.default.temporaryDirectory.appending(path: rec.name)
                try? data.write(to: url)
                DispatchQueue.main.async {
                    self.shareURL = url
                    self.showShare = true
                }
            }
        } else {
            Task {
                if let u = await LocalVideoResolver.exportURL(localId: rec.localRef) {
                    self.shareURL = u
                    self.showShare = true
                }
            }
        }
    }

    private func categoryOf(_ f: CarFile) -> MediaCategory {
        if f.locked == true { return .locked }
        if !f.isVideo { return .snapshot }
        return .loop
    }

    private func rateLabel(_ r: Float) -> String {
        if abs(r - 1.0) < 0.01 { return "1.0×" }
        if r >= 10 { return String(format: "%.0f×", r) }
        return String(format: "%.1f×", r)
    }

    // MARK: 控件显隐（暂停时常驻，播放中 4s 自动隐藏）

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            // 暂停状态下控件常驻，避免「找不到控件」
            if model.playing {
                withAnimation(.easeInOut(duration: 0.4)) {
                    controlsVisible = false
                }
            }
        }
    }
}

// MARK: - VLC 桥接

struct VLCView: UIViewRepresentable {
    let mediaPlayer: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        mediaPlayer.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - VLC 回调中转（隔离 @objc 协议，回调线程 → 主线程）

private final class VLCDelivery: NSObject, VLCMediaPlayerDelegate {
    var onState: () -> Void = {}
    var onEnd: () -> Void = {}

    func mediaPlayerStateChanged(_ aNotification: Notification) { onState() }
    func mediaPlayerReachedEnd(_ aNotification: Notification) { onEnd() }
}

// MARK: - VLC 采样器（在后台队列读取播放状态）

/// libvlc 的 position / time 读取会与播放线程的输入锁同步；当网络流卡住时，
/// 在主线程读这些属性会把整个 UI 冻住（画面停在最后一帧，按钮/返回全部失效）。
/// 因此所有属性读取都放到独立串行队列，主线程只接收采样结果。
private final class VLCProbe {
    private let player: VLCMediaPlayer
    private let queue = DispatchQueue(label: "carlink.vlc.probe", qos: .utility)
    private var busy = false

    init(player: VLCMediaPlayer) {
        self.player = player
    }

    struct Sample {
        let position: Double
        let timeMs: Int
        let remainingMs: Int
        let playing: Bool
    }

    func sample(_ completion: @escaping (Sample) -> Void) {
        if busy { return }
        busy = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let s = Sample(position: Double(self.player.position),
                           timeMs: Int(self.player.time.intValue),
                           remainingMs: Int(self.player.remainingTime?.intValue ?? 0),
                           playing: self.player.isPlaying)
            DispatchQueue.main.async {
                self.busy = false
                completion(s)
            }
        }
    }
}

// MARK: - 播放模型

@MainActor
final class PlayerModel: NSObject, ObservableObject {
    let mediaPlayer = VLCMediaPlayer()
    private let delivery = VLCDelivery()
    private lazy var probe = VLCProbe(player: mediaPlayer)

    @Published var playing = false
    @Published var buffering = false
    @Published var position: Double = 0
    @Published var timeText = "00:00"
    @Published var durationText = "--:--"
    @Published var rate: Float = 1.0
    @Published var endedToken = 0

    private var ticker: Timer?
    private var currentPath: String?
    private var pendingResume: Double?
    private var endFired = false

    override init() {
        super.init()
        mediaPlayer.delegate = delivery
        delivery.onState = { [weak self] in
            Task { @MainActor in self?.syncState() }
        }
        delivery.onEnd = { [weak self] in
            Task { @MainActor in self?.fireEnd() }
        }
    }

    func play(url: URL, resumePosition: Double = 0) {
        endFired = false
        buffering = true
        pendingResume = resumePosition > 0.01 ? min(resumePosition, 0.98) : nil
        currentPath = url.query?.components(separatedBy: "&")
            .first { $0.hasPrefix("path=") }?
            .removingPercentEncoding?
            .replacingOccurrences(of: "path=", with: "")
        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        mediaPlayer.rate = rate
        mediaPlayer.play()
        playing = true
        startTicker()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        mediaPlayer.stop()
    }

    func togglePlay() {
        if playing {
            mediaPlayer.pause()
            playing = false
        } else {
            buffering = true
            mediaPlayer.play()
            playing = true
        }
    }

    func jump(_ seconds: Int) {
        if seconds > 0 {
            mediaPlayer.jumpForward(Int32(seconds))
        } else {
            mediaPlayer.jumpBackward(Int32(-seconds))
        }
    }

    func seek(to pos: Double) {
        let clamped = min(max(pos, 0), 0.999)
        mediaPlayer.position = Float(clamped)
        position = clamped
    }

    func setRate(_ r: Float) {
        rate = r
        mediaPlayer.rate = r
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 主线程只做轻量展示；真正的 VLC 读取在后台队列
    private func tick() {
        probe.sample { [weak self] s in
            Task { @MainActor in self?.apply(s) }
        }
    }

    private func apply(_ s: VLCProbe.Sample) {
        // 三路互切：新流开播后恢复上次进度
        if let p = pendingResume, s.playing, s.timeMs > 0 {
            mediaPlayer.position = Float(p)
            pendingResume = nil
        }
        position = s.position
        timeText = Fmt.mseconds(max(0, s.timeMs))
        let dur = s.timeMs - s.remainingMs   // remainingTime 为负值
        if dur > 0 {
            durationText = Fmt.mseconds(dur)
            if let p = currentPath {
                DurationCache.set(Double(dur) / 1000.0, for: p)
            }
        }
        if s.position > 0.0005 || s.timeMs > 0 {
            buffering = false
        }
        playing = s.playing
    }

    private func syncState() {
        // 不再读 mediaPlayer.state（可能与输入线程同步阻塞）；由采样结果驱动 UI
        if !playing && position > 0.995 { fireEnd() }
    }

    private func fireEnd() {
        guard !endFired else { return }
        endFired = true
        playing = false
        buffering = false
        endedToken += 1
    }
}
