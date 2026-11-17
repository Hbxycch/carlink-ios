import Foundation
import Photos
import PhotosUI
import UIKit

// MARK: - 本地库记录（防重复下载的匹配依据：源路径 + 源大小）

enum SavedKind: String, Codable {
    case photoAlbum   // 存在系统相册「CarLink 车机互传」相簿（图片 / mp4）
    case fileTS       // 转存失败的 .ts 回退文件，存「文件」App › CarLink
}

struct LocalRecord: Codable, Identifiable, Equatable {
    let sourcePath: String
    let sourceSize: Int64
    let name: String
    let modified: Double
    let category: MediaCategory
    let camera: Camera
    let kind: SavedKind
    let localRef: String          // PHAsset localIdentifier 或相对文件名
    let downloadedAt: Date
    var duration: Double?
    /// 本地封面缓存文件名（Documents/CarLink/Thumbs/ 下）
    var thumbPath: String?

    var id: String { "\(sourcePath)#\(sourceSize)" }
    var date: Date { Date(timeIntervalSince1970: modified / 1000.0) }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var records: [LocalRecord] = []

    private static var storeURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "CarLink/Library/library.json")
    }

    /// 回退 .ts 文件目录（「文件」App › CarLink › CarLink）
    nonisolated static var tsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "CarLink")
    }

    /// 「车机文件」浏览器下载的任意文件目录（「文件」App › CarLink › 车机文件）
    nonisolated static var carFilesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "CarLink/车机文件")
    }

    init() {
        load()
    }

    // MARK: - 匹配

    func isDownloaded(_ file: CarFile) -> Bool {
        records.contains { $0.sourcePath == file.path && $0.sourceSize == file.size }
    }

    func record(for file: CarFile) -> LocalRecord? {
        records.first { $0.sourcePath == file.path && $0.sourceSize == file.size }
    }

    func downloadedCount(in files: [CarFile]) -> Int {
        files.filter { isDownloaded($0) }.count
    }

    // MARK: - 查询

    func records(category: MediaCategory) -> [LocalRecord] {
        records
            .filter { $0.category == category }
            .sorted { $0.date > $1.date }
    }

    func screenshotRecords() -> [LocalRecord] {
        // 截图的 category 也按 snapshot 记录？截图走 screenshot 下载，category 用 snapshot 存疑——
        // 约定：截图下载记录 category = .snapshot（本地文件页与抓拍同栏展示）
        records.filter { $0.category == .snapshot }.sorted { $0.date > $1.date }
    }

    /// 某分类下有记录的日期集合（日历蓝点）
    func days(category: MediaCategory) -> Set<String> {
        Set(records(category: category).map { Fmt.day($0.date) })
    }

    // MARK: - 增删

    func add(_ r: LocalRecord) {
        records.removeAll { $0.id == r.id }
        records.append(r)
        save()
    }

    func remove(_ r: LocalRecord) {
        // 删除本地副本（相册资产或文件），车机原片不受影响
        switch r.kind {
        case .photoAlbum:
            PhotoSaver.deleteAsset(localId: r.localRef)
        case .fileTS:
            try? FileManager.default.removeItem(at: Self.tsDirectory.appending(path: r.localRef))
        }
        LocalThumbStore.delete(record: r)
        records.removeAll { $0.id == r.id }
        save()
    }

    func setDuration(_ d: Double, for r: LocalRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) {
            records[i].duration = d
            save()
        }
    }

    var totalBytes: Int64 {
        records.reduce(0) { $0 + $1.sourceSize }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let list = try? JSONDecoder().decode([LocalRecord].self, from: data) else { return }
        records = list
    }

    private func save() {
        let dir = Self.storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
