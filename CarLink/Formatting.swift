import Foundation
import SwiftUI

// MARK: - 格式化工具

enum Fmt {
    static func bytes(_ v: Int64) -> String {
        let f = Double(v)
        if f >= 1_073_741_824 { return String(format: "%.2f GB", f / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.1f MB", f / 1_048_576) }
        if f >= 1024 { return String(format: "%.1f KB", f / 1024) }
        return "\(v) B"
    }

    static func bytes(_ v: Int) -> String { bytes(Int64(v)) }

    static func rate(_ v: Double) -> String {
        let f = Double(v)
        if f >= 1_048_576 { return String(format: "%.1f MB/s", f / 1_048_576) }
        if f >= 1024 { return String(format: "%.1f KB/s", f / 1024) }
        return String(format: "%.0f B/s", f)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func dateTime(_ d: Date) -> String { dateFormatter.string(from: d) }
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func time(_ d: Date) -> String { shortTimeFormatter.string(from: d) }

    /// 秒 → "3:58" / "1:02:03"
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func mseconds(_ ms: Int) -> String {
        duration(Double(ms) / 1000.0)
    }
}

// MARK: - 摄像头颜色

extension Camera {
    var color: Color {
        switch self {
        case .front: return Color(red: 0.18, green: 0.49, blue: 0.88)   // 蓝
        case .rear: return Color(red: 0.93, green: 0.47, blue: 0.10)    // 橙
        case .free: return Color(red: 0.13, green: 0.68, blue: 0.38)    // 绿
        case .unknown: return Color.gray
        }
    }
}

/// 摄像头角标（前/后/自由，彩色小圆角）
struct CameraBadge: View {
    let camera: Camera
    var body: some View {
        Text(camera.title)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(camera.color))
    }
}

// MARK: - 视频文件时长缓存（播放/下载后回填，列表展示用）

enum DurationCache {
    private static var store: [String: Double] = [:]

    static func duration(for path: String) -> Double? {
        store[path]
    }

    static func set(_ d: Double, for path: String) {
        store[path] = d
    }
}
