import Foundation
import SwiftUI

// MARK: - 媒体分类（与车机端 /api/files?category= 对应）

enum MediaCategory: String, CaseIterable, Identifiable, Codable {
    case loop
    case snapshot
    case locked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: return "循环文件"
        case .snapshot: return "抓拍文件"
        case .locked: return "锁影文件"
        }
    }

    var apiValue: String { rawValue }
}

// MARK: - 摄像头

enum Camera: String, Codable, CaseIterable {
    case front
    case rear
    case free
    case unknown

    var title: String {
        switch self {
        case .front: return "前"
        case .rear: return "后"
        case .free: return "自由"
        case .unknown: return "·"
        }
    }
}

// MARK: - 远端文件条目（车机端 FileEntry.toJson）

struct CarFile: Identifiable, Codable, Hashable {
    let name: String
    let path: String
    let size: Int64
    let modified: Double
    let format: String?
    let camera: String?
    let locked: Bool?
    let thumb: String?

    var id: String { path }

    var cameraEnum: Camera { Camera(rawValue: (camera ?? "unknown").lowercased()) ?? .unknown }

    var isVideo: Bool {
        let f = (format ?? "").lowercased()
        return ["ts", "mp4", "mov", "avi", "mkv", "mpg", "mpeg"].contains(f)
    }

    var date: Date { Date(timeIntervalSince1970: modified / 1000.0) }

    /// 文件名中的时间戳，如 20260101_120000 → "20260101_120000"
    var stamp: String? {
        guard let m = name.range(of: #"\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        return String(name[m])
    }

    /// 三路互切用：同时间戳不同摄像头
    func sameStamp(as other: CarFile) -> Bool {
        guard let a = stamp, let b = other.stamp else { return false }
        return a == b
    }
}

// MARK: - /api/files 响应

struct FileListResponse: Codable {
    let files: [CarFile]
    let type: String?
    let category: String?
    let total: Int?
    /// 分页：车机端还会返回 hasMore / indexing / scanned（老版本没有这些字段）
    let hasMore: Bool?
    let indexing: Bool?
    let scanned: Int?
}

/// 一页文件列表（车机端是「后台建索引 + 内存切片」，索引没建好时 indexing = true）
struct FilePage {
    let files: [CarFile]
    let total: Int
    let hasMore: Bool
    let indexing: Bool
    let scanned: Int
    var isEmpty: Bool { files.isEmpty && total == 0 }
}

// MARK: - /api/info 中的 wifi 节点

struct WifiInfo: Codable {
    let mode: String?      // station | ap
    let band: String?      // 2.4GHz | 5GHz | 6GHz
    let freqMhz: Int?
    let channel: Int?
    let linkSpeed: Int?
    let rssi: Int?
    let quality: String?   // 优 | 良 | 一般 | 弱
}

// MARK: - /api/info
struct CarInfo: Codable {
    struct Switches: Codable {
        let screenshot: Bool?
        let dashcam: Bool?
        let receive: Bool?
    }
    struct Counts: Codable {
        let screenshot: Int?
        let dashcam: Int?
    }
    let deviceName: String
    let version: String
    let versionCode: Int?
    let port: Int
    let ip: String?
    let theme: String?
    /// 车机机型（Android Build.MODEL，如 ROCO K706 / TCL 85Q9K）
    let model: String?
    /// 车机厂商（Build.BRAND）
    let brand: String?
    let wifi: WifiInfo?
    let switches: Switches?
    let counts: Counts?
    /// 车机是否支持快照流（v1.1.28+）
    let cameraFrame: Bool?
    /// 车机是否支持屏幕截图（v1.1.29+）
    let screenCapture: Bool?
    /// 车机是否支持远程重启整机（v1.1.30+）
    let deviceControl: Bool?

    /// 容错解码：老版本车机缺字段（如 port / version）也允许连上，
    /// 避免浏览器能打开、App 却因 JSON 解析失败连不上的情况
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = (try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? "车机"
        version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? "?"
        versionCode = try? c.decodeIfPresent(Int.self, forKey: .versionCode)
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? 8080
        ip = try? c.decodeIfPresent(String.self, forKey: .ip)
        theme = try? c.decodeIfPresent(String.self, forKey: .theme)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        brand = try? c.decodeIfPresent(String.self, forKey: .brand)
        wifi = try? c.decodeIfPresent(WifiInfo.self, forKey: .wifi)
        switches = try? c.decodeIfPresent(Switches.self, forKey: .switches)
        counts = try? c.decodeIfPresent(Counts.self, forKey: .counts)
        cameraFrame = try? c.decodeIfPresent(Bool.self, forKey: .cameraFrame)
        screenCapture = try? c.decodeIfPresent(Bool.self, forKey: .screenCapture)
        deviceControl = try? c.decodeIfPresent(Bool.self, forKey: .deviceControl)
    }

