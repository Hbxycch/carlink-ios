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
        guard await hasVideoTrack(asset) else { return nil }

        // 直通（remux）：不重编码，仅换容器
        if let out = await export(asset: asset, preset: AVAssetExportPresetPassthrough, type: .mp4) {
            return Result(url: out, duration: await durationSeconds(of: asset))
        }
        // 少数 TS 直通不支持 mp4 封装时，退回 mov 容器（相册同样接受）
        if let out = await export(asset: asset, preset: AVAssetExportPresetPassthrough, type: .mov) {
            return Result(url: out, duration: await durationSeconds(of: asset))
        }
        // 再退一步：H.264 直通失败（SPS/PPS 异常等）时用最高画质重编码，慢但一定能播
        if let out = await export(asset: asset, preset: AVAssetExportPresetHighestQuality, type: .mp4) {
            return Result(url: out, duration: await durationSeconds(of: asset))
        }
        return nil
    }

    /// 视频是否可播：有视频轨 + isPlayable
    static func hasVideoTrack(_ asset: AVAsset) async -> Bool {
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { return false }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return !tracks.isEmpty
        } catch {
            return false
        }
    }

    /// 校验落地文件（存相册前调用，避免把只有音轨/损坏的 mp4 写进相册）
    static func isPlayableVideoFile(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attrs?[.size] as? Int64) ?? 0) > 1024 else { return false }
        return await hasVideoTrack(AVURLAsset(url: url))
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
            // 关键校验：导出成功但没视频轨（只有 AAC）时宁可判失败回退 TS
            if await hasVideoTrack(AVURLAsset(url: out)) {
                return out
            }
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    private static func durationSeconds(of asset: AVAsset) async -> Double? {
        let d = try? await asset.load(.duration)
        let seconds = CMTimeGetSeconds(d ?? .zero)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
