import SwiftUI
import UIKit
import MobileVLCKit

// MARK: - 统一播放条目（车机在线 / 本地已下载）
//
// 以前在线播放走 PlayerView（VLC + 全套控件），本地播放走 LocalViewerSheet
// （系统 VideoPlayer / 裸 VLC，没有倍速、没有三路互切）。两者合并成同一套控件：
// 只要把「怎么拿到 URL」抽象出来，UI 完全复用。

struct PlayItem: Identifiable {
    /// 列表内唯一标识：远程用车机路径，本地用 sourcePath#size
    let id: String
    let name: String
    let date: Date
    let camera: Camera
    let size: Int64
    let locked: Bool
    let isVideo: Bool
    let duration: Double?
    let category: MediaCategory
    /// 车机端条目（在线播放 / 下载用；本地条目也可能带上，便于显示车机路径）
    let file: CarFile?
    /// 本地已下载副本（存在则直接播本地，省流量也更快）
    let record: LocalRecord?

    /// 文件名里的时间戳（三路互切用）
    var stamp: String? {
        guard let m = name.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        return String(name[m])
    }

    func sameStamp(as other: PlayItem) -> Bool {
        guard let a = stamp, let b = other.stamp else { return false }
        return a == b
    }

    /// 只在车机上、本地还没有副本 → 显示下载按钮
    var canDownload: Bool { file != nil && record == nil }
    var remotePath: String? { file?.path }
    /// 播放进度的缓存键（时长记忆用）
    var cacheKey: String? { file?.path ?? record?.localRef }
}

extension PlayItem {
    init(file: CarFile, record: LocalRecord?) {
        self.id = file.path
        self.name = file.name
        self.date = file.date
        self.camera = file.cameraEnum
        self.size = file.size
        self.locked = file.locked == true
        self.isVideo = file.isVideo
        self.duration = record?.duration ?? DurationCache.duration(for: file.path)
        self.category = file.locked == true ? .locked : (file.isVideo ? .loop : .snapshot)
        self.file = file
        self.record = record
    }

    init(record: LocalRecord) {
        let exts: Set<String> = ["mp4", "mov", "ts", "mkv", "avi", "m4v", "mpg", "mpeg"]
        let ext = (record.name as NSString).pathExtension.lowercased()
        self.id = record.id
        self.name = record.name
        self.date = record.date
        self.camera = record.camera
        self.size = record.sourceSize
        self.locked = record.category == .locked
        self.isVideo = exts.contains(ext)
        self.duration = record.duration
        self.category = record.category
        self.file = nil
        self.record = record
    }
}

/// 解析可播放 URL：本地副本优先，其次车机流
private func resolvePlayURL(_ item: PlayItem, api: APIClient?) async -> URL? {
    if let rec = item.record { return await LocalVideoResolver.playableURL(record: rec) }
    if let p = item.remotePath, let api = api { return api.downloadURL(path: p) }
    return nil
}

// MARK: - 视频播放页（VLC 边下边播 + 全套控件；在线/本地共用）