    /// 机型展示："ROCO K706"（无 model 时退回 brand）
    var modelText: String? {
        if let m = model, !m.isEmpty { return m }
        if let b = brand, !b.isEmpty { return b }
        return nil
    }
}

// MARK: - /api/volumes（内部存储 / SD 卡 / USB 剩余空间）

struct VolumeInfo: Codable, Identifiable {
    let uuid: String?
    let type: String?         // internal / sd / usb
    let path: String?
    let description: String?
    let totalBytes: Int64?
    let freeBytes: Int64?
    let removable: Bool?
    let mounted: Bool?

    var id: String { (uuid ?? path ?? description ?? "v") + (type ?? "") }
    var usedRatio: Double {
        guard let t = totalBytes, t > 0, let f = freeBytes else { return 0 }
        return min(1, max(0, Double(t - f) / Double(t)))
    }
    var isMounted: Bool { mounted ?? true }
}

struct VolumeListResponse: Codable {
    let volumes: [VolumeInfo]
}

// MARK: - /api/status

struct StatusResponse: Codable {
    let serviceRunning: Bool?
    let upRate: Double?
    let downRate: Double?
    let upTotal: Int64?
    let downTotal: Int64?
    let clientCount: Int?
}

// MARK: - 上传相关响应

struct UploadInitResponse: Decodable {
    let ok: Bool
    let uploadId: String?
    let offset: Int64?
    let policy: String?
    let error: String?
}

struct UploadChunkResponse: Decodable {
    let ok: Bool
    let offset: Int64?
    let error: String?
}

struct UploadCompleteResponse: Decodable {
    let ok: Bool
    let saved: Bool?
    let path: String?
    let name: String?
    let error: String?
}

// MARK: - /api/browse 车机文件浏览器

struct BrowseEntry: Codable, Identifiable {
    let name: String
    let path: String
    let dir: Bool
    let size: Int64?
    let modified: Double?
    let ext: String?
    /// 根节点（存储卷）标记
    let root: Bool?
    let freeBytes: Int64?
    let totalBytes: Int64?

    var id: String { path }
    var date: Date { Date(timeIntervalSince1970: (modified ?? 0) / 1000.0) }
}

struct BrowseResponse: Codable {
    let ok: Bool?
    let path: String?
    let parent: String?
    let entries: [BrowseEntry]
    let total: Int?
    let hasMore: Bool?
    let truncated: Bool?
    let error: String?
}

// MARK: - 已保存设备

struct SavedDevice: Codable, Identifiable, Equatable {
    var host: String
    var port: Int
    var name: String
    var id: String { "\(host):\(port)" }
}

// MARK: - /api/stream/status 摄像头推流

struct StreamStatusResponse: Codable {
    let streams: [StreamInfo]
    let ffmpeg: StreamFfmpeg?
}

struct StreamInfo: Codable, Identifiable {
    let camera: String
    /// 当前是否有推流线程在跑
    let enabled: Bool?
    /// 配置里的开关（区分「没开」和「开了但没跑起来」）
    let on: Bool?
    let url: String?
    let state: String?
    let currentFile: String?
    let lastError: String?
    let sinceMs: Int?
    let segments: Int?

    var id: String { camera }

    var title: String {
        switch camera {
        case "front": return "前路"
        case "rear": return "后路"
        case "free": return "自由视角"
        default: return camera
        }
    }

    var stateTitle: String {
        switch state ?? "" {
        case "pushing": return "推流中"
        case "waiting": return "等待录像"
        case "error": return "错误重试"
        case "no-dir": return "未找到录像目录"
        case "no-video": return "目录无录像"
        case "no-ffmpeg": return "组件部署中"
        case "starting": return "启动中"
        case "stopped": return "已停止"
        default: return "未启动"
        }
    }

    var stateColor: Color {
        switch state ?? "" {
        case "pushing": return .green
        case "waiting", "starting", "no-ffmpeg": return .orange
        case "error", "no-dir", "no-video": return .red
        default: return .secondary
        }
    }
}

struct StreamFfmpeg: Codable {
    let state: String?
    let progress: Int?
    let installed: Bool?
    let error: String?
}

// MARK: - /api/camera/status 车机快照流

struct CameraFrameStatus: Codable, Identifiable {
    let camera: String
    let hasFrame: Bool?
    /// live = ffmpeg 关键帧管线；snapshot = 一次性抽帧 / DVR 缩略图兜底
    let source: String?
    let ageMs: Int?
    let bytes: Int?
    let width: Int?
    let height: Int?
    /// starting / running / idle / no-ffmpeg / no-file / error / stopped
    let worker: String?
    let ffmpeg: Bool?
    let error: String?

    var id: String { camera }

    var sourceTitle: String {
        switch source ?? "" {
        case "live": return "实时帧"
        case "snapshot": return "快照"
        default: return "无画面"
        }
    }
}

struct CameraFramesResponse: Codable {
    let frames: [CameraFrameStatus]
}

// MARK: - /api/screen/recent（车机 CarCap 目录里的历史截图）

struct ScreenShotItem: Codable, Identifiable {
    let name: String
    let path: String
    let size: Int64?
    let mtime: Int64?

    var id: String { path }

    var date: Date? {
        guard let m = mtime, m > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(m) / 1000)
    }
}

struct ScreenShotsResponse: Codable {
    let shots: [ScreenShotItem]
    let dir: String?
}
