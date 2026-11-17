import Foundation
import Combine
import UIKit

// MARK: - 下载条目

enum DownloadState: String {
    case waiting
    case downloading
    case paused
    case failed
    case done
}

enum DownloadTarget {
    case screenshot
    case dashcam(MediaCategory)
    /// 车机文件浏览器里的任意文件：原样存「文件」App › CarLink › 车机文件
    case carFile

    var category: MediaCategory {
        switch self {
        case .screenshot: return .snapshot   // 截图与抓拍在本地文件页同栏展示
        case .dashcam(let c): return c
        case .carFile: return .snapshot
        }
    }

    var isArbitraryFile: Bool {
        if case .carFile = self { return true }
        return false
    }
}

final class DownloadItem: Identifiable, ObservableObject {
    let id: String            // 车机端源路径
    let file: CarFile
    let target: DownloadTarget

    @Published var state: DownloadState = .waiting
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var message: String?
    @Published var savedAs: String?

    var task: URLSessionDownloadTask?
    var resumeData: Data?

    init(file: CarFile, target: DownloadTarget) {
        self.file = file
        self.target = target
        self.id = file.path
    }

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(received) / Double(total))
    }

    var isActive: Bool { state == .downloading || state == .waiting }
}

// MARK: - URLSession 下载引擎（delegate 模式，支持暂停恢复）

protocol DownloadEngineDelegate: AnyObject {
    func onProgress(path: String, received: Int64, total: Int64)
    func onFinished(path: String, tempURL: URL, response: HTTPURLResponse?)
    func onError(path: String, error: Error)
}

