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
        try Self.checkHTTP(resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func checkHTTP(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
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

    /// 截图列表
    func screenshots() async throws -> [CarFile] {
        try await files(type: "screenshot")
    }

    /// 记录仪分类列表
    func dashcam(category: MediaCategory) async throws -> [CarFile] {
        try await files(type: "dashcam", category: category.apiValue)
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

    // MARK: - 分片上传

    func uploadInit(name: String, size: Int64) async throws -> UploadInitResponse {
        var req = URLRequest(url: url("/api/upload/init"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "size": size])
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        try Self.checkHTTP(resp)
        return try JSONDecoder().decode(UploadInitResponse.self, from: data)
    }

    func uploadChunk(id: String, offset: Int64, body: Data) async throws -> Int64 {
        var req = URLRequest(url: url("/api/upload", query: ["id": id, "offset": String(offset)]))
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, resp) = try await session.data(for: req)
        try Self.checkHTTP(resp)
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
        try Self.checkHTTP(resp)
        let r = try? JSONDecoder().decode(UploadCompleteResponse.self, from: data)
        if let r = r { return r }
        // 服务端返回非 JSON 时兜底
        return UploadCompleteResponse(ok: (resp as? HTTPURLResponse)?.statusCode == 200,
                                      saved: nil, path: nil, name: nil, error: nil)
    }
}
