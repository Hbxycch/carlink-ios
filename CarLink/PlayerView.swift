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

    private let rates: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0]

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
                    badgesRow
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar
                }
                .padding()
                .transition(.opacity)
            }
        }
        .onAppear {
            if UserDefaults.standard.object(forKey: rateKey) != nil {
                model.rate = UserDefaults.standard.float(forKey: rateKey)
            }
            guard let api = conn.client else { return }
            model.play(url: api.downloadURL(path: file.path))
            scheduleHide()
        }
        .onDisappear { model.stop() }
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
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                        Text("已在本地")
                            .font(.caption2)
                    }
                    .foregroundStyle(.green)
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
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
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

            // 倍速（按分类记忆）
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
                            .background(Capsule().fill(active ? Color.blue : Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

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

    private func play(_ f: CarFile, syncPosition: Bool) {
        currentFile = f
        if let u = conn.client?.downloadURL(path: f.path) {
            model.play(url: u, resumePosition: syncPosition ? model.position : 0)
            scheduleHide()
        }
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
            PhotoSaver.loadAssetVideoURL(localId: rec.localRef) { url in
                guard let u = url else { return }
                DispatchQueue.main.async {
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

// MARK: - 播放模型

@MainActor
final class PlayerModel: NSObject, ObservableObject {
    let mediaPlayer = VLCMediaPlayer()
    private let delivery = VLCDelivery()

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
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            playing = false
        } else {
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

    private func tick() {
        // 三路互切：新流开播后恢复上次进度
        if let p = pendingResume, mediaPlayer.isPlaying, mediaPlayer.time.intValue > 0 {
            mediaPlayer.position = Float(p)
            pendingResume = nil
        }
        position = Double(mediaPlayer.position)
        let t = Int(mediaPlayer.time.intValue)
        let rem = Int(mediaPlayer.remainingTime?.intValue ?? 0)
        timeText = Fmt.mseconds(max(0, t))
        let dur = t - rem   // remainingTime 为负值
        if dur > 0 {
            durationText = Fmt.mseconds(dur)
            if let p = currentPath {
                DurationCache.set(Double(dur) / 1000.0, for: p)
            }
        }
        playing = mediaPlayer.isPlaying
    }

    private func syncState() {
        playing = mediaPlayer.isPlaying
        let st = mediaPlayer.state
        buffering = (st == .buffering) || (st == .opening)
        if st == .ended { fireEnd() }
    }

    private func fireEnd() {
        guard !endFired else { return }
        endFired = true
        playing = false
        endedToken += 1
    }
}
