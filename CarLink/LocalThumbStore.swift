import Foundation
import AVFoundation
import UIKit

/// 本地文件封面：优先用下载时缓存的车机缩略图；图片直接读；mp4/mov 本地生成首帧。
/// （.ts 无法被 AVFoundation 可靠解码，不生成首帧，靠车机缩略图兜底）
enum LocalThumbStore {

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 回退文件目录（Documents/CarLink，与 LibraryStore.tsDirectory 一致）
    private static var filesDirectory: URL {
        documentsDirectory.appending(path: "CarLink")
    }

    /// 封面缓存目录（Documents/CarLink/Thumbs）
    static var directory: URL {
        filesDirectory.appending(path: "Thumbs")
    }

    /// 保存封面数据，返回相对文件名（存入 LocalRecord.thumbPath）
    @discardableResult
    static func save(_ data: Data, name: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name)
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// 读取封面（缓存缩略图 → 图片直读 → mp4/mov 首帧）
    static func load(record: LocalRecord) async -> UIImage? {
        // 1) 下载时缓存的车机缩略图
        if let name = record.thumbPath {
            let url = directory.appending(path: name)
            if let img = UIImage(contentsOfFile: url.path) { return img }
        }
        let src = filesDirectory.appending(path: record.localRef)
        let ext = (record.name as NSString).pathExtension.lowercased()
        // 2) 图片文件直接读
        if ["png", "jpg", "jpeg", "webp", "heic", "bmp", "gif"].contains(ext) {
            return UIImage(contentsOfFile: src.path)
        }
        // 3) mp4 / mov：本地生成首帧
        if ["mp4", "mov", "m4v"].contains(ext), FileManager.default.fileExists(atPath: src.path) {
            return await firstFrame(of: src)
        }
        return nil
    }

    /// 删除记录时清理封面缓存
    static func delete(record: LocalRecord) {
        if let name = record.thumbPath {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private static func firstFrame(of url: URL) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let t = CMTime(seconds: 1.0, preferredTimescale: 600)
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
    }
}
