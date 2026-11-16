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

    var category: MediaCategory {
        switch self {
        case .screenshot: return .snapshot   // 截图与抓拍在本地文件页同栏展示
        case .dashcam(let c): return c
        }
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

// MARK: - 下载管理器

@MainActor
final class DownloadManager: ObservableObject, DownloadEngineDelegate {
    @Published private(set) var items: [DownloadItem] = []

    private let maxConcurrent = 2

    weak var connection: ConnectionStore?
    weak var library: LibraryStore?
    weak var settings: SettingsStore?
    private var netCancellable: AnyCancellable?

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
            if let lib = library, lib.isDownloaded(f) { continue }
            items.insert(DownloadItem(file: f, target: target), at: 0)
            added += 1
        }
        if added > 0 { pump() }
        return added
    }

    func addOne(_ f: CarFile, target: DownloadTarget) {
        _ = add([f], target: target)
    }

    // MARK: - 控制

    func pause(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .waiting else { return }
        item.state = .paused
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
            task.resume()
        } else {
            item.received = 0
            item.total = 0
            item.state = .waiting
            pump()
        }
    }

    func cancel(_ item: DownloadItem) {
        item.task?.cancel()
        item.task = nil
        item.resumeData = nil
        items.removeAll { $0.id == item.id }
    }

    func retry(_ item: DownloadItem) {
        item.resumeData = nil
        item.received = 0
        item.total = 0
        item.message = nil
        item.state = .waiting
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
    }

    func clearFinished() {
        items.removeAll { $0.state == .done }
    }

    // MARK: - 调度

    private func pump() {
        // 仅 WiFi 下载：不在 WiFi 时保持排队
        if settings?.wifiOnlyDownload == true, settings?.isWiFi == false { return }
        let running = runningCount
        guard running < maxConcurrent else { return }
        let slots = maxConcurrent - running
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
        // 视频请求 format=mp4（车机端转封装），截图直接下载。
        // 版本守卫：车机端 1.1.10 之前执行 mp4 转封装会触发 32 位 stagefright
        // 原生崩溃（整个服务进程被杀），旧版本只下载原始 TS。
        let mp4Capable = Self.serverVersionAtLeastMp4(connection?.carInfo?.version)
        let wantMp4 = item.file.isVideo && mp4Capable
        let url = api.downloadURL(path: item.file.path, format: wantMp4 ? "mp4" : nil)
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let task = DownloadEngine.shared.session.downloadTask(with: req)
        DownloadEngine.shared.register(task: task, path: item.id)
        item.task = task
        item.state = .downloading
        item.message = nil
        task.resume()
    }

    /// 服务端版本 >= 1.1.10（versionCode 12）才支持安全的 mp4 转封装
    private static func serverVersionAtLeastMp4(_ version: String?) -> Bool {
        let minimum = [1, 1, 10]
        guard let v = version else { return false }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        for (a, b) in zip(parts, minimum) {
            if a > b { return true }
            if a < b { return false }
        }
        return true
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
    }

    private func _onFinished(path: String, tempURL: URL, response: HTTPURLResponse?) async {
        guard let item = items.first(where: { $0.id == path }) else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        item.task = nil

        let remoteFormat = response?.value(forHTTPHeaderField: "X-CarLink-Format") // mp4 | fallback-ts | nil
        let isMp4 = remoteFormat == "mp4"

        // 保存目标文件名：转存成功时扩展名换为 .mp4
        var finalName = item.file.name
        if isMp4, item.file.isVideo {
            let base = (finalName as NSString).deletingPathExtension
            finalName = base + ".mp4"
        }

        let saveToPhotos = UserDefaults.standard.object(forKey: "saveToPhotos") as? Bool ?? true
        // 只有服务端真正转成 mp4 才能存进相册（系统相册不支持 TS）；
        // TS / 回退文件一律存「文件」App
        let wantPhotos = isMp4 && saveToPhotos

        var kind: SavedKind = .fileTS
        var localRef: String?

        if wantPhotos {
            item.message = "保存到相册…"
            do {
                // 异步保存：授权弹窗与相册写库都不阻塞主线程
                let assetId = try await PhotoSaver.saveToAlbum(fileAt: tempURL)
                kind = .photoAlbum
                localRef = assetId
            } catch {
                // 相册失败 → 回退存「文件」App
                item.message = "相册保存失败（\(error.localizedDescription)），已改存「文件」App"
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
                    let ext = (finalName as NSString).pathExtension
                    dest = dir.appending(path: "\(base)-\(i).\(ext)")
                    i += 1
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                kind = .fileTS
                localRef = dest.lastPathComponent
            } catch {
                item.state = .failed
                item.message = "保存失败：\(error.localizedDescription)"
                return
            }
        }

        let record = LocalRecord(
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
        library?.add(record)
        item.state = .done
        item.savedAs = kind == .photoAlbum ? "已存相册" : "已存文件 App"
        pump()
    }

    private func _onError(path: String, error: Error) {
        guard let item = items.first(where: { $0.id == path }) else { return }
        item.task = nil
        if item.state == .paused { return }   // 主动暂停产生的事件，忽略
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        item.state = .failed
        item.message = ConnectionStore.describe(error)
        pump()
    }
}
