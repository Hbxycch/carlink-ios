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

private struct ScreenShotResult {
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

    var isLive: Bool { source == "adb" }
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
            Text("车机现场截屏后直接把图片回传手机，不在车机留存。截图只在这里预览，需要时点「保存到相册」。车机端 1.1.29+ 支持。")
        }
    }

    private var screenDir: String { "/sdcard/Pictures/CarCap" }

    @ViewBuilder
    private func screenResult(_ r: ScreenShotResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(uiImage: r.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 210)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))

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

            if let note = r.note, !r.note.isEmpty, !r.isLive {
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

            NavigationLink {
                CarFilesBrowserView(initialPath: screenDir)
            } label: {
                HStack {
                    Label("查看车机全部截图", systemImage: "photo.on.rectangle")
                    Spacer()
                    Text("CarCap").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private func captureScreen() {
        guard let api = conn.client else {
            screenPhase = .failed("未连接车机")
            return
        }
        screenPhase = .capturing(Date())
        Task {
            do {
                let cap = try await api.captureScreen()
                guard let img = UIImage(data: cap.data) else {
                    screenPhase = .failed("车机返回的不是有效图片")
                    return
                }
                let name = "carlink-screen-\(Int(Date().timeIntervalSince1970)).png"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try cap.data.write(to: url)
                screenPhase = .done(ScreenShotResult(image: img,
                                                     source: cap.source,
                                                     ms: cap.ms,
                                                     width: cap.width,
                                                     height: cap.height,
                                                     bytes: cap.data.count,
                                                     note: cap.note,
                                                     at: Date(),
                                                     fileURL: url))
            } catch {
                screenPhase = .failed((error as? APIError)?.message ?? error.localizedDescription)
            }
        }
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
