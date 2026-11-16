import Foundation
import Photos
import PhotosUI

// MARK: - 上传条目

enum UploadState: String {
    case preparing
    case running
    case done
    case failed
}

enum UploadSource {
    case asset(String)     // PHAsset localIdentifier
    case fileURL(URL)      // 文件 App 选中的文件
}

final class UploadItem: Identifiable, ObservableObject {
    let id = UUID()
    let source: UploadSource
    let displayName: String

    @Published var state: UploadState = .preparing
    @Published var size: Int64 = 0
    @Published var sent: Int64 = 0
    @Published var message: String?
    @Published var savedPath: String?

    init(source: UploadSource, displayName: String) {
        self.source = source
        self.displayName = displayName
    }

    var progress: Double {
        guard size > 0 else { return 0 }
        return min(1, Double(sent) / Double(size))
    }
}

// MARK: - 上传管理器（车机端三段式分片上传）

@MainActor
final class UploadManager: ObservableObject {
    @Published private(set) var items: [UploadItem] = []

    private let chunkSize = 2 * 1024 * 1024

    weak var connection: ConnectionStore?

    var activeCount: Int {
        items.filter { $0.state == .preparing || $0.state == .running }.count
    }

    // MARK: - 入口

    func uploadAsset(_ assetId: String, name: String) {
        let item = UploadItem(source: .asset(assetId), displayName: name)
        items.insert(item, at: 0)
        Task { await run(item) }
    }

    func uploadFile(url: URL) {
        let needScope = url.startAccessingSecurityScopedResource()
        let item = UploadItem(source: .fileURL(url), displayName: url.lastPathComponent)
        items.insert(item, at: 0)
        Task { [weak self] in
            await self?.run(item)
            if needScope { url.stopAccessingSecurityScopedResource() }
        }
    }

    func remove(_ item: UploadItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { $0.state == .done || $0.state == .failed }
    }

    // MARK: - 执行

    private func run(_ item: UploadItem) async {
        do {
            guard let api = connection?.client else { throw APIError("未连接车机") }

            // 1. 取文件（相册资产导出到临时目录，或直接用文件 URL）
            var url: URL
            var name: String
            switch item.source {
            case .asset(let id):
                item.state = .preparing
                let (u, n) = try await Self.exportAsset(id)
                url = u; name = n
            case .fileURL(let u):
                url = u; name = u.lastPathComponent
            }

            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            guard size > 0 else { throw APIError("文件为空或无法读取") }
            item.size = size
            item.state = .running

            // 2. init
            let initResp = try await api.uploadInit(name: name, size: size)
            guard initResp.ok, let uploadId = initResp.uploadId else {
                throw APIError(initResp.error ?? "上传初始化失败")
            }

            // 3. 分片 PUT
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var offset = initResp.offset ?? 0
            if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
            while offset < size {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                let newOffset = try await api.uploadChunk(id: uploadId, offset: offset, body: chunk)
                offset = newOffset
                item.sent = offset
            }

            // 4. complete
            let done = try await api.uploadComplete(id: uploadId)
            guard done.ok else { throw APIError(done.error ?? "完成上传失败") }
            item.state = .done
            item.savedPath = done.path

            // 相册导出的临时文件清理
            if case .asset = item.source { try? FileManager.default.removeItem(at: url) }
        } catch {
            item.state = .failed
            item.message = ConnectionStore.describe(error)
        }
    }

    // MARK: - 相册资源导出

    private static func exportAsset(_ id: String) async throws -> (URL, String) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw APIError("找不到所选照片/视频")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [.fullSizeVideo, .pairedVideo, .video, .fullSizePhoto, .photo]
        let res = preferred.compactMap { t in resources.first(where: { $0.type == t }) }.first ?? resources.first
        guard let r = res else { throw APIError("无法读取所选资源") }

        let name = r.originalFilename ?? "\(UUID().uuidString).bin"
        let ext = (name as NSString).pathExtension
        let safeExt = ext.isEmpty ? "bin" : ext
        let url = FileManager.default.temporaryDirectory
            .appending(path: "upload-\(UUID().uuidString).\(safeExt)")

        return try await withCheckedThrowingContinuation { cont in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: r, toFile: url, options: opts) { err in
                if let e = err {
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(throwing: e)
                } else {
                    cont.resume(returning: (url, name))
                }
            }
        }
    }
}
