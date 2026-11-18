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

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 3600
        session = URLSession(configuration: cfg)
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
}
