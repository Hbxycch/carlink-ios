import SwiftUI
import MobileVLCKit

// MARK: - 视频播放页（VLCKit 边下边播 .ts）

struct PlayerView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    let file: CarFile
    /// 同分类全部条目（用于三路互切）
    let siblings: [CarFile]

    @StateObject private var model = PlayerModel()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var currentFile: CarFile

    init(file: CarFile, siblings: [CarFile]) {
        self.file = file
        self.siblings = siblings
        _currentFile = State(initialValue: file)
    }

    /// 同时间戳的其它摄像头
    private var cameraSwitches: [CarFile] {
        siblings.filter { $0.id != currentFile.id && $0.sameStamp(as: currentFile) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(mediaPlayer: model.mediaPlayer)
                .ignoresSafeArea()

            if controlsVisible {
                VStack {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar
                }
                .padding()
                .transition(.opacity)
            }
        }
        .onTapGesture { toggleControls() }
        .onAppear {
            guard let api = conn.client else { return }
            model.play(url: api.downloadURL(path: file.path))
            scheduleHide()
        }
        .onDisappear { model.stop() }
    }

    // 顶部：标题 + 关闭 + 三路切换
    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                CameraBadge(camera: currentFile.cameraEnum)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.dateTime(currentFile.date))
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(Fmt.bytes(currentFile.size))\(durationText)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if !libraryDownloaded {
                    Button {
                        downloads.addOne(currentFile, target: categoryOf(currentFile))
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
            }
            if !cameraSwitches.isEmpty {
                HStack(spacing: 8) {
                    Text("切换").font(.caption).foregroundStyle(.white.opacity(0.7))
                    ForEach(cameraSwitches) { f in
                        Button {
                            currentFile = f
                            model.play(url: streamURL(f))
                        } label: {
                            CameraBadge(camera: f.cameraEnum)
                                .padding(4)
                                .background(Capsule().fill(Color.white.opacity(0.15)))
                        }
                    }
                }
            }
        }
    }

    // 中部：±10s + 播放/暂停
    private var centerControls: some View {
        HStack(spacing: 44) {
            Button {
                model.jump(-10)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "gobackward.10").font(.largeTitle)
                    Text("后退 10s").font(.caption2)
                }
                .foregroundStyle(.white)
            }
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
            }
            Button {
                model.jump(10)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "goforward.10").font(.largeTitle)
                    Text("前进 10s").font(.caption2)
                }
                .foregroundStyle(.white)
            }
        }
    }

    // 底部：进度 + 时间 + 倍速
    private var bottomBar: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(
                get: { model.position },
                set: { model.seek(to: $0) }
            ))
            HStack {
                Text(model.timeText).font(.caption.monospacedDigit()).foregroundStyle(.white)
                Text("/ \(model.durationText)").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Menu {
                    ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { r in
                        Button {
                            model.setRate(r)
                        } label: {
                            if abs(model.rate - r) < 0.01 {
                                Label(rateLabel(r), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(r))
                            }
                        }
                    }
                } label: {
                    Text(rateLabel(model.rate))
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    // MARK: - 工具

    private var libraryDownloaded: Bool {
        downloads.library?.isDownloaded(currentFile) ?? false
    }

    private func categoryOf(_ f: CarFile) -> MediaCategory {
        if f.locked == true { return .locked }
        if !f.isVideo { return .snapshot }
        return .loop
    }

    private func streamURL(_ f: CarFile) -> URL? {
        conn.client?.downloadURL(path: f.path)
    }

    private var durationText: String {
        if let d = DurationCache.duration(for: currentFile.path) {
            return " · \(Fmt.duration(d))"
        }
        return ""
    }

    private func rateLabel(_ r: Float) -> String {
        if abs(r - 1.0) < 0.01 { return "1.0×" }
        return String(format: "%.1f×", r)
    }

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
            withAnimation(.easeInOut(duration: 0.4)) {
                controlsVisible = false
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

// MARK: - 播放模型

@MainActor
final class PlayerModel: ObservableObject {
    let mediaPlayer = VLCMediaPlayer()

    @Published var playing = false
    @Published var position: Double = 0
    @Published var timeText = "00:00"
    @Published var durationText = "--:--"
    @Published var rate: Float = 1.0

    private var ticker: Timer?
    private var currentPath: String?

    func play(url: URL) {
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
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        position = Double(mediaPlayer.position)
        let t = mediaPlayer.time.intValue
        let rem = mediaPlayer.remainingTime.intValue
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
}
