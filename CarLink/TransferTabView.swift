import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 车机截图状态

private enum ScreenPhase {
    case idle
    case capturing(Date)
    case done(ScreenShotResult)
    case failed(String)
}

private struct ScreenShotResult: Identifiable {
    let image: UIImage
    /// adb = 现场截屏；cache = 车机 ADB 不可用时回退最近一张
    let source: String
    let ms: Int
    let width: Int
    let height: Int
    let bytes: Int
    let note: String?
    let at: Date
    let fileURL: URL

    var id: URL { fileURL }
    var isLive: Bool { source == "adb" }
}

// MARK: - 截图临时文件管理
//
// 自动连拍每 2~10 秒产生一张约 140KB 的 PNG，早期实现按秒时间戳命名且从不清理，
// 连拍一天就能堆 4~6GB。这里统一放到 tmp/carlink-shots/ 子目录并限制保留张数：
//   · 每次写入后 trim 到 keepCount 张（连拍期间目录恒定约 4 张 / 600KB）；
//   · 停止连拍 / 退出全屏时再收紧到只留当前展示那张，供结果卡继续分享、存相册；
//   · App 启动时清掉旧版本散落在 tmp 根目录的 carlink-screen-*.png 遗留文件。
// 用「保留窗口」而不是写完立刻删，是为了让异步的 ShareLink / 保存到相册能读完文件。
final class ScreenShotTempStore {
    static let shared = ScreenShotTempStore()

    /// App 启动时调用：触发单例初始化（清掉旧版本遗留文件）并收紧目录。
    /// 旧版本可能已堆积上万个 PNG，放到后台线程，避免同步删除卡住启动。
    static func cleanupOnLaunch() {
        DispatchQueue.global(qos: .utility).async {
            _ = shared
            shared.trim(keeping: [], keep: 4)
        }
    }

    private let dir: URL
    private let fm = FileManager.default
    /// 常规保留上限：当前展示 + 传输页结果卡 + 分享/相册读取缓冲
    private let keepCount = 4

    private init() {
        let d = fm.temporaryDirectory.appendingPathComponent("carlink-shots", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        // 旧版本遗留：tmp 根目录里按秒命名的 carlink-screen-<时间戳>.png
        let legacy = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                  includingPropertiesForKeys: nil,
                                                  options: .skipsHiddenFiles)) ?? []
        for u in legacy {
            guard u.lastPathComponent.hasPrefix("carlink-screen-"),
                  u.pathExtension.lowercased() == "png" else { continue }
            try? fm.removeItem(at: u)
        }
    }

    /// 写入一张新截图并返回 URL；写完后立刻按上限清理旧文件
    func write(_ data: Data) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shot-\(UUID().uuidString).png")
        // atomic：先写临时再 rename，避免连拍时 ShareLink / 相册读到写了一半的文件
        try data.write(to: url, options: .atomic)
        trim()
        return url
    }

    /// 只保留 protected 指定文件 + 最新 keep 张，其余删除
    func trim(keeping protected: [URL] = [], keep: Int? = nil) {
        let limit = keep ?? keepCount
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles) else { return }

        let dated: [(URL, Date)] = files.map { u in
            let values = try? u.resourceValues(forKeys: [.contentModificationDateKey])
            let d = values?.contentModificationDate ?? Date.distantPast
            return (u, d)
        }.sorted { $0.1 > $1.1 }

        let keepSet = Set(protected.map { $0.standardizedFileURL })
            .union(dated.prefix(limit).map { $0.0.standardizedFileURL })
        for (u, _) in dated where !keepSet.contains(u.standardizedFileURL) {
            try? fm.removeItem(at: u)
        }
    }
}

// MARK: - 传输 Tab：车机屏幕截图 + 上传 + 下载队列

