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

// MARK: - 已保存设备

struct SavedDevice: Codable, Identifiable, Equatable {
    var host: String
    var port: Int
    var name: String
    var id: String { "\(host):\(port)" }
}
