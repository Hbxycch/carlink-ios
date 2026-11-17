import Foundation
import AVFoundation

/// 手机端 TS → MP4 转封装（AVAssetExportSession 直通模式，不转码、画质无损）。
///
/// 背景：部分车机/电视 ROM 的 32 位 stagefright MPEG4Writer 有原生缺陷，
/// 服务端转封装会 SIGABRT（`FORTIFY: write: count -1`），因此改由 iOS 系统
/// muxer 在手机本地完成。记录仪 TS 是 H.264 + AAC(ADTS)，AVFoundation 原生支持。
enum LocalRemux {

    struct Result {
        let url: URL
        let duration: Double?
    }

    /// 转封装为 mp4；失败返回 nil（调用方回退保存原始 TS）
    static func toMp4(src: URL) async -> Result? {
        let asset = AVURLAsset(url: src)

        // 先确认容器可读且有视频轨
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { return nil }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else { return nil }
        } catch {
            return nil
        }

        // 直通（remux）：不重编码，仅换容器
        if let out = await export(asset: asset, preset: AVAssetExportPresetPassthrough, type: .mp4) {
            return Result(url: out, duration: durationSeconds(of: asset))
        }
        // 少数 TS 直通不支持 mp4 封装时，退回 mov 容器（相册同样接受）
        if let out = await export(asset: asset, preset: AVAssetExportPresetPassthrough, type: .mov) {
            return Result(url: out, duration: durationSeconds(of: asset))
        }
        return nil
    }

    private static func export(asset: AVAsset, preset: String, type: AVFileType) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        guard session.supportedFileTypes.contains(type) else { return nil }

        let ext = (type == .mov) ? "mov" : "mp4"
        let out = FileManager.default.temporaryDirectory
            .appending(path: "remux-\(UUID().uuidString).\(ext)")
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        if session.status == .completed {
            let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            if size > 0 { return out }
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    private static func durationSeconds(of asset: AVAsset) -> Double? {
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
