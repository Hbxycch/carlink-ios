import Foundation
import AVFoundation
import Photos
import UIKit

/// 系统相册「CarLink 车机互传」相簿操作
enum PhotoSaver {
    static let albumName = "CarLink 车机互传"

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "bmp", "gif"]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - 授权

    static func requestAddAuthorization() -> Bool {
        let st = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if st == .authorized || st == .limited { return true }
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            ok = (s == .authorized || s == .limited)
            sem.signal()
        }
        sem.wait()
        return ok
    }

    // MARK: - 相簿

    private static func fetchAlbum() -> PHAssetCollection? {
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: PHAssetCollection?
        fetch.enumerateObjects { c, _, _ in
            if c.localizedTitle == albumName { found = c }
        }
        return found
    }

    @discardableResult
    private static func ensureAlbum() throws -> PHAssetCollection {
        if let a = fetchAlbum() { return a }
        var placeholderId: String?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            placeholderId = req.placeholderForCreatedAssetCollection?.localIdentifier
        }
        guard let pid = placeholderId,
              let created = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [pid], options: nil).firstObject else {
            throw APIError("创建相簿失败")
        }
        return created
    }

    // MARK: - 保存

    /// 保存文件（图片或视频）到相簿，返回 PHAsset localIdentifier
    @discardableResult
    static func saveToAlbum(fileAt url: URL) throws -> String {
        guard requestAddAuthorization() else { throw APIError("没有相册权限") }
        let album = try ensureAlbum()
        let isImage = isImageFile(url)
        var assetId: String?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let create = PHAssetCreationRequest.forAsset()
            if isImage {
                create.addResource(with: .photo, fileURL: url, options: nil)
            } else {
                create.addResource(with: .video, fileURL: url, options: nil)
            }
            assetId = create.placeholderForCreatedAsset?.localIdentifier
            if let placeholder = create.placeholderForCreatedAsset {
                let albumReq = PHAssetCollectionChangeRequest(for: album)
                albumReq?.addAssets([placeholder] as NSArray)
            }
        }
        guard let id = assetId else { throw APIError("保存到相册失败") }
        return id
    }

    // MARK: - 读取（本地回看）

    static func fetchAsset(localId: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject
    }

    static func loadAssetImage(localId: String, size: CGSize = UIScreen.main.bounds.size, completion: @escaping (UIImage?) -> Void) {
        guard let asset = fetchAsset(localId: localId) else { completion(nil); return }
        let opts = PHImageRequestOptions()
        opts.isSynchronous = false
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                              options: opts) { img, _ in completion(img) }
    }

    static func loadAssetVideoURL(localId: String, completion: @escaping (URL?) -> Void) {
        guard let asset = fetchAsset(localId: localId) else { completion(nil); return }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
            if let urlAsset = avAsset as? AVURLAsset {
                completion(urlAsset.url)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - 删除

    static func deleteAsset(localId: String) {
        guard let asset = fetchAsset(localId: localId) else { return }
        try? PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }
}