struct TransferTabView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var uploads: UploadManager
    @EnvironmentObject var downloads: DownloadManager

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    /// 截图状态机：idle → capturing(开始时间) → done / failed
    @State private var screenPhase: ScreenPhase = .idle
    @State private var screenToast: String?
    /// 全屏查看的截图（点图片进入）
    @State private var previewShot: ScreenShotResult?

    var body: some View {
        NavigationStack {
            List {
                screenSection
                carFilesSection
                uploadSection
                downloadSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("传输")
            .overlay(alignment: .bottom) {
                if let t = screenToast {
                    Text(t)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.74)))
                        .padding(.bottom, 22)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: screenToast)
            .fullScreenCover(item: $previewShot) { shot in
                ScreenShotFullscreen(shot: shot) {
                    // 全屏里点「重截」：就地刷新大图，同时让退出后的结果卡也是新图
                    let r = try await fetchShot()
                    screenPhase = .done(r)
                    return r
                }
            }
        }
    }

    // MARK: - 车机屏幕截图（服务端现场截屏）

    private var screenSupported: Bool {
        // 老车机没有这个字段时按支持处理：真正调用会返回 404 并给出升级提示
        conn.carInfo?.screenCapture != false
    }

    private var screenSection: some View {
        Section {
            if !conn.isLinkUsable {
                Label(conn.hasSession ? "车机连接已断开，正在自动重连…" : "未连接车机，连接后可截图",
                      systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else if !screenSupported {
                Label("车机端 v\(conn.carInfo?.version ?? "?") 不支持截图，请先升级到 1.1.29",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            } else {
                switch screenPhase {
                case .idle:
                    Button {
                        captureScreen()
                    } label: {
                        HStack(spacing: 8) {
                            Label("截取车机屏幕", systemImage: "camera.viewfinder")
                            Spacer()
                            Text("约 1 秒").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .capturing(let started):
                    HStack(spacing: 10) {
                        ProgressView()
                        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                            Text("正在截取车机屏幕… 已用时 "
                                 + String(format: "%.1f", max(0, ctx.date.timeIntervalSince(started)))
                                 + "s")
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 4)
                case .done(let r):
                    screenResult(r)
                    // 单独成一格：与上一排按钮之间由 List 原生行距隔开，避免误触
                    NavigationLink {
                        CarFilesBrowserView(initialPath: screenDir)
                    } label: {
                        HStack {
                            Label("查看车机全部截图", systemImage: "photo.on.rectangle")
                            Spacer()
                            Text("CarCap").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .failed(let msg):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(msg, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        HStack(spacing: 14) {
                            Button("重试") { captureScreen() }
                                .font(.subheadline.weight(.medium))
                            NavigationLink("查看车机全部截图") {
                                CarFilesBrowserView(initialPath: screenDir)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("车机屏幕")
        } footer: {
            Text("车机现场截屏后直接把图片回传手机，不在车机留存；手机端临时图只保留最近几张，自动连拍不会占满存储。截图只在这里预览，需要时点「保存到相册」。车机端 1.1.29+ 支持。")
        }
    }

    private var screenDir: String { "/sdcard/Pictures/CarCap" }

    @ViewBuilder
    private func screenResult(_ r: ScreenShotResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                previewShot = r
            } label: {
                Image(uiImage: r.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 210)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                            Text("全屏")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(8)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看车机屏幕大图")

            HStack(spacing: 6) {
                Text("\(r.width)×\(r.height) · \(Fmt.bytes(r.bytes)) · \(Self.timeText.string(from: r.at))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !r.isLive {
                    Text("最近一张")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                } else {
                    Text("现场截屏")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                }
            }

            if let note = r.note, !note.isEmpty, !r.isLive {
                Text(note).font(.caption2).foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                Button {
                    saveShot(r)
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                }
                .font(.subheadline)
                ShareLink(item: r.fileURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .font(.subheadline)
                Button {
                    captureScreen()
                } label: {
                    Label("重截", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func captureScreen() {
        guard conn.client != nil else {
            screenPhase = .failed("未连接车机")
            return
        }
        screenPhase = .capturing(Date())
        Task {
            do {
                screenPhase = .done(try await fetchShot())
            } catch {
                screenPhase = .failed(Self.errorText(error))
            }
        }
    }

    /// 单次现场截屏：传输页与全屏预览里的「重截」共用
    private func fetchShot() async throws -> ScreenShotResult {
        guard let api = conn.client else {
            throw NSError(domain: "CarLink", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "未连接车机"])
        }
        let cap = try await api.captureScreen()
        guard let img = UIImage(data: cap.data) else {
            throw NSError(domain: "CarLink", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "车机返回的不是有效图片"])
        }
        // 统一交给临时文件管理器：只保留最近几张，连拍不会撑爆手机存储
        let url = try ScreenShotTempStore.shared.write(cap.data)
        return ScreenShotResult(image: img,
                                source: cap.source,
                                ms: cap.ms,
                                width: cap.width,
                                height: cap.height,
                                bytes: cap.data.count,
                                note: cap.note,
                                at: Date(),
                                fileURL: url)
    }

    static func errorText(_ error: Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }

    private func saveShot(_ r: ScreenShotResult) {
        Task {
            do {
                _ = try await PhotoSaver.saveToAlbum(fileAt: r.fileURL)
                screenToast = "已保存到相册"
            } catch {
                screenToast = "保存失败：\(error.localizedDescription)"
            }
            hideToast()
        }
    }

    private func hideToast() {
        let text = screenToast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if screenToast == text { screenToast = nil }
        }
    }

    static let timeText: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - 车机文件（浏览内部存储 / SD 卡）

    private var carFilesSection: some View {
        Section {
            NavigationLink {
                CarFilesBrowserView()
            } label: {
                Label("浏览车机文件", systemImage: "externaldrive")
            }
            .disabled(!conn.isLinkUsable)
        } header: {
            Text("车机文件")
        } footer: {
            Text(conn.isLinkUsable
                 ? "浏览车机内部存储 / SD 卡 / U 盘里的任意文件（音乐、安装包、文档…）并下载到「文件」App › CarLink › 车机文件。"
                 : (conn.hasSession ? "车机连接已断开，正在自动重连…" : "未连接车机，连接后即可浏览车机文件。"))
        }
    }

    // MARK: - 上传

    private var uploadSection: some View {
        Section {
            if !conn.isLinkUsable {
                Label(conn.hasSession ? "车机连接已断开，正在自动重连…" : "未连接车机，连接后即可上传",
                      systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            PhotosPicker(selection: $photoSelection,
                         matching: .any(of: [.images, .videos]),
                         photoLibrary: .shared()) {
                Label("从相册选择上传", systemImage: "photo.stack")
            }
            .disabled(!conn.isLinkUsable)
            .onChange(of: photoSelection) { items in
                for item in items {
                    guard let id = item.itemIdentifier else { continue }
                    uploads.uploadAsset(id, name: "照片/视频")
                }
                photoSelection.removeAll()
            }

            Button {
                showFileImporter = true
            } label: {
                Label("从「文件」App 选择上传", systemImage: "folder")
            }
            .disabled(!conn.isLinkUsable)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    uploads.uploadFile(url: url)
                }
            }

            if !uploads.items.isEmpty {
                ForEach(uploads.items) { item in
                    UploadRow(item: item) {
                        uploads.remove(item)
                    }
                }
                if uploads.items.contains(where: { $0.state == .done || $0.state == .failed }) {
                    Button("清除已完成/失败") { uploads.clearFinished() }
                        .font(.subheadline)
                }
            }
        } header: {
            Text("上传到车机")
        } footer: {
            if let maxBytes = conn.carInfo?.switches?.receive, maxBytes == false {
                Text("车机端已关闭「文件接收」，上传会被拒绝。").foregroundStyle(.orange)
            } else {
                Text("上传分片进行（2 MB/片），中断后可重新发起。")
            }
        }
    }

    // MARK: - 下载队列

    private var downloadSection: some View {
        Section {
            if downloads.items.isEmpty {
                Text("暂无下载任务")
                    .foregroundStyle(.secondary)
            }
            if !downloads.items.isEmpty {
                HStack {
                    Button("全部暂停") { downloads.pauseAll() }
                        .font(.subheadline)
                    Spacer()
                    Button("全部取消") { downloads.cancelAll() }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Spacer()
                    if downloads.items.contains(where: { $0.state == .done }) {
                        Button("清除已完成") { downloads.clearFinished() }
                            .font(.subheadline)
                    }
                }
            }
            ForEach(downloads.items) { item in
                DownloadRow(item: item,
                            onPause: { downloads.pause(item) },
                            onResume: { downloads.resume(item) },
                            onRetry: { downloads.retry(item) },
                            onCancel: { downloads.cancel(item) })
            }
        } header: {
            HStack {
                Text("下载队列")
                Spacer()
                if downloads.activeCount > 0 {
                    Text("进行中 \(downloads.activeCount)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        } footer: {
            Text("视频下载后在本机转存 .mp4（画质不变）；转存失败的坏文件自动保存原始 .ts 到「文件」App › CarLink。播放视频时下载会自动挂起，退出播放后续跑。")
        }
    }
}

// MARK: - 上传行

struct UploadRow: View {
    @ObservedObject var item: UploadItem
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.state == .done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
            }
            if item.state == .preparing || item.state == .running {
                ProgressView(value: item.progress)
                Text("\(Fmt.bytes(item.sent)) / \(item.size > 0 ? Fmt.bytes(item.size) : "…")"
                     + (item.state == .running && item.speedBps > 0 ? " · \(Fmt.rate(item.speedBps))" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let msg = item.message {
                Text(msg).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch item.state {
        case .preparing: return "hourglass"
        case .running: return "arrow.up.circle"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .preparing: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .orange
        }
    }

    private var statusText: String {
        switch item.state {
        case .preparing: return "准备中…"
        case .running: return item.speedBps > 0
            ? "上传中 \(Int(item.progress * 100))% · \(Fmt.rate(item.speedBps))"
            : "上传中 \(Int(item.progress * 100))%"
        case .done: return "已保存到车机 \(item.savedPath.map { "· \($0)" } ?? "")"
        case .failed: return item.message ?? "上传失败"
        }
    }
}

// MARK: - 下载行

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    var onPause: () -> Void
    var onResume: () -> Void
    var onRetry: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CameraBadge(camera: item.file.cameraEnum)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.file.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                controls
            }
            if item.state == .downloading || (item.state == .paused && item.received > 0) {
                ProgressView(value: item.progress)
                Text("\(Fmt.bytes(item.received)) / \(item.total > 0 ? Fmt.bytes(item.total) : Fmt.bytes(item.file.size))"
                     + (item.state == .downloading && item.speedBps > 0 ? " · \(Fmt.rate(item.speedBps))" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let msg = item.message, item.state == .failed || item.state == .done {
                Text(msg).font(.caption2).foregroundStyle(item.state == .failed ? .orange : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch item.state {
            case .downloading, .waiting:
                Button(action: onPause) { Image(systemName: "pause.circle") }
            case .paused, .failed:
                Button(action: onResume) { Image(systemName: "play.circle") }
            default:
                EmptyView()
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.title3)
    }

    private var statusText: String {
        switch item.state {
        case .waiting: return "排队中"
        case .downloading: return item.speedBps > 0
            ? "下载中 \(Int(item.progress * 100))% · \(Fmt.rate(item.speedBps))"
            : "下载中 \(Int(item.progress * 100))%"
        case .paused: return "已暂停 \(Int(item.progress * 100))%"
        case .failed: return item.message ?? "下载失败"
        case .done: return item.savedAs ?? "已完成"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed: return .orange
        case .done: return .green
        default: return .secondary
        }
    }
}

// MARK: - 车机截图全屏预览
//
// 传输 Tab 里点截图缩略图直接进这里：默认竖屏整屏看图，
// 想看细节可点底部「横屏」按钮切换方向（退出自动恢复竖屏），
// 支持双击 / 捏合放大、放大后拖动，单击收起工具栏。

private struct ScreenShotFullscreen: View {
    let shot: ScreenShotResult
    /// 重新截取一张车机屏幕；全屏里的「重截」按钮调用
    let capture: () async throws -> ScreenShotResult

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var showChrome = true
    @State private var landscape = false
    @State private var toast: String?
    /// 全屏内重截后的新图（不改动 previewShot，避免 fullScreenCover 重建）
    @State private var refreshed: ScreenShotResult?
    /// 手动重截 / 自动连拍共用的忙标志，避免两张截图并发
    @State private var busy = false

    // MARK: 自动截图
    /// 0 = 关闭；否则为间隔秒数
    @State private var autoSeconds = 0
    /// 每次开启 / 改间隔 / 停止都 +1，驱动 .task(id:) 取消上一轮循环
    @State private var autoSession = 0
    @State private var autoCount = 0
    @State private var autoNextAt: Date?
    @State private var autoSave = false
    @State private var autoFailStreak = 0

    private var display: ScreenShotResult { refreshed ?? shot }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: display.image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnify)
                .simultaneousGesture(pan)
                .onTapGesture(count: 2) { toggleZoom() }
                .onTapGesture { toggleChrome() }

            if showChrome { chrome }
        }
        .statusBarHidden(true)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.74)))
                    .padding(.bottom, 74)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast)
        // id 变化 / 视图消失会自动 cancel 上一轮连拍，无需手动管理 Timer
        .task(id: autoSession) {
            await autoRun()
        }
        .onAppear {
            // 默认竖屏，是否转横屏交给底部按钮
            DispatchQueue.main.async { OrientationLock.shared.set(.portrait) }
        }
        .onDisappear {
            stopAuto()
            // 连拍/重截期间产生的临时图只留当前展示这张，退出后结果卡还要用它分享、存相册
            ScreenShotTempStore.shared.trim(keeping: [display.fileURL], keep: 1)
            OrientationLock.shared.set(.portrait)
        }
    }

    private var subtitle: String {
        var s = "\(display.width)×\(display.height) · \(Fmt.bytes(display.bytes)) · "
            + TransferTabView.timeText.string(from: display.at)
        s += display.isLive ? " · 现场截屏" : " · 最近一张"
        return s
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .accessibilityLabel("关闭")

                VStack(alignment: .leading, spacing: 1) {
                    Text("车机屏幕")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Button {
                    toggleZoom()
                } label: {
                    Image(systemName: scale > 1.01
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .accessibilityLabel(scale > 1.01 ? "还原大小" : "放大")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            Spacer(minLength: 0)

            if autoSeconds > 0 { autoStatusBar }

            HStack(spacing: 16) {
                Button {
                    save()
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                }
                ShareLink(item: display.fileURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button {
                    recapture()
                } label: {
                    if busy {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 26)
                    } else {
                        Label("重截", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(busy)
                .accessibilityLabel("重新截取车机屏幕")
                Button {
                    toggleOrientation()
                } label: {
                    Label(landscape ? "竖屏" : "横屏",
                          systemImage: landscape ? "rotate.left" : "rotate.right")
                }
                .accessibilityLabel(landscape ? "切回竖屏" : "切换横屏")

                Menu {
                    Section("自动截图间隔") {
                        ForEach([2, 3, 5, 10], id: \.self) { s in
                            Button {
                                startAuto(s)
                            } label: {
                                if autoSeconds == s {
                                    Label("每 \(s) 秒", systemImage: "checkmark")
                                } else {
                                    Text("每 \(s) 秒")
                                }
                            }
                        }
                    }
                    Button {
                        autoSave.toggle()
                    } label: {
                        Label(autoSave ? "自动保存：开" : "自动保存：关",
                              systemImage: autoSave ? "checkmark.square" : "square")
                    }
                    if autoSeconds > 0 {
                        Button("停止自动截图", role: .destructive) {
                            stopAuto()
                        }
                    }
                } label: {
                    Label(autoSeconds > 0 ? "\(autoSeconds)s" : "自动",
                          systemImage: autoSeconds > 0 ? "timer.circle.fill" : "timer")
                }
                .accessibilityLabel("自动截图设置")
            }
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .tint(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .padding(.bottom, 10)
        }
    }

    // MARK: 手势

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                scale = min(max(baseScale * v, 1), 5)
            }
            .onEnded { _ in
                if scale <= 1.02 {
                    withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
                } else {
                    baseScale = scale
                    baseOffset = offset
                }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1.01 else { return }
                let limit = 180 * (scale - 1)
                let x = baseOffset.width + v.translation.width
                let y = baseOffset.height + v.translation.height
                offset = CGSize(width: min(max(x, -limit), limit),
                                height: min(max(y, -limit), limit))
            }
            .onEnded { _ in
                guard scale > 1.01 else { return }
                baseOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            if scale > 1.01 {
                resetZoom()
            } else {
                scale = 2.4
                baseScale = 2.4
            }
        }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.16)) { showChrome.toggle() }
    }

    /// 默认竖屏，由用户点「横屏」主动切换；退出时统一恢复竖屏
    private func toggleOrientation() {
        landscape.toggle()
        OrientationLock.shared.set(landscape ? .landscape : .portrait)
    }

    private func save() {
        Task {
            do {
                _ = try await PhotoSaver.saveToAlbum(fileAt: display.fileURL)
                flash("已保存到相册")
            } catch {
                flash("保存失败：\(error.localizedDescription)")
            }
        }
    }

    /// 全屏内重新截一张车机屏幕：大图就地刷新，不用退出再进
    private func recapture() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await capture()
                refreshed = r
                resetZoom()
                flash("已重新截取车机屏幕")
            } catch {
                flash("截取失败：\(TransferTabView.errorText(error))")
            }
        }
    }

    // MARK: - 自动截图（按间隔连拍）

    /// 连拍状态条：显示间隔、已截张数、下一张倒计时与停止按钮
    private var autoStatusBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("自动 · 每 \(autoSeconds)s · 已 \(autoCount) 张")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                if autoSave {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption2)
                }
                Spacer(minLength: 4)
                Text(nextText(ctx.date))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Button {
                    stopAuto()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17))
                }
                .accessibilityLabel("停止自动截图")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(autoSave ? Color.green.opacity(0.26) : Color.white.opacity(0.14)))
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func nextText(_ now: Date) -> String {
        if busy { return "截取中…" }
        guard let t = autoNextAt else { return "准备中…" }
        return "下一张 \(max(0, Int(ceil(t.timeIntervalSince(now)))))s"
    }

    private func startAuto(_ seconds: Int) {
        autoSeconds = seconds
        autoCount = 0
        autoFailStreak = 0
        autoNextAt = nil
        autoSession += 1           // 重启连拍循环（旧 task 自动 cancel）
        flash("自动截图已开启：每 \(seconds) 秒一张")
    }

    private func stopAuto() {
        guard autoSeconds > 0 else { return }
        autoSeconds = 0
        autoNextAt = nil
        autoSession += 1           // 让在途的连拍循环立刻退出
        // 停止后不再产生新图，收紧保留窗口
        ScreenShotTempStore.shared.trim(keeping: [display.fileURL], keep: 2)
    }

    /// .task(id:) 驱动：id 变化或视图消失会自动 cancel 上一轮，不留后台定时器
    private func autoRun() async {
        guard autoSeconds > 0 else { return }
        let seconds = autoSeconds
        while !Task.isCancelled, autoSeconds == seconds {
            let began = Date()
            await autoCaptureOnce(seconds: seconds)
            guard !Task.isCancelled, autoSeconds == seconds else { break }
            // 扣掉本次截图耗时，保证「每 N 秒一张」而不是「每 N+耗时 秒一张」
            let wait = max(0.3, Double(seconds) - Date().timeIntervalSince(began))
            autoNextAt = Date().addingTimeInterval(wait)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func autoCaptureOnce(seconds: Int) async {
        guard autoSeconds == seconds, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await capture()
            guard autoSeconds == seconds else { return }   // 期间已停止：丢弃这一张
            refreshed = r          // 不 resetZoom，保留用户当前放大 / 拖动位置
            autoCount += 1
            autoFailStreak = 0
            if autoSave {
                _ = try? await PhotoSaver.saveToAlbum(fileAt: r.fileURL)
            }
        } catch {
            guard autoSeconds == seconds else { return }
            autoFailStreak += 1
            if autoFailStreak >= 3 {
                flash("自动截图已停止：连续 3 次截取失败")
                stopAuto()
            } else {
                flash("自动截取失败（\(autoFailStreak)/3）：\(TransferTabView.errorText(error))")
            }
        }
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            if toast == text { toast = nil }
        }
    }
}