final class DownloadEngine: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadEngine()

    private(set) lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    /// taskIdentifier → 源路径
    private var taskMap: [Int: String] = [:]
    private let lock = NSLock()

    weak var owner: DownloadEngineDelegate?

    func register(task: URLSessionDownloadTask, path: String) {
        lock.lock(); defer { lock.unlock() }
        taskMap[task.taskIdentifier] = path
    }

    func path(of task: URLSessionTask) -> String? {
        lock.lock(); defer { lock.unlock() }
        return taskMap[task.taskIdentifier]
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let path = path(of: downloadTask) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.owner?.onProgress(path: path, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 先把临时文件搬到稳定位置，再回主线程处理
        let stable = FileManager.default.temporaryDirectory
            .appending(path: "dl-\(UUID().uuidString)-\(downloadTask.response?.suggestedFilename ?? "file")")
        try? FileManager.default.moveItem(at: location, to: stable)
        let response = downloadTask.response as? HTTPURLResponse
        guard let path = path(of: downloadTask) else {
            try? FileManager.default.removeItem(at: stable)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.owner?.onFinished(path: path, tempURL: stable, response: response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error, let path = path(of: task) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.owner?.onError(path: path, error: e)
        }
    }

    private override init() {
        super.init()
    }
}

// MARK: - 下载角标（供列表页在封面上显示进度，不依赖 DownloadItem 的细粒度发布）

struct DownloadBadge: Equatable {
    var state: DownloadState
    var progress: Double

    var paused: Bool { state == .paused || state == .failed }
    var active: Bool { state == .downloading || state == .waiting || state == .paused }
}

// MARK: - 下载管理器

@MainActor
final class DownloadManager: ObservableObject, DownloadEngineDelegate {
    @Published private(set) var items: [DownloadItem] = []

    /// 源路径 → 封面进度角标（仅在百分比整数变化时更新，避免高频刷新整页）
    @Published private(set) var badges: [String: DownloadBadge] = [:]

    private let maxConcurrent = 2

    weak var connection: ConnectionStore?
    weak var library: LibraryStore?
    weak var settings: SettingsStore?
    private var netCancellable: AnyCancellable?

    // MARK: 播放期间限流
    //
    // 车机 CPU 很弱、WiFi 带宽也有限：一边看录像一边跑两个下载，播放端会不停卡顿。
    // 所以播放器打开时把正在跑的下载挂起（URLSession 支持 Range 断点续传，恢复时接着下），
    // 退出播放再自动续跑；排队中的任务在播放期间不启动。

    private var playbackDepth = 0
    /// 被「播放限流」自动挂起的任务（区别于用户手动暂停，退出播放后只续跑这些）
    private var autoPausedForPlayback: Set<String> = []

    var playbackActive: Bool { playbackDepth > 0 }
    var pausedForPlaybackCount: Int { autoPausedForPlayback.count }

    private var effectiveMaxConcurrent: Int {
        let v = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        return v > 0 ? min(4, max(1, v)) : maxConcurrent
    }

    /// 播放开始：挂起下载（可嵌套调用，按次数配对）
    func beginPlayback() {
        playbackDepth += 1
        guard playbackDepth == 1, settings?.pauseDownloadDuringPlayback != false else { return }
        for it in items where it.state == .downloading {
            autoPausedForPlayback.insert(it.id)
            pause(it)
        }
    }

    /// 播放结束：稍等片刻再续跑，避免「退出播放瞬间就抢带宽」造成界面卡顿
    func endPlayback() {
        playbackDepth = max(0, playbackDepth - 1)
        guard playbackDepth == 0, !autoPausedForPlayback.isEmpty else { return }
        let ids = autoPausedForPlayback
        autoPausedForPlayback.removeAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.playbackDepth == 0 else { return }
            for id in ids {
                if let it = self.items.first(where: { $0.id == id }), it.state == .paused {
                    self.resume(it)
                }
            }
            self.pump()
        }
    }

    /// 设置变更后重新调度（并发数、播放限流开关）
    func reschedule() { pump() }

    var activeCount: Int {
        items.filter { $0.state == .downloading || $0.state == .waiting }.count
    }

    var runningCount: Int {
        items.filter { $0.state == .downloading }.count
    }

    func setup(connection: ConnectionStore, library: LibraryStore, settings: SettingsStore) {
        self.connection = connection
        self.library = library
        self.settings = settings
        DownloadEngine.shared.owner = self
        // 网络变化（回到 WiFi）时自动续跑排队任务
        netCancellable = settings.$isWiFi
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pump() }
    }

    // MARK: - 加入队列

    /// 加入下载（自动跳过已在队列和已下载的）
    func add(_ files: [CarFile], target: DownloadTarget) -> Int {
        let inQueue = Set(items.map(\.id))
        var added = 0
        for f in files {
            guard !inQueue.contains(f.path) else { continue }
            if !target.isArbitraryFile, let lib = library, lib.isDownloaded(f) { continue }
            items.insert(DownloadItem(file: f, target: target), at: 0)
            badges[f.path] = DownloadBadge(state: .waiting, progress: 0)
            added += 1
        }
        if added > 0 { pump() }
        return added
    }

    /// 封面角标查询（无任务返回 nil）
    func badge(for path: String) -> DownloadBadge? {
        badges[path]
    }

    func addOne(_ f: CarFile, target: DownloadTarget) {
        _ = add([f], target: target)
    }

    // MARK: - 控制

    func pause(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .waiting else { return }
        item.state = .paused
        badges[item.id] = DownloadBadge(state: .paused, progress: item.progress)
        if let t = item.task, t.state == .running {
            t.cancel(byProducingResumeData: { [weak item] data in
                DispatchQueue.main.async { item?.resumeData = data }
            })
        }
        item.task = nil
    }

    func resume(_ item: DownloadItem) {
        guard item.state == .paused || item.state == .failed else { return }
        if let rd = item.resumeData {
            let task = DownloadEngine.shared.session.downloadTask(withResumeData: rd)
            DownloadEngine.shared.register(task: task, path: item.id)
            item.task = task
            item.resumeData = nil
            item.state = .downloading
            item.message = nil
            badges[item.id] = DownloadBadge(state: .downloading, progress: item.progress)
            task.resume()
        } else {
            item.received = 0
            item.total = 0
            item.state = .waiting
            badges[item.id] = DownloadBadge(state: .waiting, progress: 0)
            pump()
        }
    }

    func cancel(_ item: DownloadItem) {
        item.task?.cancel()
        item.task = nil
        item.resumeData = nil
        items.removeAll { $0.id == item.id }
        badges[item.id] = nil
    }

    func retry(_ item: DownloadItem) {
        item.resumeData = nil
        item.received = 0
        item.total = 0
        item.message = nil
        item.state = .waiting
        badges[item.id] = DownloadBadge(state: .waiting, progress: 0)
        pump()
    }

    func pauseAll() {
        for it in items where it.state == .downloading || it.state == .waiting {
            pause(it)
        }
    }

    func cancelAll() {
        for it in items { it.task?.cancel() }
        items.removeAll()
        badges.removeAll()
    }

    func clearFinished() {
        items.removeAll { $0.state == .done }
    }

    // MARK: - 调度

    private func pump() {
        // 仅 WiFi 下载：不在 WiFi 时保持排队
        if settings?.wifiOnlyDownload == true, settings?.isWiFi == false { return }
        // 播放中：不启动新任务（正在跑的在 beginPlayback 里已挂起）
        if playbackDepth > 0, settings?.pauseDownloadDuringPlayback != false { return }
        let cap = effectiveMaxConcurrent
        let running = runningCount
        guard running < cap else { return }
        let slots = cap - running
        var started = 0
        for item in items where item.state == .waiting {
            start(item)
            started += 1
            if started >= slots { break }
        }
    }

    private func start(_ item: DownloadItem) {
        guard let api = connection?.client else {
            item.state = .failed
            item.message = "未连接车机"
            return
        }
        // 一律下载原始 .ts：
        // 部分车机/电视的 32 位 stagefright MPEG4Writer 存在原生缺陷，服务端转封装会
        // SIGABRT（FORTIFY write count -1），且崩溃后主进程要干等到超时，客户端表现为
        // 「0% 卡住 / 连接超时」。因此转封装改在手机本地做（LocalRemux，iOS 系统 muxer）。
        let url = api.downloadURL(path: item.file.path)
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let task = DownloadEngine.shared.session.downloadTask(with: req)
        DownloadEngine.shared.register(task: task, path: item.id)
        item.task = task
        item.state = .downloading
        item.message = nil
        task.resume()
    }

    // MARK: - 引擎回调（主线程）

    nonisolated func onProgress(path: String, received: Int64, total: Int64) {
        Task { @MainActor in self._onProgress(path: path, received: received, total: total) }
    }

    nonisolated func onFinished(path: String, tempURL: URL, response: HTTPURLResponse?) {
        Task { @MainActor in await self._onFinished(path: path, tempURL: tempURL, response: response) }
    }

    nonisolated func onError(path: String, error: Error) {
        Task { @MainActor in self._onError(path: path, error: error) }
    }

    private func _onProgress(path: String, received: Int64, total: Int64) {
        guard let item = items.first(where: { $0.id == path }), item.state == .downloading else { return }
        item.received = received
        if total > 0 { item.total = total }
        // 封面角标：只在百分比整数变化时刷新，避免高频重绘整个列表
        let denom = total > 0 ? Double(total) : Double(max(item.file.size, 1))
        let pct = min(100, Int(Double(received) / denom * 100))
        if Int((badges[path]?.progress ?? -1) * 100) != pct {
            badges[path] = DownloadBadge(state: .downloading, progress: Double(pct) / 100.0)
        }
    }

    private func _onFinished(path: String, tempURL: URL, response: HTTPURLResponse?) async {
        guard let item = items.first(where: { $0.id == path }) else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        item.task = nil

        // 「车机文件」浏览器下载的任意文件：原样存「文件」App，
        // 不做转封装、不进相册、不进本地库（它可能是音乐/文档/安装包）
        if item.target.isArbitraryFile {
            saveArbitraryFile(item, tempURL: tempURL)
            pump()
            return
        }

        var sourceURL = tempURL
        var remuxedURL: URL?
        var finalName = item.file.name
        var duration: Double?

        // 车机端若已转好 mp4 则直接用；否则在手机本地转封装（不转码，H.264+AAC 直通）
        let serverFormat = response?.value(forHTTPHeaderField: "X-CarLink-Format")
        if item.file.isVideo && serverFormat != "mp4" {
            item.message = "转存 MP4…"
            if let r = await LocalRemux.toMp4(src: tempURL) {
                sourceURL = r.url
                remuxedURL = r.url
                duration = r.duration
                let base = (finalName as NSString).deletingPathExtension
                finalName = base + "." + r.url.pathExtension
            }
        }
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            if let r = remuxedURL { try? FileManager.default.removeItem(at: r) }
        }

        let ext = sourceURL.pathExtension.lowercased()
        let isMp4 = (ext == "mp4" || ext == "mov")

        let saveToPhotos = UserDefaults.standard.object(forKey: "saveToPhotos") as? Bool ?? true
        let isImage = PhotoSaver.isImageFile(sourceURL)
        // 系统相册只接受图片和「真的有视频轨」的 mp4/mov：
        // 转封装可能只成功写出音轨，这类文件入相册后就是黑屏 + 静音图标，
        // 因此存相册前先真读一遍轨道，不合格就落到「文件」App（内置 VLC 仍可播放）。
        var playableVideo = false
        if !isImage && isMp4 {
            playableVideo = await LocalRemux.isPlayableVideoFile(sourceURL)
        }
        let wantPhotos = saveToPhotos && (isImage || playableVideo)

        var kind: SavedKind = .fileTS
        var localRef: String?
        var photosError: String?

        if wantPhotos {
            item.message = "保存到相册…"
            do {
                let assetId = try await PhotoSaver.saveToAlbum(fileAt: sourceURL)
                kind = .photoAlbum
                localRef = assetId
            } catch {
                // 相册失败 → 回退存「文件」App
                photosError = error.localizedDescription
            }
        }

        if localRef == nil {
            do {
                let dir = LibraryStore.tsDirectory
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var dest = dir.appending(path: finalName)
                var i = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    let base = (finalName as NSString).deletingPathExtension
                    let e = (finalName as NSString).pathExtension
                    dest = dir.appending(path: "\(base)-\(i).\(e)")
                    i += 1
                }
                try FileManager.default.moveItem(at: sourceURL, to: dest)
                // 源文件已移走，defer 里不要再删它
                if sourceURL == remuxedURL { remuxedURL = nil }
                kind = .fileTS
                localRef = dest.lastPathComponent
            } catch {
                item.state = .failed
                item.message = "保存失败：\(error.localizedDescription)"
                badges[path] = nil
                return
            }
        }

        var record = LocalRecord(
            sourcePath: item.file.path,
            sourceSize: item.file.size,
            name: finalName,
            modified: item.file.modified,
            category: item.target.category,
            camera: item.file.cameraEnum,
            kind: kind,
            localRef: localRef!,
            downloadedAt: Date()
        )
        record.duration = duration

        // 封面：下载完成后抓取车机端缩略图缓存到本地（本地文件页显示封面）
        if item.file.isVideo, let thumbPath = item.file.thumb, let api = connection?.client {
            if let data = try? await api.fetchRaw(path: thumbPath), !data.isEmpty,
               data.count < 4 * 1024 * 1024 {
                let safeName = record.id
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "#", with: "-") + ".jpg"
                record.thumbPath = LocalThumbStore.save(data, name: safeName)
            }
        }

        library?.add(record)
        if let d = duration { DurationCache.set(d, for: item.file.path) }
        item.state = .done
        item.savedAs = kind == .photoAlbum ? "已存相册" : "已存文件 App"
        badges[path] = nil
        if let e = photosError {
            item.message = "相册保存失败（\(e)），已存「文件」App"
        } else if kind == .fileTS && item.file.isVideo && !playableVideo {
            item.message = "该视频转封装后仍无法进相册，已存「文件」App（本地文件页可用内置播放器观看）"
        } else {
            item.message = nil
        }
        pump()
    }

    /// 任意文件落盘：Documents/CarLink/车机文件/<原名>（重名自动加序号）
    private func saveArbitraryFile(_ item: DownloadItem, tempURL: URL) {
        let name = item.file.name.isEmpty ? "file" : item.file.name
        do {
            let dir = LibraryStore.carFilesDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var dest = dir.appending(path: name)
            var i = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appending(path: ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)")
                i += 1
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            item.state = .done
            item.message = nil
            item.savedAs = "已存「文件」App › CarLink › 车机文件"
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            item.state = .failed
            item.message = "保存失败：\(error.localizedDescription)"
        }
        badges[item.id] = nil
    }

    private func _onError(path: String, error: Error) {
        guard let item = items.first(where: { $0.id == path }) else { return }
        item.task = nil
        if item.state == .paused { return }   // 主动暂停产生的事件，忽略
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        item.state = .failed
        item.message = ConnectionStore.describe(error)
        badges[path] = nil
        pump()
    }
}
