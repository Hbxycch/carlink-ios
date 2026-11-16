import Foundation

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
    let wifi: WifiInfo?
    let switches: Switches?
    let counts: Counts?
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

// MARK: - 已保存设备

struct SavedDevice: Codable, Identifiable, Equatable {
    var host: String
    var port: Int
    var name: String
    var id: String { "\(host):\(port)" }
}
