import SwiftUI
import AVFoundation
import AVKit
import Photos
import MobileVLCKit

// MARK: - 本地文件播放（下载回来的视频）
//
// 设计要点：
// 1. 相册里的视频用 PHImageManager.requestAVAsset 取资产——它常常返回 AVComposition
//    （用户剪辑过 / iCloud 视频 / 部分格式），旧代码强转 AVURLAsset 会拿到 nil，
//    于是 AVPlayer 为 nil，界面就是「黑屏 + 静音喇叭」图标。这里直接拿 AVAsset 建
//    AVPlayerItem，不再依赖 URL。
// 2. 「文件」App 里的 .ts 回退文件 AVFoundation 不保证能解（MPEG-TS 容器），
//    一律交给内置的 VLC 内核播放，兼容性最好。

// MARK: - VLC 文件播放器

struct VLCFileView: UIViewRepresentable {
    let url: URL
    var autoplay: Bool = true

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        let player = VLCMediaPlayer()
        player.drawable = v
        player.media = VLCMedia(url: url)
        if autoplay { player.play() }
        context.coordinator.player = player
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.player?.stop()
        coordinator.player?.drawable = nil
        coordinator.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: VLCMediaPlayer?
    }
}

// MARK: - 相册视频资产解析

enum LocalVideoResolver {

    /// 统一播放器要的是「一个能直接交给 VLC 的 URL」：
    /// - 「文件」App 里的回退副本 → 沙盒内的真实文件；
    /// - 相册资产 → 先试 AVURLAsset 的原始 URL（多数情况下可读），
    ///   不可读（iCloud / 剪辑过的 AVComposition）再导出到缓存目录，按资产 id 复用。
    static func playableURL(record: LocalRecord) async -> URL? {
        switch record.kind {
        case .fileTS:
            let u = LibraryStore.tsDirectory.appending(path: record.localRef)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        case .photoAlbum:
            if let av = await asset(localId: record.localRef),
               let u = (av as? AVURLAsset)?.url,
               FileManager.default.isReadableFile(atPath: u.path) {
                return u
            }
            return await exportResourceToCache(localId: record.localRef, name: record.name)
        }
    }

    /// 把相册资产的原文件复制到缓存目录（VLC 只认文件路径），同一资产复用已导出的副本
    static func exportResourceToCache(localId: String, name: String) async -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PlayCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension.isEmpty ? "mp4" : (name as NSString).pathExtension
        let safeId = localId.replacingOccurrences(of: "/", with: "_")
        let out = dir.appending(path: "\(safeId).\(ext)")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: out.path),
           ((attrs[.size] as? Int64) ?? 0) > 0 {
            return out
        }
        guard let a = PhotoSaver.fetchAsset(localId: localId),
              let res = PHAssetResource.assetResources(for: a).first(where: {
                  $0.type == .fullSizeVideo || $0.type == .video
              }) else { return nil }
        try? FileManager.default.removeItem(at: out)
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: res, toFile: out, options: opts) { err in
                if err == nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: out.path),
                   ((attrs[.size] as? Int64) ?? 0) > 0 {
                    cont.resume(returning: out)
                } else {
                    try? FileManager.default.removeItem(at: out)
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 取相册视频的 AVAsset（兼容 AVComposition）
    static func asset(localId: String) async -> AVAsset? {
        await withCheckedContinuation { (cont: CheckedContinuation<AVAsset?, Never>) in
            guard let a = PhotoSaver.fetchAsset(localId: localId) else {
                cont.resume(returning: nil)
                return
            }
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: a, options: opts) { av, _, _ in
                cont.resume(returning: av)
            }
        }
    }

    /// 相册视频 → AVPlayerItem（不依赖 URL，AVComposition 也能直接播）
    static func playerItem(localId: String) async -> AVPlayerItem? {
        guard let av = await asset(localId: localId) else { return nil }
        let item = AVPlayerItem(asset: av)
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }

    /// 分享需要真实文件：AVURLAsset 直接用，其余（AVComposition）导出为 mp4
    static func exportURL(localId: String) async -> URL? {
        guard let av = await asset(localId: localId) else { return nil }
        if let u = av as? AVURLAsset { return u.url }
        guard let session = AVAssetExportSession(asset: av, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appending(path: "album-\(UUID().uuidString).mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status == .completed,
           let attrs = try? FileManager.default.attributesOfItem(atPath: out.path),
           ((attrs[.size] as? Int64) ?? 0) > 0 {
            return out
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }
}

// MARK: - 通用本地视频播放视图（相册资产 / 文件双通道）

struct LocalVideoView: View {
    /// 相册资产 id（与 fileURL 二选一）
    var localId: String? = nil
    /// 「文件」App 中的路径
    var fileURL: URL? = nil

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        Group {
            if let fileURL = fileURL {
                VLCFileView(url: fileURL)
            } else if let player = player {
                VideoPlayer(player: player)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(CL.orange)
                    Text("该视频已从相册移除或仍在 iCloud")
                        .font(.subheadline)
                    Text("可在「本地文件」删除该记录后重新下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .task(id: localId ?? fileURL?.absoluteString) {
            guard fileURL == nil, let id = localId else { return }
            if let item = await LocalVideoResolver.playerItem(localId: id) {
                let p = AVPlayer(playerItem: item)
                p.play()
                player = p
            } else {
                failed = true
            }
        }
        .onDisappear { player?.pause() }
    }
}
