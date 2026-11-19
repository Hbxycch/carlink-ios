import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// 车机端 HTTP API 客户端（对应 com.zood.carlink 的接口）
final class APIClient {
    let host: String
    let port: Int
    private let session: URLSession
    /// 心跳专用会话：4s 超时，掉线判定不被大文件传输的 15s/120s 超时拖慢
    private let probeSession: URLSession

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 3600
        session = URLSession(configuration: cfg)

        let pcfg = URLSessionConfiguration.ephemeral
        pcfg.timeoutIntervalForRequest = 4
        pcfg.timeoutIntervalForResource = 6
        pcfg.waitsForConnectivity = false
        pcfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        probeSession = URLSession(configuration: pcfg)
    }

    var baseURLText: String { "http://\(host):\(port)" }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(string: baseURLText + path)!
        if !query.isEmpty {
            comps.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    // MARK: - 基础请求

    private func getJSON<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, resp) = try await session.data(from: url(path, query: query))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let raw = Self.preview(data)
            ConnLogStore.shared.log("ERR", "HTTP \(http.statusCode) \(path) 响应: \(raw)")
            throw APIError("HTTP \(http.statusCode)：\(raw)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let raw = Self.preview(data)
            ConnLogStore.shared.log("ERR", "解析 \(path) 失败: \(ConnLogStore.describe(error)) 原始响应: \(raw)")
            throw APIError("解析 \(path) 响应失败：\(raw)")
        }
    }

    /// 响应体预览（前 400 字符，用于诊断日志）
    static func preview(_ data: Data) -> String {
        if data.isEmpty { return "<空响应 0 字节>" }
        let s = String(data: data.prefix(400), encoding: .utf8) ?? "<\(data.count) 字节二进制>"
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    /// 原始 GET（诊断用：拿状态码 + 响应体前 400 字符，不做 JSON 解析）
    func raw(path: String) async throws -> (Int, String) {
        let (data, resp) = try await session.data(from: url(path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (code, Self.preview(data))
    }

    /// 校验状态码。4xx 时服务端 body 里带中文原因（如"无法创建接收目录"），
    /// 直接透传比只显示 "HTTP 400" 有用得多。
    static func checkHTTP(_ resp: URLResponse, body: Data? = nil) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let body = body,
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let msg = obj["error"] as? String, !msg.isEmpty {
                throw APIError(msg)
            }
            throw APIError("HTTP \(http.statusCode)")
        }
    }

    // MARK: - 信息 / 状态

    func info() async throws -> CarInfo {
        try await getJSON("/api/info")
    }

    func status() async throws -> StatusResponse {
        try await getJSON("/api/status")
    }

    /// 心跳探测：拿实时状态 + 往返耗时（ms）。用 4s 短超时，掉线能秒级发现。
    func ping() async throws -> (StatusResponse, Int) {
        let t0 = Date()
        let (data, resp) = try await probeSession.data(from: url("/api/status"))
        try Self.checkHTTP(resp, body: data)
        let s: StatusResponse
        do {
            s = try JSONDecoder().decode(StatusResponse.self, from: data)
        } catch {
            throw APIError("解析 /api/status 响应失败：\(Self.preview(data))")
        }
        return (s, max(1, Int(Date().timeIntervalSince(t0) * 1000)))
    }

    /// 存储卷（内部存储 / SD 卡 / USB 的总量与剩余）
    func volumes() async throws -> [VolumeInfo] {
        let r: VolumeListResponse = try await getJSON("/api/volumes")
        return r.volumes
    }

    // MARK: - 文件列表

    func files(type: String, camera: String? = nil, category: String? = nil) async throws -> [CarFile] {
        var q = ["type": type]
        if let c = camera, c != "all" { q["camera"] = c }
        if let cat = category { q["category"] = cat }
        let r: FileListResponse = try await getJSON("/api/files", query: q)
        return r.files
    }

    /// 分页拉取（SD 卡上万条录像时必须用这个，否则一次几 MB JSON 会把弱车机拖到超时）
    func filesPage(type: String, camera: String? = nil, category: String? = nil,
                   limit: Int = 60, offset: Int = 0, refresh: Bool = false) async throws -> FilePage {
        var q = ["type": type, "limit": "\(limit)", "offset": "\(offset)"]
        if let c = camera, c != "all" { q["camera"] = c }
        if let cat = category { q["category"] = cat }
        if refresh { q["refresh"] = "1" }
        let r: FileListResponse = try await getJSON("/api/files", query: q)
        return FilePage(files: r.files,
                        total: r.total ?? r.files.count,
                        hasMore: r.hasMore ?? false,
                        indexing: r.indexing ?? false,
                        scanned: r.scanned ?? 0)
    }

    /// 截图列表
    func screenshots() async throws -> [CarFile] {
        try await files(type: "screenshot")
    }
    /// 记录仪分类列表
    func dashcam(category: MediaCategory) async throws -> [CarFile] {
        try await files(type: "dashcam", category: category.apiValue)
    }

    /// 车机文件浏览（内部存储 / SD 卡 / U 盘）。path 传空 = 列出各存储卷
    func browse(path: String, limit: Int = 300, offset: Int = 0) async throws -> BrowseResponse {
        try await getJSON("/api/browse", query: ["path": path,
                                                "limit": "\(limit)",
                                                "offset": "\(offset)"])
    }

    // MARK: - 下载（流式播放 / 缩略图）

    func downloadURL(path: String, format: String? = nil) -> URL {
        var q = ["path": path]
        if let f = format { q["format"] = f }
        return url("/api/download", query: q)
    }

    /// 缩略图 URL（车机端 thumbnails 与视频同目录，允许下载）
    func thumbURL(_ file: CarFile) -> URL? {
        guard let t = file.thumb else { return nil }
        return downloadURL(path: t)
    }

    /// 下载原始文件数据（缩略图等小文件）
    func fetchRaw(path: String) async throws -> Data {
        let (data, resp) = try await session.data(from: downloadURL(path: path))
        try Self.checkHTTP(resp)
        return data
    }

    // MARK: - 车机状态（字段动态，用字典承载避免脆 Codable）

    func deviceInfoDict() async throws -> [String: Any] {
        try await getJSONDict("/api/device/info")
    }

    func deviceAppsDict() async throws -> [String: Any] {
        try await getJSONDict("/api/device/apps")
    }

    func devicePeripheralsDict() async throws -> [String: Any] {
        try await getJSONDict("/api/device/peripherals")
    }

    private func getJSONDict(_ path: String) async throws -> [String: Any] {
        let (data, resp) = try await session.data(from: url(path))
        try Self.checkHTTP(resp)
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError("响应格式错误")
        }
        return d
    }

    // MARK: - 分片上传

    func uploadInit(name: String, size: Int64, dir: String? = nil) async throws -> UploadInitResponse {
        var req = URLRequest(url: url("/api/upload/init"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "size": size]
        if let d = dir, !d.isEmpty { body["dir"] = d }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.checkHTTP(resp, body: data)
        return try JSONDecoder().decode(UploadInitResponse.self, from: data)
    }

    func uploadChunk(id: String, offset: Int64, body: Data) async throws -> Int64 {
        var req = URLRequest(url: url("/api/upload", query: ["id": id, "offset": String(offset)]))
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, resp) = try await session.data(for: req)
        try Self.checkHTTP(resp, body: data)
        let r = try JSONDecoder().decode(UploadChunkResponse.self, from: data)
        guard r.ok, let newOffset = r.offset else {
            throw APIError(r.error ?? "上传分片失败")
        }
        return newOffset
    }

    func uploadComplete(id: String) async throws -> UploadCompleteResponse {
        var req = URLRequest(url: url("/api/upload/\(id)/complete"))
        req.httpMethod = "POST"
        let (data, resp) = try await session.data(for: req)
        try Self.checkHTTP(resp, body: data)
        let r = try? JSONDecoder().decode(UploadCompleteResponse.self, from: data)
        if let r = r { return r }
        // 服务端返回非 JSON 时兜底
        return UploadCompleteResponse(ok: (resp as? HTTPURLResponse)?.statusCode == 200,
                                      saved: nil, path: nil, name: nil, error: nil)
    }

    // MARK: - 车机快照流（/api/camera/frame）

    /// 单帧 JPEG 地址（带时间戳绕过缓存）
    func cameraFrameURL(cam: String) -> URL {
        url("/api/camera/frame", query: ["cam": cam,
                                         "t": "\(Int(Date().timeIntervalSince1970 * 1000))"])
    }

    /// 拉一帧 JPEG。用 6s 短超时：车机首帧可能要准备管线，但不能拖住整个界面。
    func fetchCameraFrame(cam: String) async throws -> Data {
        var req = URLRequest(url: cameraFrameURL(cam: cam))
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String, !msg.isEmpty {
                throw APIError(msg)
            }
            throw APIError("HTTP \(http.statusCode)")
        }
        return data
    }

    func cameraStatus() async throws -> [CameraFrameStatus] {
        let r: CameraFramesResponse = try await getJSON("/api/camera/status")
        return r.frames
    }

    // MARK: - 摄像头推流

    func streamStatus() async throws -> StreamStatusResponse {
        try await getJSON("/api/stream/status")
    }

    // MARK: - 车机屏幕截图（/api/screen/capture）

    /// 一次截图结果。source: adb = 现场截屏；cache = 车机 ADB 不可用时回退最近一张
    struct ScreenCapture {
        let data: Data
        let source: String
        let ms: Int
        let width: Int
        let height: Int
        let note: String?

        var isLive: Bool { source == "adb" }
    }

    /// 让车机现场截一张屏（PNG）。12s 超时：车机侧实测 0.4~0.6s，留足余量但不干等。
    func captureScreen() async throws -> ScreenCapture {
        var req = URLRequest(url: url("/api/screen/capture",
                                      query: ["t": "\(Int(Date().timeIntervalSince1970 * 1000))"]))
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError("无效响应") }
        guard (200..<300).contains(http.statusCode) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String, !msg.isEmpty {
                throw APIError(msg)
            }
            throw APIError(http.statusCode == 404 ? "车机端不支持截图，请升级到 1.1.29" : "HTTP \(http.statusCode)")
        }
        func headerInt(_ name: String) -> Int {
            Int(http.value(forHTTPHeaderField: name) ?? "") ?? 0
        }
        let noteRaw = http.value(forHTTPHeaderField: "X-CarLink-Capture-Note")
        return ScreenCapture(data: data,
                             source: http.value(forHTTPHeaderField: "X-CarLink-Capture") ?? "adb",
                             ms: headerInt("X-CarLink-Capture-Ms"),
                             width: headerInt("X-CarLink-Width"),
                             height: headerInt("X-CarLink-Height"),
                             note: noteRaw?.removingPercentEncoding)
    }

    /// 车机 CarCap 目录里最近的截图（名称 / 大小 / 时间 / 路径）
    func recentScreenshots(limit: Int = 20) async throws -> ScreenShotsResponse {
        try await getJSON("/api/screen/recent", query: ["limit": "\(limit)"])
    }

    /// 远程重启车机整机（车机端 v1.1.30+）。
    /// 车机端会先回 200 再延迟 1.5s 执行 reboot，避免连接被掐断让客户端误判失败。
    func rebootCar() async throws {
        var req = URLRequest(url: url("/api/device/reboot"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            throw APIError("车机端不支持远程重启，请先升级到 v1.1.30")
        }
        try Self.checkHTTP(resp, body: data)
    }

    /// 远程启动 / 关闭车机上的应用（车机端 v1.1.31+）。
    /// 车机端走本地 root adbd 回环执行 monkey / am force-stop，返回 ok + message + output。
    func controlApp(packageName: String, action: String) async throws -> [String: Any] {
        var req = URLRequest(url: url("/api/device/app/control"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject:
                                                    ["package": packageName, "action": action])
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            throw APIError("车机端不支持应用启动/关闭，请先升级到 v1.1.31")
        }
        try Self.checkHTTP(resp, body: data)
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError("响应格式错误")
        }
        return d
    }

    /// 远程修改车机配置（键名与车机端 /api/config 一致，
    /// 如 stream_front_on / stream_front_url；改完车机会自动重载推流）
    func updateConfig(_ body: [String: Any]) async throws {
        var req = URLRequest(url: url("/api/config"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.checkHTTP(resp, body: data)
    }
}