struct PlayerView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// 同分类全部条目（三路互切 / 相邻时段 / 自动连播 / 上下滑切换）
    let items: [PlayItem]

    @StateObject private var model = PlayerModel()
    @State private var index: Int
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showInfo = false
    @State private var confirmDeleteLocal = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var fullscreen = false
    @State private var loadingURL = false
    @State private var loadFailed: String?
    @State private var hint: String?
    @State private var hintTask: Task<Void, Never>?
    @State private var loadToken = 0

    /// 0.5× ~ 10×（慢放查细节 / 快进找事件）
    private let rates: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 7.0, 10.0]

    init(items: [PlayItem], startID: String) {
        self.items = items
        let i = items.firstIndex { $0.id == startID } ?? 0
        _index = State(initialValue: max(0, min(i, max(0, items.count - 1))))
    }

    private var item: PlayItem {
        guard !items.isEmpty else {
            return PlayItem(file: CarFile(name: "", path: "", size: 0, modified: 0,
                                          format: nil, camera: nil, locked: nil, thumb: nil),
                            record: nil)
        }
        return items[min(max(index, 0), items.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(mediaPlayer: model.mediaPlayer)
                .ignoresSafeArea()

            // 手势层（位于视频之上、控件之下）：单击切换控件，双击左右 ±10s，
            // 上划 = 上一条，下滑 = 下一条
            HStack(spacing: 0) {
                tapZone { model.jump(-10) }
                tapZone { model.jump(10) }
            }
            .ignoresSafeArea()
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        let dy = v.translation.height
                        let dx = v.translation.width
                        // 只认“明显竖向”的滑动，避免和横向误触打架
                        guard abs(dy) > abs(dx) * 1.3, abs(dy) > 56 else { return }
                        step(dy < 0 ? -1 : 1)
                    }
            )

            if let e = loadFailed {
                failedOverlay(e)
            } else if loadingURL {
                loadingOverlay
            } else if model.buffering {
                bufferingOverlay
            }

            if let h = hint {
                hintOverlay(h)
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
            // 播放期间给下载任务让路：车机 CPU/带宽都弱，边下边看必卡
            downloads.beginPlayback()
            playCurrent()
            scheduleHide()
        }
        .onDisappear {
            loadToken += 1
            model.stop()
            if fullscreen { setFullscreen(false) }
            downloads.endPlayback()
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
                if let rec = localRecord {
                    library.remove(rec)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶部：返回 + 摄像头 + 标题 + 下载/已在本地 + 更多菜单

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                if fullscreen { setFullscreen(false) }
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.15)))
            }

            CameraBadge(camera: item.camera)

            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.dateTime(item.date))
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if localRecord != nil {
                    HStack(spacing: 4) {
                        LocalTag(compact: true)
                        Text("\(Fmt.bytes(item.size))\(durationText)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    Text("\(Fmt.bytes(item.size))\(durationText)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 4)

            if item.canDownload, let f = item.file {
                Button {
                    downloads.addOne(f, target: .dashcam(item.category))
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

    // 状态徽标：● REC / 本地副本 · 上划下一条 提示
    private var badgesRow: some View {
        HStack(spacing: 5) {
            if localRecord != nil {
                Image(systemName: "internaldrive.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.green)
                Text("本地播放")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("REC")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                Text("TS 边下边播")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if item.locked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("锁定段")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 6)

            if downloads.playbackActive && downloads.pausedForPlaybackCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "pause.circle")
                        .font(.caption2)
                    Text("暂停 \(downloads.pausedForPlaybackCount) 个下载")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.72))
                .padding(.trailing, 6)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                Text("上一条")
                    .font(.caption2)
                Text("/")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                Text("下一条")
                    .font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.6))
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
            .tint(item.locked ? Color.red : Color.white)

            HStack {
                Text(model.timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Text("/ \(model.durationText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(index + 1)/\(items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
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

                // 相邻时段（上一条 / 下一条，和上下滑等效）
                HStack {
                    Button {
                        step(-1)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.up").font(.caption2)
                            Text(prevItem.map { Fmt.time($0.date) } ?? "到头了")
                                .font(.caption)
                        }
                        .foregroundStyle(.white)
                        .opacity(prevItem == nil ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("上一条 / 下一条")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button {
                        step(1)
                    } label: {
                        HStack(spacing: 3) {
                            Text(nextItem.map { Fmt.time($0.date) } ?? "到头了")
                                .font(.caption)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .opacity(nextItem == nil ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 覆盖层

    private var loadingOverlay: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(localRecord == nil ? "正在连接车机…" : "正在准备本地视频…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
    }

    private var bufferingOverlay: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("缓冲中…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45)))
    }

    private func failedOverlay(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(CL.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("重试") { playCurrent() }
                    .buttonStyle(.borderedProminent)
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.6)))
        .padding(28)
    }

    private func hintOverlay(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.top, fullscreen ? 24 : 92)
            Spacer()
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: - 子组件

    @ViewBuilder
    private func cameraChip(_ cam: Camera) -> some View {
        let target = sameStampItems.first { $0.camera == cam }
        let isCurrent = item.camera == cam
        Button {
            if let t = target, !isCurrent, let i = items.firstIndex(where: { $0.id == t.id }) {
                index = i
                playCurrent(resume: model.position)   // 三路互切保持进度
                showHint("切换到「\(cam.title)」\(Fmt.time(t.date))")
                scheduleHide()
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

    /// 同时间戳的条目（含自己）——三路互切用
    private var sameStampItems: [PlayItem] {
        items.filter { $0.id == item.id || $0.sameStamp(as: item) }
    }

    /// 同摄像头按时间排序（相邻时段 / 自动连播 / 上下滑）
    private var cameraTimeline: [PlayItem] {
        items
            .filter { $0.camera == item.camera || $0.camera == .unknown || item.camera == .unknown }
            .sorted { $0.date < $1.date }
    }

    private var prevItem: PlayItem? {
        guard let i = cameraTimeline.firstIndex(where: { $0.id == item.id }), i > 0 else { return nil }
        return cameraTimeline[i - 1]
    }

    private var nextItem: PlayItem? {
        guard let i = cameraTimeline.firstIndex(where: { $0.id == item.id }),
              i + 1 < cameraTimeline.count else { return nil }
        return cameraTimeline[i + 1]
    }

    private var localRecord: LocalRecord? {
        if let r = item.record { return r }
        if let f = item.file { return library.record(for: f) }
        return nil
    }

    private var infoText: String {
        var lines = [
            "文件名：\(item.name)",
            "大小：\(Fmt.bytes(item.size))",
            "时间：\(Fmt.dateTime(item.date))",
            "摄像头：\(item.camera.title)"
        ]
        if let r = item.record {
            lines.append("来源：本地副本（\(r.kind == .photoAlbum ? "系统相册" : "文件 App")）")
        }
        if let p = item.remotePath {
            lines.append("车机路径：\(p)")
        }
        if let d = item.duration ?? DurationCache.duration(for: item.cacheKey ?? "") {
            lines.insert("时长：\(Fmt.duration(d))", at: 2)
        }
        return lines.joined(separator: "\n")
    }

    private var durationText: String {
        if let d = item.duration ?? DurationCache.duration(for: item.cacheKey ?? "") {
            return " · \(Fmt.duration(d))"
        }
        return ""
    }

    private var rateKey: String {
        "playerRate.\(item.category.rawValue)"
    }

    // MARK: - 动作

    private func playCurrent(resume: Double = 0) {
        loadToken += 1
        let token = loadToken
        let target = item
        loadFailed = nil
        loadingURL = true
        model.prepareForLoad()
        Task {
            let url = await resolvePlayURL(target, api: conn.client)
            guard token == loadToken else { return }
            loadingURL = false
            guard let url else {
                loadFailed = target.record == nil
                    ? "未连接车机，无法在线播放"
                    : "该视频已从相册移除或仍在 iCloud"
                return
            }
            model.play(url: url, resumePosition: resume, cacheKey: target.cacheKey)
        }
    }

    /// 上/下切一条：上划 = 上一条（-1），下滑 = 下一条（+1）
    private func step(_ delta: Int) {
        let target = index + delta
        guard target >= 0, target < items.count else {
            showHint(delta < 0 ? "已经是第一条了" : "已经是最后一条了")
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }
        index = target
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        playCurrent()
        showHint("\(delta < 0 ? "上一条" : "下一条") · \(Fmt.dateTime(item.date))")
        scheduleHide()
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { hint = text }
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { hint = nil }
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

    /// 播放结束：自动连播下一条（可关），否则唤出控件
    private func handleEnded() {
        if settings.autoPlayNext, nextItem != nil {
            step(1)
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
    private var currentKey: String?
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

    /// 切来源前先清空状态，避免上一条的进度/时长污染新的一条
    func prepareForLoad() {
        endFired = false
        pendingResume = nil
        buffering = true
        playing = false
        position = 0
        timeText = "00:00"
        durationText = "--:--"
        mediaPlayer.stop()
    }

    func play(url: URL, resumePosition: Double = 0, cacheKey: String? = nil) {
        endFired = false
        buffering = true
        pendingResume = resumePosition > 0.01 ? min(resumePosition, 0.98) : nil
        currentKey = cacheKey
        let media = VLCMedia(url: url)
        // 车机是弱 CPU + 共享 WiFi：多缓冲一点能明显减少卡顿与花屏
        if url.isFileURL {
            media.addOption(":file-caching=600")
        } else {
            media.addOption(":network-caching=2000")
        }
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
            if let p = currentKey {
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
